import Chau7Core
import SwiftUI

/// Main terminal tab: connection status bar, tab selector, output display,
/// keyboard shortcut bar (esc, tab, ^C, ^D, arrows), and text input field.
/// Supports two rendering modes: rich grid renderer (default) and plain text.
struct TerminalView: View {
    var client: RemoteClient
    @Binding var isPairingPresented: Bool
    /// Opens the connection settings tab; invoked on a long-press of the
    /// connection status symbol in the tabs bar.
    var onOpenConnectionSettings: () -> Void = {}

    @AppStorage(AppSettings.holdToSendKey) private var holdToSend = AppSettings.holdToSendDefault
    @AppStorage(AppSettings.renderANSIKey) private var renderANSI = AppSettings.renderANSIDefault
    @AppStorage(AppSettings.experimentalTerminalRendererKey)
    private var experimentalTerminalRenderer = AppSettings.experimentalTerminalRendererDefault
    @AppStorage(AppSettings.showKeyboardBarKey) private var showKeyboardBar = AppSettings.showKeyboardBarDefault
    @AppStorage(AppSettings.terminalFontSizeKey) private var terminalFontSize = AppSettings.terminalFontSizeDefault
    @AppStorage(AppSettings.colorSchemeNameKey) private var colorSchemeName = AppSettings.colorSchemeNameDefault

    @State private var inputText = ""
    /// The user hid an auto-surfaced key row for the current waiting episode.
    /// Reset when the active tab's need signal rises again, so the row
    /// re-appears for the NEXT menu without permanently re-pinning itself.
    @State private var autoKeysDismissed = false
    @State private var sendCount = 0
    @State private var justSent = false
    @State private var pendingProtectedSend: ProtectedRemoteSend?
    @State private var textAwayFromBottom = false
    @State private var scrollToBottomToken = 0
    @State private var isErrorExpanded = false
    @FocusState private var inputFocused: Bool

    var body: some View {
        NavigationStack {
            Group {
                if client.pairingInfo == nil {
                    UnpairedTerminalView(isPairingPresented: $isPairingPresented)
                } else {
                    pairedContent
                }
            }
            .navigationBarTitleDisplayMode(.inline)
        }
        .alert("Protected Remote Action", isPresented: protectedSendBinding) {
            Button("Cancel", role: .cancel) {
                if let pendingProtectedSend {
                    inputText = pendingProtectedSend.text
                }
                pendingProtectedSend = nil
            }
            Button("Request Approval", role: .destructive) {
                guard let pendingProtectedSend else { return }
                client.recordProtectedActionSubmission(
                    text: pendingProtectedSend.text,
                    flaggedAction: pendingProtectedSend.flaggedAction
                )
                if client.sendInput(pendingProtectedSend.text, appendNewline: true) {
                    inputText = ""
                    markSent()
                    self.pendingProtectedSend = nil
                } else {
                    inputText = pendingProtectedSend.text
                    self.pendingProtectedSend = nil
                }
            }
        } message: {
            Text(pendingProtectedSend?.message ?? "")
        }
    }

    private var pairedContent: some View {
        VStack(spacing: 0) {
            statusBar
            tabsBar
            outputView
            // One in-flow key row, keyboard up or down. It deliberately does
            // NOT use a keyboard-accessory toolbar: the system accessory
            // rendered over the input bar and fought keyboard avoidance,
            // while an in-flow row always sits cleanly above the input.
            if showsPinnedControlKeys {
                controlKeyRow
            }
            inputBar
        }
        // The row also appears without a user gesture (auto-surface when the
        // active tab waits on a menu), so animate on the resolved value rather
        // than relying on the toggle button's withAnimation.
        .animation(.easeInOut(duration: 0.15), value: showsPinnedControlKeys)
        .onChange(of: client.activeTabNeedsMenuKeys) { _, needed in
            if needed { autoKeysDismissed = false }
        }
    }

    // MARK: - Status

    /// Compact, tappable connection indicator that sits at the start of the
    /// tabs bar. Tap toggles connect/disconnect; long-press opens connection
    /// settings. Replaces the old full-width status header + connect button.
    private var connectionStatusSymbol: some View {
        ConnectionStatusSymbol(phase: client.connectionPhase)
            .frame(width: 34, height: 34)
            .contentShape(Rectangle())
            .onTapGesture { toggleConnection() }
            .onLongPressGesture { onOpenConnectionSettings() }
            .disabled(!canToggleConnection)
            .accessibilityLabel(connectionAccessibilityLabel)
            .accessibilityHint("Touch and hold to open connection settings.")
            .accessibilityAddTraits(.isButton)
    }

