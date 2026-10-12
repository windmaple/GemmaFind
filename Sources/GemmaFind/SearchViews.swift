import AppKit
import GemmaFindCore
import SwiftUI

/// Root of the search panel: query field on top, results list + preview below.
struct SearchRootView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            SearchFieldBar()
            Divider().opacity(0.5)
            if model.query.trimmingCharacters(in: .whitespaces).isEmpty {
                HomeView()
            } else if model.results.isEmpty {
                EmptyResultsView()
            } else {
                HSplitView {
                    ResultsList()
                        .frame(minWidth: 280, idealWidth: 330, maxWidth: 420)
                    PreviewPane()
                        .frame(minWidth: 320, maxWidth: .infinity)
                }
            }
            Divider().opacity(0.5)
            FooterBar()
        }
        .frame(minWidth: 640, minHeight: 380)
    }
}

// MARK: - Search field

struct SearchFieldBar: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "sparkle.magnifyingglass")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(LinearGradient(colors: [.blue, .purple], startPoint: .topLeading, endPoint: .bottomTrailing))
            FocusedTextField(text: $model.query, placeholder: "Search anything — files, photos, videos, voice memos…")
                .frame(height: 30)
            if model.isSearching {
                ProgressView().controlSize(.small)
            } else if !model.query.isEmpty {
                Button { model.query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }
}

/// NSTextField wrapper that grabs focus whenever the panel is shown.
struct FocusedTextField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String

    func makeNSView(context: Context) -> NSTextField {
        let tf = NSTextField()
        tf.isBordered = false
        tf.drawsBackground = false
        tf.focusRingType = .none
        tf.font = .systemFont(ofSize: 22, weight: .regular)
        tf.placeholderString = placeholder
        tf.delegate = context.coordinator
        tf.cell?.isScrollable = true
        tf.cell?.wraps = false
        context.coordinator.field = tf
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.focus),
                                               name: .gemmaFindFocusSearch, object: nil)
        DispatchQueue.main.async { context.coordinator.focus() }
        return tf
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        if nsView.stringValue != text { nsView.stringValue = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>
        weak var field: NSTextField?
        init(text: Binding<String>) { self.text = text }

        @objc func focus() {
            guard let field, let window = field.window else { return }
            window.makeFirstResponder(field)
            field.currentEditor()?.selectAll(nil)
        }

        func controlTextDidChange(_ obj: Notification) {
            if let f = obj.object as? NSTextField { text.wrappedValue = f.stringValue }
        }
    }
}

// MARK: - Results

struct ResultsList: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(model.results) { r in
                        ResultRow(result: r, selected: r.id == (model.selectedResult?.id))
                            .id(r.id)
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) { model.open(r) }
                            .onTapGesture { model.selectedID = r.id }
                            .contextMenu {
                                Button("Open") { model.open(r) }
                                Button("Reveal in Finder") { model.revealInFinder(r) }
                                Button("Copy Path") { model.copyPath(r) }
                            }
                    }
                }
                .padding(8)
            }
            .onChange(of: model.selectedID) { _, id in
                if let id { withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(id) } }
            }
        }
    }
}

struct ResultRow: View {
    let result: SearchResult
    let selected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            FileThumbnail(file: result.file, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(result.file.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    if result.keywordMatch {
                        Image(systemName: "textformat.abc").font(.system(size: 9)).opacity(0.7)
                            .help("Contains your exact words")
                    }
                }
                Text(snippet).font(.system(size: 11.5)).opacity(0.75).lineLimit(2)
                Text(folderDisplay).font(.system(size: 10)).opacity(0.5).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 4)
            RelevanceBadge(similarity: result.similarity, score: result.score)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 9).fill(selected ? Color.accentColor.opacity(0.85) : .clear))
        .foregroundStyle(selected ? Color.white : Color.primary)
    }

    var snippet: String {
        let c = result.chunk
        switch c.modality {
        case .text:
            let t = (c.text ?? "").replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            if let p = c.page { return "p.\(p + 1) · " + t }
            return t
        case .image: return "Image match"
        case .videoFrame: return "Scene at \((c.time ?? 0).timestampString)" + extraTimes
        case .audio: return "Sound at \((c.time ?? 0).timestampString)" + extraTimes
        }
    }

    var extraTimes: String {
        let more = result.extraChunks.compactMap { $0.time }.prefix(3).map { $0.timestampString }
        return more.isEmpty ? "" : " · also " + more.joined(separator: ", ")
    }

    var folderDisplay: String {
        let dir = (result.file.path as NSString).deletingLastPathComponent
        return (dir as NSString).abbreviatingWithTildeInPath
    }
}

