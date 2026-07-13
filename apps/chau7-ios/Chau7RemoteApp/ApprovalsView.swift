import Chau7Core
import SwiftUI
import UIKit

/// Approval workflow tab: interactive prompts, pending approval requests, and
/// decision history. Every live item renders as a unified "decision card" —
/// severity rail → identity → the ask → hero command → collapsible details →
/// action zone — so risk reads at a glance and the two card types feel like one
/// system. Destructive commands promote to hold-to-allow to defeat mis-taps.
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
                        "You're all caught up",
                        systemImage: "checkmark.shield",
                        description: Text("Protected actions, command approvals, and detected Claude / Codex prompts land here. Agents pause until you decide.")
                    )
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                }

                if !client.pendingInteractivePrompts.isEmpty {
                    decisionSection("Interactive prompts", count: client.pendingInteractivePrompts.count) {
                        ForEach(client.pendingInteractivePrompts) { prompt in
                            InteractivePromptCard(
                                prompt: prompt,
                                customText: binding(for: prompt.id),
                                onRespond: { option in respondToPrompt(prompt, option: option) },
                                onSendCustom: { sendCustomReply(for: prompt) },
                                onDismiss: { dismissPrompt(prompt.id) },
                                onGoToTab: { onOpenTerminalTab(prompt.tabID) }
                            )
                            .decisionRow()
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
                    decisionSection("Needs your decision", count: client.pendingApprovals.count) {
                        ForEach(client.pendingApprovals) { request in
                            ApprovalRequestCard(
                                request: request,
                                onGoToTab: tabID(for: request).map { id in { onOpenTerminalTab(id) } }
                            ) { approved in
                                hapticTrigger.toggle()
                                client.respondToApproval(requestID: request.requestID, approved: approved)
                            }
                            .decisionRow()
                        }
                    }
                }

                if !client.approvalHistory.isEmpty {
                    Section {
                        ForEach(client.approvalHistory.suffix(20).reversed()) { entry in
                            ApprovalHistoryRow(entry: entry)
                        }
                    } header: {
                        Text("History").font(.footnote.weight(.semibold))
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color(.systemGroupedBackground))
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

    /// A section that carries a title plus a live count pill, shared by both
    /// live decision groups so their headers read identically.
    @ViewBuilder
    private func decisionSection(
        _ title: String,
        count: Int,
        @ViewBuilder content: () -> some View
    ) -> some View {
        Section {
            content()
        } header: {
            HStack(spacing: 6) {
                Text(title).font(.footnote.weight(.semibold))
                Text("\(count)")
                    .font(.caption2.weight(.bold).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 1)
                    .background(Color(.tertiarySystemFill), in: Capsule())
            }
        }
    }

    // MARK: - Actions (preserved behaviour)

    private func respondToPrompt(_ prompt: RemoteInteractivePrompt, option: RemoteInteractivePromptOption) {
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
    }

    private func sendCustomReply(for prompt: RemoteInteractivePrompt) {
        let text = customText(for: prompt.id)
        if client.respondToInteractivePrompt(promptID: prompt.id, customText: text) {
            resetCustomPromptState(for: prompt.id)
            hapticTrigger.toggle()
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

// MARK: - List row styling

private extension View {
    /// Makes a card float edge-to-edge on the grouped background: no separator,
    /// clear row fill, tight vertical rhythm.
    func decisionRow() -> some View {
        listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
    }
}

// MARK: - Severity styling

extension ApprovalSeverity {
    /// The rail / accent colour. Standard stays muted so ordinary commands don't
    /// cry wolf; protected and destructive escalate through the semantic palette.
    var accent: Color {
        switch self {
        case .standard: Color(.tertiaryLabel)
        case .protected: .orange
        case .destructive: .red
        }
    }

    /// Only protected and destructive warrant a badge; a standard command is
    /// self-evident and a badge would be noise.
    var badge: (text: String, icon: String)? {
        switch self {
        case .standard: nil
        case .protected: ("Protected action", "lock.shield.fill")
        case .destructive: ("Destructive · irreversible", "exclamationmark.octagon.fill")
        }
    }

    /// The irreversible tier promotes Allow to a deliberate press-and-hold.
    var requiresHoldToAllow: Bool { self == .destructive }
}

private struct SeverityBadge: View {
    let severity: ApprovalSeverity

    var body: some View {
        if let badge = severity.badge {
            Label(badge.text, systemImage: badge.icon)
                .font(.caption2.weight(.bold))
                .textCase(.uppercase)
                .foregroundStyle(severity.accent)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(severity.accent.opacity(0.14), in: Capsule())
        }
    }
}

// MARK: - Card chrome

/// The shared shell: a rounded surface with a leading severity rail, a hairline
/// border, and a soft lift. Both card types pour their content into it.
private struct DecisionCard<Content: View>: View {
    let accent: Color
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(spacing: 0) {
            Rectangle().fill(accent).frame(width: 4)
            VStack(alignment: .leading, spacing: 12) { content() }
                .padding(EdgeInsets(top: 14, leading: 14, bottom: 14, trailing: 14))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.05), radius: 9, x: 0, y: 3)
    }
}

/// "Who is asking, from where, and when" — an agent glyph, a name, a monospaced
/// repo · branch line, and a relative timestamp.
private struct CardIdentityRow: View {
    let toolName: String?
    let location: String?
    let timestamp: Date

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: Self.icon(for: toolName))
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 30, height: 30)
                .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(toolName ?? "Command")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                if let location, !location.isEmpty {
                    Text(location)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            Spacer(minLength: 8)
            Text(timestamp, style: .relative)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
    }

    private static func icon(for tool: String?) -> String {
        let name = (tool ?? "").lowercased()
        if name.contains("codex") { return "chevron.left.forwardslash.chevron.right" }
        if name.contains("claude") { return "sparkles" }
        return "terminal.fill"
    }
}

/// The hero: the command rendered as a real terminal line — prompt glyph,
/// monospace, copyable — with the severity accent on the prompt.
private struct CommandBlock: View {
    let command: String
    let accent: Color

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Text("$")
                .font(.system(.callout, design: .monospaced).weight(.bold))
                .foregroundStyle(accent)
            Text(command)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                UIPasteboard.general.string = command
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Copy command")
        }
        .padding(12)
        .background(Color(.tertiarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
    }
}

/// A single collapsible "Details" disclosure that folds directory, rationale,
/// and recent activity behind one tap — compact by default, so the decision
/// stays above the fold.
private struct CardDetails: View {
    let rows: [DetailRow]
    @State private var isExpanded = false

    struct DetailRow: Identifiable {
        let icon: String
        let label: String
        let value: String
        var id: String { label }
    }

    var body: some View {
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { isExpanded.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.bold))
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            .foregroundStyle(.tertiary)
                        Text(isExpanded ? "Hide details" : "Details")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)

                if isExpanded {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(rows) { row in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Label(row.label, systemImage: row.icon)
                                    .labelStyle(.iconOnly)
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                                    .frame(width: 16)
                                Text(row.value)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .padding(.top, 9)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
    }
}

/// Press-and-hold Allow for the destructive tier: the fill sweeps across while
/// held and fires on completion; releasing early cancels. A deliberate gesture
/// that a pocket tap can't reproduce.
private struct HoldToConfirmButton: View {
    let title: String
    let subtitle: String
    let tint: Color
    let action: () -> Void

    @State private var progress: CGFloat = 0
    @State private var isPressing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            GeometryReader { geo in
                Rectangle()
                    .fill(.white.opacity(0.28))
                    .frame(width: geo.size.width * progress)
            }
            VStack(spacing: 1) {
                Text(title).font(.callout.weight(.bold))
                Text(subtitle).font(.caption2).opacity(0.9)
            }
            .foregroundStyle(.white)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 46)
        .background(tint, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onLongPressGesture(minimumDuration: 0.9, pressing: { pressing in
            isPressing = pressing
            if reduceMotion {
                progress = pressing ? 0.5 : 0
            } else {
                withAnimation(pressing ? .linear(duration: 0.9) : .easeOut(duration: 0.18)) {
                    progress = pressing ? 1 : 0
                }
            }
        }, perform: action)
        .accessibilityLabel("\(title). \(subtitle)")
        .accessibilityHint("Press and hold to confirm this irreversible action.")
    }
}

