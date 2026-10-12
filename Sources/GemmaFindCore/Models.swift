import Foundation

/// The broad family a file belongs to, used for extraction, icons and preview.
public enum FileKind: Int, Codable, CaseIterable, Sendable {
    case text = 0       // plain text, markdown, source code
    case pdf = 1
    case richText = 2   // rtf, docx, doc, html, odt, pages-exported docs
    case image = 3
    case video = 4
    case audio = 5

    public var displayName: String {
        switch self {
        case .text: return "Text & Code"
        case .pdf: return "PDF"
        case .richText: return "Documents"
        case .image: return "Images"
        case .video: return "Videos"
        case .audio: return "Audio"
        }
    }

    public var symbolName: String {
        switch self {
        case .text: return "doc.text"
        case .pdf: return "doc.richtext"
        case .richText: return "doc.append"
        case .image: return "photo"
        case .video: return "film"
        case .audio: return "waveform"
        }
    }
}

/// The modality of an indexed chunk. Different modalities live in the same vector
/// space but have different similarity distributions, so search normalizes per modality.
public enum ChunkModality: Int, Codable, CaseIterable, Sendable {
    case text = 0
    case image = 1
    case videoFrame = 2
    case audio = 3

    /// Group used for per-modality score calibration.
    var calibrationGroup: Int {
        switch self {
        case .text: return 0
        case .image, .videoFrame: return 1
        case .audio: return 2
        }
    }
}

/// A piece of content extracted from a file, ready to embed.
public enum ExtractedPiece: Sendable {
    /// Text located at `range` (UTF-16 offsets) within the file's extracted text
    /// (or within the page text for PDFs).
    case text(String, range: NSRange, page: Int?)
    /// Encoded JPEG/PNG bytes. `time` is set for video frames (seconds).
    case image(Data, time: Double?)
    /// WAV bytes (16 kHz mono PCM16) covering `time ..< time + duration` seconds.
    case audio(Data, time: Double, duration: Double)
}

/// A stored chunk row (without its embedding).
public struct ChunkRecord: Sendable, Hashable {
    public let id: Int64
    public let fileID: Int64
    public let modality: ChunkModality
    public let text: String?
    public let range: NSRange?
    public let page: Int?
    public let time: Double?
    public let duration: Double?
}

public struct FileRecord: Sendable, Hashable {
    public let id: Int64
    public let path: String
    public let kind: FileKind
    public let modified: Double
    public let size: Int64

    public var url: URL { URL(fileURLWithPath: path) }
    public var name: String { (path as NSString).lastPathComponent }
}

/// One search hit, grouped per file (best chunk wins).
public struct SearchResult: Identifiable, Sendable, Hashable {
    public var id: Int64 { file.id }
    public let file: FileRecord
    public let chunk: ChunkRecord
    /// Raw cosine similarity of the best chunk (may be 0 for keyword-only hits).
    public let similarity: Float
    /// Final fused ranking score (higher is better).
    public let score: Double
    /// Whether a literal keyword / filename match contributed.
    public let keywordMatch: Bool
    /// Other matching chunks in the same file (e.g. more timestamps in a video).
    public let extraChunks: [ChunkRecord]
}

public struct IndexProgress: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        case idle
        case loadingModel
        case downloadingModel(Double)
        case scanning
        case indexing
        case paused
        case error(String)
    }
    public var phase: Phase = .idle
    public var filesTotal: Int = 0
    public var filesDone: Int = 0
    public var currentFile: String?
    public var indexedFiles: Int = 0
    public var indexedChunks: Int = 0

    public init() {}
}
