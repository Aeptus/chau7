import XCTest
import Chau7Core

final class ProviderTokenAccountingTests: XCTestCase {
    func testProviderBucketsPreserveIndependentAnthropicAndGeminiReasoning() {
        XCTAssertEqual(ProviderTokenAccounting.uncachedInput(provider: "openai", input: 125, cacheRead: 80), 45)
        XCTAssertEqual(ProviderTokenAccounting.visibleOutput(provider: "codex", output: 47, reasoning: 19), 28)
        XCTAssertEqual(ProviderTokenAccounting.uncachedInput(provider: "gemini", input: 125, cacheRead: 80), 45)
        XCTAssertEqual(ProviderTokenAccounting.visibleOutput(provider: "gemini", output: 47, reasoning: 19), 47)
        XCTAssertEqual(ProviderTokenAccounting.uncachedInput(provider: "anthropic", input: 125, cacheRead: 80), 125)
        XCTAssertEqual(ProviderTokenAccounting.uncachedInput(provider: "openai", input: 125, cacheRead: nil), 125)
        XCTAssertNil(ProviderTokenAccounting.uncachedInput(provider: "openai", input: nil, cacheRead: 80))
        XCTAssertNil(ProviderTokenAccounting.visibleOutput(provider: "openai", output: nil, reasoning: 19))
        XCTAssertEqual(ProviderTokenAccounting.visibleOutput(provider: "openai", output: 10, reasoning: 20), 0)
    }

    func testRawEvidenceAndReconciliationNormalizeExactlyOnce() {
        let evidence = UsageEvidence.proxyEvent(
            provider: "openai",
            model: nil,
            sessionID: "session",
            endpoint: nil,
            projectPath: "/repo",
            observedAt: Date(),
            inputTokens: 125,
            outputTokens: 47,
            cacheCreationInputTokens: nil,
            cacheReadInputTokens: 80,
            reasoningOutputTokens: 19,
            costUSD: 0.1,
            pricingVersion: nil
        )
        XCTAssertEqual(evidence.inputTokens, 125)
        XCTAssertEqual(evidence.tokenUsage.inputTokens, 45)
        XCTAssertEqual(evidence.tokenUsage.totalBillableTokens, 172)
        let report = UsageReconciliationService.reconcile([evidence])
        XCTAssertEqual(report.totalTokenUsage.inputTokens, 45)
        XCTAssertEqual(report.totalTokenUsage.outputTokens, 28)
        XCTAssertEqual(report.totalTokenUsage.totalBillableTokens, 172)
        let run = TelemetryRun(
            id: "measured",
            provider: "codex",
            cwd: "/repo",
            totalInputTokens: 45,
            totalCacheReadInputTokens: 80,
            totalOutputTokens: 28,
            totalReasoningOutputTokens: 19,
            tokenUsageSource: .proxy
        )
        XCTAssertEqual(UsageEvidence.runSummary(run).tokenUsage.totalBillableTokens, 172)
    }
}
