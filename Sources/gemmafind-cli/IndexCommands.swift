import Foundation
import GemmaFindCore

/// `index <folder> [--db path]` and `search "<query>" [--db path]`.
func runIndexCommand(_ command: String) async throws {
    let dbURL = argValue("--db").map { URL(fileURLWithPath: $0) }
        ?? AppPaths.cacheDirectory.appendingPathComponent("cli-index.sqlite")
    let store = try IndexStore(url: dbURL, dimension: ModelInfo.dimension)
    let vectors = VectorIndex(dimension: ModelInfo.dimension)
    let embedder = GemmaEmbedder(modelPath: ModelInfo.localURL.path)
    try await embedder.load()

    switch command {
    case "index":
        guard CommandLine.arguments.count > 2 else { print("usage: index <folder>"); return }
        let folder = URL(fileURLWithPath: CommandLine.arguments[2]).standardizedFileURL.path
        let indexer = Indexer(store: store, vectors: vectors, embedder: embedder,
                              settings: IndexSettings(folders: [folder]))
        let start = Date()
        let done = DispatchSemaphore(value: 0)
        let finished = Flag()
        await indexer.loadVectors()
        await indexer.setProgressHandler { p in
            if case .indexing = p.phase, let f = p.currentFile {
                print("  [\(p.filesDone + 1)/\(p.filesTotal)] \((f as NSString).lastPathComponent)")
            }
            if p.phase == .idle, p.filesDone == p.filesTotal, finished.setOnce() {
                print(String(format: "Indexed %d files / %d chunks in %.1fs", p.indexedFiles, p.indexedChunks, Date().timeIntervalSince(start)))
                done.signal()
            }
        }
        await indexer.requestFullScan()
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async { done.wait(); c.resume() }
        }

    case "search":
        guard CommandLine.arguments.count > 2 else { print("usage: search \"query\""); return }
        let query = CommandLine.arguments[2]
        store.forEachEmbedding { cid, fid, m, v in vectors.add(chunkID: cid, fileID: fid, modality: m, vector: v) }
        let engine = SearchEngine(store: store, vectors: vectors, embedder: embedder)
        let r = try await engine.search(query, limit: 10)
        print(String(format: "%d results for \"%@\" in %.1f ms (%d vectors)", r.results.count, query, r.elapsed * 1000, vectors.count))
        for (i, res) in r.results.enumerated() {
            var where_ = ""
            if let p = res.chunk.page { where_ = " p.\(p + 1)" }
            if let t = res.chunk.time { where_ = " @\(t.timestampString)" }
            let snippet = (res.chunk.text ?? "[\(res.chunk.modality)]").replacingOccurrences(of: "\n", with: " ").prefix(90)
            print(String(format: "%2d. %.2f sim=%.3f %@ %@%@%@\n      %@", i + 1, res.score, res.similarity,
                         res.keywordMatch ? "K" : " ", res.file.name, where_, "", String(snippet)))
        }

    default:
        print("Unknown command \(command). Use: smoke | index <folder> | search \"query\"")
    }
}

final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var set = false
    func setOnce() -> Bool { lock.withLock { if set { return false }; set = true; return true } }
}
