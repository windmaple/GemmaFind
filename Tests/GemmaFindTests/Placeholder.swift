import Foundation
import XCTest
@testable import GemmaFindCore

/// Deterministic fake embedder: bag-of-words hashed into a normalized vector.
/// Texts sharing words get high cosine similarity, which is enough to test plumbing.
struct FakeEmbedder: Embedder {
    let dimension = 64

    func vector(_ text: String) -> [Float] {
        var v = [Float](repeating: 0, count: dimension)
        for w in text.lowercased().split(whereSeparator: { !$0.isLetter }) where w.count > 2 {
            var h = Hasher(); h.combine(String(w)); let i = abs(h.finalize()) % dimension
            v[i] += 1
        }
        let n = sqrt(v.reduce(0) { $0 + $1 * $1 })
        return n > 0 ? v.map { $0 / n } : v.enumerated().map { $0.offset == 0 ? 1 : 0 }
    }

    func embedQuery(_ text: String) async throws -> [Float] { vector(text) }
    func embedDocuments(_ items: [EmbeddingInput]) async throws -> [[Float]] {
        items.map {
            switch $0 {
            case .document(_, let t), .raw(let t): return vector(t)
            case .image, .audio: return vector("media")
            }
        }
    }
}

final class TextChunkerTests: XCTestCase {
    func testShortTextIsSingleChunk() {
        let chunks = TextChunker().chunk("Hello world.")
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks[0].1, NSRange(location: 0, length: 12))
    }

    func testRangesMatchSubstringsAndCoverText() {
        let sentence = "The quick brown fox jumps over the lazy dog. "
        let text = String(repeating: sentence, count: 120) + "Final 🦊 emoji sentence."
        let chunker = TextChunker(targetLength: 500, overlap: 80)
        let chunks = chunker.chunk(text)
        XCTAssertGreaterThan(chunks.count, 5)
        let ns = text as NSString
        var covered = 0
        for (s, r) in chunks {
            XCTAssertEqual(ns.substring(with: r), s, "chunk text must equal the substring at its range")
            XCTAssertLessThanOrEqual(r.length, 500)
            XCTAssertLessThanOrEqual(r.location, covered, "chunks must not leave gaps")
            covered = max(covered, NSMaxRange(r))
        }
        XCTAssertEqual(covered, ns.length)
        // Sentence-aligned: most chunks end right after a period+space.
        let aligned = chunks.dropLast().filter { $0.0.hasSuffix(". ") }.count
        XCTAssertGreaterThan(aligned, chunks.count / 2)
    }

    func testSentenceSplitter() {
        let r = SentenceSplitter.sentences(in: "First one. Second one!  Third?")
        XCTAssertEqual(r.count, 3)
        XCTAssertEqual(("First one. Second one!  Third?" as NSString).substring(with: r[1]), "Second one!")
    }
}

final class VectorIndexTests: XCTestCase {
    func randomUnit(_ d: Int) -> [Float] {
        var v = (0..<d).map { _ in Float.random(in: -1...1) }
        let n = sqrt(v.reduce(0) { $0 + $1 * $1 }); v = v.map { $0 / n }
        return v
    }

    func testTopKMatchesNaive() {
        let d = 32
        let index = VectorIndex(dimension: d)
        var vecs: [Int64: [Float]] = [:]
        for i in 0..<500 {
            let v = randomUnit(d); vecs[Int64(i)] = v
            index.add(chunkID: Int64(i), fileID: Int64(i / 5), modality: .text, vector: v)
        }
        let q = randomUnit(d)
        let hits = index.search(q, k: 10)
        let naive = vecs.map { ($0.key, zip(q, $0.value).reduce(Float(0)) { $0 + $1.0 * $1.1 }) }
            .sorted { $0.1 > $1.1 }.prefix(10).map { $0.0 }
        XCTAssertEqual(hits.map(\.chunkID), Array(naive))
        XCTAssertEqual(hits.first?.similarity ?? 0, zip(q, vecs[naive[0]]!).reduce(0) { $0 + $1.0 * $1.1 }, accuracy: 1e-4)
    }

