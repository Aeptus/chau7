import SwiftUI
import Chau7Core

/// Shared header skeleton for pane views. Replaces four hand-rolled
/// `HStack(icon, title, …, Spacer, …, Close)` bars that were spelled out
/// independently in TextEditorPaneView, FilePreviewPaneView,
/// DiffViewerPaneView, and RepositoryPaneView.
///
///     [icon] [title] [titleAccessory] ────── [trailing] [×]
///
/// Three `@ViewBuilder` slots fill in the per-pane embellishments:
///
/// * `title` — the title region itself. Defaults to a `Text(titleString)`
///   when constructed via the String convenience init; complex panes
///   (TextEditor's tap-to-copy filename, Repository's branch-picker
///   button) supply a custom `View` here.
/// * `titleAccessory` — slot between title and the flex spacer (dirty
///   dot, +N/-M counts, ahead/behind chip, IMAGE badge, …).
/// * `trailing` — slot between spacer and close button (save buttons,
///   mode picker, refresh, runbook toggle, …).
struct PaneHeaderBar<TitleView: View, TitleAccessory: View, Trailing: View>: View {
    let icon: String
    let onClose: () -> Void
    let closeHelp: String
    @ViewBuilder let title: () -> TitleView
    @ViewBuilder let titleAccessory: () -> TitleAccessory
    @ViewBuilder let trailing: () -> Trailing

    init(
        icon: String,
        closeHelp: String = L("Close Pane", "Close Pane"),
        onClose: @escaping () -> Void,
        @ViewBuilder title: @escaping () -> TitleView,
        @ViewBuilder titleAccessory: @escaping () -> TitleAccessory = { EmptyView() },
        @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }
    ) {
        self.icon = icon
        self.closeHelp = closeHelp
        self.onClose = onClose
        self.title = title
        self.titleAccessory = titleAccessory
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            title()

            titleAccessory()

            Spacer()

            trailing()

            PaneCloseButton(closeHelp: closeHelp, onClose: onClose)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

/// Shared close control for pane headers and headerless terminal panes.
struct PaneCloseButton: View {
    let closeHelp: String
    let onClose: () -> Void

    init(
        closeHelp: String = L("Close Pane", "Close Pane"),
        onClose: @escaping () -> Void
    ) {
        self.closeHelp = closeHelp
        self.onClose = onClose
    }

    var body: some View {
        Button(action: onClose) {
            Image(systemName: "xmark")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(closeHelp)
        .accessibilityLabel(closeHelp)
    }
}

/// Standard title view used by panes that don't need an interactive title
/// region. Applies the canonical 11pt-medium / line-limit-1 /
/// middle-truncation styling so each callsite doesn't re-spell it.
struct PaneHeaderTitle: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .medium))
            .lineLimit(1)
            .truncationMode(.middle)
    }
}
