#if !SWIFT_PACKAGE
import XCTest
@testable import Chau7

final class RuntimeSessionBehaviorTests: XCTestCase {
    func testDuplicateCompleteTurnLeavesSessionReady() {
        let session = RuntimeSession(
            tabID: UUID(),
            backend: ClaudeCodeBackend(),
            config: SessionConfig(directory: "/tmp/runtime-duplicate-complete", provider: "claude")
        )

        session.transition(.backendReady)
        XCTAssertNotNil(session.startTurn(prompt: "Hello"))

        let first = session.completeTurn(summary: "done", terminalOutput: nil)
        XCTAssertNotNil(first)
        XCTAssertEqual(session.state, .ready)

        let second = session.completeTurn(summary: "duplicate", terminalOutput: nil)
        XCTAssertNil(second)
        XCTAssertEqual(session.state, .ready)
    }

    func testTurnCompletedIncludesMatchingTurnStartedAndDuration() throws {
        let session = RuntimeSession(
            tabID: UUID(),
            backend: ClaudeCodeBackend(),
            config: SessionConfig(directory: "/tmp/runtime-turn-duration", provider: "claude")
        )

        session.transition(.backendReady)
        let turnID = try XCTUnwrap(session.startTurn(prompt: "Hello"))
        let result = session.completeTurn(summary: "done", terminalOutput: nil)

        XCTAssertNotNil(result)
        let events = session.journal.events(forTurn: turnID)
        let started = events.first { $0.type == RuntimeEventType.turnStarted.rawValue }
        let completed = events.first { $0.type == RuntimeEventType.turnCompleted.rawValue }
        XCTAssertNotNil(started)
        XCTAssertNotNil(completed)
        XCTAssertEqual(completed?.turnID, started?.turnID)
        XCTAssertNotNil(completed?.data["turn_duration_ms"])
    }

    func testJournalUserInputCapturesCurrentTurnAndPromptPreview() throws {
        let session = RuntimeSession(
            tabID: UUID(),
            backend: ClaudeCodeBackend(),
            config: SessionConfig(directory: "/tmp/runtime-user-input", provider: "claude")
        )

        session.transition(.backendReady)
        let turnID = try XCTUnwrap(session.startTurn(prompt: "Hello"))
        session.journalUserInput(prompt: String(repeating: "x", count: 520), correlationID: "corr-user-input")

        let userInput = try XCTUnwrap(
            session.journal.events(forTurn: turnID).first { $0.type == RuntimeEventType.userInput.rawValue }
        )
        XCTAssertEqual(userInput.turnID, turnID)
        XCTAssertEqual(userInput.correlationID, "corr-user-input")
        XCTAssertEqual(userInput.data["prompt_length"], "520")
        XCTAssertEqual(userInput.data["prompt_preview"]?.count, 500)
    }

    func testSuppressProviderUserPromptEchoConsumesOnlyMatchingRuntimePrompt() throws {
        let session = RuntimeSession(
            tabID: UUID(),
            backend: ClaudeCodeBackend(),
            config: SessionConfig(directory: "/tmp/runtime-user-echo", provider: "claude")
        )

        session.transition(.backendReady)
        _ = try XCTUnwrap(session.startTurn(prompt: "status"))

        XCTAssertTrue(session.shouldSuppressProviderUserPromptEcho(prompt: "status"))
        XCTAssertFalse(session.shouldSuppressProviderUserPromptEcho(prompt: "status"))
        XCTAssertFalse(session.shouldSuppressProviderUserPromptEcho(prompt: "different"))
    }

    func testDuplicateApprovalRequestWithoutActiveTurnIsIgnored() {
        let session = RuntimeSession(
            tabID: UUID(),
            backend: ClaudeCodeBackend(),
            config: SessionConfig(directory: "/tmp/runtime-duplicate-approval", provider: "claude")
        )

        session.transition(.backendReady)
        let approval = session.requestApproval(tool: "Read", description: "Need approval")

        XCTAssertNil(approval)
        XCTAssertEqual(session.state, .ready)
        XCTAssertNil(session.pendingApproval)
    }

    func testApprovalTimeoutFailsTurnAndClearsPendingTurnState() {
        let session = RuntimeSession(
            tabID: UUID(),
            backend: ClaudeCodeBackend(),
            config: SessionConfig(directory: "/tmp/runtime-approval-timeout", provider: "claude")
        )

        session.transition(.backendReady)
        XCTAssertNotNil(session.startTurn(prompt: "Need approval"))
        XCTAssertNotNil(session.requestApproval(tool: "Read", description: "Need approval"))

        session.handleApprovalTimeout()

        XCTAssertEqual(session.state, .ready)
        XCTAssertNil(session.pendingApproval)
        XCTAssertNil(session.currentTurnID)

        let failureEvents = session.journal
            .events(after: 0, limit: 100)
            .events
            .filter { $0.type == RuntimeEventType.turnFailed.rawValue }
        XCTAssertEqual(failureEvents.count, 1)
        XCTAssertEqual(failureEvents.first?.data?["reason"], "approval_timeout")
    }

