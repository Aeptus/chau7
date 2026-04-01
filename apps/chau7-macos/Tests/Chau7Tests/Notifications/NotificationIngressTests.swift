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
        XCTAssertEqual(accepted.canonicalEvent.kind, .waitingForInput)
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

    func testIngressDropsTerminalSessionFinishedWithoutExactIdentity() {
        let event = AIEvent(
            source: .terminalSession,
            type: "finished",
            tool: "Claude",
            message: "Finished",
            ts: "2026-04-01T00:00:00Z",
            reliability: .authoritative
        )

        let decision = NotificationIngress.ingest(event)
        guard case .drop(let reason) = decision else {
            return XCTFail("Expected ingress drop")
        }

        XCTAssertTrue(reason.contains("missing exact routing identity"))
    }

    func testIngressAcceptsTerminalSessionFinishedWithTabIdentity() {
        let tabID = UUID()
        let event = AIEvent(
            source: .terminalSession,
            type: "finished",
            tool: "Claude",
            message: "Finished",
            ts: "2026-04-01T00:00:00Z",
            tabID: tabID,
            reliability: .authoritative
        )

        let decision = NotificationIngress.ingest(event)
        guard case .accept(let accepted) = decision else {
            return XCTFail("Expected ingress acceptance")
        }

        XCTAssertEqual(accepted.sharedEvent.tabID, tabID)
        XCTAssertEqual(accepted.sharedEvent.type, "finished")
        XCTAssertEqual(accepted.canonicalEvent.kind, .taskFinished)
    }

    func testIngressAcceptsShellCommandFailureAsCanonicalSharedEvent() {
        let event = AIEvent(
            source: .shell,
            type: "command_failed",
            tool: "Shell",
            message: "Exit 1",
            ts: "2026-04-01T00:00:00Z",
            directory: "/tmp/test",
            reliability: .authoritative
        )

        let decision = NotificationIngress.ingest(event)
        guard case .accept(let accepted) = decision else {
            return XCTFail("Expected shell ingress acceptance")
        }

        XCTAssertEqual(accepted.sharedEvent.type, "command_failed")
        XCTAssertEqual(accepted.canonicalEvent.kind, .taskFailed)
    }

    func testIngressAcceptsAppInformationalEventAsCanonicalSharedEvent() {
        let event = AIEvent(
            source: .app,
            type: "update_available",
            tool: "Chau7",
            message: "A new version is available.",
            ts: "2026-04-01T00:00:00Z",
            reliability: .authoritative
        )

        let decision = NotificationIngress.ingest(event)
        guard case .accept(let accepted) = decision else {
            return XCTFail("Expected app ingress acceptance")
        }

        XCTAssertEqual(accepted.sharedEvent.type, "update_available")
        XCTAssertEqual(accepted.canonicalEvent.kind, .informational)
    }
}
