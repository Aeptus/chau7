import Foundation
import SQLite3
import XCTest
import Chau7Core
@testable import Chau7

final class ProxyTokenAccountingTests: XCTestCase {
    private func makeStore() throws -> ProxyAnalyticsStore {
        let path = NSTemporaryDirectory() + "chau7-proxy-accounting-\(UUID().uuidString).db"
        addTeardownBlock { try? FileManager.default.removeItem(atPath: path) }
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        let timestamp = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-60))
        let sql = """
        CREATE TABLE api_calls (
            session_id TEXT, provider TEXT, model TEXT, endpoint TEXT,
            input_tokens INTEGER, output_tokens INTEGER,
            cache_creation_input_tokens INTEGER, cache_read_input_tokens INTEGER,
            reasoning_output_tokens INTEGER, latency_ms INTEGER,
            status_code INTEGER, cost_usd REAL, timestamp TEXT,
            error_message TEXT, project_path TEXT
        );
        INSERT INTO api_calls VALUES
            ('a','openai','openai','/v1/responses',125,47,NULL,80,19,10,200,0.2,'\(timestamp)',NULL,'/repo/main'),
            ('b','codex','codex','/v1/responses',125,47,NULL,80,19,10,200,0.2,'\(timestamp)',NULL,'/repo/main'),
            ('c','gemini','gemini','/v1/generate',125,47,NULL,80,19,10,200,0.2,'\(timestamp)',NULL,'/repo/main'),
            ('d','anthropic','anthropic','/v1/messages',125,47,NULL,80,19,10,200,0.2,'\(timestamp)',NULL,'/repo/main'),
            ('e','openai','unknown','/v1/responses',10,5,NULL,NULL,NULL,10,200,NULL,'\(timestamp)',NULL,'/repo/unknown'),
            ('f','openai','zero','/v1/responses',10,5,0,0,0,10,200,0,'\(timestamp)',NULL,'/repo/zero'),
            ('g','openai','clamped','/v1/responses',3,2,NULL,4,3,10,200,0.2,'\(timestamp)',NULL,'/repo/clamped'),
            ('h','openai','valid','/v1/responses',10,5,NULL,0,0,10,200,0.2,'\(timestamp)',NULL,'/repo/clamped');
        """
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
        return ProxyAnalyticsStore(databasePath: path)
    }

    func testProviderModelRepositoryAndTrendTotalsNormalizeEachRequestOnce() throws {
        let store = try makeStore()
        let models = Dictionary(uniqueKeysWithValues: store.modelStats(projectPath: "/repo/main").map { ($0.model, $0) })
        XCTAssertEqual(models["openai"]?.totalBillableTokens, 172)
        XCTAssertEqual(models["codex"]?.totalBillableTokens, 172)
        XCTAssertEqual(models["gemini"]?.totalBillableTokens, 191)
        XCTAssertEqual(models["anthropic"]?.totalBillableTokens, 271)
        XCTAssertEqual(store.providerStats(projectPath: "/repo/main").reduce(0) { $0 + $1.totalBillableTokens }, 806)
        XCTAssertEqual(store.overallStats(projectPath: "/repo/main").totalAllTokens, 806)
        XCTAssertEqual(store.repoSummary(projectPath: "/repo/main").totalTokens, 806)
        XCTAssertEqual(store.dailyTrend(projectPath: "/repo/main").reduce(0) { $0 + $1.totalTokens }, 806)
        XCTAssertEqual(store.hourlyTrend(projectPath: "/repo/main").reduce(0) { $0 + $1.totalTokens }, 806)
        XCTAssertEqual(store.repoSummary(projectPath: "/repo/main").totalCostUSD, 0.8, accuracy: 0.0001)
        // Clamp each request before SUM, rather than cancelling malformed
        // negative differences against a different request's known usage.
        XCTAssertEqual(store.repoSummary(projectPath: "/repo/clamped").totalTokens, 22)
    }

    func testRecentCallsKeepRawObservationsAndUseCanonicalMeteredTotals() throws {
        let store = try makeStore()
        let calls = Dictionary(uniqueKeysWithValues: store.recentCalls(projectPath: "/repo/main").map { ($0.model, $0) })
        let openai = try XCTUnwrap(calls["openai"])
        XCTAssertEqual(openai.observedInputTokens, 125)
        XCTAssertEqual(openai.observedOutputTokens, 47)
        XCTAssertEqual(openai.tokenUsage.inputTokens, 45)
        XCTAssertEqual(openai.tokenUsage.outputTokens, 28)
        XCTAssertEqual(openai.totalBillableTokens, 172)
        XCTAssertEqual(calls["codex"]?.provider, .openai)
        XCTAssertEqual(calls["codex"]?.totalBillableTokens, 172)
        XCTAssertEqual(calls["gemini"]?.totalBillableTokens, 191)
        XCTAssertEqual(calls["anthropic"]?.totalBillableTokens, 271)
        XCTAssertEqual(APICallStats.from(Array(calls.values)).totalAllTokens, 806)
        let unknown = try XCTUnwrap(store.recentCalls(projectPath: "/repo/unknown").first)
        XCTAssertNil(unknown.observedCacheReadInputTokens)
        XCTAssertNil(unknown.observedCacheCreationInputTokens)
        XCTAssertNil(unknown.observedReasoningOutputTokens)
        XCTAssertNil(unknown.observedCostUSD)
        let zero = try XCTUnwrap(store.recentCalls(projectPath: "/repo/zero").first)
        XCTAssertEqual(zero.observedCacheReadInputTokens, 0)
        XCTAssertEqual(zero.observedCostUSD, 0)
    }
}
