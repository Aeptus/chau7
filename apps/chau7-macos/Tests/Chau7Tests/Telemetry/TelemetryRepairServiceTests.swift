import XCTest
@testable import Chau7
@testable import Chau7Core

final class TelemetryRepairServiceTests: XCTestCase {
    func testNeedsTranscriptRepairForFallbackClaudeRun() {
        let run = TelemetryRun(
            id: "run-1",
            sessionID: "session-1",
            provider: "claude",
            cwd: "/tmp/chau7",
            startedAt: Date(timeIntervalSince1970: 1_765_000_000),
            endedAt: Date(timeIntervalSince1970: 1_765_000_100),
            costSource: .unavailable,
            costState: .missing,
            rawTranscriptRef: "pty_log"
        )

        XCTAssertTrue(TelemetryRepairService.needsTranscriptRepair(run))
    }

    func testDoesNotNeedTranscriptRepairWithoutSessionID() {
        let run = TelemetryRun(
            id: "run-2",
            provider: "claude",
            cwd: "/tmp/chau7",
            startedAt: Date(timeIntervalSince1970: 1_765_000_000),
            endedAt: Date(timeIntervalSince1970: 1_765_000_100),
            costSource: .unavailable,
            costState: .missing,
            rawTranscriptRef: "pty_log"
        )

        XCTAssertFalse(TelemetryRepairService.needsTranscriptRepair(run))
    }

    func testDoesNotNeedTranscriptRepairForObservedProxyRun() {
        let run = TelemetryRun(
            id: "run-3",
            sessionID: "session-3",
            provider: "openai",
            cwd: "/tmp/chau7",
            startedAt: Date(timeIntervalSince1970: 1_765_000_000),
            endedAt: Date(timeIntervalSince1970: 1_765_000_100),
            totalInputTokens: 100,
            totalOutputTokens: 50,
            costUSD: 1.25,
            tokenUsageSource: .proxy,
            tokenUsageState: .complete,
            costSource: .observed,
            costState: .complete,
            rawTranscriptRef: "/tmp/chau7/transcript.jsonl"
        )

        XCTAssertFalse(TelemetryRepairService.needsTranscriptRepair(run))
    }
}
