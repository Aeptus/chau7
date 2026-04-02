import XCTest
@testable import Chau7Core

final class NotificationProviderAdapterRegistryTests: XCTestCase {
    func testClaudeNotificationEventMapsToWaitingInput() {
        let event = AIEvent(
            id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
            source: .claudeCode,
            type: "notification",
            rawType: "notification",
            tool: "Claude",
            title: "Claude needs your input",
            message: "Claude is waiting for your input",
            notificationType: "idle_prompt",
            ts: "2026-04-01T00:00:00Z",
            sessionID: "claude-session-1",
            producer: "claude_code_monitor",
            reliability: .authoritative
        )

        let decision = NotificationProviderAdapterRegistry.adapt(event)
        guard case let .emit(adapted, canonical) = decision else {
            return XCTFail("Expected canonical Claude notification")
        }

        XCTAssertEqual(canonical.kind, .waitingForInput)
        XCTAssertEqual(adapted.type, "waiting_input")
        XCTAssertEqual(adapted.rawType, "notification")
        XCTAssertEqual(adapted.notificationType, "idle_prompt")
        XCTAssertEqual(adapted.tool, "Claude")
    }

    func testClaudeResponseCompleteIsDroppedAsStateOnly() {
        let event = AIEvent(
            source: .claudeCode,
            type: "response_complete",
            rawType: "response_complete",
            tool: "Claude",
            message: "done",
            ts: "2026-04-01T00:00:00Z",
            sessionID: "claude-session-1",
            producer: "claude_code_monitor",
            reliability: .authoritative
        )

        let decision = NotificationProviderAdapterRegistry.adapt(event)
        guard case let .drop(reason) = decision else {
            return XCTFail("Expected Claude response_complete to be dropped")
        }

        XCTAssertTrue(reason.contains("state-only"))
    }

    func testClaudeNotificationEventMapsToAttentionRequired() {
        let event = AIEvent(
            source: .claudeCode,
            type: "notification",
            rawType: "notification",
            tool: "Claude",
            title: "Claude needs your attention",
            message: "Claude Code needs your attention",
            notificationType: "elicitation_dialog",
            ts: "2026-04-01T00:00:00Z",
            sessionID: "claude-session-2",
            producer: "claude_code_monitor",
            reliability: .authoritative
        )

        let decision = NotificationProviderAdapterRegistry.adapt(event)
        guard case let .emit(adapted, canonical) = decision else {
            return XCTFail("Expected canonical Claude attention event")
        }

        XCTAssertEqual(canonical.kind, .attentionRequired)
        XCTAssertEqual(adapted.type, "attention_required")
        XCTAssertEqual(adapted.notificationType, "elicitation_dialog")
    }

    func testRuntimeWaitingInputCanonicalizesWithoutChangingBehavior() {
        let event = AIEvent(
            source: .runtime,
            type: "waiting_input",
            tool: "Codex",
            message: "Codex is waiting",
            ts: "2026-04-01T00:00:00Z",
            sessionID: "session-1",
            producer: "runtime_session_manager",
            reliability: .authoritative
        )

        let decision = NotificationProviderAdapterRegistry.adapt(event)
        guard case let .emit(adapted, canonical) = decision else {
            return XCTFail("Expected runtime canonical event to emit canonical form")
        }

        XCTAssertEqual(adapted.type, "waiting_input")
        XCTAssertEqual(adapted.tool, "Codex")
        XCTAssertEqual(canonical.kind, .waitingForInput)
    }

    func testCodexAgentTurnCompleteCanonicalizesToFinished() {
        let event = AIEvent(
            source: .codex,
            type: "agent-turn-complete",
            rawType: "agent-turn-complete",
            tool: "Codex",
            title: "Codex finished",
            message: "Turn complete",
            ts: "2026-04-02T00:00:00Z",
            tabID: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"),
            producer: "codex_notify_hook",
            reliability: .authoritative
        )

        let decision = NotificationProviderAdapterRegistry.adapt(event)
        guard case let .emit(adapted, canonical) = decision else {
            return XCTFail("Expected Codex turn complete to emit canonical finished")
        }

        XCTAssertEqual(adapted.type, "finished")
        XCTAssertEqual(adapted.rawType, "agent-turn-complete")
        XCTAssertEqual(canonical.kind, .taskFinished)
        XCTAssertEqual(adapted.reliability, .authoritative)
    }

    func testCodexApprovalRequestedCanonicalizesToPermission() {
        let event = AIEvent(
            source: .codex,
            type: "approval-requested",
            rawType: "approval-requested",
            tool: "Codex",
            message: "Needs approval",
            ts: "2026-04-02T00:00:00Z",
            tabID: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"),
            producer: "codex_notify_hook",
            reliability: .authoritative
        )

        let decision = NotificationProviderAdapterRegistry.adapt(event)
        guard case let .emit(adapted, canonical) = decision else {
            return XCTFail("Expected Codex approval event to emit canonical permission")
        }

        XCTAssertEqual(adapted.type, "permission")
        XCTAssertEqual(canonical.kind, .permissionRequired)
    }

