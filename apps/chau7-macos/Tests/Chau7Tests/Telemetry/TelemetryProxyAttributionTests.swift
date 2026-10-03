import XCTest
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

    func testRejectsOverlappingRunsAndConflictingIdentities() {
        let first = makeRun("first")
        let second = makeRun("second")
        let evidence = makeEvidence("request", metadata: ["tab_id": "tab"])
        XCTAssertTrue(TelemetryProxyAttribution.attribute(observations: [evidence], runs: [first, second]).isEmpty)
        XCTAssertTrue(TelemetryProxyAttribution.attribute(observations: [makeEvidence("wrong", session: "other", metadata: ["tab_id": "tab"])], runs: [first]).isEmpty)
    }

    func testBoundaryBelongsOnlyToNextRun() {
        var first = makeRun("first")
        first.endedAt = Date(timeIntervalSince1970: 1010)
        let next = TelemetryRun(id: "next", sessionID: "session", tabID: "tab", provider: "codex", cwd: "/repo", startedAt: Date(timeIntervalSince1970: 1010))
        let result = TelemetryProxyAttribution.attribute(observations: [makeEvidence("boundary")], runs: [first, next])
        XCTAssertNil(result["first"])
        XCTAssertEqual(result["next"]?.requestCount, 1)
    }

    func testDeduplicatesStableRequestsAndNeverReattributesRunSummaries() {
        let run = makeRun("run")
        let evidence = makeEvidence("request")
        let result = TelemetryProxyAttribution.attribute(
            observations: [evidence, evidence, UsageEvidence.runSummary(ProxyRunAttribution(
                inputTokens: 100,
                cacheCreationInputTokens: nil,
                cacheReadInputTokens: 0,
                outputTokens: 10,
                reasoningOutputTokens: nil,
                costUSD: 0.1
            ).applying(to: run))],
            runs: [run]
        )
        XCTAssertEqual(result["run"]?.requestCount, 1)
        XCTAssertEqual(result["run"]?.costUSD, 0.1)
    }

    func testCacheAbsenceZeroAndPartialCostCoverageRemainDistinct() {
        let run = makeRun("run")
        let updated = TelemetryProxyAttribution.attribute(observations: [makeEvidence("read")], runs: [run])["run"]?.applying(to: run)
        XCTAssertNil(updated?.totalCacheCreationInputTokens)
        XCTAssertEqual(updated?.totalCacheReadInputTokens, 0)
        XCTAssertEqual(updated?.totalCachedInputTokens, 0)
        XCTAssertEqual(updated?.costSource, .observed)
        XCTAssertEqual(updated?.costState, .partial)
        XCTAssertEqual(updated?.metadata["proxy_priced_request_count"], "1")
    }

    func testDifferentRequestsWithIdenticalUsageInOneSecondAreNotCollapsed() {
        let result = TelemetryProxyAttribution.attribute(observations: [makeEvidence("first"), makeEvidence("second")], runs: [makeRun("run")])
        XCTAssertEqual(result["run"]?.inputTokens, 200)
        XCTAssertEqual(result["run"]?.requestCount, 2)
    }

    private func makeRun(_ id: String) -> TelemetryRun {
        TelemetryRun(id: id, sessionID: "session", tabID: "tab", provider: "codex", cwd: "/repo", startedAt: Date(timeIntervalSince1970: 1000))
    }

    private func makeEvidence(_ id: String, session: String = "session", metadata: [String: String] = [:]) -> UsageEvidence {
        UsageEvidence.proxyEvent(
            provider: "openai",
            model: nil,
            sessionID: session,
            endpoint: "/v1/responses",
            projectPath: "/repo",
            observedAt: Date(timeIntervalSince1970: 1010),
            inputTokens: 100,
            outputTokens: 10,
            cacheCreationInputTokens: nil,
            cacheReadInputTokens: 0,
            reasoningOutputTokens: nil,
            costUSD: 0.1,
            pricingVersion: nil,
            metadata: metadata,
            requestID: id
        )
    }

    func testEvidenceReconciliationDoesNotCountMeasuredRunSummaryAgain() {
        let run = makeRun("run")
        let observation = makeEvidence("request")
        let measured = TelemetryProxyAttribution.attribute(observations: [observation], runs: [run])[run.id]
        let summary = UsageEvidence.runSummary(measured?.applying(to: run) ?? run)
        let report = UsageReconciliationService.reconcile([observation, summary])
        XCTAssertEqual(report.totalCostUSD, 0.1)
        XCTAssertEqual(report.totalTokenUsage.inputTokens, 100)
    }

}
