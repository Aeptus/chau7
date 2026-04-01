import XCTest
@testable import Chau7Core

final class CanonicalNotificationModelTests: XCTestCase {
    func testSemanticKindsAreStable() {
        XCTAssertEqual(NotificationSemanticKind.taskFinished.rawValue, "task_finished")
        XCTAssertEqual(NotificationSemanticKind.taskFailed.rawValue, "task_failed")
        XCTAssertEqual(NotificationSemanticKind.permissionRequired.rawValue, "permission_required")
        XCTAssertEqual(NotificationSemanticKind.waitingForInput.rawValue, "waiting_for_input")
    }

    func testAttentionSeekingKinds() {
        XCTAssertTrue(NotificationSemanticKind.taskFinished.isAttentionSeeking)
        XCTAssertTrue(NotificationSemanticKind.taskFailed.isAttentionSeeking)
        XCTAssertTrue(NotificationSemanticKind.permissionRequired.isAttentionSeeking)
        XCTAssertTrue(NotificationSemanticKind.waitingForInput.isAttentionSeeking)
        XCTAssertFalse(NotificationSemanticKind.authenticationSucceeded.isAttentionSeeking)
        XCTAssertFalse(NotificationSemanticKind.informational.isAttentionSeeking)
    }

    func testProviderEventBuildsCanonicalEvent() {
        let tabID = UUID()
        let event = NotificationProviderEvent(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            providerID: "claude_code",
            providerName: "Claude Code",
            rawType: "notification",
            title: "Claude needs your input",
            message: "Claude is waiting for your input",
            notificationType: "permission_prompt",
            sessionID: "session-123",
            tabID: tabID,
            directory: "/tmp/mockup",
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            metadata: ["hook": "Notification"]
        )

        let canonical = event.canonicalEvent(kind: .permissionRequired, reliability: .authoritative)
        XCTAssertEqual(canonical.id, event.id)
        XCTAssertEqual(canonical.kind, .permissionRequired)
        XCTAssertEqual(canonical.providerID, "claude_code")
        XCTAssertEqual(canonical.providerName, "Claude Code")
        XCTAssertEqual(canonical.rawType, "notification")
        XCTAssertEqual(canonical.title, "Claude needs your input")
        XCTAssertEqual(canonical.message, "Claude is waiting for your input")
        XCTAssertEqual(canonical.notificationType, "permission_prompt")
        XCTAssertEqual(canonical.sessionID, "session-123")
        XCTAssertEqual(canonical.tabID, tabID)
        XCTAssertEqual(canonical.directory, "/tmp/mockup")
        XCTAssertEqual(canonical.timestamp, event.timestamp)
        XCTAssertEqual(canonical.reliability, .authoritative)
        XCTAssertEqual(canonical.metadata["hook"], "Notification")
        XCTAssertTrue(canonical.isAttentionSeeking)
    }

    func testAdapterResultAccessors() {
        let event = CanonicalNotificationEvent(
            kind: .taskFinished,
            providerID: "codex",
            providerName: "Codex",
            message: "Done"
        )

        let emitted = NotificationProviderAdapterResult.emit(event)
        XCTAssertEqual(emitted.canonicalEvent, event)
        XCTAssertNil(emitted.reason)

        let dropped = NotificationProviderAdapterResult.drop(reason: "disabled")
        XCTAssertNil(dropped.canonicalEvent)
        XCTAssertEqual(dropped.reason, "disabled")

        let deferred = NotificationProviderAdapterResult.deferToFallback(reason: "missing identity")
        XCTAssertNil(deferred.canonicalEvent)
        XCTAssertEqual(deferred.reason, "missing identity")
    }
}
