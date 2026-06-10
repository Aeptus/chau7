import SwiftUI
import AppKit
import Chau7Core
import CryptoKit

// MARK: - F02: Native Split Panes with Text Editor Support

enum SavedSplitNodeKind: String, Codable {
    case terminal
    case textEditor
    case filePreview
    case diffViewer
    case repositoryPane
    case dashboard
    case split
}

final class SavedSplitNode: Codable, Equatable {
    /// Schema version of this persisted split tree. Bump when a new pane
    /// kind is added or a field's interpretation changes so old binaries
    /// reading a newer snapshot fail loudly (the caller substitutes a
    /// default layout) instead of silently decoding the parts they
    /// understand and dropping the rest.
    static let currentVersion = 1

    let version: Int
    let kind: SavedSplitNodeKind
    let id: String
    let direction: SplitDirection?
    let ratio: Double?
    let first: SavedSplitNode?
    let second: SavedSplitNode?
    let textEditorPath: String?
    let previewFilePath: String?
    let diffFilePath: String?
    let diffDirectory: String?
    let diffMode: String?
    let repoDirectory: String?
    let dashboardRepoGroupID: String?

    init(
        version: Int = SavedSplitNode.currentVersion,
        kind: SavedSplitNodeKind,
        id: String,
        direction: SplitDirection?,
        ratio: Double?,
        first: SavedSplitNode?,
        second: SavedSplitNode?,
        textEditorPath: String?,
        previewFilePath: String? = nil,
        diffFilePath: String? = nil,
        diffDirectory: String? = nil,
        diffMode: String? = nil,
        repoDirectory: String? = nil,
        dashboardRepoGroupID: String? = nil
    ) {
        self.version = version
        self.kind = kind
        self.id = id
        self.direction = direction
        self.ratio = ratio
        self.first = first
        self.second = second
        self.textEditorPath = textEditorPath
        self.previewFilePath = previewFilePath
        self.diffFilePath = diffFilePath
        self.diffDirectory = diffDirectory
        self.diffMode = diffMode
        self.repoDirectory = repoDirectory
        self.dashboardRepoGroupID = dashboardRepoGroupID
    }

    enum CodingKeys: String, CodingKey {
        case version, kind, id, direction, ratio, first, second
        case textEditorPath, previewFilePath, diffFilePath, diffDirectory, diffMode
        case repoDirectory, dashboardRepoGroupID
    }

    convenience init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Pre-versioned snapshots (everything currently on disk) are read
        // as version 1; future bumps will fail loudly on snapshots written
        // by a newer binary.
        let version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        if version > SavedSplitNode.currentVersion {
            throw DecodingError.dataCorruptedError(
                forKey: .version,
                in: container,
                debugDescription:
                    "SavedSplitNode version \(version) is newer than supported version " +
                    "\(SavedSplitNode.currentVersion); falling back to a default layout."
            )
        }

        self.init(
            version: version,
            kind: try container.decode(SavedSplitNodeKind.self, forKey: .kind),
            id: try container.decode(String.self, forKey: .id),
            direction: try container.decodeIfPresent(SplitDirection.self, forKey: .direction),
            ratio: try container.decodeIfPresent(Double.self, forKey: .ratio),
            first: try container.decodeIfPresent(SavedSplitNode.self, forKey: .first),
            second: try container.decodeIfPresent(SavedSplitNode.self, forKey: .second),
            textEditorPath: try container.decodeIfPresent(String.self, forKey: .textEditorPath),
            previewFilePath: try container.decodeIfPresent(String.self, forKey: .previewFilePath),
            diffFilePath: try container.decodeIfPresent(String.self, forKey: .diffFilePath),
            diffDirectory: try container.decodeIfPresent(String.self, forKey: .diffDirectory),
            diffMode: try container.decodeIfPresent(String.self, forKey: .diffMode),
            repoDirectory: try container.decodeIfPresent(String.self, forKey: .repoDirectory),
            dashboardRepoGroupID: try container.decodeIfPresent(String.self, forKey: .dashboardRepoGroupID)
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(kind, forKey: .kind)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(direction, forKey: .direction)
        try container.encodeIfPresent(ratio, forKey: .ratio)
        try container.encodeIfPresent(first, forKey: .first)
        try container.encodeIfPresent(second, forKey: .second)
        try container.encodeIfPresent(textEditorPath, forKey: .textEditorPath)
        try container.encodeIfPresent(previewFilePath, forKey: .previewFilePath)
        try container.encodeIfPresent(diffFilePath, forKey: .diffFilePath)
        try container.encodeIfPresent(diffDirectory, forKey: .diffDirectory)
        try container.encodeIfPresent(diffMode, forKey: .diffMode)
        try container.encodeIfPresent(repoDirectory, forKey: .repoDirectory)
        try container.encodeIfPresent(dashboardRepoGroupID, forKey: .dashboardRepoGroupID)
    }

    static func == (lhs: SavedSplitNode, rhs: SavedSplitNode) -> Bool {
        lhs.version == rhs.version &&
            lhs.kind == rhs.kind &&
            lhs.id == rhs.id &&
            lhs.direction == rhs.direction &&
            lhs.ratio == rhs.ratio &&
            lhs.textEditorPath == rhs.textEditorPath &&
            lhs.previewFilePath == rhs.previewFilePath &&
            lhs.diffFilePath == rhs.diffFilePath &&
            lhs.diffDirectory == rhs.diffDirectory &&
            lhs.diffMode == rhs.diffMode &&
            lhs.repoDirectory == rhs.repoDirectory &&
            lhs.dashboardRepoGroupID == rhs.dashboardRepoGroupID &&
            lhs.first == rhs.first &&
            lhs.second == rhs.second
    }
}

/// Direction for splitting a pane
enum SplitDirection: String, Codable {
    case horizontal // Side by side
    case vertical // Stacked
}

/// Type of pane content
enum PaneType: String, Codable {
    case terminal
    case textEditor
    case filePreview
    case diffViewer
    case repositoryPane
    case dashboard
}

/// Represents a node in the split pane tree
indirect enum SplitNode: Identifiable {
    case terminal(id: UUID, session: TerminalSessionModel)
    case textEditor(id: UUID, editor: TextEditorModel)
    case filePreview(id: UUID, preview: FilePreviewModel)
    case diffViewer(id: UUID, diff: DiffViewerModel)
    case repositoryPane(id: UUID, repo: RepositoryPaneModel)
    case dashboard(id: UUID, dashboard: AgentDashboardModel)
    case split(id: UUID, direction: SplitDirection, first: SplitNode, second: SplitNode, ratio: CGFloat)

    var id: UUID {
        switch self {
        case .terminal(let id, _),
             .textEditor(let id, _),
             .filePreview(let id, _),
             .diffViewer(let id, _),
             .repositoryPane(let id, _),
             .dashboard(let id, _):
            return id
        case .split(let id, _, _, _, _):
            return id
        }
    }

    /// Gets all pane IDs in this subtree
    var allPaneIDs: [UUID] {
        switch self {
        case .terminal(let id, _),
             .textEditor(let id, _),
             .filePreview(let id, _),
             .diffViewer(let id, _),
             .repositoryPane(let id, _),
             .dashboard(let id, _):
            return [id]
        case .split(_, _, let first, let second, _):
            return first.allPaneIDs + second.allPaneIDs
        }
    }

    /// Gets all terminal IDs in this subtree
    var allTerminalIDs: [UUID] {
        switch self {
        case .terminal(let id, _):
            return [id]
        case .textEditor, .filePreview, .diffViewer, .repositoryPane, .dashboard:
            return []
        case .split(_, _, let first, let second, _):
            return first.allTerminalIDs + second.allTerminalIDs
        }
    }

    /// Gets all terminal sessions in this subtree
    var allSessions: [TerminalSessionModel] {
        switch self {
        case .terminal(_, let session):
            return [session]
        case .textEditor, .filePreview, .diffViewer, .repositoryPane, .dashboard:
            return []
        case .split(_, _, let first, let second, _):
            return first.allSessions + second.allSessions
        }
    }

    /// Returns terminal panes as `(id, session)` pairs in tree order.
    var terminalSessionPairs: [(id: UUID, session: TerminalSessionModel)] {
        switch self {
        case .terminal(let id, let session):
            return [(id: id, session: session)]
        case .textEditor, .filePreview, .diffViewer, .repositoryPane, .dashboard:
            return []
        case .split(_, _, let first, let second, _):
            return first.terminalSessionPairs + second.terminalSessionPairs
        }
    }

    var allEditors: [TextEditorModel] {
        switch self {
        case .terminal, .filePreview, .diffViewer, .repositoryPane, .dashboard:
            return []
        case .textEditor(_, let editor):
            return [editor]
        case .split(_, _, let first, let second, _):
            return first.allEditors + second.allEditors
        }
    }

    /// Returns a persistence-safe snapshot of this node.
    var savedRepresentation: SavedSplitNode {
        switch self {
        case .terminal(let id, _):
            return SavedSplitNode(
                kind: .terminal,
                id: id.uuidString,
                direction: nil,
                ratio: nil,
                first: nil,
                second: nil,
                textEditorPath: nil
            )
        case .textEditor(let id, let editor):
            return SavedSplitNode(
                kind: .textEditor,
                id: id.uuidString,
                direction: nil,
                ratio: nil,
                first: nil,
                second: nil,
                textEditorPath: editor.filePath
            )
        case .filePreview(let id, let preview):
            return SavedSplitNode(
                kind: .filePreview,
                id: id.uuidString,
                direction: nil,
                ratio: nil,
                first: nil,
                second: nil,
                textEditorPath: nil,
                previewFilePath: preview.filePath
            )
        case .diffViewer(let id, let diff):
            return SavedSplitNode(
                kind: .diffViewer,
                id: id.uuidString,
                direction: nil,
                ratio: nil,
                first: nil,
                second: nil,
                textEditorPath: nil,
                diffFilePath: diff.filePath,
                diffDirectory: diff.directory,
                diffMode: diff.diffMode.rawValue
            )
        case .repositoryPane(let id, let repo):
            return SavedSplitNode(
                kind: .repositoryPane,
                id: id.uuidString,
                direction: nil,
                ratio: nil,
                first: nil,
                second: nil,
                textEditorPath: nil,
                repoDirectory: repo.directory
            )
        case .dashboard(let id, let dashboard):
            return SavedSplitNode(
                kind: .dashboard,
                id: id.uuidString,
                direction: nil,
                ratio: nil,
                first: nil,
                second: nil,
                textEditorPath: nil,
                dashboardRepoGroupID: dashboard.repoGroupID
            )
        case .split(let id, let direction, let first, let second, let ratio):
            return SavedSplitNode(
                kind: .split,
                id: id.uuidString,
                direction: direction,
                ratio: Double(ratio),
                first: first.savedRepresentation,
                second: second.savedRepresentation,
                textEditorPath: nil
            )
        }
    }
}

