import Foundation

public enum AppPaths {
    public static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("GemmaFind", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    public static var modelsDirectory: URL {
        let dir = supportDirectory.appendingPathComponent("models", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    public static var cacheDirectory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("GemmaFind", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    public static var indexDatabase: URL { supportDirectory.appendingPathComponent("index.sqlite") }
}

/// The EmbeddingGemma 2 LiteRT-LM model (text + image + audio encoders).
public enum ModelInfo {
    public static let fileName = "embeddinggemma-2-740m.litertlm"
    public static let repo = "litert-community/embeddinggemma-2-740m-litert-lm"
    public static let expectedSize: Int64 = 484_622_336
    public static var downloadURL: URL { URL(string: "https://huggingface.co/\(repo)/resolve/main/\(fileName)")! }
    public static var localURL: URL { AppPaths.modelsDirectory.appendingPathComponent(fileName) }
    public static let dimension = 768

    public static var isDownloaded: Bool {
        let attrs = try? FileManager.default.attributesOfItem(atPath: localURL.path)
        return (attrs?[.size] as? NSNumber)?.int64Value == expectedSize
    }
}

/// Downloads the model with progress reporting.
public final class ModelDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private var continuation: CheckedContinuation<URL, Error>?
    private var progressHandler: (@Sendable (Double) -> Void)?
    private var session: URLSession?

    public override init() {}

    public func download(progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        if ModelInfo.isDownloaded { return ModelInfo.localURL }
        progressHandler = progress
        return try await withCheckedThrowingContinuation { cont in
            continuation = cont
            let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
            self.session = session
            session.downloadTask(with: ModelInfo.downloadURL).resume()
        }
    }

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                           totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : ModelInfo.expectedSize
        progressHandler?(Double(totalBytesWritten) / Double(total))
    }

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            let dest = ModelInfo.localURL
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: location, to: dest)
            continuation?.resume(returning: dest)
        } catch {
            continuation?.resume(throwing: error)
        }
        continuation = nil
        session.finishTasksAndInvalidate()
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            continuation?.resume(throwing: error)
            continuation = nil
        }
        session.finishTasksAndInvalidate()
    }
}
