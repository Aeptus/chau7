import Chau7Core
import SwiftUI

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

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                statusBar
                tabsBar
                outputView
                keyboardBar
                inputBar
            }
            .navigationTitle("Chau7 Remote")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Pair") { isPairingPresented = true }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    connectButton
                }
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

    private var statusBar: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(client.status)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            if let error = client.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(Color(UIColor.secondarySystemBackground))
    }

    private var statusColor: Color {
        guard client.isConnected else { return .red }
        switch client.status {
        case "Encrypted", "Session ready": return .green
        default: return .yellow
        }
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
        HStack(spacing: 10) {
            Menu {
                if client.tabs.isEmpty {
                    Text("No remote tabs available yet")
                } else {
                    ForEach(client.tabs) { tab in
                        Button {
                            client.switchTab(tab.tabID)
                        } label: {
                            Label {
                                Text(tab.title)
                                    .lineLimit(1)
                            } icon: {
                                if tab.tabID == client.activeTabID {
                                    Image(systemName: "checkmark")
                                } else if tab.isMCPControlled {
                                    Image(systemName: "face.dashed.fill")
                                }
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 8) {
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
                .onSubmit { if !holdToSend { submitInput() } }

            sendButton
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(UIColor.secondarySystemBackground))
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
            Button(action: submitInput) {
                Image(systemName: "arrow.up.circle.fill").font(.title2)
            }
            .disabled(inputText.isEmpty || !client.canSendInput)
        }
    }

    private func submitInput() {
        let text = inputText
        guard !text.isEmpty else { return }

        if let flaggedAction = client.flaggedProtectedAction(for: text) {
            client.recordProtectedActionPrompt(text: text, flaggedAction: flaggedAction)
            pendingProtectedSend = ProtectedRemoteSend(
                text: text,
                flaggedAction: flaggedAction,
                message: "\(flaggedAction) requires a second approval before it is forwarded to your Mac."
            )
            return
        }

        guard client.sendInput(text, appendNewline: appendNewline) else { return }
        inputText = ""
        sendCount += 1
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
            client.sendInput(sequence, appendNewline: false)
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
