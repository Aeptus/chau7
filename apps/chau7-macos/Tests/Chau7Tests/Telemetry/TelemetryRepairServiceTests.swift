import XCTest
@testable import Chau7
@testable import Chau7Core

final class TelemetryRepairServiceTests: XCTestCase {
    func testInitialExtractionExcludesPeriodicAndExplicitRepairUntilReleased() throws {
        let provider = DelayedProvider(providerName: "codex-initial-\(UUID())")
        provider.ready = true
        let service = TelemetryRepairService(providers: [provider])
        let run = TelemetryRun(
            id: "initial-extraction-\(UUID())", sessionID: "session", provider: provider.providerName,
            cwd: "/tmp", startedAt: Date(), endedAt: Date(), rawTranscriptRef: "pty_log"
        )
        XCTAssertTrue(service.beginInitialExtraction(runID: run.id))
        XCTAssertFalse(service.beginInitialExtraction(runID: run.id))
        TelemetryStore.shared.insertRun(run)
        XCTAssertEqual(service.rebuildRunIfNeeded(runID: run.id), .skipped)
        _ = service.rebuildRecentIncompleteRuns()
        XCTAssertEqual(provider.calls, 0, "initial extraction must exclude periodic repair too")
        XCTAssertNil(try XCTUnwrap(TelemetryStore.shared.getRun(run.id)).transcriptRepairAttemptedAt)
        service.finishInitialExtraction(runID: run.id)
        XCTAssertEqual(service.rebuildRunIfNeeded(runID: run.id), .rebuilt)
        XCTAssertEqual(provider.calls, 1)
    }

    func testMissingTranscriptDoesNotLatchCompletedAndCanRecoverAfterFlush() throws {
        let provider = DelayedProvider()
        var now = Date()
        let service = TelemetryRepairService(providers: [provider], now: { now })
        let run = TelemetryRun(
            id: "delayed-repair-\(UUID())",
            sessionID: "session",
            provider: "codex",
            cwd: "/tmp",
            startedAt: now.addingTimeInterval(-10),
            endedAt: now,
            costSource: .unavailable,
            rawTranscriptRef: "pty_log"
        )
        TelemetryStore.shared.insertRun(run)
        XCTAssertEqual(service.rebuildRunIfNeeded(runID: run.id), .skipped)
        XCTAssertNil(try XCTUnwrap(TelemetryStore.shared.getRun(run.id)).transcriptRepairAttemptedAt)
        XCTAssertEqual(service.rebuildRunIfNeeded(runID: run.id), .skipped)
        XCTAssertEqual(provider.calls, 1, "immediate sweeps must respect failure backoff")
        provider.ready = true
        now = now.addingTimeInterval(8)
        XCTAssertEqual(service.rebuildRunIfNeeded(runID: run.id), .rebuilt)
        XCTAssertEqual(provider.calls, 2)
        let repaired = try XCTUnwrap(TelemetryStore.shared.getRun(run.id))
        XCTAssertNotNil(repaired.transcriptRepairAttemptedAt)
        XCTAssertEqual(repaired.totalInputTokens, 123)
        XCTAssertFalse(TelemetryRepairService.needsTranscriptRepair(repaired))
    }

    private final class DelayedProvider: RunContentProvider, @unchecked Sendable {
        let providerName: String
        var calls = 0
        var ready = false
        init(providerName: String = "codex") {
            self.providerName = providerName
        }

        func canHandle(provider: String) -> Bool {
            provider == providerName
        }

        func extractContent(runID: String, sessionID: String?, cwd: String, startedAt: Date, endedAt: Date?) -> ExtractedRunContent? {
            calls += 1
            return ready ? ExtractedRunContent(totalInputTokens: 123, tokenUsageState: .complete, rawTranscriptRef: "/synthetic/transcript.jsonl") : nil
        }
    }

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

    func testLegacyFailedAttemptWithNoTranscriptRemainsRecoverable() {
        let run = TelemetryRun(
            id: "run-1",
            sessionID: "session-1",
            provider: "claude",
            cwd: "/tmp/chau7",
            startedAt: Date(timeIntervalSince1970: 1_765_000_000),
            endedAt: Date(timeIntervalSince1970: 1_765_000_100),
            costSource: .unavailable,
            costState: .missing,
            rawTranscriptRef: "pty_log",
            transcriptRepairAttemptedAt: Date(timeIntervalSince1970: 1_765_000_200)
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
