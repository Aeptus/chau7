#if os(macOS)
import Foundation

/// Decides when the `--hang-watchdog` child should exit.
///
/// The watchdog exists to capture one diagnostic stack sample for one main-thread
/// stall. It is a separate process that outlives the stall it was spawned for,
/// and while it lives it holds a process slot and — because it is `fork`ed from
/// the app — a copy of the app's inherited file descriptors, including the remote
/// IPC socket. A descriptor inherited by an unrelated process makes socket
/// ownership ambiguous and is exactly the kind of thing that turns "which process
/// is serving `remote.sock`?" into guesswork.
///
/// So the child exits as soon as the main thread is demonstrably advancing again.
/// The controller clears `watchdogProcess` once the child is gone and re-arms on
/// the next stall, so exiting early costs nothing.
///
/// Pure and value-typed so the lifetime rule is unit-testable without spawning
/// processes.
public struct MainThreadHangWatchdogLifetime: Equatable, Sendable {
    /// How long the main thread must be continuously healthy before the child
    /// exits. Long enough that a stall recurring within a few hundred ms does not
    /// spawn a fresh child each time (and trip the controller's 5 s launch
    /// throttle repeatedly), short enough that the child is not held for the
    /// app's remaining lifetime.
    public static let healthyGraceSeconds: TimeInterval = 2

    private static let maximumLifetimeSeconds: TimeInterval = 3600

    /// `nil` until the main thread is first observed healthy.
    public private(set) var healthySince: TimeInterval?
    public private(set) var startedAt: TimeInterval
    public private(set) var hasCapturedSample: Bool

    public init(startedAt: TimeInterval) {
        self.startedAt = startedAt
        self.healthySince = nil
        self.hasCapturedSample = false
    }

    /// - Parameters:
    ///   - isHealthy: whether the main thread's progress token advanced this pass.
    ///   - capturedSampleNow: whether a sample was just written.
    ///   - now: wall clock, injected for testability.
    public mutating func observe(
        isHealthy: Bool,
        capturedSampleNow: Bool,
        now: TimeInterval
    ) {
        if capturedSampleNow { hasCapturedSample = true }

        if isHealthy {
            if healthySince == nil { healthySince = now }
        } else {
            // A stall resets the grace window: we are wanted again.
            healthySince = nil
        }
    }

    /// Whether the child should exit after the given observation.
    public func shouldExit(
        parentIsAlive: Bool,
        now: TimeInterval
    ) -> Bool {
        // The parent going away is the original exit condition.
        if !parentIsAlive { return true }

        if let healthySince,
           now - healthySince >= Self.healthyGraceSeconds {
            return true
        }

        // Backstop. A child that never observes a healthy heartbeat and never
        // captures anything is not doing its job, and an unbounded child is
        // worse than no watchdog.
        if now - startedAt >= Self.maximumLifetimeSeconds {
            return true
        }

        return false
    }
}

/// What the controller should do about the watchdog child on one tick.
public enum MainThreadHangWatchdogLaunchAction: Equatable, Sendable {
    /// Spawn a child (the callee's own `isRunning` guard makes this idempotent).
    case launch
    /// A child existed but is gone while a stall continues — clear and respawn.
    case replace
    /// Healthy: drop the handle, do not spawn.
    case idle
}

public extension MainThreadHangWatchdogLifetime {
    /// Whether to launch / replace / idle the watchdog child.
    ///
    /// The bug this encodes against: `launchIndependentWatchdog()` used to run
    /// unconditionally on every tick, which was safe only because the child never
    /// self-exited — the `watchdogProcess == nil` guard then suppressed every
    /// respawn forever. Teaching the child to retire on recovery (see
    /// `MainThreadHangWatchdogLifetime`) flipped that invariant and turned the
    /// tick into a ~3 second fork/exec loop, observed 2806 times in one session.
    ///
    /// The child is a diagnostic aid for a stall, so it is launched only while a
    /// stall is in progress and is otherwise left to retire on its own.
    static func launchAction(
        phaseIsStalled: Bool,
        enteredStall: Bool,
        existingWatchdogRunning: Bool?
    ) -> MainThreadHangWatchdogLaunchAction {
        let stallActive = phaseIsStalled || enteredStall
        guard stallActive else { return .idle }
        if existingWatchdogRunning == false { return .replace }
        return .launch
    }
}
#endif
