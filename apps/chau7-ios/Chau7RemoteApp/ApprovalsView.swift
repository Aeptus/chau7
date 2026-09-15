import Chau7Core
import SwiftUI
import UIKit

/// Approval workflow tab. Each pending decision — a command approval or a
/// detected Claude / Codex prompt — takes the whole screen: severity up top,
/// the command as the centrepiece, context readable inline, and deliberate
/// actions in the thumb zone. Several pending items become a swipeable deck
/// that advances as you decide. History lives one tap away.
struct ApprovalsView: View {
    var client: RemoteClient
    /// Switches the main tab bar to the terminal and activates the given remote
    /// tab, so a card can offer a "read more" jump into the live session.
    var onOpenTerminalTab: (UInt32) -> Void
    @State private var hapticTrigger = false
    @State private var pendingPromptConfirmation: PendingInteractivePromptConfirmation?
    @State private var customPromptDrafts: [String: String] = [:]
    @State private var selection: String?
    @State private var showHistory = false

    /// Approvals first (they gate a running command), then detected prompts,
    /// merged into one ordered decision queue.
    private var decisions: [PendingDecision] {
        client.pendingApprovals.map(PendingDecision.approval)
            + client.pendingInteractivePrompts.map(PendingDecision.prompt)
    }

    var body: some View {
        NavigationStack {
            Group {
                if decisions.isEmpty {
                    emptyState
                } else {
                    deck
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    if decisions.isEmpty {
                        Text("Approvals").font(.headline)
                    } else {
                        QueueIndicator(index: currentIndex, count: decisions.count)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if !client.approvalHistory.isEmpty {
                        Button {
                            showHistory = true
                        } label: {
                            Image(systemName: "clock.arrow.circlepath")
                        }
                        .accessibilityLabel("Decision history")
                    }
                }
            }
            .sheet(isPresented: $showHistory) { historySheet }
            .sensoryFeedback(.success, trigger: hapticTrigger)
            .alert(
                pendingPromptConfirmation?.title ?? "Confirm Prompt Response",
                isPresented: pendingPromptConfirmationBinding
            ) {
                Button("Cancel", role: .cancel) { pendingPromptConfirmation = nil }
                Button(pendingPromptConfirmation?.confirmationLabel ?? "Confirm", role: .destructive) {
                    confirmPendingPrompt()
                }
            } message: {
                Text(pendingPromptConfirmation?.message ?? "")
            }
        }
        .onAppear { normalizeSelection() }
        .onChange(of: decisions.map(\.id)) { _, _ in normalizeSelection() }
    }

    // MARK: - Deck

    private var deck: some View {
        TabView(selection: $selection) {
            ForEach(decisions) { decision in
                decisionPage(decision)
                    .tag(decision.id as String?)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
    }

    @ViewBuilder
    private func decisionPage(_ decision: PendingDecision) -> some View {
        switch decision {
        case let .approval(request):
            FullScreenApprovalCard(
                request: request,
                onGoToTab: tabID(for: request).map { id in { onOpenTerminalTab(id) } }
            ) { approved in
                let next = nextSelection(after: decision.id)
                hapticTrigger.toggle()
                client.respondToApproval(requestID: request.requestID, approved: approved)
                selection = next
            }
        case let .prompt(prompt):
            FullScreenPromptCard(
                prompt: prompt,
                customText: binding(for: prompt.id),
                onRespond: { option in respondToPrompt(prompt, option: option, decisionID: decision.id) },
                onSendCustom: { sendCustomReply(for: prompt, decisionID: decision.id) },
                onDismiss: {
                    let next = nextSelection(after: decision.id)
                    dismissPrompt(prompt.id)
                    selection = next
                },
                onGoToTab: { onOpenTerminalTab(prompt.tabID) },
                onToggleOption: { option in
                    hapticTrigger.toggle()
                    _ = client.toggleInteractivePromptOption(promptID: prompt.id, optionID: option.id)
                },
                onSubmitMultiSelect: {
                    let next = nextSelection(after: decision.id)
                    if client.submitInteractivePrompt(promptID: prompt.id) {
                        resetCustomPromptState(for: prompt.id)
                        hapticTrigger.toggle()
                        selection = next
                    }
                }
            )
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("You're all caught up", systemImage: "checkmark.shield")
        } description: {
            Text("Protected actions, command approvals, and detected Claude / Codex prompts appear here. Agents pause until you decide.")
        } actions: {
            if !client.approvalHistory.isEmpty {
                Button("View history") { showHistory = true }
            }
        }
    }

    private var historySheet: some View {
        NavigationStack {
            List {
                ForEach(client.approvalHistory.suffix(50).reversed()) { entry in
                    ApprovalHistoryRow(entry: entry)
                }
            }
            .listStyle(.plain)
            .navigationTitle("History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { showHistory = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: - Queue selection

    private var currentIndex: Int {
        guard let selection, let idx = decisions.firstIndex(where: { $0.id == selection }) else { return 0 }
        return idx
    }

    /// The id to land on after the item at `id` is resolved — the next one, or
    /// the previous when it was last, or nil when the queue empties. Computed
    /// against the queue *before* the resolving mutation removes the item.
    private func nextSelection(after id: String) -> String? {
        let ids = decisions.map(\.id)
        guard let idx = ids.firstIndex(of: id) else { return ids.first }
        if idx + 1 < ids.count { return ids[idx + 1] }
        if idx > 0 { return ids[idx - 1] }
        return nil
    }

    /// Keep `selection` pointing at a real page as the queue changes.
    private func normalizeSelection() {
        let ids = decisions.map(\.id)
        if let selection, ids.contains(selection) { return }
        selection = ids.first
    }

    // MARK: - Actions (preserved behaviour)

    private func respondToPrompt(_ prompt: RemoteInteractivePrompt, option: RemoteInteractivePromptOption, decisionID: String) {
        if option.isDestructive {
            // Defer advancing until the confirmation alert is accepted.
            pendingPromptConfirmation = PendingInteractivePromptConfirmation(
                promptID: prompt.id,
                decisionID: decisionID,
                promptText: prompt.prompt,
                toolName: prompt.toolName,
                tabTitle: prompt.tabTitle,
                option: option
            )
        } else if client.respondToInteractivePrompt(promptID: prompt.id, optionID: option.id) {
            let next = nextSelection(after: decisionID)
            resetCustomPromptState(for: prompt.id)
            hapticTrigger.toggle()
            selection = next
        }
    }

    private func sendCustomReply(for prompt: RemoteInteractivePrompt, decisionID: String) {
        let text = customText(for: prompt.id)
        if client.respondToInteractivePrompt(promptID: prompt.id, customText: text) {
            let next = nextSelection(after: decisionID)
            resetCustomPromptState(for: prompt.id)
            hapticTrigger.toggle()
            selection = next
        }
    }

    private func confirmPendingPrompt() {
        guard let confirmation = pendingPromptConfirmation else { return }
        let next = nextSelection(after: confirmation.decisionID)
        if client.respondToInteractivePrompt(promptID: confirmation.promptID, optionID: confirmation.option.id) {
            resetCustomPromptState(for: confirmation.promptID)
            hapticTrigger.toggle()
            selection = next
        }
        pendingPromptConfirmation = nil
    }

    private var pendingPromptConfirmationBinding: Binding<Bool> {
        Binding(
            get: { pendingPromptConfirmation != nil },
            set: { isPresented in
                if !isPresented { pendingPromptConfirmation = nil }
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

/// One item in the merged decision queue.
private enum PendingDecision: Identifiable {
    case approval(ApprovalRequest)
    case prompt(RemoteInteractivePrompt)

    var id: String {
        switch self {
        case let .approval(request): "approval:\(request.id)"
        case let .prompt(prompt): "prompt:\(prompt.id)"
        }
    }
}

private struct PendingInteractivePromptConfirmation: Equatable {
    let promptID: String
    let decisionID: String
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

// MARK: - Queue indicator

private struct QueueIndicator: View {
    let index: Int
    let count: Int

    var body: some View {
        VStack(spacing: 3) {
            Text("Decision \(index + 1) of \(count)")
                .font(.footnote.weight(.semibold))
            if count > 1 {
                HStack(spacing: 5) {
                    ForEach(0 ..< count, id: \.self) { dot in
                        Circle()
                            .fill(dot == index ? Color.accentColor : Color.secondary.opacity(0.35))
                            .frame(width: 6, height: 6)
                    }
                }
            }
        }
    }
}

// MARK: - Severity styling

extension ApprovalSeverity {
    /// The rail / accent colour. Standard stays muted so ordinary commands don't
    /// cry wolf; protected and destructive escalate through the semantic palette.
    var accent: Color {
        switch self {
        case .standard: Color(.systemBlue)
        case .protected: .orange
        case .destructive: .red
        }
    }

    var heroIcon: String {
        switch self {
        case .standard: "terminal.fill"
        case .protected: "lock.shield.fill"
        case .destructive: "exclamationmark.octagon.fill"
        }
    }

    var heroTitle: String {
        switch self {
        case .standard: "Command approval"
        case .protected: "Protected action"
        case .destructive: "Destructive"
        }
    }

    var consequence: String {
        switch self {
        case .standard: "Review the command, then allow or deny."
        case .protected: "Targets a Chau7-managed process or path."
        case .destructive: "Rewrites or deletes state — this can't be undone."
        }
    }

    /// Tinted header band. Standard stays neutral (no alarm); protected and
    /// destructive wash the header in their semantic hue.
    var headerBackground: Color {
        switch self {
        case .standard: Color(.secondarySystemGroupedBackground)
        case .protected: Color.orange.opacity(0.13)
        case .destructive: Color.red.opacity(0.13)
        }
    }

    /// The irreversible tier promotes Allow to a deliberate press-and-hold.
    var requiresHoldToAllow: Bool { self == .destructive }
}

// MARK: - Shared card pieces

/// The tinted top band that states what kind of decision this is and its
/// consequence in a line, before any reading.
private struct DecisionHeader: View {
    let icon: String
    let title: String
    let subtitle: String
    let tint: Color
    let background: Color
    var onDismiss: (() -> Void)?

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 42, height: 42)
                .background(tint, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.bold))
                    .textCase(.uppercase)
                    .foregroundStyle(tint)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss prompt")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background)
    }
}

/// "Who is asking, from where, and when" — an agent glyph, a name, a monospaced
/// repo · branch line, and a relative timestamp.
private struct CardIdentityRow: View {
    let toolName: String?
    let location: String?
    let timestamp: Date

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: Self.icon(for: toolName))
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 36, height: 36)
                .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
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

    static func location(project: String?, branch: String?, tab: String?) -> String? {
        let parts = [project, branch].compactMap { $0?.isEmpty == false ? $0 : nil }
        if !parts.isEmpty { return parts.joined(separator: " · ") }
        return tab
    }
}

/// The hero: the command rendered as a real terminal line — prompt glyph,
/// monospace, copyable — sized up so it reads as the centrepiece.
private struct CommandBlock: View {
    let command: String
    let accent: Color

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text("$")
                .font(.system(.title3, design: .monospaced).weight(.bold))
                .foregroundStyle(accent)
            Text(command)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                UIPasteboard.general.string = command
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Copy command")
        }
        .padding(16)
        .background(Color(.tertiarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// Inline, always-readable key/value context — directory, rationale, recent
/// command. Full-screen has the room, so nothing hides behind a disclosure.
private struct ContextList: View {
    let rows: [Row]

    struct Row: Identifiable {
        let icon: String
        let label: String
        let value: String
        var isProse = false
        var id: String { label }
    }

    var body: some View {
        if !rows.isEmpty {
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { offset, row in
                    if offset > 0 { Divider().padding(.leading, 40) }
                    HStack(alignment: .top, spacing: 10) {
                        Label(row.label, systemImage: row.icon)
                            .labelStyle(.iconOnly)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.label)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                            Text(row.value)
                                .font(row.isProse ? .caption : .system(.caption, design: .monospaced))
                                .foregroundStyle(row.isProse ? .secondary : .primary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 11)
                    .padding(.horizontal, 14)
                }
            }
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            GeometryReader { geo in
                Rectangle()
                    .fill(.white.opacity(0.28))
                    .frame(width: geo.size.width * progress)
            }
            VStack(spacing: 1) {
                Text(title).font(.headline)
                Text(subtitle).font(.caption2).opacity(0.9)
            }
            .foregroundStyle(.white)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 54)
        .background(tint, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        .onLongPressGesture(minimumDuration: 0.9, pressing: { pressing in
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
            Text(label).font(.headline)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 54)
        .foregroundStyle(allow ? Color.green : Color.red)
        .background((allow ? Color.green : Color.red).opacity(0.12), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
    }
}

/// "Read more" affordance that jumps from a card to the live terminal tab.
private struct GoToTabButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("View live in terminal", systemImage: "arrow.up.forward.app")
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .accessibilityHint("Opens the terminal tab for this request so you can read the full context.")
    }
}

// MARK: - Full-screen approval card

struct FullScreenApprovalCard: View {
    let request: ApprovalRequest
    var onGoToTab: (() -> Void)?
    let onRespond: (Bool) -> Void

    var body: some View {
        VStack(spacing: 0) {
            DecisionHeader(
                icon: request.severity.heroIcon,
                title: request.severity.heroTitle,
                subtitle: request.severity.consequence,
                tint: request.severity.accent,
                background: request.severity.headerBackground
            )

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    CardIdentityRow(
                        toolName: request.toolName,
                        location: CardIdentityRow.location(project: request.projectName, branch: request.branchName, tab: request.tabTitle),
                        timestamp: request.timestamp
                    )

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Wants to run")
                            .font(.caption.weight(.semibold))
                            .textCase(.uppercase)
                            .foregroundStyle(.tertiary)
                        CommandBlock(command: request.command, accent: request.severity.accent)
                        if request.flaggedCommand != request.command {
                            Label("Flagged as \(request.flaggedCommand)", systemImage: "flag.fill")
                                .font(.caption)
                                .foregroundStyle(request.severity.accent)
                        }
                    }

                    ContextList(rows: contextRows)

                    if let onGoToTab {
                        GoToTabButton(action: onGoToTab)
                    }
                }
                .padding(20)
            }

            actionBar
        }
    }

    private var actionBar: some View {
        VStack(spacing: 0) {
            Divider()
            Group {
                if request.responseState.isBusy {
                    InFlightBanner(
                        label: request.responseState.actionLabel ?? "Sending…",
                        allow: request.responseState.isAllowIntent ?? true
                    )
                } else {
                    HStack(spacing: 11) {
                        Button(role: .destructive) { onRespond(false) } label: {
                            Text("Deny").font(.headline).frame(maxWidth: .infinity, minHeight: 54)
                        }
                        .buttonStyle(.bordered)
                        .tint(.red)
                        .frame(maxWidth: 130)

                        if request.severity.requiresHoldToAllow {
                            HoldToConfirmButton(title: "Hold to allow", subtitle: "irreversible", tint: .green, action: { onRespond(true) })
                        } else {
                            Button { onRespond(true) } label: {
                                Text("Allow").font(.headline).frame(maxWidth: .infinity, minHeight: 54)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.green)
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 8)
        }
        .background(Color(.systemBackground))
    }

    private var contextRows: [ContextList.Row] {
        var rows: [ContextList.Row] = []
        if let dir = request.currentDirectory, !dir.isEmpty {
            rows.append(.init(icon: "folder", label: "Directory", value: dir))
        }
        if let note = request.contextNote, !note.isEmpty {
            rows.append(.init(icon: "info.circle", label: "Why", value: note, isProse: true))
        }
        if let recent = request.recentCommand, !recent.isEmpty, recent != request.command {
            rows.append(.init(icon: "clock.arrow.circlepath", label: "Recent command", value: recent))
        }
        return rows
    }
}

// MARK: - Full-screen prompt card

struct FullScreenPromptCard: View {
    let prompt: RemoteInteractivePrompt
    @Binding var customText: String
    let onRespond: (RemoteInteractivePromptOption) -> Void
    let onSendCustom: () -> Void
    let onDismiss: () -> Void
    let onGoToTab: () -> Void
    /// Multi-select prompts only: toggle one option in the TUI (no submit).
    var onToggleOption: (RemoteInteractivePromptOption) -> Void = { _ in }
    /// Multi-select prompts only: confirm the current selection with Enter.
    var onSubmitMultiSelect: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            DecisionHeader(
                icon: "text.bubble.fill",
                title: "Interactive prompt",
                subtitle: "\(prompt.toolName) is waiting on your choice.",
                tint: .accentColor,
                background: Color.accentColor.opacity(0.12),
                onDismiss: onDismiss
            )

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    CardIdentityRow(
                        toolName: prompt.toolName,
                        location: CardIdentityRow.location(project: prompt.projectName, branch: prompt.branchName, tab: prompt.tabTitle),
                        timestamp: prompt.detectedAt
                    )

                    Text(prompt.prompt)
                        .font(.title3.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)

                    ContextList(rows: contextRows)

                    if prompt.isMultiSelect == true {
                        MultiSelectPromptOptions(
                            options: prompt.options,
                            onToggle: onToggleOption,
                            onSubmit: onSubmitMultiSelect
                        )
                    } else {
                        VStack(spacing: 9) {
                            ForEach(prompt.options) { option in
                                PromptOptionButton(option: option) { onRespond(option) }
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Custom reply").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        HStack(spacing: 8) {
                            TextField("Escape prompt and send text", text: $customText, axis: .vertical)
                                .font(.system(.callout, design: .monospaced))
                                .lineLimit(1 ... 4)
                                .padding(.horizontal, 12).padding(.vertical, 10)
                                .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                            Button("Send", action: onSendCustom)
                                .font(.callout.weight(.semibold))
                                .buttonStyle(.borderedProminent)
                                .disabled(customText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }

                    GoToTabButton(action: onGoToTab)
                }
                .padding(20)
            }
        }
    }

    private var contextRows: [ContextList.Row] {
        var rows: [ContextList.Row] = []
        if let dir = prompt.currentDirectory, !dir.isEmpty {
            rows.append(.init(icon: "folder", label: "Directory", value: dir))
        }
        if let detail = prompt.detail, !detail.isEmpty {
            rows.append(.init(icon: "text.alignleft", label: "Prompt context", value: detail, isProse: true))
        }
        return rows
    }
}

// MARK: - Multi-select options

/// Checkbox-style option list for multi-select prompts. Each tap sends the
/// option's toggle digit to the TUI immediately (the terminal is the source
/// of truth for selection state — the local checkmarks mirror the taps made
/// FROM THIS CARD and can drift if someone also toggles on the Mac), and the
/// submit button confirms with a bare Enter.
private struct MultiSelectPromptOptions: View {
    let options: [RemoteInteractivePromptOption]
    let onToggle: (RemoteInteractivePromptOption) -> Void
    let onSubmit: () -> Void

    @State private var toggledOptionIDs: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Multi-select — toggles apply live in the terminal")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            ForEach(options) { option in
                Button {
                    if toggledOptionIDs.contains(option.id) {
                        toggledOptionIDs.remove(option.id)
                    } else {
                        toggledOptionIDs.insert(option.id)
                    }
                    onToggle(option)
                } label: {
                    HStack(alignment: .center, spacing: 12) {
                        Image(systemName: toggledOptionIDs.contains(option.id) ? "checkmark.square.fill" : "square")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(toggledOptionIDs.contains(option.id) ? Color.accentColor : .secondary)
                        Text(option.label)
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 8)
                        if option.isDestructive {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.callout.weight(.semibold))
                                .foregroundStyle(.orange)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.secondarySystemGroupedBackground))
                    .overlay {
                        RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                }
                .buttonStyle(.plain)
            }

            Button(action: onSubmit) {
                Label("Submit selection", systemImage: "arrow.turn.down.left")
                    .font(.callout.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 4)
        }
    }
}

// MARK: - Prompt option button

private struct PromptOptionButton: View {
    let option: RemoteInteractivePromptOption
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 12) {
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
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(option.isDestructive ? .orange : .secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(backgroundColor)
            .overlay {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .stroke(borderColor, lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var trimmedResponse: String {
        option.response.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var backgroundColor: Color {
        option.isDestructive ? Color.orange.opacity(0.10) : Color(.secondarySystemGroupedBackground)
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
