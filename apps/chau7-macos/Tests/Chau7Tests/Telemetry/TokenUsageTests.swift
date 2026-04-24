import XCTest
import Chau7Core

final class TokenUsageTests: XCTestCase {

    // MARK: - Clamping

    func testInitClampsNegativesToZero() {
        let usage = TokenUsage(
            inputTokens: -1,
            cacheCreationInputTokens: -2,
            cacheReadInputTokens: -3,
            cachedInputTokens: -4,
            outputTokens: -5,
            reasoningOutputTokens: -6
        )
        XCTAssertEqual(usage.inputTokens, 0)
        XCTAssertEqual(usage.cacheCreationInputTokens, 0)
        XCTAssertEqual(usage.cacheReadInputTokens, 0)
        XCTAssertEqual(usage.cachedInputTokens, 0)
        XCTAssertEqual(usage.outputTokens, 0)
        XCTAssertEqual(usage.reasoningOutputTokens, 0)
    }

    // MARK: - Cached-token reconciliation

    func testCachedInputTokensTakesMaxOfExplicitAndSum() {
        // Provider reports cachedInputTokens=100 but sum of create+read=50 → keep 100.
        let usage = TokenUsage(
            inputTokens: 0,
            cacheCreationInputTokens: 30,
            cacheReadInputTokens: 20,
            cachedInputTokens: 100
        )
        XCTAssertEqual(usage.cachedInputTokens, 100)
    }

    func testCachedInputTokensRaisedToSumWhenExplicitLow() {
        // cachedInputTokens=10 but create+read=70 → bump to 70 so effective total is consistent.
        let usage = TokenUsage(
            inputTokens: 0,
            cacheCreationInputTokens: 40,
            cacheReadInputTokens: 30,
            cachedInputTokens: 10
        )
        XCTAssertEqual(usage.cachedInputTokens, 70)
    }

    func testEffectiveCachedInputTokensUsesSumWhenLarger() {
        let usage = TokenUsage(
            inputTokens: 0,
            cacheCreationInputTokens: 50,
            cacheReadInputTokens: 25
        )
        XCTAssertEqual(usage.effectiveCachedInputTokens, 75)
    }

    func testUncategorizedCachedInputTokensWhenExplicitExceedsSum() {
        let usage = TokenUsage(
            inputTokens: 0,
            cacheCreationInputTokens: 20,
            cacheReadInputTokens: 10,
            cachedInputTokens: 100
        )
        XCTAssertEqual(usage.uncategorizedCachedInputTokens, 70)
    }

    func testUncategorizedCachedInputTokensClampsToZero() {
        let usage = TokenUsage(
            inputTokens: 0,
            cacheCreationInputTokens: 50,
            cacheReadInputTokens: 40,
            cachedInputTokens: 10
        )
        // cachedInputTokens gets raised to 90, create+read=90, uncategorized=0.
        XCTAssertEqual(usage.uncategorizedCachedInputTokens, 0)
    }

    // MARK: - Totals

    func testTotalVisibleTokensIsInputPlusOutput() {
        let usage = TokenUsage(
            inputTokens: 100,
            cacheCreationInputTokens: 50,
            cacheReadInputTokens: 25,
            outputTokens: 200,
            reasoningOutputTokens: 30
        )
        XCTAssertEqual(usage.totalVisibleTokens, 300)
        XCTAssertEqual(usage.totalTokens, 300)
    }

    func testTotalBillableIncludesCacheAndReasoning() {
        let usage = TokenUsage(
            inputTokens: 100,
            cacheCreationInputTokens: 50,
            cacheReadInputTokens: 25,
            outputTokens: 200,
            reasoningOutputTokens: 30
        )
        // 100 input + 75 effective cached + 200 output + 30 reasoning = 405
        XCTAssertEqual(usage.totalBillableTokens, 405)
    }

