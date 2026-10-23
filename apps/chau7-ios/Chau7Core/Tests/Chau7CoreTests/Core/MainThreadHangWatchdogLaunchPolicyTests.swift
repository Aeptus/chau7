import XCTest
@testable import Chau7Core

/// Regression coverage for the watchdog *spawn* decision, in the controller.
///
/// ## The regression
///
/// `launchIndependentWatchdog()` used to be called unconditionally on every
/// monitor tick. That was safe only for as long as the `--hang-watchdog` child
/// never exited on its own: it looped `while parentIsAlive`, so it lived for the
/// app's whole lifetime, `watchdogProcess` stayed non-nil, and the
/// `watchdogProcess == nil` guard inside the launcher suppressed every respawn.
///
/// Teaching the child to retire once the main thread was healthy (see
/// `MainThreadHangWatchdogLifetimeTests`) flipped that invariant. The child then
/// exited within a second or two, the controller cleared the handle, and the
/// next tick spawned a replacement — which retired, which spawned another. A
/// live install logged 2806 starts and 2805 replacements on a ~3 second cycle.
///
/// The child and its lifetime are both correct in isolation; the defect is
/// entirely in how the parent reacts to the child exiting. That is what these
/// tests pin down.
final class MainThreadHangWatchdogLaunchPolicyTests: XCTestCase {
    private func action(
        stalled: Bool,
        enteredStall: Bool = false,
        running: Bool?
    ) -> MainThreadHangWatchdogLaunchAction {
        MainThreadHangWatchdogLifetime.launchAction(
            phaseIsStalled: stalled,
            enteredStall: enteredStall,
            existingWatchdogRunning: running
        )
    }

    // MARK: - The loop this prevents

    /// The regression in one assertion: a healthy main thread must never spawn,
    /// however stale the child handle is. An unconditional launch here is the
    /// fork/exec loop.
    func testHealthyMainThreadNeverLaunches() {
        XCTAssertEqual(action(stalled: false, running: nil), .idle)
        XCTAssertEqual(action(stalled: false, running: true), .idle)
        XCTAssertEqual(action(stalled: false, running: false), .idle)
    }

    /// End-to-end shape of the loop: healthy -> child exits -> healthy again.
    /// Every step must be `.idle`, so no spawn can occur at any point.
    func testHealthyChildExitDoesNotRespawn() {
        var launches = 0
        // Simulate a healthy main thread with a child that has just retired.
        for existing in [true, false, nil, false, true] {
            if action(stalled: false, running: existing) == .launch { launches += 1 }
        }
        XCTAssertEqual(launches, 0, "a healthy main thread must never spawn a child")
    }

    /// Simulate the real tick loop across a healthy period. This is the loop that
    /// produced 2806 spawns.
    func testRepeatedHealthyTicksProduceNoLaunches() {
        var launches = 0
        for tick in 0 ..< 500 {
            // The child is alive for a couple of ticks, then retires.
            let running: Bool? = tick < 2 ? true : (tick == 2 ? false : nil)
            if action(stalled: false, running: running) == .launch { launches += 1 }
        }
        XCTAssertEqual(launches, 0, "500 healthy ticks must produce zero spawns")
    }

    // MARK: - It must still work when it matters

    /// A stall begins: spawn.
    func testStallEntryLaunches() {
        XCTAssertEqual(action(stalled: true, enteredStall: true, running: nil), .launch)
        XCTAssertEqual(action(stalled: true, enteredStall: true, running: true), .launch)
    }

    /// An ongoing stall whose child died still needs one, or a hang that lasts
    /// longer than one child's life would go unsampled.
    func testStallWithDeadChildReplaces() {
        XCTAssertEqual(action(stalled: true, running: false), .replace)
        XCTAssertEqual(action(stalled: true, enteredStall: true, running: false), .replace)
    }

    /// An ongoing stall with a live child is idempotent — the launcher's own
    /// guard makes `launch` a no-op, so this must not become `replace`.
    func testStallWithLiveChildDoesNotReplace() {
        XCTAssertEqual(action(stalled: true, running: true), .launch)
    }

    /// Recovery ends the stall, so a live child is left to retire on its own and
    /// the handle is dropped.
    func testRecoveryIsIdleEvenWithLiveChild() {
        XCTAssertEqual(action(stalled: false, running: true), .idle)
    }

    // MARK: - Ordering guarantee

    /// A stall that both begins this tick and replaces a dead child must still
    /// end with exactly one spawn, never zero.
    func testReplacementAlwaysLeadsToExactlyOneSpawn() {
        let decision = action(stalled: true, enteredStall: true, running: false)
        XCTAssertEqual(decision, .replace, "replace must imply a spawn follows")
    }
}
