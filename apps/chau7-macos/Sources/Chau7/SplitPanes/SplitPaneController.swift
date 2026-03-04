import SwiftUI
import AppKit

// MARK: - F02: Native Split Panes with Text Editor Support

enum SavedSplitNodeKind: String, Codable {
    case terminal
    case textEditor
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

    init(
        kind: SavedSplitNodeKind,
        id: String,
        direction: SplitDirection?,
        ratio: Double?,
        first: SavedSplitNode?,
        second: SavedSplitNode?,
        textEditorPath: String?
    ) {
        self.kind = kind
        self.id = id
        self.direction = direction
        self.ratio = ratio
        self.first = first
        self.second = second
        self.textEditorPath = textEditorPath
    }

    static func == (lhs: SavedSplitNode, rhs: SavedSplitNode) -> Bool {
        lhs.kind == rhs.kind &&
            lhs.id == rhs.id &&
            lhs.direction == rhs.direction &&
            lhs.ratio == rhs.ratio &&
            lhs.textEditorPath == rhs.textEditorPath &&
            lhs.first == rhs.first &&
            lhs.second == rhs.second
    }
}

/// Direction for splitting a pane
enum SplitDirection: String, Codable {
    case horizontal  // Side by side
    case vertical    // Stacked
}

/// Type of pane content
enum PaneType: String, Codable {
    case terminal
    case textEditor
}

/// Represents a node in the split pane tree
indirect enum SplitNode: Identifiable {
    case terminal(id: UUID, session: TerminalSessionModel)
    case textEditor(id: UUID, editor: TextEditorModel)
    case split(id: UUID, direction: SplitDirection, first: SplitNode, second: SplitNode, ratio: CGFloat)

    var id: UUID {
        switch self {
        case .terminal(let id, _):
            return id
        case .textEditor(let id, _):
            return id
        case .split(let id, _, _, _, _):
            return id
        }
    }

    /// Gets all pane IDs in this subtree
    var allPaneIDs: [UUID] {
        switch self {
        case .terminal(let id, _):
            return [id]
        case .textEditor(let id, _):
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
        case .textEditor:
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
        case .textEditor:
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
        case .textEditor:
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
    /// Closes all terminal sessions in this subtree
    /// NOTE: Methods below are kept in an extension to keep SplitNode behavior
    /// in one cohesive area and to avoid moving the core tree-representation
    /// model around.
}

extension SplitNode {
    /// Closes all terminal sessions in this subtree
    func closeAllSessions() {
        switch self {
        case .terminal(_, let session):
            session.closeSession()
        case .textEditor:
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
        case .textEditor:
            return nil
        case .split(_, _, let first, let second, _):
            return first.findSession(id: id) ?? second.findSession(id: id)
        }
    }

    /// Finds a text editor model by ID
    func findEditor(id: UUID) -> TextEditorModel? {
        switch self {
        case .terminal:
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
        case .terminal:
            return nil
        case .textEditor(_, let editor):
            return editor
        case .split(_, _, let first, let second, _):
            return first.findFirstEditor() ?? second.findFirstEditor()
        }
    }

    /// Gets the pane type for a given ID
    func paneType(for id: UUID) -> PaneType? {
        switch self {
        case .terminal(let paneId, _):
            return paneId == id ? .terminal : nil
        case .textEditor(let paneId, _):
            return paneId == id ? .textEditor : nil
        case .split(_, _, let first, let second, _):
            return first.paneType(for: id) ?? second.paneType(for: id)
        }
    }

    /// Checks if tree has any text editors
    var hasTextEditor: Bool {
        switch self {
        case .terminal:
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

    @Published var content: String = ""
    @Published var filePath: String?
    @Published var isDirty: Bool = false
    @Published var isLoading: Bool = false
    @Published var lastError: String?
    @Published var scrollToLine: Int?  // F03: Line to scroll to after loading (set after content loads)

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
        pendingScrollToLine = line  // Store for after load completes

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

// MARK: - Split Pane Controller

/// Manages split pane layout for a tab
final class SplitPaneController: ObservableObject {
    @Published var root: SplitNode
    @Published var focusedPaneID: UUID

    private weak var appModel: AppModel?

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
    /// - Parameters:
    ///   - path: Absolute path to the file
    ///   - line: Optional line number to scroll to after loading
    func openFileInEditor(path: String, line: Int? = nil) {
        if let editor = root.findFirstEditor() {
            editor.loadFile(at: path, scrollToLine: line)
        } else {
            splitWithTextEditor(direction: .horizontal, filePath: path, scrollToLine: line)
        }
    }

    private func splitNode(_ node: SplitNode, targetID: UUID, direction: SplitDirection, newNode: SplitNode) -> SplitNode {
        switch node {
        case .terminal(let id, let session):
            if id == targetID {
                let oldTerminal = SplitNode.terminal(id: id, session: session)
                return .split(
                    id: UUID(),
                    direction: direction,
                    first: oldTerminal,
                    second: newNode,
                    ratio: 0.5
                )
            }
            return node

        case .textEditor(let id, let editor):
            if id == targetID {
                let oldEditor = SplitNode.textEditor(id: id, editor: editor)
                return .split(
                    id: UUID(),
                    direction: direction,
                    first: oldEditor,
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

        case .textEditor(let id, _):
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
                return (.split(id: id, direction: dir, first: newFirst, second: newSecond, ratio: ratio),
                        firstResult.siblingID ?? secondResult.siblingID)
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
            case .textEditor:
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
        case .terminal, .textEditor:
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
        case .terminal, .textEditor:
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
