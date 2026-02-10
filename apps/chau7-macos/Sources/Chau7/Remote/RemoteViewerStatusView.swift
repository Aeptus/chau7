import SwiftUI

/// SwiftUI view showing remote viewer status.
/// Displays viewer count badge, viewer list popover with names and connection time,
/// approve/deny buttons for pending viewers, disconnect per viewer,
/// share link display with copy button, and start/stop sharing toggle.
struct RemoteViewerStatusView: View {
    @ObservedObject private var viewerMode = RemoteViewerMode.shared
    @State private var showPopover = false
    @State private var copiedLink = false

    var body: some View {
        Button {
            showPopover.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "eye")
                    .font(.system(size: 11))
                if !viewerMode.connectedViewers.isEmpty {
                    Text(viewerMode.connectedViewers.count.formatted())
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.accentColor.opacity(0.2))
                        .clipShape(Capsule())
                }
                if !viewerMode.pendingApprovals.isEmpty {
                    Circle()
                        .fill(Color.orange)
                        .frame(width: 6, height: 6)
                }
            }
            .foregroundStyle(viewerMode.isSharing ? Color.accentColor : .secondary)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showPopover, arrowEdge: .bottom) {
            viewerPopoverContent
                .frame(width: 320)
        }
    }

    // MARK: - Popover Content

    @ViewBuilder
    private var viewerPopoverContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header with sharing toggle
            HStack {
                Text(L("viewer.title", "Remote Viewers"))
                    .font(.headline)
                Spacer()
                Toggle("", isOn: Binding(
                    get: { viewerMode.isSharing },
                    set: { newValue in
                        if newValue {
                            viewerMode.startSharing()
                        } else {
                            viewerMode.stopSharing()
                        }
                    }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
            }

            if viewerMode.isSharing {
                // Share link
                if let link = viewerMode.shareLink {
                    shareLinkSection(link: link)
                }

                Divider()

                // Pending approvals
                if !viewerMode.pendingApprovals.isEmpty {
                    pendingSection
                    Divider()
                }

                // Connected viewers
                connectedSection
            } else {
                Text(L("viewer.notSharing", "Enable sharing to allow remote viewing of your terminal session."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
    }

    // MARK: - Share Link

    @ViewBuilder
    private func shareLinkSection(link: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("viewer.shareLink", "Share Link"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack {
                Text(link)
                    .font(.system(size: 11, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(link, forType: .string)
                    copiedLink = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        copiedLink = false
                    }
                } label: {
                    Image(systemName: copiedLink ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    // MARK: - Pending Approvals

    @ViewBuilder
    private var pendingSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "bell.badge")
                    .foregroundColor(.orange)
                Text(L("viewer.pending", "Pending Approval"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            ForEach(viewerMode.pendingApprovals) { viewer in
                HStack {
                    Image(systemName: "person.circle")
                        .foregroundStyle(.secondary)
                    Text(viewer.name)
                        .font(.system(size: 12))
                    Spacer()
                    Button {
                        viewerMode.approveViewer(viewer.id)
                    } label: {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                    }
                    .buttonStyle(.plain)
                    .help(L("viewer.approve", "Approve"))

                    Button {
                        viewerMode.denyViewer(viewer.id)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.red)
                    }
                    .buttonStyle(.plain)
                    .help(L("viewer.deny", "Deny"))
                }
                .padding(.vertical, 2)
            }
        }
    }

    // MARK: - Connected Viewers

    @ViewBuilder
    private var connectedSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "person.2")
                    .foregroundColor(.green)
                Text(L("viewer.connected", "Connected"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(
                    String(
                        format: L("viewer.connectedCount", "(%d/%d)"),
                        viewerMode.connectedViewers.count,
                        viewerMode.maxViewers
                    )
                )
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            if viewerMode.connectedViewers.isEmpty {
                Text(L("viewer.noViewers", "No viewers connected"))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 4)
            } else {
                ForEach(viewerMode.connectedViewers) { viewer in
                    HStack {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 6, height: 6)
                        Text(viewer.name)
                            .font(.system(size: 12))
                        Spacer()
                        Text(viewer.connectionDuration)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Button {
                            viewerMode.disconnectViewer(viewer.id)
                        } label: {
                            Image(systemName: "xmark.circle")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help(L("viewer.disconnect", "Disconnect"))
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }
}
