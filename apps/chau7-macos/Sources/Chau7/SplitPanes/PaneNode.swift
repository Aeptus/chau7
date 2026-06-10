import Foundation

// MARK: - PaneNode Protocol
//
// Contract every leaf pane in the side-panel tree honors. Replaces the ~17
// hand-rolled 7-case switches on the previous `SplitNode` enum — adding a
// new pane kind no longer touches every traversal helper, just adds a new
// `PaneNode` conformer.
//
// This file introduces the protocol and the six concrete wrappers in
// Phase 1a; the `SplitNode` enum migration to `.leaf(any PaneNode)` lands
// in Phase 1b, and persistence pivots onto `PaneNode.savedRepresentation`
// in Phase 1c.

/// Contract a leaf pane honors. Wrappers around the existing model types
/// (TerminalSessionModel, TextEditorModel, etc.) so the tree can hold any
/// pane behind one protocol existential.
protocol PaneNode: AnyObject {
    /// Stable identity within the split tree. Persistence rounds-trip on this.
    var id: UUID { get }

    /// Discriminator for the few cases where pattern-matching on the
    /// existential isn't enough (SwiftUI body branches, persistence kind tag).
    var kind: PaneType { get }

    /// True when removing the pane would lose user work. The close-pane
    /// flow on `SplitPaneController` consults this to decide whether to
    /// prompt; non-editor panes return false unconditionally.
    var hasUnsavedWork: Bool { get }

    /// Called when the pane is dropped from the tree. Terminal panes close
    /// their PTY session here; most panes need nothing. Default is no-op.
    func dispose()
}

extension PaneNode {
    var hasUnsavedWork: Bool { false }
    func dispose() {}
}

// MARK: - Terminal Pane

/// Leaf node wrapping a `TerminalSessionModel`. `dispose` closes the PTY
/// session so the tree can be collapsed without leaking the shell.
final class TerminalPane: PaneNode {
    let id: UUID
    let session: TerminalSessionModel

    var kind: PaneType { .terminal }

    init(id: UUID = UUID(), session: TerminalSessionModel) {
        self.id = id
        self.session = session
    }

    func dispose() {
        session.closeSession()
    }
}

// MARK: - Text Editor Pane

/// Leaf node wrapping a `TextEditorModel`. `hasUnsavedWork` mirrors the
/// editor's `isDirty` flag so the close-pane prompt fires on dirty
/// editors only.
final class TextEditorPane: PaneNode {
    let id: UUID
    let editor: TextEditorModel

    var kind: PaneType { .textEditor }
    var hasUnsavedWork: Bool { editor.isDirty }

    init(id: UUID = UUID(), editor: TextEditorModel) {
        self.id = id
        self.editor = editor
    }
}

// MARK: - File Preview Pane

/// Leaf node wrapping a `FilePreviewModel`. Read-only; never has unsaved
/// work and needs no disposal.
final class FilePreviewPane: PaneNode {
    let id: UUID
    let preview: FilePreviewModel

    var kind: PaneType { .filePreview }

    init(id: UUID = UUID(), preview: FilePreviewModel) {
        self.id = id
        self.preview = preview
    }
}

// MARK: - Diff Viewer Pane

/// Leaf node wrapping a `DiffViewerModel`. Read-only.
final class DiffViewerPane: PaneNode {
    let id: UUID
    let diff: DiffViewerModel

    var kind: PaneType { .diffViewer }

    init(id: UUID = UUID(), diff: DiffViewerModel) {
        self.id = id
        self.diff = diff
    }
}

// MARK: - Repository Pane

/// Leaf node wrapping a `RepositoryPaneModel`. The repo model owns its
/// own draft persistence and refresh policy; the pane is just a holder.
final class RepositoryPane: PaneNode {
    let id: UUID
    let repo: RepositoryPaneModel

    var kind: PaneType { .repositoryPane }

    init(id: UUID = UUID(), repo: RepositoryPaneModel) {
        self.id = id
        self.repo = repo
    }
}

// MARK: - Dashboard Pane

/// Leaf node wrapping an `AgentDashboardModel`. No PTY, no unsaved state.
final class DashboardPane: PaneNode {
    let id: UUID
    let dashboard: AgentDashboardModel

    var kind: PaneType { .dashboard }

    init(id: UUID = UUID(), dashboard: AgentDashboardModel) {
        self.id = id
        self.dashboard = dashboard
    }
}
