import Foundation
import SQLite3
import XCTest
import Chau7Core
@testable import Chau7

final class ProxyLatencyConcurrencyTests: XCTestCase {
    private func makeDatabase() throws -> String {
        let path = NSTemporaryDirectory() + "chau7-latency-\(UUID().uuidString).db"
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        let sql = """
        CREATE TABLE api_calls (
            provider TEXT, model TEXT, endpoint TEXT,
            latency_ms INTEGER, ttft_ms INTEGER, timestamp TEXT,
            project_path TEXT, session_id TEXT, status_code INTEGER,
            input_tokens INTEGER DEFAULT 0, output_tokens INTEGER DEFAULT 0,
            cache_creation_input_tokens INTEGER DEFAULT 0, cache_read_input_tokens INTEGER DEFAULT 0,
            reasoning_output_tokens INTEGER DEFAULT 0, cost_usd REAL DEFAULT 0
        );
        INSERT INTO api_calls (provider, model, endpoint, latency_ms, ttft_ms, timestamp, project_path, session_id, status_code) VALUES
            ('codex', 'gpt', '/v1/responses', 900, 150, '2026-10-02T18:00:00.250Z', '/repo/target', 'one', 200),
            ('claude', 'claude', '/v1/messages', 600, 0, '2026-10-02T18:00:01Z', '/repo/target', 'two', 200),
            ('codex', 'gpt', '/v1/responses', 900, 150, '2026-10-02T18:00:02Z', '/repo/other', 'other', 200),
            ('codex', 'gpt', '/v1/responses', 900, 150, '2026-10-02T18:00:03Z', '/repo/target', 'failed', 500),
            ('codex', 'gpt', '/v1/responses', 900, 150, 'invalid', '/repo/target', 'invalid', 200);
        """
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
        return path
    }

    func testLatencyRowsPreserveFilteringOrderAndPreferredMetric() throws {
        let path = try makeDatabase()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = ProxyAnalyticsStore(databasePath: path)
        let samples = store.latencySamples(projectPath: "/repo/target")
        XCTAssertEqual(samples.map(\.sessionID), ["one", "two"])
        XCTAssertEqual(samples.map(\.provider), ["openai", "anthropic"])
        XCTAssertEqual(samples.map(\.latencyMs), [150, 600])
        XCTAssertEqual(samples.map(\.sourceKind), ["proxy_api_ttft", "proxy_api_round_trip"])
        XCTAssertEqual(samples.first?.timestamp.timeIntervalSince1970, DateFormatters.parseISO8601("2026-10-02T18:00:00.250Z")?.timeIntervalSince1970)
        let filtered = store.latencySamples(
            after: DateFormatters.parseISO8601("2026-10-02T18:00:00.500Z"),
            providerFilterKey: "anthropic", projectPath: "/repo/target"
        )
        XCTAssertEqual(filtered.map(\.sessionID), ["two"])
    }

    func testBlockedTimestampDecodingDoesNotBlockOtherDatabaseReaders() throws {
        let path = try makeDatabase()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = ProxyAnalyticsStore(databasePath: path)
        let decoding = expectation(description: "Timestamp decoding started")
        let decoded = expectation(description: "Timestamp decoding finished")
        let read = expectation(description: "Another query finished during decoding")
        let readerFinished = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        DispatchQueue.global(qos: .utility).async {
            _ = store.latencySamples(providerFilterKey: "anthropic", projectPath: "/repo/target", timestampParser: { value in
                decoding.fulfill()
                _ = release.wait(timeout: .now() + 3)
                return DateFormatters.parseISO8601(value)
            })
            decoded.fulfill()
        }
        wait(for: [decoding], timeout: 2)
        DispatchQueue.global(qos: .utility).async {
            let summary = store.repoSummary(projectPath: "/repo/target")
            XCTAssertEqual(summary.callCount, 4)
            read.fulfill()
            readerFinished.signal()
        }
        wait(for: [read], timeout: 1)
        release.signal()
        wait(for: [decoded], timeout: 2)
        XCTAssertEqual(readerFinished.wait(timeout: .now() + 3), .success)
    }
}
