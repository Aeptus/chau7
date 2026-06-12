import AppKit

/// Bridges OS memory-pressure reclamation onto the main thread for the
/// main-confined per-tab caches that previously never responded to pressure:
/// tab switch snapshots (`OverlayTab.cachedSnapshot`), the session-side
/// snapshot mirror (`lastRenderedSnapshot`, one full Retina window bitmap per
/// ever-selected tab), the search buffer cache (`cachedBufferData`), and the
/// per-view scrollback line cache (`cachedBufferLines`, a full `[String]`
/// duplicate of the Rust ring).
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

    private static func reclaimOnMain(_ level: MemoryPressureLevel) {
        var clearedSnapshots = 0
        var clearedBufferCaches = 0
        var volatileWindows = 0
        var seenCoordinators = Set<ObjectIdentifier>()

        for (_, model) in TerminalControlService.shared.allModels {
            let selectedID = model.selectedTabID
            for index in model.tabs.indices {
                let tab = model.tabs[index]
                if level == .warning, tab.id == selectedID { continue }

                if model.tabs[index].cachedSnapshot != nil {
                    model.tabs[index].cachedSnapshot = nil
                    clearedSnapshots += 1
                }
                for (_, session) in tab.splitController.terminalSessions {
                    if session.lastRenderedSnapshot != nil {
                        session.lastRenderedSnapshot = nil
                        clearedSnapshots += 1
                    }
                    if session.cachedBufferData != nil {
                        session.cachedBufferData = nil
                        clearedBufferCaches += 1
                    }
                    if let view = session.rustTerminalView, view.cachedBufferLines != nil {
                        view.cachedBufferLines = nil
                        clearedBufferCaches += 1
                    }

                    // Critical only: GPU resources (glyph atlas + buffers) of
                    // fully invisible windows go volatile. Window-level — the
                    // coordinator is shared by every tab in its window — and
                    // promotion happens at the top of the window's next draw.
                    if level == .critical,
                       let coordinator = session.windowMetalCoordinator,
                       seenCoordinators.insert(ObjectIdentifier(coordinator)).inserted {
                        let window = coordinator.metalView.window
                        let windowInvisible = window.map {
                            !$0.isVisible || $0.isMiniaturized || !$0.occlusionState.contains(.visible)
                        } ?? true
                        if windowInvisible {
                            coordinator.markTexturesVolatile()
                            volatileWindows += 1
                        }
                    }
                }
            }
        }

        Log.info("TerminalMemoryReclaimer[\(level)]: cleared \(clearedSnapshots) snapshot(s), \(clearedBufferCaches) buffer cache(s), \(volatileWindows) window(s) GPU-volatile")
    }
}