    func testCodexFallbackIdlePreservesFallbackReliability() {
        let event = AIEvent(
            source: .codex,
            type: "idle",
            tool: "Codex",
            message: "Idle",
            ts: "2026-04-02T00:00:00Z",
            sessionID: "thread_123",
            producer: "history_idle_monitor",
            reliability: .fallback
        )

        let decision = NotificationProviderAdapterRegistry.adapt(event)
        guard case let .emit(adapted, canonical) = decision else {
            return XCTFail("Expected Codex idle event to canonicalize")
        }

        XCTAssertEqual(adapted.type, "idle")
        XCTAssertEqual(adapted.reliability, .fallback)
        XCTAssertEqual(canonical.kind, .idle)
        XCTAssertEqual(canonical.reliability, .fallback)
    }

    func testUnsupportedGenericAIEventIsDropped() {
        let event = AIEvent(
            source: .runtime,
            type: "provider_internal_state",
            rawType: "provider_internal_state",
            tool: "Codex",
            message: "internal state",
            ts: "2026-04-01T00:00:00Z",
            sessionID: "session-1",
            producer: "runtime_session_manager",
            reliability: .authoritative
        )

        let decision = NotificationProviderAdapterRegistry.adapt(event)
        guard case let .drop(reason) = decision else {
            return XCTFail("Expected unsupported generic AI raw event to be dropped")
        }

        XCTAssertTrue(reason.contains("Unsupported generic AI raw event"))
    }

    func testHistoryMonitorFinishedCanonicalizesAsFallback() {
        let event = AIEvent(
            source: .historyMonitor,
            type: "finished",
            tool: "Codex",
            message: "Codex finished",
            ts: "2026-04-01T00:00:00Z",
            sessionID: "session-1",
            producer: "history_idle_monitor",
            reliability: .fallback
        )

        let decision = NotificationProviderAdapterRegistry.adapt(event)
        guard case let .emit(adapted, canonical) = decision else {
            return XCTFail("Expected canonical history monitor event")
        }

        XCTAssertEqual(canonical.kind, .taskFinished)
        XCTAssertEqual(adapted.type, "finished")
        XCTAssertEqual(adapted.reliability, .fallback)
    }

    func testEventsLogWaitingInputDropsWithoutIdentity() {
        let event = AIEvent(
            source: .eventsLog,
            type: "waiting_input",
            tool: "Codex",
            message: "Codex needs input",
            ts: "2026-04-01T00:00:00Z",
            producer: "external_events_log",
            reliability: .fallback
        )

        let decision = NotificationProviderAdapterRegistry.adapt(event)
        guard case let .drop(reason) = decision else {
            return XCTFail("Expected events log event without identity to drop")
        }

        XCTAssertTrue(reason.contains("missing routing identity"))
    }

    func testShellCommandFailedPreservesTriggerTypeAndCanonicalizes() {
        let event = AIEvent(
            source: .shell,
            type: "command_failed",
            tool: "Shell",
            message: "Exit 1",
            ts: "2026-04-01T00:00:00Z",
            directory: "/tmp/test",
            reliability: .authoritative
        )

        let decision = NotificationProviderAdapterRegistry.adapt(event)
        guard case let .emit(adapted, canonical) = decision else {
            return XCTFail("Expected canonical shell event")
        }

        XCTAssertEqual(adapted.type, "command_failed")
        XCTAssertEqual(adapted.rawType, "command_failed")
        XCTAssertEqual(canonical.kind, .taskFailed)
    }

    func testAppUpdateAvailablePreservesTriggerTypeAndCanonicalizes() {
        let event = AIEvent(
            source: .app,
            type: "update_available",
            tool: "Chau7",
            message: "A new version is available.",
            ts: "2026-04-01T00:00:00Z",
            reliability: .authoritative
        )

        let decision = NotificationProviderAdapterRegistry.adapt(event)
        guard case let .emit(adapted, canonical) = decision else {
            return XCTFail("Expected canonical app event")
        }

        XCTAssertEqual(adapted.type, "update_available")
        XCTAssertEqual(canonical.kind, .informational)
    }

    func testAPIProxyErrorCanonicalizesAsFailure() {
        let event = AIEvent(
            source: .apiProxy,
            type: "api_error",
            tool: "OpenAI",
            message: "500",
            ts: "2026-04-01T00:00:00Z",
            reliability: .heuristic
        )

        let decision = NotificationProviderAdapterRegistry.adapt(event)
        guard case let .emit(adapted, canonical) = decision else {
            return XCTFail("Expected canonical API proxy event")
        }

        XCTAssertEqual(adapted.type, "api_error")
        XCTAssertEqual(canonical.kind, .taskFailed)
    }
}
