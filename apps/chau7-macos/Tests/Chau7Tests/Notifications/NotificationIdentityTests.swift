import XCTest
@testable import Chau7Core

/// Golden parity tests: `NotificationIdentity` must produce byte-identical
/// keys to the formulas that shipped in `MonitoringSchedule` and
/// `NotificationDeliverySemantics` before the key derivations were unified.
final class NotificationIdentityTests: XCTestCase {

    // MARK: - Event matrix

    private func eventMatrix() -> [(label: String, event: AIEvent)] {
        let tabID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        return [
            ("session only", AIEvent(
                source: .claudeCode, type: "finished", tool: "Claude Code",
                message: "done", ts: DateFormatters.nowISO8601(), sessionID: "Sess-123"
            )),
            ("tab only", AIEvent(
                source: .codex, type: "waiting_input", tool: "Codex",
                message: "input?", ts: DateFormatters.nowISO8601(), tabID: tabID
            )),
            ("dir only", AIEvent(
                source: .shell, type: "failed", tool: "zsh",
                message: "exit 1", ts: DateFormatters.nowISO8601(),
                directory: "/Users/Test/Repo/../Repo"
            )),
            ("no identity", AIEvent(
                source: .unknown, type: "permission", tool: "  Mixed Case Tool  ",
                message: "?", ts: DateFormatters.nowISO8601()
            )),
            ("all identities", AIEvent(
                source: .claudeCode, type: "  Attention_Required  ", tool: "Claude Code",
                message: "look", ts: DateFormatters.nowISO8601(),
                directory: "/tmp/work", tabID: tabID, sessionID: "abc"
            )),
            ("idle for repeat family", AIEvent(
                source: .claudeCode, type: "idle", tool: "Claude Code",
                message: "idle", ts: DateFormatters.nowISO8601(), sessionID: "abc"
            ))
        ]
    }

    // MARK: - Legacy formula reimplementations (pre-unification)

    private func legacyCoalescingKey(for event: AIEvent) -> String {
        let provider = AIObservation.providerKey(for: event)
        let normalizedType = event.type
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let identity = AIObservation.identityKey(for: event)
        return "\(provider)|\(normalizedType)|\(identity)"
    }

    private func legacyRateLimitKey(triggerID: String, event: AIEvent) -> String {
        "\(triggerID)|\(AIObservation.identityKey(for: event))"
    }

    private func legacyAuthorityKeys(for event: AIEvent) -> [String] {
        let normalizedTool = event.tool
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        var identities: [String] = []
        if let sessionID = event.sessionID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !sessionID.isEmpty {
            identities.append("session:\(sessionID.lowercased())")
        }
        if let tabID = event.tabID {
            identities.append("tab:\(tabID.uuidString.lowercased())")
        }
        if let directory = event.directory?.trimmingCharacters(in: .whitespacesAndNewlines),
           !directory.isEmpty {
            identities.append("dir:\(URL(fileURLWithPath: directory).standardized.path.lowercased())")
        }
        if identities.isEmpty {
            identities.append(AIObservation.identityKey(for: event))
        }
        return identities.map { "\(event.normalizedType)|\(normalizedTool)|\($0)" }
    }

    private func legacyRepeatSuppressionKey(for event: AIEvent, family: String) -> String {
        let tool = event.tool.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return "\(family)|\(tool)|\(AIObservation.identityKey(for: event))"
    }

    private func legacyClosedIdentityKeys(for event: AIEvent) -> [String] {
        let tool = event.tool.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let closedKey = "\(tool)|\(AIObservation.identityKey(for: event))"
        if let sessionID = event.sessionID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !sessionID.isEmpty {
            return ["session:\(sessionID.lowercased())", closedKey]
        }
        return [closedKey]
    }

    // MARK: - Parity

