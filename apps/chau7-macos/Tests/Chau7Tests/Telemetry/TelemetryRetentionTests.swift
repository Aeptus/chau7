import SQLite3
import XCTest
@testable import Chau7

/// Exercises the telemetry retention prune against a throwaway temp database so
/// it never touches the shared store's real file (`swift test` does not isolate
/// the home, so `TelemetryStore.shared` points at the user's real runs.db).
final class TelemetryRetentionTests: XCTestCase {
    private var dbPath: String!
    private var db: OpaquePointer?

    override func setUpWithError() throws {
        try super.setUpWithError()
        dbPath = NSTemporaryDirectory() + "chau7-retention-\(UUID().uuidString).db"
        XCTAssertEqual(sqlite3_open(dbPath, &db), SQLITE_OK)
        sqlite3_exec(db, "PRAGMA foreign_keys=ON", nil, nil, nil)
        // Minimal slice of the real schema: enough to drive the prune + verify
        // the ON DELETE CASCADE that removes a pruned run's child rows.
        let schema = """
        CREATE TABLE runs (
            run_id TEXT PRIMARY KEY,
            provider TEXT NOT NULL,
            cwd TEXT NOT NULL,
            started_at TEXT NOT NULL
        );
        CREATE TABLE turns (
            turn_id TEXT PRIMARY KEY,
            run_id TEXT NOT NULL REFERENCES runs(run_id) ON DELETE CASCADE,
            content TEXT
        );
        """
        XCTAssertEqual(sqlite3_exec(db, schema, nil, nil, nil), SQLITE_OK, errmsg())
    }

    override func tearDownWithError() throws {
        if let db { sqlite3_close(db) }
        db = nil
        try? FileManager.default.removeItem(atPath: dbPath)
        try super.tearDownWithError()
    }

    func testPrunesRunsOlderThanWindowAndCascadesChildRows() throws {
        insertRun("old", startedAtOffsetDays: -100, withTurn: true)
        insertRun("recent", startedAtOffsetDays: -1, withTurn: true)

        let outcome = try TelemetryStore.deleteRunsOlderThan(retentionDays: 30, in: XCTUnwrap(db))

        XCTAssertEqual(outcome, .pruned(deleted: 1, clampedDays: 30))
        XCTAssertEqual(runCount(), 1, "only the recent run should remain")
        XCTAssertEqual(turnCount(), 1, "the old run's turn should be cascade-deleted")
    }

    func testRetentionDisabledKeepsEverything() throws {
        insertRun("ancient", startedAtOffsetDays: -1000)

        XCTAssertEqual(try TelemetryStore.deleteRunsOlderThan(retentionDays: 0, in: XCTUnwrap(db)), .disabled)
        XCTAssertEqual(runCount(), 1)
    }

    func testNothingToPruneWhenAllRunsAreRecent() throws {
        insertRun("recent", startedAtOffsetDays: -2)

        XCTAssertEqual(try TelemetryStore.deleteRunsOlderThan(retentionDays: 30, in: XCTUnwrap(db)), .nothingToPrune)
        XCTAssertEqual(runCount(), 1)
    }

    func testRetentionWindowIsClampedToMaxDays() throws {
        // A run older than the clamp boundary is still pruned, and the reported
        // window is clamped rather than the raw (typo-sized) input.
        insertRun("beyond-clamp", startedAtOffsetDays: -(TelemetryRetention.maxDays + 500))

        let outcome = try TelemetryStore.deleteRunsOlderThan(retentionDays: 999_999, in: XCTUnwrap(db))

        XCTAssertEqual(outcome, .pruned(deleted: 1, clampedDays: TelemetryRetention.maxDays))
        XCTAssertEqual(runCount(), 0)
    }

    // MARK: - Helpers

    private func insertRun(_ id: String, startedAtOffsetDays days: Int, withTurn: Bool = false) {
        let startedAt = "strftime('%Y-%m-%dT%H:%M:%fZ','now','\(days) days')"
        let sql = "INSERT INTO runs (run_id, provider, cwd, started_at) VALUES ('\(id)','codex','/tmp',\(startedAt))"
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK, errmsg())
        if withTurn {
            let turn = "INSERT INTO turns (turn_id, run_id, content) VALUES ('t-\(id)','\(id)','content')"
            XCTAssertEqual(sqlite3_exec(db, turn, nil, nil, nil), SQLITE_OK, errmsg())
        }
    }

    private func runCount() -> Int {
        count("SELECT COUNT(*) FROM runs")
    }

    private func turnCount() -> Int {
        count("SELECT COUNT(*) FROM turns")
    }

    private func count(_ sql: String) -> Int {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, sqlite3_step(stmt) == SQLITE_ROW else {
            return -1
        }
        return Int(sqlite3_column_int(stmt, 0))
    }

    private func errmsg() -> String {
        db.map { String(cString: sqlite3_errmsg($0)) } ?? "no db"
    }
}
