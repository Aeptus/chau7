import Chau7Core
import SwiftUI

/// Main terminal tab: connection status bar, tab selector, output display,
/// keyboard shortcut bar (esc, tab, ^C, ^D, arrows), and text input field.
/// Supports two rendering modes: rich grid renderer (default) and plain text.
struct TerminalView: View {
    var client: RemoteClient
    @Binding var isPairingPresented: Bool

    @AppStorage(AppSettings.holdToSendKey) private var holdToSend = AppSettings.holdToSendDefault
    @AppStorage(AppSettings.appendNewlineKey) private var appendNewline = AppSettings.appendNewlineDefault
    @AppStorage(AppSettings.renderANSIKey) private var renderANSI = AppSettings.renderANSIDefault
    @AppStorage(AppSettings.experimentalTerminalRendererKey)
    private var experimentalTerminalRenderer = AppSettings.experimentalTerminalRendererDefault
    @AppStorage(AppSettings.showKeyboardBarKey) private var showKeyboardBar = AppSettings.showKeyboardBarDefault
    @AppStorage(AppSettings.terminalFontSizeKey) private var terminalFontSize = AppSettings.terminalFontSizeDefault

    @State private var inputText = ""
    @State private var sendCount = 0
    @State private var justSent = false
    @State private var pendingProtectedSend: ProtectedRemoteSend?
    @State private var textAwayFromBottom = false
    @State private var scrollToBottomToken = 0
    @State private var isErrorExpanded = false

    var body: some View {
        NavigationStack {
            Group {
                if client.pairingInfo == nil {
                    UnpairedTerminalView(isPairingPresented: $isPairingPresented)
                } else {
                    pairedContent
                }
            }
            .navigationTitle("Chau7 Remote")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
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
            if showsKeyboardBar {
                keyboardBar
            }
            inputBar
        }
    }

    // MARK: - Status

    private var statusBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Circle()
                    .fill(client.connectionPhase.color)
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)
                Text(client.connectionDisplayLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if let error = client.lastError, !error.isEmpty {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { isErrorExpanded.toggle() }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "exclamationmark.triangle.fill")
                            Text("Issue")
                            Image(systemName: isErrorExpanded ? "chevron.up" : "chevron.down")
                                .font(.caption2)
                        }
                        .font(.caption)
                        .foregroundStyle(.red)
                    }
                    .accessibilityLabel("Connection issue. Tap for details.")
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Status: \(client.connectionDisplayLabel)")

            if isErrorExpanded, let error = client.lastError, !error.isEmpty {
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
                                Text(tabMenuTitle(for: tab))
                                    .lineLimit(1)
                            } icon: {
                                tabMenuIcon(for: tab)
                            }
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

    // MARK: - Keyboard Bar

    private var showsKeyboardBar: Bool {
        showKeyboardBar && client.canSendInput
    }

    private var keyboardBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                TermKey("esc", labelText: "Escape", send: "\u{1B}", client: client)
                TermKey("tab", labelText: "Tab", send: "\t", client: client)
                TermKey("^C", labelText: "Control C", send: "\u{03}", client: client)
                TermKey("^D", labelText: "Control D", send: "\u{04}", client: client)
                TermKey("^Z", labelText: "Control Z", send: "\u{1A}", client: client)
                TermKey("^L", labelText: "Control L", send: "\u{0C}", client: client)
                Divider().frame(height: 24).padding(.horizontal, 4)
                TermKey("\u{2191}", labelText: "Up arrow", send: "\u{1B}[A", client: client)
                TermKey("\u{2193}", labelText: "Down arrow", send: "\u{1B}[B", client: client)
                TermKey("\u{2190}", labelText: "Left arrow", send: "\u{1B}[D", client: client)
                TermKey("\u{2192}", labelText: "Right arrow", send: "\u{1B}[C", client: client)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
        .background(Color(UIColor.tertiarySystemBackground))
    }

    // MARK: - Input Bar

    private var inputBar: some View {
        HStack(spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { showKeyboardBar.toggle() }
            } label: {
                Image(systemName: showKeyboardBar ? "keyboard.chevron.compact.down" : "keyboard")
                    .font(.title3)
                    .frame(width: 32, height: 32)
            }
            .disabled(!client.canSendInput)
            .accessibilityLabel(showKeyboardBar ? "Hide control keys" : "Show control keys")

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
            HoldToSendButton(isEnabled: !inputText.isEmpty && client.canSendInput) {
                submitInput()
            }
            .sensoryFeedback(.impact(flexibility: .solid, intensity: 0.5), trigger: sendCount)
        } else {
            Button(action: submitInput) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
                    .frame(width: 44, height: 44)
            }
            .sensoryFeedback(.impact(flexibility: .solid, intensity: 0.5), trigger: sendCount)
            .disabled(inputText.isEmpty || !client.canSendInput)
            .accessibilityLabel("Send")
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
    let client: RemoteClient
    @State private var tapCount = 0

    init(_ label: String, labelText: String, send sequence: String, client: RemoteClient) {
        self.label = label
        self.accessibilityName = labelText
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
