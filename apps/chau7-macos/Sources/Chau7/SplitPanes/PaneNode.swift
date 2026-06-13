import Foundation
import Chau7Core

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

    /// Pane-owned serialization. The tree's `savedRepresentation` just asks
    /// each leaf to describe itself; adding a new pane kind no longer
    /// touches a central encode switch. The decode side still routes
    /// through `SplitNode.fromSavedNode` because it needs a factory tied to
    /// the persisted `kind` tag — Phase 6 will lift that into a registry.
    func savedRepresentation() -> SavedSplitNode
}

extension PaneNode {
    var hasUnsavedWork: Bool {
        false
    }

    func dispose() {}
}

// MARK: - Terminal Pane

/// Leaf node wrapping a `TerminalSessionModel`. `dispose` closes the PTY
/// session so the tree can be collapsed without leaking the shell.
final class TerminalPane: PaneNode {
    let id: UUID
    let session: TerminalSessionModel

    var kind: PaneType {
        .terminal
    }

    init(id: UUID = UUID(), session: TerminalSessionModel) {
        self.id = id
        self.session = session
    }

    func dispose() {
        session.closeSession()
    }

    func savedRepresentation() -> SavedSplitNode {
        SavedSplitNode(
            kind: .terminal,
            id: id.uuidString,
            direction: nil, ratio: nil, first: nil, second: nil,
            textEditorPath: nil
        )
    }

    /// Reconstructs a `TerminalPane` from its persisted form. Seeds the
    /// fresh session with the restored repo identity, working directory,
    /// and AI provider hint from `paneStates` so the tab title resolves
    /// to "Codex" / "Claude" / etc. on first render rather than waiting
    /// for the deferred per-tab restore.
    static func makeFromSaved(_ node: SavedSplitNode, context: PaneFactoryContext) -> TerminalPane {
        let resolvedID = UUID(uuidString: node.id) ?? UUID()
        let session = TerminalSessionModel(appModel: context.appModel)
        if let state = context.paneStates[resolvedID] {
            if let knownRepoRoot = OverlayTabsModel.normalizedSavedRepoField(state.knownRepoRoot) {
                KnownRepoIdentityStore.shared.record(
                    rootPath: knownRepoRoot,
                    branch: OverlayTabsModel.normalizedSavedRepoField(state.knownGitBranch)
                )
            }
            let restoreDirectory = state.preferredRestoreDirectory
            if !restoreDirectory.isEmpty {
                session.updateCurrentDirectory(restoreDirectory)
            }
            if let normalized = AIResumeParser.normalizeProviderName(state.aiProvider ?? "") {
                session.lastAIProvider = normalized
            }
        }
        return TerminalPane(id: resolvedID, session: session)
    }
}

// MARK: - Text Editor Pane

/// Leaf node wrapping a `TextEditorModel`. `hasUnsavedWork` mirrors the
/// editor's `isDirty` flag so the close-pane prompt fires on dirty
/// editors only.
final class TextEditorPane: PaneNode {
    let id: UUID
    let editor: TextEditorModel

    var kind: PaneType {
        .textEditor
    }

    var hasUnsavedWork: Bool {
        editor.isDirty
    }

    init(id: UUID = UUID(), editor: TextEditorModel) {
        self.id = id
        self.editor = editor
    }

    func savedRepresentation() -> SavedSplitNode {
        SavedSplitNode(
            kind: .textEditor,
            id: id.uuidString,
            direction: nil, ratio: nil, first: nil, second: nil,
            textEditorPath: editor.filePath
        )
    }

    /// Reconstructs a `TextEditorPane` from its persisted form, loading
    /// the file when a path was recorded.
    static func makeFromSaved(_ node: SavedSplitNode, context: PaneFactoryContext) -> TextEditorPane {
        let resolvedID = UUID(uuidString: node.id) ?? UUID()
        let editor = TextEditorModel()
        if let path = node.textEditorPath,
           !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            editor.loadFile(at: path)
        }
        return TextEditorPane(id: resolvedID, editor: editor)
    }
}

// MARK: - File Preview Pane

/// Leaf node wrapping a `FilePreviewModel`. Read-only; never has unsaved
/// work and needs no disposal.
final class FilePreviewPane: PaneNode {
    let id: UUID
    let preview: FilePreviewModel

    var kind: PaneType {
        .filePreview
    }

    init(id: UUID = UUID(), preview: FilePreviewModel) {
        self.id = id
        self.preview = preview
    }

    func savedRepresentation() -> SavedSplitNode {
        SavedSplitNode(
            kind: .filePreview,
            id: id.uuidString,
            direction: nil, ratio: nil, first: nil, second: nil,
            textEditorPath: nil,
            previewFilePath: preview.filePath
        )
    }

