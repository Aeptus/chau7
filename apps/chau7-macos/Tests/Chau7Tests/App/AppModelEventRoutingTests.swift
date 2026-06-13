import XCTest
import AppKit
import Chau7Core
@testable import Chau7

@MainActor
final class AppModelEventRoutingTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // NotificationManager's focus-refresh path calls
        // UNUserNotificationCenter.current(), which crashes in test
        // processes without a real bundle. Force isolated-test mode so
        // the manager skips platform delivery (mirrors
        // NotificationServicesTests).
        setenv("CHAU7_ISOLATED_TEST_MODE", "1", 1)
        // The delivery pipeline reads `NSApp.isActive`; NSApp is nil in a
        // bare swiftpm test process until NSApplication is instantiated.
        _ = NSApplication.shared
    }

    /// `AppModel.publishUnifiedEventOnMain` routes every recorded event
    /// through `notifications?.manager.processUnifiedEvent` and silently
    /// drops the event when no notification services are attached. Event
    /// routing tests therefore need a real (headless) pipeline.
    private func makeModel() -> AppModel {
        AppModel(notifications: NotificationServices())
    }

    /// Polls the main run loop until `condition` is true or `timeout` elapses.
    /// Returns the final state of the condition so callers can assert on it.
    @discardableResult
    private func waitUntil(timeout: TimeInterval = 5.0, condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        return condition()
    }

    /// Drains the main run loop for a fixed interval — used for negative
    /// assertions ("nothing further was emitted") after the positive signal
    /// has already been observed.
    private func drainMainQueue(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    func testRecordEventEagerlyResolvesTabIDFromSessionContext() {
        let model = makeModel()
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

        XCTAssertTrue(
            waitUntil { model.recentEvents.last?.tabID == expectedTabID },
            "recordEvent should append the event with the resolved tab ID on the main queue"
        )
        XCTAssertEqual(
            capturedTarget,
            TabTarget(
                tool: "Codex",
                directory: "/tmp/chau7",
                tabID: nil,
                sessionID: "019d25d0-d0bd-7501-99ba-1f937c17b29b"
            )
        )
    }

    func testRecordEventDoesNotReResolveExplicitTabID() {
        let model = makeModel()
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

        XCTAssertTrue(
            waitUntil { model.recentEvents.last?.tabID == explicitTabID },
            "recordEvent should keep the explicit tab ID"
        )
        XCTAssertEqual(resolverCallCount, 0)
    }

    func testClaudeResponseCompleteEmitsWaitingInputFallbackWhenNoHookNotificationArrives() {
        let model = makeModel()
        // The fallback path resolves its tab ID via
        // `authoritativeClaudeTabID`, which honours an explicit stamped
        // tab ID on the event (the generic `tabIDResolver` is not consulted
        // for Claude-sourced events). Stamp the tab ID so the fallback
        // event carries it deterministically without needing a live runtime
        // session registration.
        let expectedTabID = UUID()
        model.claudeWaitingInputFallbackDelay = 0.01

        let event = ClaudeCodeEvent(
            type: .responseComplete,
            hook: "Stop",
            sessionId: "claude-session-1",
            transcriptPath: "/tmp/transcript.jsonl",
            toolName: "Write",
            message: "done",
            cwd: "/tmp/chau7",
            tabID: expectedTabID.uuidString,
            timestamp: Date()
        )

        model.handleClaudeCodeResponseComplete(event)

        XCTAssertTrue(
            waitUntil { model.recentEvents.last?.producer == "claude_response_complete_fallback" },
            "fallback waiting-input event should be emitted after the fallback delay"
        )
        let emitted = model.recentEvents.last
        XCTAssertEqual(emitted?.type, "waiting_input")
        XCTAssertEqual(emitted?.sessionID, "claude-session-1")
        XCTAssertEqual(emitted?.tabID, expectedTabID)
        XCTAssertEqual(emitted?.reliability, .fallback)
    }

    func testClaudeHookNotificationCancelsWaitingInputFallback() {
        let model = makeModel()
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

        XCTAssertTrue(
            waitUntil { model.recentEvents.contains { $0.rawType == "notification" } },
            "authoritative hook notification should be recorded"
        )
        // Drain well past the fallback delay to prove the fallback was cancelled.
        drainMainQueue(0.3)
        let fallbackEvents = model.recentEvents.filter { $0.producer == "claude_response_complete_fallback" }
        XCTAssertTrue(fallbackEvents.isEmpty)
    }

    func testAuthoritativeClaudeNotificationDoesNotUseGenericTabResolver() {
        let model = makeModel()
        var resolverCallCount = 0

        model.tabIDResolver = { _ in
            resolverCallCount += 1
            return UUID()
        }

        let notification = ClaudeCodeEvent(
            type: .notification,
            hook: "Notification",
            sessionId: "claude-session-3",
            transcriptPath: "/tmp/transcript.jsonl",
            toolName: "Write",
            title: "Claude needs your input",
            message: "Claude is waiting for your input",
            notificationType: "idle_prompt",
            cwd: "/tmp/chau7",
            timestamp: Date()
        )

        model.handleClaudeCodeMonitorEvent(notification)

        // The shared event's canonical `type` is normalised to the semantic
        // kind ("waiting_input" for an idle_prompt notification); the
        // original wire shape survives on `rawType`.
        XCTAssertTrue(
            waitUntil { model.recentEvents.last?.rawType == "notification" },
            "authoritative claude notification should be recorded"
        )
        let emitted = model.recentEvents.last
        XCTAssertEqual(emitted?.type, "waiting_input")
        XCTAssertEqual(resolverCallCount, 0)
        XCTAssertNil(emitted?.tabID)
        XCTAssertEqual(emitted?.sessionID, "claude-session-3")
    }

    func testAuthoritativeClaudeNotificationUsesStampedHookTabID() {
        let model = makeModel()
        let stampedTabID = UUID()
        var resolverCallCount = 0

        model.tabIDResolver = { _ in
            resolverCallCount += 1
            return UUID()
        }

        let notification = ClaudeCodeEvent(
            type: .notification,
            hook: "Notification",
            sessionId: "claude-session-4",
            transcriptPath: "/tmp/transcript.jsonl",
            toolName: "Write",
            title: "Claude needs your input",
            message: "Claude is waiting for your input",
            notificationType: "idle_prompt",
            cwd: "/tmp/chau7",
            tabID: stampedTabID.uuidString,
            timestamp: Date()
        )

        model.handleClaudeCodeMonitorEvent(notification)

        // See note above: canonical `type` is the semantic kind; the raw
        // wire type ("notification") survives on `rawType`.
        XCTAssertTrue(
            waitUntil { model.recentEvents.last?.rawType == "notification" },
            "authoritative claude notification should be recorded"
        )
        let emitted = model.recentEvents.last
        XCTAssertEqual(emitted?.type, "waiting_input")
        XCTAssertEqual(resolverCallCount, 0)
        XCTAssertEqual(emitted?.tabID, stampedTabID)
        XCTAssertEqual(emitted?.sessionID, "claude-session-4")
    }
}
