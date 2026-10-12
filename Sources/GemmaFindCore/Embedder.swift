import Foundation
import LiteRTLM

/// Anything that turns content into L2-normalized vectors in a shared space.
public protocol Embedder: Sendable {
    var dimension: Int { get }
    func embedQuery(_ text: String) async throws -> [Float]
    func embedDocuments(_ items: [EmbeddingInput]) async throws -> [[Float]]
}

/// A single item to embed.
public enum EmbeddingInput: Sendable {
    /// Document text; `title` is usually the file name.
    case document(title: String?, text: String)
    /// Free-form text that already carries its task prefix.
    case raw(String)
    /// Encoded JPEG/PNG bytes.
    case image(Data)
    /// WAV bytes.
    case audio(Data)
}

/// EmbeddingGemma 2 prompt formats (from the model card).
public enum EmbeddingPrompt {
    public static func query(_ q: String) -> String { "task: search result | query: \(q)" }
    public static func document(title: String?, text: String) -> String {
        let t = (title?.isEmpty == false) ? title! : "none"
        return "title: \(t) | text: \(text)"
    }
}

public enum EmbeddingError: Error, CustomStringConvertible {
    case modelMissing(String)
    case badDimension(Int)
    public var description: String {
        switch self {
        case .modelMissing(let p): return "Model file not found at \(p)"
        case .badDimension(let d): return "Unexpected embedding size \(d)"
        }
    }
}

/// EmbeddingGemma 2 on LiteRT-LM. Tries the Metal GPU backend first and falls back to CPU.
public actor GemmaEmbedder: Embedder {
    public nonisolated let dimension: Int
    public let modelPath: String
    private var engine: EmbeddingEngine?
    public private(set) var backendDescription = "not loaded"

    /// Max text tokens per input. Chunks are ~1000 chars (~250–350 tokens).
    let maxInputLength: Int

    public init(modelPath: String, dimension: Int = 768, maxInputLength: Int = 512) {
        self.modelPath = modelPath
        self.dimension = dimension
        self.maxInputLength = maxInputLength
    }

    public func load(preferGPU: Bool = true) async throws {
        if engine != nil { return }
        guard FileManager.default.fileExists(atPath: modelPath) else { throw EmbeddingError.modelMissing(modelPath) }
        let cacheDir = AppPaths.cacheDirectory.path
        var lastError: Error?
        let attempts: [(Backend, String)] = preferGPU
            ? [(.gpu, "GPU (Metal)"), (.cpu(threadCount: ProcessInfo.processInfo.activeProcessorCount / 2), "CPU")]
            : [(.cpu(threadCount: ProcessInfo.processInfo.activeProcessorCount / 2), "CPU")]
        for (backend, name) in attempts {
            do {
                let config = EmbeddingEngineConfig(
                    modelPath: modelPath,
                    backend: backend,
                    visionBackend: backend,
                    audioBackend: backend,
                    cacheDir: cacheDir,
                    maxInputLength: maxInputLength,
                    visionTokensPerImage: 140
                )
                let e = EmbeddingEngine(config: config)
                try await e.initialize()
                engine = e
                backendDescription = name
                return
            } catch {
                lastError = error
                NSLog("GemmaFind: \(name) backend failed: \(error)")
            }
        }
        throw lastError ?? EmbeddingError.modelMissing(modelPath)
    }

    public func unload() async {
        await engine?.close()
        engine = nil
        backendDescription = "not loaded"
    }

    private func requireEngine() async throws -> EmbeddingEngine {
        if engine == nil { try await load() }
        return engine!
    }

    private var options: EmbeddingOptions { EmbeddingOptions(normalize: true, outputSize: dimension) }

    public func embedQuery(_ text: String) async throws -> [Float] {
        let e = try await requireEngine()
        let r = try await e.computeEmbedding(contents: [.text(EmbeddingPrompt.query(text))], options: options)
        return try check(r.embedding)
    }

    public func embedDocuments(_ items: [EmbeddingInput]) async throws -> [[Float]] {
        guard !items.isEmpty else { return [] }
        let e = try await requireEngine()
        var out: [[Float]] = []
        out.reserveCapacity(items.count)
        // Text inputs are batched; media are embedded one by one (variable-size encoders).
        var textBatch: [(Int, String)] = []
        var results = [[Float]?](repeating: nil, count: items.count)
        for (i, item) in items.enumerated() {
            switch item {
            case .document(let title, let text): textBatch.append((i, EmbeddingPrompt.document(title: title, text: text)))
            case .raw(let s): textBatch.append((i, s))
            case .image(let data):
                results[i] = try check(try await e.computeEmbedding(contents: [.imageData(data)], options: options).embedding)
            case .audio(let data):
                results[i] = try check(try await e.computeEmbedding(contents: [.audioData(data)], options: options).embedding)
            }
        }
        if !textBatch.isEmpty {
            let batch: [[Content]] = textBatch.map { [.text($0.1)] }
            let responses = try await e.computeEmbeddingBatch(contentsBatch: batch, options: options)
            for (k, r) in responses.enumerated() { results[textBatch[k].0] = try check(r.embedding) }
        }
        for r in results { out.append(r ?? [Float](repeating: 0, count: dimension)) }
        return out
    }

    private func check(_ v: [Float]) throws -> [Float] {
        guard v.count == dimension else { throw EmbeddingError.badDimension(v.count) }
        return v
    }
}
