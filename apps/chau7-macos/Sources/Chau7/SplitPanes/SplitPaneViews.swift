import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Chau7Core

// MARK: - Split Pane View

struct SplitPaneView: View {
    var controller: SplitPaneController
    let renderPhase: TabRenderPhase
    let isInteractive: Bool

    var body: some View {
        SplitNodeView(
            node: controller.root,
            focusedID: controller.focusedPaneID,
            renderPhase: renderPhase,
            isInteractive: isInteractive
        )
        .environment(\.paneEnvironment, PaneEnvironment(
            onFocus: { id in controller.setFocusedPane(id) },
            onUpdateRatio: { splitID, newRatio in
                controller.updateRatio(splitID: splitID, newRatio: newRatio)
            },
            onClosePane: { id in controller.closePane(id: id) },
            onFilePathClicked: controller.onFilePathClicked,
            onRunCommand: { [weak controller] command, lineNumber, editor in
                controller?.sendCommandToTerminal(command, sourceEditor: editor, sourceLineNumber: lineNumber)
            }
        ))
    }
}

struct SplitNodeView: View {
    let node: SplitNode
    let focusedID: UUID
    let renderPhase: TabRenderPhase
    let isInteractive: Bool

    @Environment(\.paneEnvironment) private var env

    var body: some View {
        switch node {
        case .leaf(let pane):
            leafView(for: pane)

        case .split(let splitID, let direction, let first, let second, let ratio):
            SplitContainerView(
                splitID: splitID,
                direction: direction,
                first: first,
                second: second,
                modelRatio: ratio,
                focusedID: focusedID,
                renderPhase: renderPhase,
                isInteractive: isInteractive
            )
        }
    }

    /// Dispatches on the concrete pane type. Adding a new pane kind means
    /// adding one case here and one PaneNode conformer — the traversal
    /// helpers stay untouched.
    @ViewBuilder
    private func leafView(for pane: any PaneNode) -> some View {
        switch pane {
        case let p as TerminalPane:
            TerminalPaneView(
                id: p.id,
                session: p.session,
                renderPhase: renderPhase,
                isInteractive: isInteractive,
                onFocus: { env?.onFocus(p.id) },
                onFilePathClicked: env?.onFilePathClicked
            )

        case let p as TextEditorPane:
            TextEditorPaneView(
                id: p.id,
                editor: p.editor,
                onFocus: { env?.onFocus(p.id) },
                onClose: { env?.onClosePane(p.id) },
                onRunCommand: env?.onRunCommand
            )

        case let p as FilePreviewPane:
            FilePreviewPaneView(
                id: p.id,
                preview: p.preview,
                onFocus: { env?.onFocus(p.id) },
                onClose: { env?.onClosePane(p.id) }
            )

        case let p as DiffViewerPane:
            DiffViewerPaneView(
                id: p.id,
                diff: p.diff,
                onFocus: { env?.onFocus(p.id) },
                onClose: { env?.onClosePane(p.id) }
            )

        case let p as RepositoryPane:
            RepositoryPaneView(
                id: p.id,
                repo: p.repo,
                onFocus: { env?.onFocus(p.id) },
                onClose: { env?.onClosePane(p.id) },
                onFileClicked: { path, dir in
                    let absolutePath = URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: dir)).path
                    env?.onFilePathClicked?(absolutePath, nil, nil)
                }
            )

        case let p as DashboardPane:
            AgentDashboardView(model: p.dashboard) { path in
                env?.onFilePathClicked?(path, nil, nil)
            }

        default:
            EmptyView()
        }
    }
}

/// Separate view for split container to hold @State for smooth dragging.
/// Reads `onUpdateRatio` from `@Environment(\.paneEnvironment)` instead of
/// taking it as an init parameter.
struct SplitContainerView: View {
    let splitID: UUID
    let direction: SplitDirection
    let first: SplitNode
    let second: SplitNode
    let modelRatio: CGFloat
    let focusedID: UUID
    let renderPhase: TabRenderPhase
    let isInteractive: Bool

    @Environment(\.paneEnvironment) private var env
    @State private var liveRatio: CGFloat = 0.5

