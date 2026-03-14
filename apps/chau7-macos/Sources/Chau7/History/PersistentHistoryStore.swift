import Foundation
import SQLite3
import Chau7Core

/// Persistent storage for command history using SQLite.
/// Uses the C SQLite3 API directly (no external dependencies).
/// Database location: ~/Library/Application Support/Chau7/history.db
///
/// Schema:
/// ```sql
/// CREATE TABLE IF NOT EXISTS history (
///     id INTEGER PRIMARY KEY AUTOINCREMENT,
///     command TEXT NOT NULL,
///     directory TEXT,
///     exit_code INTEGER,
///     shell TEXT,
///     tab_id TEXT,
///     session_id TEXT,
///     timestamp REAL NOT NULL,
///     duration REAL
/// );
/// CREATE INDEX IF NOT EXISTS idx_history_timestamp ON history(timestamp DESC);
/// CREATE INDEX IF NOT EXISTS idx_history_command ON history(command);
/// CREATE INDEX IF NOT EXISTS idx_history_directory ON history(directory);
/// ```
final class PersistentHistoryStore {
    static let shared = PersistentHistoryStore()

    private var db: OpaquePointer?
    private let dbQueue = DispatchQueue(label: "com.chau7.historyDB", qos: .utility)

    /// Session ID for this app launch
    let sessionID: String = UUID().uuidString

    /// Maximum number of records to keep
    var maxRecords = 50000

    private init() {
        openDatabase()
        createTables()
        Log.info("PersistentHistoryStore initialized: \(dbPath)")
    }

    /// Testable initializer that opens an arbitrary database path.
    /// Pass `":memory:"` for a fast, throwaway in-memory database.
    init(path: String) {
        if sqlite3_open(path, &db) != SQLITE_OK {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            Log.error("PersistentHistoryStore: failed to open database at \(path): \(msg)")
            self.db = nil
        }
        execute("PRAGMA journal_mode=WAL")
        execute("PRAGMA synchronous=NORMAL")
        createTables()
    }

    deinit {
        if let db = db {
            sqlite3_close(db)
        }
    }

    // MARK: - Database Setup

