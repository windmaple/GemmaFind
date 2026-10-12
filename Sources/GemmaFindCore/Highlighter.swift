import Foundation

/// Computes highlight ranges for the preview pane.
public enum Highlighter {
    /// Literal (case/diacritic-insensitive) occurrences of query terms at word starts.
    /// Terms of 5+ letters also match common inflections (prefix match).
    public static func termRanges(in text: String, query: String, limit: Int = 500) -> [NSRange] {
        let ns = text as NSString
        var out: [NSRange] = []
        for term in QueryTerms.terms(in: query) {
            let needle = term.count >= 5 ? String(term.prefix(max(4, term.count - 2))) : term
            var searchRange = NSRange(location: 0, length: ns.length)
            while out.count < limit {
                let r = ns.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive], range: searchRange)
                if r.location == NSNotFound { break }
                // Must start at a word boundary.
                let atWordStart = r.location == 0 || !isWordChar(ns.character(at: r.location - 1))
                if atWordStart {
                    // Extend to the end of the word for prefix matches.
                    var end = r.location + r.length
                    if needle.count < term.count || term.count >= 5 {
                        while end < ns.length, isWordChar(ns.character(at: end)), end - r.location < term.count + 4 { end += 1 }
                    }
                    let candidate = NSRange(location: r.location, length: end - r.location)
                    // For short terms require an exact word match.
                    if term.count >= 5 || end >= ns.length || !isWordChar(ns.character(at: end)) {
                        out.append(candidate)
                    }
                }
                searchRange = NSRange(location: r.location + r.length, length: ns.length - r.location - r.length)
            }
        }
        return out.sorted { $0.location < $1.location }
    }

    static func isWordChar(_ c: unichar) -> Bool {
        guard let scalar = UnicodeScalar(c) else { return false }
        return CharacterSet.alphanumerics.contains(scalar)
    }

    public struct SentenceMatch: Sendable, Equatable {
        /// Range relative to the full document text (or page text for PDFs).
        public let range: NSRange
        public let similarity: Float
    }

    /// Embeds each sentence of the matched chunk and returns the ones closest to the query,
    /// so the preview can emphasize *why* this chunk matched.
    public static func bestSentences(chunkText: String, chunkRange: NSRange, title: String?, queryVector: [Float],
                                     embedder: any Embedder, maxResults: Int = 2) async -> [SentenceMatch] {
        let sentences = SentenceSplitter.sentences(in: chunkText)
        guard sentences.count > 1, !queryVector.isEmpty else {
            return [SentenceMatch(range: chunkRange, similarity: 0)]
        }
        let ns = chunkText as NSString
        let inputs = sentences.map { EmbeddingInput.document(title: title, text: ns.substring(with: $0)) }
        guard let vecs = try? await embedder.embedDocuments(inputs) else { return [] }
        let scored = zip(sentences, vecs).map { (r, v) -> SentenceMatch in
            let sim = zip(queryVector, v).reduce(Float(0)) { $0 + $1.0 * $1.1 }
            return SentenceMatch(range: NSRange(location: chunkRange.location + r.location, length: r.length), similarity: sim)
        }.sorted { $0.similarity > $1.similarity }
        guard let top = scored.first else { return [] }
        // Keep the best sentence plus any close runner-up.
        return Array(scored.prefix(maxResults).filter { $0.similarity >= top.similarity - 0.03 })
    }
}

public extension Double {
    /// 75.4 → "1:15"
    var timestampString: String {
        let s = Int(self.rounded(.down))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}
