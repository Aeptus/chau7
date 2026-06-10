import XCTest
@testable import Chau7

/// Polling.untilTrue replaced two hand-rolled DispatchQueue recursion
/// sites that were copy-pasted with subtly different parameters. These
/// tests exercise the helper directly via a virtual-time scheduler so
/// the policy is provable without any real sleeps.
final class PollingTests: XCTestCase {

    func testFiresOnSettledImmediatelyWhenPredicateAlreadyTrue() {
        let scheduler = TestMainScheduler()
        var settled = false

        Polling.untilTrue(
            on: scheduler,
            predicate: { true },
            onSettled: { settled = true }
        )

        XCTAssertTrue(settled)
        XCTAssertEqual(scheduler.pendingCount, 0, "Already-true predicate must not enqueue work")
    }

    func testWaitsUntilPredicateFlipsThenSettles() {
        let scheduler = TestMainScheduler()
        var ready = false
        var settled = false

        Polling.untilTrue(
            on: scheduler,
            every: 0.25,
            attempts: 10,
            predicate: { ready },
            onSettled: { settled = true }
        )

        XCTAssertFalse(settled)
        XCTAssertEqual(scheduler.pendingCount, 1)

        scheduler.advance(by: 0.25)
        XCTAssertFalse(settled, "Predicate still false; runner reschedules")
        XCTAssertEqual(scheduler.pendingCount, 1)

        ready = true
        scheduler.advance(by: 0.25)
        XCTAssertTrue(settled)
        XCTAssertEqual(scheduler.pendingCount, 0)
    }

    func testFiresOnTimeoutAfterAttemptsExhausted() {
        let scheduler = TestMainScheduler()
        var settled = false
        var timedOut = false

        Polling.untilTrue(
            on: scheduler,
            every: 0.1,
            attempts: 3,
            predicate: { false },
            onSettled: { settled = true },
            onTimeout: { timedOut = true }
        )

        // Initial check + 3 scheduled attempts = 4 evaluations total. Spin
        // the scheduler long enough to exhaust them.
        for _ in 0..<5 { scheduler.advance(by: 0.1) }

        XCTAssertFalse(settled)
        XCTAssertTrue(timedOut)
        XCTAssertEqual(scheduler.pendingCount, 0, "Runner must stop after exhausting attempts")
    }

    func testHardBoundOnTotalEvaluations() {
        // A predicate that's permanently false must not schedule more than
        // `attempts` follow-up hops, no matter how many times we advance.
        let scheduler = TestMainScheduler()

        Polling.untilTrue(
            on: scheduler,
            every: 0.1,
            attempts: 5,
            predicate: { false },
            onSettled: { XCTFail("Predicate never true") }
        )

        for _ in 0..<20 { scheduler.advance(by: 0.1) }

        XCTAssertEqual(scheduler.pendingCount, 0)
        XCTAssertLessThanOrEqual(
            scheduler.totalScheduledHops, 5,
            "Polling must respect the attempts ceiling"
        )
    }
}
