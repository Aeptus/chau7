import XCTest
#if !SWIFT_PACKAGE
@testable import Chau7

final class MonitoringScheduleTests: XCTestCase {

    func testClaudeNextCheckDelayReturnsNilWithNoActiveSessions() {
        let delay = ClaudeCodeMonitor.nextIdleCheckDelay(
            now: Date(),
            minimumIdleCheckInterval: 1.0,
            idleThreshold: 60.0,
            sessions: []
        )
        XCTAssertNil(delay)
    }

    func testClaudeNextCheckDelayUsesActiveSessionsOnly() {
        let now = Date()
        let sessions = [
            session(
                state: .closed,
                lastActivity: now.addingTimeInterval(-120)
            ),
            session(
                state: .active,
                lastActivity: now.addingTimeInterval(-10)
            ),
            session(
                state: .waitingInput,
                lastActivity: now.addingTimeInterval(-5)
            ),
            session(
                state: .responding,
                lastActivity: now.addingTimeInterval(-20)
            )
        ]

        let delay = ClaudeCodeMonitor.nextIdleCheckDelay(
            now: now,
            minimumIdleCheckInterval: 1.0,
            idleThreshold: 60.0,
            sessions: sessions
        )
        XCTAssertEqual(delay, 40.0, accuracy: 0.0001)
    }

    func testClaudeNextCheckDelayReturnsNilForNonMonitoredSessionStates() {
        let now = Date()
        let sessions = [
            session(state: .waitingInput, lastActivity: now.addingTimeInterval(-10)),
            session(state: .waitingPermission, lastActivity: now.addingTimeInterval(-20)),
            session(state: .idle, lastActivity: now.addingTimeInterval(-30)),
            session(state: .closed, lastActivity: now.addingTimeInterval(-40))
        ]

        let delay = ClaudeCodeMonitor.nextIdleCheckDelay(
            now: now,
            minimumIdleCheckInterval: 1.0,
            idleThreshold: 60.0,
            sessions: sessions
        )
        XCTAssertNil(delay)
    }

    func testClaudeNextCheckDelayAppliesMinimumFloorForOverdueSessions() {
        let now = Date()
        let session = session(
            state: .active,
            lastActivity: now.addingTimeInterval(-200)
        )

        let delay = ClaudeCodeMonitor.nextIdleCheckDelay(
            now: now,
            minimumIdleCheckInterval: 120.0,
            idleThreshold: 60.0,
            sessions: [session]
        )
        XCTAssertEqual(delay, 120.0, accuracy: 0.0001)
    }

    func testHistoryIdleNextCheckDelayReturnsNilWithoutSessions() {
        let delay = HistoryIdleMonitor.nextCheckDelay(
            now: Date(),
            minimumCheckInterval: 1.0,
            idleSeconds: 60.0,
            staleSeconds: 120.0,
            lastSeen: [:]
        )
        XCTAssertNil(delay)
    }

    func testHistoryIdleNextCheckDelayUsesMinimumIntervalFloor() {
        let now = Date()
        let lastSeen: [String: Date] = [
            "near-threshold": now.addingTimeInterval(-59.3)
        ]

        let delay = HistoryIdleMonitor.nextCheckDelay(
            now: now,
            minimumCheckInterval: 1.0,
            idleSeconds: 60.0,
            staleSeconds: 120.0,
            lastSeen: lastSeen
        )
        XCTAssertEqual(delay, 1.0, accuracy: 0.0001)
    }

    func testHistoryIdleNextCheckDelayPicksSoonestDeadlineAcrossSessions() {
        let now = Date()
        let lastSeen: [String: Date] = [
            "slow": now.addingTimeInterval(-75.0),
            "fast": now.addingTimeInterval(-20.0)
        ]

        let delay = HistoryIdleMonitor.nextCheckDelay(
            now: now,
            minimumCheckInterval: 1.0,
            idleSeconds: 60.0,
            staleSeconds: 100.0,
            lastSeen: lastSeen
        )
        XCTAssertEqual(delay, 25.0, accuracy: 0.0001)
    }

    func testHistoryIdleNextCheckDelayRespectsMinimumWhenSessionIsStaleSoon() {
        let now = Date()
        let lastSeen: [String: Date] = [
            "staleSoon": now.addingTimeInterval(-75.0),
            "activeLong": now.addingTimeInterval(-10.0)
        ]

        let delay = HistoryIdleMonitor.nextCheckDelay(
            now: now,
            minimumCheckInterval: 1.0,
            idleSeconds: 60.0,
            staleSeconds: 100.0,
            lastSeen: lastSeen
        )
        XCTAssertEqual(delay, 1.0, accuracy: 0.0001)
    }

