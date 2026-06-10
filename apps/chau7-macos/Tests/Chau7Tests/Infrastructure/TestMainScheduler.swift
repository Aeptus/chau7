import Foundation
@testable import Chau7

/// Virtual-time `MainScheduler` for unit tests. Queues work without
/// touching the run loop and runs it when `advance(by:)` crosses each
/// item's deadline.
///
/// Tests should construct one of these, hand it to the system under test
/// in lieu of `SystemMainScheduler()`, and step time forward in the
/// quantities the policy under test cares about. No real time passes.
final class TestMainScheduler: MainScheduler {
    private struct Pending {
        let id: Int
        let deadline: TimeInterval
        let work: () -> Void
    }

    private var pending: [Pending] = []
    private var nextID = 0
    private(set) var virtualTime: TimeInterval = 0
    private(set) var totalScheduledHops = 0

    func async(_ work: @escaping () -> Void) {
        enqueue(deadline: virtualTime, work: work)
    }

    func asyncAfter(seconds: TimeInterval, _ work: @escaping () -> Void) {
        enqueue(deadline: virtualTime + seconds, work: work)
    }

    private func enqueue(deadline: TimeInterval, work: @escaping () -> Void) {
        pending.append(Pending(id: nextID, deadline: deadline, work: work))
        nextID += 1
        totalScheduledHops += 1
    }

    /// Advance virtual time by `seconds` and run every work item whose
    /// deadline sits at or before the new virtual time, in deadline order.
    /// Work scheduled by a fired item runs only when its own deadline is
    /// crossed (so a chain of `asyncAfter(0.25, …)` calls needs repeated
    /// `advance` to drain).
    func advance(by seconds: TimeInterval) {
        virtualTime += seconds
        while let nextIndex = pending
            .enumerated()
            .filter({ $0.element.deadline <= virtualTime })
            .min(by: { ($0.element.deadline, $0.element.id) < ($1.element.deadline, $1.element.id) })?
            .offset {
            let item = pending.remove(at: nextIndex)
            item.work()
        }
    }

    /// Drain everything pending regardless of deadline. Useful for tests
    /// that just want every queued continuation to run.
    func drain() {
        let snapshot = pending.sorted { ($0.deadline, $0.id) < ($1.deadline, $1.id) }
        pending.removeAll()
        for item in snapshot {
            item.work()
        }
    }

    var pendingCount: Int { pending.count }
}
