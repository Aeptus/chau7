import SwiftUI

@main
struct Chau7RemoteApp: App {
    var body: some Scene {
        WindowGroup {
            RemoteRootView()
        }
    }
}

struct RemoteRootView: View {
    @StateObject private var client = RemoteClient()
    @State private var inputText: String = ""
    @State private var isPairingPresented = false
    @State private var pairingError: String?
    @AppStorage("hold_to_send") private var holdToSend = true
    @AppStorage("append_newline") private var appendNewline = true
    @AppStorage("render_ansi") private var renderANSI = false
    @State private var pairingPayload: String = {
        if let data = KeychainStore.load(key: "pairing_payload"),
           let str = String(data: data, encoding: .utf8) {
            return str
        }
        return ""
    }()

    private var pairingInfo: PairingInfo? {
        guard let data = pairingPayload.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(PairingInfo.self, from: data)
    }

    private func savePairingPayload(_ value: String) {
        pairingPayload = value
        if value.isEmpty {
            _ = KeychainStore.delete(key: "pairing_payload")
        } else if let data = value.data(using: .utf8) {
            _ = KeychainStore.save(key: "pairing_payload", data: data)
        }
    }

    private var activeError: String? {
        client.lastError ?? pairingError
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                statusBar
                tabsBar
                outputView
                inputView
            }
            .navigationTitle("Chau7 Remote")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Pair") {
                        isPairingPresented = true
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(client.isConnected ? "Disconnect" : "Connect") {
                        if client.isConnected {
                            client.disconnect()
                        } else if let pairingInfo {
                            client.connect(pairing: pairingInfo)
                        }
                    }
                    .disabled(pairingInfo == nil && !client.isConnected)
                }
            }
            .sheet(isPresented: $isPairingPresented) {
                PairingSheetView(
                    pairingPayload: Binding(
                        get: { pairingPayload },
                        set: { savePairingPayload($0) }
                    ),
                    pairingError: $pairingError
                )
            }
        }
    }

    private var statusBar: some View {
        HStack {
            Text(client.status)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            if let error = activeError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(Color(UIColor.secondarySystemBackground))
    }

    private var tabsBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(client.tabs) { tab in
                    Button(action: { client.switchTab(tab.tabID) }) {
                        Text(tab.title)
                            .lineLimit(1)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(tab.isActive ? Color.accentColor.opacity(0.2) : Color.clear)
                            .cornerRadius(8)
                    }
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .background(Color(UIColor.systemBackground))
    }

    private var outputView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(displayedOutput)
                    .font(.system(.body, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .id("bottom")
            }
            .background(Color(UIColor.systemBackground))
            .onChange(of: client.outputText) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
        }
    }

    private var inputView: some View {
        VStack(spacing: 8) {
            TextEditor(text: $inputText)
                .frame(minHeight: 80, maxHeight: 120)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.secondary.opacity(0.3))
                )

            HStack {
                Toggle("Hold to Send", isOn: $holdToSend)
                    .toggleStyle(.switch)
                Toggle("Append Newline", isOn: $appendNewline)
                    .toggleStyle(.switch)
                Toggle("Render ANSI", isOn: $renderANSI)
                    .toggleStyle(.switch)
                Spacer()
                Button(holdToSend ? "Hold to Send" : "Send") {
                    if !holdToSend {
                        submitInput()
                    }
                }
                .simultaneousGesture(
                    LongPressGesture(minimumDuration: 0.4)
                        .onEnded { _ in
                            if holdToSend {
                                submitInput()
                            }
                        }
                )
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .background(Color(UIColor.secondarySystemBackground))
    }

    private func submitInput() {
        let text = inputText
        inputText = ""
        client.sendInput(text, appendNewline: appendNewline)
    }

    private var displayedOutput: String {
        renderANSI ? client.outputText : stripANSI(from: client.outputText)
    }

    private func stripANSI(from input: String) -> String {
        var output = ""
        var iterator = input.unicodeScalars.makeIterator()
        var scalar = iterator.next()
        while let current = scalar {
            if current == "\u{1B}" {
                scalar = iterator.next()
                if let next = scalar, next == "[" {
                    while let candidate = iterator.next() {
                        if candidate.value >= 0x40 && candidate.value <= 0x7E {
                            scalar = iterator.next()
                            break
                        }
                    }
                    continue
                }
            }
            output.unicodeScalars.append(current)
            scalar = iterator.next()
        }
        return output
    }
}
