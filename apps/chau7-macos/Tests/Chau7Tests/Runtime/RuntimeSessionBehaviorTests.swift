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
}
#endif