    var body: some View {
        GeometryReader { geometry in
            let totalSize = direction == .horizontal ? geometry.size.width : geometry.size.height
            let dividerSize: CGFloat = 5
            let effectiveRatio = liveRatio
            let primaryDim = (totalSize - dividerSize) * effectiveRatio
            let divider = SplitDivider(
                isVertical: direction == .horizontal,
                liveRatio: $liveRatio,
                baseRatio: modelRatio,
                totalSize: totalSize,
                onDragEnd: { newRatio in
                    env?.onUpdateRatio(splitID, newRatio)
                }
            )

            if direction == .horizontal {
                HStack(spacing: 0) {
                    nodeView(for: first).frame(width: primaryDim)
                    divider
                    nodeView(for: second)
                }
            } else {
                VStack(spacing: 0) {
                    nodeView(for: first).frame(height: primaryDim)
                    divider
                    nodeView(for: second)
                }
            }
        }
        .onAppear {
            liveRatio = modelRatio
        }
        .onChange(of: modelRatio) {
            liveRatio = modelRatio
        }
    }

    private func nodeView(for node: SplitNode) -> SplitNodeView {
        SplitNodeView(
            node: node,
            focusedID: focusedID,
            renderPhase: renderPhase,
            isInteractive: isInteractive
        )
    }
}

// MARK: - Terminal Pane View

struct TerminalPaneView: View {
    let id: UUID
    let session: TerminalSessionModel
    let renderPhase: TabRenderPhase
    let isInteractive: Bool
    let onFocus: () -> Void
    var onFilePathClicked: ((String, Int?, Int?) -> Void)? // F03: Internal editor callback

    var body: some View {
        TerminalViewRepresentable(model: session, renderPhase: renderPhase, isInteractive: isInteractive, onFilePathClicked: onFilePathClicked)
            // Use simultaneousGesture to allow the tap to be recognized without blocking
            // the NSView's native mouse event handling for text selection
            .simultaneousGesture(
                TapGesture()
                    .onEnded { _ in
                        onFocus()
                    }
            )
    }
}

// MARK: - Text Editor Pane View

struct TextEditorPaneView: View {
    let id: UUID
    var editor: TextEditorModel
    let onFocus: () -> Void
    let onClose: () -> Void
    /// Callback to run a command in the terminal (for markdown runbooks)
    var onRunCommand: ((String, Int?, TextEditorModel?) -> Void)?

    @State private var showFilePicker = false
    @State private var isMarkdownMode = false
    @State private var showCopiedToast = false
    @State private var editorSelectedRange = NSRange(location: 0, length: 0)
    @State private var editorConfig = EditorConfig.load()

    private var isMarkdownFile: Bool {
        guard let filePath = editor.filePath?.lowercased() else { return false }
        return filePath.hasSuffix(".md") || filePath.hasSuffix(".markdown")
    }

