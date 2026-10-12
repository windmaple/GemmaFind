import Foundation

/// Hybrid semantic + keyword search, grouped per file.
public final class SearchEngine: @unchecked Sendable {
    let store: IndexStore
    let vectors: VectorIndex
    let embedder: any Embedder

    /// Calibrated (z-score) threshold below which semantic-only hits are treated as noise.
    public var minCalibratedScore: Float = 1.8

    public init(store: IndexStore, vectors: VectorIndex, embedder: any Embedder) {
        self.store = store
        self.vectors = vectors
        self.embedder = embedder
    }

    public struct Response: Sendable {
        public let query: String
        public let queryVector: [Float]
        public let results: [SearchResult]
        public let elapsed: TimeInterval
    }

    public func search(_ rawQuery: String, limit: Int = 40) async throws -> Response {
        let start = Date()
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return Response(query: query, queryVector: [], results: [], elapsed: 0) }

        async let qvTask = embedder.embedQuery(query)
        let keyword = store.keywordSearch(query, limit: 150)
        let qv = try await qvTask
        if Task.isCancelled { throw CancellationError() }

        let keywordRank = Dictionary(keyword.enumerated().map { ($0.element.0, $0.offset) }, uniquingKeysWith: { a, _ in a })
        let hits = vectors.search(qv, k: 400, include: Set(keywordRank.keys))

        // Fuse: calibrated semantic score + a keyword bonus that decays with BM25 rank.
        struct Scored { let hit: VectorIndex.Hit; let score: Double; let keyword: Bool }
        var scored: [Scored] = []
        var belowThreshold: [Scored] = []
        scored.reserveCapacity(hits.count)
        for h in hits {
            var s = Double(h.calibrated)
            let kw = keywordRank[h.chunkID]
            if let r = kw {
                s += 1.0 + 2.0 * (1.0 - Double(r) / Double(max(keyword.count, 1)))
            } else if h.calibrated < minCalibratedScore {
                if belowThreshold.count < 30 { belowThreshold.append(Scored(hit: h, score: s, keyword: false)) }
                continue
            }
            scored.append(Scored(hit: h, score: s, keyword: kw != nil))
        }
        // Nothing confident? Offer a few best guesses (hits are sorted by calibrated score).
        if scored.isEmpty {
            var fileSet = Set<Int64>()
            for s in belowThreshold where fileSet.count < 3 && !fileSet.contains(s.hit.fileID) {
                scored.append(s)
                fileSet.insert(s.hit.fileID)
            }
        }

        // Group by file: best chunk wins, keep a few extras (e.g. more timestamps).
        var byFile: [Int64: [Scored]] = [:]
        for s in scored { byFile[s.hit.fileID, default: []].append(s) }
        var groups = byFile.map { (fid, list) -> (Int64, [Scored]) in (fid, list.sorted { $0.score > $1.score }) }
        groups.sort { a, b in
            // Small boost for files with several strong matching chunks.
            let sa = a.1[0].score + 0.15 * Double(min(a.1.count - 1, 4))
            let sb = b.1[0].score + 0.15 * Double(min(b.1.count - 1, 4))
            return sa > sb
        }
        groups = Array(groups.prefix(limit))

        let files = store.files(ids: groups.map { $0.0 })
        let chunkIDs = groups.flatMap { $0.1.prefix(6).map { $0.hit.chunkID } }
        let chunks = store.chunks(ids: chunkIDs)

        var results: [SearchResult] = []
        for (fid, list) in groups {
            guard let file = files[fid], let best = chunks[list[0].hit.chunkID] else { continue }
            // Skip files that were deleted from disk since indexing.
            let extras = list.dropFirst().prefix(5).compactMap { chunks[$0.hit.chunkID] }
            results.append(SearchResult(file: file, chunk: best, similarity: list[0].hit.similarity,
                                        score: list[0].score + 0.15 * Double(min(list.count - 1, 4)),
                                        keywordMatch: list.contains { $0.keyword }, extraChunks: Array(extras)))
        }
        return Response(query: query, queryVector: qv, results: results, elapsed: Date().timeIntervalSince(start))
    }
}
