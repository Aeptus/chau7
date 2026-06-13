import Foundation

/// Inputs every pane factory in the registry needs to reconstruct a pane
/// from its persisted form. `appModel` is required by `TerminalPane` to
/// build a fresh `TerminalSessionModel`; `paneStates` carries restored
/// terminal-pane state (knownRepoRoot, lastAIProvider, …) keyed by pane id.
struct PaneFactoryContext {
    let appModel: AppModel
    let paneStates: [UUID: SavedTerminalPaneState]
}

/// Registry that maps `PaneType` → a factory closure rebuilding a pane
/// from its `SavedSplitNode` form. Replaces the central 6-case switch
/// inside `SplitNode.fromSavedNode` so adding a new pane kind no longer
/// requires editing the decode-side dispatch — the new pane's
/// `makeFromSaved(_:context:)` static + a registry entry is enough.
///
/// The registry intentionally lives in one place so the lookup is
/// O(1) and the dispatch table is reviewable at a glance. The pane
/// classes own the per-kind reconstruction logic via their static
/// `makeFromSaved`; the registry just routes the lookup.
enum PaneFactoryRegistry {
    /// Lookup table populated from each pane's `makeFromSaved` static.
    /// New pane kinds extend this dictionary literal — no edits required
    /// to `SplitNode.fromSavedNode` or any other persistence-side switch.
    static let factories: [PaneType: (SavedSplitNode, PaneFactoryContext) -> any PaneNode] = [
        .terminal: { TerminalPane.makeFromSaved($0, context: $1) },
        .textEditor: { TextEditorPane.makeFromSaved($0, context: $1) },
        .filePreview: { FilePreviewPane.makeFromSaved($0, context: $1) },
        .diffViewer: { DiffViewerPane.makeFromSaved($0, context: $1) },
        .repositoryPane: { RepositoryPane.makeFromSaved($0, context: $1) },
        .dashboard: { DashboardPane.makeFromSaved($0, context: $1) }
    ]
}

// MARK: - SavedSplitNodeKind helpers

extension SavedSplitNodeKind {
    /// Maps the persisted kind tag to a live `PaneType`, or nil for the
    /// non-leaf `.split` case. Used by `SplitNode.fromSavedNode` to route
    /// pane leaves through the registry while keeping the split branch
    /// inline.
    var paneType: PaneType? {
        switch self {
        case .terminal: return .terminal
        case .textEditor: return .textEditor
        case .filePreview: return .filePreview
        case .diffViewer: return .diffViewer
        case .repositoryPane: return .repositoryPane
        case .dashboard: return .dashboard
        case .split: return nil
        }
    }
}
