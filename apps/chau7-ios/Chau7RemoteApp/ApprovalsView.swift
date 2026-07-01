import SwiftUI
import Chau7Core

/// Approval workflow tab: interactive prompts, pending approval requests,
/// and decision history. Pending requests show command context (tool, directory,
/// recent command). Dangerous interactive prompts require confirmation.
struct ApprovalsView: View {
    var client: RemoteClient
    /// Switches the main tab bar to the terminal and activates the given remote
    /// tab, so a card can offer a "read more" jump into the live session.
    var onOpenTerminalTab: (UInt32) -> Void
    @State private var hapticTrigger = false
    @State private var pendingPromptConfirmation: PendingInteractivePromptConfirmation?
    @State private var customPromptDrafts: [String: String] = [:]

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
                            InteractivePromptCard(
                                prompt: prompt,
                                customText: binding(for: prompt.id),
                                onRespond: { option in
                                    if option.isDestructive {
                                        pendingPromptConfirmation = PendingInteractivePromptConfirmation(
                                            promptID: prompt.id,
                                            promptText: prompt.prompt,
                                            toolName: prompt.toolName,
                                            tabTitle: prompt.tabTitle,
                                            option: option
                                        )
                                    } else if client.respondToInteractivePrompt(promptID: prompt.id, optionID: option.id) {
                                        resetCustomPromptState(for: prompt.id)
                                        hapticTrigger.toggle()
                                    }
                                },
                                onSendCustom: {
                                    let text = customText(for: prompt.id)
                                    if client.respondToInteractivePrompt(promptID: prompt.id, customText: text) {
                                        resetCustomPromptState(for: prompt.id)
                                        hapticTrigger.toggle()
                                    }
                                },
                                onDismiss: { dismissPrompt(prompt.id) },
                                onGoToTab: { onOpenTerminalTab(prompt.tabID) }
                            )
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    dismissPrompt(prompt.id)
                                } label: {
                                    Label("Dismiss", systemImage: "xmark.circle")
                                }
                            }
                        }
                    }
                }

                if !client.pendingApprovals.isEmpty {
                    Section("Pending") {
                        ForEach(client.pendingApprovals) { request in
                            ApprovalRequestCard(
                                request: request,
                                onGoToTab: tabID(for: request).map { id in { onOpenTerminalTab(id) } }
                            ) { approved in
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

    private func binding(for promptID: String) -> Binding<String> {
        Binding(
            get: { customPromptDrafts[promptID] ?? "" },
            set: { customPromptDrafts[promptID] = $0 }
        )
    }

    private func customText(for promptID: String) -> String {
        customPromptDrafts[promptID] ?? ""
    }

    private func resetCustomPromptState(for promptID: String) {
        customPromptDrafts[promptID] = nil
    }

    private func dismissPrompt(_ promptID: String) {
        client.dismissInteractivePrompt(promptID: promptID)
        resetCustomPromptState(for: promptID)
        hapticTrigger.toggle()
    }

    /// Best-effort resolution of the remote tab for a structured approval, which
    /// (unlike an interactive prompt) carries no tab id — match on the tab title
    /// the Mac sent. Returns nil when it can't be resolved, so the "Go to Tab"
    /// affordance simply doesn't appear.
    private func tabID(for request: ApprovalRequest) -> UInt32? {
        guard let title = request.tabTitle, !title.isEmpty else { return nil }
        return client.tabs.first(where: { $0.title == title })?.tabID
    }
}

private struct PendingInteractivePromptConfirmation: Equatable {
    let promptID: String
    let promptText: String
    let toolName: String
    let tabTitle: String
    let option: RemoteInteractivePromptOption

    var title: String { "Confirm Dangerous Prompt" }
    var confirmationLabel: String { option.label }
    var message: String {
        "\(toolName) on \(tabTitle) is asking:\n\n\(promptText)\n\nThis will send `\(option.response.trimmingCharacters(in: .whitespacesAndNewlines))` back to the terminal."
    }
}

struct InteractivePromptCard: View {
    let prompt: RemoteInteractivePrompt
    @Binding var customText: String
    let onRespond: (RemoteInteractivePromptOption) -> Void
    let onSendCustom: () -> Void
    let onDismiss: () -> Void
    let onGoToTab: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Label("Interactive Prompt", systemImage: "text.bubble")
                        .font(.subheadline.weight(.semibold))
                    Text("\(prompt.toolName) · \(prompt.tabTitle)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 6) {
                    Text(prompt.detectedAt, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Button {
                        onDismiss()
                    } label: {
                        Label("Dismiss", systemImage: "xmark.circle.fill")
                            .labelStyle(.titleAndIcon)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Dismiss prompt")
                }
            }

            Text(prompt.prompt)
                .font(.callout.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)

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
                ApprovalContextDetailRow(
                    title: "Prompt Context",
                    value: detail,
                    systemImage: "text.alignleft"
                )
            }

            GoToTabButton(action: onGoToTab)

            ForEach(prompt.options) { option in
                PromptOptionButton(option: option) {
                    onRespond(option)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Custom reply")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextField("Escape prompt and send text", text: $customText, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.callout, design: .monospaced))
                    .lineLimit(1 ... 3)

                HStack {
                    Spacer()
                    Button("Send Reply") {
                        onSendCustom()
                    }
                    .buttonStyle(.bordered)
                    .disabled(customText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .padding(.vertical, 6)
    }

    private func promptContextItems(for prompt: RemoteInteractivePrompt) -> [ApprovalContextItem] {
        ApprovalContextItem.projectAndBranch(project: prompt.projectName, branch: prompt.branchName)
    }
}

// MARK: - Approval Request Card

struct ApprovalRequestCard: View {
    let request: ApprovalRequest
    var onGoToTab: (() -> Void)?
    let onRespond: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(request.title)
                    .font(.subheadline.weight(.semibold))
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
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(UIColor.tertiarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

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

            if let onGoToTab {
                GoToTabButton(action: onGoToTab)
            }

            HStack(spacing: 10) {
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
        items += ApprovalContextItem.projectAndBranch(project: request.projectName, branch: request.branchName)
        return items
    }
}

/// "Read more" affordance that jumps from an approval/prompt card to the live
/// terminal for that tab.
private struct GoToTabButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("View in Terminal", systemImage: "terminal")
                .font(.caption.weight(.semibold))
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .accessibilityHint("Opens the terminal tab for this request so you can read the full context.")
    }
}

private struct ApprovalContextItem: Identifiable {
    let label: String
    let systemImage: String
    var id: String { "\(systemImage):\(label)" }

    /// Project + branch chips, shared by the prompt and approval cards so the
    /// labels and icons are defined once.
    static func projectAndBranch(project: String?, branch: String?) -> [ApprovalContextItem] {
        var items: [ApprovalContextItem] = []
        if let project, !project.isEmpty {
            items.append(ApprovalContextItem(label: project, systemImage: "folder"))
        }
        if let branch, !branch.isEmpty {
            items.append(ApprovalContextItem(label: branch, systemImage: "arrow.triangle.branch"))
        }
        return items
    }
}

private struct ApprovalContextRow: View {
    let items: [ApprovalContextItem]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(items) { item in
                    Label(item.label, systemImage: item.systemImage)
                        .font(.caption)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
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
    var collapsedLineLimit: Int = 3
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label(title, systemImage: systemImage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if isExpandable {
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
                    } label: {
                        Label(isExpanded ? "Less" : "More", systemImage: isExpanded ? "chevron.up" : "chevron.down")
                            .labelStyle(.titleAndIcon)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.tint)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(isExpanded ? "Collapse \(title)" : "Expand \(title)")
                }
            }
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(isExpanded ? nil : collapsedLineLimit)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color(UIColor.tertiarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .contentShape(Rectangle())
                .onTapGesture {
                    guard isExpandable else { return }
                    withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
                }
        }
    }

    /// A value longer than this (or spanning multiple lines) collapses behind a
    /// More/Less control; shorter context stays fully visible with no chevron.
    private static let collapseThreshold = 140

    /// Only long or multi-line values are worth collapsing; short single-line
    /// context (e.g. a directory) stays fully visible with no chevron.
    private var isExpandable: Bool {
        value.count > Self.collapseThreshold || value.contains("\n")
    }
}

private struct PromptOptionButton: View {
    let option: RemoteInteractivePromptOption
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.label)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                    if !trimmedResponse.isEmpty {
                        Text(trimmedResponse)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: option.isDestructive ? "exclamationmark.triangle.fill" : "arrow.up.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(option.isDestructive ? .orange : .secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(backgroundColor)
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(borderColor, lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var trimmedResponse: String {
        option.response.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var backgroundColor: Color {
        option.isDestructive ? Color.orange.opacity(0.10) : Color(UIColor.secondarySystemBackground)
    }

    private var borderColor: Color {
        option.isDestructive ? Color.orange.opacity(0.35) : Color.primary.opacity(0.08)
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
