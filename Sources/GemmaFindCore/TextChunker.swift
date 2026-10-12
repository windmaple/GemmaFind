import Foundation
import NaturalLanguage

/// Splits text into overlapping, sentence-aligned chunks while keeping UTF-16 ranges
/// so the preview can scroll to and highlight the exact span.
public struct TextChunker: Sendable {
    public var targetLength: Int
    public var overlap: Int
    public var maxChunks: Int

    public init(targetLength: Int = 1000, overlap: Int = 150, maxChunks: Int = 400) {
        self.targetLength = targetLength
        self.overlap = overlap
        self.maxChunks = maxChunks
    }

    /// Returns (chunkText, range) pairs. Ranges are UTF-16 offsets into `text`.
    public func chunk(_ text: String) -> [(String, NSRange)] {
        let ns = text as NSString
        let total = ns.length
        guard total > 0 else { return [] }
        if total <= targetLength {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? [] : [(text, NSRange(location: 0, length: total))]
        }

        // Candidate break points: sentence / paragraph boundaries.
        var boundaries: [Int] = []
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            boundaries.append(NSRange(range, in: text).upperBound)
            return true
        }
        if boundaries.last != total { boundaries.append(total) }

        var chunks: [(String, NSRange)] = []
        var start = 0
        var bIndex = 0
        while start < total && chunks.count < maxChunks {
            let hardEnd = min(total, start + targetLength)
            // Choose the last sentence boundary within the window, but past its midpoint.
            var end = hardEnd
            while bIndex < boundaries.count && boundaries[bIndex] <= start { bIndex += 1 }
            var j = bIndex
            var best: Int?
            while j < boundaries.count && boundaries[j] <= hardEnd {
                if boundaries[j] - start >= targetLength / 2 { best = boundaries[j] }
                j += 1
            }
            if let best { end = best }
            else if hardEnd < total {
                // Fall back to a whitespace break.
                let window = NSRange(location: start + targetLength / 2, length: hardEnd - start - targetLength / 2)
                let ws = ns.rangeOfCharacter(from: .whitespacesAndNewlines, options: .backwards, range: window)
                if ws.location != NSNotFound { end = ws.location + 1 }
            }
            end = Self.safeBoundary(ns, end)
            let range = NSRange(location: start, length: end - start)
            let piece = ns.substring(with: range)
            if !piece.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                chunks.append((piece, range))
            }
            if end >= total { break }
            // Step forward with overlap, snapping to a word start.
            var next = max(end - overlap, start + 1)
            let snap = ns.rangeOfCharacter(from: .whitespacesAndNewlines, options: [], range: NSRange(location: next, length: end - next))
            if snap.location != NSNotFound { next = snap.location + 1 }
            start = Self.safeBoundary(ns, next)
        }
        return chunks
    }

    /// Avoid splitting a UTF-16 surrogate pair.
    static func safeBoundary(_ ns: NSString, _ index: Int) -> Int {
        guard index > 0, index < ns.length else { return index }
        let c = ns.character(at: index)
        if UTF16.isTrailSurrogate(c) { return index + 1 }
        return index
    }
}

/// Sentence ranges (UTF-16) within a string; used for fine-grained highlighting.
public enum SentenceSplitter {
    public static func sentences(in text: String, maxSentences: Int = 40) -> [NSRange] {
        var out: [NSRange] = []
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            var r = NSRange(range, in: text)
            // Trim trailing whitespace/newlines from the highlight.
            let ns = text as NSString
            while r.length > 0, let scalar = UnicodeScalar(ns.character(at: r.location + r.length - 1)),
                  CharacterSet.whitespacesAndNewlines.contains(scalar) {
                r.length -= 1
            }
            if r.length >= 3 { out.append(r) }
            return out.count < maxSentences
        }
        return out
    }
}
