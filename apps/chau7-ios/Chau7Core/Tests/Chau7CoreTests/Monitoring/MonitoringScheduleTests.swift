import XCTest
import Chau7Core

final class MonitoringScheduleTests: XCTestCase {

    // MARK: - Claude Code idle check

    func testNextIdleCheckDelayReturnsNilWithNoActiveSessions() {
        let delay = MonitoringSchedule.nextIdleCheckDelay(
            now: Date(),
            minimumInterval: 1.0,
            idleThreshold: 60.0,
            activeSessionDates: []
        )
        XCTAssertNil(delay)
    }

    func testNextIdleCheckDelayUsesClosestSession() {
        let now = Date()
        // Two active sessions: one 10s ago, one 20s ago.
        // With 60s threshold, remaining = 50s and 40s → picks 40s.
        let dates = [
            now.addingTimeInterval(-10),
            now.addingTimeInterval(-20)
        ]

        let delay = MonitoringSchedule.nextIdleCheckDelay(
            now: now,
            minimumInterval: 1.0,
            idleThreshold: 60.0,
            activeSessionDates: dates
        )
        XCTAssertEqual(delay!, 40.0, accuracy: 0.001)
    }

    func testNextIdleCheckDelayAppliesMinimumFloorForOverdueSessions() {
        let now = Date()
        // Session 200s ago with 60s threshold → remaining is -140s → clamped to minimumInterval
        let dates = [now.addingTimeInterval(-200)]

        let delay = MonitoringSchedule.nextIdleCheckDelay(
            now: now,
            minimumInterval: 120.0,
            idleThreshold: 60.0,
            activeSessionDates: dates
        )
        XCTAssertEqual(delay!, 120.0, accuracy: 0.001)
    }

    func testNextIdleCheckDelayUsesThresholdNotMinimumForNonOverdueSessions() {
        let now = Date()
        let dates = [now.addingTimeInterval(-10)]

        let delay = MonitoringSchedule.nextIdleCheckDelay(
            now: now,
            minimumInterval: 1.0,
            idleThreshold: 60.0,
            activeSessionDates: dates
        )
        XCTAssertEqual(delay!, 50.0, accuracy: 0.001)
    }

    // MARK: - History idle check

    func testNextHistoryCheckDelayReturnsNilWithoutSessions() {
        let delay = MonitoringSchedule.nextHistoryCheckDelay(
            now: Date(),
            minimumCheckInterval: 1.0,
            idleSeconds: 60.0,
            staleSeconds: 120.0,
            lastSeen: [:]
        )
        XCTAssertNil(delay)
    }

    func testNextHistoryCheckDelayUsesMinimumIntervalFloor() {
        let now = Date()
        // Session 59.3s ago → idle deadline at 60s → remaining = 0.7s → clamped to 1.0
        let lastSeen = ["near-threshold": now.addingTimeInterval(-59.3)]

        let delay = MonitoringSchedule.nextHistoryCheckDelay(
            now: now,
            minimumCheckInterval: 1.0,
            idleSeconds: 60.0,
            staleSeconds: 120.0,
            lastSeen: lastSeen
        )
        XCTAssertEqual(delay!, 1.0, accuracy: 0.001)
    }

    func testNextHistoryCheckDelayPicksSoonestDeadlineAcrossSessions() {
        let now = Date()
        // "recent" 10s ago: idle at 60s → 50s remaining, stale at 100s → 90s
        // "older" 40s ago: idle at 60s → 20s remaining, stale at 100s → 60s
        // Picks 20s (soonest non-overdue idle deadline)
        let lastSeen = [
            "recent": now.addingTimeInterval(-10.0),
            "older": now.addingTimeInterval(-40.0)
        ]

        let delay = MonitoringSchedule.nextHistoryCheckDelay(
            now: now,
            minimumCheckInterval: 1.0,
            idleSeconds: 60.0,
            staleSeconds: 100.0,
            lastSeen: lastSeen
        )
        XCTAssertEqual(delay!, 20.0, accuracy: 0.001)
    }

    func testNextHistoryCheckDelayRespectsMinimumWhenSessionIsStaleSoon() {
        let now = Date()
        // "staleSoon" 75s ago: stale at 100s → 25s but also idle at 60s → -15s → clamp to 1.0
        let lastSeen = [
            "staleSoon": now.addingTimeInterval(-75.0),
            "activeLong": now.addingTimeInterval(-10.0)
        ]

        let delay = MonitoringSchedule.nextHistoryCheckDelay(
            now: now,
            minimumCheckInterval: 1.0,
            idleSeconds: 60.0,
            staleSeconds: 100.0,
            lastSeen: lastSeen
        )
        XCTAssertEqual(delay!, 1.0, accuracy: 0.001)
    }

    func testNextHistoryCheckDelayClampsStaleToIdlePlusOne() {
        let now = Date()
        // staleSeconds=1.0 is below idleSeconds+1 (61s), so clamped to 61s
        let lastSeen = ["session": now.addingTimeInterval(-10)]

        let delay = MonitoringSchedule.nextHistoryCheckDelay(
            now: now,
            minimumCheckInterval: 1.0,
            idleSeconds: 60.0,
            staleSeconds: 1.0,
            lastSeen: lastSeen
        )
        // idle deadline = 50s remaining, stale deadline = 51s remaining → picks 50s
        XCTAssertEqual(delay!, 50.0, accuracy: 0.001)
    }

    func testNextHistoryCheckDelayForOverdueStateFallsBackToMinimum() {
        let now = Date()
        // Session 400s ago → all deadlines in the past → clamped to 1.0
        let lastSeen = ["session": now.addingTimeInterval(-400)]

        let delay = MonitoringSchedule.nextHistoryCheckDelay(
            now: now,
            minimumCheckInterval: 1.0,
            idleSeconds: 60.0,
            staleSeconds: 100.0,
            lastSeen: lastSeen
        )
        XCTAssertEqual(delay!, 1.0, accuracy: 0.001)
    }

    // MARK: - Process resource polling

    func testNextPollIntervalStartsAtMinimum() {
        let interval = MonitoringSchedule.nextPollInterval(
            consecutiveNoDataPolls: 0
        )
        XCTAssertEqual(interval, MonitoringSchedule.defaultMinimumPollInterval, accuracy: 0.001)
    }

    func testNextPollIntervalBacksOffExponentially() {
        let first = MonitoringSchedule.nextPollInterval(consecutiveNoDataPolls: 1)
        // 0.75 * 1.8^1 = 1.35
        XCTAssertEqual(first, 1.35, accuracy: 0.001)

        let second = MonitoringSchedule.nextPollInterval(consecutiveNoDataPolls: 2)
        // 0.75 * 1.8^2 = 2.43
        XCTAssertEqual(second, 2.43, accuracy: 0.001)
    }

    func testNextPollIntervalCapsAtMaximum() {
        let capped = MonitoringSchedule.nextPollInterval(consecutiveNoDataPolls: 100)
        XCTAssertEqual(capped, MonitoringSchedule.defaultMaxPollInterval, accuracy: 0.001)
    }

    func testNextPollIntervalTreatsNegativeAsNoData() {
        let interval = MonitoringSchedule.nextPollInterval(consecutiveNoDataPolls: -3)
        XCTAssertEqual(interval, MonitoringSchedule.defaultMinimumPollInterval, accuracy: 0.001)
    }
}