/// A "…in flight" banner shown in place of the action row once a decision is
/// optimistically sent, so the card reflects the pending outcome immediately.
private struct InFlightBanner: View {
    let label: String
    let allow: Bool

    var body: some View {
        HStack(spacing: 9) {
            ProgressView().controlSize(.small)
            Text(label).font(.callout.weight(.semibold))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 11)
        .foregroundStyle(allow ? Color.green : Color.red)
        .background((allow ? Color.green : Color.red).opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// "Read more" affordance that jumps from a card to the live terminal tab.
private struct GoToTabButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("View in terminal", systemImage: "arrow.up.forward.app")
                .font(.caption.weight(.semibold))
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .accessibilityHint("Opens the terminal tab for this request so you can read the full context.")
    }
}

// MARK: - Interactive Prompt Card

struct InteractivePromptCard: View {
    let prompt: RemoteInteractivePrompt
    @Binding var customText: String
    let onRespond: (RemoteInteractivePromptOption) -> Void
    let onSendCustom: () -> Void
    let onDismiss: () -> Void
    let onGoToTab: () -> Void

    var body: some View {
        DecisionCard(accent: .accentColor) {
            HStack(alignment: .top) {
                Label("Interactive prompt", systemImage: "text.bubble.fill")
                    .font(.caption2.weight(.bold))
                    .textCase(.uppercase)
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Color.accentColor.opacity(0.14), in: Capsule())
                Spacer()
                Button(action: onDismiss) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.body)
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss prompt")
            }