    /// Whether the symbol tap can do anything right now. Mirrors the old
    /// connect button guard: never attempt connect without pairing info.
    private var canToggleConnection: Bool {
        switch client.connectionPhase {
        case .connected, .connecting:
            return true
        case .disconnected, .warning:
            return client.pairingInfo != nil
        }
    }

    private func toggleConnection() {
        switch client.connectionPhase {
        case .connected, .connecting:
            client.disconnect()
        case .disconnected, .warning:
            guard client.pairingInfo != nil else { return }
            client.connect()
        }
    }

    private var connectionAccessibilityLabel: String {
        switch client.connectionPhase {
        case .connected:
            return "Connected. Double-tap to disconnect."
        case .connecting:
            return "Connecting. Double-tap to stop."
        case .warning, .disconnected:
            return "Disconnected. Double-tap to connect."
        }
    }

    /// Only surfaces when there's a connection error to report — the live status
    /// itself now lives in the navigation bar, so this stays out of the way
    /// until something is actually wrong.
    @ViewBuilder
    private var statusBar: some View {
        if let error = client.lastError, !error.isEmpty {
            VStack(spacing: 0) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { isErrorExpanded.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                        Text("Connection issue")
                        Image(systemName: isErrorExpanded ? "chevron.up" : "chevron.down")
                            .font(.caption2)
                        Spacer()
                    }
                    .font(.caption)
                    .foregroundStyle(.red)
                }
                .accessibilityLabel("Connection issue. Tap for details.")
                .padding(.horizontal)
                .padding(.vertical, 6)

                if isErrorExpanded {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        HStack(spacing: 10) {
                            if !client.isConnected {
                                Button {
                                    client.lastError = nil
                                    isErrorExpanded = false
                                    client.connect()
                                } label: {
                                    Label("Retry", systemImage: "arrow.clockwise")
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                            Button("Dismiss") {
                                client.lastError = nil
                                isErrorExpanded = false
                            }
                            .buttonStyle(.borderless)
                            .controlSize(.small)
                            Spacer()
                        }
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 8)
                }
            }
            .background(Color(UIColor.secondarySystemBackground))
        }
    }

    // MARK: - Tabs

    private var tabsBar: some View {
        HStack(spacing: 10) {
            connectionStatusSymbol

            Menu {
                let groups = repoTabGroups
                if groups.isEmpty {
                    Text("No remote tabs available yet")
                } else if groups.count == 1 {
                    // A single group's header (often just "Other") is noise —
                    // keep the flat list.
                    tabMenuButtons(for: groups[0].tabs)
                } else {
                    // Repo names render as section titles — the system menu
                    // styles them smaller and secondary, visually distinct
                    // from the tab entries beneath them.
                    ForEach(groups) { group in
                        Section(group.title) {
                            tabMenuButtons(for: group.tabs)
                        }
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    if let color = activeTabStatusColor {
                        Circle()
                            .fill(color)
                            .frame(width: 7, height: 7)
                            .accessibilityHidden(true)
                    }
                    Text(activeTabMenuLabel)
                        .font(.system(.footnote, design: .rounded).weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(UIColor.secondarySystemBackground))
                .clipShape(Capsule(style: .continuous))
            }
            .accessibilityLabel("Active session: \(activeTabMenuLabel)\(activeTabStatusDescription.map { ", \($0)" } ?? "")")

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    if let projectName = activeProjectName {
                        metadataChip(projectName, systemImage: "shippingbox")
                    }
                    if let branchName = activeBranchName {
                        metadataChip(branchName, systemImage: "arrow.triangle.branch")
                    }
                    if let toolName = activeToolName {
                        metadataChip(toolName, systemImage: "sparkles")
                    }
                    if activeTabIsMCPControlled {
                        metadataChip("MCP", systemImage: "face.dashed.fill")
                    }
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color(UIColor.systemBackground))
    }

    private struct RepoTabGroup: Identifiable {
        let id: String
        let title: String
        let tabs: [RemoteTab]
    }

    /// Tabs grouped by repo (projectName) and alphabetized within each group.
    /// Tabs without a repo collect under "Other", always last.
    ///
    /// Groups are ordered by name rather than by first appearance in
    /// `client.tabs`. A SwiftUI `Menu` re-runs its content closure whenever the
    /// state it reads changes — including while presented — and activity
    /// re-sends reorder `client.tabs`. Sorting both levels makes the rendered
    /// identity sequence independent of that activity churn, so an open menu
    /// keeps its scroll position while still reflecting real additions and
    /// removals.
    private var repoTabGroups: [RepoTabGroup] {
        let fallback = "Other"
        var tabsByRepo: [String: [RemoteTab]] = [:]
        for tab in client.tabs {
            let name = tab.projectName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            tabsByRepo[name.isEmpty ? fallback : name, default: []].append(tab)
        }
        let order = tabsByRepo.keys.sorted { lhs, rhs in
            // "Other" is a catch-all, not a repo — it sorts last regardless.
            if lhs == fallback { return false }
            if rhs == fallback { return true }
            return lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
        }
        return order.map {
            RepoTabGroup(
                id: $0,
                title: $0,
                tabs: RemoteTabOrdering.alphabetically(tabsByRepo[$0] ?? [])
            )
        }
    }

    private func tabMenuButtons(for tabs: [RemoteTab]) -> some View {
        ForEach(tabs) { tab in
            Button {
                DiagnosticsLog.shared.info(.tab, "Selected remote tab", [
                    "tab_id": String(tab.tabID),
                    "title": tab.title
                ])
                client.switchTab(tab.tabID)
            } label: {
                Label {
                    Text(tabMenuTitle(for: tab))
                        .lineLimit(1)
                } icon: {
                    tabMenuIcon(for: tab)
                }
            }
        }
    }

    @ViewBuilder
    private func tabMenuIcon(for tab: RemoteTab) -> some View {
        if tab.tabID == client.activeTabID {
            Image(systemName: "checkmark")
        } else if let symbol = statusSymbol(for: tab) {
            Image(systemName: symbol)
        } else if tab.isMCPControlled {
            Image(systemName: "face.dashed.fill")
        }
    }

    private func tabMenuTitle(for tab: RemoteTab) -> String {
        guard let activity = client.liveActivityState, activity.tabID == tab.tabID,
              let label = statusWord(for: activity.status) else {
            return tab.title
        }
        return "\(tab.title) · \(label)"
    }

    // MARK: - Output

    private var outputView: some View {
        Group {
            if experimentalTerminalRenderer {
                RemoteTerminalRendererView(client: client)
            } else {
                RemoteTerminalTextView(
                    text: renderANSI ? client.outputText : client.strippedOutputText,
                    fontSize: CGFloat(terminalFontSize),
                    colorScheme: AppSettings.colorScheme(named: colorSchemeName),
                    isAwayFromBottom: $textAwayFromBottom,
                    scrollToBottomToken: scrollToBottomToken
                )
            }
        }
        .overlay(alignment: .bottom) {
            if justSent {
                sentConfirmationToast
                    .padding(.bottom, 12)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if isAwayFromBottom {
                jumpToLatestButton
                    .padding(.trailing, 14)
                    .padding(.bottom, 14)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isAwayFromBottom)
        .animation(.easeInOut(duration: 0.2), value: justSent)
    }

    private var jumpToLatestButton: some View {
        Button(action: jumpToLatest) {
            Image(systemName: "arrow.down")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(Color.accentColor, in: Circle())
                .shadow(radius: 4, y: 2)
        }
        .accessibilityLabel("Jump to latest output")
    }

    private var sentConfirmationToast: some View {
        Label("Sent", systemImage: "checkmark.circle.fill")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(.green.opacity(0.92), in: Capsule())
            .accessibilityHidden(true)
    }

    // MARK: - Control Keys

    /// The pinned fixed row shows when the user opted in via the toggle OR the
    /// active tab is waiting on a menu/input (auto-surface — the signal only
    /// ever adds visibility), AND the keyboard is down — otherwise the
    /// accessory bar covers typing.
    /// Visible when pinned by the user OR auto-surfaced because the active
    /// tab waits on a menu (unless the user dismissed it for this episode).
    /// The keyboard button is authoritative: it always toggles this off/on.
    private var showsPinnedControlKeys: Bool {
        controlKeyRowRequested && client.canSendInput
    }

    private var controlKeyRowRequested: Bool {
        showKeyboardBar || (client.activeTabNeedsMenuKeys && !autoKeysDismissed)
    }

    /// Horizontally scrolling row of terminal control keys, shown as one
    /// in-flow row above the input bar. The `maxWidth: .infinity` lets the
    /// ScrollView span the
    /// full width when hosted inside `ToolbarItemGroup(placement: .keyboard)`,
    /// which otherwise collapses it to its intrinsic (content) width.
    private var controlKeyRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                TermKey("esc", labelText: "Escape", send: "\u{1B}", semantic: .init(key: "escape"), client: client)
                // Bare CR with no body takes the Mac's `.enterKey` submit path
                // with zero delay — it behaves like a real Enter keypress, which
                // is what TUI selection menus need to confirm a highlighted row.
                TermKey("\u{23CE}", labelText: "Return", send: "\r", semantic: .init(key: "enter"), client: client)
                TermKey("tab", labelText: "Tab", send: "\t", semantic: .init(key: "tab"), client: client)
                TermKey("\u{21E7}\u{21E5}", labelText: "Shift Tab", send: "\u{1B}[Z", semantic: .init(key: "tab", modifiers: ["shift"]), client: client)
                TermKey("^C", labelText: "Control C", send: "\u{03}", semantic: .init(key: "c", modifiers: ["control"]), client: client)
                TermKey("^D", labelText: "Control D", send: "\u{04}", semantic: .init(key: "d", modifiers: ["control"]), client: client)
                TermKey("^Z", labelText: "Control Z", send: "\u{1A}", semantic: .init(key: "z", modifiers: ["control"]), client: client)
                TermKey("^L", labelText: "Control L", send: "\u{0C}", semantic: .init(key: "l", modifiers: ["control"]), client: client)
                Divider().frame(height: 24).padding(.horizontal, 4)
                TermKey("\u{2191}", labelText: "Up arrow", send: "\u{1B}[A", semantic: .init(key: "up"), client: client)
                TermKey("\u{2193}", labelText: "Down arrow", send: "\u{1B}[B", semantic: .init(key: "down"), client: client)
                TermKey("\u{2190}", labelText: "Left arrow", send: "\u{1B}[D", semantic: .init(key: "left"), client: client)
                TermKey("\u{2192}", labelText: "Right arrow", send: "\u{1B}[C", semantic: .init(key: "right"), client: client)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
        .frame(maxWidth: .infinity)
        .background(Color(UIColor.tertiarySystemBackground))
    }

    // MARK: - Input Bar

    private var inputBar: some View {
        HStack(spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { toggleControlKeyRow() }
            } label: {
                Image(systemName: controlKeyRowRequested ? "keyboard.chevron.compact.down" : "keyboard")
                    .font(.title3)
                    .frame(width: 32, height: 32)
            }
            .disabled(!client.canSendInput)
            .accessibilityLabel(controlKeyRowRequested ? "Hide control keys" : "Show control keys")

            TextField("Input", text: $inputText, axis: .vertical)
                .font(.system(.body, design: .monospaced))
                .lineLimit(1...4)
                .textFieldStyle(.roundedBorder)
                .submitLabel(.send)
                .focused($inputFocused)
                .onSubmit { if !holdToSend { submitInput(trigger: "submit_label") } }
                .onChange(of: inputText) { oldValue, newValue in
                    handleInputChange(from: oldValue, to: newValue)
                }

            sendButton
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(UIColor.secondarySystemBackground))
    }

    /// Hide always wins over any reason the row is visible: hiding an
    /// auto-surfaced row dismisses it for this waiting episode (it returns
    /// for the next menu); hiding a pinned row unpins it. Showing pins it.
    private func toggleControlKeyRow() {
        if controlKeyRowRequested {
            showKeyboardBar = false
            autoKeysDismissed = true
        } else {
            showKeyboardBar = true
        }
    }

    @ViewBuilder
    private var sendButton: some View {
        if holdToSend {
            HoldToSendButton(isEnabled: !inputText.isEmpty && client.canSendInput) {
                submitInput()
            }
            .sensoryFeedback(.impact(flexibility: .solid, intensity: 0.5), trigger: sendCount)
        } else {
            Button(action: { submitInput() }) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
                    .frame(width: 44, height: 44)
            }
            .sensoryFeedback(.impact(flexibility: .solid, intensity: 0.5), trigger: sendCount)
            .disabled(inputText.isEmpty || !client.canSendInput)
            .accessibilityLabel("Send")
        }
    }

    /// Logs each keystroke delta and — for a multiline (`axis: .vertical`)
    /// field where the Return key inserts a newline instead of firing
    /// `onSubmit` — treats a trailing newline as a send when hold-to-send is
    /// off. This is the core fix for "input text isn't actually sent".
    private func handleInputChange(from oldValue: String, to newValue: String) {
        logKeystrokeDelta(from: oldValue, to: newValue)

        guard !holdToSend, newValue.hasSuffix("\n") else { return }
        // Strip every trailing newline the Return key inserted, then submit.
        var trimmed = newValue
        while trimmed.hasSuffix("\n") { trimmed.removeLast() }
        inputText = trimmed
        guard !trimmed.isEmpty else { return }
        submitInput(trigger: "return_key")
    }

    private func logKeystrokeDelta(from oldValue: String, to newValue: String) {
        guard oldValue != newValue else { return }
        let commonPrefix = oldValue.commonPrefix(with: newValue)
        let prefixCount = commonPrefix.count
        if newValue.count > oldValue.count {
            let inserted = String(newValue.dropFirst(prefixCount))
            DiagnosticsLog.shared.keystroke(inserted, field: "terminal_input", extra: ["op": "insert"])
        } else {
            let removedCount = oldValue.count - newValue.count
            DiagnosticsLog.shared.keystroke(
                "<delete \(removedCount)>",
                field: "terminal_input",
                extra: ["op": "delete"]
            )
        }
    }

    private func submitInput(trigger: String = "send_button") {
        let text = inputText
        guard !text.isEmpty else { return }

        DiagnosticsLog.shared.info(.input, "Submit requested", [
            "trigger": trigger,
            "bytes": String(text.utf8.count),
            "tab_id": String(client.activeTabID),
            "can_send": client.canSendInput ? "true" : "false"
        ])

        if let flaggedAction = client.flaggedProtectedAction(for: text) {
            client.recordProtectedActionPrompt(text: text, flaggedAction: flaggedAction)
            DiagnosticsLog.shared.warn(.input, "Submit held for protected action", ["action": flaggedAction])
            pendingProtectedSend = ProtectedRemoteSend(
                text: text,
                flaggedAction: flaggedAction,
                message: "\(flaggedAction) requires a second approval before it is forwarded to your Mac."
            )
            return
        }

        // A digit answering an on-screen selection menu acts on the keypress
        // itself; the terminator would arrive as a separate delayed Enter and
        // land on whatever the TUI renders next. Drop it for those sends.
        let suppressTerminator = RemoteMenuKeyHeuristics.shouldSuppressSubmitTerminator(
            text: text,
            hasPendingPromptForActiveTab: client.pendingInteractivePrompts
                .contains { $0.tabID == client.activeTabID }
        )
        if suppressTerminator {
            DiagnosticsLog.shared.info(.input, "Submit terminator suppressed for menu digit", [
                "trigger": trigger,
                "tab_id": String(client.activeTabID)
            ])
        }

        // Send always submits. The old "Append Newline" toggle could silently
        // turn every send into an inert text drop (body lands in the
        // composer, nothing executes) — a footgun, not a feature. The only
        // terminator suppression left is the deliberate menu-digit case.
        guard client.sendInput(text, appendNewline: !suppressTerminator) else {
            DiagnosticsLog.shared.error(.input, "Submit blocked", [
                "trigger": trigger,
                "reason": client.lastError ?? "unknown"
            ])
            return
        }
        DiagnosticsLog.shared.info(.input, "Input sent", ["bytes": String(text.utf8.count)])
        inputText = ""
        markSent()
    }

    private func markSent() {
        sendCount += 1
        scrollToBottomToken += 1
        withAnimation { justSent = true }
        Task {
            try? await Task.sleep(for: .milliseconds(900))
            withAnimation { justSent = false }
        }
    }

    private func jumpToLatest() {
        if showsGridRenderer {
            client.terminalRenderer.scrollActive(to: 0)
        } else {
            scrollToBottomToken += 1
        }
    }

    private var showsGridRenderer: Bool {
        experimentalTerminalRenderer
            && client.terminalRenderer.isAvailable
            && client.terminalRenderer.renderState != nil
    }

    private var isAwayFromBottom: Bool {
        if showsGridRenderer {
            return (client.terminalRenderer.renderState?.displayOffset ?? 0) > 0
        }
        return textAwayFromBottom
    }

    private var activeTabMenuLabel: String {
        guard let activeTab else { return "No remote tabs" }
        return activeTab.title
    }

    private var activeTab: RemoteTab? {
        client.tabs.first(where: { $0.tabID == client.activeTabID })
    }

    private var activeTabIsMCPControlled: Bool {
        activeTab?.isMCPControlled ?? false
    }

    private var activeToolName: String? {
        guard client.liveActivityState?.tabID == client.activeTabID else { return nil }
        return client.liveActivityState?.toolName
    }

    private var activeProjectName: String? {
        let activityProject = client.liveActivityState?.tabID == client.activeTabID ? client.liveActivityState?.projectName : nil
        return activityProject ?? activeTab?.projectName
    }

    private var activeBranchName: String? {
        activeTab?.branchName
    }

    private var activeTabStatusColor: Color? {
        guard let activity = client.liveActivityState, activity.tabID == client.activeTabID else { return nil }
        return statusColor(for: activity.status)
    }

    private var activeTabStatusDescription: String? {
        guard let activity = client.liveActivityState, activity.tabID == client.activeTabID else { return nil }
        return statusWord(for: activity.status)
    }

    private func statusColor(for status: RemoteActivityStatus) -> Color {
        switch status {
        case .approvalRequired, .waitingInput: return .orange
        case .failed: return .red
        case .completed: return .green
        case .running: return .blue
        case .idle: return .secondary
        }
    }

    private func statusSymbol(for tab: RemoteTab) -> String? {
        guard let activity = client.liveActivityState, activity.tabID == tab.tabID else { return nil }
        switch activity.status {
        case .approvalRequired: return "lock.shield.fill"
        case .waitingInput: return "exclamationmark.bubble.fill"
        case .failed: return "xmark.octagon.fill"
        case .completed: return "checkmark.circle.fill"
        case .running: return "circle.fill"
        case .idle: return nil
        }
    }

    private func statusWord(for status: RemoteActivityStatus) -> String? {
        switch status {
        case .approvalRequired: return "needs approval"
        case .waitingInput: return "waiting"
        case .failed: return "failed"
        case .completed: return "done"
        case .running: return "running"
        case .idle: return nil
        }
    }

    @ViewBuilder
    private func metadataChip(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.system(.caption, design: .rounded).weight(.medium))
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color(UIColor.tertiarySystemBackground))
            .clipShape(Capsule(style: .continuous))
    }

    private var protectedSendBinding: Binding<Bool> {
        Binding(
            get: { pendingProtectedSend != nil },
            set: { isPresented in
                if !isPresented {
                    // Restore input text when dismissed via swipe (not via Cancel/Submit)
                    if let pending = pendingProtectedSend {
                        inputText = pending.text
                    }
                    pendingProtectedSend = nil
                }
            }
        )
    }
}

