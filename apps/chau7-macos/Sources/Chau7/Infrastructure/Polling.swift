import Foundation

/// Generic "poll until a predicate is true, give up after N hops" helper.
/// Replaces two hand-rolled DispatchQueue-recursion sites (markdown runbook
/// settle polling and editor-load settle polling) so the predicate logic
/// stops bleeding into the controller and tests can drive it via a
/// virtual-time `MainScheduler`.
enum Polling {
    /// Calls `predicate` on the scheduler and settles on `onSettled` the
    /// first time it returns true. The first check runs synchronously, so
    /// already-true predicates don't hit the scheduler at all. After
    /// `attempts` failed checks the runner invokes `onTimeout` and stops.
    ///
    /// `attempts × interval` is the hard upper bound on wall-clock time
    /// the runner will wait for the predicate to flip.
    static func untilTrue(
        on scheduler: MainScheduler,
        every interval: TimeInterval = 0.25,
        attempts: Int = 240,
        predicate: @escaping () -> Bool,
        onSettled: @escaping () -> Void,
        onTimeout: @escaping () -> Void = {}
    ) {
        if predicate() {
            onSettled()
            return
        }
        guard attempts > 0 else {
            onTimeout()
            return
        }
        scheduler.asyncAfter(seconds: interval) {
            untilTrue(
                on: scheduler,
                every: interval,
                attempts: attempts - 1,
                predicate: predicate,
                onSettled: onSettled,
                onTimeout: onTimeout
            )
        }
    }
}
