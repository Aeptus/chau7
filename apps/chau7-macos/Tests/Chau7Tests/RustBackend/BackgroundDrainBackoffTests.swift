import XCTest
@testable import Chau7

final class BackgroundDrainBackoffTests: XCTestCase {
    func testActiveOrRecentlyActiveViewPollsEveryTick() {
        for tick in 1 ... 20 {
            XCTAssertTrue(BackgroundDrainBackoff.shouldPoll(idleStreak: 0, tick: tick))
            XCTAssertTrue(BackgroundDrainBackoff.shouldPoll(idleStreak: 2, tick: tick))
        }
    }

    func testStrideGrowsWithIdleStreakAndCaps() {
        XCTAssertEqual(BackgroundDrainBackoff.stride(forIdleStreak: 0), 1)
        XCTAssertEqual(BackgroundDrainBackoff.stride(forIdleStreak: 2), 1)
        XCTAssertEqual(BackgroundDrainBackoff.stride(forIdleStreak: 3), 2)
        XCTAssertEqual(BackgroundDrainBackoff.stride(forIdleStreak: 4), 3)
        XCTAssertEqual(
            BackgroundDrainBackoff.stride(forIdleStreak: 100),
            BackgroundDrainBackoff.maxStride
        )
    }

    func testDormantViewPollsOncePerStride() {
        // idleStreak 3 → stride 2 → only even ticks
        let shallow = (1 ... 8).filter { BackgroundDrainBackoff.shouldPoll(idleStreak: 3, tick: $0) }
        XCTAssertEqual(shallow, [2, 4, 6, 8])

        // deeply idle → capped stride (8) → once every 8 ticks
        let deep = (1 ... 16).filter { BackgroundDrainBackoff.shouldPoll(idleStreak: 100, tick: $0) }
        XCTAssertEqual(deep, [8, 16])
    }
}
