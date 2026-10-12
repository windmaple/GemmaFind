import Accelerate
import Foundation

/// In-memory brute-force vector index (row-major Float32 matrix) with vDSP scoring.
/// 100k × 768-d ≈ 300 MB and scores in a few milliseconds on Apple Silicon.
public final class VectorIndex: @unchecked Sendable {
    public let dimension: Int
    private let lock = NSLock()
    private var matrix: [Float] = []
    private var chunkIDs: [Int64] = []
    private var fileIDs: [Int64] = []
    private var groups: [UInt8] = []
    private var rowOf: [Int64: Int] = [:]

    public init(dimension: Int) { self.dimension = dimension }

    public var count: Int { lock.withLock { chunkIDs.count } }

    public func removeAll() {
        lock.withLock {
            matrix.removeAll(); chunkIDs.removeAll(); fileIDs.removeAll(); groups.removeAll(); rowOf.removeAll()
        }
    }

    public func add(chunkID: Int64, fileID: Int64, modality: ChunkModality, vector: UnsafeBufferPointer<Float>) {
        precondition(vector.count == dimension)
        lock.withLock {
            if let row = rowOf[chunkID] {
                matrix.withUnsafeMutableBufferPointer { m in
                    for i in 0..<dimension { m[row * dimension + i] = vector[i] }
                }
                return
            }
            rowOf[chunkID] = chunkIDs.count
            chunkIDs.append(chunkID)
            fileIDs.append(fileID)
            groups.append(UInt8(modality.calibrationGroup))
            matrix.append(contentsOf: vector)
        }
    }

    public func add(chunkID: Int64, fileID: Int64, modality: ChunkModality, vector: [Float]) {
        vector.withUnsafeBufferPointer { add(chunkID: chunkID, fileID: fileID, modality: modality, vector: $0) }
    }

    public func remove(chunkIDs ids: [Int64]) {
        guard !ids.isEmpty else { return }
        lock.withLock {
            for id in ids {
                guard let row = rowOf.removeValue(forKey: id) else { continue }
                let last = chunkIDs.count - 1
                if row != last {
                    // Move last row into the hole.
                    let movedID = chunkIDs[last]
                    chunkIDs[row] = movedID
                    fileIDs[row] = fileIDs[last]
                    groups[row] = groups[last]
                    matrix.withUnsafeMutableBufferPointer { m in
                        for i in 0..<dimension { m[row * dimension + i] = m[last * dimension + i] }
                    }
                    rowOf[movedID] = row
                }
                chunkIDs.removeLast(); fileIDs.removeLast(); groups.removeLast()
                matrix.removeLast(dimension)
            }
        }
    }

    public struct Hit: Sendable {
        public let chunkID: Int64
        public let fileID: Int64
        public let similarity: Float
        /// Similarity standardized within its modality group (text / visual / audio),
        /// so cross-modal hits are comparable.
        public let calibrated: Float
    }

    /// Scores every vector against `query` (must be L2-normalized) and returns the top `k`
    /// by calibrated score, plus any chunk ids in `include` regardless of rank.
    public func search(_ query: [Float], k: Int, include: Set<Int64> = []) -> [Hit] {
        precondition(query.count == dimension)
        return lock.withLock {
            let n = chunkIDs.count
            guard n > 0 else { return [] }
            var scores = [Float](repeating: 0, count: n)
            matrix.withUnsafeBufferPointer { m in
                query.withUnsafeBufferPointer { q in
                    scores.withUnsafeMutableBufferPointer { s in
                        vDSP_mmul(m.baseAddress!, 1, q.baseAddress!, 1, s.baseAddress!, 1,
                                  vDSP_Length(n), 1, vDSP_Length(dimension))
                    }
                }
            }
            let calibrated = Self.calibrate(scores: scores, groups: groups)
            // Partial selection of top-k.
            let kk = min(k, n)
            var idx = Array(0..<n)
            if kk < n {
                idx.withUnsafeMutableBufferPointer { buf in
                    Self.partialSort(buf, k: kk) { calibrated[$0] > calibrated[$1] }
                }
                idx = Array(idx[0..<kk])
            }
            if !include.isEmpty {
                let present = Set(idx)
                for id in include { if let row = rowOf[id], !present.contains(row) { idx.append(row) } }
            }
            idx.sort { calibrated[$0] > calibrated[$1] }
            return idx.map { Hit(chunkID: chunkIDs[$0], fileID: fileIDs[$0], similarity: scores[$0], calibrated: calibrated[$0]) }
        }
    }

    /// Per-group z-scores. Groups with too few members borrow the pooled statistics.
    static func calibrate(scores: [Float], groups: [UInt8]) -> [Float] {
        var sum = [Double](repeating: 0, count: 3), sq = [Double](repeating: 0, count: 3), cnt = [Int](repeating: 0, count: 3)
        for i in 0..<scores.count {
            let g = Int(groups[i]); let s = Double(scores[i])
            sum[g] += s; sq[g] += s * s; cnt[g] += 1
        }
        let total = cnt.reduce(0, +)
        let pooledMean = sum.reduce(0, +) / Double(max(total, 1))
        let pooledVar = max(sq.reduce(0, +) / Double(max(total, 1)) - pooledMean * pooledMean, 0)
        var mean = [Double](repeating: pooledMean, count: 3)
        var std = [Double](repeating: max(pooledVar.squareRoot(), 0.03), count: 3)
        for g in 0..<3 where cnt[g] >= 24 {
            let m = sum[g] / Double(cnt[g])
            mean[g] = m
            std[g] = max((sq[g] / Double(cnt[g]) - m * m).squareRoot(), 0.03)
        }
        var out = [Float](repeating: 0, count: scores.count)
        for i in 0..<scores.count {
            let g = Int(groups[i])
            out[i] = Float((Double(scores[i]) - mean[g]) / std[g])
        }
        return out
    }

    /// Quickselect so the first k elements are the k largest (unordered).
    static func partialSort(_ a: UnsafeMutableBufferPointer<Int>, k: Int, by greater: (Int, Int) -> Bool) {
        var lo = 0, hi = a.count - 1
        while lo < hi {
            let pivot = a[(lo + hi) / 2]
            var i = lo, j = hi
            while i <= j {
                while greater(a[i], pivot) { i += 1 }
                while greater(pivot, a[j]) { j -= 1 }
                if i <= j { a.swapAt(i, j); i += 1; j -= 1 }
            }
            if k - 1 <= j { hi = j } else if k - 1 >= i { lo = i } else { return }
        }
    }
}

/// Query word extraction shared by keyword search and preview term highlighting.
public enum QueryTerms {
    static let stopwords: Set<String> = [
        "a", "an", "the", "and", "or", "of", "to", "in", "on", "for", "with", "at", "by", "from", "is", "are",
        "was", "were", "be", "it", "this", "that", "these", "those", "my", "me", "i", "about", "what", "where",
        "when", "how", "which", "who", "find", "show", "file", "files", "some", "any",
    ]

    public static func terms(in query: String) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        query.lowercased().enumerateSubstrings(in: query.lowercased().startIndex..., options: .byWords) { word, _, _, _ in
            guard let w = word, w.count >= 2, !stopwords.contains(w), !seen.contains(w) else { return }
            seen.insert(w); out.append(w)
        }
        return out
    }
}
