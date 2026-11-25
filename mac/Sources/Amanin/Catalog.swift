import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Remembers what is already on each destination (path, size, date and content hash),
/// so "copy only what's missing" works without re-reading whole drives every time.
final class Catalog: @unchecked Sendable {
    struct Entry {
        let rel: String
        let size: Int64
        let mtime: Double
        let hash: String?
    }

    private var db: OpaquePointer?
    private let lock = NSRecursiveLock()

    static var defaultURL: URL {
        appSupportDir().appendingPathComponent("catalog.sqlite")
    }

    init(url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) != SQLITE_OK {
            db = nil
        }
        exec("PRAGMA journal_mode=WAL;")
        exec("PRAGMA synchronous=NORMAL;")
        exec("""
        CREATE TABLE IF NOT EXISTS dest_files(
          root TEXT NOT NULL, rel TEXT NOT NULL, size INTEGER NOT NULL, mtime REAL NOT NULL, hash TEXT,
          PRIMARY KEY(root, rel)) WITHOUT ROWID;
        """)
        exec("CREATE INDEX IF NOT EXISTS dest_by_size ON dest_files(root, size);")
    }

    deinit { sqlite3_close(db) }

    @discardableResult
    private func exec(_ sql: String) -> Bool {
        sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK
    }

    private func prepare(_ sql: String) -> OpaquePointer? {
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        return stmt
    }

    private func bind(_ stmt: OpaquePointer?, _ i: Int32, _ s: String) {
        sqlite3_bind_text(stmt, i, s, -1, SQLITE_TRANSIENT)
    }

    private func entry(_ stmt: OpaquePointer?) -> Entry {
        let rel = String(cString: sqlite3_column_text(stmt, 0))
        let size = sqlite3_column_int64(stmt, 1)
        let mtime = sqlite3_column_double(stmt, 2)
        let hash = sqlite3_column_type(stmt, 3) == SQLITE_NULL ? nil : String(cString: sqlite3_column_text(stmt, 3))
        return Entry(rel: rel, size: size, mtime: mtime, hash: hash)
    }

    func allEntries(root: String) -> [String: Entry] {
        lock.lock(); defer { lock.unlock() }
        let stmt = prepare("SELECT rel, size, mtime, hash FROM dest_files WHERE root = ?;")
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, root)
        var out: [String: Entry] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            let e = entry(stmt)
            out[e.rel] = e
        }
        return out
    }

    func candidates(root: String, size: Int64) -> [Entry] {
        lock.lock(); defer { lock.unlock() }
        let stmt = prepare("SELECT rel, size, mtime, hash FROM dest_files WHERE root = ? AND size = ?;")
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, root)
        sqlite3_bind_int64(stmt, 2, size)
        var out: [Entry] = []
        while sqlite3_step(stmt) == SQLITE_ROW { out.append(entry(stmt)) }
        return out
    }

    func setHash(root: String, rel: String, hash: String) {
        lock.lock(); defer { lock.unlock() }
        let stmt = prepare("UPDATE dest_files SET hash = ? WHERE root = ? AND rel = ?;")
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, hash); bind(stmt, 2, root); bind(stmt, 3, rel)
        sqlite3_step(stmt)
    }

    func upsert(root: String, entry e: Entry) {
        lock.lock(); defer { lock.unlock() }
        let stmt = prepare("INSERT OR REPLACE INTO dest_files(root, rel, size, mtime, hash) VALUES(?,?,?,?,?);")
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, root); bind(stmt, 2, e.rel)
        sqlite3_bind_int64(stmt, 3, e.size)
        sqlite3_bind_double(stmt, 4, e.mtime)
        if let h = e.hash { bind(stmt, 5, h) } else { sqlite3_bind_null(stmt, 5) }
        sqlite3_step(stmt)
    }

    /// Walks the destination folder and brings the catalog up to date.
    /// Files whose size or date changed lose their stored hash.
    func refresh(root: String, cancel: CancelFlag?, progress: (Int) -> Void) throws {
        let existing = allEntries(root: root)
        let rootURL = URL(fileURLWithPath: root)
        let rootPath = rootURL.standardizedFileURL.path
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let en = FileManager.default.enumerator(at: rootURL, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else {
            throw AppError.notConnected(root)
        }
        var seen = Set<String>()
        var changed: [Entry] = []
        var count = 0
        for case let u as URL in en {
            if cancel?.isCancelled == true { throw AppError.cancelled }
            guard let rv = try? u.resourceValues(forKeys: Set(keys)), rv.isRegularFile == true else { continue }
            let rel = relPath(u, root: rootPath)
            let size = Int64(rv.fileSize ?? 0)
            let mt = rv.contentModificationDate?.timeIntervalSince1970 ?? 0
            seen.insert(rel)
            if let e = existing[rel], e.size == size, abs(e.mtime - mt) < 0.001 {
                // unchanged
            } else {
                changed.append(Entry(rel: rel, size: size, mtime: mt, hash: nil))
            }
            count += 1
            if count % 500 == 0 { progress(count) }
        }
        progress(count)

        lock.lock(); defer { lock.unlock() }
        exec("BEGIN;")
        for e in changed { upsert(root: root, entry: e) }
        let del = prepare("DELETE FROM dest_files WHERE root = ? AND rel = ?;")
        for rel in existing.keys where !seen.contains(rel) {
            sqlite3_reset(del)
            bind(del, 1, root); bind(del, 2, rel)
            sqlite3_step(del)
        }
        sqlite3_finalize(del)
        exec("COMMIT;")
    }
}
