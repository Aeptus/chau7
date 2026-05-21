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
        XCTAssertEqual(
            key,
            "claude|finished|event:\(event.id.uuidString.lowercased())"
        )
    }

    func testCoalescingKeyIgnoresProducerAndReliabilityForSameProviderState() {
        let id = UUID()
        let fallbackEvent = AIEvent(
            id: id,
            source: .historyMonitor,
            type: "finished",
            tool: "Claude",
            message: "",
            ts: "2026-03-05T00:00:00Z",
            sessionID: "session-1",
            producer: "history_idle_monitor",
            reliability: .fallback
        )
        let authoritativeEvent = AIEvent(
            id: id,
            source: .claudeCode,
            type: "finished",
            tool: "Claude",
            message: "",
            ts: "2026-03-05T00:00:00Z",
            sessionID: "session-1",
            producer: "claude_code_monitor",
            reliability: .authoritative
        )

        let fallbackKey = MonitoringSchedule.notificationCoalescingKey(for: fallbackEvent)
        let authoritativeKey = MonitoringSchedule.notificationCoalescingKey(for: authoritativeEvent)
        XCTAssertEqual(fallbackKey, authoritativeKey)
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
        XCTAssertEqual(
            key,
            "history_monitor||event:\(event.id.uuidString.lowercased())"
        )
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
        XCTAssertEqual(
            key,
            "claude|permission|session:session-123"
        )
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
        XCTAssertEqual(
            key,
            "codex|finished|dir:/tmp/chau7"
        )
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
