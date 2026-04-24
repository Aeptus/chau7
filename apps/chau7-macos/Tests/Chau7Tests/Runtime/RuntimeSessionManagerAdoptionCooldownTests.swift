import XCTest
@testable import Chau7

final class RuntimeSessionManagerAdoptionCooldownTests: XCTestCase {
    override func setUp() {
        super.setUp()
        RuntimeSessionManager.shared.resetForTesting()
    }

    override func tearDown() {
        RuntimeSessionManager.shared.resetForTesting()
        super.tearDown()
    }

    func testCooldownSkipsRepeatedFailuresWithinWindow() {
        let manager = RuntimeSessionManager.shared
        let key = "cwd:/tmp/cooldown-\(UUID().uuidString)"
        let t0 = Date(timeIntervalSince1970: 1000)

        XCTAssertFalse(
            manager.shouldSkipAdoptionByCooldown(key, now: t0),
            "fresh key must not be skipped"
        )

        manager.recordAdoptionFailure(key, now: t0)
        XCTAssertTrue(
            manager.shouldSkipAdoptionByCooldown(key, now: t0.addingTimeInterval(0.5)),
            "recent failure must be within cooldown"
        )
    }

    func testCooldownElapsesAndRetries() {
        let manager = RuntimeSessionManager.shared
        let key = "cwd:/tmp/cooldown-\(UUID().uuidString)"
        let t0 = Date(timeIntervalSince1970: 1000)

        manager.recordAdoptionFailure(key, now: t0)

        // After the cooldown window, the same key must be eligible for retry —
        // this is the contract the old permanent failedAdoptionKeys set broke.
        let afterWindow = t0.addingTimeInterval(10)
        XCTAssertFalse(
            manager.shouldSkipAdoptionByCooldown(key, now: afterWindow),
            "cooldown must elapse — no permanent lockouts"
        )
    }

    func testResetAdoptionCacheClearsFailures() {
        let manager = RuntimeSessionManager.shared
        let key = "cwd:/tmp/cooldown-\(UUID().uuidString)"
        let t0 = Date(timeIntervalSince1970: 1000)

        manager.recordAdoptionFailure(key, now: t0)
        XCTAssertTrue(manager.shouldSkipAdoptionByCooldown(key, now: t0))

        manager.resetAdoptionCache()
        XCTAssertFalse(
            manager.shouldSkipAdoptionByCooldown(key, now: t0),
            "resetAdoptionCache must clear every recorded failure"
        )
    }

    func testDifferentKeysAreIndependent() {
        let manager = RuntimeSessionManager.shared
        let keyA = "cwd:/tmp/a-\(UUID().uuidString)"
        let keyB = "cwd:/tmp/b-\(UUID().uuidString)"
        let t0 = Date(timeIntervalSince1970: 1000)

        manager.recordAdoptionFailure(keyA, now: t0)
        XCTAssertTrue(manager.shouldSkipAdoptionByCooldown(keyA, now: t0))
        XCTAssertFalse(
            manager.shouldSkipAdoptionByCooldown(keyB, now: t0),
            "keyA failure must not affect keyB"
        )
    }

    // MARK: - W3.19 chronic-orphan tracker

    func testChronicOrphanLogDecision_belowThreshold_emitsLog() {
        let manager = RuntimeSessionManager.shared
        let sessionID = "orphan-\(UUID().uuidString)"
        let t0 = Date(timeIntervalSince1970: 1000)

        // First 5 failures well before the duration window — all emit.
        for i in 0 ..< 5 {
            let decision = manager.decideChronicOrphanLog(
                sessionID: sessionID,
                now: t0.addingTimeInterval(Double(i))
            )
            XCTAssertEqual(decision, .log, "failure #\(i + 1) should still emit")
        }
    }

    func testChronicOrphanLogDecision_crossingThreshold_emitsSuppressionMarker() {
        let manager = RuntimeSessionManager.shared
        let sessionID = "orphan-\(UUID().uuidString)"
        let t0 = Date(timeIntervalSince1970: 2000)

        // 5 failures across 70 seconds — past the duration window but
        // not yet the 6-failure count threshold.
        for i in 0 ..< 5 {
            _ = manager.decideChronicOrphanLog(
                sessionID: sessionID,
                now: t0.addingTimeInterval(Double(i) * 15.0)
            )
        }

        // Sixth failure, also past duration — should emit the marker
        // (one-time crossing signal, not a repeated suppress).
        let sixthDecision = manager.decideChronicOrphanLog(
            sessionID: sessionID,
            now: t0.addingTimeInterval(75.0)
        )
        XCTAssertEqual(sixthDecision, .logSuppressionMarker)

        // Seventh and later failures past threshold should suppress silently.
        let seventhDecision = manager.decideChronicOrphanLog(
            sessionID: sessionID,
            now: t0.addingTimeInterval(80.0)
        )
        XCTAssertEqual(seventhDecision, .suppress)
    }

    func testChronicOrphanLogDecision_requiresBothCountAndDuration() {
        // A burst of 20 failures in 10 seconds — count is past threshold
        // but duration is NOT. Must still emit normal warnings until the
        // duration window is also crossed.
        let manager = RuntimeSessionManager.shared
        let sessionID = "burst-\(UUID().uuidString)"
        let t0 = Date(timeIntervalSince1970: 3000)

        for i in 0 ..< 20 {
            let decision = manager.decideChronicOrphanLog(
                sessionID: sessionID,
                now: t0.addingTimeInterval(Double(i) * 0.5)
            )
            XCTAssertEqual(
                decision,
                .log,
                "short-duration burst (#\(i + 1)) must not trigger chronic suppression"
            )
        }
    }

    func testChronicOrphanLogDecision_resetClearsSuppression() {
        let manager = RuntimeSessionManager.shared
        let sessionID = "reset-\(UUID().uuidString)"
        let t0 = Date(timeIntervalSince1970: 4000)

        // Drive into suppressed state.
        for i in 0 ..< 10 {
            _ = manager.decideChronicOrphanLog(
                sessionID: sessionID,
                now: t0.addingTimeInterval(Double(i) * 10.0)
            )
        }
        XCTAssertEqual(
            manager.decideChronicOrphanLog(sessionID: sessionID, now: t0.addingTimeInterval(120)),
            .suppress,
            "precondition: session should be suppressed"
        )

        // Reset should restore logging.
        manager.resetAdoptionCache()
        let decision = manager.decideChronicOrphanLog(
            sessionID: sessionID,
            now: t0.addingTimeInterval(130)
        )
        XCTAssertEqual(decision, .log, "resetAdoptionCache must un-suppress")
    }

    func testChronicOrphanLogDecision_perSessionIndependence() {
        // Suppression for session A must not affect session B.
        let manager = RuntimeSessionManager.shared
        let sessionA = "A-\(UUID().uuidString)"
        let sessionB = "B-\(UUID().uuidString)"
        let t0 = Date(timeIntervalSince1970: 5000)

        for i in 0 ..< 10 {
            _ = manager.decideChronicOrphanLog(
                sessionID: sessionA,
                now: t0.addingTimeInterval(Double(i) * 10.0)
            )
        }
        XCTAssertEqual(
            manager.decideChronicOrphanLog(sessionID: sessionA, now: t0.addingTimeInterval(120)),
            .suppress
        )
        XCTAssertEqual(
            manager.decideChronicOrphanLog(sessionID: sessionB, now: t0.addingTimeInterval(120)),
            .log,
            "session B is fresh — must not inherit session A's suppression"
        )
    }
}
