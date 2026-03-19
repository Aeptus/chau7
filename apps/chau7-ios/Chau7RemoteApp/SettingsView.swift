import SwiftUI

/// Shared keys and defaults for @AppStorage, preventing drift between views.
enum AppSettings {
    static let holdToSendKey = "hold_to_send"
    static let holdToSendDefault = false
    static let appendNewlineKey = "append_newline"
    static let appendNewlineDefault = true
    static let renderANSIKey = "render_ansi"
    static let renderANSIDefault = false
    static let experimentalTerminalRendererKey = "experimental_terminal_renderer"
    static let experimentalTerminalRendererDefault = false
}

struct SettingsView: View {
    var client: RemoteClient
    @Binding var isPairingPresented: Bool

    @AppStorage(AppSettings.holdToSendKey) private var holdToSend = AppSettings.holdToSendDefault
    @AppStorage(AppSettings.appendNewlineKey) private var appendNewline = AppSettings.appendNewlineDefault
    @AppStorage(AppSettings.renderANSIKey) private var renderANSI = AppSettings.renderANSIDefault
    @AppStorage(AppSettings.experimentalTerminalRendererKey)
    private var experimentalTerminalRenderer = AppSettings.experimentalTerminalRendererDefault

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 14) {
                        Chau7LogoImage(size: 56, cornerRadius: 14, fallbackFontSize: 26)

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Chau7 Remote")
                                .font(.headline)
                            Text("Connected access to your Chau7 workspace")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section("Input") {
                    Toggle("Hold to Send", isOn: $holdToSend)
                    Toggle("Append Newline", isOn: $appendNewline)
                }

                Section("Display") {
                    Toggle("Render ANSI Colors", isOn: $renderANSI)
                    Toggle("Experimental Terminal Renderer", isOn: $experimentalTerminalRenderer)
                }

                Section("Connection") {
                    if let info = client.pairingInfo {
                        LabeledContent("Relay", value: info.relayURL)
                        LabeledContent("Device ID") {
                            Text(String(info.deviceID.prefix(12)) + "...")
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        LabeledContent("Status") {
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(client.isConnected ? .green : .red)
                                    .frame(width: 8, height: 8)
                                Text(client.status)
                            }
                        }
                    } else {
                        Text("Not paired")
                            .foregroundStyle(.secondary)
                    }

                    Button("Re-pair") { isPairingPresented = true }

                    if client.isConnected {
                        Button("Disconnect", role: .destructive) {
                            client.disconnect()
                        }
                    }
                }

                Section("About") {
                    LabeledContent("Version", value: RemoteClient.appVersion)
                }
            }
            .navigationTitle("Settings")
        }
    }
}
