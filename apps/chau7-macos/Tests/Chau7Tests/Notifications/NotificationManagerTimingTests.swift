import XCTest
#if !SWIFT_PACKAGE
@testable import Chau7

final class NotificationManagerTimingTests: XCTestCase {

    func testNotificationCoalescingKeyNormalizesToolAndType() {
        let event = AIEvent(
            source: .claudeCode,
            type: "  FiNiShEd ",
            tool: "  Claude ",
            message: "done",
            ts: "2026-03-05T00:00:00Z"
        )

        let key = NotificationManager.notificationCoalescingKey(for: event)
        XCTAssertEqual(key, "claude_code|finished|claude")
    }

    func testNotificationCoalescingKeyVariesBySourceState() {
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

        let shellKey = NotificationManager.notificationCoalescingKey(for: shellEvent)
        let historyKey = NotificationManager.notificationCoalescingKey(for: historyEvent)
        XCTAssertNotEqual(shellKey, historyKey)
    }

    func testNotificationCoalescingWindowIsConfigured() {
        XCTAssertEqual(NotificationManager.defaultCoalescingWindow, 0.25, accuracy: 0.0001)
    }

    func testNotificationCoalescingKeyNormalizesMissingParts() {
        let event = AIEvent(
            source: .historyMonitor,
            type: "   ",
            tool: "",
            message: "",
            ts: "2026-03-05T00:00:00Z"
        )

        let key = NotificationManager.notificationCoalescingKey(for: event)
        XCTAssertEqual(key, "history_monitor||")
    }
}
#endif
