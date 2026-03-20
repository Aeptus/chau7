import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Split Pane View

struct SplitPaneView: View {
    @ObservedObject var controller: SplitPaneController
    let isSuspended: Bool
    let isActive: Bool

    var body: some View {
        SplitNodeView(
            node: controller.root,
            focusedID: controller.focusedPaneID,
            isSuspended: isSuspended,
            isActive: isActive,
            onFocus: { id in
                controller.focusedPaneID = id
            },
            onUpdateRatio: { splitID, newRatio in
                controller.updateRatio(splitID: splitID, newRatio: newRatio)
            },
            onClosePane: { id in
                controller.closePane(id: id)
            },
            onFilePathClicked: controller.onFilePathClicked,
            onRunCommand: { [weak controller] command in
                controller?.sendCommandToTerminal(command)
            }
        )
    }
}

struct SplitNodeView: View {
    let node: SplitNode
    let focusedID: UUID
    let isSuspended: Bool
    let isActive: Bool
    let onFocus: (UUID) -> Void
    let onUpdateRatio: (UUID, CGFloat) -> Void
    let onClosePane: (UUID) -> Void
    var onFilePathClicked: ((String, Int?, Int?) -> Void)? // F03: Internal editor callback
    var onRunCommand: ((String) -> Void)? // Markdown runbook: send command to terminal

