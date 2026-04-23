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
}
