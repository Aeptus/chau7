import Foundation
import Chau7Core

/// Shared periodic poll so many sessions derive their live AI-tool identity from a
/// single process-table snapshot per tick instead of each enumerating independently.
///
/// Subscribers receive snapshots on the main queue. Enumeration runs on a
/// user-initiated queue so the live signal isn't deprioritized when the app is busy —
/// previously, on a `.utility` queue, tab-name updates could lag well past the poll
/// interval under load (verbose logging, many active agents, continuous rendering).
/// The timer only runs while there is at least one subscriber; idle app state costs nothing.
final class ProcessTreeSnapshotService {
    static let shared = ProcessTreeSnapshotService()

    struct Subscription: Hashable {
        let id: UUID
    }

    private let lock = NSLock()
    private var subscribers: [UUID: (ProcessTreeProviderResolver.Snapshot) -> Void] = [:]
    private var timer: DispatchSourceTimer?
    /// Coalescing flag: true while an off-tick refresh capture is queued but not yet
    /// started, so a burst of shell events across many tabs can't back up the queue.
    private var refreshScheduled = false
    private let queue = DispatchQueue(
        label: "com.chau7.process-tree-snapshot",
        qos: .userInitiated
    )

    /// Short delays after a command launches at which to re-capture, so a just-`exec`'d
    /// child (e.g. `claude`) is detected within a few hundred ms instead of waiting for
    /// the next fixed poll tick. The command-start event fires before the child exists.
    static let launchSettleDelays: [TimeInterval] = [0.2, 0.6]

    /// Poll interval. Chosen to keep the shell-out cost negligible (~1 `ps` per 1.5s)
    /// while staying responsive enough that tab chrome catches a provider change
    /// within a couple of seconds of launch.
    static let pollInterval: TimeInterval = 1.5

    private init() {}

    @discardableResult
    func subscribe(
        _ onSnapshot: @escaping (ProcessTreeProviderResolver.Snapshot) -> Void
    ) -> Subscription {
        let subscription = Subscription(id: UUID())
        // Timer assignment happens under the same lock as the decision:
        // deciding under the lock but starting/stopping after releasing it
        // let a last-unsubscribe interleave with a first-subscribe and cancel
        // the new subscriber's timer — live tab-name detection then silently
        // stopped until the next subscribe.
        lock.lock()
        subscribers[subscription.id] = onSnapshot
        if subscribers.count == 1, timer == nil {
            timer = makeTimer()
        }
        lock.unlock()
        // Fire an immediate snapshot so new subscribers don't wait a full interval.
        queue.async { [weak self] in self?.capture() }
        return subscription
    }

    func unsubscribe(_ subscription: Subscription) {
        var cancelled: DispatchSourceTimer?
        lock.lock()
        subscribers.removeValue(forKey: subscription.id)
        if subscribers.isEmpty {
            cancelled = timer
            timer = nil
        }
        lock.unlock()
        cancelled?.cancel()
    }

    /// Fires a snapshot outside the regular tick — used by shell-integration events
    /// (`.promptStart`, `.commandStart`, `.commandFinished`) so the live signal catches
    /// transitions faster than the fixed poll. Coalesced: while a refresh capture is
    /// already queued, extra calls are dropped, so a burst of shell events across many
    /// tabs can't pile captures onto the serial queue.
    func refreshNow() {
        lock.lock()
        if refreshScheduled {
            lock.unlock()
            return
        }
        refreshScheduled = true
        lock.unlock()
        queue.async { [weak self] in
            guard let self else { return }
            lock.lock()
            refreshScheduled = false
            lock.unlock()
            capture()
        }
    }

    /// Schedules a short burst of captures after a command launches (see
    /// `launchSettleDelays`). Pairs with an immediate `refreshNow()` from the caller:
    /// the immediate one usually misses the not-yet-`exec`'d child, the burst catches it.
    func scheduleLaunchSettleRefresh() {
        for delay in Self.launchSettleDelays {
            queue.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.capture()
            }
        }
    }

    // MARK: - Private

    /// Source creation is cheap, so it can happen while holding the lock —
    /// which is what makes the subscribe/unsubscribe transitions atomic.
    private func makeTimer() -> DispatchSourceTimer {
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(
            deadline: .now() + Self.pollInterval,
            repeating: Self.pollInterval
        )
        source.setEventHandler { [weak self] in self?.capture() }
        source.resume()
        return source
    }

    private func capture() {
        // Skip enumeration entirely when nobody is tracking — a settle-burst capture
        // can fire after the last subscriber unsubscribed.
        lock.lock()
        let callbacks = Array(subscribers.values)
        lock.unlock()
        guard !callbacks.isEmpty else { return }
        guard let snapshot = ProcessTreeProviderResolver.captureSnapshot() else { return }
        DispatchQueue.main.async {
            for callback in callbacks {
                callback(snapshot)
            }
        }
    }
}
