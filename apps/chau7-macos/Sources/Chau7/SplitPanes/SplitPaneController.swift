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

    static func == (lhs: SavedSplitNode, rhs: SavedSplitNode) -> Bool {
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
                if !state.directory.isEmpty {
                    session.updateCurrentDirectory(state.directory)
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
    }

    static func parseUnifiedDiff(_ raw: String) -> ParseResult {
        guard !raw.isEmpty else { return ParseResult(hunks: [], additions: 0, deletions: 0) }

        var hunks: [DiffHunk] = []
        var currentLines: [DiffLineType] = []
        var currentHeader = ""
        var oldStart = 0, oldCount = 0, newStart = 0, newCount = 0
        var totalAdditions = 0, totalDeletions = 0
        var inHunk = false

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
            }
            // Skip diff header lines (diff --git, index, ---, +++)
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

        return ParseResult(hunks: hunks, additions: totalAdditions, deletions: totalDeletions)
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
    var root: SplitNode
    var focusedPaneID: UUID

    @ObservationIgnored
    private weak var appModel: AppModel?

    /// The owning tab's UUID, propagated to new terminal sessions so events
    /// carry a deterministic tabID for the TabResolver fast-path.
    @ObservationIgnored
    var ownerTabID: UUID? {
        didSet {
            // Stamp tabID on existing repo panes (e.g. after restore)
            if let repo = root.findFirstRepositoryPane() {
                repo.tabID = ownerTabID
            }
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

    init(appModel: AppModel) {
        self.appModel = appModel
        let session = TerminalSessionModel(appModel: appModel)
        let id = UUID()
        self.root = .terminal(id: id, session: session)
        self.focusedPaneID = id
        configureTerminalSession(session)
    }

    /// Initialize with an existing terminal session
    init(appModel: AppModel, session: TerminalSessionModel) {
        self.appModel = appModel
        let id = UUID()
        self.root = .terminal(id: id, session: session)
        self.focusedPaneID = id
        configureTerminalSession(session)
    }

    init(appModel: AppModel, root: SplitNode, focusedPaneID: UUID? = nil) {
        self.appModel = appModel
        self.root = root
        if let focusedPaneID, root.allPaneIDs.contains(focusedPaneID) {
            self.focusedPaneID = focusedPaneID
        } else if let firstTerminalID = root.allTerminalIDs.first {
            self.focusedPaneID = firstTerminalID
        } else {
            self.focusedPaneID = root.allPaneIDs.first ?? UUID()
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

    /// Returns the focused terminal pane ID when applicable; otherwise nil.
    func focusedTerminalSessionID() -> UUID? {
        if root.paneType(for: focusedPaneID) == .terminal {
            return focusedPaneID
        }
        return root.allTerminalIDs.first
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
        if let path = filePath {
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

    /// Closes a specific pane by ID
    func closePane(id: UUID) {
        // Don't close if it's the only pane
        guard root.allPaneIDs.count > 1 else { return }

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

    private func removeNode(_ node: SplitNode, targetID: UUID) -> (node: SplitNode?, siblingID: UUID?) {
        switch node {
        case .terminal(let id, let session):
            if id == targetID {
                session.closeSession()
                return (nil, nil)
            }
            return (node, nil)

        case .textEditor(let id, _),
             .filePreview(let id, _),
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

    /// Appends selected text from terminal to the first text editor
    func appendSelectionToEditor(_ text: String) {
        if let editor = root.findFirstEditor() {
            editor.appendText(text)
        } else {
            Log.warn("No text editor pane open to append to")
        }
    }

    /// Checks if there's a text editor open
    var hasTextEditor: Bool {
        root.hasTextEditor
    }
}

// Note: Split pane views moved to SplitPaneViews.swift
