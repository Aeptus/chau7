import SwiftUI

struct TerminalView: View {
    var client: RemoteClient
    @Binding var isPairingPresented: Bool

    @AppStorage(AppSettings.holdToSendKey) private var holdToSend = AppSettings.holdToSendDefault
    @AppStorage(AppSettings.appendNewlineKey) private var appendNewline = AppSettings.appendNewlineDefault
    @AppStorage(AppSettings.renderANSIKey) private var renderANSI = AppSettings.renderANSIDefault
    @State private var inputText = ""
    @State private var sendCount = 0

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
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(client.tabs) { tab in
                    TabChip(tab: tab, isSelected: tab.tabID == client.activeTabID) {
                        client.switchTab(tab.tabID)
                    }
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .background(Color(UIColor.systemBackground))
    }

    // MARK: - Output

    private var outputView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(renderANSI ? client.outputText : client.strippedOutputText)
                    .font(.system(size: 13, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .id("bottom")
                    .textSelection(.enabled)
            }
            .background(Color.black)
            .foregroundStyle(.green)
            .onChange(of: client.outputText) { _, _ in
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
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
                Image(systemName: "arrow.up.circle.fill").font(.title2)
            }
            .sensoryFeedback(.impact(flexibility: .solid, intensity: 0.5), trigger: sendCount)
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 0.4).onEnded { _ in
                    submitInput()
                }
            )
        } else {
            Button(action: submitInput) {
                Image(systemName: "arrow.up.circle.fill").font(.title2)
            }
            .disabled(inputText.isEmpty)
        }
    }

    private func submitInput() {
        let text = inputText
        inputText = ""
        sendCount += 1
        client.sendInput(text, appendNewline: appendNewline)
    }
}

// MARK: - Subviews

struct TabChip: View {
    let tab: RemoteTab
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if tab.isMCPControlled {
                    Image(systemName: "face.dashed")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.purple)
                }
                Text(tab.title).lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(isSelected ? Color.accentColor.opacity(0.2) : Color.clear)
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
    }
}

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
        .disabled(!client.isConnected)
    }
}