    func testCoalescingKeyParity() {
        for (label, event) in eventMatrix() {
            XCTAssertEqual(
                NotificationIdentity(for: event).coalescingKey,
                legacyCoalescingKey(for: event),
                "coalescing key drifted for: \(label)"
            )
            XCTAssertEqual(
                MonitoringSchedule.notificationCoalescingKey(for: event),
                legacyCoalescingKey(for: event),
                "MonitoringSchedule wrapper drifted for: \(label)"
            )
        }
    }

    func testRateLimitKeyParity() {
        for (label, event) in eventMatrix() {
            XCTAssertEqual(
                NotificationIdentity(for: event).rateLimitKey(triggerID: "claudeCode.finished"),
                legacyRateLimitKey(triggerID: "claudeCode.finished", event: event),
                "rate-limit key drifted for: \(label)"
            )
            XCTAssertEqual(
                MonitoringSchedule.notificationRateLimitKey(triggerID: "claudeCode.finished", event: event),
                legacyRateLimitKey(triggerID: "claudeCode.finished", event: event),
                "MonitoringSchedule wrapper drifted for: \(label)"
            )
        }
    }

    func testAuthorityKeysParity() {
        for (label, event) in eventMatrix() {
            XCTAssertEqual(
                NotificationIdentity(for: event).authorityKeys,
                legacyAuthorityKeys(for: event),
                "authority keys drifted for: \(label)"
            )
        }
        // The public wrapper additionally gates on the authoritative type set.
        for (label, event) in eventMatrix() {
            let expected = NotificationDeliverySemantics.authoritativeRoutingTypes.contains(event.normalizedType)
                ? legacyAuthorityKeys(for: event)
                : []
            XCTAssertEqual(
                NotificationDeliverySemantics.authorityKeys(for: event),
                expected,
                "semantics wrapper drifted for: \(label)"
            )
        }
    }

    func testRepeatSuppressionKeyParity() {
        for (label, event) in eventMatrix() {
            XCTAssertEqual(
                NotificationIdentity(for: event).repeatSuppressionKey(family: "interactive_attention"),
                legacyRepeatSuppressionKey(for: event, family: "interactive_attention"),
                "repeat key drifted for: \(label)"
            )
        }
        // Wrapper: only interactive-attention family types yield a key.
        let idleEvent = eventMatrix().first { $0.label == "idle for repeat family" }!.event
        XCTAssertEqual(
            NotificationDeliverySemantics.repeatSuppressionKey(for: idleEvent),
            legacyRepeatSuppressionKey(for: idleEvent, family: "interactive_attention")
        )
        let finishedEvent = eventMatrix().first { $0.label == "session only" }!.event
        XCTAssertNil(NotificationDeliverySemantics.repeatSuppressionKey(for: finishedEvent))
    }

    func testClosedIdentityKeysParity() {
        for (label, event) in eventMatrix() {
            XCTAssertEqual(
                NotificationIdentity(for: event).closedIdentityKeys,
                legacyClosedIdentityKeys(for: event),
                "closed keys drifted for: \(label)"
            )
            XCTAssertEqual(
                NotificationDeliverySemantics.closedIdentityKeys(for: event),
                legacyClosedIdentityKeys(for: event),
                "semantics wrapper drifted for: \(label)"
            )
        }
    }

    // MARK: - Timings stay wired

    func testNamedTimingsMatchLegacyConstants() {
        XCTAssertEqual(MonitoringSchedule.defaultCoalescingWindow, 0.25)
        XCTAssertEqual(NotificationTimings.coalescingWindow, 0.25)
        XCTAssertEqual(NotificationDeliverySemantics.authorityRetentionSeconds, 180)
        XCTAssertEqual(NotificationDeliverySemantics.repeatedAttentionSuppressionSeconds, 90)
        XCTAssertEqual(NotificationDeliverySemantics.closedSessionSuppressionSeconds, 180)
        XCTAssertEqual(NotificationTimings.terminalRepeatWindow, 10)
        XCTAssertEqual(NotificationTimings.rateLimitCooldown, 10)
    }
}
