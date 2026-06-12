import Foundation
import Chau7Core

/// Clears per-tab NSImage caches (preview snapshots, retained frames) when
/// requested by TabGraphicsMemoryManager. Implemented by OverlayTabsModel.
protocol TabSnapshotReleaser: AnyObject {
    @MainActor
    func releaseSnapshots(forTabID tabID: UUID, tier: TabGraphicsMemoryManager.ReleaseTier)
}

/// Releases per-tab graphics memory (CG image bitmaps) as tabs transition
/// through TabRenderPhase. Works alongside ScrollbackMemoryManager, which
/// handles the text-data side.
///
/// The RustTerminalView hooks `applyRenderPhase` to notify this manager of
/// every phase delta. The manager converts the new phase into a ReleaseTier
/// and routes the work to the registered snapshot releasers (OverlayTabsModel
/// per window), which clear NSImage properties.
///
/// GPU purgeable-state volatility is NOT handled here: the Metal coordinator
/// is shared per window, so per-tab volatility registration was wrong-grained
/// (a background tab demoting would have marked the *active* tab's atlas
/// volatile mid-render). Window-level volatility is driven by
/// `TerminalMemoryReclaimer` under critical pressure instead.
final class TabGraphicsMemoryManager {
    static let shared = TabGraphicsMemoryManager()

    enum ReleaseTier {
        /// `.active`: keep everything live.
        case keepAll
        /// `.passiveVisible`: keep only the lightweight cached preview state.
        case keepCachedOnly
        /// `.hidden`: drop all snapshots, mark Metal volatile.
        case releaseAll
    }

    private let registryLock = NSLock()
    private var snapshotReleasers: [WeakSnapshotBox] = []

    private init() {}

    // MARK: - Registration

    /// Multi-window safe: every OverlayTabsModel registers itself and the
    /// manager dispatches release requests to all of them. Each model looks up
    /// its own tab by UUID — models that don't own the tab are a no-op.
    func addSnapshotReleaser(_ releaser: TabSnapshotReleaser) {
        registryLock.lock()
        // Compact dead weak refs and drop duplicates while we're here.
        snapshotReleasers = snapshotReleasers.filter { $0.value != nil && $0.value !== releaser }
        snapshotReleasers.append(WeakSnapshotBox(value: releaser))
        registryLock.unlock()
    }

    func removeSnapshotReleaser(_ releaser: TabSnapshotReleaser) {
        registryLock.lock()
        snapshotReleasers.removeAll { $0.value == nil || $0.value === releaser }
        registryLock.unlock()
    }

    // MARK: - Phase transition entry point

    func handlePhaseTransition(tabID: UUID?, from oldPhase: TabRenderPhase, to newPhase: TabRenderPhase) {
        guard let tabID, oldPhase != newPhase else { return }

        // Policy note: Chau7's render policy almost never promotes tabs to
        // `.hidden` because most terminals report hasBackgroundActivity=true
        // (their shell process is running). Aggressively releasing on `.warm`
        // captures the big memory wins for the common case. Rebuilding a
        // cached thumbnail / glyph atlas on re-entry is a fast operation.
        let tier: ReleaseTier
        switch newPhase {
        case .active:
            tier = .keepAll
        case .passiveVisible:
            tier = .keepCachedOnly
        case .warm, .hidden:
            tier = .releaseAll
        }

        if tier != .keepAll {
            let releasers = currentSnapshotReleasers()
            DispatchQueue.main.async {
                for releaser in releasers {
                    releaser.releaseSnapshots(forTabID: tabID, tier: tier)
                }
            }
        }
    }

    // MARK: - Internal

    private func currentSnapshotReleasers() -> [TabSnapshotReleaser] {
        registryLock.lock()
        defer { registryLock.unlock() }
        return snapshotReleasers.compactMap(\.value)
    }

    private final class WeakSnapshotBox {
        weak var value: TabSnapshotReleaser?
        init(value: TabSnapshotReleaser?) {
            self.value = value
        }
    }
}
