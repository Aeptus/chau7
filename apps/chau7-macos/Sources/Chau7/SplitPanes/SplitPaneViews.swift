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
            isInteractive: isInteractive,
            onFocus: { id in
                controller.setFocusedPane(id)
            },
            onUpdateRatio: { splitID, newRatio in
                controller.updateRatio(splitID: splitID, newRatio: newRatio)
            },
            onClosePane: { id in
                controller.closePane(id: id)
            },
            onFilePathClicked: controller.onFilePathClicked,
            onRunCommand: { [weak controller] command, lineNumber, editor in
                controller?.sendCommandToTerminal(command, sourceEditor: editor, sourceLineNumber: lineNumber)
            }
        )
    }
}

struct SplitNodeView: View {
    let node: SplitNode
    let focusedID: UUID
    let renderPhase: TabRenderPhase
    let isInteractive: Bool
    let onFocus: (UUID) -> Void
    let onUpdateRatio: (UUID, CGFloat) -> Void
    let onClosePane: (UUID) -> Void
    var onFilePathClicked: ((String, Int?, Int?) -> Void)? // F03: Internal editor callback
    var onRunCommand: ((String, Int?, TextEditorModel?) -> Void)? // Markdown runbook: send command to terminal

    var body: some View {
        switch node {
        case .terminal(let id, let session):
            TerminalPaneView(
                id: id,
                session: session,
                renderPhase: renderPhase,
                isInteractive: isInteractive,
                onFocus: { onFocus(id) },
                onFilePathClicked: onFilePathClicked
            )

        case .textEditor(let id, let editor):
            TextEditorPaneView(
                id: id,
                editor: editor,
                onFocus: { onFocus(id) },
                onClose: { onClosePane(id) },
                onRunCommand: onRunCommand
            )

        case .filePreview(let id, let preview):
            FilePreviewPaneView(
                id: id,
                preview: preview,
                onFocus: { onFocus(id) },
                onClose: { onClosePane(id) }
            )

        case .diffViewer(let id, let diff):
            DiffViewerPaneView(
                id: id,
                diff: diff,
                onFocus: { onFocus(id) },
                onClose: { onClosePane(id) }
            )

        case .repositoryPane(let id, let repo):
            RepositoryPaneView(
                id: id,
                repo: repo,
                onFocus: { onFocus(id) },
                onClose: { onClosePane(id) },
                onFileClicked: { path, dir in
                    let absolutePath = URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: dir)).path
                    onFilePathClicked?(absolutePath, nil, nil)
                }
            )

        case .dashboard(_, let dashboard):
            AgentDashboardView(model: dashboard) { path in
                onFilePathClicked?(path, nil, nil)
            }

        case .split(let splitID, let direction, let first, let second, let ratio):
            SplitContainerView(
                splitID: splitID,
                direction: direction,
                first: first,
                second: second,
                modelRatio: ratio,
                focusedID: focusedID,
                renderPhase: renderPhase,
                isInteractive: isInteractive,
                onFocus: onFocus,
                onUpdateRatio: onUpdateRatio,
                onClosePane: onClosePane,
                onFilePathClicked: onFilePathClicked,
                onRunCommand: onRunCommand
            )
        }
    }
}

/// Separate view for split container to hold @State for smooth dragging
struct SplitContainerView: View {
    let splitID: UUID
    let direction: SplitDirection
    let first: SplitNode
    let second: SplitNode
    let modelRatio: CGFloat
    let focusedID: UUID
    let renderPhase: TabRenderPhase
    let isInteractive: Bool
    let onFocus: (UUID) -> Void
    let onUpdateRatio: (UUID, CGFloat) -> Void
    let onClosePane: (UUID) -> Void
    var onFilePathClicked: ((String, Int?, Int?) -> Void)? // F03: Internal editor callback
    var onRunCommand: ((String, Int?, TextEditorModel?) -> Void)? // Markdown runbook

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
                    onUpdateRatio(splitID, newRatio)
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
            isInteractive: isInteractive,
            onFocus: onFocus,
            onUpdateRatio: onUpdateRatio,
            onClosePane: onClosePane,
            onFilePathClicked: onFilePathClicked,
            onRunCommand: onRunCommand
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
                            let blocks = parseMarkdown(editor.content)
                                .compactMap { s -> (Int, String)? in
                                    if case .codeBlock(_, let code, let lineNumber) = s.kind { return (lineNumber, code) }
                                    return nil
                                }
                            // Stagger block execution so the shell processes each sequentially
                            for (i, block) in blocks.enumerated() {
                                DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.5) { [onRunCommand, editor] in
                                    onRunCommand?("\(block.1)\n", block.0, editor)
                                }
                            }
                        } label: {
                            Label(L("pane.runAll", "Run All"), systemImage: "play.fill")
                                .font(.system(size: 10))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                    }
                }

                // Close button
                Button {
                    attemptClose()
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
                    onRunBlock: { code, lineNumber in
                        onRunCommand?("\(code)\n", lineNumber, editor)
                    },
                    onRunAll: { [onRunCommand, editor] in
                        let blocks = parseMarkdown(editor.content)
                            .compactMap { section -> (Int, String)? in
                                if case .codeBlock(_, let code, let lineNumber) = section.kind { return (lineNumber, code) }
                                return nil
                            }
                        for (i, block) in blocks.enumerated() {
                            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.5) {
                                onRunCommand?("\(block.1)\n", block.0, editor)
                            }
                        }
                    },
                    codeBlockState: { code, lineNumber in
                        editor.codeBlockState(for: code, lineNumber: lineNumber)
                    },
                    onToggleCheckbox: { lineNumber in
                        editor.toggleCheckbox(lineNumber: lineNumber)
                    },
                    onContentChange: { newContent in
                        editor.updateContent(newContent)
                    }
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

    private func attemptClose() {
        // If content is dirty and not empty, prompt to save
        if editor.isDirty, !editor.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let alert = NSAlert()
            alert.messageText = L("alert.closeEditor.title", "Save changes?")
            alert.informativeText = L("alert.closeEditor.message", "Your changes will be lost if you don't save them.")
            alert.alertStyle = .warning
            alert.addButton(withTitle: L("button.save", "Save"))
            alert.addButton(withTitle: L("button.dontSave", "Don't Save"))
            alert.addButton(withTitle: L("button.cancel", "Cancel"))

            let response = alert.runModal()
            switch response {
            case .alertFirstButtonReturn:
                // Save
                if editor.filePath != nil {
                    editor.save()
                    onClose()
                } else if editor.saveUntitledIfPossible() {
                    onClose()
                } else {
                    // Need to save as first
                    let panel = NSSavePanel()
                    panel.allowedContentTypes = [.plainText]
                    panel.canCreateDirectories = true
                    panel.nameFieldStringValue = L("editor.defaultFilename", "untitled.txt")

                    if panel.runModal() == .OK, let url = panel.url {
                        if editor.saveAs(to: url.path) {
                            onClose()
                        }
                    }
                    // If save was cancelled, don't close
                }
            case .alertSecondButtonReturn:
                // Don't save - just close
                onClose()
            default:
                // Cancel - do nothing
                break
            }
        } else {
            // Content is clean or empty - close directly
            onClose()
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
