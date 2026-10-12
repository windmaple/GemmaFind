import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public enum StoreError: Error, CustomStringConvertible {
    case sqlite(String)
    public var description: String {
        switch self { case .sqlite(let m): return "SQLite: \(m)" }
    }
}

/// Persistent index: files, chunks (+ embedding BLOBs) and an FTS5 keyword index.
/// All access is serialized on an internal queue, so it is safe to use from any thread.
public final class IndexStore: @unchecked Sendable {
    public static let schemaVersion = 2

    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "gemmafind.store")
    public let dimension: Int

    public init(url: URL, dimension: Int) throws {
        self.dimension = dimension
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            throw StoreError.sqlite("cannot open \(url.path)")
        }
        try exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA foreign_keys=ON;")
        try migrate()
    }

    deinit { sqlite3_close(db) }

    private func migrate() throws {
        let version = (try? scalarInt("PRAGMA user_version")) ?? 0
        let storedDim = (try? scalarInt("SELECT value FROM meta WHERE key='dimension'")) ?? dimension
        if version != Self.schemaVersion || storedDim != dimension {
            try exec("""
            DROP TABLE IF EXISTS chunks_fts; DROP TABLE IF EXISTS chunks; DROP TABLE IF EXISTS files; DROP TABLE IF EXISTS meta;
            """)
        }
        try exec("""
        CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value);
        CREATE TABLE IF NOT EXISTS files(
            id INTEGER PRIMARY KEY, path TEXT UNIQUE NOT NULL, kind INTEGER NOT NULL,
            mtime REAL NOT NULL, size INTEGER NOT NULL, indexed_at REAL NOT NULL, failed INTEGER NOT NULL DEFAULT 0);
        CREATE TABLE IF NOT EXISTS chunks(
            id INTEGER PRIMARY KEY, file_id INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
            modality INTEGER NOT NULL, text TEXT, loc INTEGER, len INTEGER, page INTEGER, t REAL, dur REAL,
            embedding BLOB NOT NULL);
        CREATE INDEX IF NOT EXISTS chunks_file ON chunks(file_id);
        CREATE VIRTUAL TABLE IF NOT EXISTS chunks_fts USING fts5(body, name, tokenize='unicode61 remove_diacritics 2');
        """)
        try exec("PRAGMA user_version=\(Self.schemaVersion)")
        try exec("INSERT OR REPLACE INTO meta(key, value) VALUES('dimension', \(dimension))")
    }

    // MARK: - Low level helpers

    private func errmsg() -> String { String(cString: sqlite3_errmsg(db)) }

    private func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let m = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            throw StoreError.sqlite(m)
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw StoreError.sqlite("\(errmsg()) in: \(sql)")
        }
        return stmt
    }

    private func scalarInt(_ sql: String) throws -> Int {
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { throw StoreError.sqlite("no row") }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    private func bindText(_ stmt: OpaquePointer, _ idx: Int32, _ value: String?) {
        if let value { sqlite3_bind_text(stmt, idx, value, -1, SQLITE_TRANSIENT) } else { sqlite3_bind_null(stmt, idx) }
    }

    private func bindInt(_ stmt: OpaquePointer, _ idx: Int32, _ value: Int?) {
        if let value { sqlite3_bind_int64(stmt, idx, Int64(value)) } else { sqlite3_bind_null(stmt, idx) }
    }

    private func bindDouble(_ stmt: OpaquePointer, _ idx: Int32, _ value: Double?) {
        if let value { sqlite3_bind_double(stmt, idx, value) } else { sqlite3_bind_null(stmt, idx) }
    }

    private func columnText(_ stmt: OpaquePointer, _ idx: Int32) -> String? {
        guard sqlite3_column_type(stmt, idx) != SQLITE_NULL, let c = sqlite3_column_text(stmt, idx) else { return nil }
        return String(cString: c)
    }

    private func columnIntOpt(_ stmt: OpaquePointer, _ idx: Int32) -> Int? {
        sqlite3_column_type(stmt, idx) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(stmt, idx))
    }

    private func columnDoubleOpt(_ stmt: OpaquePointer, _ idx: Int32) -> Double? {
        sqlite3_column_type(stmt, idx) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, idx)
    }

    // MARK: - Files

    public struct FileStamp: Sendable { public let id: Int64; public let mtime: Double; public let size: Int64; public let failed: Bool }

    /// path → stamp for change detection.
    public func allFileStamps() -> [String: FileStamp] {
        queue.sync {
            var out: [String: FileStamp] = [:]
            guard let stmt = try? prepare("SELECT id, path, mtime, size, failed FROM files") else { return out }
            defer { sqlite3_finalize(stmt) }
            while sqlite3_step(stmt) == SQLITE_ROW {
                let path = columnText(stmt, 1) ?? ""
                out[path] = FileStamp(id: sqlite3_column_int64(stmt, 0), mtime: sqlite3_column_double(stmt, 2),
                                      size: sqlite3_column_int64(stmt, 3), failed: sqlite3_column_int(stmt, 4) != 0)
            }
            return out
        }
    }

    public func file(id: Int64) -> FileRecord? {
        queue.sync {
            guard let stmt = try? prepare("SELECT id, path, kind, mtime, size FROM files WHERE id=?") else { return nil }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, id)
            return sqlite3_step(stmt) == SQLITE_ROW ? readFile(stmt) : nil
        }
    }

    public func files(ids: [Int64]) -> [Int64: FileRecord] {
        guard !ids.isEmpty else { return [:] }
        return queue.sync {
            var out: [Int64: FileRecord] = [:]
            let list = ids.map(String.init).joined(separator: ",")
            guard let stmt = try? prepare("SELECT id, path, kind, mtime, size FROM files WHERE id IN (\(list))") else { return out }
            defer { sqlite3_finalize(stmt) }
            while sqlite3_step(stmt) == SQLITE_ROW { let f = readFile(stmt); out[f.id] = f }
            return out
        }
    }

    private func readFile(_ stmt: OpaquePointer) -> FileRecord {
        FileRecord(id: sqlite3_column_int64(stmt, 0), path: columnText(stmt, 1) ?? "",
                   kind: FileKind(rawValue: Int(sqlite3_column_int(stmt, 2))) ?? .text,
                   modified: sqlite3_column_double(stmt, 3), size: sqlite3_column_int64(stmt, 4))
    }

    /// A chunk ready to be written.
    public struct NewChunk: Sendable {
        public var modality: ChunkModality
        public var text: String?
        public var range: NSRange?
        public var page: Int?
        public var time: Double?
        public var duration: Double?
        public var embedding: [Float]
        public init(modality: ChunkModality, text: String? = nil, range: NSRange? = nil, page: Int? = nil,
                    time: Double? = nil, duration: Double? = nil, embedding: [Float]) {
            self.modality = modality; self.text = text; self.range = range; self.page = page
            self.time = time; self.duration = duration; self.embedding = embedding
        }
    }

    /// Replaces a file and all of its chunks atomically. Returns the file id and the
    /// ids assigned to `chunks` (same order) plus the ids of chunks that were removed.
    @discardableResult
    public func replaceFile(path: String, kind: FileKind, mtime: Double, size: Int64, failed: Bool = false,
                            chunks: [NewChunk]) throws -> (fileID: Int64, chunkIDs: [Int64], removedChunkIDs: [Int64]) {
        try queue.sync {
            try exec("BEGIN IMMEDIATE")
            do {
                let removed = try deleteFileLocked(path: path)
                let ins = try prepare("INSERT INTO files(path, kind, mtime, size, indexed_at, failed) VALUES(?,?,?,?,?,?)")
                defer { sqlite3_finalize(ins) }
                bindText(ins, 1, path); sqlite3_bind_int(ins, 2, Int32(kind.rawValue))
                sqlite3_bind_double(ins, 3, mtime); sqlite3_bind_int64(ins, 4, size)
                sqlite3_bind_double(ins, 5, Date().timeIntervalSince1970); sqlite3_bind_int(ins, 6, failed ? 1 : 0)
                guard sqlite3_step(ins) == SQLITE_DONE else { throw StoreError.sqlite(errmsg()) }
                let fileID = sqlite3_last_insert_rowid(db)

                let cstmt = try prepare("INSERT INTO chunks(file_id, modality, text, loc, len, page, t, dur, embedding) VALUES(?,?,?,?,?,?,?,?,?)")
                defer { sqlite3_finalize(cstmt) }
                let fstmt = try prepare("INSERT INTO chunks_fts(rowid, body, name) VALUES(?,?,?)")
                defer { sqlite3_finalize(fstmt) }
                let name = Self.searchableName(path)
                var ids: [Int64] = []
                ids.reserveCapacity(chunks.count)
                for c in chunks {
                    sqlite3_reset(cstmt); sqlite3_clear_bindings(cstmt)
                    sqlite3_bind_int64(cstmt, 1, fileID)
                    sqlite3_bind_int(cstmt, 2, Int32(c.modality.rawValue))
                    bindText(cstmt, 3, c.text)
                    bindInt(cstmt, 4, c.range?.location); bindInt(cstmt, 5, c.range?.length)
                    bindInt(cstmt, 6, c.page); bindDouble(cstmt, 7, c.time); bindDouble(cstmt, 8, c.duration)
                    c.embedding.withUnsafeBytes { raw in
                        _ = sqlite3_bind_blob(cstmt, 9, raw.baseAddress, Int32(raw.count), SQLITE_TRANSIENT)
                    }
                    guard sqlite3_step(cstmt) == SQLITE_DONE else { throw StoreError.sqlite(errmsg()) }
                    let cid = sqlite3_last_insert_rowid(db)
                    ids.append(cid)

                    sqlite3_reset(fstmt); sqlite3_clear_bindings(fstmt)
                    sqlite3_bind_int64(fstmt, 1, cid)
                    bindText(fstmt, 2, c.text ?? "")
                    bindText(fstmt, 3, name)
                    guard sqlite3_step(fstmt) == SQLITE_DONE else { throw StoreError.sqlite(errmsg()) }
                }
                try exec("COMMIT")
                return (fileID, ids, removed)
            } catch {
                try? exec("ROLLBACK")
                throw error
            }
        }
    }

    /// Removes a file. Returns the chunk ids that were deleted.
    @discardableResult
    public func deleteFile(path: String) -> [Int64] {
        queue.sync {
            (try? exec("BEGIN IMMEDIATE")) ?? ()
            let removed = (try? deleteFileLocked(path: path)) ?? []
            (try? exec("COMMIT")) ?? ()
            return removed
        }
    }

    /// Removes every file under `prefix` (a folder that is no longer indexed).
    public func deleteFiles(underFolder prefix: String) -> [Int64] {
        let paths: [String] = queue.sync {
            var out: [String] = []
            guard let stmt = try? prepare("SELECT path FROM files WHERE path LIKE ? ESCAPE '\\'") else { return out }
            defer { sqlite3_finalize(stmt) }
            let escaped = prefix.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
            bindText(stmt, 1, escaped.hasSuffix("/") ? escaped + "%" : escaped + "/%")
            while sqlite3_step(stmt) == SQLITE_ROW { if let p = columnText(stmt, 0) { out.append(p) } }
            return out
        }
        return paths.flatMap { deleteFile(path: $0) }
    }

    private func deleteFileLocked(path: String) throws -> [Int64] {
        let sel = try prepare("SELECT c.id FROM chunks c JOIN files f ON f.id=c.file_id WHERE f.path=?")
        defer { sqlite3_finalize(sel) }
        bindText(sel, 1, path)
        var ids: [Int64] = []
        while sqlite3_step(sel) == SQLITE_ROW { ids.append(sqlite3_column_int64(sel, 0)) }
        if !ids.isEmpty {
            let list = ids.map(String.init).joined(separator: ",")
            try exec("DELETE FROM chunks_fts WHERE rowid IN (\(list))")
        }
        let del = try prepare("DELETE FROM files WHERE path=?")
        defer { sqlite3_finalize(del) }
        bindText(del, 1, path)
        guard sqlite3_step(del) == SQLITE_DONE else { throw StoreError.sqlite(errmsg()) }
        return ids
    }

    public func wipe() throws {
        try queue.sync { try exec("DELETE FROM chunks_fts; DELETE FROM chunks; DELETE FROM files;") }
    }

    // MARK: - Chunks

    public func chunks(ids: [Int64]) -> [Int64: ChunkRecord] {
        guard !ids.isEmpty else { return [:] }
        return queue.sync {
            var out: [Int64: ChunkRecord] = [:]
            let list = ids.map(String.init).joined(separator: ",")
            guard let stmt = try? prepare("SELECT id, file_id, modality, text, loc, len, page, t, dur FROM chunks WHERE id IN (\(list))") else { return out }
            defer { sqlite3_finalize(stmt) }
            while sqlite3_step(stmt) == SQLITE_ROW { let c = readChunk(stmt); out[c.id] = c }
            return out
        }
    }

    private func readChunk(_ stmt: OpaquePointer) -> ChunkRecord {
        let loc = columnIntOpt(stmt, 4), len = columnIntOpt(stmt, 5)
        return ChunkRecord(id: sqlite3_column_int64(stmt, 0), fileID: sqlite3_column_int64(stmt, 1),
                           modality: ChunkModality(rawValue: Int(sqlite3_column_int(stmt, 2))) ?? .text,
                           text: columnText(stmt, 3),
                           range: (loc != nil && len != nil) ? NSRange(location: loc!, length: len!) : nil,
                           page: columnIntOpt(stmt, 6), time: columnDoubleOpt(stmt, 7), duration: columnDoubleOpt(stmt, 8))
    }

    /// Streams every (chunkID, fileID, modality, embedding) for building the in-memory index.
    public func forEachEmbedding(_ body: (Int64, Int64, ChunkModality, UnsafeBufferPointer<Float>) -> Void) {
        queue.sync {
            guard let stmt = try? prepare("SELECT id, file_id, modality, embedding FROM chunks") else { return }
            defer { sqlite3_finalize(stmt) }
            while sqlite3_step(stmt) == SQLITE_ROW {
                let bytes = Int(sqlite3_column_bytes(stmt, 3))
                guard bytes == dimension * MemoryLayout<Float>.size, let blob = sqlite3_column_blob(stmt, 3) else { continue }
                let buf = UnsafeBufferPointer(start: blob.assumingMemoryBound(to: Float.self), count: dimension)
                body(sqlite3_column_int64(stmt, 0), sqlite3_column_int64(stmt, 1),
                     ChunkModality(rawValue: Int(sqlite3_column_int(stmt, 2))) ?? .text, buf)
            }
        }
    }

    public struct Counts: Sendable { public let files: Int; public let chunks: Int }
    public func counts() -> Counts {
        queue.sync {
            Counts(files: (try? scalarInt("SELECT COUNT(*) FROM files WHERE failed=0")) ?? 0,
                   chunks: (try? scalarInt("SELECT COUNT(*) FROM chunks")) ?? 0)
        }
    }

    // MARK: - Keyword search

    /// FTS5 search over chunk text and file names. Returns (chunkID, bm25) best first.
    public func keywordSearch(_ query: String, limit: Int = 100) -> [(Int64, Double)] {
        let terms = QueryTerms.terms(in: query)
        guard !terms.isEmpty else { return [] }
        // Prefix match each term; require all terms (implicit AND).
        let match = terms.map { "\"\($0.replacingOccurrences(of: "\"", with: ""))\"*" }.joined(separator: " ")
        return queue.sync {
            var out: [(Int64, Double)] = []
            // Weight file-name hits above body hits.
            guard let stmt = try? prepare("SELECT rowid, bm25(chunks_fts, 1.0, 4.0) AS r FROM chunks_fts WHERE chunks_fts MATCH ? ORDER BY r LIMIT ?") else { return out }
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, match)
            sqlite3_bind_int(stmt, 2, Int32(limit))
            while sqlite3_step(stmt) == SQLITE_ROW {
                out.append((sqlite3_column_int64(stmt, 0), sqlite3_column_double(stmt, 1)))
            }
            return out
        }
    }

    /// "My_Trip-Notes.final.md" → "My Trip Notes final md My_Trip-Notes.final.md"
    static func searchableName(_ path: String) -> String {
        let name = (path as NSString).lastPathComponent
        let spaced = name.replacingOccurrences(of: "[_\\-.]+", with: " ", options: .regularExpression)
        // Split camelCase too.
        let camel = spaced.replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression)
        return camel + " " + name
    }
}
