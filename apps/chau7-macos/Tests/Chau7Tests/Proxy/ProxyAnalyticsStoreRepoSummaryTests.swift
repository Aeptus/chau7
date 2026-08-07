import SQLite3
import XCTest
@testable import Chau7

final class ProxyAnalyticsStoreRepoSummaryTests: XCTestCase {
    private var databasePath = ""
    private var latestTargetCallAt = Date()

    override func setUpWithError() throws {
        try super.setUpWithError()
        databasePath = NSTemporaryDirectory() + "chau7-proxy-summary-\(UUID().uuidString).db"

        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databasePath, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        let olderTargetCallAt = now.addingTimeInterval(-2 * 60 * 60)
        latestTargetCallAt = now.addingTimeInterval(-60 * 60)
        let otherRepoCallAt = now.addingTimeInterval(-30 * 60)
        let formatter = ISO8601DateFormatter()
        let schema = """
        CREATE TABLE api_calls (
            id INTEGER PRIMARY KEY,
            provider TEXT NOT NULL,
            input_tokens INTEGER,
            output_tokens INTEGER,
            cache_creation_input_tokens INTEGER,
            cache_read_input_tokens INTEGER,
            reasoning_output_tokens INTEGER,
            cost_usd REAL,
            timestamp TEXT,
            project_path TEXT
        );
        CREATE INDEX idx_api_calls_project_timestamp ON api_calls(project_path, timestamp);
        INSERT INTO api_calls VALUES
            (1, 'claude', 20, 10, 0, 0, 0, 2.0, '\(formatter.string(from: olderTargetCallAt))', '/repo/target'),
            (2, 'codex', 10, 5, 2, 3, 4, 1.2, '\(formatter.string(from: latestTargetCallAt))', '/repo/target'),
            (3, 'gemini', 99, 99, 0, 0, 0, 9.9, '\(formatter.string(from: otherRepoCallAt))', '/repo/other');
        """
        XCTAssertEqual(sqlite3_exec(db, schema, nil, nil, nil), SQLITE_OK)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: databasePath)
        try super.tearDownWithError()
    }

    func testRepoSummaryAggregatesAttributedRowsAndHourlyTrend() throws {
        let store = ProxyAnalyticsStore(databasePath: databasePath)

        let summary = store.repoSummary(projectPath: "/repo/target", hourlyDays: 1)

        XCTAssertEqual(summary.callCount, 2)
        XCTAssertEqual(summary.totalTokens, 54)
        XCTAssertEqual(summary.totalCostUSD, 3.2, accuracy: 0.0001)
        XCTAssertEqual(summary.providers, ["anthropic", "openai"])
        XCTAssertEqual(try XCTUnwrap(summary.lastCallAt).timeIntervalSince1970, latestTargetCallAt.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(summary.hourlyCost.reduce(0) { $0 + $1.callCount }, 2)
    }

    func testRepoSummaryReturnsEmptyForMissingRepositoryAndFilteredProvider() {
        let store = ProxyAnalyticsStore(databasePath: databasePath)

        let missing = store.repoSummary(projectPath: "/repo/missing")
        XCTAssertEqual(missing.callCount, 0)
        XCTAssertTrue(missing.providers.isEmpty)
        XCTAssertTrue(missing.hourlyCost.isEmpty)

        let openAI = store.repoSummary(projectPath: "/repo/target", providerFilterKey: "openai")
        XCTAssertEqual(openAI.callCount, 1)
        XCTAssertEqual(openAI.totalTokens, 24)
        XCTAssertEqual(openAI.providers, ["openai"])
    }
}