    /// Reconstructs a `FilePreviewPane` from its persisted form, loading
    /// the previewed file when a path was recorded.
    static func makeFromSaved(_ node: SavedSplitNode, context: PaneFactoryContext) -> FilePreviewPane {
        let resolvedID = UUID(uuidString: node.id) ?? UUID()
        let preview = FilePreviewModel()
        if let path = node.previewFilePath,
           !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            preview.loadFile(at: path)
        }
        return FilePreviewPane(id: resolvedID, preview: preview)
    }
}

// MARK: - Diff Viewer Pane

/// Leaf node wrapping a `DiffViewerModel`. Read-only.
final class DiffViewerPane: PaneNode {
    let id: UUID
    let diff: DiffViewerModel

    var kind: PaneType {
        .diffViewer
    }

    init(id: UUID = UUID(), diff: DiffViewerModel) {
        self.id = id
        self.diff = diff
    }

    func savedRepresentation() -> SavedSplitNode {
        SavedSplitNode(
            kind: .diffViewer,
            id: id.uuidString,
            direction: nil, ratio: nil, first: nil, second: nil,
            textEditorPath: nil,
            diffFilePath: diff.filePath,
            diffDirectory: diff.directory,
            diffMode: diff.diffMode.rawValue
        )
    }

    /// Reconstructs a `DiffViewerPane` from its persisted form, kicking
    /// off the diff load when the file path and directory were both
    /// recorded.
    static func makeFromSaved(_ node: SavedSplitNode, context: PaneFactoryContext) -> DiffViewerPane {
        let resolvedID = UUID(uuidString: node.id) ?? UUID()
        let diff = DiffViewerModel()
        if let file = node.diffFilePath, let dir = node.diffDirectory,
           !file.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let mode = node.diffMode.flatMap(DiffMode.init(rawValue:)) ?? .workingTree
            diff.loadDiff(file: file, in: dir, mode: mode)
        }
        return DiffViewerPane(id: resolvedID, diff: diff)
    }
}

// MARK: - Repository Pane

/// Leaf node wrapping a `RepositoryPaneModel`. The repo model owns its
/// own draft persistence and refresh policy; the pane is just a holder.
final class RepositoryPane: PaneNode {
    let id: UUID
    let repo: RepositoryPaneModel

    var kind: PaneType {
        .repositoryPane
    }

    init(id: UUID = UUID(), repo: RepositoryPaneModel) {
        self.id = id
        self.repo = repo
    }

    func savedRepresentation() -> SavedSplitNode {
        SavedSplitNode(
            kind: .repositoryPane,
            id: id.uuidString,
            direction: nil, ratio: nil, first: nil, second: nil,
            textEditorPath: nil,
            repoDirectory: repo.directory
        )
    }

    /// Reconstructs a `RepositoryPane` from its persisted form, kicking
    /// off the repo load when a directory was recorded.
    static func makeFromSaved(_ node: SavedSplitNode, context: PaneFactoryContext) -> RepositoryPane {
        let resolvedID = UUID(uuidString: node.id) ?? UUID()
        let repo = RepositoryPaneModel()
        if let dir = node.repoDirectory,
           !dir.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            repo.load(directory: dir)
        }
        return RepositoryPane(id: resolvedID, repo: repo)
    }
}

// MARK: - Dashboard Pane

/// Leaf node wrapping an `AgentDashboardModel`. No PTY, no unsaved state.
final class DashboardPane: PaneNode {
    let id: UUID
    let dashboard: AgentDashboardModel

    var kind: PaneType {
        .dashboard
    }

    init(id: UUID = UUID(), dashboard: AgentDashboardModel) {
        self.id = id
        self.dashboard = dashboard
    }

    func savedRepresentation() -> SavedSplitNode {
        SavedSplitNode(
            kind: .dashboard,
            id: id.uuidString,
            direction: nil, ratio: nil, first: nil, second: nil,
            textEditorPath: nil,
            dashboardRepoGroupID: dashboard.repoGroupID
        )
    }

    /// Reconstructs a `DashboardPane` from its persisted form. An empty
    /// `repoGroupID` is a valid initial state (the dashboard renders an
    /// empty agent list rather than crashing).
    static func makeFromSaved(_ node: SavedSplitNode, context: PaneFactoryContext) -> DashboardPane {
        let resolvedID = UUID(uuidString: node.id) ?? UUID()
        let repoGroupID = node.dashboardRepoGroupID ?? ""
        let dashboard = AgentDashboardModel(repoGroupID: repoGroupID)
        return DashboardPane(id: resolvedID, dashboard: dashboard)
    }
}
