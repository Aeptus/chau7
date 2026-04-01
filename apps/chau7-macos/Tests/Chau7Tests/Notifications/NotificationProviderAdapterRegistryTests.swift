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
            return XCTFail("Expected runtime canonicalization")
        }

        XCTAssertEqual(canonical.kind, .waitingForInput)
        XCTAssertEqual(adapted.type, "waiting_input")
        XCTAssertEqual(adapted.tool, "Codex")
    }
}
