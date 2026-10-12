import Foundation

/// Maps file extensions to the kind of content GemmaFind can extract.
public enum FileTypes {
    public static let textExtensions: Set<String> = [
        // prose & data
        "txt", "text", "md", "markdown", "mdx", "rst", "org", "adoc", "tex", "log", "csv", "tsv",
        "json", "jsonl", "yaml", "yml", "toml", "ini", "cfg", "conf", "xml", "plist", "srt", "vtt",
        // code
        "swift", "m", "mm", "h", "hpp", "hh", "c", "cc", "cpp", "cxx", "cs", "java", "kt", "kts",
        "scala", "go", "rs", "py", "pyi", "ipynb", "rb", "php", "pl", "lua", "r", "jl", "dart",
        "js", "mjs", "cjs", "jsx", "ts", "tsx", "vue", "svelte", "css", "scss", "sass", "less",
        "sh", "bash", "zsh", "fish", "ps1", "bat", "sql", "graphql", "proto", "gradle", "cmake",
        "make", "mk", "dockerfile", "tf", "hcl", "nix", "zig", "hs", "ex", "exs", "erl", "clj",
        "elm", "ml", "fs", "v", "sv", "vhd", "asm", "s",
    ]
    public static let pdfExtensions: Set<String> = ["pdf"]
    public static let richTextExtensions: Set<String> = ["rtf", "rtfd", "docx", "doc", "odt", "html", "htm", "webarchive"]
    public static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "gif", "webp", "tif", "tiff", "bmp"]
    public static let videoExtensions: Set<String> = ["mp4", "mov", "m4v", "avi", "mkv", "webm", "3gp"]
    public static let audioExtensions: Set<String> = ["mp3", "m4a", "wav", "aac", "aiff", "aif", "flac", "caf", "ogg", "opus"]

    /// Files with no extension that are still worth reading as text.
    public static let textFileNames: Set<String> = ["makefile", "dockerfile", "readme", "license", "gemfile", "podfile", "procfile"]

    public static func kind(for url: URL) -> FileKind? {
        let ext = url.pathExtension.lowercased()
        if ext.isEmpty {
            return textFileNames.contains(url.lastPathComponent.lowercased()) ? .text : nil
        }
        if textExtensions.contains(ext) { return .text }
        if pdfExtensions.contains(ext) { return .pdf }
        if richTextExtensions.contains(ext) { return .richText }
        if imageExtensions.contains(ext) { return .image }
        if videoExtensions.contains(ext) { return .video }
        if audioExtensions.contains(ext) { return .audio }
        return nil
    }

    /// Per-kind size ceilings to keep indexing snappy.
    public static func maxSize(for kind: FileKind) -> Int64 {
        switch kind {
        case .text: return 5 * 1024 * 1024
        case .pdf: return 200 * 1024 * 1024
        case .richText: return 50 * 1024 * 1024
        case .image: return 80 * 1024 * 1024
        case .video: return 8 * 1024 * 1024 * 1024
        case .audio: return 1024 * 1024 * 1024
        }
    }

    /// Directory names never descended into.
    public static let skippedDirectoryNames: Set<String> = [
        "node_modules", ".git", ".hg", ".svn", "build", ".build", "DerivedData", "Pods", "venv",
        ".venv", "__pycache__", ".gradle", ".idea", ".next", "dist", "target", ".cache", ".Trash",
    ]

    /// Directory extensions that are packages (bundles) and should not be descended into.
    public static let packageExtensions: Set<String> = [
        "app", "framework", "bundle", "photoslibrary", "musiclibrary", "tvlibrary", "xcodeproj",
        "xcworkspace", "xcassets", "pkg", "plugin", "kext", "lproj", "imovielibrary", "fcpbundle",
        "logicx", "band", "pages", "numbers", "key", "sparsebundle",
    ]
}
