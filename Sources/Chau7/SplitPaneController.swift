import SwiftUI
import AppKit

// MARK: - F02: Native Split Panes with Text Editor Support

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
    func loadFile(at path: String) {
        // Create a unique token for this load operation
        let token = UUID()
        loadingToken = token
        isLoading = true
        lastError = nil

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
                    Log.info("Loaded file: \(path)")
                }
            } catch {
                DispatchQueue.main.async {
                    guard self?.loadingToken == token else { return }
                    self?.isLoading = false
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
    func splitWithTextEditor(direction: SplitDirection, filePath: String? = nil) {
        guard FeatureSettings.shared.isSplitPanesEnabled else { return }

        let editor = TextEditorModel()
        if let path = filePath {
            editor.loadFile(at: path)
        }
        let newID = UUID()
        let newNode = SplitNode.textEditor(id: newID, editor: editor)

        root = splitNode(root, targetID: focusedPaneID, direction: direction, newNode: newNode)
        focusedPaneID = newID
    }

    /// Opens a file in the existing text editor, or creates a new split if none exists
    func openFileInEditor(path: String) {
        if let editor = root.findFirstEditor() {
            editor.loadFile(at: path)
        } else {
            splitWithTextEditor(direction: .horizontal, filePath: path)
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
        // Don't close if it's the only pane
        guard root.allPaneIDs.count > 1 else { return }

        let result = removeNode(root, targetID: focusedPaneID)
        if let newRoot = result.node {
            root = newRoot
            // Focus the sibling or first available
            if let newFocus = result.siblingID ?? root.allPaneIDs.first {
                focusedPaneID = newFocus
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

// MARK: - Split Pane View

struct SplitPaneView: View {
    @ObservedObject var controller: SplitPaneController
    let isSuspended: Bool

    var body: some View {
        SplitNodeView(
            node: controller.root,
            focusedID: controller.focusedPaneID,
            isSuspended: isSuspended,
            onFocus: { id in
                controller.focusedPaneID = id
            }
        )
    }
}

struct SplitNodeView: View {
    let node: SplitNode
    let focusedID: UUID
    let isSuspended: Bool
    let onFocus: (UUID) -> Void

    var body: some View {
        switch node {
        case .terminal(let id, let session):
            TerminalPaneView(
                id: id,
                session: session,
                isSuspended: isSuspended,
                onFocus: { onFocus(id) }
            )

        case .textEditor(let id, let editor):
            TextEditorPaneView(
                id: id,
                editor: editor,
                onFocus: { onFocus(id) }
            )

        case .split(_, let direction, let first, let second, let ratio):
            GeometryReader { geometry in
                if direction == .horizontal {
                    HStack(spacing: 1) {
                        SplitNodeView(node: first, focusedID: focusedID, isSuspended: isSuspended, onFocus: onFocus)
                            .frame(width: geometry.size.width * ratio - 0.5)
                        SplitDivider(isVertical: true)
                        SplitNodeView(node: second, focusedID: focusedID, isSuspended: isSuspended, onFocus: onFocus)
                    }
                } else {
                    VStack(spacing: 1) {
                        SplitNodeView(node: first, focusedID: focusedID, isSuspended: isSuspended, onFocus: onFocus)
                            .frame(height: geometry.size.height * ratio - 0.5)
                        SplitDivider(isVertical: false)
                        SplitNodeView(node: second, focusedID: focusedID, isSuspended: isSuspended, onFocus: onFocus)
                    }
                }
            }
        }
    }
}

// MARK: - Terminal Pane View

struct TerminalPaneView: View {
    let id: UUID
    let session: TerminalSessionModel
    let isSuspended: Bool
    let onFocus: () -> Void

    var body: some View {
        TerminalViewRepresentable(model: session, isSuspended: isSuspended)
            .contentShape(Rectangle())
            .onTapGesture {
                onFocus()
            }
    }
}

// MARK: - Text Editor Pane View

struct TextEditorPaneView: View {
    let id: UUID
    @ObservedObject var editor: TextEditorModel
    let onFocus: () -> Void

    @State private var showFilePicker = false

    var body: some View {
        VStack(spacing: 0) {
            // Header bar
            HStack(spacing: 8) {
                Image(systemName: "doc.text")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                Text(editor.fileName)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)

                if editor.isDirty {
                    Circle()
                        .fill(Color.orange)
                        .frame(width: 6, height: 6)
                }

                Spacer()

                // Open file button
                Button {
                    showFilePicker = true
                } label: {
                    Image(systemName: "folder")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .help("Open File")

                // Save button
                Button {
                    if editor.filePath != nil {
                        editor.save()
                    } else {
                        saveAs()
                    }
                } label: {
                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .disabled(!editor.isDirty && editor.filePath != nil)
                .help("Save")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            // Editor content
            if editor.isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                TextEditorContent(text: Binding(
                    get: { editor.content },
                    set: { editor.updateContent($0) }
                ))
                .font(.system(size: 12, design: .monospaced))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            onFocus()
        }
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: [.plainText, .sourceCode, .text],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    _ = url.startAccessingSecurityScopedResource()
                    editor.loadFile(at: url.path)
                    url.stopAccessingSecurityScopedResource()
                }
            case .failure(let error):
                Log.error("File picker error: \(error.localizedDescription)")
            }
        }
    }

    private func saveAs() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "untitled.txt"

        if panel.runModal() == .OK, let url = panel.url {
            editor.saveAs(to: url.path)
        }
    }
}

// MARK: - Text Editor Content (NSTextView wrapper for better performance)

struct TextEditorContent: NSViewRepresentable {
    @Binding var text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? NSTextView else {
            Log.error("TextEditorContent: documentView is not NSTextView")
            return scrollView
        }

        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.backgroundColor = NSColor.textBackgroundColor
        textView.textColor = NSColor.textColor
        textView.delegate = context.coordinator
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if textView.string != text {
            // Preserve selection and scroll position
            let selectedRanges = textView.selectedRanges
            let visibleRect = textView.visibleRect
            textView.string = text
            textView.selectedRanges = selectedRanges
            textView.scrollToVisible(visibleRect)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: TextEditorContent

        init(_ parent: TextEditorContent) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }
    }
}

// MARK: - Split Divider

struct SplitDivider: View {
    let isVertical: Bool

    var body: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: isVertical ? 1 : nil, height: isVertical ? nil : 1)
    }
}
