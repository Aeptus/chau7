import XCTest
@testable import Chau7
import Chau7Core

final class TelemetryProxyAttributionTests: XCTestCase {
    func test_attributes_proxy_usage_to_enclosing_run_by_tab_and_marks_measured() {
        let startedAt = Date(timeIntervalSince1970: 1000)
        let run = TelemetryRun(
            id: "run-1",
            sessionID: "session-1",
            tabID: "tab-1",
            provider: "codex",
            model: "gpt-5",
            cwd: "/repo",
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(60)
        )
        let evidence = UsageEvidence.proxyEvent(
            provider: "openai",
            model: "gpt-5",
            sessionID: "session-1",
            endpoint: "/v1/responses",
            projectPath: "/repo",
            observedAt: startedAt.addingTimeInterval(10),
            inputTokens: 100,
            outputTokens: 20,
            cacheCreationInputTokens: 30,
            cacheReadInputTokens: 40,
            reasoningOutputTokens: 5,
            costUSD: 0.25,
            pricingVersion: "test",
            metadata: ["tab_id": "tab-1"]
        )

        let attributed = TelemetryProxyAttribution.attribute(
            observations: [evidence],
            runs: [run]
        )

        XCTAssertEqual(attributed["run-1"]?.costUSD, 0.25)
        XCTAssertEqual(attributed["run-1"]?.inputTokens, 100)
        XCTAssertEqual(attributed["run-1"]?.cacheCreationInputTokens, 30)
        XCTAssertEqual(attributed["run-1"]?.cacheReadInputTokens, 40)
        XCTAssertEqual(attributed["run-1"]?.tokenUsageSource, .proxy)
        XCTAssertEqual(attributed["run-1"]?.costSource, .observed)
    }

    func test_does_not_attribute_proxy_usage_outside_run_window_without_identity() {
        let startedAt = Date(timeIntervalSince1970: 2000)
        let run = TelemetryRun(
            id: "run-1",
            sessionID: nil,
            tabID: nil,
            provider: "codex",
            cwd: "/repo",
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(10)
        )
        let evidence = UsageEvidence.proxyEvent(
            provider: "codex",
            model: nil,
            sessionID: nil,
            endpoint: "/v1/responses",
            projectPath: "/repo",
            observedAt: startedAt.addingTimeInterval(60),
            inputTokens: 1,
            outputTokens: 1,
            cacheCreationInputTokens: nil,
            cacheReadInputTokens: nil,
            reasoningOutputTokens: nil,
            costUSD: 0.01,
            pricingVersion: nil
        )

        XCTAssertTrue(TelemetryProxyAttribution.attribute(observations: [evidence], runs: [run]).isEmpty)
    }
}
