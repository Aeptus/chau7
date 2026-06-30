import Chau7Core
import SwiftUI

/// Main terminal tab: connection status bar, tab selector, output display,
/// keyboard shortcut bar (esc, tab, ^C, ^D, arrows), and text input field.
/// Supports two rendering modes: plain text (default) and experimental grid renderer.
struct TerminalView: View {
    var client: RemoteClient
    @Binding var isPairingPresented: Bool

    @AppStorage(AppSettings.holdToSendKey) private var holdToSend = AppSettings.holdToSendDefault
    @AppStorage(AppSettings.appendNewlineKey) private var appendNewline = AppSettings.appendNewlineDefault
    @AppStorage(AppSettings.renderANSIKey) private var renderANSI = AppSettings.renderANSIDefault
    @AppStorage(AppSettings.experimentalTerminalRendererKey)
    private var experimentalTerminalRenderer = AppSettings.experimentalTerminalRendererDefault
    @State private var inputText = ""
    @State private var sendCount = 0
    @State private var pendingProtectedSend: ProtectedRemoteSend?
    @State private var isTabPickerPresented = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                errorBanner
                tabsBar
                outputView
                keyboardBar
                inputBar
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Pair") { isPairingPresented = true }
                }
                ToolbarItem(placement: .principal) {
                    connectionStatusHeader
                }
                ToolbarItem(placement: .topBarTrailing) {
                    connectButton
                }
            }
            .sheet(isPresented: $isTabPickerPresented) {
                TabPickerSheet(client: client)
                    .presentationDetents([.medium, .large])
            }
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
                if client.sendInput(pendingProtectedSend.text, appendNewline: appendNewline) {
                    sendCount += 1
                    inputText = ""
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

    // MARK: - Status

    /// Connection status shown in place of the old "Chau7 Remote" title.
    private var connectionStatusHeader: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(client.status.displayText)
                .font(.headline)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Connection status: \(client.status.displayText)")
    }

    /// Only surfaces when there is an error to report; the status itself now
    /// lives in the navigation bar.
    @ViewBuilder
    private var errorBanner: some View {
        if let error = client.lastError {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption)
                Text(error)
                    .font(.caption)
                    .lineLimit(2)
                Spacer(minLength: 0)
            }
            .foregroundStyle(.red)
            .padding(.horizontal)
            .padding(.vertical, 6)
            .background(Color(UIColor.secondarySystemBackground))
        }
    }

    private var statusColor: Color {
        guard client.isConnected else { return .red }
        return client.status.isEncryptedSession ? .green : .yellow
    }

    private var connectButton: some View {
        Button(client.isConnected ? "Disconnect" : "Connect") {
            if client.isConnected {
                client.disconnect()
            } else {
                client.connect()
            }
        }
        .disabled(client.pairingInfo == nil && !client.isConnected)
    }

    // MARK: - Tabs

    private var tabsBar: some View {
        VStack(spacing: 8) {
            Button {
                DiagnosticsLog.shared.info(.ui, "Opened tab picker", ["tab_count": String(client.tabs.count)])
                isTabPickerPresented = true
            } label: {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(activeTabMenuLabel)
                            .font(.system(.subheadline, design: .rounded).weight(.semibold))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if let subtitle = activeTabSubtitle {
                            Text(subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity)
                .background(Color(UIColor.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)

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

    // MARK: - Output

    private var outputView: some View {
        Group {
            if experimentalTerminalRenderer {
                RemoteTerminalRendererView(client: client)
            } else {
                RemoteTerminalTextView(
                    text: renderANSI ? client.outputText : client.strippedOutputText
                )
            }
        }
    }

    // MARK: - Keyboard Bar

    private var keyboardBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                TermKey("esc", send: "\u{1B}", client: client)
                TermKey("tab", send: "\t", client: client)
                TermKey("^C", send: "\u{03}", client: client)
                TermKey("^D", send: "\u{04}", client: client)
                TermKey("^Z", send: "\u{1A}", client: client)
                TermKey("^L", send: "\u{0C}", client: client)
                Divider().frame(height: 24).padding(.horizontal, 4)
                TermKey("\u{2191}", send: "\u{1B}[A", client: client)
                TermKey("\u{2193}", send: "\u{1B}[B", client: client)
                TermKey("\u{2190}", send: "\u{1B}[D", client: client)
                TermKey("\u{2192}", send: "\u{1B}[C", client: client)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
        .background(Color(UIColor.tertiarySystemBackground))
    }

    // MARK: - Input Bar

    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField("Input", text: $inputText, axis: .vertical)
                .font(.system(.body, design: .monospaced))
                .lineLimit(1...4)
                .textFieldStyle(.roundedBorder)
                .submitLabel(.send)
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

    @ViewBuilder
    private var sendButton: some View {
        if holdToSend {
            Button {} label: {
                VStack(spacing: 2) {
                    Image(systemName: "hand.tap.fill").font(.title3)
                    Text("Hold")
                        .font(.caption2)
                }
            }
            .sensoryFeedback(.impact(flexibility: .solid, intensity: 0.5), trigger: sendCount)
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 0.4).onEnded { _ in
                    submitInput()
                }
            )
            .disabled(inputText.isEmpty || !client.canSendInput)
        } else {
            Button {
                submitInput()
            } label: {
                Image(systemName: "arrow.up.circle.fill").font(.title2)
            }
            .disabled(inputText.isEmpty || !client.canSendInput)
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

        guard client.sendInput(text, appendNewline: appendNewline) else {
            DiagnosticsLog.shared.error(.input, "Submit blocked", [
                "trigger": trigger,
                "reason": client.lastError ?? "unknown"
            ])
            return
        }
        DiagnosticsLog.shared.info(.input, "Input sent", ["bytes": String(text.utf8.count)])
        inputText = ""
        sendCount += 1
    }

    private var activeTabMenuLabel: String {
        guard let activeTab else { return "No remote tabs" }
        return activeTab.title
    }

    /// Repo + AI provider summary shown under the active tab name in the
    /// dropdown button.
    private var activeTabSubtitle: String? {
        var parts: [String] = []
        if let projectName = activeProjectName { parts.append(projectName) }
        if let provider = activeProviderName { parts.append(provider) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// AI provider for the active tab: prefer the live activity tool name,
    /// fall back to the provider reported in the tab list.
    private var activeProviderName: String? {
        if let toolName = activeToolName { return toolName }
        return activeTab?.aiProvider
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

// MARK: - Subviews

struct TermKey: View {
    let label: String
    let sequence: String
    let client: RemoteClient
    @State private var tapCount = 0

    init(_ label: String, send sequence: String, client: RemoteClient) {
        self.label = label
        self.sequence = sequence
        self.client = client
    }

    var body: some View {
        Button {
            tapCount += 1
            DiagnosticsLog.shared.keystroke(label, field: "key_bar", extra: ["op": "control_key"])
            let sent = client.sendInput(sequence, appendNewline: false)
            if !sent {
                DiagnosticsLog.shared.error(.input, "Control key blocked", [
                    "key": label,
                    "reason": client.lastError ?? "unknown"
                ])
            }
        } label: {
            Text(label)
                .font(.system(size: 13, design: .monospaced))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color(UIColor.quaternarySystemFill))
                .cornerRadius(6)
        }
        .sensoryFeedback(.impact(flexibility: .solid, intensity: 0.3), trigger: tapCount)
        .buttonStyle(.plain)
        .disabled(!client.canSendInput)
    }
}

private struct ProtectedRemoteSend: Identifiable {
    let id = UUID()
    let text: String
    let flaggedAction: String
    let message: String
}

/// Full-width tab picker presented from the terminal tab selector. Each row
/// shows the tab name, repo name, and AI provider.
struct TabPickerSheet: View {
    var client: RemoteClient
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if client.tabs.isEmpty {
                    ContentUnavailableView(
                        "No Remote Tabs",
                        systemImage: "macwindow",
                        description: Text("Tabs from your Mac will appear here once connected.")
                    )
                } else {
                    List {
                        ForEach(client.tabs) { tab in
                            Button {
                                DiagnosticsLog.shared.info(.tab, "Selected remote tab", [
                                    "tab_id": String(tab.tabID),
                                    "title": tab.title
                                ])
                                client.switchTab(tab.tabID)
                                dismiss()
                            } label: {
                                TabPickerRow(tab: tab, isActive: tab.tabID == client.activeTabID)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Tabs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

private struct TabPickerRow: View {
    let tab: RemoteTab
    let isActive: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
                .font(.title3)

            VStack(alignment: .leading, spacing: 4) {
                Text(tab.title)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 8) {
                    if let projectName = tab.projectName {
                        rowChip(projectName, systemImage: "shippingbox")
                    }
                    if let branchName = tab.branchName {
                        rowChip(branchName, systemImage: "arrow.triangle.branch")
                    }
                    if let provider = tab.aiProvider {
                        rowChip(provider, systemImage: "sparkles")
                    }
                    if tab.isMCPControlled {
                        rowChip("MCP", systemImage: "face.dashed.fill")
                    }
                }
            }

            if tab.isMCPControlled {
                Image(systemName: "face.dashed.fill")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func rowChip(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.caption2.weight(.medium))
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color(UIColor.tertiarySystemBackground))
            .clipShape(Capsule(style: .continuous))
    }
}
