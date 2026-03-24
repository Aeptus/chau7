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

            let contextItems = promptContextItems(for: prompt)
            if !contextItems.isEmpty {
                ApprovalContextRow(items: contextItems)
            }

            if let currentDirectory = prompt.currentDirectory, !currentDirectory.isEmpty {
                ApprovalContextDetailRow(
                    title: "Directory",
                    value: currentDirectory,
                    systemImage: "folder"
                )
            }

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

    private func promptContextItems(for prompt: RemoteInteractivePrompt) -> [ApprovalContextItem] {
        var items: [ApprovalContextItem] = []
        if let projectName = prompt.projectName, !projectName.isEmpty {
            items.append(ApprovalContextItem(label: projectName, systemImage: "folder"))
        }
        if let branchName = prompt.branchName, !branchName.isEmpty {
            items.append(ApprovalContextItem(label: branchName, systemImage: "arrow.triangle.branch"))
        }
        return items
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

            let contextItems = approvalContextItems(for: request)
            if !contextItems.isEmpty {
                ApprovalContextRow(items: contextItems)
            }

            if let currentDirectory = request.currentDirectory, !currentDirectory.isEmpty {
                ApprovalContextDetailRow(
                    title: "Directory",
                    value: currentDirectory,
                    systemImage: "folder"
                )
            }

            if let contextNote = request.contextNote, !contextNote.isEmpty {
                ApprovalContextDetailRow(
                    title: "Context",
                    value: contextNote,
                    systemImage: "info.circle"
                )
            }

            if let recentCommand = request.recentCommand,
               !recentCommand.isEmpty,
               recentCommand != request.command {
                ApprovalContextDetailRow(
                    title: "Recent Command",
                    value: recentCommand,
                    systemImage: "terminal"
                )
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

            if let actionLabel = request.responseState.actionLabel {
                Label(actionLabel, systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                Button(role: .destructive) { onRespond(false) } label: {
                    Label("Deny", systemImage: "xmark")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(request.responseState.isBusy)

                Button { onRespond(true) } label: {
                    Label("Allow", systemImage: "checkmark")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .disabled(request.responseState.isBusy)
            }
        }
        .padding(.vertical, 4)
    }

    private func approvalContextItems(for request: ApprovalRequest) -> [ApprovalContextItem] {
        var items: [ApprovalContextItem] = []
        if let toolName = request.toolName, !toolName.isEmpty {
            items.append(ApprovalContextItem(label: toolName, systemImage: "wand.and.stars"))
        }
        if let tabTitle = request.tabTitle, !tabTitle.isEmpty {
            items.append(ApprovalContextItem(label: tabTitle, systemImage: "rectangle.on.rectangle"))
        }
        if let projectName = request.projectName, !projectName.isEmpty {
            items.append(ApprovalContextItem(label: projectName, systemImage: "folder"))
        }
        if let branchName = request.branchName, !branchName.isEmpty {
            items.append(ApprovalContextItem(label: branchName, systemImage: "arrow.triangle.branch"))
        }
        return items
    }
}

private struct ApprovalContextItem: Identifiable {
    let label: String
    let systemImage: String
    var id: String { "\(systemImage):\(label)" }
}

private struct ApprovalContextRow: View {
    let items: [ApprovalContextItem]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(items) { item in
                    Label(item.label, systemImage: item.systemImage)
                        .font(.caption)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color(UIColor.secondarySystemBackground))
                        .clipShape(Capsule())
                }
            }
        }
    }
}

private struct ApprovalContextDetailRow: View {
    let title: String
    let value: String
    let systemImage: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: systemImage)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(UIColor.tertiarySystemBackground))
                .cornerRadius(8)
        }
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
