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

    case "demo-json":
        // demo-json <corpus-root> <out.json> "q1" "q2" … — real results for the website demo.
        let args = Array(CommandLine.arguments.dropFirst(2)).filter { !$0.hasPrefix("--db") && $0 != argValue("--db") }
        guard args.count >= 3 else { print("usage: demo-json <corpus-root> <out.json> \"query\"…"); return }
        let root = URL(fileURLWithPath: args[0]).standardizedFileURL.path
        store.forEachEmbedding { cid, fid, m, v in vectors.add(chunkID: cid, fileID: fid, modality: m, vector: v) }
        let engine = SearchEngine(store: store, vectors: vectors, embedder: embedder)
        var out: [[String: Any]] = []
        for q in args.dropFirst(2) {
            let r = try await engine.search(q, limit: 4)
            var results: [[String: Any]] = []
            for res in r.results {
                let rel = String(res.file.path.dropFirst(root.count))
                var item: [String: Any] = [
                    "name": res.file.name,
                    "folder": "~/Documents" + (rel as NSString).deletingLastPathComponent,
                    "kind": "\(res.file.kind)",
                    "modality": "\(res.chunk.modality)",
                    "similarity": (Double(res.similarity) * 1000).rounded() / 1000,
                    "score": (res.score * 100).rounded() / 100,
                    "keyword": res.keywordMatch,
                ]
                if let t = res.chunk.time { item["time"] = t; item["times"] = ([res.chunk] + res.extraChunks).compactMap { $0.time } }
                if let d = res.chunk.duration { item["duration"] = d }
                if let p = res.chunk.page { item["page"] = p + 1 }
                if let text = res.chunk.text, let cr = res.chunk.range {
                    let full: String
                    if res.file.kind == .pdf {
                        full = TextExtractor.pdfPages(of: res.file.url)[res.chunk.page ?? 0]
                    } else {
                        full = TextExtractor.fullText(of: res.file.url, kind: res.file.kind) ?? text
                    }
                    let sentences = await Highlighter.bestSentences(chunkText: text, chunkRange: cr, title: res.file.name,
                                                                    queryVector: r.queryVector, embedder: embedder)
                    // JS strings are UTF-16 too, so NSRange offsets carry over directly.
                    item["text"] = full
                    item["passage"] = [cr.location, cr.length]
                    item["sentences"] = sentences.map { [$0.range.location, $0.range.length] }
                    item["terms"] = Highlighter.termRanges(in: full, query: q).map { [$0.location, $0.length] }
                }
                results.append(item)
            }
            out.append(["query": q, "ms": Int(r.elapsed * 1000), "results": results])
            print("  \(q) → \(r.results.map { $0.file.name })")
        }
        let data = try JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: args[1]))
        print("Wrote \(args[1])")

    default:
        print("Unknown command \(command). Use: smoke | index <folder> | search \"query\" | demo-json <root> <out> \"q\"…")
    }
}

final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var set = false
    func setOnce() -> Bool { lock.withLock { if set { return false }; set = true; return true } }
}
