import SwiftUI
import AppKit

// MARK: - Diff Viewer Pane View

/// Displays a unified git diff with colored additions/deletions, line numbers, and mode toggle.
struct DiffViewerPaneView: View {
    let id: UUID
    @Bindable var diff: DiffViewerModel
    let onFocus: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Header bar
            diffHeader

            Divider()

            // Content
            if diff.isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = diff.lastError {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if diff.hunks.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.circle")
                        .font(.title)
                        .foregroundStyle(.green)
                    Text(L("splitPane.diff.noChanges", "No changes"))
                        .font(.body)
                        .foregroundStyle(.secondary)
                    Text(diff.diffMode == .workingTree
                        ? L("splitPane.diff.noWorkingChanges", "Working tree is clean for this file")
                        : L("splitPane.diff.noStagedChanges", "No staged changes for this file"))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                UnifiedDiffContent(hunks: diff.hunks)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { onFocus() }
    }

    private var diffHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.left.arrow.right")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            Text(diff.fileName)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)

            if diff.additions > 0 || diff.deletions > 0 {
                HStack(spacing: 4) {
                    Text("+\(diff.additions)")
                        .foregroundStyle(.green)
                    Text("-\(diff.deletions)")
                        .foregroundStyle(.red)
                }
                .font(.system(size: 10, weight: .medium, design: .monospaced))
            }

            Spacer()

            // Mode toggle
            Picker("", selection: $diff.diffMode) {
                Text(L("splitPane.diff.working", "Working")).tag(DiffMode.workingTree)
                Text(L("splitPane.diff.staged", "Staged")).tag(DiffMode.staged)
            }
            .pickerStyle(.segmented)
            .frame(width: 140)
            .onChange(of: diff.diffMode) { diff.refresh() }

            Button { diff.refresh() } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(L("splitPane.diff.refresh", "Refresh Diff"))

            Button { onClose() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(L("splitPane.diff.close", "Close Diff"))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

// MARK: - Unified Diff Content

/// Renders unified diff hunks with colored lines, line numbers, and monospaced font.
struct UnifiedDiffContent: NSViewRepresentable {
    let hunks: [DiffHunk]

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.usesFindBar = true
        textView.backgroundColor = NSColor.textBackgroundColor
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
        renderDiff(into: textView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = context.coordinator.textView else { return }
        renderDiff(into: textView)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator {
        weak var textView: NSTextView?
    }

    private func renderDiff(into textView: NSTextView) {
        let attributed = NSMutableAttributedString()
        let monoFont = NSFont.monospacedSystemFont(ofSize: CGFloat(FeatureSettings.shared.fontSize), weight: .regular)
        let smallFont = NSFont.monospacedSystemFont(ofSize: CGFloat(FeatureSettings.shared.fontSize) - 1, weight: .medium)

        let defaultAttrs: [NSAttributedString.Key: Any] = [
            .font: monoFont,
            .foregroundColor: NSColor.textColor
        ]

        let additionColor = NSColor.systemGreen.withAlphaComponent(0.15)
        let deletionColor = NSColor.systemRed.withAlphaComponent(0.15)
        let hunkHeaderColor = NSColor.systemBlue.withAlphaComponent(0.1)

        var oldLine = 0
        var newLine = 0

        for hunk in hunks {
            oldLine = hunk.oldStart
            newLine = hunk.newStart

            for lineType in hunk.lines {
                switch lineType {
                case .hunkHeader(let text):
                    let line = NSMutableAttributedString(string: "     \(text)\n", attributes: [
                        .font: smallFont,
                        .foregroundColor: NSColor.systemBlue,
                        .backgroundColor: hunkHeaderColor
                    ])
                    attributed.append(line)

                case .context(let text):
                    let prefix = String(format: "%4d %4d  ", oldLine, newLine)
                    let line = NSMutableAttributedString(string: "\(prefix)\(text)\n", attributes: defaultAttrs)
                    attributed.append(line)
                    oldLine += 1
                    newLine += 1

                case .addition(let text):
                    let prefix = String(format: "     %4d +", newLine)
                    let attrs: [NSAttributedString.Key: Any] = [
                        .font: monoFont,
                        .foregroundColor: NSColor.systemGreen,
                        .backgroundColor: additionColor
                    ]
                    let line = NSMutableAttributedString(string: "\(prefix)\(text)\n", attributes: attrs)
                    attributed.append(line)
                    newLine += 1

                case .deletion(let text):
                    let prefix = String(format: "%4d      -", oldLine)
                    let attrs: [NSAttributedString.Key: Any] = [
                        .font: monoFont,
                        .foregroundColor: NSColor.systemRed,
                        .backgroundColor: deletionColor
                    ]
                    let line = NSMutableAttributedString(string: "\(prefix)\(text)\n", attributes: attrs)
                    attributed.append(line)
                    oldLine += 1
                }
            }

            // Blank line between hunks
            attributed.append(NSAttributedString(string: "\n", attributes: defaultAttrs))
        }

        textView.textStorage?.setAttributedString(attributed)
    }
}