    var body: some View {
        switch node {
        case .terminal(let id, let session):
            TerminalPaneView(
                id: id,
                session: session,
                isSuspended: isSuspended,
                isActive: isActive,
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

        case .split(let splitID, let direction, let first, let second, let ratio):
            SplitContainerView(
                splitID: splitID,
                direction: direction,
                first: first,
                second: second,
                modelRatio: ratio,
                focusedID: focusedID,
                isSuspended: isSuspended,
                isActive: isActive,
                onFocus: onFocus,
                onUpdateRatio: onUpdateRatio,
                onClosePane: onClosePane,
                onFilePathClicked: onFilePathClicked
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
    let isSuspended: Bool
    let isActive: Bool
    let onFocus: (UUID) -> Void
    let onUpdateRatio: (UUID, CGFloat) -> Void
    let onClosePane: (UUID) -> Void
    var onFilePathClicked: ((String, Int?, Int?) -> Void)? // F03: Internal editor callback
    var onRunCommand: ((String) -> Void)? // Markdown runbook

    @State private var liveRatio: CGFloat = 0.5

    var body: some View {
        GeometryReader { geometry in
            let totalSize = direction == .horizontal ? geometry.size.width : geometry.size.height
            let dividerSize: CGFloat = 5
            let effectiveRatio = liveRatio

            if direction == .horizontal {
                HStack(spacing: 0) {
                    SplitNodeView(
                        node: first,
                        focusedID: focusedID,
                        isSuspended: isSuspended,
                        isActive: isActive,
                        onFocus: onFocus,
                        onUpdateRatio: onUpdateRatio,
                        onClosePane: onClosePane,
                        onFilePathClicked: onFilePathClicked,
                        onRunCommand: onRunCommand
                    )
                    .frame(width: (totalSize - dividerSize) * effectiveRatio)
                    SplitDivider(
                        isVertical: true,
                        liveRatio: $liveRatio,
                        baseRatio: modelRatio,
                        totalSize: totalSize,
                        onDragEnd: { newRatio in
                            onUpdateRatio(splitID, newRatio)
                        }
                    )
                    SplitNodeView(
                        node: second,
                        focusedID: focusedID,
                        isSuspended: isSuspended,
                        isActive: isActive,
                        onFocus: onFocus,
                        onUpdateRatio: onUpdateRatio,
                        onClosePane: onClosePane,
                        onFilePathClicked: onFilePathClicked,
                        onRunCommand: onRunCommand
                    )
                }
            } else {
                VStack(spacing: 0) {
                    SplitNodeView(
                        node: first,
                        focusedID: focusedID,
                        isSuspended: isSuspended,
                        isActive: isActive,
                        onFocus: onFocus,
                        onUpdateRatio: onUpdateRatio,
                        onClosePane: onClosePane,
                        onFilePathClicked: onFilePathClicked,
                        onRunCommand: onRunCommand
                    )
                    .frame(height: (totalSize - dividerSize) * effectiveRatio)
                    SplitDivider(
                        isVertical: false,
                        liveRatio: $liveRatio,
                        baseRatio: modelRatio,
                        totalSize: totalSize,
                        onDragEnd: { newRatio in
                            onUpdateRatio(splitID, newRatio)
                        }
                    )
                    SplitNodeView(
                        node: second,
                        focusedID: focusedID,
                        isSuspended: isSuspended,
                        isActive: isActive,
                        onFocus: onFocus,
                        onUpdateRatio: onUpdateRatio,
                        onClosePane: onClosePane,
                        onFilePathClicked: onFilePathClicked,
                        onRunCommand: onRunCommand
                    )
                }
            }
        }
        .onAppear {
            liveRatio = modelRatio
        }
        .onChange(of: modelRatio) { newRatio in
            liveRatio = newRatio
        }
    }
}

// MARK: - Terminal Pane View

struct TerminalPaneView: View {
    let id: UUID
    let session: TerminalSessionModel
    let isSuspended: Bool
    let isActive: Bool
    let onFocus: () -> Void
    var onFilePathClicked: ((String, Int?, Int?) -> Void)? // F03: Internal editor callback

    var body: some View {
        TerminalViewRepresentable(model: session, isSuspended: isSuspended, isActive: isActive, onFilePathClicked: onFilePathClicked)
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
    @ObservedObject var editor: TextEditorModel
    let onFocus: () -> Void
    let onClose: () -> Void
    /// Callback to run a command in the terminal (for markdown runbooks)
    var onRunCommand: ((String) -> Void)?

    @State private var showFilePicker = false
    @State private var isMarkdownMode = false

    private var isMarkdownFile: Bool {
        editor.filePath?.hasSuffix(".md") == true
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
                .help(L("Open File", "Open File"))

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
                    .help(isMarkdownMode ? "Show Source" : "Show Runbook")

                    if isMarkdownMode, onRunCommand != nil {
                        Button {
                            let blocks = parseMarkdown(editor.content)
                                .compactMap { s -> String? in
                                    if case .codeBlock(_, let code) = s.kind { return code }
                                    return nil
                                }
                            // Stagger block execution so the shell processes each sequentially
                            for (i, block) in blocks.enumerated() {
                                DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.5) { [onRunCommand] in
                                    onRunCommand?(block + "\n")
                                }
                            }
                        } label: {
                            Label("Run All", systemImage: "play.fill")
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
            } else if isMarkdownFile && isMarkdownMode {
                MarkdownRunbookView(
                    content: editor.content,
                    fileName: editor.fileName,
                    onRunBlock: { code in onRunCommand?(code + "\n") },
                    onRunAll: { [onRunCommand] in
                        let blocks = parseMarkdown(editor.content)
                            .compactMap { section -> String? in
                                if case .codeBlock(_, let code) = section.kind { return code }
                                return nil
                            }
                        for (i, block) in blocks.enumerated() {
                            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.5) {
                                onRunCommand?(block + "\n")
                            }
                        }
                    }
                )
            } else {
                TextEditorContent(
                    text: Binding(
                        get: { editor.content },
                        set: { editor.updateContent($0) }
                    ),
                    editor: editor
                )
                .font(.system(size: 12, design: .monospaced))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            onFocus()
        }
        .onChange(of: editor.filePath) { newPath in
            isMarkdownMode = newPath?.hasSuffix(".md") == true
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

// MARK: - Text Editor Content (NSTextView wrapper for better performance)

struct TextEditorContent: NSViewRepresentable {
    @Binding var text: String
    @ObservedObject var editor: TextEditorModel

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

        // F03: Handle scroll-to-line request
        // Note: scrollToLine is set only after content loads (see TextEditorModel.loadFile)
        if let line = editor.scrollToLine {
            scrollToLine(line, in: textView)
            // Clear synchronously to prevent re-triggering
            // This is safe because we're already on main thread in updateNSView
            editor.scrollToLine = nil
        }
    }

    /// Scrolls the text view to show the specified line number (1-based)
    private func scrollToLine(_ lineNumber: Int, in textView: NSTextView) {
        let text = textView.string as NSString
        var currentLine = 1
        var lineStart = 0

        // Find the character index at the start of the target line
        for i in 0 ..< text.length {
            if currentLine == lineNumber {
                lineStart = i
                break
            }
            if text.character(at: i) == 0x0A { // newline
                currentLine += 1
            }
        }

        // If we didn't find the line, scroll to end
        if currentLine < lineNumber {
            lineStart = text.length
        }

        // Create a range at the line start and scroll to it
        let range = NSRange(location: lineStart, length: 0)
        textView.scrollRangeToVisible(range)
        textView.setSelectedRange(range)
        Log.info("Scrolled editor to line \(lineNumber)")
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        // Clear the undo stack to prevent use-after-free when the NSTextView
        // is deallocated but NSUndoManager still holds references to it.
        if let textView = scrollView.documentView as? NSTextView {
            textView.undoManager?.removeAllActions()
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
