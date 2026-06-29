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

    // Diagnostics
    static let verboseLoggingKey = "diagnostics_verbose"
    static let verboseLoggingDefault = true
    static let logKeystrokesKey = "diagnostics_log_keystrokes"
    static let logKeystrokesDefault = true
}

struct SettingsView: View {
    var client: RemoteClient
    @Binding var isPairingPresented: Bool

    @AppStorage(AppSettings.holdToSendKey) private var holdToSend = AppSettings.holdToSendDefault
    @AppStorage(AppSettings.appendNewlineKey) private var appendNewline = AppSettings.appendNewlineDefault
    @AppStorage(AppSettings.renderANSIKey) private var renderANSI = AppSettings.renderANSIDefault
    @AppStorage(AppSettings.experimentalTerminalRendererKey)
    private var experimentalTerminalRenderer = AppSettings.experimentalTerminalRendererDefault
    @AppStorage(AppSettings.verboseLoggingKey) private var verboseLogging = AppSettings.verboseLoggingDefault
    @AppStorage(AppSettings.logKeystrokesKey) private var logKeystrokes = AppSettings.logKeystrokesDefault

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

                Section {
                    Toggle("Verbose Logging", isOn: $verboseLogging)
                    Toggle("Log Keystrokes", isOn: $logKeystrokes)
                    NavigationLink {
                        DiagnosticsLogView()
                    } label: {
                        Label("Diagnostics Log", systemImage: "doc.text.magnifyingglass")
                    }
                } header: {
                    Text("Diagnostics")
                } footer: {
                    Text("Captures a verbose on-device log — including performance data and, when enabled, every keystroke typed in the app — for troubleshooting. Nothing leaves your device until you tap Export. Keystroke capture records the literal characters you type.")
                }

                Section("About") {
                    LabeledContent("Version", value: RemoteClient.appVersion)
                }
            }
            .navigationTitle("Settings")
        }
    }
}