    func testRemoveKeepsIndexConsistent() {
        let d = 8
        let index = VectorIndex(dimension: d)
        let a = randomUnit(d), b = randomUnit(d), c = randomUnit(d)
        index.add(chunkID: 1, fileID: 1, modality: .text, vector: a)
        index.add(chunkID: 2, fileID: 1, modality: .text, vector: b)
        index.add(chunkID: 3, fileID: 2, modality: .text, vector: c)
        index.remove(chunkIDs: [1])
        XCTAssertEqual(index.count, 2)
        XCTAssertEqual(index.search(c, k: 1).first?.chunkID, 3)
        XCTAssertEqual(index.search(b, k: 1).first?.chunkID, 2)
        let included = index.search(b, k: 1, include: [3])
        XCTAssertEqual(Set(included.map(\.chunkID)), [2, 3])
    }

    func testCalibrationPutsModalitiesOnCommonScale() {
        // Visual scores are systematically lower; calibration should still surface the visual outlier.
        var scores: [Float] = (0..<100).map { _ in Float.random(in: 0.50...0.55) }
        var groups = [UInt8](repeating: 0, count: 100)
        scores += (0..<50).map { _ in Float.random(in: 0.20...0.25) }
        groups += [UInt8](repeating: 1, count: 50)
        scores.append(0.40); groups.append(1)   // relevant image: low raw, high within-group
        let cal = VectorIndex.calibrate(scores: scores, groups: groups)
        XCTAssertEqual(cal.indices.max { cal[$0] < cal[$1] }, scores.count - 1)
    }
}

final class HighlighterTests: XCTestCase {
    func testTermRangesWordStartsAndInflections() {
        let text = "Solar panels shed snow. A panel's angle matters; unsnowy days help. SOLAR!"
        let ranges = Highlighter.termRanges(in: text, query: "solar panel snow")
        let words = ranges.map { (text as NSString).substring(with: $0).lowercased() }
        XCTAssertTrue(words.contains("solar"))
        XCTAssertTrue(words.contains("panels"))
        XCTAssertTrue(words.contains("snow"))
        XCTAssertFalse(words.contains { $0.contains("unsnow") }, "must match at word starts only")
        XCTAssertEqual(words.filter { $0 == "solar" }.count, 2)
    }

    func testStopwordsIgnored() {
        XCTAssertEqual(QueryTerms.terms(in: "Where is the budget for the trip?"), ["budget", "trip"])
    }

    func testBestSentencesPicksRelevantSentence() async {
        let e = FakeEmbedder()
        let text = "We talked about the weather. The budget for marketing grew a lot. Then lunch."
        let q = try! await e.embedQuery("marketing budget")
        let m = await Highlighter.bestSentences(chunkText: text, chunkRange: NSRange(location: 100, length: (text as NSString).length),
                                                title: nil, queryVector: q, embedder: e)
        XCTAssertFalse(m.isEmpty)
        let r = NSRange(location: m[0].range.location - 100, length: m[0].range.length)
        XCTAssertEqual((text as NSString).substring(with: r), "The budget for marketing grew a lot.")
    }
}

