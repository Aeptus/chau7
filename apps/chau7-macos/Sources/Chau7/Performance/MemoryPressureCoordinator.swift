import Foundation

/// Severity of an OS memory-pressure signal, decoupled from the breadcrumb's
/// `Severity` so cache owners depend on this small contract, not on telemetry types.
enum MemoryPressureLevel {
    /// Early signal — shed cheap, fully-regenerable memory; keep recent context.
    case warning
    /// Late signal — release reclaimable memory aggressively.
    case critical
}

/// A cache or buffer that can release memory on demand under OS memory pressure.
///
/// Conformers register once (typically at init) with `MemoryPressureCoordinator`,
/// which holds them weakly. `reclaimMemory(_:)` must be safe to call from a
/// background queue and return the number of bytes it released (best-effort estimate),
/// which the coordinator sums so the response is observable in telemetry.
protocol MemoryReclaimable: AnyObject {
    @discardableResult
    func reclaimMemory(_ level: MemoryPressureLevel) -> Int
}

/// Central fan-out for memory-pressure reclamation.
///
/// Previously the OS pressure signal was only logged — no cache ever shrank in
/// response. This coordinator turns that passive signal into an actionable one:
/// `MemoryPressureResponder` calls `reclaim(_:)`, which broadcasts to every
/// registered `MemoryReclaimable`. Owners register themselves (open/closed — adding
/// a new reclaimable is a one-line `register` call), and the coordinator keeps only
/// weak references so deregistration is automatic when an owner is freed.
final class MemoryPressureCoordinator {
    static let shared = MemoryPressureCoordinator()

    private let lock = NSLock()
    private var registrants: [Weak] = []

    private final class Weak {
        weak var value: MemoryReclaimable?
        init(_ value: MemoryReclaimable) {
            self.value = value
        }
    }

    init() {}

    /// Registers a reclaimable. Held weakly; safe to call more than once for the
    /// same instance only in the sense that duplicates are coalesced lazily — callers
    /// should register exactly once (e.g. in `init`).
    func register(_ reclaimable: MemoryReclaimable) {
        lock.lock()
        defer { lock.unlock() }
        registrants.removeAll { $0.value == nil || $0.value === reclaimable }
        registrants.append(Weak(reclaimable))
    }

    /// Broadcasts a reclaim request to all live registrants and returns the total
    /// bytes freed. Dead weak slots are pruned. The registrant snapshot is taken
    /// under the lock and released before calling out, so a reclaimable may touch
    /// the coordinator without deadlocking.
    @discardableResult
    func reclaim(_ level: MemoryPressureLevel) -> Int {
        lock.lock()
        let targets = registrants.compactMap(\.value)
        registrants.removeAll { $0.value == nil }
        lock.unlock()

        return targets.reduce(0) { $0 + $1.reclaimMemory(level) }
    }

    /// Number of live registrants (testing/diagnostics).
    var registrantCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return registrants.compactMap(\.value).count
    }
}