    func testHasAnyTokensReflectsTotalVisible() {
        XCTAssertFalse(TokenUsage().hasAnyTokens)
        XCTAssertTrue(TokenUsage(outputTokens: 1).hasAnyTokens)
        // Only cache tokens + no visible tokens → reported as no tokens
        XCTAssertFalse(TokenUsage(cacheReadInputTokens: 100).hasAnyTokens)
    }

    // MARK: - add

    func testAddSumsAllFields() {
        var a = TokenUsage(
            inputTokens: 10,
            cacheCreationInputTokens: 5,
            cacheReadInputTokens: 3,
            cachedInputTokens: 8,
            outputTokens: 20,
            reasoningOutputTokens: 4
        )
        let b = TokenUsage(
            inputTokens: 7,
            cacheCreationInputTokens: 2,
            cacheReadInputTokens: 1,
            cachedInputTokens: 3,
            outputTokens: 15,
            reasoningOutputTokens: 1
        )
        a.add(b)
        XCTAssertEqual(a.inputTokens, 17)
        XCTAssertEqual(a.outputTokens, 35)
        XCTAssertEqual(a.cacheCreationInputTokens, 7)
        XCTAssertEqual(a.cacheReadInputTokens, 4)
        XCTAssertEqual(a.reasoningOutputTokens, 5)
    }

    // MARK: - Codable round trip

    func testCodableRoundTrip() throws {
        let usage = TokenUsage(
            inputTokens: 100,
            cacheCreationInputTokens: 50,
            cacheReadInputTokens: 25,
            outputTokens: 200,
            reasoningOutputTokens: 10
        )
        let data = try JSONEncoder().encode(usage)
        let decoded = try JSONDecoder().decode(TokenUsage.self, from: data)
        XCTAssertEqual(decoded, usage)
    }

    // MARK: - Reconciliation helper

    func testReconcileCachedInputTokensReturnsMaxOfSuppliedAndExplicit() {
        XCTAssertEqual(
            TokenUsage.reconcileCachedInputTokens(supplied: 100, creation: 30, read: 20),
            100,
            "supplied > explicit stays supplied"
        )
        XCTAssertEqual(
            TokenUsage.reconcileCachedInputTokens(supplied: 10, creation: 30, read: 40),
            70,
            "supplied < explicit bumps to explicit sum"
        )
        XCTAssertEqual(
            TokenUsage.reconcileCachedInputTokens(supplied: 0, creation: 0, read: 0),
            0
        )
    }

    func testReconcileCachedInputTokensClampsNegatives() {
        XCTAssertEqual(
            TokenUsage.reconcileCachedInputTokens(supplied: -5, creation: -2, read: -3),
            0,
            "all-negative reconciliation returns 0"
        )
        XCTAssertEqual(
            TokenUsage.reconcileCachedInputTokens(supplied: -10, creation: 20, read: 30),
            50,
            "negative supplied but positive explicit returns explicit sum"
        )
    }

    func testReconcileAppliedIdenticallyByTokenUsageInitAndTelemetryRunInit() {
        // Both callers should produce the same reconciled cached-input total
        // given the same inputs. Lock in the "one rule, two wrappers" shape
        // introduced in W2.2.
        let usage = TokenUsage(
            inputTokens: 0,
            cacheCreationInputTokens: 30,
            cacheReadInputTokens: 40,
            cachedInputTokens: 10
        )
        let run = TelemetryRun(
            id: "run-1",
            sessionID: "s",
            provider: "claude",
            cwd: "/tmp",
            startedAt: Date(timeIntervalSince1970: 0),
            totalInputTokens: nil,
            totalCacheCreationInputTokens: 30,
            totalCacheReadInputTokens: 40,
            totalCachedInputTokens: 10,
            totalOutputTokens: nil,
            totalReasoningOutputTokens: nil,
            costUSD: nil,
            tokenUsageSource: .unknown,
            tokenUsageState: .missing,
            costSource: .unavailable,
            costState: .missing,
            turnCount: 0,
            tags: [],
            metadata: [:]
        )
        XCTAssertEqual(usage.cachedInputTokens, 70)
        XCTAssertEqual(run.totalCachedInputTokens, 70)
    }
}
