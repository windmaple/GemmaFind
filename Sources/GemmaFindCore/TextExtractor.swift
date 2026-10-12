import AppKit
import Foundation
import PDFKit

/// Extracts plain text from text-like files. The exact same functions are used at index
/// time and preview time so stored UTF-16 ranges line up with what the preview shows.
public enum TextExtractor {
    /// Full text for `.text` and `.richText` files.
    public static func fullText(of url: URL, kind: FileKind) -> String? {
        switch kind {
        case .text: return readPlainText(url)
        case .richText: return readRichText(url)
        default: return nil
        }
    }

    /// Per-page text for PDFs (index 0-based).
    public static func pdfPages(of url: URL, maxPages: Int = 500) -> [String] {
        guard let doc = PDFDocument(url: url) else { return [] }
        let count = min(doc.pageCount, maxPages)
        var pages: [String] = []
        pages.reserveCapacity(count)
        for i in 0..<count {
            pages.append(doc.page(at: i)?.string ?? "")
        }
        return pages
    }

    static func readPlainText(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        if looksBinary(data) { return nil }
        if let s = String(data: data, encoding: .utf8) { return s }
        var enc: String.Encoding = .utf8
        if let s = try? String(contentsOf: url, usedEncoding: &enc) { return s }
        return String(data: data, encoding: .isoLatin1)
    }

    static func looksBinary(_ data: Data) -> Bool {
        let sample = data.prefix(8192)
        guard !sample.isEmpty else { return false }
        var zeros = 0
        for b in sample where b == 0 { zeros += 1 }
        return zeros > sample.count / 100
    }

    static func readRichText(_ url: URL) -> String? {
        let ext = url.pathExtension.lowercased()
        if ext == "html" || ext == "htm" {
            guard let html = readPlainText(url) else { return nil }
            return HTMLStripper.strip(html)
        }
        var options: [NSAttributedString.DocumentReadingOptionKey: Any] = [:]
        switch ext {
        case "docx": options[.documentType] = NSAttributedString.DocumentType.officeOpenXML
        case "doc": options[.documentType] = NSAttributedString.DocumentType.docFormat
        case "odt": options[.documentType] = NSAttributedString.DocumentType.openDocument
        case "rtf": options[.documentType] = NSAttributedString.DocumentType.rtf
        case "rtfd": options[.documentType] = NSAttributedString.DocumentType.rtfd
        case "webarchive": options[.documentType] = NSAttributedString.DocumentType.webArchive
        default: break
        }
        if let attr = try? NSAttributedString(url: url, options: options, documentAttributes: nil) {
            return attr.string
        }
        return nil
    }
}

/// Minimal, deterministic HTML → text conversion (WebKit-based import must run on the
/// main thread, which we avoid in the background indexer).
public enum HTMLStripper {
    public static func strip(_ html: String) -> String {
        var s = html
        let patterns: [(String, String)] = [
            ("(?is)<(script|style|noscript|svg|head)[^>]*>.*?</\\1>", " "),
            ("(?i)<br\\s*/?>", "\n"),
            ("(?i)</(p|div|li|h[1-6]|tr|section|article|header|footer|blockquote|pre)>", "\n"),
            ("(?s)<!--.*?-->", " "),
            ("(?s)<[^>]+>", ""),
        ]
        for (pattern, template) in patterns {
            if let re = try? NSRegularExpression(pattern: pattern) {
                s = re.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length), withTemplate: template)
            }
        }
        let entities = ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&apos;": "'"]
        for (k, v) in entities { s = s.replacingOccurrences(of: k, with: v) }
        if let re = try? NSRegularExpression(pattern: "[ \\t]+") {
            s = re.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length), withTemplate: " ")
        }
        if let re = try? NSRegularExpression(pattern: "\\n\\s*\\n+") {
            s = re.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length), withTemplate: "\n\n")
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
