import XCTest
@testable import Chau7Core

/// Regression coverage for the hang-watchdog child's lifetime.
///
/// The watchdog is spawned on the first detected main-thread stall and was
/// written to supervise "until the parent dies". Observed in the field: a single
/// stall seven seconds after launch left a `--hang-watchdog` process alive for
/// 12h40m, still sleeping — holding a process slot and, because it is forked
/// from the app, a copy of the app's inherited descriptors including the remote
/// IPC socket. That ambiguity is what made "which process owns `remote.sock`?"
/// unanswerable during triage.
///
/// The child's job is one diagnostic sample for one stall, so it should exit as
/// soon as the main thread is demonstrably advancing again.
final class MainThreadHangWatchdogLifetimeTests: XCTestCase {
    private let start = 1000.0
    private let grace = MainThreadHangWatchdogLifetime.healthyGraceSeconds

    private func lifetime() -> MainThreadHangWatchdogLifetime {
        MainThreadHangWatchdogLifetime(startedAt: start)
    }

    // MARK: - The stuck case this fixes

    func testHealthyMainThreadEventuallyRetiresTheChild() {
        var lifetime = lifetime()
        // Stall for a while, then the main thread recovers.
        for tick in 0 ..< 20 {
            lifetime.observe(isHealthy: false, capturedSampleNow: false, now: start + Double(tick) * 0.25)
        }
        let sampleAt = start + 5
        lifetime.observe(isHealthy: false, capturedSampleNow: true, now: sampleAt)
        XCTAssertTrue(lifetime.hasCapturedSample)

        // The child stays while the main thread is still stalled, even after it
        // has written its sample.
        XCTAssertFalse(lifetime.shouldExit(parentIsAlive: true, now: sampleAt + grace + 10))

        // Recovery starts the grace window.
        let recoveredAt = sampleAt + 0.25
        lifetime.observe(isHealthy: true, capturedSampleNow: false, now: recoveredAt)

        // Still inside the grace window: exiting instantly would re-spawn a
        // child every time a stall flickers.
        XCTAssertFalse(lifetime.shouldExit(parentIsAlive: true, now: recoveredAt + 0.1))

        // But it does not outlive the recovery by more than the grace.
        XCTAssertTrue(lifetime.shouldExit(parentIsAlive: true, now: recoveredAt + grace + 0.01))
    }

    /// A child that never sampled and never stalls — a false-positive launch —
    /// must still retire, or the parent is worse off than with no watchdog.
    func testChildWithNoStallStillRetires() {
        var lifetime = lifetime()
        lifetime.observe(isHealthy: true, capturedSampleNow: false, now: start)

        XCTAssertFalse(lifetime.shouldExit(parentIsAlive: true, now: start + grace - 0.1))
        XCTAssertTrue(lifetime.shouldExit(parentIsAlive: true, now: start + grace + 0.01))
    }

    // MARK: - Staying alive when it matters

    /// The whole point: while the main thread is still stalled, the child must
    /// stay to capture the sample.
    func testChildStaysAliveWhileStalled() {
        var lifetime = lifetime()
        for tick in 0 ..< 200 {
            lifetime.observe(isHealthy: false, capturedSampleNow: false, now: start + Double(tick) * 0.25)
        }

        XCTAssertFalse(
            lifetime.shouldExit(parentIsAlive: true, now: start + 50),
            "a watchdog must not retire while the main thread is still stalled"
        )
    }

    /// A stall recurring inside the grace window restarts the clock, so a
    /// flapping main thread does not accumulate short-lived children.
    func testRecurringStallResetsTheGraceWindow() {
        var lifetime = lifetime()
        lifetime.observe(isHealthy: true, capturedSampleNow: false, now: start)
        lifetime.observe(isHealthy: true, capturedSampleNow: false, now: start + grace - 0.2)

        // Stall again just before the grace would have elapsed.
        lifetime.observe(isHealthy: false, capturedSampleNow: false, now: start + grace - 0.1)
        XCTAssertFalse(lifetime.shouldExit(parentIsAlive: true, now: start + grace + 0.5))

        // Recovery starts a fresh window from the new time.
        let recoveredAt = start + grace + 0.5
        lifetime.observe(isHealthy: true, capturedSampleNow: false, now: recoveredAt)
        XCTAssertFalse(lifetime.shouldExit(parentIsAlive: true, now: recoveredAt + grace - 0.1))
        XCTAssertTrue(lifetime.shouldExit(parentIsAlive: true, now: recoveredAt + grace + 0.1))
    }

    // MARK: - Parent death

    /// The original exit condition must keep working, even mid-stall.
    func testParentDeathExitsImmediately() {
        var lifetime = lifetime()
        lifetime.observe(isHealthy: false, capturedSampleNow: false, now: start)

        XCTAssertTrue(lifetime.shouldExit(parentIsAlive: false, now: start))
    }

    // MARK: - Backstop

    /// A child that somehow never sees a readable heartbeat must not live
    /// forever. The heartbeat check in the runner already exits on an unreadable
    /// heartbeat; this is the belt to that braces.
    func testMaximumLifetimeIsBounded() {
        var lifetime = lifetime()
        // Never healthy, never sampled.
        XCTAssertFalse(lifetime.shouldExit(parentIsAlive: true, now: start + 60))
        XCTAssertTrue(
            lifetime.shouldExit(parentIsAlive: true, now: start + 3601),
            "the child must be bounded even if it never observes health"
        )
    }

    // MARK: - Sample bookkeeping

    func testCapturedSampleIsRecorded() {
        var lifetime = lifetime()
        XCTAssertFalse(lifetime.hasCapturedSample)

        lifetime.observe(isHealthy: false, capturedSampleNow: true, now: start)
        XCTAssertTrue(lifetime.hasCapturedSample)
    }

    func testHealthySinceTracksOnlyContinuousHealth() {
        var lifetime = lifetime()
        XCTAssertNil(lifetime.healthySince)

        lifetime.observe(isHealthy: true, capturedSampleNow: false, now: start)
        XCTAssertEqual(lifetime.healthySince, start)

        lifetime.observe(isHealthy: false, capturedSampleNow: false, now: start + 1)
        XCTAssertNil(lifetime.healthySince, "a stall must clear the healthy window")
    }

    func testGraceIsPositive() {
        XCTAssertGreaterThan(
            MainThreadHangWatchdogLifetime.healthyGraceSeconds, 0,
            "a zero grace would exit on the first healthy tick and thrash the child"
        )
    }
}
