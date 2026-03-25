import SwiftUI
import AppKit

// MARK: - F02: Native Split Panes with Text Editor Support

enum SavedSplitNodeKind: String, Codable {
    case terminal
    case textEditor
    case filePreview
    case diffViewer
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
        diffMode: String? = nil
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
}

/// Represents a node in the split pane tree
indirect enum SplitNode: Identifiable {
    case terminal(id: UUID, session: TerminalSessionModel)
    case textEditor(id: UUID, editor: TextEditorModel)
    case filePreview(id: UUID, preview: FilePreviewModel)
    case diffViewer(id: UUID, diff: DiffViewerModel)
    case split(id: UUID, direction: SplitDirection, first: SplitNode, second: SplitNode, ratio: CGFloat)

    var id: UUID {
        switch self {
        case .terminal(let id, _),
             .textEditor(let id, _),
             .filePreview(let id, _),
             .diffViewer(let id, _):
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
             .diffViewer(let id, _):
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
        case .textEditor, .filePreview, .diffViewer:
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
        case .textEditor, .filePreview, .diffViewer:
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
        case .textEditor, .filePreview, .diffViewer:
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
            if let state = paneStates[resolvedID], !state.directory.isEmpty {
                session.updateCurrentDirectory(state.directory)
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
        case .textEditor, .filePreview, .diffViewer:
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
        case .textEditor, .filePreview, .diffViewer:
            return nil
        case .split(_, _, let first, let second, _):
            return first.findSession(id: id) ?? second.findSession(id: id)
        }
    }

    /// Finds a text editor model by ID
    func findEditor(id: UUID) -> TextEditorModel? {
        switch self {
        case .terminal, .filePreview, .diffViewer:
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
        case .terminal, .filePreview, .diffViewer:
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
        case .terminal, .textEditor, .diffViewer:
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
        case .terminal, .textEditor, .diffViewer:
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
        case .terminal, .textEditor, .filePreview:
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
        case .terminal, .textEditor, .filePreview:
            return nil
        case .diffViewer(_, let diff):
            return diff
        case .split(_, _, let first, let second, _):
            return first.findFirstDiffViewer() ?? second.findFirstDiffViewer()
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
        case .split(_, _, let first, let second, _):
            return first.paneType(for: id) ?? second.paneType(for: id)
        }
    }

    /// Checks if tree has any text editors
    var hasTextEditor: Bool {
        switch self {
        case .terminal, .filePreview, .diffViewer:
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
final class TextEditorModel: ObservableObject, Identifiable {
    let id = UUID()

    @Published var content = ""
    @Published var filePath: String?
    @Published var isDirty = false
    @Published var isLoading = false
    @Published var lastError: String?
    @Published var scrollToLine: Int? // F03: Line to scroll to after loading (set after content loads)

    /// Pending line to scroll to after next load completes
    private var pendingScrollToLine: Int?

    /// Token to track current loading operation (prevents race conditions)
    private var loadingToken: UUID?

    /// The file name for display
    var fileName: String {
        if let path = filePath {
            return (path as NSString).lastPathComponent
        }
        return "Untitled"
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
        pendingScrollToLine = line // Store for after load completes

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let contents = try String(contentsOfFile: path, encoding: .utf8)
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
    func save() {
        guard let path = filePath else {
            Log.warn("No file path set, cannot save")
            return
        }
        saveAs(to: path)
    }

    /// Save content to a specific path
    /// Returns true on success, false on failure
    @discardableResult
    func saveAs(to path: String) -> Bool {
        lastError = nil
        do {
            try content.write(toFile: path, atomically: true, encoding: .utf8)
            filePath = path
            isDirty = false
            Log.info("Saved file: \(path)")
            return true
        } catch {
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
        Log.info("Appended text to editor: \(trimmedText.prefix(50))...")
    }

    /// Update content (marks as dirty)
    func updateContent(_ newContent: String) {
        if content != newContent {
            content = newContent
            isDirty = true
        }
    }
}

// MARK: - File Preview Model

/// Read-only file viewer model — lighter than TextEditorModel (no editing, no dirty tracking).
/// Supports both text files (with syntax highlighting) and image files.
final class FilePreviewModel: ObservableObject, Identifiable {
    let id = UUID()

    @Published var content = ""
    @Published var filePath: String?
    @Published var isLoading = false
    @Published var lastError: String?
    @Published var imageData: Data?
    @Published var isImageFile = false
    @Published var scrollToLine: Int?

    private var pendingScrollToLine: Int?
    private var loadingToken: UUID?

    static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "svg", "webp", "ico", "bmp", "tiff", "tif"
    ]

    var fileName: String {
        if let path = filePath {
            return (path as NSString).lastPathComponent
        }
        return "No File"
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
    case workingTree  // git diff (unstaged changes)
    case staged       // git diff --cached
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
final class DiffViewerModel: ObservableObject, Identifiable {
    let id = UUID()

    @Published var filePath: String?
    @Published var directory: String?
    @Published var isLoading = false
    @Published var lastError: String?
    @Published var hunks: [DiffHunk] = []
    @Published var diffMode: DiffMode = .workingTree
    @Published var rawDiff: String = ""
    @Published var additions: Int = 0
    @Published var deletions: Int = 0

    var fileName: String {
        if let path = filePath {
            return (path as NSString).lastPathComponent
        }
        return "No File"
    }

    func loadDiff(file: String, in directory: String, mode: DiffMode = .workingTree) {
        self.filePath = file
        self.directory = directory
        self.diffMode = mode
        isLoading = true
        lastError = nil

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var args = ["diff"]
            if mode == .staged { args.append("--cached") }
            args += ["--", file]

            var output = GitDiffTracker.runGit(args: args, in: directory)
            var parsed = Self.parseUnifiedDiff(output)
            var effectiveMode = mode

            // Fallback: try staged diff if working tree was empty (runs on background thread)
            if output.isEmpty && parsed.hunks.isEmpty && mode == .workingTree {
                let stagedOutput = GitDiffTracker.runGit(args: ["diff", "--cached", "--", file], in: directory)
                if !stagedOutput.isEmpty {
                    output = stagedOutput
                    parsed = Self.parseUnifiedDiff(stagedOutput)
                    effectiveMode = .staged
                }
            }

            DispatchQueue.main.async {
                self?.rawDiff = output
                self?.hunks = parsed.hunks
                self?.additions = parsed.additions
                self?.deletions = parsed.deletions
                self?.diffMode = effectiveMode
                self?.isLoading = false
                Log.info("Loaded diff: \(file) (\(parsed.hunks.count) hunks, +\(parsed.additions)/-\(parsed.deletions))")
            }
        }
    }

    func refresh() {
        guard let path = filePath, let dir = directory else { return }
        loadDiff(file: path, in: dir, mode: diffMode)
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
        scanner.scanString("@@")
        scanner.scanString("-")
        let oStart = scanner.scanInt() ?? 0
        var oCount = 1
        if scanner.scanString(",") != nil {
            oCount = scanner.scanInt() ?? 1
        }
        scanner.scanString("+")
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
final class SplitPaneController: ObservableObject {
    @Published var root: SplitNode
    @Published var focusedPaneID: UUID

    private weak var appModel: AppModel?

    /// The owning tab's UUID, propagated to new terminal sessions so events
    /// carry a deterministic tabID for the TabResolver fast-path.
    var ownerTabID: UUID?

    /// Send a command to the first terminal session in this split tree (for markdown runbooks).
    func sendCommandToTerminal(_ command: String) {
        func findSession(_ node: SplitNode) -> TerminalSessionModel? {
            switch node {
            case .terminal(_, let session): return session
            case .textEditor, .filePreview, .diffViewer: return nil
            case .split(_, _, let first, let second, _):
                return findSession(first) ?? findSession(second)
            }
        }
        findSession(root)?.sendInput(command)
    }

    /// F03: Callback for terminal Cmd+Click on file paths - opens in internal editor
    lazy var onFilePathClicked: (String, Int?, Int?) -> Void = { [weak self] path, line, _ in
        self?.openFileInEditor(path: path, line: line)
    }

    init(appModel: AppModel) {
        self.appModel = appModel
        let session = TerminalSessionModel(appModel: appModel)
        let id = UUID()
        self.root = .terminal(id: id, session: session)
        self.focusedPaneID = id
    }

    /// Initialize with an existing terminal session
    init(appModel: AppModel, session: TerminalSessionModel) {
        self.appModel = appModel
        let id = UUID()
        self.root = .terminal(id: id, session: session)
        self.focusedPaneID = id
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
        newSession.ownerTabID = ownerTabID
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

    private func splitNode(_ node: SplitNode, targetID: UUID, direction: SplitDirection, newNode: SplitNode) -> SplitNode {
        switch node {
        case .terminal(let id, _),
             .textEditor(let id, _),
             .filePreview(let id, _),
             .diffViewer(let id, _):
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
             .diffViewer(let id, _):
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
            case .textEditor, .filePreview, .diffViewer:
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
        case .terminal, .textEditor, .filePreview, .diffViewer:
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
        case .terminal, .textEditor, .filePreview, .diffViewer:
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
