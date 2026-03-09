import SwiftUI

struct ApprovalsView: View {
    @ObservedObject var client: RemoteClient

    private let haptic = UINotificationFeedbackGenerator()

    var body: some View {
        NavigationStack {
            List {
                if client.pendingApprovals.isEmpty && client.approvalHistory.isEmpty {
                    ContentUnavailableView(
                        "No Approvals",
                        systemImage: "checkmark.shield",
                        description: Text("Command approvals from MCP agents will appear here.")
                    )
                }

                if !client.pendingApprovals.isEmpty {
                    Section("Pending") {
                        ForEach(client.pendingApprovals) { request in
                            ApprovalRequestCard(request: request) { approved in
                                haptic.notificationOccurred(approved ? .success : .error)
                                client.respondToApproval(requestID: request.requestID, approved: approved)
                            }
                        }
                    }
                }

                if !client.approvalHistory.isEmpty {
                    Section("History") {
                        ForEach(client.approvalHistory.suffix(20).reversed()) { entry in
                            ApprovalHistoryRow(entry: entry)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Approvals")
        }
    }
}

// MARK: - Approval Request Card

struct ApprovalRequestCard: View {
    let request: ApprovalRequest
    let onRespond: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("Command Approval")
                    .font(.headline)
                Spacer()
                Text(request.timestamp, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Text(request.command)
                .font(.system(.callout, design: .monospaced))
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(UIColor.tertiarySystemBackground))
                .cornerRadius(8)

            if request.flaggedCommand != request.command {
                Label("Flagged: \(request.flaggedCommand)", systemImage: "flag")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            HStack(spacing: 12) {
                Button(role: .destructive) { onRespond(false) } label: {
                    Label("Deny", systemImage: "xmark")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button { onRespond(true) } label: {
                    Label("Allow", systemImage: "checkmark")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - History Row

struct ApprovalHistoryRow: View {
    let entry: ApprovalHistoryEntry

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: entry.approved ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(entry.approved ? .green : .red)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.command)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(2)
                Text(entry.timestamp, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
