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
        XCTAssertEqual(key, "claude_code|finished|claude")
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
        XCTAssertEqual(key, "history_monitor||")
    }
}
