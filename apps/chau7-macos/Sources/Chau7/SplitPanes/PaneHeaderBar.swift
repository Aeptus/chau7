import SwiftUI
import Chau7Core

/// Shared header skeleton for pane views — replaces four hand-rolled
/// `HStack(icon, title, …, Spacer, …, Close)` bars that were spelled out
/// independently in TextEditorPaneView, FilePreviewPaneView,
/// DiffViewerPaneView, and RepositoryPaneView. The shape:
///
///     [icon] [title] [titleAccessory] ────── [trailing] [×]
///
/// `titleAccessory` is the slot between the title and the flex spacer
/// (e.g. an "IMAGE" badge, additions/deletions counts, a branch chip).
/// `trailing` is the slot between the spacer and the close button
/// (e.g. a mode picker, a refresh button). Either can be `EmptyView()`.
///
/// Panes with strongly custom headers (TextEditorPaneView's autosave
/// status, plan-progress, conflict banner; RepositoryPaneView's branch
/// picker, ahead/behind, session summary) can still spell their header
/// bar out — this component only absorbs the common cases.
struct PaneHeaderBar<TitleAccessory: View, Trailing: View>: View {
    let icon: String
    let title: String
    let onClose: () -> Void
    let closeHelp: String
    @ViewBuilder let titleAccessory: () -> TitleAccessory
    @ViewBuilder let trailing: () -> Trailing

    init(
        icon: String,
        title: String,
        closeHelp: String = L("Close Pane", "Close Pane"),
        onClose: @escaping () -> Void,
        @ViewBuilder titleAccessory: @escaping () -> TitleAccessory = { EmptyView() },
        @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }
    ) {
        self.icon = icon
        self.title = title
        self.closeHelp = closeHelp
        self.onClose = onClose
        self.titleAccessory = titleAccessory
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            Text(title)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)

            titleAccessory()

            Spacer()

            trailing()

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(closeHelp)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color(nsColor: .controlBackgroundColor))
    }
}