    private var editorLanguage: EditorLanguage {
        EditorLanguage.detect(from: editor.fileName)
    }

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
                    .onTapGesture {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(editor.fileName, forType: .string)
                        withAnimation(.easeInOut(duration: 0.15)) { showCopiedToast = true }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                            withAnimation(.easeInOut(duration: 0.3)) { showCopiedToast = false }
                        }
                    }
                    .help(L("Copy file name", "Copy file name"))

                if showCopiedToast {
                    Text(L("pane.copied", "Copied"))
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                        .transition(.opacity)
                }

                if editor.isAutoSaveEnabled, let autoSaveStatusMessage = editor.autoSaveStatusMessage {
                    Text(autoSaveStatusMessage)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                } else if editor.isDirty {
                    Circle()
                        .fill(Color.orange)
                        .frame(width: 6, height: 6)
                }

                if editor.hasExternalChangeConflict {
                    Button {
                        editor.reloadFromDisk()
                    } label: {
                        Text(L("editor.reloadPrompt", "Reload?"))
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.orange)
                    }
                    .buttonStyle(.plain)
                    .help(editor.externalConflictMessage ?? L("editor.externalChangeConflict", "File changed externally. Reload?"))
                }

                if isMarkdownFile, editor.planProgress.total > 0 {
                    Text("\(editor.planProgress.checked)/\(editor.planProgress.total)")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .help(L("editor.planProgress", "Completed tasks"))
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
                .help(L("Open File", "Open File"))

                // Save button
                Button {
                    if editor.filePath != nil {
                        editor.save()
                    } else if !editor.saveUntitledIfPossible() {
                        saveAs()
                    }
                } label: {
                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .disabled(!editor.isDirty && editor.filePath != nil)
                .help(L("Save", "Save"))

                // Markdown toggle (only shown for .md files)
                if isMarkdownFile {
                    Button {
                        isMarkdownMode.toggle()
                    } label: {
                        Image(systemName: isMarkdownMode ? "doc.plaintext" : "doc.richtext")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .help(isMarkdownMode ? L("pane.showSource", "Show Source") : L("pane.showRunbook", "Show Runbook"))

                    if isMarkdownMode, onRunCommand != nil {
                        Button {
                            runAllMarkdownBlocks()
                        } label: {
                            Label(L("pane.runAll", "Run All"), systemImage: "play.fill")
                                .font(.system(size: 10))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                    }
                }

                // Close button — actual save/discard prompt lives on the
                // controller so this and ⌃⌘W share one decision path.
                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.plain)
                .help(L("Close Pane", "Close Pane"))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            // Editor content — markdown runbook or raw text
            if editor.isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if isMarkdownFile, isMarkdownMode {
                MarkdownRunbookView(
                    content: editor.content,
                    fileName: editor.fileName,
                    host: RunbookHostAdapter(
                        editor: editor,
                        sendCommand: { command, lineNumber in
                            onRunCommand?(command, lineNumber, editor)
                        }
                    )
                )
            } else {
                EnhancedEditorView(
                    text: Binding(
                        get: { editor.content },
                        set: { editor.updateContent($0) }
                    ),
                    selectedRange: $editorSelectedRange,
                    language: editorLanguage,
                    config: editorConfig,
                    onSave: { _ = editor.save() },
                    scrollToLine: editor.scrollToLine,
                    onScrollHandled: { editor.scrollToLine = nil }
                )
            }
        }
        .contentShape(Rectangle())
        .onAppear {
            isMarkdownMode = isMarkdownFile
        }
        .onTapGesture {
            onFocus()
        }
        .onChange(of: editor.filePath) {
            isMarkdownMode = isMarkdownFile
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
        panel.nameFieldStringValue = L("editor.defaultFilename", "untitled.txt")

        if panel.runModal() == .OK, let url = panel.url {
            editor.saveAs(to: url.path)
        }
    }

    /// Send every fenced code block to the terminal one at a time, waiting
    /// for each to settle before sending the next. The previous behaviour
    /// fired all blocks with a fixed 0.5s stagger, which paste-bombed the
    /// shell when an early block took longer than 0.5s — interleaving
    /// commands and leading to out-of-order execution.
    private func runAllMarkdownBlocks() {
        guard let send = onRunCommand else { return }
        let blocks = parseMarkdown(editor.content).compactMap { section -> (line: Int, code: String)? in
            if case .codeBlock(_, let code, let lineNumber) = section.kind {
                return (line: lineNumber, code: code)
            }
            return nil
        }
        editor.runMarkdownBlocksSequentially(blocks) { [editor] command, lineNumber in
            send(command, lineNumber, editor)
        }
    }
}

// MARK: - Split Divider

struct SplitDivider: View {
    let isVertical: Bool
    @Binding var liveRatio: CGFloat
    let baseRatio: CGFloat
    let totalSize: CGFloat
    let onDragEnd: (CGFloat) -> Void

    @State private var isDragging = false
    @State private var dragStartRatio: CGFloat = 0.5

    var body: some View {
        Rectangle()
            .fill(isDragging ? Color.accentColor : Color(nsColor: .separatorColor))
            .frame(width: isVertical ? 5 : nil, height: isVertical ? nil : 5)
            .contentShape(Rectangle())
            .onHover { hovering in
                if hovering {
                    if isVertical {
                        NSCursor.resizeLeftRight.push()
                    } else {
                        NSCursor.resizeUpDown.push()
                    }
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        if !isDragging {
                            isDragging = true
                            dragStartRatio = baseRatio
                        }
                        let delta = isVertical ? value.translation.width : value.translation.height
                        let deltaRatio = delta / totalSize
                        liveRatio = max(0.1, min(0.9, dragStartRatio + deltaRatio))
                    }
                    .onEnded { _ in
                        isDragging = false
                        onDragEnd(liveRatio)
                    }
            )
    }
}