extension SplitNode {
    /// Reconstructs a split tree from persisted data.
    static func fromSavedNode(
        _ node: SavedSplitNode,
        appModel: AppModel
    ) -> SplitNode {
        return fromSavedNode(node, appModel: appModel, paneStates: [:])
    }

    /// Reconstructs a split tree from persisted data.
    static func fromSavedNode(
        _ node: SavedSplitNode,
        appModel: AppModel,
        paneStates: [UUID: SavedTerminalPaneState]
    ) -> SplitNode {
        let resolvedID = UUID(uuidString: node.id) ?? UUID()

        switch node.kind {
        case .terminal:
            let session = TerminalSessionModel(appModel: appModel)
            if let state = paneStates[resolvedID] {
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
                // Eagerly seed the AI provider so the tab title shows
                // "Codex"/"Claude"/etc. on first render — without this, the
                // provider-driven fallback in `aiDisplayAppName` returns nil
                // until the deferred per-tab `restoreTabState` runs (which
                // only fires for the currently-selected tab at launch, plus
                // each tab the user subsequently clicks). Setting just
                // `lastAIProvider` is enough: the `Self.displayName(
                // fromProvider:)` branch lights up the correct name, and
                // the later full `restoreAIMetadata` call overwrites with
                // the same value + fills in `activeAppName`.
                if let normalized = AIResumeParser.normalizeProviderName(state.aiProvider ?? "") {
                    session.lastAIProvider = normalized
                }
            }
            return .terminal(id: resolvedID, session: session)
        case .textEditor:
            let editor = TextEditorModel()
            if let path = node.textEditorPath,
               !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                editor.loadFile(at: path)
            }
            return .textEditor(id: resolvedID, editor: editor)
        case .filePreview:
            let preview = FilePreviewModel()
            if let path = node.previewFilePath,
               !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                preview.loadFile(at: path)
            }
            return .filePreview(id: resolvedID, preview: preview)
        case .diffViewer:
            let diff = DiffViewerModel()
            if let file = node.diffFilePath, let dir = node.diffDirectory,
               !file.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let mode = node.diffMode.flatMap(DiffMode.init(rawValue:)) ?? .workingTree
                diff.loadDiff(file: file, in: dir, mode: mode)
            }
            return .diffViewer(id: resolvedID, diff: diff)
        case .repositoryPane:
            let repo = RepositoryPaneModel()
            if let dir = node.repoDirectory,
               !dir.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                repo.load(directory: dir)
            }
            return .repositoryPane(id: resolvedID, repo: repo)
        case .dashboard:
            let repoGroupID = node.dashboardRepoGroupID ?? ""
            let dashboard = AgentDashboardModel(repoGroupID: repoGroupID)
            return .dashboard(id: resolvedID, dashboard: dashboard)
        case .split:
            guard let firstSaved = node.first, let secondSaved = node.second else {
                return .terminal(id: resolvedID, session: TerminalSessionModel(appModel: appModel))
            }
            return .split(
                id: resolvedID,
                direction: node.direction ?? .horizontal,
                first: fromSavedNode(firstSaved, appModel: appModel, paneStates: paneStates),
                second: fromSavedNode(secondSaved, appModel: appModel, paneStates: paneStates),
                ratio: CGFloat(node.ratio ?? 0.5)
            )
        }
    }
    // Closes all terminal sessions in this subtree
    // NOTE: Methods below are kept in an extension to keep SplitNode behavior
    // in one cohesive area and to avoid moving the core tree-representation
    // model around.
}

extension SplitNode {
    /// Closes all terminal sessions in this subtree
    func closeAllSessions() {
        switch self {
        case .terminal(_, let session):
            session.closeSession()
        case .textEditor, .filePreview, .diffViewer, .repositoryPane, .dashboard:
            break
        case .split(_, _, let first, let second, _):
            first.closeAllSessions()
            second.closeAllSessions()
        }
    }

    /// Finds a terminal session by ID
    func findSession(id: UUID) -> TerminalSessionModel? {
        switch self {
        case .terminal(let termId, let session):
            return termId == id ? session : nil
        case .textEditor, .filePreview, .diffViewer, .repositoryPane, .dashboard:
            return nil
        case .split(_, _, let first, let second, _):
            return first.findSession(id: id) ?? second.findSession(id: id)
        }
    }

    /// Finds a text editor model by ID
    func findEditor(id: UUID) -> TextEditorModel? {
        switch self {
        case .terminal, .filePreview, .diffViewer, .repositoryPane, .dashboard:
            return nil
        case .textEditor(let editorId, let editor):
            return editorId == id ? editor : nil
        case .split(_, _, let first, let second, _):
            return first.findEditor(id: id) ?? second.findEditor(id: id)
        }
    }

    /// Finds the first text editor in the tree
    func findFirstEditor() -> TextEditorModel? {
        switch self {
        case .terminal, .filePreview, .diffViewer, .repositoryPane, .dashboard:
            return nil
        case .textEditor(_, let editor):
            return editor
        case .split(_, _, let first, let second, _):
            return first.findFirstEditor() ?? second.findFirstEditor()
        }
    }

    /// Finds a file preview model by ID
    func findFilePreview(id: UUID) -> FilePreviewModel? {
        switch self {
        case .terminal, .textEditor, .diffViewer, .repositoryPane, .dashboard:
            return nil
        case .filePreview(let paneId, let preview):
            return paneId == id ? preview : nil
        case .split(_, _, let first, let second, _):
            return first.findFilePreview(id: id) ?? second.findFilePreview(id: id)
        }
    }

    /// Finds the first file preview in the tree
    func findFirstFilePreview() -> FilePreviewModel? {
        switch self {
        case .terminal, .textEditor, .diffViewer, .repositoryPane, .dashboard:
            return nil
        case .filePreview(_, let preview):
            return preview
        case .split(_, _, let first, let second, _):
            return first.findFirstFilePreview() ?? second.findFirstFilePreview()
        }
    }

    /// Finds a diff viewer model by ID
    func findDiffViewer(id: UUID) -> DiffViewerModel? {
        switch self {
        case .terminal, .textEditor, .filePreview, .repositoryPane, .dashboard:
            return nil
        case .diffViewer(let paneId, let diff):
            return paneId == id ? diff : nil
        case .split(_, _, let first, let second, _):
            return first.findDiffViewer(id: id) ?? second.findDiffViewer(id: id)
        }
    }

    /// Finds the first diff viewer in the tree
    func findFirstDiffViewer() -> DiffViewerModel? {
        switch self {
        case .terminal, .textEditor, .filePreview, .repositoryPane, .dashboard:
            return nil
        case .diffViewer(_, let diff):
            return diff
        case .split(_, _, let first, let second, _):
            return first.findFirstDiffViewer() ?? second.findFirstDiffViewer()
        }
    }

    /// Finds a repository pane model by ID
    func findRepositoryPane(id: UUID) -> RepositoryPaneModel? {
        switch self {
        case .repositoryPane(let paneId, let repo):
            return paneId == id ? repo : nil
        case .terminal, .textEditor, .filePreview, .diffViewer, .dashboard:
            return nil
        case .split(_, _, let first, let second, _):
            return first.findRepositoryPane(id: id) ?? second.findRepositoryPane(id: id)
        }
    }

    /// Finds the first repository pane in the tree
    func findFirstRepositoryPane() -> RepositoryPaneModel? {
        switch self {
        case .repositoryPane(_, let repo):
            return repo
        case .terminal, .textEditor, .filePreview, .diffViewer, .dashboard:
            return nil
        case .split(_, _, let first, let second, _):
            return first.findFirstRepositoryPane() ?? second.findFirstRepositoryPane()
        }
    }

    /// Whether the tree contains a repository pane
    var hasRepositoryPane: Bool {
        findFirstRepositoryPane() != nil
    }

