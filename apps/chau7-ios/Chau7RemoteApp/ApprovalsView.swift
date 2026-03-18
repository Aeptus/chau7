import SwiftUI
import Chau7Core

struct ApprovalsView: View {
    var client: RemoteClient
    @State private var hapticTrigger = false
    @State private var pendingPromptConfirmation: PendingInteractivePromptConfirmation?

    var body: some View {
        NavigationStack {
            List {
                if client.pendingApprovals.isEmpty &&
                    client.pendingInteractivePrompts.isEmpty &&
                    client.approvalHistory.isEmpty {
                    ContentUnavailableView(
                        "No Approvals",
                        systemImage: "checkmark.shield",
                        description: Text("Protected remote actions, command approvals, and detected Claude/Codex prompts will appear here.")
                    )
                }

                if !client.pendingInteractivePrompts.isEmpty {
                    Section("Interactive Prompts") {
                        ForEach(client.pendingInteractivePrompts) { prompt in
                            InteractivePromptCard(prompt: prompt) { option in
                                if option.isDestructive {
                                    pendingPromptConfirmation = PendingInteractivePromptConfirmation(
                                        promptID: prompt.id,
                                        promptText: prompt.prompt,
                                        toolName: prompt.toolName,
                                        tabTitle: prompt.tabTitle,
                                        option: option
                                    )
                                } else if client.respondToInteractivePrompt(promptID: prompt.id, optionID: option.id) {
                                    hapticTrigger.toggle()
                                }
                            }
                        }
                    }
                }

                if !client.pendingApprovals.isEmpty {
                    Section("Pending") {
                        ForEach(client.pendingApprovals) { request in
                            ApprovalRequestCard(request: request) { approved in
                                hapticTrigger.toggle()
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
            .sensoryFeedback(.success, trigger: hapticTrigger)
            .alert(
                pendingPromptConfirmation?.title ?? "Confirm Prompt Response",
                isPresented: pendingPromptConfirmationBinding
            ) {
                Button("Cancel", role: .cancel) {
                    pendingPromptConfirmation = nil
                }
                Button(
                    pendingPromptConfirmation?.confirmationLabel ?? "Confirm",
                    role: .destructive
                ) {
                    guard let pendingPromptConfirmation else { return }
                    if client.respondToInteractivePrompt(
                        promptID: pendingPromptConfirmation.promptID,
                        optionID: pendingPromptConfirmation.option.id
                    ) {
                        hapticTrigger.toggle()
                    }
                    self.pendingPromptConfirmation = nil
                }
            } message: {
                Text(pendingPromptConfirmation?.message ?? "")
            }
        }
    }

    private var pendingPromptConfirmationBinding: Binding<Bool> {
        Binding(
            get: { pendingPromptConfirmation != nil },
            set: { isPresented in
                if !isPresented {
                    pendingPromptConfirmation = nil
                }
            }
        )
    }
}

private struct PendingInteractivePromptConfirmation: Equatable {
    let promptID: String
    let promptText: String
    let toolName: String
    let tabTitle: String
    let option: RemoteInteractivePromptOption

    var title: String { "Confirm Destructive Prompt" }
    var confirmationLabel: String { option.label }
    var message: String {
        "\(toolName) on \(tabTitle) is asking:\n\n\(promptText)\n\nThis will send `\(option.response.trimmingCharacters(in: .whitespacesAndNewlines))` back to the terminal."
    }
}

struct InteractivePromptCard: View {
    let prompt: RemoteInteractivePrompt
    let onRespond: (RemoteInteractivePromptOption) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Label("Interactive Prompt", systemImage: "text.bubble")
                        .font(.headline)
                    Text("\(prompt.toolName) · \(prompt.tabTitle)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(prompt.detectedAt, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Text(prompt.prompt)
                .font(.body.weight(.semibold))

            if let detail = prompt.detail, !detail.isEmpty {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach(prompt.options) { option in
                Button {
                    onRespond(option)
                } label: {
                    HStack {
                        Text(option.label)
                        Spacer()
                        Text(option.response.trimmingCharacters(in: .whitespacesAndNewlines))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.borderedProminent)
                .tint(option.isDestructive ? .red : .blue)
            }
        }
        .padding(.vertical, 4)
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
                Text(request.title)
                    .font(.headline)
                Spacer()
                Text(request.timestamp, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if let subtitle = request.subtitle {
                Label(subtitle, systemImage: "lock.shield")
                    .font(.caption)
                    .foregroundStyle(.orange)
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
                Text(entry.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
