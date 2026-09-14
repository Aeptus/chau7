import AppKit
import Chau7Core

/// Bridges OS memory-pressure reclamation onto the main thread for the
/// main-confined per-tab caches that previously never responded to pressure:
/// the search buffer cache (`cachedBufferData`) and the per-view scrollback
/// line cache (`cachedBufferLines`, a full `[String]` duplicate of the Rust
/// ring).
///
/// Policy: `.warning` clears non-selected tabs only (the selected tab's
/// caches are hot); `.critical` clears everything — all of it is regenerable
/// from the Rust terminal state on demand.
///
/// Returns 0 from `reclaimMemory` because the actual clearing hops to main
/// asynchronously; the per-tab byte savings are logged from there instead of
/// flowing into the coordinator's synchronous total.
final class TerminalMemoryReclaimer: MemoryReclaimable {
    static let shared = TerminalMemoryReclaimer()

    private init() {}

    func arm() {
        MemoryPressureCoordinator.shared.register(self)
    }

    @discardableResult
    func reclaimMemory(_ level: MemoryPressureLevel) -> Int {
        DispatchQueue.main.async {
            Self.reclaimOnMain(level)
        }
        return 0
    }

    /// Runs on the existing 30-second footprint timer. This enforces hard
    /// limits on regenerable per-tab caches and releases renderer allocations
    /// only for windows AppKit confirms are fully invisible.
    func enforceRoutineBudgets() {
        DispatchQueue.main.async {
            Self.enforceRoutineBudgetsOnMain()
        }
    }

    private static func enforceRoutineBudgetsOnMain() {
        let cacheBudget = TerminalMemoryBudgetPolicy.normalizedBudgetBytes(
            overrideMB: UserDefaults.standard.object(forKey: "terminal.perTabCacheBudgetMB") as? Int,
            defaultBytes: TerminalMemoryBudgetPolicy.defaultPerTabRegenerableCacheBytes
        )
        var clearedCaches = 0
        var evictedWindows = 0
        var evictedBytes = 0
        var seenCoordinators = Set<ObjectIdentifier>()

        for (_, model) in TerminalControlService.shared.allModels {
            for tab in model.tabs {
                for (_, session) in tab.splitController.terminalSessions {
                    let view = session.rustTerminalView
                    let cacheBytes = (session.cachedBufferData?.count ?? 0)
                        + (view?.cachedBufferLinesEstimatedBytes ?? 0)
                    if TerminalMemoryBudgetPolicy.exceedsBudget(bytes: cacheBytes, budgetBytes: cacheBudget) {
                        session.cachedBufferData = nil
                        view?.cachedBufferLines = nil
                        view?.cachedBufferLinesEstimatedBytes = 0
                        clearedCaches += 1
                    }

                    if let coordinator = session.windowMetalCoordinator,
                       seenCoordinators.insert(ObjectIdentifier(coordinator)).inserted {
                        let released = coordinator.evictInactiveResources()
                        if released > 0 {
                            evictedWindows += 1
                            evictedBytes += released
                        }
                    }
                }
            }
        }

        guard clearedCaches > 0 || evictedWindows > 0 else { return }
        Log.info(
            "TerminalMemoryReclaimer[routine]: cleared \(clearedCaches) oversized cache(s), " +
                "evicted \(evictedBytes / (1_024 * 1_024))MB across \(evictedWindows) invisible window(s)"
        )
    }

    private static func reclaimOnMain(_ level: MemoryPressureLevel) {
        var clearedBufferCaches = 0
        var evictedWindows = 0
        var evictedBytes = 0
        var seenCoordinators = Set<ObjectIdentifier>()

        for (_, model) in TerminalControlService.shared.allModels {
            let selectedID = model.selectedTabID
            for index in model.tabs.indices {
                let tab = model.tabs[index]
                if level == .warning, tab.id == selectedID { continue }

                for (_, session) in tab.splitController.terminalSessions {
                    if session.cachedBufferData != nil {
                        session.cachedBufferData = nil
                        clearedBufferCaches += 1
                    }
                    if let view = session.rustTerminalView, view.cachedBufferLines != nil {
                        view.cachedBufferLines = nil
                        view.cachedBufferLinesEstimatedBytes = 0
                        clearedBufferCaches += 1
                    }

                    // Fully invisible renderer resources are always safe to
                    // release under pressure; the latest triple buffer and
                    // authoritative Rust terminal remain intact.
                    if let coordinator = session.windowMetalCoordinator,
                       seenCoordinators.insert(ObjectIdentifier(coordinator)).inserted {
                        let released = coordinator.evictInactiveResources()
                        if released > 0 {
                            evictedWindows += 1
                            evictedBytes += released
                        }
                    }
                }
            }
        }

        Log.info(
            "TerminalMemoryReclaimer[\(level)]: cleared \(clearedBufferCaches) buffer cache(s), " +
                "evicted \(evictedBytes / (1_024 * 1_024))MB across \(evictedWindows) invisible window(s)"
        )
    }
}
