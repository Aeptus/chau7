import SQLite3
import XCTest
@testable import Chau7

/// Regression coverage for retention on the tables the run cascade cannot reach.
///
/// The defect: `turns.run_id` and `tool_calls.run_id` are declared
/// `REFERENCES runs(run_id) ON DELETE CASCADE`, but `usage_evidence.run_id` and
/// `provider_latency_samples.run_id` are bare `TEXT`, and `remote_client_events`
/// has no `run_id` at all. Pruning `runs` therefore could never remove them, and
/// no other code path deleted them — so the largest tables in the database grew
/// without bound while the retention policy reported itself healthy.
///
/// These tests run the real SQL against a throwaway in-memory database, so they
/// cover the statements rather than a restatement of them.
final class TelemetryUnscopedRetentionTests: XCTestCase {
    private var db: OpaquePointer?

    /// Non-optional handle for the call sites, so the assertions below read as
    /// the contract they are checking rather than as optional plumbing.
    private var handle: OpaquePointer {
        guard let db else { fatalError("setUpWithError did not open a database") }
        return db
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(":memory:", &handle), SQLITE_OK)
        db = handle
        // The cascade the fix relies on for `turns`/`tool_calls` needs this on.
        XCTAssertEqual(sqlite3_exec(handle, "PRAGMA foreign_keys=ON", nil, nil, nil), SQLITE_OK)
        try createSchema()
    }

    override func tearDownWithError() throws {
        if let db { sqlite3_close(db) }
        db = nil
        try super.tearDownWithError()
    }

    // MARK: - Schema and fixtures

    /// Mirrors the shipped column names and types for the three unscoped tables.
    /// Only the columns these tests touch are declared — the point is the
    /// retention predicate, not a byte-for-byte schema copy.
    private func createSchema() throws {
        let sql = """
        CREATE TABLE usage_evidence (
            evidence_id TEXT PRIMARY KEY,
            run_id TEXT,
            observed_at TEXT NOT NULL
        );
        CREATE TABLE provider_latency_samples (
            sample_id TEXT PRIMARY KEY,
            run_id TEXT,
            observed_at TEXT NOT NULL
        );
        CREATE TABLE remote_client_events (
            event_id TEXT PRIMARY KEY,
            event_type TEXT NOT NULL,
            timestamp TEXT NOT NULL
        );
        """
        XCTAssertEqual(sqlite3_exec(handle, sql, nil, nil, nil), SQLITE_OK)
    }

    private enum Stamp {
        /// Far enough in the past to always be outside any sane window.
        static let old = "2020-01-01T00:00:00.000Z"
        static let recent = "2999-01-01T00:00:00.000Z"
    }

    private func insertRow(_ sql: String) {
        XCTAssertEqual(sqlite3_exec(handle, sql, nil, nil, nil), SQLITE_OK, "insert failed: \(sql)")
    }

    private func count(_ table: String) -> Int {
        var stmt: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(handle, "SELECT COUNT(*) FROM \(table)", -1, &stmt, nil), SQLITE_OK)
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return -1 }
        return Int(sqlite3_column_int(stmt, 0))
    }

    // MARK: - The leak

    func testOldRowsInEveryUnscopedTableAreRemoved() {
        for table in ["usage_evidence", "provider_latency_samples", "remote_client_events"] {
            insertRow("INSERT INTO \(table) VALUES ('old', 'run-1', '\(Stamp.old)')")
        }
        for table in ["usage_evidence", "provider_latency_samples", "remote_client_events"] {
            XCTAssertEqual(count(table), 1, "\(table) fixture missing")
        }

        let outcome = TelemetryMaintenance.deleteUnscopedTelemetryOlderThan(retentionDays: 30, in: handle)

        guard case let .pruned(deleted, _) = outcome else {
            return XCTFail("expected a prune, got \(outcome)")
        }
        XCTAssertEqual(deleted, 3, "one stale row in each of the three tables")
        for table in ["usage_evidence", "provider_latency_samples", "remote_client_events"] {
            XCTAssertEqual(count(table), 0, "\(table) still holds a stale row — it would grow forever")
        }
    }

    func testRecentRowsSurvive() {
        for table in ["usage_evidence", "provider_latency_samples", "remote_client_events"] {
            insertRow("INSERT INTO \(table) VALUES ('new', 'run-1', '\(Stamp.recent)')")
        }

        let outcome = TelemetryMaintenance.deleteUnscopedTelemetryOlderThan(retentionDays: 30, in: handle)

        XCTAssertEqual(outcome, .nothingToPrune, "nothing was old, so nothing should be reported as pruned")
        for table in ["usage_evidence", "provider_latency_samples", "remote_client_events"] {
            XCTAssertEqual(count(table), 1, "\(table) must not lose in-window data")
        }
    }

    /// The window must be a real boundary: recent-but-old-enough evidence for a
    /// run inside the window is kept, stale evidence is not.
    func testOnlyRowsPastTheWindowAreRemoved() {
        insertRow("INSERT INTO usage_evidence VALUES ('keep', 'run-1', '\(Stamp.recent)')")
        insertRow("INSERT INTO usage_evidence VALUES ('drop', 'run-1', '\(Stamp.old)')")

        _ = TelemetryMaintenance.deleteUnscopedTelemetryOlderThan(retentionDays: 30, in: handle)

        XCTAssertEqual(count("usage_evidence"), 1)
    }

    // MARK: - Contract

    func testDisabledRetentionDeletesNothing() {
        insertRow("INSERT INTO usage_evidence VALUES ('old', 'run-1', '\(Stamp.old)')")

        for days in [0, -1] {
            let outcome = TelemetryMaintenance.deleteUnscopedTelemetryOlderThan(retentionDays: days, in: handle)
            XCTAssertEqual(outcome, .disabled, "retentionDays=\(days) must disable pruning")
        }
        XCTAssertEqual(count("usage_evidence"), 1, "'keep forever' must not delete")
    }

    /// A retention value larger than the clamp is pinned, matching the runs
    /// prune, so a typo cannot turn into an unbounded window.
    ///
    /// The fixture predates even a clamped 3650-day window (~2016), which a
    /// 2020-dated row would not — that row is *newer* than such a cutoff and
    /// would correctly survive, making the test assert the wrong thing.
    func testRetentionIsClamped() {
        let ancient = "1970-01-01T00:00:00.000Z"
        insertRow("INSERT INTO usage_evidence VALUES ('ancient', 'run-1', '\(ancient)')")

        let outcome = TelemetryMaintenance.deleteUnscopedTelemetryOlderThan(
            retentionDays: TelemetryRetention.maxDays + 5000,
            in: handle
        )

        guard case let .pruned(_, clampedDays) = outcome else {
            return XCTFail("expected a prune, got \(outcome)")
        }
        XCTAssertEqual(clampedDays, TelemetryRetention.maxDays)
        XCTAssertEqual(count("usage_evidence"), 0)
    }

    /// An empty database must report "nothing to prune" rather than a spurious
    /// success, so the caller can skip the VACUUM.
    func testEmptyDatabaseReportsNothingToPrune() {
        XCTAssertEqual(
            TelemetryMaintenance.deleteUnscopedTelemetryOlderThan(retentionDays: 30, in: handle),
            .nothingToPrune
        )
    }

    /// Every table the policy claims to cover must actually exist and be
    /// reachable — a typo in `unscopedRetentionTables` would otherwise fail
    /// silently at runtime with a `no such table` error, or worse, be skipped.
    func testEveryDeclaredTableIsPruned() {
        XCTAssertEqual(
            Set(TelemetryMaintenance.unscopedRetentionTables.map(\.table)),
            ["usage_evidence", "provider_latency_samples", "remote_client_events"],
            "the declared table list drifted from what the tests create"
        )
        for entry in TelemetryMaintenance.unscopedRetentionTables {
            insertRow("INSERT INTO \(entry.table) VALUES ('old', 'run-1', '\(Stamp.old)')")
        }
        _ = TelemetryMaintenance.deleteUnscopedTelemetryOlderThan(retentionDays: 30, in: handle)
        for entry in TelemetryMaintenance.unscopedRetentionTables {
            XCTAssertEqual(count(entry.table), 0, "\(entry.table) was not pruned")
        }
    }
}
