import Foundation
import XCTest
@testable import Chau7
import Chau7Core

final class TelemetryProxyPersistenceTests: XCTestCase {
    private func makeStore() throws -> TelemetryStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return TelemetryStore(testDatabasePath: directory.appendingPathComponent("runs.db").path)
    }

    private func run(_ id: String, start: TimeInterval = 1000, end: TimeInterval? = 1100) -> TelemetryRun {
        TelemetryRun(id: id, sessionID: "session", tabID: "tab", provider: "codex", cwd: "/repo", startedAt: Date(timeIntervalSince1970: start), endedAt: end.map(Date.init(timeIntervalSince1970:)))
    }

    private func evidence(_ id: String, creation: Int? = nil, read: Int? = 40) throws -> UsageEvidence {
        var json: [String: Any] = [
            "request_id": id, "session_id": "session", "tab_id": "tab", "provider": "openai", "model": "gpt-5",
            "endpoint": "/v1/responses", "project_path": "/repo", "input_tokens": 100, "output_tokens": 10,
            "latency_ms": 10, "status_code": 200, "cost_usd": 0.25, "timestamp": "1970-01-01T00:16:50.000Z"
        ]
        if let creation { json["cache_creation_input_tokens"] = creation }
        if let read { json["cache_read_input_tokens"] = read }
        let message = try JSONDecoder().decode(ProxyIPCServerData.self, from: JSONSerialization.data(withJSONObject: json))
        return message.usageEvidence(observedAt: Date(timeIntervalSince1970: 1010))
    }

    func testIPCToStoredRunIsIdempotentAndKeepsMissingCacheCreation() throws {
        let store = try makeStore()
        store.insertRun(run("run"))
        let request = try evidence("same")
        store.insertUsageEvidence(request)
        store.insertUsageEvidence(request)
        try store.insertUsageEvidence(evidence("second", read: 0))
        let saved = try XCTUnwrap(store.getRun("run"))
        XCTAssertEqual(saved.totalInputTokens, 200)
        XCTAssertNil(saved.totalCacheCreationInputTokens)
        XCTAssertEqual(saved.totalCacheReadInputTokens, 40)
        XCTAssertEqual(saved.costUSD, 0.5)
        XCTAssertEqual(saved.costSource, .observed)
        XCTAssertEqual(saved.tokenUsageSource, .proxy)
        XCTAssertEqual(saved.costState, .partial)
        XCTAssertEqual(saved.metadata["proxy_request_count"], "2")
        store.backfillProxyRunAttribution()
        XCTAssertEqual(store.getRun("run")?.costUSD, 0.5)
    }

    func testRetainedEvidenceBackfillsWhenRunArrivesAndSurvivesFinalization() throws {
        let store = try makeStore()
        try store.insertUsageEvidence(evidence("before-run", creation: 30))
        store.insertRun(run("run"))
        XCTAssertEqual(store.getRun("run")?.totalCacheCreationInputTokens, 30)
        var finalized = run("run")
        finalized.costUSD = 99
        finalized.costSource = .estimated
        store.finalizeRun(finalized, turns: [], toolCalls: [])
        XCTAssertEqual(store.getRun("run")?.costUSD, 0.25)
        store.backfillProxyRunAttribution()
        XCTAssertEqual(store.getRun("run")?.costUSD, 0.25)
    }

    func testNewOverlappingRunRevokesEarlierAttributionAndRestoresBaseline() throws {
        let store = try makeStore()
        var original = run("first")
        original.costUSD = 1
        original.costSource = .estimated
        original.costState = .estimated
        store.insertRun(original)
        try store.insertUsageEvidence(evidence("request"))
        XCTAssertEqual(store.getRun("first")?.costUSD, 0.25)
        store.insertRun(run("overlap"))
        XCTAssertEqual(store.getRun("first")?.costUSD, 1)
        XCTAssertEqual(store.getRun("first")?.costSource, .estimated)
        XCTAssertNil(store.getRun("overlap")?.costUSD)
        XCTAssertNil(store.getRun("first")?.metadata["proxy_request_count"])
    }

    func testAdjacentRunBoundaryDoesNotDoubleCount() throws {
        let store = try makeStore()
        store.insertRun(run("first", end: 1010))
        store.insertRun(run("next", start: 1010))
        try store.insertUsageEvidence(evidence("boundary"))
        XCTAssertNil(store.getRun("first")?.costUSD)
        XCTAssertEqual(store.getRun("next")?.costUSD, 0.25)
    }
}
