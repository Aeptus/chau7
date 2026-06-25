import XCTest
@testable import Chau7Core

final class AISessionEventReconcilerTests: XCTestCase {
    func testDropsDuplicateWaitingInputForSameSessionAcrossProducers() {
        let reconciler = AISessionEventReconciler()
        let first = acceptedEvent(
            type: "waiting_input",
            kind: .waitingForInput,
            sessionID: "SESSION-1",
            producer: "terminal_wait_pattern_attention",
            reliability: .heuristic
        )
        let second = acceptedEvent(
            type: "waiting_input",
            kind: .waitingForInput,
            sessionID: "session-1",
            producer: "claude_code_monitor",
            reliability: .authoritative
        )

        XCTAssertEqual(reconciler.reconcile(first), .emit(first))
        switch reconciler.reconcile(second, now: Date().addingTimeInterval(1)) {
        case .drop(let reason):
            XCTAssertTrue(reason.contains("duplicate session state"))
        case .emit:
            XCTFail("Duplicate waiting_input should not emit a second notification")
        }
    }

    func testAllowsStrongerSameStateReplacementInsideCoalescingWindow() {
        let reconciler = AISessionEventReconciler()
        let now = Date()
        let fallback = acceptedEvent(
            type: "finished",
            kind: .taskFinished,
            sessionID: "SESSION-1",
            producer: "history_idle_monitor",
            reliability: .fallback
        )
        let authoritative = acceptedEvent(
            type: "finished",
            kind: .taskFinished,
            sessionID: "session-1",
            producer: "codex_notify_hook",
            reliability: .authoritative
        )

        XCTAssertEqual(reconciler.reconcile(fallback, now: now), .emit(fallback))
        XCTAssertEqual(
            reconciler.reconcile(authoritative, now: now.addingTimeInterval(0.05)),
            .emit(authoritative)
        )
    }

    func testSuppressesImmediateDuplicateAuthoritativeTerminalState() {
        let reconciler = AISessionEventReconciler(terminalRepeatWindow: 10)
        let now = Date()
        let first = acceptedEvent(
            type: "finished",
            kind: .taskFinished,
            sessionID: "SESSION-1",
            producer: "codex_notify_hook",
            reliability: .authoritative
        )
        let duplicate = acceptedEvent(
            type: "finished",
            kind: .taskFinished,
            sessionID: "session-1",
            producer: "codex_notify_hook",
            reliability: .authoritative
        )

        XCTAssertEqual(reconciler.reconcile(first, now: now), .emit(first))
        switch reconciler.reconcile(duplicate, now: now.addingTimeInterval(1)) {
        case .drop(let reason):
            XCTAssertTrue(reason.contains("Duplicate terminal session state finished"))
        case .emit:
            XCTFail("Immediate duplicate terminal events should remain suppressed")
        }
    }

    func testAllowsLaterAuthoritativeTerminalStateForSameLongLivedSession() {
        let reconciler = AISessionEventReconciler(terminalRepeatWindow: 10)
        let now = Date()
        let first = acceptedEvent(
            type: "finished",
            kind: .taskFinished,
            sessionID: "SESSION-1",
            producer: "codex_notify_hook",
            reliability: .authoritative
        )
        let nextTurn = acceptedEvent(
            type: "finished",
            kind: .taskFinished,
            sessionID: "session-1",
            producer: "codex_notify_hook",
            reliability: .authoritative
        )

        XCTAssertEqual(reconciler.reconcile(first, now: now), .emit(first))
        XCTAssertEqual(
            reconciler.reconcile(nextTurn, now: now.addingTimeInterval(11)),
            .emit(nextTurn)
        )
    }

    func testSuppressesDelayedStrongerTerminalReplacementAsSameCompletion() {
        let reconciler = AISessionEventReconciler(terminalRepeatWindow: 10)
        let now = Date()
        let fallback = acceptedEvent(
            type: "finished",
            kind: .taskFinished,
            sessionID: "SESSION-1",
            producer: "history_idle_monitor",
            reliability: .fallback
        )
        let authoritative = acceptedEvent(
            type: "finished",
            kind: .taskFinished,
            sessionID: "session-1",
            producer: "codex_notify_hook",
            reliability: .authoritative
        )

        XCTAssertEqual(reconciler.reconcile(fallback, now: now), .emit(fallback))
        switch reconciler.reconcile(authoritative, now: now.addingTimeInterval(11)) {
        case .drop(let reason):
            XCTAssertTrue(reason.contains("Updated stronger duplicate session state"))
        case .emit:
            XCTFail("Delayed stronger replacement should update state without re-notifying")
        }
    }

