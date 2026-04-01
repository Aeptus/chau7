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
            totalInputTokens: 120_000_000,
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
}
