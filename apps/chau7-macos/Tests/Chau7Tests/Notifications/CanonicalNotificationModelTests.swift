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
        XCTAssertTrue(NotificationSemanticKind.attentionRequired.isAttentionSeeking)
        XCTAssertFalse(NotificationSemanticKind.authenticationSucceeded.isAttentionSeeking)
        XCTAssertFalse(NotificationSemanticKind.informational.isAttentionSeeking)
        XCTAssertFalse(NotificationSemanticKind.idle.isAttentionSeeking)
        XCTAssertFalse(NotificationSemanticKind.unknown.isAttentionSeeking)
    }

    func testEnrichedEventPassesEventFieldsThrough() {
        let tabID = UUID()
        let event = AIEvent(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            source: .claudeCode,
            type: "permission",
            rawType: "notification",
            tool: "Claude Code",
            title: "Claude needs your input",
            message: "Claude is waiting for your input",
            notificationType: "permission_prompt",
            ts: "2026-04-01T00:00:00Z",
            directory: "/tmp/mockup",
            tabID: tabID,
            sessionID: "session-123",
            producer: "claude_code_monitor",
            reliability: .authoritative
        )

        let enriched = EnrichedEvent(event: event, kind: .permissionRequired)

        XCTAssertEqual(enriched.event.id, event.id)
        XCTAssertEqual(enriched.kind, .permissionRequired)
        XCTAssertEqual(enriched.event.source.rawValue, "claude_code")
        XCTAssertEqual(enriched.event.tool, "Claude Code")
        XCTAssertEqual(enriched.event.rawType, "notification")
        XCTAssertEqual(enriched.event.title, "Claude needs your input")
        XCTAssertEqual(enriched.event.message, "Claude is waiting for your input")
        XCTAssertEqual(enriched.event.notificationType, "permission_prompt")
        XCTAssertEqual(enriched.event.sessionID, "session-123")
        XCTAssertEqual(enriched.event.tabID, tabID)
        XCTAssertEqual(enriched.event.directory, "/tmp/mockup")
        XCTAssertEqual(enriched.event.ts, "2026-04-01T00:00:00Z")
        XCTAssertEqual(enriched.event.reliability, .authoritative)
        XCTAssertTrue(enriched.isAttentionSeeking)
    }

    func testSemanticTriggerTypeMapsEveryKind() {
        XCTAssertEqual(SemanticTriggerType(kind: .taskFinished), .finished)
        XCTAssertEqual(SemanticTriggerType(kind: .taskFailed), .failed)
        XCTAssertEqual(SemanticTriggerType(kind: .permissionRequired), .permission)
        XCTAssertEqual(SemanticTriggerType(kind: .waitingForInput), .waitingInput)
        XCTAssertEqual(SemanticTriggerType(kind: .attentionRequired), .attentionRequired)
        XCTAssertEqual(SemanticTriggerType(kind: .authenticationSucceeded), .authenticationSucceeded)
        XCTAssertEqual(SemanticTriggerType(kind: .informational), .info)
        XCTAssertEqual(SemanticTriggerType(kind: .idle), .idle)
        XCTAssertNil(SemanticTriggerType(kind: .unknown))
    }

    func testSemanticTriggerTypeRawValuesAreStable() {
        XCTAssertEqual(SemanticTriggerType.finished.rawValue, "finished")
        XCTAssertEqual(SemanticTriggerType.failed.rawValue, "failed")
        XCTAssertEqual(SemanticTriggerType.permission.rawValue, "permission")
        XCTAssertEqual(SemanticTriggerType.waitingInput.rawValue, "waiting_input")
        XCTAssertEqual(SemanticTriggerType.attentionRequired.rawValue, "attention_required")
        XCTAssertEqual(SemanticTriggerType.authenticationSucceeded.rawValue, "authentication_succeeded")
        XCTAssertEqual(SemanticTriggerType.info.rawValue, "info")
        XCTAssertEqual(SemanticTriggerType.idle.rawValue, "idle")
    }
}
