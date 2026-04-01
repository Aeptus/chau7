import XCTest
@testable import Chau7Core

final class NotificationIngressTests: XCTestCase {
    func testIngressAcceptsCanonicalClaudeNotification() {
        let event = AIEvent(
            source: .claudeCode,
            type: "notification",
            rawType: "notification",
            tool: "Claude",
            title: "Claude needs your input",
            message: "Claude is waiting for your input",
            notificationType: "idle_prompt",
            ts: "2026-04-01T00:00:00Z",
            sessionID: "claude-session-1",
            reliability: .authoritative
        )

        let decision = NotificationIngress.ingest(event)
        guard case .accept(let accepted) = decision else {
            return XCTFail("Expected ingress acceptance")
        }

        XCTAssertEqual(accepted.sharedEvent.type, "waiting_input")
        XCTAssertEqual(accepted.canonicalEvent?.kind, .waitingForInput)
    }

    func testIngressDropsUnsupportedGenericAIEvent() {
        let event = AIEvent(
            source: .runtime,
            type: "provider_internal_state",
            rawType: "provider_internal_state",
            tool: "Codex",
            message: "internal state",
            ts: "2026-04-01T00:00:00Z",
            reliability: .authoritative
        )

        let decision = NotificationIngress.ingest(event)
        guard case .drop(let reason) = decision else {
            return XCTFail("Expected ingress drop")
        }

        XCTAssertTrue(reason.contains("Unsupported generic AI raw event"))
    }
}
