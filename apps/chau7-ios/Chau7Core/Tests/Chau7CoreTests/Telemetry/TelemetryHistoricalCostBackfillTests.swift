import XCTest
@testable import Chau7Core

final class TelemetryHistoricalCostBackfillTests: XCTestCase {
    func testRepairedRunBackfillsMissingCostForKnownOpenAIModel() throws {
        let run = TelemetryRun(
            provider: "codex",
            model: "gpt-5.4",
            cwd: "/tmp",
            totalInputTokens: 1_000_000,
            totalCachedInputTokens: 500_000,
            totalOutputTokens: 100_000,
            totalReasoningOutputTokens: 25000,
            tokenUsageState: .complete,
            costSource: .unavailable,
            costState: .missing
        )

        let repaired = try XCTUnwrap(TelemetryHistoricalCostBackfill.repairedRun(run))
        XCTAssertEqual(repaired.costSource, .estimated)
        XCTAssertEqual(repaired.costState, .estimated)
        XCTAssertEqual(try XCTUnwrap(repaired.costUSD), 4.5, accuracy: 0.0001)
    }

    func testRepairedRunLeavesAlreadyPricedRunUntouched() {
        let run = TelemetryRun(
            provider: "codex",
            model: "gpt-5.4",
            cwd: "/tmp",
            totalInputTokens: 100,
            totalOutputTokens: 50,
            costUSD: 0.42,
            tokenUsageState: .complete,
            costSource: .estimated,
            costState: .estimated
        )

        XCTAssertNil(TelemetryHistoricalCostBackfill.repairedRun(run))
    }

    func testRepairedRunIgnoresInvalidTelemetry() {
        let run = TelemetryRun(
            provider: "codex",
            model: "gpt-5.4",
            cwd: "/tmp",
            totalInputTokens: 1_000_000,
            tokenUsageState: .invalid,
            costSource: .unavailable,
            costState: .missing
        )

        XCTAssertNil(TelemetryHistoricalCostBackfill.repairedRun(run))
    }
}