            CardIdentityRow(
                toolName: prompt.toolName,
                location: Self.location(project: prompt.projectName, branch: prompt.branchName, tab: prompt.tabTitle),
                timestamp: prompt.detectedAt
            )

            Text(prompt.prompt)
                .font(.callout.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)

            CardDetails(rows: detailRows)

            VStack(spacing: 8) {
                ForEach(prompt.options) { option in
                    PromptOptionButton(option: option) { onRespond(option) }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Custom reply").font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    TextField("Escape prompt and send text", text: $customText, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.system(.callout, design: .monospaced))
                        .lineLimit(1 ... 3)
                        .padding(.horizontal, 11).padding(.vertical, 9)
                        .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    Button("Send", action: onSendCustom)
                        .font(.callout.weight(.semibold))
                        .buttonStyle(.borderedProminent)
                        .disabled(customText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }

            GoToTabButton(action: onGoToTab)
        }
    }

    private var detailRows: [CardDetails.DetailRow] {
        var rows: [CardDetails.DetailRow] = []
        if let dir = prompt.currentDirectory, !dir.isEmpty {
            rows.append(.init(icon: "folder", label: "Directory", value: dir))
        }
        if let detail = prompt.detail, !detail.isEmpty {
            rows.append(.init(icon: "text.alignleft", label: "Prompt context", value: detail))
        }
        return rows
    }

    private static func location(project: String?, branch: String?, tab: String?) -> String? {
        let parts = [project, branch].compactMap { $0?.isEmpty == false ? $0 : nil }
        if !parts.isEmpty { return parts.joined(separator: " · ") }
        return tab
    }
}

// MARK: - Approval Request Card

struct ApprovalRequestCard: View {
    let request: ApprovalRequest
    var onGoToTab: (() -> Void)?
    let onRespond: (Bool) -> Void

    var body: some View {
        DecisionCard(accent: request.severity.accent) {
            SeverityBadge(severity: request.severity)

            CardIdentityRow(
                toolName: request.toolName,
                location: Self.location(project: request.projectName, branch: request.branchName, tab: request.tabTitle),
                timestamp: request.timestamp
            )

            Text("wants to run")
                .font(.caption)
                .foregroundStyle(.secondary)

            CommandBlock(command: request.command, accent: request.severity.accent)

            if request.flaggedCommand != request.command {
                Label("Flagged as \(request.flaggedCommand)", systemImage: "flag.fill")
                    .font(.caption)
                    .foregroundStyle(request.severity.accent)
            }

            CardDetails(rows: detailRows)

            if let onGoToTab {
                GoToTabButton(action: onGoToTab)
            }

            actionZone
        }
    }

    @ViewBuilder
    private var actionZone: some View {
        if request.responseState.isBusy {
            InFlightBanner(
                label: request.responseState.actionLabel ?? "Sending…",
                allow: request.responseState.isAllowIntent ?? true
            )
        } else {
            HStack(spacing: 10) {
                Button(role: .destructive) { onRespond(false) } label: {
                    Text("Deny").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .tint(.red)

                if request.severity.requiresHoldToAllow {
                    HoldToConfirmButton(title: "Hold to allow", subtitle: "irreversible", tint: .green) {
                        onRespond(true)
                    }
                } else {
                    Button { onRespond(true) } label: {
                        Text("Allow").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .tint(.green)
                }
            }
        }
    }

    private var detailRows: [CardDetails.DetailRow] {
        var rows: [CardDetails.DetailRow] = []
        if let dir = request.currentDirectory, !dir.isEmpty {
            rows.append(.init(icon: "folder", label: "Directory", value: dir))
        }
        if let note = request.contextNote, !note.isEmpty {
            rows.append(.init(icon: "info.circle", label: "Context", value: note))
        }
        if let recent = request.recentCommand, !recent.isEmpty, recent != request.command {
            rows.append(.init(icon: "clock.arrow.circlepath", label: "Recent command", value: recent))
        }
        return rows
    }

    private static func location(project: String?, branch: String?, tab: String?) -> String? {
        let parts = [project, branch].compactMap { $0?.isEmpty == false ? $0 : nil }
        if !parts.isEmpty { return parts.joined(separator: " · ") }
        return tab
    }
}

// MARK: - Prompt option button

private struct PromptOptionButton: View {
    let option: RemoteInteractivePromptOption
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 11) {
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
                Image(systemName: option.isDestructive ? "exclamationmark.triangle.fill" : "arrow.turn.down.left")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(option.isDestructive ? .orange : .secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
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
        option.isDestructive ? Color.orange.opacity(0.10) : Color(.tertiarySystemGroupedBackground)
    }

    private var borderColor: Color {
        option.isDestructive ? Color.orange.opacity(0.35) : Color.primary.opacity(0.08)
    }
}

// MARK: - History Row

struct ApprovalHistoryRow: View {
    let entry: ApprovalHistoryEntry

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: entry.approved ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(entry.approved ? .green : .red)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(entry.command)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(2)
                Text(entry.timestamp, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}