    /// Finds the first pane ID matching the given type.
    func firstPaneID(ofType type: PaneType) -> UUID? {
        switch self {
        case .terminal(let id, _):
            return type == .terminal ? id : nil
        case .textEditor(let id, _):
            return type == .textEditor ? id : nil
        case .filePreview(let id, _):
            return type == .filePreview ? id : nil
        case .diffViewer(let id, _):
            return type == .diffViewer ? id : nil
        case .repositoryPane(let id, _):
            return type == .repositoryPane ? id : nil
        case .dashboard(let id, _):
            return type == .dashboard ? id : nil
        case .split(_, _, let first, let second, _):
            return first.firstPaneID(ofType: type) ?? second.firstPaneID(ofType: type)
        }
    }

    /// Gets the pane type for a given ID
    func paneType(for id: UUID) -> PaneType? {
        switch self {
        case .terminal(let paneId, _):
            return paneId == id ? .terminal : nil
        case .textEditor(let paneId, _):
            return paneId == id ? .textEditor : nil
        case .filePreview(let paneId, _):
            return paneId == id ? .filePreview : nil
        case .diffViewer(let paneId, _):
            return paneId == id ? .diffViewer : nil
        case .repositoryPane(let paneId, _):
            return paneId == id ? .repositoryPane : nil
        case .dashboard(let paneId, _):
            return paneId == id ? .dashboard : nil
        case .split(_, _, let first, let second, _):
            return first.paneType(for: id) ?? second.paneType(for: id)
        }
    }

    /// Checks if tree has any text editors
    var hasTextEditor: Bool {
        switch self {
        case .terminal, .filePreview, .diffViewer, .repositoryPane, .dashboard:
            return false
        case .textEditor:
            return true
        case .split(_, _, let first, let second, _):
            return first.hasTextEditor || second.hasTextEditor
        }
    }
}

// MARK: - Text Editor Model

/// Model for a text editor pane
@Observable
final class TextEditorModel: Identifiable {
    struct RunbookCodeBlockKey: Hashable {
        let lineNumber: Int
        let normalizedCommand: String
    }

    let id = UUID()

    var content = ""
    var filePath: String?
    var isDirty = false
    var isLoading = false
    var lastError: String?
    var autoSaveStatusMessage: String?
    var hasExternalChangeConflict = false
    var hasSaveConflict = false
    var externalConflictMessage: String?
    var isAutoSaveEnabled = false
    var scrollToLine: Int? // F03: Line to scroll to after loading (set after content loads)
    var codeBlockRunStates: [RunbookCodeBlockKey: RunbookCodeBlockState] = [:]

    /// Pending line to scroll to after next load completes
    @ObservationIgnored
    private var pendingScrollToLine: Int?

    /// Token to track current loading operation (prevents race conditions)
    @ObservationIgnored
    private var loadingToken: UUID?
    @ObservationIgnored
    private var autoSaveWorkItem: DispatchWorkItem?
    @ObservationIgnored
    private var autoSaveClearWorkItem: DispatchWorkItem?
    @ObservationIgnored
    private var fileMonitor: FileMonitor?
    @ObservationIgnored
    private var loadedContentHash: String?
    @ObservationIgnored
    private var isApplyingExternalReload = false
    @ObservationIgnored
    private var pendingRunbookPollWorkItems: [RunbookCodeBlockKey: DispatchWorkItem] = [:]
    @ObservationIgnored
    private var runbookExecutionGenerations: [RunbookCodeBlockKey: Int] = [:]
    @ObservationIgnored
    var untitledSaveHandler: ((TextEditorModel) -> Bool)?

    /// Main-queue scheduling abstraction used by the markdown runbook
    /// sequencer. Tests can swap a virtual-time scheduler to drive the
    /// poll loop deterministically; production keeps the default.
    @ObservationIgnored
    var mainScheduler: MainScheduler = SystemMainScheduler()

    /// The file name for display
    var fileName: String {
        if let path = filePath {
            return (path as NSString).lastPathComponent
        }
        return L("tab.untitled", "Untitled")
    }

    var planProgress: PlanProgress {
        computePlanProgress(from: content)
    }

    var isCompanionPlan: Bool {
        guard let path = filePath else { return false }
        return Self.shouldAutoEnableAutoSave(for: path)
    }

