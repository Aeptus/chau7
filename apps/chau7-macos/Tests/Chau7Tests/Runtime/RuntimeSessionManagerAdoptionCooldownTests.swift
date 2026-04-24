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
}
