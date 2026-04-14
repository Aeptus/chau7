import XCTest
@testable import Chau7Core

final class UsageEvidenceReconciliationTests: XCTestCase {
    func testProxyEvidencePreservesMissingMetrics() {
        let evidence = UsageEvidence.proxyEvent(
            provider: "anthropic",
            model: "claude-sonnet-4",
            sessionID: "session-1",
            endpoint: "/v1/messages",
            projectPath: "/tmp/chau7",
            observedAt: Date(timeIntervalSince1970: 1_765_000_000),
            inputTokens: nil,
            outputTokens: nil,
            cacheCreationInputTokens: nil,
            cacheReadInputTokens: nil,
            reasoningOutputTokens: nil,
            costUSD: nil,
            pricingVersion: "2026-04-07"
        )

        XCTAssertEqual(evidence.sourceKind, .proxy)
        XCTAssertEqual(evidence.tokenUsageState, .missing)
        XCTAssertEqual(evidence.costState, .missing)
        XCTAssertEqual(evidence.costSource, .unavailable)
        XCTAssertFalse(evidence.hasAnyTokens)
    }

    func testRunSummaryUsesSessionScopedReconciliationKey() {
        let run = TelemetryRun(
            id: "run-123",
            sessionID: "session-123",
            provider: "codex",
            model: "gpt-5.3-codex",
            cwd: "/tmp/chau7",
            startedAt: Date(timeIntervalSince1970: 1_765_000_000),
            endedAt: Date(timeIntervalSince1970: 1_765_000_100),
            totalInputTokens: 100,
            totalCacheCreationInputTokens: 5,
            totalCacheReadInputTokens: 15,
            totalCachedInputTokens: 20,
            totalOutputTokens: 50,
            totalReasoningOutputTokens: 10,
            costUSD: 1.25,
            tokenUsageSource: .transcriptSnapshot,
            tokenUsageState: .complete,
            costSource: .estimated,
            costState: .estimated
        )

        let evidence = UsageEvidence.runSummary(run)

        XCTAssertEqual(evidence.reconciliationKey, "session|codex|session-123")
        XCTAssertEqual(evidence.sourceKind, .transcript)
        XCTAssertEqual(evidence.cacheCreationInputTokens, 5)
        XCTAssertEqual(evidence.cacheReadInputTokens, 15)
        XCTAssertEqual(evidence.pricingVersion, ModelPricingTable.version)
    }

    func testRunSummaryDerivesMissingCacheBucketFromCombinedTotal() {
        let run = TelemetryRun(
            id: "run-cache-gap",
            sessionID: "session-cache-gap",
            provider: "anthropic",
            model: "claude-sonnet-4",
            cwd: "/tmp/chau7",
            startedAt: Date(timeIntervalSince1970: 1_765_000_000),
            endedAt: Date(timeIntervalSince1970: 1_765_000_100),
            totalInputTokens: 100,
            totalCacheCreationInputTokens: 5,
            totalCacheReadInputTokens: nil,
            totalCachedInputTokens: 20,
            totalOutputTokens: 50,
            tokenUsageSource: .transcriptSnapshot,
            tokenUsageState: .complete,
            costSource: .estimated,
            costState: .estimated
        )

        let evidence = UsageEvidence.runSummary(run)

        XCTAssertEqual(evidence.cacheCreationInputTokens, 5)
        XCTAssertEqual(evidence.cacheReadInputTokens, 15)
        XCTAssertEqual(evidence.tokenUsage.totalBillableTokens, 170)
    }

    func testReconciliationPrefersObservedProxyAggregate() throws {
        let timestamp = Date(timeIntervalSince1970: 1_765_000_000)
        let proxyA = UsageEvidence.proxyEvent(
            provider: "anthropic",
            model: "claude-sonnet-4",
            sessionID: "session-42",
            endpoint: "/v1/messages",
            projectPath: "/tmp/chau7",
            observedAt: timestamp,
            inputTokens: 100,
            outputTokens: 40,
            cacheCreationInputTokens: 10,
            cacheReadInputTokens: 20,
            reasoningOutputTokens: nil,
            costUSD: 1.2,
            pricingVersion: "2026-04-07"
        )
        let proxyB = UsageEvidence.proxyEvent(
            provider: "anthropic",
            model: "claude-sonnet-4",
            sessionID: "session-42",
            endpoint: "/v1/messages",
            projectPath: "/tmp/chau7",
            observedAt: timestamp.addingTimeInterval(5),
            inputTokens: 50,
            outputTokens: 30,
            cacheCreationInputTokens: nil,
            cacheReadInputTokens: 5,
            reasoningOutputTokens: nil,
            costUSD: 0.8,
            pricingVersion: "2026-04-07"
        )
        let transcript = UsageEvidence.runSummary(
            TelemetryRun(
                id: "run-42",
                sessionID: "session-42",
                provider: "anthropic",
                model: "claude-sonnet-4",
                cwd: "/tmp/chau7",
                startedAt: timestamp,
                endedAt: timestamp.addingTimeInterval(60),
                totalInputTokens: 170,
                totalCacheCreationInputTokens: 12,
                totalCacheReadInputTokens: 18,
                totalCachedInputTokens: 30,
                totalOutputTokens: 70,
                totalReasoningOutputTokens: nil,
                costUSD: 3.6,
                tokenUsageSource: .transcriptSnapshot,
                tokenUsageState: .complete,
                costSource: .estimated,
                costState: .estimated
            )
        )

        let report = UsageReconciliationService.reconcile([proxyA, proxyB, transcript])
        let group = try XCTUnwrap(report.groups.first)

        XCTAssertEqual(group.selected.sourceKind, .proxy)
        XCTAssertEqual(group.selected.costSource, .observed)
        XCTAssertEqual(try XCTUnwrap(group.selected.costUSD), 2.0, accuracy: 0.0001)
        XCTAssertEqual(group.selected.inputTokens, 150)
        XCTAssertEqual(group.selected.cacheCreationInputTokens, 10)
        XCTAssertEqual(group.selected.cacheReadInputTokens, 25)
        XCTAssertEqual(group.selected.outputTokens, 70)
        XCTAssertEqual(group.confidence, .observed)
        XCTAssertEqual(group.alternatives.first?.sourceKind, .transcript)
        XCTAssertEqual(try XCTUnwrap(group.costDeltaUSD), -1.6, accuracy: 0.0001)
        XCTAssertEqual(report.totalCostUSD, 2.0, accuracy: 0.0001)
        XCTAssertEqual(report.totalTokenUsage.totalBillableTokens, 255)
    }
}