final class ExtractionTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("gf-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func testHTMLStripping() {
        let s = HTMLStripper.strip("<html><head><title>x</title><style>p{}</style></head><body><h1>Hi</h1><p>A &amp; B</p><script>evil()</script></body></html>")
        XCTAssertEqual(s, "Hi\nA & B")
    }

    func testRTFAndBinaryDetection() throws {
        let rtf = dir.appendingPathComponent("a.rtf")
        let attr = NSAttributedString(string: "Descale the espresso machine monthly.")
        try attr.rtf(from: NSRange(location: 0, length: attr.length), documentAttributes: [:])!.write(to: rtf)
        XCTAssertEqual(TextExtractor.fullText(of: rtf, kind: .richText)?.trimmingCharacters(in: .whitespacesAndNewlines),
                       "Descale the espresso machine monthly.")
        let bin = dir.appendingPathComponent("b.txt")
        try Data([0, 1, 2, 0, 0, 0, 5, 0, 0, 0]).write(to: bin)
        XCTAssertNil(TextExtractor.fullText(of: bin, kind: .text))
    }

    func testWavHeader() {
        let wav = MediaProcessor.wavData(pcm16: [Int16](repeating: 100, count: 1600)[...], sampleRate: 16000)
        XCTAssertEqual(wav.count, 44 + 3200)
        XCTAssertEqual(String(data: wav.prefix(4), encoding: .ascii), "RIFF")
        XCTAssertEqual(String(data: wav[8..<12], encoding: .ascii), "WAVE")
    }

    func testFileKinds() {
        XCTAssertEqual(FileTypes.kind(for: URL(fileURLWithPath: "/x/a.MD")), .text)
        XCTAssertEqual(FileTypes.kind(for: URL(fileURLWithPath: "/x/a.docx")), .richText)
        XCTAssertEqual(FileTypes.kind(for: URL(fileURLWithPath: "/x/a.HEIC")), .image)
        XCTAssertEqual(FileTypes.kind(for: URL(fileURLWithPath: "/x/a.mov")), .video)
        XCTAssertEqual(FileTypes.kind(for: URL(fileURLWithPath: "/x/a.m4a")), .audio)
        XCTAssertEqual(FileTypes.kind(for: URL(fileURLWithPath: "/x/Makefile")), .text)
        XCTAssertNil(FileTypes.kind(for: URL(fileURLWithPath: "/x/a.zip")))
    }
}

final class IndexPipelineTests: XCTestCase {
    func testIndexSearchUpdateDelete() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("gf-pipe-\(UUID().uuidString)")
        try fm.createDirectory(at: root.appendingPathComponent("node_modules"), withIntermediateDirectories: true)
        try "Sourdough bread needs a lively starter and a long ferment.".write(to: root.appendingPathComponent("bread.txt"), atomically: true, encoding: .utf8)
        try "Quarterly budget review: marketing spend and server costs.".write(to: root.appendingPathComponent("budget.md"), atomically: true, encoding: .utf8)
        try "ignored dependency".write(to: root.appendingPathComponent("node_modules/x.js"), atomically: true, encoding: .utf8)
        defer { try? fm.removeItem(at: root) }

        let e = FakeEmbedder()
        let store = try IndexStore(url: root.appendingPathComponent("../\(root.lastPathComponent).sqlite").standardizedFileURL, dimension: e.dimension)
        let vectors = VectorIndex(dimension: e.dimension)
        let indexer = Indexer(store: store, vectors: vectors, embedder: e, settings: IndexSettings(folders: [root.standardizedFileURL.path]))
        await indexer.requestFullScan()
        try await waitUntil { store.counts().files == 2 }
        XCTAssertEqual(vectors.count, 2, "node_modules must be skipped")

        let engine = SearchEngine(store: store, vectors: vectors, embedder: e)
        var r = try await engine.search("sourdough starter")
        XCTAssertEqual(r.results.first?.file.name, "bread.txt")
        r = try await engine.search("budget")
        XCTAssertEqual(r.results.first?.file.name, "budget.md")
        XCTAssertTrue(r.results.first?.keywordMatch ?? false)

        // Modify: new content should replace the old chunks.
        try "Notes about espresso machines and descaling.".write(to: root.appendingPathComponent("bread.txt"), atomically: true, encoding: .utf8)
        let future = Date().addingTimeInterval(5)
        try fm.setAttributes([.modificationDate: future], ofItemAtPath: root.appendingPathComponent("bread.txt").path)
        await indexer.noteChanged(paths: [root.appendingPathComponent("bread.txt").standardizedFileURL.path])
        try await waitUntil { (store.keywordSearch("espresso").first) != nil }
        XCTAssertTrue(store.keywordSearch("sourdough").isEmpty)
        XCTAssertEqual(vectors.count, 2)

        // Delete.
        try fm.removeItem(at: root.appendingPathComponent("budget.md"))
        await indexer.noteChanged(paths: [root.appendingPathComponent("budget.md").standardizedFileURL.path])
        try await waitUntil { store.counts().files == 1 }
        XCTAssertEqual(vectors.count, 1)
    }

    func waitUntil(timeout: TimeInterval = 10, _ condition: @escaping () -> Bool) async throws {
        let start = Date()
        while !condition() {
            if Date().timeIntervalSince(start) > timeout { XCTFail("timed out"); return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }
}
