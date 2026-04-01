import XCTest
#if !SWIFT_PACKAGE
@testable import Chau7

@MainActor
final class AppModelEventRoutingTests: XCTestCase {
    func testRecordEventEagerlyResolvesTabIDFromSessionContext() {
        let model = AppModel()
        let expectedTabID = UUID()
        var capturedTarget: TabTarget?

        model.tabIDResolver = { target in
            capturedTarget = target
            return expectedTabID
        }

        model.recordEvent(
            source: .historyMonitor,
            type: "finished",
            tool: "Codex",
            message: "Codex finished",
            notify: false,
            directory: "/tmp/chau7",
            sessionID: "019d25d0-d0bd-7501-99ba-1f937c17b29b"
        )

        let expectationDone = expectation(description: "recordEvent appended on main queue")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            XCTAssertEqual(
                capturedTarget,
                TabTarget(
                    tool: "Codex",
                    directory: "/tmp/chau7",
                    tabID: nil,
                    sessionID: "019d25d0-d0bd-7501-99ba-1f937c17b29b"
                )
            )
            XCTAssertEqual(model.recentEvents.last?.tabID, expectedTabID)
            expectationDone.fulfill()
        }

        wait(for: [expectationDone], timeout: 1.0)
    }

    func testRecordEventDoesNotReResolveExplicitTabID() {
        let model = AppModel()
        let explicitTabID = UUID()
        var resolverCallCount = 0

        model.tabIDResolver = { _ in
            resolverCallCount += 1
            return UUID()
        }

        model.recordEvent(
            source: .terminalSession,
            type: "finished",
            tool: "Codex",
            message: "done",
            notify: false,
            directory: "/tmp/chau7",
            tabID: explicitTabID,
            sessionID: "019d25d0-d0bd-7501-99ba-1f937c17b29b"
        )

        let expectationDone = expectation(description: "recordEvent kept explicit tab id")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            XCTAssertEqual(resolverCallCount, 0)
            XCTAssertEqual(model.recentEvents.last?.tabID, explicitTabID)
            expectationDone.fulfill()
        }

        wait(for: [expectationDone], timeout: 1.0)
    }

    func testClaudeResponseCompleteEmitsWaitingInputFallbackWhenNoHookNotificationArrives() {
        let model = AppModel()
        let expectedTabID = UUID()
        model.claudeWaitingInputFallbackDelay = 0.01
        model.tabIDResolver = { target in
            XCTAssertEqual(target.tool, "Claude")
            XCTAssertEqual(target.sessionID, "claude-session-1")
            return expectedTabID
        }

        let event = ClaudeCodeEvent(
            type: .responseComplete,
            hook: "Stop",
            sessionId: "claude-session-1",
            transcriptPath: "/tmp/transcript.jsonl",
            toolName: "Write",
            message: "done",
            cwd: "/tmp/chau7",
            timestamp: Date()
        )

        model.handleClaudeCodeResponseComplete(event)

        let expectationDone = expectation(description: "fallback waiting-input emitted")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            let emitted = model.recentEvents.last
            XCTAssertEqual(emitted?.type, "waiting_input")
            XCTAssertEqual(emitted?.sessionID, "claude-session-1")
            XCTAssertEqual(emitted?.tabID, expectedTabID)
            XCTAssertEqual(emitted?.producer, "claude_response_complete_fallback")
            XCTAssertEqual(emitted?.reliability, .fallback)
            expectationDone.fulfill()
        }

        wait(for: [expectationDone], timeout: 1.0)
    }

    func testClaudeHookNotificationCancelsWaitingInputFallback() {
        let model = AppModel()
        model.claudeWaitingInputFallbackDelay = 0.05

        let response = ClaudeCodeEvent(
            type: .responseComplete,
            hook: "Stop",
            sessionId: "claude-session-2",
            transcriptPath: "/tmp/transcript.jsonl",
            toolName: "Write",
            message: "done",
            cwd: "/tmp/chau7",
            timestamp: Date()
        )
        let notification = ClaudeCodeEvent(
            type: .notification,
            hook: "Notification",
            sessionId: "claude-session-2",
            transcriptPath: "/tmp/transcript.jsonl",
            toolName: "Write",
            title: "Claude needs your input",
            message: "Claude is waiting for your input",
            notificationType: "idle_prompt",
            cwd: "/tmp/chau7",
            timestamp: Date()
        )

        model.handleClaudeCodeResponseComplete(response)
        model.handleClaudeCodeMonitorEvent(notification)

        let expectationDone = expectation(description: "no fallback emitted after authoritative hook")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            let fallbackEvents = model.recentEvents.filter { $0.producer == "claude_response_complete_fallback" }
            XCTAssertTrue(fallbackEvents.isEmpty)
            XCTAssertTrue(model.recentEvents.contains { $0.rawType == "notification" })
            expectationDone.fulfill()
        }

        wait(for: [expectationDone], timeout: 1.0)
    }
}
#endif
