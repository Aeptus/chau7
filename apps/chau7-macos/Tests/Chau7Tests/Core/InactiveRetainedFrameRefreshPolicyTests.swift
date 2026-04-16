import XCTest
@testable import Chau7Core

final class InactiveRetainedFrameRefreshPolicyTests: XCTestCase {
    func testSkipsWhenAlreadyRenderedCurrentVersion() {
        let decision = InactiveRetainedFrameRefreshPolicy.decide(
            phase: .warm,
            hasRetainedFrameSourceReady: true,
            contentVersion: 4,
            sourceVersion: 4,
            lastRenderedVersion: 4,
            pendingVersion: nil,
            now: 10,
            lastRefreshAt: 9.9,
            minInterval: 0.25
        )

        XCTAssertEqual(decision, .skip)
    }

    func testSchedulesDelayedCachedRefreshWhenSourceIsCurrent() {
        let decision = InactiveRetainedFrameRefreshPolicy.decide(
            phase: .passiveVisible,
            hasRetainedFrameSourceReady: true,
            contentVersion: 7,
            sourceVersion: 7,
            lastRenderedVersion: 6,
            pendingVersion: nil,
            now: 10,
            lastRefreshAt: 9.9,
            minInterval: 0.25
        )

        XCTAssertEqual(decision.action, .schedule)
        XCTAssertEqual(decision.targetVersion, 7)
        XCTAssertFalse(decision.allowForcedSync)
        XCTAssertEqual(decision.delay, 0.15, accuracy: 0.001)
    }

    func testSchedulesForcedRefreshWhenSourceIsStale() {
        let decision = InactiveRetainedFrameRefreshPolicy.decide(
            phase: .warm,
            hasRetainedFrameSourceReady: true,
            contentVersion: 8,
            sourceVersion: 6,
            lastRenderedVersion: 6,
            pendingVersion: nil,
            now: 10,
            lastRefreshAt: 9,
            minInterval: 0.25
        )

        XCTAssertEqual(decision.action, .schedule)
        XCTAssertEqual(decision.targetVersion, 8)
        XCTAssertTrue(decision.allowForcedSync)
        XCTAssertEqual(decision.delay, 0, accuracy: 0.001)
    }

    func testUpdatesPendingRefreshToNewerVersion() {
        let decision = InactiveRetainedFrameRefreshPolicy.decide(
            phase: .warm,
            hasRetainedFrameSourceReady: false,
            contentVersion: 9,
            sourceVersion: 0,
            lastRenderedVersion: 7,
            pendingVersion: 8,
            now: 10,
            lastRefreshAt: 9.8,
            minInterval: 0.25
        )

        XCTAssertEqual(decision.action, .updatePending)
        XCTAssertEqual(decision.targetVersion, 9)
        XCTAssertTrue(decision.allowForcedSync)
        XCTAssertEqual(decision.delay, 0, accuracy: 0.001)
    }

    func testSkipsWhenActiveEvenWithNewContent() {
        let decision = InactiveRetainedFrameRefreshPolicy.decide(
            phase: .active,
            hasRetainedFrameSourceReady: false,
            contentVersion: 5,
            sourceVersion: 0,
            lastRenderedVersion: 4,
            pendingVersion: nil,
            now: 10,
            lastRefreshAt: 9,
            minInterval: 0.25
        )

        XCTAssertEqual(decision, .skip)
    }
}
