import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - File Preview Pane View

/// Read-only file preview with syntax highlighting for text and native rendering for images.
struct FilePreviewPaneView: View {
    let id: UUID
    @ObservedObject var preview: FilePreviewModel
    let onFocus: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Header bar
            HStack(spacing: 8) {
                Image(systemName: "eye")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                if let path = preview.filePath {
                    Image(nsImage: {
                        if let contentType = UTType(filenameExtension: (path as NSString).pathExtension) {
                            return NSWorkspace.shared.icon(for: contentType)
                        }
                        return NSWorkspace.shared.icon(for: .data)
                    }())
                        .resizable()
                        .frame(width: 14, height: 14)
                }

                Text(preview.fileName)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)

                if preview.isImageFile {
                    Text("IMAGE")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.15))
                        .cornerRadius(3)
                }

                Spacer()

                Button { onClose() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(L("splitPane.preview.close", "Close Preview"))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            // Content
            if preview.isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = preview.lastError {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if preview.isImageFile, let data = preview.imageData {
                ImagePreviewContent(data: data)
            } else if preview.filePath == nil {
                VStack(spacing: 8) {
                    Image(systemName: "doc")
                        .font(.title)
                        .foregroundStyle(.secondary)
                    Text(L("splitPane.preview.noFile", "No file selected"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ReadOnlyEditorContent(
                    text: preview.content,
                    filePath: preview.filePath,
                    scrollToLine: preview.scrollToLine
                )
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { onFocus() }
    }
}

// MARK: - Image Preview

/// Displays image data with aspect-fit scaling and a checkerboard background for transparency.
private struct ImagePreviewContent: View {
    let data: Data

    var body: some View {
        if let nsImage = NSImage(data: data) {
            ScrollView([.horizontal, .vertical]) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(16)
            }
            .background(checkerboardBackground)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "photo.badge.exclamationmark")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text(L("splitPane.preview.imageError", "Unable to decode image"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var checkerboardBackground: some View {
        Canvas { context, size in
            let tileSize: CGFloat = 10
            let light = Color(nsColor: NSColor.controlBackgroundColor)
            let dark = Color(nsColor: NSColor.controlBackgroundColor.withAlphaComponent(0.85))
            for row in 0 ..< Int(size.height / tileSize) + 1 {
                for col in 0 ..< Int(size.width / tileSize) + 1 {
                    let isLight = (row + col).isMultiple(of: 2)
                    let rect = CGRect(x: CGFloat(col) * tileSize, y: CGFloat(row) * tileSize, width: tileSize, height: tileSize)
                    context.fill(Path(rect), with: .color(isLight ? light : dark))
                }
            }
        }
    }
}

// MARK: - Read-Only Editor

/// Read-only text view with syntax highlighting, wrapping EnhancedEditorView in non-editable mode.
struct ReadOnlyEditorContent: NSViewRepresentable {
    let text: String
    let filePath: String?
    let scrollToLine: Int?

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.usesFindBar = true
        textView.font = NSFont.monospacedSystemFont(ofSize: CGFloat(FeatureSettings.shared.fontSize), weight: .regular)
        textView.textColor = NSColor.textColor
        textView.backgroundColor = NSColor.textBackgroundColor
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true

        context.coordinator.textView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = context.coordinator.textView else { return }
        if textView.string != text {
            textView.string = text
            applySyntaxHighlighting(textView)
        }
        if let line = scrollToLine, line > 0 {
            scrollToLine(textView, line: line)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator {
        weak var textView: NSTextView?
    }

    private func applySyntaxHighlighting(_ textView: NSTextView) {
        let highlighted = SyntaxHighlighter.shared.highlight(textView.string)
        textView.textStorage?.setAttributedString(highlighted)
        // Re-apply monospaced font (highlighter uses its own base font)
        let monoFont = NSFont.monospacedSystemFont(ofSize: CGFloat(FeatureSettings.shared.fontSize), weight: .regular)
        let fullRange = NSRange(location: 0, length: textView.string.utf16.count)
        textView.textStorage?.addAttribute(.font, value: monoFont, range: fullRange)
    }

    private func scrollToLine(_ textView: NSTextView, line: Int) {
        let text = textView.string
        var lineCount = 1
        var idx = text.startIndex
        while idx < text.endIndex, lineCount < line {
            if text[idx] == "\n" { lineCount += 1 }
            idx = text.index(after: idx)
        }
        let charIndex = text.distance(from: text.startIndex, to: idx)
        let range = NSRange(location: charIndex, length: 0)
        textView.scrollRangeToVisible(range)
    }
}
