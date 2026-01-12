import SwiftUI
import AppKit
import UniformTypeIdentifiers

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
            },
            onUpdateRatio: { splitID, newRatio in
                controller.updateRatio(splitID: splitID, newRatio: newRatio)
            }
        )
    }
}

struct SplitNodeView: View {
    let node: SplitNode
    let focusedID: UUID
    let isSuspended: Bool
    let onFocus: (UUID) -> Void
    let onUpdateRatio: (UUID, CGFloat) -> Void

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

        case .split(let splitID, let direction, let first, let second, let ratio):
            SplitContainerView(
                splitID: splitID,
                direction: direction,
                first: first,
                second: second,
                modelRatio: ratio,
                focusedID: focusedID,
                isSuspended: isSuspended,
                onFocus: onFocus,
                onUpdateRatio: onUpdateRatio
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
    let onFocus: (UUID) -> Void
    let onUpdateRatio: (UUID, CGFloat) -> Void

    @State private var liveRatio: CGFloat = 0.5

    var body: some View {
        GeometryReader { geometry in
            let totalSize = direction == .horizontal ? geometry.size.width : geometry.size.height
            let dividerSize: CGFloat = 5
            let effectiveRatio = liveRatio

            if direction == .horizontal {
                HStack(spacing: 0) {
                    SplitNodeView(node: first, focusedID: focusedID, isSuspended: isSuspended, onFocus: onFocus, onUpdateRatio: onUpdateRatio)
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
                    SplitNodeView(node: second, focusedID: focusedID, isSuspended: isSuspended, onFocus: onFocus, onUpdateRatio: onUpdateRatio)
                }
            } else {
                VStack(spacing: 0) {
                    SplitNodeView(node: first, focusedID: focusedID, isSuspended: isSuspended, onFocus: onFocus, onUpdateRatio: onUpdateRatio)
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
                    SplitNodeView(node: second, focusedID: focusedID, isSuspended: isSuspended, onFocus: onFocus, onUpdateRatio: onUpdateRatio)
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