    func testHistoryIdleNextCheckDelayClampsStaleToIdleThresholdPlusOneSecond() {
        let now = Date()
        let lastSeen: [String: Date] = [
            "session": now.addingTimeInterval(-10)
        ]

        let delay = HistoryIdleMonitor.nextCheckDelay(
            now: now,
            minimumCheckInterval: 1.0,
            idleSeconds: 60.0,
            staleSeconds: 1.0,
            lastSeen: lastSeen
        )
        XCTAssertEqual(delay, 1.0, accuracy: 0.0001)
    }

    func testHistoryIdleNextCheckDelayForOverdueStateFallsBackToMinimum() {
        let now = Date()
        let lastSeen: [String: Date] = [
            "session": now.addingTimeInterval(-400)
        ]

        let delay = HistoryIdleMonitor.nextCheckDelay(
            now: now,
            minimumCheckInterval: 1.0,
            idleSeconds: 60.0,
            staleSeconds: 100.0,
            lastSeen: lastSeen
        )
        XCTAssertEqual(delay, 1.0, accuracy: 0.0001)
    }

    func testProcessResourceNextPollIntervalStartsAtMinimum() {
        let interval = ProcessResourceMonitor.nextPollInterval(
            consecutiveNoDataPolls: 0,
            minimumPollInterval: ProcessResourceMonitor.minimumPollInterval,
            maxPollInterval: ProcessResourceMonitor.maxPollInterval,
            noDataBackoffMultiplier: 1.8,
            maxConsecutiveNoDataPolls: 8
        )
        XCTAssertEqual(interval, ProcessResourceMonitor.minimumPollInterval, accuracy: 0.0001)
    }

    func testProcessResourceNextPollIntervalBacksOffAndCaps() {
        let firstBackoff = ProcessResourceMonitor.nextPollInterval(
            consecutiveNoDataPolls: 1,
            minimumPollInterval: ProcessResourceMonitor.minimumPollInterval,
            maxPollInterval: ProcessResourceMonitor.maxPollInterval,
            noDataBackoffMultiplier: ProcessResourceMonitor.noDataBackoffMultiplier,
            maxConsecutiveNoDataPolls: ProcessResourceMonitor.maxConsecutiveNoDataPolls
        )
        XCTAssertEqual(firstBackoff, 1.35, accuracy: 0.0001)

        let capped = ProcessResourceMonitor.nextPollInterval(
            consecutiveNoDataPolls: 100,
            minimumPollInterval: ProcessResourceMonitor.minimumPollInterval,
            maxPollInterval: ProcessResourceMonitor.maxPollInterval,
            noDataBackoffMultiplier: ProcessResourceMonitor.noDataBackoffMultiplier,
            maxConsecutiveNoDataPolls: ProcessResourceMonitor.maxConsecutiveNoDataPolls
        )
        XCTAssertEqual(capped, ProcessResourceMonitor.maxPollInterval, accuracy: 0.0001)
    }

    func testProcessResourceNextPollIntervalUsesMinimumForInvalidInput() {
        let interval = ProcessResourceMonitor.nextPollInterval(
            consecutiveNoDataPolls: -3,
            minimumPollInterval: ProcessResourceMonitor.minimumPollInterval,
            maxPollInterval: ProcessResourceMonitor.maxPollInterval,
            noDataBackoffMultiplier: ProcessResourceMonitor.noDataBackoffMultiplier,
            maxConsecutiveNoDataPolls: ProcessResourceMonitor.maxConsecutiveNoDataPolls
        )
        XCTAssertEqual(interval, ProcessResourceMonitor.minimumPollInterval, accuracy: 0.0001)
    }

    // MARK: - Helpers

    private func session(
        state: ClaudeCodeMonitor.ClaudeSessionInfo.SessionState,
        lastActivity: Date
    ) -> ClaudeCodeMonitor.ClaudeSessionInfo {
        ClaudeCodeMonitor.ClaudeSessionInfo(
            id: UUID().uuidString,
            projectName: "proj",
            cwd: "/tmp",
            transcriptPath: "/tmp/transcript",
            lastActivity: lastActivity,
            state: state,
            lastToolName: nil
        )
    }
}
#endif
