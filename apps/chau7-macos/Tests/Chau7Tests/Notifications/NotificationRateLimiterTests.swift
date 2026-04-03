import XCTest
@testable import Chau7

@MainActor
final class NotificationRateLimiterTests: XCTestCase {

    // MARK: - Basic Token Consumption

    func testFirstCallSucceeds() {
        let limiter = NotificationRateLimiter()
        XCTAssertTrue(limiter.checkAndConsume(triggerId: "test"))
    }

    func testBurstAllowance() {
        let config = NotificationRateLimiter.Config(
            maxPerMinute: 5,
            burstAllowance: 3,
            cooldownSeconds: 0 // disable cooldown for pure burst testing
        )
        let limiter = NotificationRateLimiter(config: config)

        // Should be able to fire (maxPerMinute + burstAllowance) = 8 times
        var successes = 0
        for _ in 0 ..< 10 {
            if limiter.checkAndConsume(triggerId: "burst") {
                successes += 1
            }
        }
        XCTAssertEqual(successes, 8)
    }

    func testDepletionReturnsFalse() {
        let config = NotificationRateLimiter.Config(
            maxPerMinute: 1,
            burstAllowance: 0,
            cooldownSeconds: 0
        )
        let limiter = NotificationRateLimiter(config: config)

        XCTAssertTrue(limiter.checkAndConsume(triggerId: "drain"))
        XCTAssertFalse(limiter.checkAndConsume(triggerId: "drain"))
    }

    // MARK: - Cooldown

    func testCooldownBlocksRapidFires() {
        let config = NotificationRateLimiter.Config(
            maxPerMinute: 60, // high rate so tokens aren't the bottleneck
            burstAllowance: 10,
            cooldownSeconds: 5
        )
        let limiter = NotificationRateLimiter(config: config)

        XCTAssertTrue(limiter.checkAndConsume(triggerId: "cool"))
        // Second call immediately after should be blocked by cooldown
        XCTAssertFalse(limiter.checkAndConsume(triggerId: "cool"))
    }

    // MARK: - Per-Trigger Independence

    func testDifferentTriggersAreIndependent() {
        let config = NotificationRateLimiter.Config(
            maxPerMinute: 1,
            burstAllowance: 0,
            cooldownSeconds: 0
        )
        let limiter = NotificationRateLimiter(config: config)

        XCTAssertTrue(limiter.checkAndConsume(triggerId: "A"))
        XCTAssertFalse(limiter.checkAndConsume(triggerId: "A")) // depleted
        XCTAssertTrue(limiter.checkAndConsume(triggerId: "B")) // independent
    }

    // MARK: - Reset

    func testResetClearsAllBuckets() {
        let config = NotificationRateLimiter.Config(
            maxPerMinute: 1,
            burstAllowance: 0,
            cooldownSeconds: 0
        )
        let limiter = NotificationRateLimiter(config: config)

        XCTAssertTrue(limiter.checkAndConsume(triggerId: "reset"))
        XCTAssertFalse(limiter.checkAndConsume(triggerId: "reset"))

        limiter.reset()

        XCTAssertTrue(limiter.checkAndConsume(triggerId: "reset"))
    }

    // MARK: - Custom Config

    func testCustomConfigApplies() {
        let config = NotificationRateLimiter.Config(
            maxPerMinute: 2,
            burstAllowance: 1,
            cooldownSeconds: 0
        )
        let limiter = NotificationRateLimiter(config: config)

        // Should get 3 tokens (2 + 1)
        XCTAssertTrue(limiter.checkAndConsume(triggerId: "custom"))
        XCTAssertTrue(limiter.checkAndConsume(triggerId: "custom"))
        XCTAssertTrue(limiter.checkAndConsume(triggerId: "custom"))
        XCTAssertFalse(limiter.checkAndConsume(triggerId: "custom"))
    }

    func testZeroMaxPerMinuteDoesNotCrash() {
        let config = NotificationRateLimiter.Config(
            maxPerMinute: 0,
            burstAllowance: 1,
            cooldownSeconds: 0
        )
        let limiter = NotificationRateLimiter(config: config)

        // Should get burstAllowance (1) token
        XCTAssertTrue(limiter.checkAndConsume(triggerId: "zero"))
        XCTAssertFalse(limiter.checkAndConsume(triggerId: "zero"))
    }

    // MARK: - Default Config

    func testDefaultConfigValues() {
        let config = NotificationRateLimiter.Config.default
        XCTAssertEqual(config.maxPerMinute, 5)
        XCTAssertEqual(config.burstAllowance, 3)
        XCTAssertEqual(config.cooldownSeconds, 10)
    }

    // MARK: - Initial Token Count

    func testInitialTokensEqualMaxPlusBurst() {
        let config = NotificationRateLimiter.Config(
            maxPerMinute: 3,
            burstAllowance: 2,
            cooldownSeconds: 0
        )
        let limiter = NotificationRateLimiter(config: config)

        var count = 0
        while limiter.checkAndConsume(triggerId: "count") {
            count += 1
            if count > 100 { break } // safety
        }
        XCTAssertEqual(count, 5) // 3 + 2
    }
}