// MARK: - Unpaired empty state

private struct UnpairedTerminalView: View {
    @Binding var isPairingPresented: Bool

    var body: some View {
        ContentUnavailableView {
            Label("Not Connected", systemImage: "macbook.and.iphone")
        } description: {
            Text("Pair this iPhone with Chau7 running on your Mac to view sessions, respond to approvals, and steer your agents.")
        } actions: {
            Button {
                isPairingPresented = true
            } label: {
                Label("Pair with your Mac", systemImage: "qrcode.viewfinder")
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

// MARK: - Hold to Send

/// A hold-to-send button that fills a progress ring over the hold duration so
/// users understand they must keep holding, and fires once the threshold is met.
struct HoldToSendButton: View {
    let isEnabled: Bool
    let onFire: () -> Void

    @State private var progress: CGFloat = 0
    private let duration = 0.4

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.secondary.opacity(0.25), lineWidth: 3)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Image(systemName: "hand.tap.fill")
                .font(.title3)
                .foregroundStyle(isEnabled ? Color.accentColor : Color.secondary)
        }
        .frame(width: 44, height: 44)
        .contentShape(Circle())
        .opacity(isEnabled ? 1 : 0.5)
        .onLongPressGesture(minimumDuration: duration) {
            guard isEnabled else { return }
            onFire()
        } onPressingChanged: { pressing in
            guard isEnabled else {
                progress = 0
                return
            }
            if pressing {
                withAnimation(.linear(duration: duration)) { progress = 1 }
            } else {
                withAnimation(.easeOut(duration: 0.15)) { progress = 0 }
            }
        }
        .onChange(of: isEnabled) { _, newValue in
            if !newValue { progress = 0 }
        }
        .accessibilityLabel("Hold to send")
        .accessibilityHint("Press and hold to send your input")
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - Subviews

struct TermKey: View {
    let label: String
    let accessibilityName: String
    let sequence: String
    /// Semantic identity of the key (TerminalKeyPress vocabulary). When set
    /// and the Mac advertises key_input, the press goes over the KEY_INPUT
    /// frame so the Mac's encoder resolves application-cursor mode and
    /// control combos; otherwise the raw `sequence` rides .input as before,
    /// which works against every Mac.
    let semanticKey: RemoteKeyInputPayload.Key?
    let client: RemoteClient
    @State private var tapCount = 0

    init(
        _ label: String,
        labelText: String,
        send sequence: String,
        semantic semanticKey: RemoteKeyInputPayload.Key? = nil,
        client: RemoteClient
    ) {
        self.label = label
        self.accessibilityName = labelText
        self.sequence = sequence
        self.semanticKey = semanticKey
        self.client = client
    }

    var body: some View {
        Button {
            tapCount += 1
            DiagnosticsLog.shared.keystroke(label, field: "key_bar", extra: ["op": "control_key"])
            let sent: Bool
            if let semanticKey, client.supportsKeyInput {
                sent = client.sendKeyInput([semanticKey])
            } else {
                sent = client.sendInput(sequence, appendNewline: false)
            }
            if !sent {
                DiagnosticsLog.shared.error(.input, "Control key blocked", [
                    "key": label,
                    "reason": client.lastError ?? "unknown"
                ])
            }
        } label: {
            Text(label)
                .font(.system(size: 13, design: .monospaced))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(minWidth: 44, minHeight: 36)
                .background(Color(UIColor.quaternarySystemFill))
                .cornerRadius(6)
        }
        .sensoryFeedback(.impact(flexibility: .solid, intensity: 0.3), trigger: tapCount)
        .buttonStyle(.plain)
        .disabled(!client.canSendInput)
        .accessibilityLabel(accessibilityName)
    }
}

private struct ProtectedRemoteSend: Identifiable {
    let id = UUID()
    let text: String
    let flaggedAction: String
    let message: String
}

// MARK: - Connection Status Symbol

/// Compact connection indicator with three visual states driven by
/// `RemoteClient.ConnectionPhase`:
/// - `.connected` → green check
/// - `.connecting` → three orange bouncing dots
/// - `.warning` / `.disconnected` → red cross
private struct ConnectionStatusSymbol: View {
    let phase: RemoteClient.ConnectionPhase

    var body: some View {
        switch phase {
        case .connected:
            Image(systemName: "checkmark.circle.fill")
                .font(.headline)
                .foregroundStyle(.green)
        case .connecting:
            BouncingDots()
        case .warning, .disconnected:
            Image(systemName: "xmark.circle.fill")
                .font(.headline)
                .foregroundStyle(.red)
        }
    }
}

/// Three small orange dots that bounce vertically in sequence, phased by index,
/// to signal an in-progress connection. Sized to fit a toolbar/line height.
private struct BouncingDots: View {
    @State private var animating = false

    private let dotSize: CGFloat = 5
    private let bounce: CGFloat = 4

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(.orange)
                    .frame(width: dotSize, height: dotSize)
                    .offset(y: animating ? -bounce : bounce)
                    .animation(
                        .easeInOut(duration: 0.4)
                            .repeatForever(autoreverses: true)
                            .delay(Double(index) * 0.15),
                        value: animating
                    )
            }
        }
        .onAppear { animating = true }
        .accessibilityHidden(true)
    }
}
