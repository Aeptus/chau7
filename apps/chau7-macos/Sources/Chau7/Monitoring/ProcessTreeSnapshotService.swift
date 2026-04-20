import Foundation
import Chau7Core

/// Shared periodic `ps` poll so many sessions derive their live AI-tool identity
/// from a single snapshot per tick instead of each shelling out independently.
///
/// Subscribers receive snapshots on the main queue. The underlying subprocess runs
/// on a utility queue to keep main responsive. The timer only runs while there is
/// at least one subscriber; idle app state costs nothing.
final class ProcessTreeSnapshotService {
    static let shared = ProcessTreeSnapshotService()

    struct Subscription: Hashable {
        let id: UUID
    }

    private let lock = NSLock()
    private var subscribers: [UUID: (ProcessTreeProviderResolver.Snapshot) -> Void] = [:]
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(
        label: "com.chau7.process-tree-snapshot",
        qos: .utility
    )

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
        lock.lock()
        subscribers[subscription.id] = onSnapshot
        let shouldStart = subscribers.count == 1 && timer == nil
        lock.unlock()
        if shouldStart {
            startTimer()
        }
        // Fire an immediate snapshot so new subscribers don't wait a full interval.
        queue.async { [weak self] in self?.capture() }
        return subscription
    }

    func unsubscribe(_ subscription: Subscription) {
        lock.lock()
        subscribers.removeValue(forKey: subscription.id)
        let shouldStop = subscribers.isEmpty
        lock.unlock()
        if shouldStop {
            stopTimer()
        }
    }

    /// Fires a snapshot outside the regular tick — used by shell-integration events
    /// (`.promptStart`, `.commandStart`, `.commandFinished`) so the live signal
    /// catches transitions faster than the fixed poll.
    func refreshNow() {
        queue.async { [weak self] in self?.capture() }
    }

    // MARK: - Private

    private func startTimer() {
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(
            deadline: .now() + Self.pollInterval,
            repeating: Self.pollInterval
        )
        source.setEventHandler { [weak self] in self?.capture() }
        source.resume()
        lock.lock()
        timer = source
        lock.unlock()
    }

    private func stopTimer() {
        lock.lock()
        let existing = timer
        timer = nil
        lock.unlock()
        existing?.cancel()
    }

    private func capture() {
        guard let snapshot = ProcessTreeProviderResolver.captureSnapshot() else { return }
        lock.lock()
        let callbacks = Array(subscribers.values)
        lock.unlock()
        DispatchQueue.main.async {
            for callback in callbacks {
                callback(snapshot)
            }
        }
    }
}