    func testRepeatedApprovalTimeoutsMarkSessionFailed() {
        let session = RuntimeSession(
            tabID: UUID(),
            backend: ClaudeCodeBackend(),
            config: SessionConfig(directory: "/tmp/runtime-approval-stuck", provider: "claude")
        )

        session.transition(.backendReady)

        for attempt in 1 ... 3 {
            XCTAssertNotNil(session.startTurn(prompt: "Need approval \(attempt)"))
            XCTAssertNotNil(session.requestApproval(tool: "Read", description: "Need approval"))
            session.handleApprovalTimeout()
        }

        XCTAssertEqual(session.state, .failed)
        XCTAssertNil(session.pendingApproval)
        XCTAssertNil(session.currentTurnID)

        let events = session.journal.events(after: 0, limit: 100).events
        let sessionErrors = events.filter { $0.type == RuntimeEventType.sessionError.rawValue }
        XCTAssertEqual(sessionErrors.count, 1)
        XCTAssertEqual(sessionErrors.first?.data?["reason"], "approval_timeout_stuck")
        XCTAssertEqual(sessionErrors.first?.data?["approval_timeout_count"], "3")
    }

    func testCompleteTurnAccumulatesLiveUsageAndEstimatedCost() throws {
        let session = RuntimeSession(
            tabID: UUID(),
            backend: ClaudeCodeBackend(),
            config: SessionConfig(
                directory: "/tmp/runtime-live-usage",
                provider: "claude",
                model: "claude-sonnet-4"
            )
        )

        session.transition(.backendReady)
        _ = try XCTUnwrap(session.startTurn(prompt: "Hello"))
        session.addTokens(input: 1_000_000, output: 200_000, cacheCreation: 100_000, cacheRead: 300_000, reasoningOutput: 50000)

        let result = try XCTUnwrap(session.completeTurn(summary: "done", terminalOutput: nil))

        XCTAssertGreaterThanOrEqual(result.durationMs, 0)
        XCTAssertEqual(session.completedTurnCount, 1)
        XCTAssertEqual(session.cumulativeTokenUsage.inputTokens, 1_000_000)
        XCTAssertEqual(session.cumulativeTokenUsage.cachedInputTokens, 400_000)
        XCTAssertEqual(session.cumulativeTokenUsage.outputTokens, 200_000)
        XCTAssertEqual(session.cumulativeTokenUsage.reasoningOutputTokens, 50000)
        XCTAssertEqual(try XCTUnwrap(result.estimatedCostUSD), 7.215, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(session.estimatedCostUSD), 7.215, accuracy: 0.0001)
        XCTAssertNotNil(session.lastTurnCompletedAt)
        XCTAssertGreaterThan(session.activeDurationMs, -1)
    }

    func testCostThresholdsOnlyEmitOncePerSession() {
        let session = RuntimeSession(
            tabID: UUID(),
            backend: ClaudeCodeBackend(),
            config: SessionConfig(
                directory: "/tmp/runtime-thresholds",
                provider: "claude",
                model: "claude-sonnet-4"
            )
        )

        session.transition(.backendReady)
        _ = session.startTurn(prompt: "Hello")
        session.addTokens(input: 500_000, output: 0, cacheCreation: 0, cacheRead: 0)
        _ = session.completeTurn(summary: "done", terminalOutput: nil)

        XCTAssertEqual(session.consumeCrossedCostThresholds([1, 5, 10]), [1])
        XCTAssertTrue(session.consumeCrossedCostThresholds([1, 5, 10]).isEmpty)
    }

    func testCompletedTurnSnapshotPreservesLastFinishedTurnStats() throws {
        let session = RuntimeSession(
            tabID: UUID(),
            backend: ClaudeCodeBackend(),
            config: SessionConfig(
                directory: "/tmp/runtime-last-turn-snapshot",
                provider: "claude",
                model: "claude-sonnet-4"
            )
        )

        session.transition(.backendReady)
        _ = try XCTUnwrap(session.startTurn(prompt: "Hello"))
        session.recordToolUse(name: "Edit", file: "Sources/App.swift")
        session.addTokens(input: 100, output: 25, cacheCreation: 10, cacheRead: 5, reasoningOutput: 3)
        _ = try XCTUnwrap(session.completeTurn(summary: "done", terminalOutput: nil))

        let snapshot = try XCTUnwrap(session.lastCompletedTurnSnapshot)
        XCTAssertEqual(snapshot.stats.inputTokens, 100)
        XCTAssertEqual(snapshot.stats.outputTokens, 25)
        XCTAssertEqual(snapshot.stats.reasoningOutputTokens, 3)
        XCTAssertEqual(snapshot.stats.cacheCreationTokens, 10)
        XCTAssertEqual(snapshot.stats.cacheReadTokens, 5)
        XCTAssertEqual(snapshot.stats.toolTallies["Edit"]?.count, 1)
        XCTAssertEqual(snapshot.exitReason, .success)
        XCTAssertGreaterThanOrEqual(snapshot.durationMs, 0)
    }
}
#endif
