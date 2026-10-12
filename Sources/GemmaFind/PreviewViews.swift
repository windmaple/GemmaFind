import AppKit
import AVKit
import GemmaFindCore
import PDFKit
import SwiftUI

/// Right-hand preview for the selected result, with highlights explaining the match.
struct PreviewPane: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        if let r = model.selectedResult {
            VStack(spacing: 0) {
                PreviewHeader(result: r)
                Divider().opacity(0.4)
                Group {
                    switch r.file.kind {
                    case .text, .richText: TextPreview(result: r, query: model.query, queryVector: model.lastQueryVector)
                    case .pdf: PDFPreview(result: r, query: model.query, queryVector: model.lastQueryVector)
                    case .image: ImagePreview(result: r)
                    case .video, .audio: MediaPreview(result: r)
                    }
                }
                .id(r.id)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            Color.clear
        }
    }
}

struct PreviewHeader: View {
    let result: SearchResult
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: result.file.path)).resizable().frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(result.file.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(meta).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Button { model.open(result) } label: { Image(systemName: "arrow.up.forward.app") }
                .help("Open (↩)")
            Button { model.revealInFinder(result) } label: { Image(systemName: "folder") }
                .help("Reveal in Finder (⌘↩)")
            Button { SearchPanelController.shared.toggleQuickLook() } label: { Image(systemName: "eye") }
                .help("Quick Look (⌘Y)")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    var meta: String {
        let size = ByteCountFormatter.string(fromByteCount: result.file.size, countStyle: .file)
        let date = Date(timeIntervalSince1970: result.file.modified).formatted(date: .abbreviated, time: .shortened)
        return "\(result.file.kind.displayName) · \(size) · \(date)"
    }
}

// MARK: - Text

/// Loads the document text, highlights the matched passage, its best sentences
/// (re-embedded on the fly) and literal query terms, then scrolls to the match.
struct TextPreview: View {
    let result: SearchResult
    let query: String
    let queryVector: [Float]
    @EnvironmentObject var model: AppModel
    @State private var content: HighlightedText?

