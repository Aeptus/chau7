import SwiftUI

/// Bundles the callback closures that the side-panel tree's recursive view
/// machinery used to thread through every `SplitNodeView` initializer (five
/// separate parameters at each level). They're all invariant down the tree
/// — the controller knows what to do regardless of which node is currently
/// being rendered — so pushing them through `@Environment` once at the root
/// keeps the per-node init signatures focused on per-node concerns
/// (`focusedID`, `renderPhase`, `isInteractive`) and frees the leaf views
/// from carrying closures they don't directly use.
struct PaneEnvironment {
    /// Called when a pane (by id) requests keyboard focus — typically a tap
    /// or click on the pane body.
    let onFocus: (UUID) -> Void

    /// Called when the user drags a split divider, with the new ratio for
    /// the split node identified by `id`.
    let onUpdateRatio: (UUID, CGFloat) -> Void

    /// Called when a pane requests to close itself.
    let onClosePane: (UUID) -> Void

    /// Optional: called when terminal output's clickable file-path link is
    /// activated. Nil when the host does not provide click-to-open routing.
    let onFilePathClicked: ((String, Int?, Int?) -> Void)?

    /// Optional: called when a runbook code block requests execution
    /// against the host terminal session.
    let onRunCommand: ((String, Int?, TextEditorModel?) -> Void)?
}

private struct PaneEnvironmentKey: EnvironmentKey {
    static let defaultValue: PaneEnvironment? = nil
}

extension EnvironmentValues {
    /// Side-panel root sets this once via `.environment(\.paneEnvironment, …)`
    /// and the recursive `SplitNodeView` machinery pulls it back out as
    /// needed without re-threading five closures through every level.
    var paneEnvironment: PaneEnvironment? {
        get { self[PaneEnvironmentKey.self] }
        set { self[PaneEnvironmentKey.self] = newValue }
    }
}
