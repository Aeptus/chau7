import XCTest
@testable import Chau7Core

final class TelemetryMetricsSanitizerTests: XCTestCase {
    func testSanitize_marksMissingWhenNoTokensArePresent() {
        let content = ExtractedRunContent(
            turns: [TelemetryTurn(runID: "run-1", turnIndex: 0, role: .assistant, content: "hi")],
            tokenUsageSource: .transcriptDelta,
            tokenUsageState: .complete,
            costSource: .unavailable,
            costState: .missing
        )

        let result = TelemetryMetricsSanitizer.sanitize(content, provider: "claude")

        XCTAssertNil(result.content.totalInputTokens)
        XCTAssertEqual(result.content.tokenUsageState, .missing)
        XCTAssertNil(result.warning)
    }

    func testSanitize_invalidatesImplausibleTokenTotals() {
        let content = ExtractedRunContent(
            turns: [TelemetryTurn(runID: "run-1", turnIndex: 0, role: .assistant, content: "hi")],
            totalInputTokens: 1_200_000_000,
            totalOutputTokens: 10,
            costUSD: 12.34,
            tokenUsageSource: .transcriptDelta,
            tokenUsageState: .complete,
            costSource: .estimated,
            costState: .complete
        )

        let result = TelemetryMetricsSanitizer.sanitize(content, provider: "codex")

        XCTAssertEqual(result.content.tokenUsageState, .invalid)
        XCTAssertEqual(result.content.costState, .missing)
        XCTAssertNil(result.content.totalInputTokens)
        XCTAssertNil(result.content.costUSD)
        XCTAssertNotNil(result.warning)
    }

    func testSanitize_keepsLargeButPlausibleTranscriptTotals() {
        let content = ExtractedRunContent(
            turns: [TelemetryTurn(runID: "run-2", turnIndex: 0, role: .assistant, content: "hi")],
            totalInputTokens: 802_504,
            totalCacheCreationInputTokens: 9_541_997,
            totalCacheReadInputTokens: 181_895_638,
            totalOutputTokens: 726_929,
            costUSD: 123.45,
            tokenUsageSource: .transcriptDelta,
            tokenUsageState: .complete,
            costSource: .estimated,
            costState: .complete
        )

        let result = TelemetryMetricsSanitizer.sanitize(content, provider: "claude")

        XCTAssertEqual(result.content.tokenUsageState, .complete)
        XCTAssertEqual(result.content.costState, .complete)
        XCTAssertEqual(result.content.totalCacheReadInputTokens, 181_895_638)
        XCTAssertEqual(result.content.costUSD, 123.45)
        XCTAssertNil(result.warning)
    }
}