    func testSuppressesFallbackAttentionAfterTerminalState() {
        let reconciler = AISessionEventReconciler()
        let finished = acceptedEvent(
            type: "finished",
            kind: .taskFinished,
            sessionID: "SESSION-1",
            producer: "codex_notify_hook",
            reliability: .authoritative
        )
        let staleWaiting = acceptedEvent(
            type: "waiting_input",
            kind: .waitingForInput,
            sessionID: "session-1",
            producer: "history_idle_monitor",
            reliability: .fallback
        )

        XCTAssertEqual(reconciler.reconcile(finished), .emit(finished))
        switch reconciler.reconcile(staleWaiting) {
        case .drop(let reason):
            XCTAssertTrue(reason.contains("Stale post-terminal"))
        case .emit:
            XCTFail("Fallback attention after finished should be suppressed")
        }
    }

    func testAuthoritativePermissionReopensFinishedSessionWithoutLifecycleEvent() {
        // Codex emits no raw lifecycle (tool_start/session_start) events, so a
        // finished session was never reopened and every later permission prompt
        // was dropped as "Stale post-terminal". An authoritative attention
        // signal must reopen the session on its own.
        let reconciler = AISessionEventReconciler()
        let finished = acceptedEvent(
            type: "finished",
            kind: .taskFinished,
            sessionID: "SESSION-1",
            producer: "codex_notify_hook",
            reliability: .authoritative
        )
        let nextTurnPermission = acceptedEvent(
            type: "permission",
            kind: .permissionRequired,
            sessionID: "session-1",
            producer: "codex_notify_hook",
            reliability: .authoritative
        )

        XCTAssertEqual(reconciler.reconcile(finished), .emit(finished))
        switch reconciler.reconcile(nextTurnPermission, now: Date().addingTimeInterval(1)) {
        case .emit(let event):
            XCTAssertEqual(event, nextTurnPermission)
        case .drop(let reason):
            XCTFail("Authoritative permission after finished should reopen the session, got drop: \(reason)")
        }
    }

    func testReopenedSessionStillDedupesRepeatedPermission() {
        // Reopening must not re-arm duplicate suppression: a second identical
        // pending permission for the same unanswered prompt stays deduped.
        let reconciler = AISessionEventReconciler()
        let finished = acceptedEvent(
            type: "finished",
            kind: .taskFinished,
            sessionID: "SESSION-1",
            producer: "codex_notify_hook",
            reliability: .authoritative
        )
        let permission = acceptedEvent(
            type: "permission",
            kind: .permissionRequired,
            sessionID: "session-1",
            producer: "codex_notify_hook",
            reliability: .authoritative
        )
        let duplicate = acceptedEvent(
            type: "permission",
            kind: .permissionRequired,
            sessionID: "session-1",
            producer: "codex_notify_hook",
            reliability: .authoritative
        )

        XCTAssertEqual(reconciler.reconcile(finished), .emit(finished))
        guard case .emit = reconciler.reconcile(permission, now: Date().addingTimeInterval(1)) else {
            return XCTFail("First post-terminal permission should reopen and emit")
        }
        switch reconciler.reconcile(duplicate, now: Date().addingTimeInterval(2)) {
        case .drop(let reason):
            XCTAssertTrue(reason.contains("Duplicate session state"))
        case .emit:
            XCTFail("Repeated identical permission should remain deduped after reopen")
        }
    }

    func testRawRunningObservationReopensFinishedSession() {
        let reconciler = AISessionEventReconciler()
        let finished = acceptedEvent(
            type: "finished",
            kind: .taskFinished,
            sessionID: "SESSION-1",
            producer: "codex_notify_hook",
            reliability: .authoritative
        )
        let running = AIEvent(
            source: .codex,
            type: "user_prompt",
            rawType: "user_prompt",
            tool: "Codex",
            message: "new prompt",
            ts: "2026-04-01T00:00:01Z",
            sessionID: "session-1",
            producer: "codex_notify_hook",
            reliability: .authoritative
        )
        let nextWaiting = acceptedEvent(
            type: "waiting_input",
            kind: .waitingForInput,
            sessionID: "session-1",
            producer: "codex_notify_hook",
            reliability: .authoritative
        )

        XCTAssertEqual(reconciler.reconcile(finished), .emit(finished))
        XCTAssertNotNil(reconciler.observeRawEvent(running))
        XCTAssertEqual(reconciler.reconcile(nextWaiting), .emit(nextWaiting))
    }

    func testSessionAliasBeatsTabAliasForSameEventIdentity() {
        let reconciler = AISessionEventReconciler()
        let tabID = UUID()
        let first = acceptedEvent(
            type: "permission",
            kind: .permissionRequired,
            sessionID: "SESSION-1",
            tabID: tabID,
            producer: "claude_code_monitor",
            reliability: .authoritative
        )
        let second = acceptedEvent(
            type: "permission",
            kind: .permissionRequired,
            sessionID: "session-1",
            producer: "terminal_osc9",
            reliability: .authoritative
        )

        XCTAssertEqual(reconciler.reconcile(first), .emit(first))
        switch reconciler.reconcile(second) {
        case .drop(let reason):
            XCTAssertTrue(reason.contains("Duplicate session state"))
        case .emit:
            XCTFail("Session alias should dedupe even when a later event lacks tabID")
        }
    }

