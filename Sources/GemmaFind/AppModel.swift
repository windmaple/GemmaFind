import AppKit
import Combine
import GemmaFindCore
import ServiceManagement
import SwiftUI

/// Central app state: owns the index, model, indexer and search, and drives the UI.
@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    enum ModelState: Equatable {
        case notReady
        case downloading(Double)
        case loading
        case ready(String)      // backend description
        case failed(String)
    }

    // MARK: Published UI state
    @Published var query = ""
    @Published private(set) var results: [SearchResult] = []
    @Published var selectedID: Int64?
    @Published private(set) var isSearching = false
    @Published private(set) var searchElapsed: TimeInterval = 0
    @Published private(set) var lastQueryVector: [Float] = []
    @Published private(set) var modelState: ModelState = .notReady
    @Published private(set) var progress = IndexProgress()
    @Published var settings: IndexSettings {
        didSet {
            guard settings != oldValue else { return }
            saveSettings()
            applySettings(old: oldValue)
        }
    }
    @Published var launchAtLogin: Bool = (SMAppService.mainApp.status == .enabled) {
        didSet { setLaunchAtLogin(launchAtLogin) }
    }

    var selectedResult: SearchResult? { results.first { $0.id == selectedID } ?? results.first }

    // MARK: Engine
    let embedder = GemmaEmbedder(modelPath: ModelInfo.localURL.path, dimension: ModelInfo.dimension)
    let vectors = VectorIndex(dimension: ModelInfo.dimension)
    private(set) var store: IndexStore?
    private(set) var indexer: Indexer?
    private(set) var searchEngine: SearchEngine?
    private var watcher: FolderWatcher?
    private var searchTask: Task<Void, Never>?
    private var lastSearchedQuery = ""
    private var queryCancellable: AnyCancellable?

    /// Developer/test mode: `GEMMAFIND_TEST_FOLDER=/path` indexes only that folder into a
    /// separate database and never persists settings. `GEMMAFIND_DEMO_QUERY` opens the panel
    /// with that query once the model is ready.
    let testFolder = ProcessInfo.processInfo.environment["GEMMAFIND_TEST_FOLDER"]
    let demoQuery = ProcessInfo.processInfo.environment["GEMMAFIND_DEMO_QUERY"]

    private init() {
        if let folder = ProcessInfo.processInfo.environment["GEMMAFIND_TEST_FOLDER"] {
            settings = IndexSettings(folders: [URL(fileURLWithPath: folder).standardizedFileURL.path])
        } else if let data = UserDefaults.standard.data(forKey: "indexSettings"),
           let s = try? JSONDecoder().decode(IndexSettings.self, from: data) {
            settings = s
        } else {
            settings = .defaults
        }
        queryCancellable = $query
            .removeDuplicates()
            .debounce(for: .milliseconds(120), scheduler: RunLoop.main)
            .sink { [weak self] q in self?.runSearch(q) }
    }

    private var databaseURL: URL {
        testFolder == nil ? AppPaths.indexDatabase : AppPaths.cacheDirectory.appendingPathComponent("test-index.sqlite")
    }

    // MARK: Startup

    func start() {
        Task { await bootstrap() }
    }

    private func bootstrap() async {
        do {
            let store = try IndexStore(url: databaseURL, dimension: ModelInfo.dimension)
            self.store = store
            let indexer = Indexer(store: store, vectors: vectors, embedder: embedder, settings: settings)
            self.indexer = indexer
            self.searchEngine = SearchEngine(store: store, vectors: vectors, embedder: embedder)
            await indexer.setProgressHandler { p in
                Task { @MainActor in AppModel.shared.progress = p }
            }
            await indexer.loadVectors()
        } catch {
            modelState = .failed("Index database error: \(error)")
            return
        }

        // Model: download if needed, then load on GPU.
        if !ModelInfo.isDownloaded {
            modelState = .downloading(0)
            do {
                _ = try await ModelDownloader().download { p in
                    Task { @MainActor in AppModel.shared.modelState = .downloading(p) }
                }
            } catch {
                modelState = .failed("Model download failed: \(error.localizedDescription)")
                return
            }
        }
        modelState = .loading
        do {
            try await embedder.load(preferGPU: true)
            modelState = .ready(await embedder.backendDescription)
        } catch {
            modelState = .failed("Could not load EmbeddingGemma 2: \(error)")
            return
        }

        startWatcher()
        await indexer?.requestFullScan()
        if let demoQuery {
            SearchPanelController.shared.show()
            try? await Task.sleep(nanoseconds: 1_500_000_000)   // let the initial scan land
            let snapshotDir = ProcessInfo.processInfo.environment["GEMMAFIND_SNAPSHOT_DIR"]
            for (i, q) in demoQuery.components(separatedBy: "||").enumerated() {
                query = q
                runSearch(q)
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                NSLog("GemmaFind demo: \"\(q)\" → \(results.map { $0.file.name })")
                if let dir = snapshotDir {
                    SearchPanelController.shared.snapshot(to: URL(fileURLWithPath: dir).appendingPathComponent("demo-\(i + 1).png"))
                }
            }
            return
        }
        if !query.isEmpty { runSearch(query) }
    }

    private func startWatcher() {
        let w = FolderWatcher { paths in
            Task { await AppModel.shared.indexer?.noteChanged(paths: paths) }
        }
        w.start(folders: settings.folders)
        watcher = w
    }

    // MARK: Settings

    private func saveSettings() {
        guard testFolder == nil else { return }
        if let data = try? JSONEncoder().encode(settings) { UserDefaults.standard.set(data, forKey: "indexSettings") }
    }

    private func applySettings(old: IndexSettings) {
        let new = settings
        Task {
            await indexer?.update(settings: new)
            watcher?.start(folders: new.folders)
            await indexer?.requestFullScan()
        }
    }

    func addFolder(_ url: URL) {
        let path = url.standardizedFileURL.path
        guard !settings.folders.contains(path) else { return }
        settings.folders.append(path)
    }

    func removeFolder(_ path: String) {
        settings.folders.removeAll { $0 == path }
    }

    func togglePause() {
        Task {
            guard let indexer else { return }
            await indexer.setPaused(!(await indexer.isPaused))
        }
    }

    func reindexAll() {
        Task { try? await indexer?.reindexEverything() }
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("GemmaFind: launch at login change failed: \(error)")
        }
    }

    // MARK: Search

    private func runSearch(_ q: String) {
        searchTask?.cancel()
        let trimmed = q.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            results = []; selectedID = nil; isSearching = false; lastQueryVector = []
            return
        }
        guard let engine = searchEngine, case .ready = modelState else { return }
        isSearching = true
        let sameQuery = trimmed == lastSearchedQuery
        lastSearchedQuery = trimmed
        searchTask = Task {
            do {
                let response = try await engine.search(trimmed, limit: 40)
                guard !Task.isCancelled else { return }
                let keepSelection = sameQuery && response.results.contains { $0.id == self.selectedID }
                self.results = response.results
                self.lastQueryVector = response.queryVector
                self.searchElapsed = response.elapsed
                if !keepSelection { self.selectedID = response.results.first?.id }
                self.isSearching = false
            } catch {
                if !Task.isCancelled { self.isSearching = false }
            }
        }
    }

    func moveSelection(_ delta: Int) {
        guard !results.isEmpty else { return }
        let idx = results.firstIndex { $0.id == selectedID } ?? 0
        let next = max(0, min(results.count - 1, idx + delta))
        selectedID = results[next].id
    }

    // MARK: Actions

    func open(_ result: SearchResult? = nil) {
        guard let r = result ?? selectedResult else { return }
        NSWorkspace.shared.open(r.file.url)
        SearchPanelController.shared.hide()
    }

    func revealInFinder(_ result: SearchResult? = nil) {
        guard let r = result ?? selectedResult else { return }
        NSWorkspace.shared.activateFileViewerSelecting([r.file.url])
        SearchPanelController.shared.hide()
    }

    func copyPath(_ result: SearchResult? = nil) {
        guard let r = result ?? selectedResult else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(r.file.path, forType: .string)
    }

    /// Re-extracted document text for previews (same extractor used during indexing).
    nonisolated static func documentText(for file: FileRecord) -> String? {
        TextExtractor.fullText(of: file.url, kind: file.kind)
    }

    var statusLine: String {
        switch modelState {
        case .notReady: return "Starting…"
        case .downloading(let p): return String(format: "Downloading EmbeddingGemma 2… %.0f%%", p * 100)
        case .loading: return "Loading EmbeddingGemma 2…"
        case .failed(let m): return m
        case .ready:
            switch progress.phase {
            case .scanning: return "Scanning folders…"
            case .indexing: return "Indexing \(progress.filesDone)/\(progress.filesTotal)…"
            case .paused: return "Indexing paused · \(progress.indexedFiles) files"
            case .error(let m): return m
            default: return "\(progress.indexedFiles.formatted()) files · \(progress.indexedChunks.formatted()) passages indexed"
            }
        }
    }
}
