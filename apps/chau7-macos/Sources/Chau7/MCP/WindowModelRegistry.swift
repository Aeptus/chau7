import Foundation

/// Owns the window/model registration state shared by the MCP and Remote
/// control planes: which `OverlayTabsModel`s exist, their stable window IDs,
/// and cross-window tab lookups. Extracted from `TerminalControlService` so
/// the bookkeeping is testable in isolation and consumers can depend on the
/// registry (or a protocol over it) instead of the whole MCP service.
///
/// Threading: main-thread confined, exactly like the state it replaced —
/// registration happens from AppDelegate (main thread) and lookups run inside
/// `TerminalControlService`'s main-queue hops.
final class WindowModelRegistry {
    /// Weak wrapper with a stable ID so window_id doesn't shift when models deallocate.
    private struct WeakModel {
        let windowID: Int
        weak var model: OverlayTabsModel?
    }

    private var registeredModels: [WeakModel] = []
    private var nextWindowID = 0

    /// Register an overlay model, assigning it the next stable window ID.
    /// Returns `false` (no-op) when the model is already registered.
    @discardableResult
    func register(_ model: OverlayTabsModel) -> Bool {
        // Already registered? Skip.
        if registeredModels.contains(where: { $0.model === model }) { return false }
        // Prune dead references
        registeredModels.removeAll { $0.model == nil }
        let id = nextWindowID
        nextWindowID += 1
        registeredModels.append(WeakModel(windowID: id, model: model))
        return true
    }

    /// Unregister when a window closes. Optional — dead refs are pruned lazily.
    func unregister(_ model: OverlayTabsModel) {
        registeredModels.removeAll { $0.model == nil || $0.model === model }
    }

    /// All currently alive (windowID, model) pairs, preserving stable IDs.
    var allModels: [(windowID: Int, model: OverlayTabsModel)] {
        registeredModels.compactMap { entry in
            guard let model = entry.model else { return nil }
            return (entry.windowID, model)
        }
    }

    /// All tabs across all registered windows. Use for cross-window resolution
    /// (e.g., notification routing that must search every window, not just window 0).
    var allTabs: [OverlayTab] {
        allModels.flatMap { $0.model.tabs }
    }

    /// Find the OverlayTabsModel that owns a given tab UUID.
    func model(containingTab tabID: UUID) -> OverlayTabsModel? {
        allModels.first(where: { $0.model.tabs.contains(where: { $0.id == tabID }) })?.model
    }
}