    var body: some View {
        ZStack {
            if let content {
                HighlightTextView(content: content)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .task(id: "\(result.chunk.id)|\(query)") { await load() }
    }

    private func load() async {
        let file = result.file
        let chunk = result.chunk
        let q = query
        guard let full = await Task.detached(priority: .userInitiated, operation: { AppModel.documentText(for: file) }).value else {
            content = HighlightedText(text: chunk.text ?? "", isCode: false, passage: nil, sentences: [], terms: [])
            return
        }
        // Window very large documents around the match.
        let ns = full as NSString
        let chunkRange = chunk.range ?? NSRange(location: 0, length: 0)
        var window = NSRange(location: 0, length: ns.length)
        if ns.length > 300_000 {
            let start = max(0, chunkRange.location - 100_000)
            window = NSRange(location: start, length: min(ns.length - start, 200_000))
        }
        let text = window.length == ns.length ? full : ns.substring(with: window)
        func shift(_ r: NSRange) -> NSRange? {
            let s = NSRange(location: r.location - window.location, length: r.length)
            return s.location >= 0 && NSMaxRange(s) <= (text as NSString).length ? s : nil
        }
        let isCode = FileTypes.textExtensions.contains(file.url.pathExtension.lowercased())
            && !["md", "markdown", "txt", "text", "rst", "org", "log"].contains(file.url.pathExtension.lowercased())
        let terms = Highlighter.termRanges(in: text, query: q)
        let passage = chunk.range.flatMap(shift)
        content = HighlightedText(text: text, isCode: isCode, passage: passage, sentences: [], terms: terms)

        // Fine-grained: which sentences in the passage best match the query?
        guard let chunkText = chunk.text, let cr = chunk.range, !queryVector.isEmpty else { return }
        let matches = await Highlighter.bestSentences(chunkText: chunkText, chunkRange: cr, title: file.name,
                                                      queryVector: queryVector, embedder: model.embedder)
        guard !Task.isCancelled else { return }
        let sentences = matches.compactMap { shift($0.range) }
        content = HighlightedText(text: text, isCode: isCode, passage: passage, sentences: sentences, terms: terms)
    }
}

struct HighlightedText: Equatable {
    let text: String
    let isCode: Bool
    let passage: NSRange?
    let sentences: [NSRange]
    let terms: [NSRange]
}

struct HighlightTextView: NSViewRepresentable {
    let content: HighlightedText

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        if let tv = scroll.documentView as? NSTextView {
            tv.isEditable = false
            tv.isSelectable = true
            tv.drawsBackground = false
            tv.textContainerInset = NSSize(width: 14, height: 12)
            tv.isAutomaticLinkDetectionEnabled = false
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? NSTextView, context.coordinator.last != content else { return }
        let firstLoad = context.coordinator.last?.text != content.text
        context.coordinator.last = content
        let attr = Self.attributed(content)
        tv.textStorage?.setAttributedString(attr)
        // Scroll the strongest highlight into the middle of the view.
        if let target = content.sentences.first ?? content.passage ?? content.terms.first {
            DispatchQueue.main.async {
                tv.layoutManager?.ensureLayout(for: tv.textContainer!)
                guard let lm = tv.layoutManager, let tc = tv.textContainer else { return }
                let glyphs = lm.glyphRange(forCharacterRange: target, actualCharacterRange: nil)
                var rect = lm.boundingRect(forGlyphRange: glyphs, in: tc)
                rect.origin.y += tv.textContainerInset.height
                let visible = scroll.contentView.bounds.height
                let y = max(0, rect.midY - visible / 2)
                if firstLoad {
                    scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
                } else {
                    NSAnimationContext.runAnimationGroup { ctx in
                        ctx.duration = 0.2
                        scroll.contentView.animator().setBoundsOrigin(NSPoint(x: 0, y: y))
                    }
                }
                scroll.reflectScrolledClipView(scroll.contentView)
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var last: HighlightedText? }

    static func attributed(_ c: HighlightedText) -> NSAttributedString {
        let font: NSFont = c.isCode ? .monospacedSystemFont(ofSize: 12, weight: .regular) : .systemFont(ofSize: 13.5)
        let para = NSMutableParagraphStyle()
        para.lineSpacing = c.isCode ? 2 : 4
        let s = NSMutableAttributedString(string: c.text, attributes: [
            .font: font, .foregroundColor: NSColor.labelColor.withAlphaComponent(0.78), .paragraphStyle: para,
        ])
        let len = s.length
        func valid(_ r: NSRange) -> Bool { r.location >= 0 && NSMaxRange(r) <= len }
        if let p = c.passage, valid(p) {
            s.addAttributes([.backgroundColor: NSColor.controlAccentColor.withAlphaComponent(0.10),
                             .foregroundColor: NSColor.labelColor], range: p)
        }
        for r in c.sentences where valid(r) {
            s.addAttributes([.backgroundColor: NSColor.systemYellow.withAlphaComponent(0.42),
                             .foregroundColor: NSColor.labelColor], range: r)
        }
        let bold = c.isCode ? NSFont.monospacedSystemFont(ofSize: 12, weight: .bold) : NSFont.systemFont(ofSize: 13.5, weight: .bold)
        for r in c.terms where valid(r) {
            s.addAttributes([.font: bold, .underlineStyle: NSUnderlineStyle.thick.rawValue,
                             .underlineColor: NSColor.systemOrange, .foregroundColor: NSColor.labelColor], range: r)
        }
        return s
    }
}

// MARK: - PDF

struct PDFPreview: View {
    let result: SearchResult
    let query: String
    let queryVector: [Float]
    @EnvironmentObject var model: AppModel
    @State private var sentences: [NSRange] = []

    var body: some View {
        PDFKitView(url: result.file.url, page: result.chunk.page ?? 0, passage: result.chunk.range,
                   sentences: sentences, query: query)
            .task(id: "\(result.chunk.id)|\(query)") {
                sentences = []
                guard let text = result.chunk.text, let cr = result.chunk.range, !queryVector.isEmpty else { return }
                let m = await Highlighter.bestSentences(chunkText: text, chunkRange: cr, title: result.file.name,
                                                        queryVector: queryVector, embedder: model.embedder)
                if !Task.isCancelled { sentences = m.map(\.range) }
            }
    }
}

struct PDFKitView: NSViewRepresentable {
    let url: URL
    let page: Int
    let passage: NSRange?
    let sentences: [NSRange]
    let query: String

    func makeNSView(context: Context) -> PDFView {
        let v = PDFView()
        v.autoScales = true
        v.displayMode = .singlePageContinuous
        v.backgroundColor = .clear
        return v
    }

    func updateNSView(_ v: PDFView, context: Context) {
        if v.document?.documentURL != url { v.document = PDFDocument(url: url) }
        guard let doc = v.document, let pdfPage = doc.page(at: min(page, max(doc.pageCount - 1, 0))) else { return }
        let pageLen = (pdfPage.string ?? "") as NSString
        func sel(_ r: NSRange, _ color: NSColor) -> PDFSelection? {
            guard r.location >= 0, NSMaxRange(r) <= pageLen.length, let s = pdfPage.selection(for: r) else { return nil }
            s.color = color
            return s
        }
        var highlights: [PDFSelection] = []
        if let p = passage, let s = sel(p, NSColor.controlAccentColor.withAlphaComponent(0.18)) { highlights.append(s) }
        let sentenceSels = sentences.compactMap { sel($0, NSColor.systemYellow.withAlphaComponent(0.55)) }
        highlights += sentenceSels
        for r in Highlighter.termRanges(in: pageLen as String, query: query, limit: 60) {
            if let s = sel(r, NSColor.systemOrange.withAlphaComponent(0.5)) { highlights.append(s) }
        }
        v.highlightedSelections = highlights
        if ProcessInfo.processInfo.environment["GEMMAFIND_TEST_FOLDER"] != nil {
            NSLog("GemmaFind PDF preview: pages=\(doc.pageCount) page=\(page) highlights=\(highlights.count) sentences=\(sentenceSels.map { $0.string ?? "" })")
        }
        let key = "\(url.path)|\(page)|\(sentences.count)"
        if context.coordinator.lastKey != key {
            context.coordinator.lastKey = key
            DispatchQueue.main.async {
                if let target = sentenceSels.first ?? highlights.first {
                    v.go(to: target)
                } else {
                    v.go(to: pdfPage)
                }
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var lastKey = "" }
}

// MARK: - Image

struct ImagePreview: View {
    let result: SearchResult
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .shadow(radius: 6, y: 2)
                    .padding(18)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .task(id: result.file.path) {
            let path = result.file.path
            image = await Task.detached(priority: .userInitiated) {
                MediaProcessor.downsampledJPEG(url: URL(fileURLWithPath: path), maxPixel: 1800).flatMap(NSImage.init(data:))
            }.value
        }
    }
}

// MARK: - Video / audio

struct MediaPreview: View {
    let result: SearchResult
    @State private var player: AVPlayer?

    var matches: [ChunkRecord] {
        ([result.chunk] + result.extraChunks).filter { $0.time != nil }
    }

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                if result.file.kind == .audio {
                    RoundedRectangle(cornerRadius: 12).fill(.quaternary)
                    Image(systemName: "waveform").font(.system(size: 64, weight: .ultraLight)).foregroundStyle(.secondary)
                }
                if let player {
                    PlayerView(player: player, audioOnly: result.file.kind == .audio)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
            }
            .frame(maxHeight: result.file.kind == .audio ? 160 : .infinity)
            .padding(.horizontal, 14)
            .padding(.top, 12)

            VStack(alignment: .leading, spacing: 6) {
                Text("Matching moments").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                FlowChips(items: matches) { c in
                    Button { seek(to: c.time ?? 0, play: true) } label: {
                        Label(label(for: c), systemImage: c.modality == .audio ? "waveform" : "film")
                            .font(.system(size: 11.5, weight: c.id == result.chunk.id ? .semibold : .regular))
                            .padding(.horizontal, 9).padding(.vertical, 4)
                            .background(Capsule().fill(c.id == result.chunk.id ? Color.yellow.opacity(0.45) : Color.secondary.opacity(0.15)))
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.bottom, 12)
            if result.file.kind == .audio { Spacer() }
        }
        .onAppear {
            let p = AVPlayer(url: result.file.url)
            player = p
            seek(to: result.chunk.time ?? 0, play: false)
        }
        .onDisappear { player?.pause() }
        .onReceive(NotificationCenter.default.publisher(for: .gemmaFindPanelHidden)) { _ in player?.pause() }
    }

    func label(for c: ChunkRecord) -> String {
        let t = (c.time ?? 0).timestampString
        if c.modality == .audio, let d = c.duration { return "\(t)–\(((c.time ?? 0) + d).timestampString) sound" }
        return "\(t) scene"
    }

    func seek(to t: Double, play: Bool) {
        player?.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        if play { player?.play() }
    }
}

struct PlayerView: NSViewRepresentable {
    let player: AVPlayer
    let audioOnly: Bool
    func makeNSView(context: Context) -> AVPlayerView {
        let v = AVPlayerView()
        v.player = player
        v.controlsStyle = audioOnly ? .inline : .floating
        v.showsFullScreenToggleButton = !audioOnly
        return v
    }
    func updateNSView(_ v: AVPlayerView, context: Context) {
        if v.player !== player { v.player = player }
    }
}

/// Simple wrapping row of chips.
struct FlowChips<Item: Identifiable, Content: View>: View {
    let items: [Item]
    let content: (Item) -> Content
    init(items: [Item], @ViewBuilder content: @escaping (Item) -> Content) {
        self.items = items
        self.content = content
    }
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) { ForEach(items) { content($0) } }
        }
    }
}

extension ChunkRecord: Identifiable {}