    /// Load content from a file
    /// - Parameters:
    ///   - path: Absolute path to the file
    ///   - scrollToLine: Optional line number to scroll to after loading (1-based)
    func loadFile(at path: String, scrollToLine line: Int? = nil) {
        // Create a unique token for this load operation
        let token = UUID()
        loadingToken = token
        isLoading = true
        lastError = nil
        hasExternalChangeConflict = false
        hasSaveConflict = false
        externalConflictMessage = nil
        pendingScrollToLine = line // Store for after load completes

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let contents = try String(contentsOfFile: path, encoding: .utf8)
                let hash = Self.contentHash(contents)
                DispatchQueue.main.async {
                    // Only apply if this is still the current load operation
                    guard self?.loadingToken == token else {
                        Log.info("Ignoring stale file load result for: \(path)")
                        return
                    }
                    self?.content = contents
                    self?.filePath = path
                    self?.isDirty = false
                    self?.isLoading = false
                    self?.loadedContentHash = hash
                    self?.isAutoSaveEnabled = Self.shouldAutoEnableAutoSave(for: path)
                    self?.setAutoSaveStatusMessage(nil)
                    self?.startWatchingCurrentFile()
                    // F03: Set scrollToLine AFTER content is loaded
                    if let pending = self?.pendingScrollToLine {
                        self?.scrollToLine = pending
                        self?.pendingScrollToLine = nil
                    }
                    Log.info("Loaded file: \(path)")
                }
            } catch {
                DispatchQueue.main.async {
                    guard self?.loadingToken == token else { return }
                    self?.isLoading = false
                    self?.pendingScrollToLine = nil
                    self?.lastError = "Failed to load file: \(error.localizedDescription)"
                    Log.error("Failed to load file: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Save content to the current file
    @discardableResult
    func save() -> Bool {
        guard let path = filePath else {
            Log.warn("No file path set, cannot save")
            return false
        }
        return saveAs(to: path)
    }

    @discardableResult
    func saveUntitledIfPossible() -> Bool {
        untitledSaveHandler?(self) ?? false
    }

    /// Save content to a specific path
    /// Returns true on success, false on failure
    @discardableResult
    func saveAs(to path: String) -> Bool {
        lastError = nil
        hasSaveConflict = false
        externalConflictMessage = nil
        if !canSaveOverCurrentDiskVersion(path: path) {
            hasSaveConflict = true
            hasExternalChangeConflict = true
            externalConflictMessage = L("editor.externalChangeConflict", "File changed externally. Reload?")
            lastError = L("editor.saveConflict", "Save blocked because the file changed on disk. Reload and merge first.")
            return false
        }

        do {
            stopWatchingCurrentFile()
            try content.write(toFile: path, atomically: true, encoding: .utf8)
            filePath = path
            isDirty = false
            loadedContentHash = Self.contentHash(content)
            isAutoSaveEnabled = isAutoSaveEnabled || Self.shouldAutoEnableAutoSave(for: path)
            hasExternalChangeConflict = false
            hasSaveConflict = false
            externalConflictMessage = nil
            if isAutoSaveEnabled {
                setAutoSaveStatusMessage(L("editor.autoSaved", "Auto-saved"))
            }
            startWatchingCurrentFile()
            Log.info("Saved file: \(path)")
            return true
        } catch {
            startWatchingCurrentFile()
            lastError = "Failed to save file: \(error.localizedDescription)"
            Log.error("Failed to save file: \(error.localizedDescription)")
            return false
        }
    }

    /// Append text to the end of the content
    func appendText(_ text: String) {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }

        if content.isEmpty {
            content = trimmedText
        } else if content.hasSuffix("\n") {
            content += trimmedText
        } else {
            content += "\n" + trimmedText
        }
        isDirty = true
        scheduleAutoSaveIfNeeded()
        Log.info("Appended text to editor: \(trimmedText.prefix(50))...")
    }

    /// Update content (marks as dirty)
    func updateContent(_ newContent: String) {
        if content != newContent {
            content = newContent
            isDirty = true
            hasSaveConflict = false
            scheduleAutoSaveIfNeeded()
        }
    }

    func reloadFromDisk() {
        guard let path = filePath else { return }
        loadFile(at: path, scrollToLine: nil)
    }

    /// Drop unsaved edits, restoring the editor to the last persisted file
    /// content if known. Used by the close-pane "Don't Save" path so the
    /// autosave debounce timer can't resurrect the discarded edits, and so
    /// any restore-on-relaunch path sees a clean editor.
    func discardPendingChanges() {
        autoSaveWorkItem?.cancel()
        autoSaveWorkItem = nil
        isDirty = false
        hasSaveConflict = false
        hasExternalChangeConflict = false
        externalConflictMessage = nil
        if let path = filePath,
           let diskContent = try? String(contentsOfFile: path, encoding: .utf8) {
            content = diskContent
            loadedContentHash = Self.contentHash(diskContent)
        }
    }

    func toggleCheckbox(lineNumber: Int) {
        guard let path = filePath, !isDirty else {
            updateContent(toggleCheckboxInContent(content, lineNumber: lineNumber))
            return
        }
        stopWatchingCurrentFile()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let currentDiskContent = try String(contentsOfFile: path, encoding: .utf8)
                let updated = toggleCheckboxInContent(currentDiskContent, lineNumber: lineNumber)
                try updated.write(toFile: path, atomically: true, encoding: .utf8)
                let hash = Self.contentHash(updated)
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.content = updated
                    self.loadedContentHash = hash
                    self.isDirty = false
                    self.hasExternalChangeConflict = false
                    self.hasSaveConflict = false
                    self.externalConflictMessage = nil
                    self.setAutoSaveStatusMessage(L("editor.autoSaved", "Auto-saved"))
                    self.startWatchingCurrentFile()
                }
            } catch {
                DispatchQueue.main.async {
                    self?.startWatchingCurrentFile()
                    self?.lastError = "Failed to toggle checkbox: \(error.localizedDescription)"
                }
            }
        }
    }

    /// Send a list of markdown code blocks to the terminal one at a time,
    /// waiting for each to settle (succeed or fail) before sending the next.
    /// `send` is responsible for actually forwarding the block to the shell
    /// and calling `markCodeBlockQueued` (typically via
    /// `SplitPaneController.sendCommandToTerminal`); this method only
    /// orchestrates the queue, so it stays composable with the existing
    /// per-block run path.
    ///
    /// If a block never reports a terminal state (e.g. no shell session is
    /// attached, or the user clears the runbook) the runner gives up after
    /// ~60s on that block and stops the whole sequence — the user can press
    /// Run All again or run remaining blocks individually.
    func runMarkdownBlocksSequentially(
        _ blocks: [(line: Int, code: String)],
        send: @escaping (String, Int) -> Void
    ) {
        sendNextMarkdownBlock(blocks: blocks, index: 0, send: send)
    }

    private func sendNextMarkdownBlock(
        blocks: [(line: Int, code: String)],
        index: Int,
        send: @escaping (String, Int) -> Void
    ) {
        guard index < blocks.count else { return }
        let block = blocks[index]
        send("\(block.code)\n", block.line)
        Polling.untilTrue(
            on: mainScheduler,
            predicate: { [weak self] in
                guard let self else { return true } // cancelled — let chain unwind
                switch codeBlockState(for: block.code, lineNumber: block.line) {
                case .succeeded, .failed: return true
                case .running, .none: return false
                }
            },
            onSettled: { [weak self] in
                self?.sendNextMarkdownBlock(blocks: blocks, index: index + 1, send: send)
            }
        )
    }

    func markCodeBlockQueued(_ code: String, lineNumber: Int, tabID: String) {
        let key = Self.runbookCodeBlockKey(for: code, lineNumber: lineNumber)
        codeBlockRunStates[key] = .running
        pendingRunbookPollWorkItems[key]?.cancel()
        let generation = (runbookExecutionGenerations[key] ?? 0) + 1
        runbookExecutionGenerations[key] = generation
        let submittedAt = Date()
        pollForCommandCompletion(
            command: code,
            key: key,
            generation: generation,
            tabID: tabID,
            submittedAt: submittedAt,
            attemptsRemaining: 120
        )
    }

    func codeBlockState(for code: String, lineNumber: Int) -> RunbookCodeBlockState? {
        codeBlockRunStates[Self.runbookCodeBlockKey(for: code, lineNumber: lineNumber)]
    }

    deinit {
        autoSaveWorkItem?.cancel()
        autoSaveClearWorkItem?.cancel()
        stopWatchingCurrentFile()
        for workItem in pendingRunbookPollWorkItems.values {
            workItem.cancel()
        }
    }

    private func scheduleAutoSaveIfNeeded() {
        guard isAutoSaveEnabled, filePath != nil else { return }
        autoSaveWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, isDirty else { return }
            _ = save()
        }
        autoSaveWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: workItem)
    }

    private func startWatchingCurrentFile() {
        guard let path = filePath, !path.isEmpty else { return }
        stopWatchingCurrentFile()
        fileMonitor = FileMonitor(url: URL(fileURLWithPath: path)) { [weak self] in
            DispatchQueue.main.async {
                self?.handleExternalFileChange()
            }
        }
        fileMonitor?.start()
    }

    private func stopWatchingCurrentFile() {
        fileMonitor?.stop()
        fileMonitor = nil
    }

    private func handleExternalFileChange() {
        guard !isApplyingExternalReload else { return }
        guard let path = filePath,
              let diskContent = try? String(contentsOfFile: path, encoding: .utf8) else {
            return
        }
        let diskHash = Self.contentHash(diskContent)
        guard diskHash != loadedContentHash else { return }
        if isDirty {
            hasExternalChangeConflict = true
            externalConflictMessage = L("editor.externalChangeConflict", "File changed externally. Reload?")
            return
        }
        isApplyingExternalReload = true
        content = diskContent
        loadedContentHash = diskHash
        isDirty = false
        hasExternalChangeConflict = false
        hasSaveConflict = false
        externalConflictMessage = nil
        isApplyingExternalReload = false
    }

    private func canSaveOverCurrentDiskVersion(path: String) -> Bool {
        guard let existingContent = try? String(contentsOfFile: path, encoding: .utf8) else {
            return !FileManager.default.fileExists(atPath: path)
        }
        guard let loadedContentHash else { return true }
        return Self.contentHash(existingContent) == loadedContentHash
    }

    private func setAutoSaveStatusMessage(_ message: String?) {
        autoSaveStatusMessage = message
        autoSaveClearWorkItem?.cancel()
        guard message != nil else { return }
        let workItem = DispatchWorkItem { [weak self] in
            self?.autoSaveStatusMessage = nil
        }
        autoSaveClearWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: workItem)
    }

    private func pollForCommandCompletion(
        command: String,
        key: RunbookCodeBlockKey,
        generation: Int,
        tabID: String,
        submittedAt: Date,
        attemptsRemaining: Int
    ) {
        guard attemptsRemaining > 0 else {
            codeBlockRunStates[key] = .failed
            pendingRunbookPollWorkItems.removeValue(forKey: key)
            return
        }
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let block = MainActor.assumeIsolated {
                CommandBlockManager.shared.blocksForTab(tabID)
            }.reversed().first { candidate in
                candidate.startTime >= submittedAt.addingTimeInterval(-1)
                    && Self.normalizedRunbookKey(for: candidate.command) == key.normalizedCommand
            }
            guard runbookExecutionGenerations[key] == generation else {
                pendingRunbookPollWorkItems.removeValue(forKey: key)
                return
            }
            if let block, !block.isRunning {
                codeBlockRunStates[key] = block.isSuccess ? .succeeded : .failed
                pendingRunbookPollWorkItems.removeValue(forKey: key)
                return
            }
            pollForCommandCompletion(
                command: command,
                key: key,
                generation: generation,
                tabID: tabID,
                submittedAt: submittedAt,
                attemptsRemaining: attemptsRemaining - 1
            )
        }
        pendingRunbookPollWorkItems[key] = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: workItem)
    }

    private static func contentHash(_ content: String) -> String {
        let digest = SHA256.hash(data: Data(content.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func normalizedRunbookKey(for command: String) -> String {
        command.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func runbookCodeBlockKey(for command: String, lineNumber: Int) -> RunbookCodeBlockKey {
        RunbookCodeBlockKey(
            lineNumber: lineNumber,
            normalizedCommand: normalizedRunbookKey(for: command)
        )
    }

    private static func shouldAutoEnableAutoSave(for path: String) -> Bool {
        let normalized = path.replacingOccurrences(of: "\\", with: "/")
        if normalized.hasSuffix("/.chau7/plan.md") {
            return true
        }
        if normalized.contains("/.chau7/sessions/"), normalized.hasSuffix("/plan.md") {
            return true
        }
        if SessionNoteAttachmentLocator.isSessionNotePath(normalized) {
            return true
        }
        return false
    }
}

enum RunbookCodeBlockState {
    case running
    case succeeded
    case failed
}

// MARK: - File Preview Model

/// Read-only file viewer model — lighter than TextEditorModel (no editing, no dirty tracking).
/// Supports both text files (with syntax highlighting) and image files.
@Observable
final class FilePreviewModel: Identifiable {
    let id = UUID()

    var content = ""
    var filePath: String?
    var isLoading = false
    var lastError: String?
    var imageData: Data?
    var isImageFile = false
    var scrollToLine: Int?

    @ObservationIgnored
    private var pendingScrollToLine: Int?
    @ObservationIgnored
    private var loadingToken: UUID?

    static let imageExtensions: Set = [
        "png", "jpg", "jpeg", "gif", "svg", "webp", "ico", "bmp", "tiff", "tif"
    ]

    var fileName: String {
        if let path = filePath {
            return (path as NSString).lastPathComponent
        }
        return L("tab.noFile", "No File")
    }

    var fileExtension: String {
        guard let path = filePath else { return "" }
        return (path as NSString).pathExtension.lowercased()
    }

    func loadFile(at path: String, scrollToLine line: Int? = nil) {
        let token = UUID()
        loadingToken = token
        isLoading = true
        lastError = nil
        pendingScrollToLine = line

        let ext = (path as NSString).pathExtension.lowercased()
        let isImage = Self.imageExtensions.contains(ext)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            if isImage {
                do {
                    let data = try Data(contentsOf: URL(fileURLWithPath: path))
                    DispatchQueue.main.async {
                        guard self?.loadingToken == token else { return }
                        self?.imageData = data
                        self?.isImageFile = true
                        self?.content = ""
                        self?.filePath = path
                        self?.isLoading = false
                        Log.info("Loaded image preview: \(path)")
                    }
                } catch {
                    DispatchQueue.main.async {
                        guard self?.loadingToken == token else { return }
                        self?.isLoading = false
                        self?.lastError = "Failed to load image: \(error.localizedDescription)"
                    }
                }
            } else {
                do {
                    let contents = try String(contentsOfFile: path, encoding: .utf8)
                    DispatchQueue.main.async {
                        guard self?.loadingToken == token else { return }
                        self?.content = contents
                        self?.isImageFile = false
                        self?.imageData = nil
                        self?.filePath = path
                        self?.isLoading = false
                        if let pending = self?.pendingScrollToLine {
                            self?.scrollToLine = pending
                            self?.pendingScrollToLine = nil
                        }
                        Log.info("Loaded file preview: \(path)")
                    }
                } catch {
                    DispatchQueue.main.async {
                        guard self?.loadingToken == token else { return }
                        self?.isLoading = false
                        self?.pendingScrollToLine = nil
                        self?.lastError = "Failed to load file: \(error.localizedDescription)"
                    }
                }
            }
        }
    }
}

// MARK: - Diff Viewer Model

/// Mode for diff comparison
enum DiffMode: String, Codable {
    case workingTree // git diff (unstaged changes)
    case staged // git diff --cached
}

/// A single line in a diff hunk
enum DiffLineType {
    case context(String)
    case addition(String)
    case deletion(String)
    case hunkHeader(String)
}

/// What the parser learned about the diff beyond the hunk content. Lets the
/// empty-state UI explain *why* there are no hunks instead of always
/// claiming "no changes" for files that are actually binary or renamed.
enum DiffSummary: Equatable {
    /// Normal textual diff (hunks may or may not be present).
    case content
    /// Git reported `Binary files a/foo and b/foo differ` — no textual hunks.
    case binary
    /// Git reported `rename from`/`rename to` lines; if textual hunks also
    /// appear in the diff (rename + edit) they're still parsed normally and
    /// the summary just adds the rename context.
    case renamed(from: String, to: String)
}

/// A parsed hunk from unified diff output
struct DiffHunk: Identifiable {
    let id = UUID()
    let header: String
    let oldStart: Int
    let oldCount: Int
    let newStart: Int
    let newCount: Int
    let lines: [DiffLineType]
}

/// Model for a git diff viewer pane.
/// Loads unified diff output via `git diff` and parses it into structured hunks.
@Observable
final class DiffViewerModel: Identifiable {
    let id = UUID()

    var filePath: String?
    var directory: String?
    var isLoading = false
    var lastError: String?
    var hunks: [DiffHunk] = []
    var diffMode: DiffMode = .workingTree
    var rawDiff = ""
    var additions = 0
    var deletions = 0
    /// What the parser detected outside the hunk lines (binary, rename, or
    /// plain content). Drives the empty-state UI when there are no hunks.
    var summary: DiffSummary = .content
    var protectedAccessSnapshot = ProtectedPathAccessPolicy.accessSnapshot(
        root: nil,
        isProtectedPath: false,
        isFeatureEnabled: false,
        hasActiveScope: false,
        hasSecurityScopedBookmark: false,
        isDeniedByCooldown: false,
        hasKnownIdentity: false
    )

    @ObservationIgnored
    private let gitRunner: ([String], String) -> String
    @ObservationIgnored
    private let accessSnapshotProvider: (String) -> ProtectedPathAccessSnapshot
    @ObservationIgnored
    private let accessRequester: (String, String) -> ProtectedPathAccessSnapshot
    @ObservationIgnored
    private let loadQueue: DispatchQueue
    @ObservationIgnored
    private var loadingToken: UUID?

    init(
        gitRunner: @escaping ([String], String) -> String = GitDiffTracker.runGit,
        accessSnapshotProvider: @escaping (String) -> ProtectedPathAccessSnapshot = { path in
            ProtectedPathPolicy.liveAccessSnapshot(forPath: path)
        },
        accessRequester: @escaping (String, String) -> ProtectedPathAccessSnapshot = { path, actionDescription in
            precondition(Thread.isMainThread, "Protected folder prompts must run on the main thread")
            return MainActor.assumeIsolated {
                ProtectedPathPolicy.ensureLiveAccessForUserInitiatedAction(
                    path: path,
                    actionDescription: actionDescription
                )
            }
        },
        loadQueue: DispatchQueue = DispatchQueue.global(qos: .userInitiated)
    ) {
        self.gitRunner = gitRunner
        self.accessSnapshotProvider = accessSnapshotProvider
        self.accessRequester = accessRequester
        self.loadQueue = loadQueue
    }

    var fileName: String {
        if let path = filePath {
            return (path as NSString).lastPathComponent
        }
        return L("tab.noFile", "No File")
    }

    @discardableResult
    func startLoading(file: String, in directory: String, mode: DiffMode = .workingTree) -> UUID {
        filePath = file
        self.directory = directory
        diffMode = mode
        isLoading = true
        lastError = nil
        let token = UUID()
        loadingToken = token
        return token
    }

    func finishLoading(
        token: UUID,
        file: String,
        output: String,
        parsed: ParseResult,
        effectiveMode: DiffMode
    ) {
        guard loadingToken == token else { return }
        rawDiff = output
        hunks = parsed.hunks
        additions = parsed.additions
        deletions = parsed.deletions
        summary = parsed.summary
        diffMode = effectiveMode
        isLoading = false
        Log.info("Loaded diff: \(file) (\(parsed.hunks.count) hunks, +\(parsed.additions)/-\(parsed.deletions))")
    }

    func loadDiff(file: String, in directory: String, mode: DiffMode = .workingTree) {
        guard let liveDirectory = prepareLiveGitAccess(for: directory, actionDescription: "load live diff") else {
            return
        }
        let token = startLoading(file: file, in: liveDirectory, mode: mode)

        loadQueue.async { [weak self] in
            var args = ["diff"]
            if mode == .staged { args.append("--cached") }
            args += ["--", file]

            var output = self?.gitRunner(args, liveDirectory) ?? ""
            var parsed = Self.parseUnifiedDiff(output)
            var effectiveMode = mode

            // Fallback: try staged diff if working tree was empty (runs on background thread)
            if output.isEmpty, parsed.hunks.isEmpty, mode == .workingTree {
                let stagedOutput = self?.gitRunner(["diff", "--cached", "--", file], liveDirectory) ?? ""
                if !stagedOutput.isEmpty {
                    output = stagedOutput
                    parsed = Self.parseUnifiedDiff(stagedOutput)
                    effectiveMode = .staged
                }
            }

            DispatchQueue.main.async {
                self?.finishLoading(
                    token: token,
                    file: file,
                    output: output,
                    parsed: parsed,
                    effectiveMode: effectiveMode
                )
            }
        }
    }

    func refresh() {
        guard let path = filePath, let dir = directory else { return }
        loadDiff(file: path, in: dir, mode: diffMode)
    }

    private func prepareLiveGitAccess(for directory: String, actionDescription: String) -> String? {
        let normalized = URL(fileURLWithPath: directory).standardized.path
        let initialSnapshot = accessSnapshotProvider(normalized)
        protectedAccessSnapshot = initialSnapshot

        guard initialSnapshot.root != nil, !initialSnapshot.canProbeLive else {
            lastError = nil
            return normalized
        }

        let updatedSnapshot = accessRequester(normalized, actionDescription)
        protectedAccessSnapshot = updatedSnapshot
        guard updatedSnapshot.canProbeLive else {
            lastError = liveAccessDeniedMessage(for: updatedSnapshot, actionDescription: actionDescription)
            isLoading = false
            return nil
        }

        lastError = nil
        return normalized
    }

    private func liveAccessDeniedMessage(for snapshot: ProtectedPathAccessSnapshot, actionDescription: String) -> String {
        let location = snapshot.root.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "this folder"
        switch snapshot.recommendedAction {
        case .enableFeature:
            return "Chau7 needs protected-folder access enabled to \(actionDescription) in \(location)."
        case .grantAccess:
            return "Grant Chau7 access to \(location) to \(actionDescription)."
        case .waitForCooldown:
            return "Chau7 cannot \(actionDescription) in \(location) until protected-folder access is granted again."
        case .regrantAccess:
            return "Chau7 needs refreshed access to \(location) to \(actionDescription)."
        case .none:
            return "Chau7 could not \(actionDescription)."
        }
    }

    func toggleDiffMode() {
        diffMode = diffMode == .workingTree ? .staged : .workingTree
        refresh()
    }

    // MARK: - Unified Diff Parser

    struct ParseResult {
        let hunks: [DiffHunk]
        let additions: Int
        let deletions: Int
        let summary: DiffSummary
    }

    static func parseUnifiedDiff(_ raw: String) -> ParseResult {
        guard !raw.isEmpty else {
            return ParseResult(hunks: [], additions: 0, deletions: 0, summary: .content)
        }

        var hunks: [DiffHunk] = []
        var currentLines: [DiffLineType] = []
        var currentHeader = ""
        var oldStart = 0, oldCount = 0, newStart = 0, newCount = 0
        var totalAdditions = 0, totalDeletions = 0
        var inHunk = false
        var isBinary = false
        var renameFrom: String?
        var renameTo: String?

        for line in raw.components(separatedBy: "\n") {
            if line.hasPrefix("@@") {
                // Flush previous hunk
                if inHunk {
                    hunks.append(DiffHunk(
                        header: currentHeader,
                        oldStart: oldStart, oldCount: oldCount,
                        newStart: newStart, newCount: newCount,
                        lines: currentLines
                    ))
                    currentLines = []
                }

                // Parse hunk header: @@ -oldStart,oldCount +newStart,newCount @@
                currentHeader = line
                let numbers = parseHunkHeader(line)
                oldStart = numbers.oldStart
                oldCount = numbers.oldCount
                newStart = numbers.newStart
                newCount = numbers.newCount
                currentLines.append(.hunkHeader(line))
                inHunk = true

            } else if inHunk {
                if line.hasPrefix("+") {
                    currentLines.append(.addition(String(line.dropFirst())))
                    totalAdditions += 1
                } else if line.hasPrefix("-") {
                    currentLines.append(.deletion(String(line.dropFirst())))
                    totalDeletions += 1
                } else if line.hasPrefix(" ") {
                    currentLines.append(.context(String(line.dropFirst())))
                } else if line.hasPrefix("\\") {
                    // "\ No newline at end of file" — skip
                }
            } else {
                // Pre-hunk header lines from `git diff`: detect binary and
                // rename markers so the empty-state UI can explain *why*
                // there are no hunks instead of just showing "no changes".
                if line.hasPrefix("Binary files ") || line.hasPrefix("GIT binary patch") {
                    isBinary = true
                } else if line.hasPrefix("rename from ") {
                    renameFrom = String(line.dropFirst("rename from ".count))
                } else if line.hasPrefix("rename to ") {
                    renameTo = String(line.dropFirst("rename to ".count))
                }
            }
        }

        // Flush last hunk
        if inHunk {
            hunks.append(DiffHunk(
                header: currentHeader,
                oldStart: oldStart, oldCount: oldCount,
                newStart: newStart, newCount: newCount,
                lines: currentLines
            ))
        }

        let summary: DiffSummary
        if isBinary {
            summary = .binary
        } else if let from = renameFrom, let to = renameTo {
            summary = .renamed(from: from, to: to)
        } else {
            summary = .content
        }

        return ParseResult(
            hunks: hunks,
            additions: totalAdditions,
            deletions: totalDeletions,
            summary: summary
        )
    }

    private static func parseHunkHeader(_ header: String) -> (oldStart: Int, oldCount: Int, newStart: Int, newCount: Int) {
        // Format: @@ -oldStart[,oldCount] +newStart[,newCount] @@
        let scanner = Scanner(string: header)
        _ = scanner.scanString("@@")
        _ = scanner.scanString("-")
        let oStart = scanner.scanInt() ?? 0
        var oCount = 1
        if scanner.scanString(",") != nil {
            oCount = scanner.scanInt() ?? 1
        }
        _ = scanner.scanString("+")
        let nStart = scanner.scanInt() ?? 0
        var nCount = 1
        if scanner.scanString(",") != nil {
            nCount = scanner.scanInt() ?? 1
        }
        return (oStart, oCount, nStart, nCount)
    }
}

// MARK: - Split Pane Controller

/// Manages split pane layout for a tab
@Observable
final class SplitPaneController {
    var root: SplitNode {
        didSet {
            reconcilePresentationTerminalAnchor()
        }
    }

    var focusedPaneID: UUID {
        didSet {
            rememberFocusedTerminalIfNeeded()
        }
    }

    @ObservationIgnored
    private var presentationTerminalPaneID: UUID?

    @ObservationIgnored
    private weak var appModel: AppModel?

    /// Modal dialogs (close-confirm, Save As) are injected so headless tests
    /// can drive the close-time decision path without spinning AppKit.
    @ObservationIgnored
    private let dialogs: Dialogs

    /// Main-queue scheduling abstraction used by the markdown runbook
    /// sequencer and the deferred-append polling so virtual-time tests can
    /// step those loops without sleeping.
    @ObservationIgnored
    private let mainScheduler: MainScheduler

    /// The owning tab's UUID, propagated to new terminal sessions so events
    /// carry a deterministic tabID for the TabResolver fast-path.
    @ObservationIgnored
    var ownerTabID: UUID? {
        didSet {
            // Stamp tabID on existing repo panes (e.g. after restore)
            if let repo = root.findFirstRepositoryPane() {
                repo.tabID = ownerTabID
            }
            attachUntitledSessionNoteEditorsIfPossible()
        }
    }

    /// Applies tab-level configuration to current and future terminal sessions.
    /// Used to keep split-created sessions aligned with the parent tab's callbacks.
    @ObservationIgnored
    var terminalSessionConfigurator: ((TerminalSessionModel) -> Void)? {
        didSet {
            for (_, session) in terminalSessions {
                configureTerminalSession(session)
            }
        }
    }

    /// Send a command to the first terminal session in this split tree (for markdown runbooks).
    func sendCommandToTerminal(_ command: String, sourceEditor: TextEditorModel? = nil, sourceLineNumber: Int? = nil) {
        func findSession(_ node: SplitNode) -> TerminalSessionModel? {
            switch node {
            case .terminal(_, let session): return session
            case .textEditor, .filePreview, .diffViewer, .repositoryPane, .dashboard: return nil
            case .split(_, _, let first, let second, _):
                return findSession(first) ?? findSession(second)
            }
        }
        guard let session = findSession(root) else { return }
        session.sendInput(command)
        if let sourceEditor, let sourceLineNumber, let tabID = session.ownerTabID?.uuidString {
            sourceEditor.markCodeBlockQueued(command, lineNumber: sourceLineNumber, tabID: tabID)
        }
    }

    /// F03: Callback for terminal Cmd+Click on file paths - opens in internal editor
    var onFilePathClicked: (String, Int?, Int?) -> Void {
        { [weak self] path, line, _ in
            self?.openFileInEditor(path: path, line: line)
        }
    }

    private func configureTerminalSession(_ session: TerminalSessionModel) {
        if let ownerTabID {
            session.ownerTabID = ownerTabID
        }
        terminalSessionConfigurator?(session)
    }

    private func configureTextEditor(_ editor: TextEditorModel) {
        editor.untitledSaveHandler = { [weak self] model in
            self?.saveUntitledEditorToAttachedSessionNote(model) ?? false
        }
    }

    init(
        appModel: AppModel,
        dialogs: Dialogs = SystemDialogs(),
        mainScheduler: MainScheduler = SystemMainScheduler()
    ) {
        self.appModel = appModel
        self.dialogs = dialogs
        self.mainScheduler = mainScheduler
        let session = TerminalSessionModel(appModel: appModel)
        let id = UUID()
        self.root = .terminal(id: id, session: session)
        self.focusedPaneID = id
        self.presentationTerminalPaneID = id
        configureTerminalSession(session)
    }

    /// Initialize with an existing terminal session
    init(
        appModel: AppModel,
        session: TerminalSessionModel,
        dialogs: Dialogs = SystemDialogs(),
        mainScheduler: MainScheduler = SystemMainScheduler()
    ) {
        self.appModel = appModel
        self.dialogs = dialogs
        self.mainScheduler = mainScheduler
        let id = UUID()
        self.root = .terminal(id: id, session: session)
        self.focusedPaneID = id
        self.presentationTerminalPaneID = id
        configureTerminalSession(session)
    }

    init(
        appModel: AppModel,
        root: SplitNode,
        focusedPaneID: UUID? = nil,
        dialogs: Dialogs = SystemDialogs(),
        mainScheduler: MainScheduler = SystemMainScheduler()
    ) {
        self.appModel = appModel
        self.dialogs = dialogs
        self.mainScheduler = mainScheduler
        self.root = root
        if let focusedPaneID, root.allPaneIDs.contains(focusedPaneID) {
            self.focusedPaneID = focusedPaneID
        } else if let firstTerminalID = root.allTerminalIDs.first {
            self.focusedPaneID = firstTerminalID
        } else {
            self.focusedPaneID = root.allPaneIDs.first ?? UUID()
        }
        self.presentationTerminalPaneID = Self.presentationTerminalID(
            in: root,
            focusedPaneID: self.focusedPaneID,
            previousPresentationTerminalPaneID: nil
        )
        for (_, session) in terminalSessions {
            configureTerminalSession(session)
        }
        for editor in root.allEditors {
            configureTextEditor(editor)
        }
    }

    /// Returns all terminal sessions with their pane IDs.
    var terminalSessions: [(UUID, TerminalSessionModel)] {
        root.terminalSessionPairs
    }

    /// Exports the current split layout for persistence.
    func exportLayout() -> SavedSplitNode {
        root.savedRepresentation
    }

    /// Restores focus for a pane if it still exists in the current tree.
    func setFocusedPane(_ paneID: UUID) {
        guard root.allPaneIDs.contains(paneID) else { return }
        focusedPaneID = paneID
    }

    /// Returns the terminal pane that should receive shell focus. When a
    /// non-terminal side pane is focused, this remains anchored to the most
    /// recently focused terminal pane instead of drifting back to the primary
    /// terminal.
    func focusedTerminalSessionID() -> UUID? {
        if root.paneType(for: focusedPaneID) == .terminal {
            return focusedPaneID
        }
        return validPresentationTerminalPaneID() ?? root.allTerminalIDs.first
    }

    private static func presentationTerminalID(
        in root: SplitNode,
        focusedPaneID: UUID,
        previousPresentationTerminalPaneID: UUID?
    ) -> UUID? {
        PresentationPaneFocusPolicy.selectedTerminalPaneID(
            focusedPaneID: focusedPaneID,
            terminalPaneIDs: root.allTerminalIDs,
            previousPresentationPaneID: previousPresentationTerminalPaneID
        )
    }

    private func validPresentationTerminalPaneID() -> UUID? {
        guard let presentationTerminalPaneID,
              root.findSession(id: presentationTerminalPaneID) != nil else {
            return nil
        }
        return presentationTerminalPaneID
    }

    private func rememberFocusedTerminalIfNeeded() {
        presentationTerminalPaneID = Self.presentationTerminalID(
            in: root,
            focusedPaneID: focusedPaneID,
            previousPresentationTerminalPaneID: presentationTerminalPaneID
        )
    }

    private func reconcilePresentationTerminalAnchor() {
        presentationTerminalPaneID = Self.presentationTerminalID(
            in: root,
            focusedPaneID: focusedPaneID,
            previousPresentationTerminalPaneID: presentationTerminalPaneID
        )
    }

    var attachedSessionNotePath: String? {
        guard let repoRoot = currentRepoRootForSessionNote(),
              let ownerTabID else {
            return nil
        }
        return SessionNoteAttachmentLocator.filePath(repoRoot: repoRoot, tabID: ownerTabID)
    }

    private var existingAttachedSessionNotePath: String? {
        guard let path = attachedSessionNotePath,
              FileManager.default.fileExists(atPath: path) else {
            return nil
        }
        return path
    }

    private func currentRepoRootForSessionNote() -> String? {
        let candidateSessions: [TerminalSessionModel?] = [
            focusedSession,
            presentationSession,
            primarySession
        ]
        for session in candidateSessions.compactMap({ $0 }) {
            if let root = session.displayGitRootPath?.trimmingCharacters(in: .whitespacesAndNewlines),
               !root.isEmpty {
                return URL(fileURLWithPath: root).standardized.path
            }
        }
        return nil
    }

    private func ensureSessionNoteFileExists(at path: String) {
        let url = URL(fileURLWithPath: path)
        FileOperations.createDirectory(at: url.deletingLastPathComponent())
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        _ = FileOperations.writeString("", to: url.path)
    }

    private func resolvedTextEditorFilePath(_ filePath: String?) -> String? {
        guard let filePath else {
            return preparedAttachedSessionNotePath()
        }
        return filePath
    }

    private func preparedAttachedSessionNotePath() -> String? {
        guard let path = attachedSessionNotePath else { return nil }
        ensureSessionNoteFileExists(at: path)
        return path
    }

    func attachUntitledSessionNoteEditorsIfPossible() {
        guard let notePath = preparedAttachedSessionNotePath() else { return }
        for editor in root.allEditors where editor.filePath == nil {
            editor.loadFile(at: notePath)
        }
    }

    @discardableResult
    private func saveUntitledEditorToAttachedSessionNote(_ editor: TextEditorModel) -> Bool {
        guard let repoRoot = currentRepoRootForSessionNote(),
              let ownerTabID else {
            return false
        }

        let path = SessionNoteAttachmentLocator.filePath(repoRoot: repoRoot, tabID: ownerTabID)
        ensureSessionNoteFileExists(at: path)
        return editor.saveAs(to: path)
    }

    func restoreAttachedSessionNoteIfNeeded() {
        guard root.firstPaneID(ofType: .textEditor) == nil,
              let notePath = existingAttachedSessionNotePath else {
            return
        }
        let preservedFocus = focusedPaneID
        splitWithTextEditor(direction: .horizontal, filePath: notePath)
        setFocusedPane(preservedFocus)
    }

    // MARK: - Split Operations

    /// Splits the focused pane with a new terminal
    func splitWithTerminal(direction: SplitDirection) {
        guard FeatureSettings.shared.isSplitPanesEnabled else { return }
        guard let appModel else { return }

        let newSession = TerminalSessionModel(appModel: appModel)
        configureTerminalSession(newSession)
        let newID = UUID()
        let newNode = SplitNode.terminal(id: newID, session: newSession)

        root = splitNode(root, targetID: focusedPaneID, direction: direction, newNode: newNode)
        focusedPaneID = newID
    }

    /// Splits the focused pane with a text editor
    /// Note: This always works regardless of isSplitPanesEnabled since it's an explicit user action
    func splitWithTextEditor(direction: SplitDirection, filePath: String? = nil, scrollToLine: Int? = nil) {
        let editor = TextEditorModel()
        configureTextEditor(editor)
        if let path = resolvedTextEditorFilePath(filePath) {
            editor.loadFile(at: path, scrollToLine: scrollToLine)
        }
        let newID = UUID()
        let newNode = SplitNode.textEditor(id: newID, editor: editor)

        root = splitNode(root, targetID: focusedPaneID, direction: direction, newNode: newNode)
        focusedPaneID = newID
    }

    /// Toggles the text editor pane: closes if one exists, opens if not.
    func toggleTextEditor(filePath: String? = nil) {
        if let paneID = root.firstPaneID(ofType: .textEditor) {
            closePane(id: paneID)
        } else {
            splitWithTextEditor(direction: .horizontal, filePath: filePath)
        }
    }

    /// Opens a file in the existing text editor, or creates a new split if none exists
    func openFileInEditor(path: String, line: Int? = nil) {
        if let editor = root.findFirstEditor() {
            editor.loadFile(at: path, scrollToLine: line)
        } else {
            splitWithTextEditor(direction: .horizontal, filePath: path, scrollToLine: line)
        }
    }

    // MARK: - File Preview

    /// Splits the focused pane with a read-only file preview
    func splitWithFilePreview(direction: SplitDirection, filePath: String? = nil, scrollToLine: Int? = nil) {
        let preview = FilePreviewModel()
        if let path = filePath {
            preview.loadFile(at: path, scrollToLine: scrollToLine)
        }
        let newID = UUID()
        let newNode = SplitNode.filePreview(id: newID, preview: preview)

        root = splitNode(root, targetID: focusedPaneID, direction: direction, newNode: newNode)
        focusedPaneID = newID
    }

    /// Toggles the file preview pane: closes if one exists, opens if not.
    func toggleFilePreview(filePath: String? = nil) {
        if let paneID = root.firstPaneID(ofType: .filePreview) {
            closePane(id: paneID)
        } else {
            splitWithFilePreview(direction: .horizontal, filePath: filePath)
        }
    }

    /// Opens a file in the existing preview pane, or creates a new split if none exists
    func openFilePreview(path: String, line: Int? = nil) {
        if let preview = root.findFirstFilePreview() {
            preview.loadFile(at: path, scrollToLine: line)
        } else {
            splitWithFilePreview(direction: .horizontal, filePath: path, scrollToLine: line)
        }
    }

    // MARK: - Diff Viewer

    /// Splits the focused pane with a diff viewer
    func splitWithDiffViewer(direction: SplitDirection, filePath: String, directory: String, mode: DiffMode = .workingTree) {
        let diff = DiffViewerModel()
        diff.loadDiff(file: filePath, in: directory, mode: mode)
        let newID = UUID()
        let newNode = SplitNode.diffViewer(id: newID, diff: diff)

        root = splitNode(root, targetID: focusedPaneID, direction: direction, newNode: newNode)
        focusedPaneID = newID
    }

    /// Opens a diff in the existing diff viewer, or creates a new split if none exists
    func openDiffViewer(filePath: String, directory: String, mode: DiffMode = .workingTree) {
        if let diff = root.findFirstDiffViewer() {
            diff.loadDiff(file: filePath, in: directory, mode: mode)
        } else {
            splitWithDiffViewer(direction: .horizontal, filePath: filePath, directory: directory, mode: mode)
        }
    }

    // MARK: - Repository Pane

    /// Splits the focused pane with a repository pane
    func splitWithRepositoryPane(direction: SplitDirection, directory: String) {
        let repo = RepositoryPaneModel()
        repo.tabID = ownerTabID
        repo.load(directory: directory)
        let newID = UUID()
        let newNode = SplitNode.repositoryPane(id: newID, repo: repo)

        root = splitNode(root, targetID: focusedPaneID, direction: direction, newNode: newNode)
        focusedPaneID = newID
    }

    /// Toggles the repository pane: closes if one exists, opens if not.
    func toggleRepositoryPane(directory: String) {
        if let paneID = root.firstPaneID(ofType: .repositoryPane) {
            closePane(id: paneID)
        } else {
            splitWithRepositoryPane(direction: .horizontal, directory: directory)
        }
    }

    /// Opens a repository pane, reusing an existing one or creating a new split.
    /// For toggle behavior (close if open), use `toggleRepositoryPane` instead.
    func openRepositoryPane(directory: String) {
        if let repo = root.findFirstRepositoryPane() {
            repo.load(directory: directory)
        } else {
            splitWithRepositoryPane(direction: .horizontal, directory: directory)
        }
    }

    private func splitNode(_ node: SplitNode, targetID: UUID, direction: SplitDirection, newNode: SplitNode) -> SplitNode {
        switch node {
        case .terminal(let id, _),
             .textEditor(let id, _),
             .filePreview(let id, _),
             .diffViewer(let id, _),
             .repositoryPane(let id, _),
             .dashboard(let id, _):
            if id == targetID {
                return .split(
                    id: UUID(),
                    direction: direction,
                    first: node,
                    second: newNode,
                    ratio: 0.5
                )
            }
            return node

        case .split(let id, let dir, let first, let second, let ratio):
            return .split(
                id: id,
                direction: dir,
                first: splitNode(first, targetID: targetID, direction: direction, newNode: newNode),
                second: splitNode(second, targetID: targetID, direction: direction, newNode: newNode),
                ratio: ratio
            )
        }
    }

    /// Closes the focused pane
    func closeFocusedPane() {
        closePane(id: focusedPaneID)
    }

    /// Closes a specific pane by ID. For a dirty text editor that the user did
    /// not opt into auto-save for, prompts to save/discard/cancel — Cancel
    /// aborts the close. Auto-save-enabled editors (session notes, plan.md)
    /// flush silently on close because the user has already opted into
    /// continuous saving; suppressing the prompt for those files preserves
    /// the type-and-⌃⌘W flow that `.chau7/sessions/<tab>/note.md` relies on.
    /// This is the single source of truth for close-time save decisions; the
    /// per-view close button and the ⌃⌘W menu both flow through here.
    func closePane(id: UUID) {
        // Don't close if it's the only pane
        guard root.allPaneIDs.count > 1 else { return }

        if let editor = root.findEditor(id: id), editor.isDirty {
            if editor.isAutoSaveEnabled {
                if editor.filePath != nil {
                    _ = editor.save()
                } else {
                    _ = editor.saveUntitledIfPossible()
                }
            } else {
                guard confirmCloseDirtyEditor(editor) else { return }
            }
        }

        let result = removeNode(root, targetID: id)
        if let newRoot = result.node {
            root = newRoot
            // If we closed the focused pane, focus the sibling or first available
            if focusedPaneID == id {
                if let newFocus = result.siblingID ?? root.allPaneIDs.first {
                    focusedPaneID = newFocus
                }
            }
        }
    }

    /// Run the save/discard/cancel dialog for a dirty editor. Returns true when
    /// the caller should proceed with the close (saved or explicitly discarded),
    /// false on cancel or on a failed Save As that the user did not complete.
    private func confirmCloseDirtyEditor(_ editor: TextEditorModel) -> Bool {
        switch dialogs.confirmCloseDirtyEditor() {
        case .save:
            if editor.filePath != nil {
                return editor.save()
            }
            if editor.saveUntitledIfPossible() {
                return true
            }
            return runSaveAsPanel(for: editor)
        case .dontSave:
            // Don't Save: explicitly discard pending edits so downstream code
            // (autosave debounce, restore-on-relaunch) doesn't resurrect them.
            editor.discardPendingChanges()
            return true
        case .cancel:
            return false
        }
    }

    private func runSaveAsPanel(for editor: TextEditorModel) -> Bool {
        let defaultName = L("editor.defaultFilename", "untitled.txt")
        guard let chosenPath = dialogs.runSaveAsPanel(defaultName: defaultName) else {
            return false
        }
        return editor.saveAs(to: chosenPath)
    }

    private func removeNode(_ node: SplitNode, targetID: UUID) -> (node: SplitNode?, siblingID: UUID?) {
        switch node {
        case .terminal(let id, let session):
            if id == targetID {
                session.closeSession()
                return (nil, nil)
            }
            return (node, nil)

        case .textEditor(let id, _):
            if id == targetID {
                // The close-time save/discard decision is made by `closePane`
                // before it ever reaches this case, so there is nothing more
                // to do here than drop the node from the tree.
                return (nil, nil)
            }
            return (node, nil)

        case .filePreview(let id, _),
             .diffViewer(let id, _),
             .repositoryPane(let id, _),
             .dashboard(let id, _):
            if id == targetID {
                return (nil, nil)
            }
            return (node, nil)

        case .split(let id, let dir, let first, let second, let ratio):
            // Recurse into both children
            let firstResult = removeNode(first, targetID: targetID)
            let secondResult = removeNode(second, targetID: targetID)

            // Both children still exist - rebuild the split
            if let newFirst = firstResult.node, let newSecond = secondResult.node {
                return (
                    .split(id: id, direction: dir, first: newFirst, second: newSecond, ratio: ratio),
                    firstResult.siblingID ?? secondResult.siblingID
                )
            }
            // First child was removed - promote second child, return first pane of second as sibling
            if firstResult.node == nil, let newSecond = secondResult.node {
                return (newSecond, newSecond.allPaneIDs.first)
            }
            // Second child was removed - promote first child, return first pane of first as sibling
            if let newFirst = firstResult.node, secondResult.node == nil {
                return (newFirst, newFirst.allPaneIDs.first)
            }
            // Both removed (shouldn't happen normally)
            return (nil, nil)
        }
    }

    // MARK: - Navigation

    /// Focuses the next pane in order
    func focusNextPane() {
        let ids = root.allPaneIDs
        guard ids.count > 1,
              let currentIndex = ids.firstIndex(of: focusedPaneID) else { return }
        let nextIndex = (currentIndex + 1) % ids.count
        focusedPaneID = ids[nextIndex]
    }

    /// Focuses the previous pane in order
    func focusPreviousPane() {
        let ids = root.allPaneIDs
        guard ids.count > 1,
              let currentIndex = ids.firstIndex(of: focusedPaneID) else { return }
        let prevIndex = (currentIndex - 1 + ids.count) % ids.count
        focusedPaneID = ids[prevIndex]
    }

    /// Gets the focused session (if focused pane is a terminal)
    var focusedSession: TerminalSessionModel? {
        root.findSession(id: focusedPaneID)
    }

    /// Gets the terminal session that should drive tab chrome, snapshots, and
    /// selected-tab render recovery. Non-terminal panes can own keyboard focus
    /// without changing which shell pane is considered visually active.
    var presentationSession: TerminalSessionModel? {
        if let session = focusedSession {
            return session
        }
        if let terminalPaneID = validPresentationTerminalPaneID() ?? root.allTerminalIDs.first,
           let session = root.findSession(id: terminalPaneID) {
            return session
        }
        return primarySession
    }

    /// Gets the focused editor (if focused pane is an editor)
    var focusedEditor: TextEditorModel? {
        root.findEditor(id: focusedPaneID)
    }

    /// Gets the first terminal session in the tree
    var primarySession: TerminalSessionModel? {
        func findFirst(_ node: SplitNode) -> TerminalSessionModel? {
            switch node {
            case .terminal(_, let session):
                return session
            case .textEditor, .filePreview, .diffViewer, .repositoryPane, .dashboard:
                return nil
            case .split(_, _, let first, let second, _):
                return findFirst(first) ?? findFirst(second)
            }
        }
        return findFirst(root)
    }

    // MARK: - Resize

    /// Adjusts the split ratio for the parent of the focused pane
    func adjustRatio(delta: CGFloat) {
        root = adjustRatioInNode(root, targetID: focusedPaneID, delta: delta)
    }

    private func adjustRatioInNode(_ node: SplitNode, targetID: UUID, delta: CGFloat) -> SplitNode {
        switch node {
        case .terminal, .textEditor, .filePreview, .diffViewer, .repositoryPane, .dashboard:
            return node

        case .split(let id, let dir, let first, let second, var ratio):
            // Check if target is in first or second
            let firstIDs = first.allPaneIDs
            let secondIDs = second.allPaneIDs

            if firstIDs.contains(targetID) || secondIDs.contains(targetID) {
                // Adjust ratio at this level
                ratio = max(0.1, min(0.9, ratio + delta))
            }

            return .split(
                id: id,
                direction: dir,
                first: adjustRatioInNode(first, targetID: targetID, delta: delta),
                second: adjustRatioInNode(second, targetID: targetID, delta: delta),
                ratio: ratio
            )
        }
    }

    /// Updates the ratio for a specific split node by ID
    func updateRatio(splitID: UUID, newRatio: CGFloat) {
        root = updateRatioInNode(root, splitID: splitID, newRatio: newRatio)
    }

    private func updateRatioInNode(_ node: SplitNode, splitID: UUID, newRatio: CGFloat) -> SplitNode {
        switch node {
        case .terminal, .textEditor, .filePreview, .diffViewer, .repositoryPane, .dashboard:
            return node

        case .split(let id, let dir, let first, let second, let ratio):
            if id == splitID {
                // This is the split to update
                let clampedRatio = max(0.1, min(0.9, newRatio))
                return .split(id: id, direction: dir, first: first, second: second, ratio: clampedRatio)
            }

            // Recurse into children
            return .split(
                id: id,
                direction: dir,
                first: updateRatioInNode(first, splitID: splitID, newRatio: newRatio),
                second: updateRatioInNode(second, splitID: splitID, newRatio: newRatio),
                ratio: ratio
            )
        }
    }

    // MARK: - Text Editor Operations

    /// Appends selected text from the terminal to the side text editor,
    /// opening one if none exists. ⇧⌥⌘E used to log a warning and do nothing
    /// when no editor was open, which made the shortcut feel broken — the
    /// implicit mental model is "send selection to editor", so we now create
    /// the editor on demand. The new editor attaches to the tab-scoped
    /// session note (when a repo root is known) via the existing untitled
    /// auto-attach plumbing, so the appended selection lands somewhere
    /// durable instead of being thrown away on tab close.
    func appendSelectionToEditor(_ text: String) {
        if let editor = root.findFirstEditor() {
            editor.appendText(text)
            return
        }
        splitWithTextEditor(direction: .horizontal)
        guard let editor = root.findFirstEditor() else {
            Log.warn("Failed to open text editor for selection append")
            return
        }
        appendTextAfterEditorLoad(editor, text: text)
    }

    /// The freshly created editor may still be loading its attached session
    /// note off the background queue, so we defer the append until the load
    /// settles. After a short timeout we append anyway — losing the user's
    /// selection because we waited for a load that never resolved would be
    /// worse than appending into the in-memory buffer.
    private func appendTextAfterEditorLoad(_ editor: TextEditorModel, text: String) {
        Polling.untilTrue(
            on: mainScheduler,
            every: 0.05,
            attempts: 40,
            predicate: { [weak editor] in editor?.isLoading == false },
            onSettled: { [weak editor] in editor?.appendText(text) },
            onTimeout: { [weak editor] in editor?.appendText(text) }
        )
    }

    /// Checks if there's a text editor open
    var hasTextEditor: Bool {
        root.hasTextEditor
    }
}

// Note: Split pane views moved to SplitPaneViews.swift
