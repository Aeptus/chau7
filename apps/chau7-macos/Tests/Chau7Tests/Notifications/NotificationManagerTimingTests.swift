import XCTest
import Chau7Core

final class NotificationCoalescingTests: XCTestCase {

    func testCoalescingKeyNormalizesToolAndType() {
        let event = AIEvent(
            source: .claudeCode,
            type: "  FiNiShEd ",
            tool: "  Claude ",
            message: "done",
            ts: "2026-03-05T00:00:00Z"
        )

        let key = MonitoringSchedule.notificationCoalescingKey(for: event)
        XCTAssertEqual(key, "claude_code|finished|claude|event:\(event.id.uuidString.lowercased())")
    }

    func testCoalescingKeyVariesBySource() {
        let shellEvent = AIEvent(
            source: .shell,
            type: "finished",
            tool: "Claude",
            message: "",
            ts: "2026-03-05T00:00:00Z"
        )
        let historyEvent = AIEvent(
            source: .historyMonitor,
            type: "finished",
            tool: "Claude",
            message: "",
            ts: "2026-03-05T00:00:00Z"
        )

        let shellKey = MonitoringSchedule.notificationCoalescingKey(for: shellEvent)
        let historyKey = MonitoringSchedule.notificationCoalescingKey(for: historyEvent)
        XCTAssertNotEqual(shellKey, historyKey)
    }

    func testCoalescingWindowIsConfigured() {
        XCTAssertEqual(MonitoringSchedule.defaultCoalescingWindow, 0.25, accuracy: 0.001)
    }

    func testCoalescingKeyHandlesEmptyFields() {
        let event = AIEvent(
            source: .historyMonitor,
            type: "   ",
            tool: "",
            message: "",
            ts: "2026-03-05T00:00:00Z"
        )

        let key = MonitoringSchedule.notificationCoalescingKey(for: event)
        XCTAssertEqual(key, "history_monitor|||event:\(event.id.uuidString.lowercased())")
    }

    func testCoalescingKeyScopesBySessionWhenTabIDMissing() {
        let event = AIEvent(
            source: .runtime,
            type: "permission",
            tool: "Claude",
            message: "",
            ts: "2026-03-05T00:00:00Z",
            sessionID: "SESSION-123"
        )

        let key = MonitoringSchedule.notificationCoalescingKey(for: event)
        XCTAssertEqual(key, "runtime|permission|claude|session:session-123")
    }

    func testCoalescingKeyScopesByDirectoryWhenNoTabOrSessionExists() {
        let event = AIEvent(
            source: .shell,
            type: "finished",
            tool: "Codex",
            message: "",
            ts: "2026-03-05T00:00:00Z",
            directory: "/tmp/../tmp/chau7"
        )

        let key = MonitoringSchedule.notificationCoalescingKey(for: event)
        XCTAssertEqual(key, "shell|finished|codex|dir:/tmp/chau7")
    }

    func testRateLimitKeyIncludesIdentityScope() {
        let first = AIEvent(
            source: .runtime,
            type: "permission",
            tool: "Claude",
            message: "",
            ts: "2026-03-05T00:00:00Z",
            tabID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")
        )
        let second = AIEvent(
            source: .runtime,
            type: "permission",
            tool: "Claude",
            message: "",
            ts: "2026-03-05T00:00:00Z",
            tabID: UUID(uuidString: "FFFFFFFF-BBBB-CCCC-DDDD-EEEEEEEEEEEE")
        )

        let firstKey = MonitoringSchedule.notificationRateLimitKey(triggerID: "runtime.permission", event: first)
        let secondKey = MonitoringSchedule.notificationRateLimitKey(triggerID: "runtime.permission", event: second)
        XCTAssertNotEqual(firstKey, secondKey)
    }
}
