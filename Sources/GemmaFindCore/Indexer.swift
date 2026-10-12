import Foundation

/// User-configurable indexing scope.
public struct IndexSettings: Codable, Equatable, Sendable {
    public var folders: [String]
    public var enabledKinds: Set<FileKind>
    /// fnmatch-style patterns matched against the full path, e.g. "*/Archive/*".
    public var excludedPatterns: [String]

    public init(folders: [String], enabledKinds: Set<FileKind> = Set(FileKind.allCases), excludedPatterns: [String] = []) {
        self.folders = folders
        self.enabledKinds = enabledKinds
        self.excludedPatterns = excludedPatterns
    }

    public static var defaults: IndexSettings {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return IndexSettings(folders: ["Documents", "Desktop", "Downloads"].map { "\(home)/\($0)" })
    }

    public func isExcluded(_ path: String) -> Bool {
        excludedPatterns.contains { fnmatch($0, path, 0) == 0 }
    }
}

/// Crawls folders, extracts content, embeds it and keeps the store + vector index in sync.
public actor Indexer {
    public typealias ProgressHandler = @Sendable (IndexProgress) -> Void

    let store: IndexStore
    let vectors: VectorIndex
    let embedder: any Embedder
    let chunker = TextChunker()
    let mediaLimits = MediaProcessor.Limits()
    var settings: IndexSettings
    var progress = IndexProgress()
    var onProgress: ProgressHandler?
    var paused = false
    var running = false
    var pendingPaths: Set<String> = []
    var rescanRequested = false

    public init(store: IndexStore, vectors: VectorIndex, embedder: any Embedder, settings: IndexSettings) {
        self.store = store
        self.vectors = vectors
        self.embedder = embedder
        self.settings = settings
    }

    public func setProgressHandler(_ handler: ProgressHandler?) { onProgress = handler }

    public func update(settings new: IndexSettings) {
        let removedFolders = Set(settings.folders).subtracting(new.folders)
        settings = new
        for folder in removedFolders {
            vectors.remove(chunkIDs: store.deleteFiles(underFolder: folder))
        }
        refreshCounts()
    }

    public func setPaused(_ value: Bool) {
        paused = value
        if !value, !running { Task { await self.runLoop() } }
        publish()
    }

    public var isPaused: Bool { paused }

    /// Loads every stored embedding into the in-memory vector index.
    public func loadVectors() {
        vectors.removeAll()
        store.forEachEmbedding { cid, fid, modality, vec in
            vectors.add(chunkID: cid, fileID: fid, modality: modality, vector: vec)
        }
        refreshCounts()
    }

    /// Full reconciliation of all folders (new, changed and deleted files).
    public func requestFullScan() {
        rescanRequested = true
        if !running { Task { await self.runLoop() } }
    }

    /// Incremental update for changed paths reported by FSEvents.
    public func noteChanged(paths: [String]) {
        pendingPaths.formUnion(paths)
        if !running { Task { await self.runLoop() } }
    }

    public func reindexEverything() throws {
        try store.wipe()
        vectors.removeAll()
        refreshCounts()
        requestFullScan()
    }

    // MARK: - Work loop

    private func runLoop() async {
        guard !running else { return }
        running = true
        defer { running = false }
        while !paused {
            if rescanRequested {
                rescanRequested = false
                pendingPaths.removeAll()
                await fullScan()
            } else if !pendingPaths.isEmpty {
                let paths = pendingPaths
                pendingPaths.removeAll()
                await incremental(paths: paths)
            } else {
                break
            }
        }
        progress.phase = paused ? .paused : .idle
        progress.currentFile = nil
        publish()
    }

    struct Candidate { let path: String; let kind: FileKind; let mtime: Double; let size: Int64 }

    private func fullScan() async {
        progress.phase = .scanning
        progress.filesDone = 0
        progress.filesTotal = 0
        publish()

        var found: [String: Candidate] = [:]
        for folder in settings.folders {
            for c in enumerate(folder: folder) { found[c.path] = c }
        }
        let stamps = store.allFileStamps()

        // Deleted (or now-excluded) files.
        for (path, _) in stamps where found[path] == nil {
            vectors.remove(chunkIDs: store.deleteFile(path: path))
        }
        // New / changed files; cheap kinds first so text results show up quickly.
        let todo = found.values.filter { c in
            guard let s = stamps[c.path] else { return true }
            return abs(s.mtime - c.mtime) > 0.5 || s.size != c.size
        }.sorted { order($0.kind) == order($1.kind) ? $0.mtime > $1.mtime : order($0.kind) < order($1.kind) }

        await process(todo)
    }

    private func incremental(paths: Set<String>) async {
        var todo: [Candidate] = []
        let stamps = store.allFileStamps()
        for path in paths {
            var isDir: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
            guard settings.folders.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) else { continue }
            if !exists {
                // File or folder removed.
                vectors.remove(chunkIDs: store.deleteFile(path: path))
                vectors.remove(chunkIDs: store.deleteFiles(underFolder: path))
                continue
            }
            if isDir.boolValue {
                for c in enumerate(folder: path) {
                    if let s = stamps[c.path], abs(s.mtime - c.mtime) <= 0.5, s.size == c.size { continue }
                    todo.append(c)
                }
            } else if let c = candidate(for: URL(fileURLWithPath: path)) {
                if let s = stamps[c.path], abs(s.mtime - c.mtime) <= 0.5, s.size == c.size { continue }
                todo.append(c)
            } else if stamps[path] != nil {
                vectors.remove(chunkIDs: store.deleteFile(path: path))
            }
        }
        await process(todo)
    }

    private func process(_ todo: [Candidate]) async {
        progress.phase = todo.isEmpty ? .idle : .indexing
        progress.filesTotal = todo.count
        progress.filesDone = 0
        publish()
        for c in todo {
            if paused || rescanRequested { break }
            progress.currentFile = c.path
            publish()
            await index(c)
            progress.filesDone += 1
            if progress.filesDone % 10 == 0 { refreshCounts() }
            publish()
        }
        refreshCounts()
    }

    private func order(_ kind: FileKind) -> Int {
        switch kind {
        case .text, .richText: return 0
        case .pdf: return 1
        case .image: return 2
        case .audio: return 3
        case .video: return 4
        }
    }

    // MARK: - Enumeration

    private func enumerate(folder: String) -> [Candidate] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .contentModificationDateKey, .fileSizeKey, .isPackageKey]
        guard let e = FileManager.default.enumerator(at: URL(fileURLWithPath: folder), includingPropertiesForKeys: keys,
                                                     options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var out: [Candidate] = []
        for case let url as URL in e {
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isDirectory == true {
                let name = url.lastPathComponent
                if FileTypes.skippedDirectoryNames.contains(name)
                    || FileTypes.packageExtensions.contains(url.pathExtension.lowercased())
                    || values?.isPackage == true
                    || settings.isExcluded(url.path) {
                    e.skipDescendants()
                }
                continue
            }
            if let c = candidate(for: url, values: values) { out.append(c) }
        }
        return out
    }

    private func candidate(for url: URL, values: URLResourceValues? = nil) -> Candidate? {
        let v = values ?? (try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]))
        guard v?.isRegularFile == true, let kind = FileTypes.kind(for: url), settings.enabledKinds.contains(kind) else { return nil }
        let path = url.standardizedFileURL.path
        if settings.isExcluded(path) || url.lastPathComponent.hasPrefix(".") { return nil }
        let size = Int64(v?.fileSize ?? 0)
        guard size > 0, size <= FileTypes.maxSize(for: kind) else { return nil }
        return Candidate(path: path, kind: kind, mtime: v?.contentModificationDate?.timeIntervalSince1970 ?? 0, size: size)
    }

    // MARK: - Per-file indexing

    private func index(_ c: Candidate) async {
        let url = URL(fileURLWithPath: c.path)
        let title = url.lastPathComponent
        do {
            let pieces = await extract(url: url, kind: c.kind)
            var chunks: [IndexStore.NewChunk] = []
            // Embed in modest batches so search queries can interleave.
            let batchSize = 12
            var i = 0
            while i < pieces.count {
                let slice = Array(pieces[i..<min(i + batchSize, pieces.count)])
                let inputs: [EmbeddingInput] = slice.map { p in
                    switch p {
                    case .text(let s, _, _): return .document(title: title, text: s)
                    case .image(let d, _): return .image(d)
                    case .audio(let d, _, _): return .audio(d)
                    }
                }
                let vecs = try await embedder.embedDocuments(inputs)
                for (p, v) in zip(slice, vecs) {
                    switch p {
                    case .text(let s, let range, let page):
                        chunks.append(.init(modality: .text, text: s, range: range, page: page, embedding: v))
                    case .image(_, let time):
                        chunks.append(.init(modality: time == nil ? .image : .videoFrame, time: time, embedding: v))
                    case .audio(_, let time, let dur):
                        chunks.append(.init(modality: .audio, time: time, duration: dur, embedding: v))
                    }
                }
                i += batchSize
                if paused { return }
            }
            let result = try store.replaceFile(path: c.path, kind: c.kind, mtime: c.mtime, size: c.size,
                                               failed: chunks.isEmpty, chunks: chunks)
            vectors.remove(chunkIDs: result.removedChunkIDs)
            for (cid, chunk) in zip(result.chunkIDs, chunks) {
                vectors.add(chunkID: cid, fileID: result.fileID, modality: chunk.modality, vector: chunk.embedding)
            }
        } catch {
            NSLog("GemmaFind: failed to index \(c.path): \(error)")
            _ = try? store.replaceFile(path: c.path, kind: c.kind, mtime: c.mtime, size: c.size, failed: true, chunks: [])
        }
    }

    func extract(url: URL, kind: FileKind) async -> [ExtractedPiece] {
        switch kind {
        case .text, .richText:
            guard let text = TextExtractor.fullText(of: url, kind: kind) else { return [] }
            return chunker.chunk(text).map { .text($0.0, range: $0.1, page: nil) }
        case .pdf:
            var out: [ExtractedPiece] = []
            for (i, page) in TextExtractor.pdfPages(of: url).enumerated() {
                for (s, r) in chunker.chunk(page) { out.append(.text(s, range: r, page: i)) }
                if out.count >= chunker.maxChunks { break }
            }
            return out
        case .image:
            guard let jpeg = MediaProcessor.downsampledJPEG(url: url, maxPixel: mediaLimits.imageMaxPixel) else { return [] }
            return [.image(jpeg, time: nil)]
        case .video:
            var out: [ExtractedPiece] = await MediaProcessor.videoFrames(url: url, limits: mediaLimits).map { .image($0.0, time: $0.1) }
            out += await MediaProcessor.audioSegments(url: url, limits: mediaLimits).map { .audio($0.0, time: $0.1, duration: $0.2) }
            return out
        case .audio:
            return await MediaProcessor.audioSegments(url: url, limits: mediaLimits).map { .audio($0.0, time: $0.1, duration: $0.2) }
        }
    }

    // MARK: - Progress

    private func refreshCounts() {
        let c = store.counts()
        progress.indexedFiles = c.files
        progress.indexedChunks = c.chunks
        publish()
    }

    private func publish() {
        if paused, progress.phase != .paused, !running { progress.phase = .paused }
        onProgress?(progress)
    }
}
