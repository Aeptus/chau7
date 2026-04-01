import XCTest
@testable import Chau7Core

final class CanonicalNotificationMappingTests: XCTestCase {
    func testNotificationTypeMappings() {
        let permissionKind: NotificationSemanticKind = NotificationSemanticMapping.kind(
            rawType: nil as String?,
            notificationType: "permission_prompt"
        )
        let waitingKind: NotificationSemanticKind = NotificationSemanticMapping.kind(
            rawType: nil as String?,
            notificationType: "idle_prompt"
        )
        let authKind: NotificationSemanticKind = NotificationSemanticMapping.kind(
            rawType: nil as String?,
            notificationType: "auth_success"
        )
        let attentionKind: NotificationSemanticKind = NotificationSemanticMapping.kind(
            rawType: nil as String?,
            notificationType: "elicitation_dialog"
        )
        XCTAssertEqual(permissionKind, .permissionRequired)
        XCTAssertEqual(waitingKind, .waitingForInput)
        XCTAssertEqual(authKind, .authenticationSucceeded)
        XCTAssertEqual(attentionKind, .attentionRequired)
    }

    func testRawTypeMappings() {
        let finished: NotificationSemanticKind = NotificationSemanticMapping.kind(rawType: "response_complete")
        let failed: NotificationSemanticKind = NotificationSemanticMapping.kind(rawType: "failed")
        let permission: NotificationSemanticKind = NotificationSemanticMapping.kind(rawType: "permission_request")
        let waiting: NotificationSemanticKind = NotificationSemanticMapping.kind(rawType: "waiting_input")
        let notification: NotificationSemanticKind = NotificationSemanticMapping.kind(rawType: "notification")
        let idle: NotificationSemanticKind = NotificationSemanticMapping.kind(rawType: "idle")
        let informational: NotificationSemanticKind = NotificationSemanticMapping.kind(rawType: "info")
        XCTAssertEqual(finished, .taskFinished)
        XCTAssertEqual(failed, .taskFailed)
        XCTAssertEqual(permission, .permissionRequired)
        XCTAssertEqual(waiting, .waitingForInput)
        XCTAssertEqual(notification, .attentionRequired)
        XCTAssertEqual(idle, .idle)
        XCTAssertEqual(informational, .informational)
    }

    func testNotificationTypeTakesPrecedenceOverRawType() {
        let kind: NotificationSemanticKind = NotificationSemanticMapping.kind(
            rawType: "finished",
            notificationType: "permission_prompt"
        )
        XCTAssertEqual(
            kind,
            .permissionRequired
        )
    }

    func testNormalize() {
        XCTAssertEqual(NotificationSemanticMapping.normalize(" Permission Prompt "), "permission_prompt")
        XCTAssertEqual(NotificationSemanticMapping.normalize("idle-prompt"), "idle_prompt")
        XCTAssertEqual(NotificationSemanticMapping.normalize("auth success"), "authsuccess")
    }
}
