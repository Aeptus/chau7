import SQLite3
import XCTest
@testable import Chau7

/// Exercises `TelemetrySchemaMigrator` against a throwaway temp database so it
/// never touches the shared store's real file (`swift test` does not isolate
/// the home, so `TelemetryStore.shared` points at the user's real runs.db).
final class TelemetrySchemaMigratorTests: XCTestCase {
    private var dbPath = ""
    private var db: OpaquePointer?

    override func setUpWithError() throws {
        try super.setUpWithError()
        dbPath = NSTemporaryDirectory() + "chau7-schema-migrator-\(UUID().uuidString).db"
        XCTAssertEqual(sqlite3_open(dbPath, &db), SQLITE_OK)
        sqlite3_exec(db, "PRAGMA foreign_keys=ON", nil, nil, nil)
    }

    override func tearDownWithError() throws {
        if let db { sqlite3_close(db) }
        db = nil
        try? FileManager.default.removeItem(atPath: dbPath)
        try super.tearDownWithError()
    }

    func testFreshDatabaseReachesCurrentSchemaVersion() {
        let migrator = TelemetrySchemaMigrator(db: db)
        migrator.createTables()
        migrator.applyMigrations()

        XCTAssertEqual(migrator.schemaVersion(), TelemetrySchemaMigrator.currentSchemaVersion)
        // The ladder must record every intermediate version, not jump straight
        // to the target — downgrade detection and idempotence both rely on it.
        XCTAssertEqual(recordedSchemaVersions(), Array(1 ... TelemetrySchemaMigrator.currentSchemaVersion))
        // v4 columns + the shared ingest_seq trigger infrastructure must exist.
        for table in ["runs", "usage_evidence", "remote_client_events"] {
            XCTAssertEqual(columnCount(table: table, column: "ingest_seq"), 1, "\(table).ingest_seq missing")
            XCTAssertTrue(schemaObjectExists(type: "trigger", name: "trg_\(table)_ingest_seq"))
            XCTAssertTrue(schemaObjectExists(type: "index", name: "idx_\(table)_ingest_seq"))
        }
    }

    func testRunningMigrationsTwiceIsANoOp() {
        let migrator = TelemetrySchemaMigrator(db: db)
        migrator.createTables()
        migrator.applyMigrations()
        let versionAfterFirstPass = migrator.schemaVersion()
        let schemaAfterFirstPass = schemaDump()

        migrator.createTables()
        migrator.applyMigrations()

        XCTAssertEqual(migrator.schemaVersion(), versionAfterFirstPass)
        XCTAssertEqual(recordedSchemaVersions(), Array(1 ... TelemetrySchemaMigrator.currentSchemaVersion))
        XCTAssertEqual(schemaDump(), schemaAfterFirstPass, "second pass must not alter any table/index/trigger")
    }

    func testEnsureColumnAddsMissingColumnAndSkipsExistingOne() {
        XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE sample (a TEXT)", nil, nil, nil), SQLITE_OK)
        let migrator = TelemetrySchemaMigrator(db: db)

        migrator.ensureColumn(table: "sample", name: "b", definition: "INTEGER")
        XCTAssertEqual(columnCount(table: "sample", column: "b"), 1, "missing column should be added")

        // Second call must recognize the existing column and do nothing
        // (a blind ALTER TABLE ADD COLUMN would fail with a duplicate error).
        migrator.ensureColumn(table: "sample", name: "b", definition: "INTEGER")
        XCTAssertEqual(columnCount(table: "sample", column: "b"), 1, "existing column must not be duplicated")
        XCTAssertEqual(columnCount(table: "sample", column: "a"), 1)
    }

    // MARK: - Helpers

    private func recordedSchemaVersions() -> [Int] {
        var versions: [Int] = []
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT version FROM schema_version ORDER BY version", -1, &stmt, nil) == SQLITE_OK else {
            return versions
        }
        while sqlite3_step(stmt) == SQLITE_ROW {
            versions.append(Int(sqlite3_column_int(stmt, 0)))
        }
        return versions
    }

    private func columnCount(table: String, column: String) -> Int {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(\(table))", -1, &stmt, nil) == SQLITE_OK else { return -1 }
        var count = 0
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let name = sqlite3_column_text(stmt, 1), String(cString: name) == column {
                count += 1
            }
        }
        return count
    }

    private func schemaObjectExists(type: String, name: String) -> Bool {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = "SELECT COUNT(*) FROM sqlite_master WHERE type = ? AND name = ?"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        sqlite3_bind_text(stmt, 1, type, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_text(stmt, 2, name, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(stmt) == SQLITE_ROW else { return false }
        return sqlite3_column_int(stmt, 0) > 0
    }

    /// Full DDL dump — tables, indexes, and triggers — used to prove a second
    /// migration pass changes nothing.
    private func schemaDump() -> [String] {
        var rows: [String] = []
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = "SELECT type || '|' || name || '|' || COALESCE(sql, '') FROM sqlite_master ORDER BY type, name"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return rows }
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let text = sqlite3_column_text(stmt, 0) {
                rows.append(String(cString: text))
            }
        }
        return rows
    }
}
