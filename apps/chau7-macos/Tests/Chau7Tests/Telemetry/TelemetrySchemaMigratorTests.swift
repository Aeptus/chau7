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
        // The shared ingest_seq trigger infrastructure must cover latency
        // samples as well as the original three v4 tables.
        let sequencedTables = ["runs", "usage_evidence", "remote_client_events", "provider_latency_samples"]
        for table in sequencedTables {
            XCTAssertEqual(columnCount(table: table, column: "ingest_seq"), 1, "\(table).ingest_seq missing")
            XCTAssertTrue(schemaObjectExists(type: "trigger", name: "trg_\(table)_ingest_seq"))
            XCTAssertTrue(schemaObjectExists(type: "index", name: "idx_\(table)_ingest_seq"))
            let triggerSQL = schemaSQL(type: "trigger", name: "trg_\(table)_ingest_seq")
            for sourceTable in sequencedTables {
                XCTAssertTrue(
                    triggerSQL.contains("FROM \(sourceTable)"),
                    "\(table) trigger must include \(sourceTable) in its shared counter"
                )
            }
        }
    }

    func testVersion4FixtureMigratesToVersion5AndReplacesLegacyTriggers() {
        let migrator = TelemetrySchemaMigrator(db: db)
        migrator.createTables()
        migrator.ensureColumn(table: "runs", name: "transcript_repair_attempted_at", definition: "TEXT")
        for table in ["runs", "usage_evidence", "remote_client_events"] {
            migrator.ensureColumn(table: table, name: "ingest_seq", definition: "INTEGER")
        }
        installVersion4IngestSequenceInfrastructure()
        for version in 2 ... 4 {
            XCTAssertEqual(
                sqlite3_exec(db, "INSERT INTO schema_version (version) VALUES (\(version))", nil, nil, nil),
                SQLITE_OK
            )
        }

        XCTAssertEqual(migrator.schemaVersion(), 4)
        XCTAssertEqual(columnCount(table: "provider_latency_samples", column: "ingest_seq"), 0)
        XCTAssertFalse(
            schemaSQL(type: "trigger", name: "trg_runs_ingest_seq").contains("FROM provider_latency_samples")
        )

        migrator.applyMigrations()

        XCTAssertEqual(migrator.schemaVersion(), 5)
        XCTAssertEqual(recordedSchemaVersions(), [1, 2, 3, 4, 5])
        XCTAssertEqual(columnCount(table: "provider_latency_samples", column: "ingest_seq"), 1)
        XCTAssertTrue(schemaObjectExists(type: "index", name: "idx_provider_latency_samples_ingest_seq"))
        for table in ["runs", "usage_evidence", "remote_client_events", "provider_latency_samples"] {
            XCTAssertTrue(
                schemaSQL(type: "trigger", name: "trg_\(table)_ingest_seq")
                    .contains("FROM provider_latency_samples"),
                "v5 must replace the embedded v4 trigger SQL for \(table)"
            )
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

    private func schemaSQL(type: String, name: String) -> String {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = "SELECT sql FROM sqlite_master WHERE type = ? AND name = ?"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return "" }
        sqlite3_bind_text(stmt, 1, type, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_text(stmt, 2, name, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(stmt) == SQLITE_ROW,
              let text = sqlite3_column_text(stmt, 0) else {
            return ""
        }
        return String(cString: text)
    }

    /// Reproduces the v4 DDL exactly: three sequenced tables whose trigger
    /// bodies know nothing about provider_latency_samples.
    private func installVersion4IngestSequenceInfrastructure() {
        for table in ["runs", "usage_evidence", "remote_client_events"] {
            let sql = """
            CREATE INDEX idx_\(table)_ingest_seq ON \(table)(ingest_seq);
            CREATE TRIGGER trg_\(table)_ingest_seq
            AFTER INSERT ON \(table)
            WHEN NEW.ingest_seq IS NULL
            BEGIN
                UPDATE \(table)
                SET ingest_seq = (
                    SELECT COALESCE(MAX(seq), 0) + 1 FROM (
                        SELECT MAX(ingest_seq) AS seq FROM runs
                        UNION ALL SELECT MAX(ingest_seq) FROM usage_evidence
                        UNION ALL SELECT MAX(ingest_seq) FROM remote_client_events
                    )
                )
                WHERE rowid = NEW.rowid;
            END;
            """
            XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
        }
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