    func testBridgeEventMergesPreviouslySeparateTabAndSessionRecords() {
        let reconciler = AISessionEventReconciler()
        let tabID = UUID()
        let tabOnly = acceptedEvent(
            type: "permission",
            kind: .permissionRequired,
            sessionID: nil,
            tabID: tabID,
            producer: "terminal_osc9",
            reliability: .authoritative
        )
        let sessionOnly = acceptedEvent(
            type: "permission",
            kind: .permissionRequired,
            sessionID: "session-1",
            tabID: nil,
            producer: "claude_code_monitor",
            reliability: .authoritative
        )
        let bridge = acceptedEvent(
            type: "permission",
            kind: .permissionRequired,
            sessionID: "session-1",
            tabID: tabID,
            producer: "claude_code_monitor",
            reliability: .authoritative
        )
        let laterTabOnly = acceptedEvent(
            type: "permission",
            kind: .permissionRequired,
            sessionID: nil,
            tabID: tabID,
            producer: "terminal_osc9",
            reliability: .authoritative
        )

        XCTAssertEqual(reconciler.reconcile(tabOnly), .emit(tabOnly))
        XCTAssertEqual(reconciler.reconcile(sessionOnly), .emit(sessionOnly))

        switch reconciler.reconcile(bridge) {
        case .drop(let reason):
            XCTAssertTrue(reason.contains("Duplicate session state"))
        case .emit:
            XCTFail("Bridge event should merge aliases without emitting another notification")
        }

        switch reconciler.reconcile(laterTabOnly) {
        case .drop(let reason):
            XCTAssertTrue(reason.contains("Duplicate session state"))
        case .emit:
            XCTFail("Merged tab alias should route to the same session record")
        }
    }

    func testStrongerDuplicateOutsideCoalescingWindowUpdatesWithoutRenotifying() {
        let reconciler = AISessionEventReconciler()
        let now = Date()
        let heuristic = acceptedEvent(
            type: "waiting_input",
            kind: .waitingForInput,
            sessionID: "session-1",
            producer: "terminal_wait_pattern_attention",
            reliability: .heuristic
        )
        let authoritative = acceptedEvent(
            type: "waiting_input",
            kind: .waitingForInput,
            sessionID: "session-1",
            producer: "claude_code_monitor",
            reliability: .authoritative
        )
        let weakerDuplicate = acceptedEvent(
            type: "waiting_input",
            kind: .waitingForInput,
            sessionID: "session-1",
            producer: "terminal_wait_pattern_attention",
            reliability: .heuristic
        )

        XCTAssertEqual(reconciler.reconcile(heuristic, now: now), .emit(heuristic))
        switch reconciler.reconcile(authoritative, now: now.addingTimeInterval(1)) {
        case .drop(let reason):
            XCTAssertTrue(reason.contains("Updated stronger duplicate session state"))
        case .emit:
            XCTFail("Stronger duplicate outside the replacement window should update state without a second notification")
        }
        switch reconciler.reconcile(weakerDuplicate, now: now.addingTimeInterval(2)) {
        case .drop(let reason):
            XCTAssertTrue(reason.contains("Duplicate session state"))
        case .emit:
            XCTFail("Weaker duplicate after the authoritative update should remain suppressed")
        }
    }

    private func acceptedEvent(
        type: String,
        kind: NotificationSemanticKind,
        sessionID: String?,
        tabID: UUID? = nil,
        producer: String,
        reliability: AIEventReliability
    ) -> NotificationIngress.AcceptedEvent {
        let event = AIEvent(
            source: .codex,
            type: type,
            tool: "Codex",
            message: type,
            ts: "2026-04-01T00:00:00Z",
            tabID: tabID,
            sessionID: sessionID,
            producer: producer,
            reliability: reliability
        )
        let canonical = CanonicalNotificationEvent(
            id: event.id,
            kind: kind,
            providerID: event.source.rawValue,
            providerName: event.tool,
            rawType: event.rawType ?? event.type,
            message: event.message,
            sessionID: event.sessionID,
            tabID: event.tabID,
            timestamp: DateFormatters.iso8601.date(from: event.ts) ?? Date(),
            reliability: event.reliability,
            metadata: ["producer": producer]
        )
        return NotificationIngress.AcceptedEvent(sharedEvent: event, canonicalEvent: canonical)
    }
}