struct RelevanceBadge: View {
    let similarity: Float
    let score: Double

    var body: some View {
        // Map calibrated score (~1.5…7) to 1–5 dots.
        let dots = max(1, min(5, Int((score - 1.0) / 1.2) + 1))
        HStack(spacing: 2) {
            ForEach(0..<5, id: \.self) { i in
                Circle().frame(width: 4, height: 4).opacity(i < dots ? 0.9 : 0.2)
            }
        }
        .padding(.top, 4)
        .help(String(format: "Similarity %.3f · score %.2f", similarity, score))
    }
}

/// File icon, or a real thumbnail for images.
struct FileThumbnail: View {
    let file: FileRecord
    let size: CGFloat
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                    .frame(width: size, height: size).clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                Image(nsImage: NSWorkspace.shared.icon(forFile: file.path)).resizable().frame(width: size, height: size)
            }
        }
        .frame(width: size, height: size)
        .task(id: file.path) {
            guard file.kind == .image || file.kind == .video else { image = nil; return }
            let path = file.path, kind = file.kind
            image = await Task.detached(priority: .utility) { () -> NSImage? in
                if kind == .image {
                    guard let data = MediaProcessor.downsampledJPEG(url: URL(fileURLWithPath: path), maxPixel: 96) else { return nil }
                    return NSImage(data: data)
                }
                guard let cg = await MediaProcessor.videoThumbnail(url: URL(fileURLWithPath: path), at: 1, maxPixel: 96) else { return nil }
                return NSImage(cgImage: cg, size: .zero)
            }.value
        }
    }
}

// MARK: - Home / empty / footer

struct HomeView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "sparkle.magnifyingglass").font(.system(size: 44, weight: .light))
                .foregroundStyle(LinearGradient(colors: [.blue, .purple, .pink], startPoint: .topLeading, endPoint: .bottomTrailing))
            Text("Search by meaning, not just words").font(.title3.weight(.semibold))
            Text("Try “receipts from the Tokyo trip”, “dog on the beach”, or “the meeting where we discussed the budget”.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 460)
            ModelStatusView().padding(.top, 6)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

struct ModelStatusView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        switch model.modelState {
        case .downloading(let p):
            VStack(spacing: 6) {
                ProgressView(value: p).frame(width: 260)
                Text(String(format: "Downloading EmbeddingGemma 2 (485 MB)… %.0f%%", p * 100)).font(.caption).foregroundStyle(.secondary)
            }
        case .loading, .notReady:
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Loading EmbeddingGemma 2…").font(.caption) }
        case .failed(let m):
            Label(m, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
        case .ready:
            if case .indexing = model.progress.phase {
                VStack(spacing: 6) {
                    ProgressView(value: Double(model.progress.filesDone), total: Double(max(model.progress.filesTotal, 1))).frame(width: 260)
                    Text(model.statusLine).font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text(model.statusLine).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct EmptyResultsView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(spacing: 10) {
            Spacer()
            if case .ready = model.modelState {
                Image(systemName: "questionmark.folder").font(.system(size: 34, weight: .light)).foregroundStyle(.secondary)
                Text(model.isSearching ? "Searching…" : "No matches yet").font(.headline)
                if case .indexing = model.progress.phase {
                    Text("Still indexing — results will improve as more files are processed.").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                ModelStatusView()
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct FooterBar: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        HStack(spacing: 14) {
            Text(model.statusLine).lineLimit(1)
            if case .ready(let backend) = model.modelState {
                Text("EmbeddingGemma 2 · \(backend)").foregroundStyle(.tertiary)
            }
            Spacer()
            if !model.results.isEmpty {
                Text(String(format: "%d result%@ · %.0f ms", model.results.count, model.results.count == 1 ? "" : "s", model.searchElapsed * 1000)).foregroundStyle(.tertiary)
            }
            Group {
                Text("↩ Open"); Text("⌘↩ Reveal"); Text("⌘Y Quick Look")
            }.foregroundStyle(.tertiary)
        }
        .font(.system(size: 10.5))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
    }
}