    private var dbPath: String {
        let dir = RuntimeIsolation.appSupportDirectory(named: "Chau7")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            Log.error("PersistentHistoryStore: failed to create dir: \(error)")
        }
        return dir.appendingPathComponent("history.db").path
    }

    private func openDatabase() {
        // Use FULLMUTEX mode so the connection is safe for concurrent access
        // from both dbQueue (inserts) and caller threads (reads).
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        if sqlite3_open_v2(dbPath, &db, flags, nil) != SQLITE_OK {
            Log.error("PersistentHistoryStore: failed to open database: \(String(cString: sqlite3_errmsg(db!)))")
            db = nil
            // Attempt recovery: rename corrupt DB and retry with fresh file
            let corruptPath = dbPath + ".corrupt.\(Int(Date().timeIntervalSince1970))"
            try? FileManager.default.moveItem(atPath: dbPath, toPath: corruptPath)
            Log.warn("PersistentHistoryStore: renamed corrupt DB to \(corruptPath), retrying")
            if sqlite3_open_v2(dbPath, &db, flags, nil) != SQLITE_OK {
                Log.error("PersistentHistoryStore: retry also failed")
                db = nil
            }
        }
        execute("PRAGMA journal_mode=WAL")
        execute("PRAGMA synchronous=NORMAL")
    }

    private func createTables() {
        execute("""
            CREATE TABLE IF NOT EXISTS history (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                command TEXT NOT NULL,
                directory TEXT,
                exit_code INTEGER,
                shell TEXT,
                tab_id TEXT,
                session_id TEXT,
                timestamp REAL NOT NULL,
                duration REAL
            )
        """)
        execute("CREATE INDEX IF NOT EXISTS idx_history_timestamp ON history(timestamp DESC)")
        execute("CREATE INDEX IF NOT EXISTS idx_history_command ON history(command)")
        execute("CREATE INDEX IF NOT EXISTS idx_history_directory ON history(directory)")
    }

    // MARK: - Insert

    func insert(_ record: HistoryRecord) {
        dbQueue.async { [weak self] in
            guard let self = self, let db = db else { return }
            let sql = """
                INSERT INTO history (command, directory, exit_code, shell, tab_id, session_id, timestamp, duration)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                Log.error("PersistentHistoryStore: prepare insert failed")
                return
            }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_text(stmt, 1, (record.command as NSString).utf8String, -1, nil)
            bindOptionalText(stmt, 2, record.directory)
            bindOptionalInt(stmt, 3, record.exitCode)
            bindOptionalText(stmt, 4, record.shell)
            bindOptionalText(stmt, 5, record.tabID)
            bindOptionalText(stmt, 6, record.sessionID ?? sessionID)
            sqlite3_bind_double(stmt, 7, record.timestamp.timeIntervalSince1970)
            if let d = record.duration {
                sqlite3_bind_double(stmt, 8, d)
            } else {
                sqlite3_bind_null(stmt, 8)
            }

            if sqlite3_step(stmt) != SQLITE_DONE {
                Log.error("PersistentHistoryStore: insert failed: \(String(cString: sqlite3_errmsg(db)))")
            } else {
                Log.trace("PersistentHistoryStore: inserted '\(record.command)'")
            }

            trimIfNeeded()
        }
    }

    /// Synchronous insert used by tests and import operations.
    func insertSync(_ record: HistoryRecord) {
        guard let db = db else { return }
        let sql = """
            INSERT INTO history (command, directory, exit_code, shell, tab_id, session_id, timestamp, duration)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            Log.error("PersistentHistoryStore: prepare insert failed")
            return
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, (record.command as NSString).utf8String, -1, nil)
        bindOptionalText(stmt, 2, record.directory)
        bindOptionalInt(stmt, 3, record.exitCode)
        bindOptionalText(stmt, 4, record.shell)
        bindOptionalText(stmt, 5, record.tabID)
        bindOptionalText(stmt, 6, record.sessionID ?? sessionID)
        sqlite3_bind_double(stmt, 7, record.timestamp.timeIntervalSince1970)
        if let d = record.duration {
            sqlite3_bind_double(stmt, 8, d)
        } else {
            sqlite3_bind_null(stmt, 8)
        }

        if sqlite3_step(stmt) != SQLITE_DONE {
            Log.error("PersistentHistoryStore: insert failed: \(String(cString: sqlite3_errmsg(db)))")
        }

        trimIfNeeded()
    }

    // MARK: - Query

    func search(query: String, limit: Int = 50) -> [HistoryRecord] {
        var results: [HistoryRecord] = []
        guard let db = db else { return results }

        let sql = """
            SELECT id, command, directory, exit_code, shell, tab_id, session_id, timestamp, duration
            FROM history WHERE command LIKE ? ORDER BY timestamp DESC LIMIT ?
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return results }
        defer { sqlite3_finalize(stmt) }

        let pattern = "%\(query)%"
        sqlite3_bind_text(stmt, 1, (pattern as NSString).utf8String, -1, nil)
        sqlite3_bind_int(stmt, 2, Int32(limit))

        while sqlite3_step(stmt) == SQLITE_ROW {
            results.append(readRecord(stmt))
        }

        return results
    }

    func recent(limit: Int = 100) -> [HistoryRecord] {
        var results: [HistoryRecord] = []
        guard let db = db else { return results }

        let sql = """
            SELECT id, command, directory, exit_code, shell, tab_id, session_id, timestamp, duration
            FROM history ORDER BY timestamp DESC LIMIT ?
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return results }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int(stmt, 1, Int32(limit))

        while sqlite3_step(stmt) == SQLITE_ROW {
            results.append(readRecord(stmt))
        }

        return results
    }

    func recentForDirectory(_ directory: String, limit: Int = 50) -> [HistoryRecord] {
        var results: [HistoryRecord] = []
        guard let db = db else { return results }

        let sql = """
            SELECT id, command, directory, exit_code, shell, tab_id, session_id, timestamp, duration
            FROM history WHERE directory = ? ORDER BY timestamp DESC LIMIT ?
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return results }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, (directory as NSString).utf8String, -1, nil)
        sqlite3_bind_int(stmt, 2, Int32(limit))

        while sqlite3_step(stmt) == SQLITE_ROW {
            results.append(readRecord(stmt))
        }

        return results
    }

    func frequentCommands(limit: Int = 20) -> [FrequentCommand] {
        var results: [FrequentCommand] = []
        guard let db = db else { return results }

        let sql = """
            SELECT command, COUNT(*) as cnt, MAX(timestamp) as last_ts
            FROM history GROUP BY command ORDER BY cnt DESC LIMIT ?
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return results }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int(stmt, 1, Int32(limit))

        while sqlite3_step(stmt) == SQLITE_ROW {
            let command = String(cString: sqlite3_column_text(stmt, 0))
            let count = Int(sqlite3_column_int(stmt, 1))
            let ts = sqlite3_column_double(stmt, 2)
            results.append(FrequentCommand(command: command, count: count, lastUsed: Date(timeIntervalSince1970: ts)))
        }

        return results
    }

    func totalCount() -> Int {
        guard let db = db else { return 0 }
        let sql = "SELECT COUNT(*) FROM history"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }

        if sqlite3_step(stmt) == SQLITE_ROW {
            return Int(sqlite3_column_int(stmt, 0))
        }
        return 0
    }

    /// Returns the database file size in bytes, or 0 if unavailable.
    func databaseSizeBytes() -> UInt64 {
        let path: String
        if db != nil {
            if let cPath = sqlite3_db_filename(db, "main") {
                path = String(cString: cPath)
            } else {
                path = dbPath
            }
        } else {
            path = dbPath
        }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attrs[.size] as? UInt64 else {
            return 0
        }
        return size
    }

    // MARK: - Export / Import

    /// Exports all history records as JSON data.
    func exportJSON() -> Data? {
        let records = recent(limit: maxRecords)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            return try encoder.encode(records)
        } catch {
            Log.error("PersistentHistoryStore: export JSON encode failed: \(error)")
            return nil
        }
    }

    /// Imports history records from JSON data, appending to existing history.
    /// Returns the number of records imported.
    @discardableResult
    func importJSON(_ data: Data) -> Int {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let records: [HistoryRecord]
        do {
            records = try decoder.decode([HistoryRecord].self, from: data)
        } catch {
            Log.error("PersistentHistoryStore: failed to decode import JSON: \(error)")
            return 0
        }
        var count = 0
        for record in records {
            insertSync(record)
            count += 1
        }
        Log.info("PersistentHistoryStore: imported \(count) records")
        return count
    }

    // MARK: - Maintenance

    func clearAll() {
        execute("DELETE FROM history")
        execute("VACUUM")
        Log.info("PersistentHistoryStore: cleared all history")
    }

    func clearOlderThan(days: Int) {
        guard let db = db else { return }
        let cutoff = Date().addingTimeInterval(-Double(days * 86400)).timeIntervalSince1970
        let sql = "DELETE FROM history WHERE timestamp < ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, cutoff)
        if sqlite3_step(stmt) != SQLITE_DONE {
            Log.error("PersistentHistoryStore: clearOlderThan failed: \(String(cString: sqlite3_errmsg(db)))")
        }
        Log.info("PersistentHistoryStore: cleared history older than \(days) days")
    }

    private func trimIfNeeded() {
        guard let db = db else { return }
        let count = totalCount()
        if count > maxRecords {
            let excess = count - maxRecords
            let sql = "DELETE FROM history WHERE id IN (SELECT id FROM history ORDER BY timestamp ASC LIMIT ?)"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int(stmt, 1, Int32(excess))
            if sqlite3_step(stmt) != SQLITE_DONE {
                Log.error("PersistentHistoryStore: trim failed: \(String(cString: sqlite3_errmsg(db)))")
            }
            Log.info("PersistentHistoryStore: trimmed \(excess) oldest records")
        }
    }

    // MARK: - Helpers

    private func execute(_ sql: String) {
        guard let db = db else { return }
        var errMsg: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &errMsg) != SQLITE_OK {
            let err = errMsg.map { String(cString: $0) } ?? "unknown"
            Log.error("PersistentHistoryStore SQL error: \(err)")
            sqlite3_free(errMsg)
        }
    }

    private func readRecord(_ stmt: OpaquePointer?) -> HistoryRecord {
        let id = sqlite3_column_int64(stmt, 0)
        let command = String(cString: sqlite3_column_text(stmt, 1))
        let directory = sqlite3_column_type(stmt, 2) != SQLITE_NULL ? String(cString: sqlite3_column_text(stmt, 2)) : nil
        let exitCode = sqlite3_column_type(stmt, 3) != SQLITE_NULL ? Int(sqlite3_column_int(stmt, 3)) : nil
        let shell = sqlite3_column_type(stmt, 4) != SQLITE_NULL ? String(cString: sqlite3_column_text(stmt, 4)) : nil
        let tabID = sqlite3_column_type(stmt, 5) != SQLITE_NULL ? String(cString: sqlite3_column_text(stmt, 5)) : nil
        let sessionID = sqlite3_column_type(stmt, 6) != SQLITE_NULL ? String(cString: sqlite3_column_text(stmt, 6)) : nil
        let timestamp = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 7))
        let duration = sqlite3_column_type(stmt, 8) != SQLITE_NULL ? sqlite3_column_double(stmt, 8) : nil

        return HistoryRecord(
            id: id, command: command, directory: directory, exitCode: exitCode,
            shell: shell, tabID: tabID, sessionID: sessionID,
            timestamp: timestamp, duration: duration
        )
    }

    private func bindOptionalText(_ stmt: OpaquePointer?, _ index: Int32, _ value: String?) {
        if let v = value {
            sqlite3_bind_text(stmt, index, (v as NSString).utf8String, -1, nil)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    private func bindOptionalInt(_ stmt: OpaquePointer?, _ index: Int32, _ value: Int?) {
        if let v = value {
            sqlite3_bind_int(stmt, index, Int32(v))
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }
}
