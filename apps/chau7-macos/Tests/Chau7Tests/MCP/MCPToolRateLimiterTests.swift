import XCTest
import Chau7Core

final class MCPToolRateLimiterTests: XCTestCase {
    func testAllowsBurstThenBlocksUntilRefill() {
        var limiter = MCPToolRateLimiter(
            config: .init(defaultLimit: .init(maxPerMinute: 1, burstAllowance: 1))
        )
        let start = Date(timeIntervalSinceReferenceDate: 100)

        XCTAssertTrue(limiter.evaluate(toolName: "tab_create", now: start).isAllowed)
        XCTAssertTrue(limiter.evaluate(toolName: "tab_create", now: start).isAllowed)

        let blocked = limiter.evaluate(toolName: "tab_create", now: start)
        XCTAssertFalse(blocked.isAllowed)
        XCTAssertEqual(blocked.retryAfterSeconds ?? 0, 60, accuracy: 0.001)

        let allowedAfterRefill = limiter.evaluate(toolName: "tab_create", now: start.addingTimeInterval(60))
        XCTAssertTrue(allowedAfterRefill.isAllowed)
    }

    func testBucketsAreIndependentPerTool() {
        var limiter = MCPToolRateLimiter(
            config: .init(defaultLimit: .init(maxPerMinute: 1, burstAllowance: 0))
        )
        let now = Date(timeIntervalSinceReferenceDate: 200)

        XCTAssertTrue(limiter.evaluate(toolName: "tab_create", now: now).isAllowed)
        XCTAssertFalse(limiter.evaluate(toolName: "tab_create", now: now).isAllowed)
        XCTAssertTrue(limiter.evaluate(toolName: "runtime_events_poll", now: now).isAllowed)
    }

    func testToolSpecificOverridesApply() {
        var limiter = MCPToolRateLimiter(
            config: .init(
                defaultLimit: .init(maxPerMinute: 1, burstAllowance: 0),
                perToolLimits: ["runtime_events_poll": .init(maxPerMinute: 2, burstAllowance: 1)]
            )
        )
        let now = Date(timeIntervalSinceReferenceDate: 300)

        XCTAssertTrue(limiter.evaluate(toolName: "runtime_events_poll", now: now).isAllowed)
        XCTAssertTrue(limiter.evaluate(toolName: "runtime_events_poll", now: now).isAllowed)
        XCTAssertTrue(limiter.evaluate(toolName: "runtime_events_poll", now: now).isAllowed)
        XCTAssertFalse(limiter.evaluate(toolName: "runtime_events_poll", now: now).isAllowed)

        XCTAssertTrue(limiter.evaluate(toolName: "tab_exec", now: now).isAllowed)
        XCTAssertFalse(limiter.evaluate(toolName: "tab_exec", now: now).isAllowed)
    }

    func testZeroRefillLimitReturnsNilRetryAfter() {
        var limiter = MCPToolRateLimiter(
            config: .init(defaultLimit: .init(maxPerMinute: 0, burstAllowance: 1))
        )
        let now = Date(timeIntervalSinceReferenceDate: 400)

        XCTAssertTrue(limiter.evaluate(toolName: "runtime_session_create", now: now).isAllowed)
        let blocked = limiter.evaluate(toolName: "runtime_session_create", now: now)
        XCTAssertFalse(blocked.isAllowed)
        XCTAssertNil(blocked.retryAfterSeconds)
    }
}
