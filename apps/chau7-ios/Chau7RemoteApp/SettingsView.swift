import SwiftUI
import UIKit

/// Shared keys and defaults for @AppStorage, preventing drift between views.
enum AppSettings {
    static let holdToSendKey = "hold_to_send"
    // Hold-to-send is the documented default: it guards against accidental sends
    // to a live terminal that may be driving an AI agent.
    static let holdToSendDefault = true
    static let appendNewlineKey = "append_newline"
    static let appendNewlineDefault = true
    static let renderANSIKey = "render_ansi"
    static let renderANSIDefault = false
    static let experimentalTerminalRendererKey = "experimental_terminal_renderer"
    // Rich (grid) renderer is the better default — it shows real color and
    // formatting and falls back to the plain text view when unavailable.
    static let experimentalTerminalRendererDefault = true
    static let showKeyboardBarKey = "show_keyboard_bar"
    static let showKeyboardBarDefault = false
    static let terminalFontSizeKey = "terminal_font_size"
    static let terminalFontSizeDefault = 13.0
    static let terminalFontSizeMin = 10.0
    static let terminalFontSizeMax = 22.0
    static let hasCompletedOnboardingKey = "has_completed_onboarding"
}

struct SettingsView: View {
    var client: RemoteClient
    @Binding var isPairingPresented: Bool

    @AppStorage(AppSettings.holdToSendKey) private var holdToSend = AppSettings.holdToSendDefault
    @AppStorage(AppSettings.appendNewlineKey) private var appendNewline = AppSettings.appendNewlineDefault
    @AppStorage(AppSettings.renderANSIKey) private var renderANSI = AppSettings.renderANSIDefault
    @AppStorage(AppSettings.experimentalTerminalRendererKey)
    private var experimentalTerminalRenderer = AppSettings.experimentalTerminalRendererDefault
    @AppStorage(AppSettings.showKeyboardBarKey) private var showKeyboardBar = AppSettings.showKeyboardBarDefault
    @AppStorage(AppSettings.terminalFontSizeKey) private var terminalFontSize = AppSettings.terminalFontSizeDefault

    @Environment(\.scenePhase) private var scenePhase

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
                    .accessibilityElement(children: .combine)
                }

                Section("Input") {
                    Toggle("Hold to Send", isOn: $holdToSend)
                    Toggle("Append Newline", isOn: $appendNewline)
                    Toggle("Show Control Keys", isOn: $showKeyboardBar)
                } footer: {
                    Text("Hold to Send requires a long press before input is forwarded, guarding against accidental sends. Control Keys shows the esc / tab / ^C row above the input field.")
                }

                Section("Display") {
                    Toggle("Rich Terminal Renderer", isOn: $experimentalTerminalRenderer)
                    Toggle("Show Raw ANSI Codes", isOn: $renderANSI)
                        .disabled(experimentalTerminalRenderer)

                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Text Size")
                            Spacer()
                            Text("\(Int(terminalFontSize)) pt")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Slider(
                            value: $terminalFontSize,
                            in: AppSettings.terminalFontSizeMin...AppSettings.terminalFontSizeMax,
                            step: 1
                        )
                        .accessibilityLabel("Terminal text size")
                        .accessibilityValue("\(Int(terminalFontSize)) points")
                    }
                } footer: {
                    Text("The Rich Terminal Renderer draws full color and formatting (recommended). When it is off, the basic text view is used; Show Raw ANSI Codes then keeps the unprocessed color escape sequences instead of stripping them.")
                }

                Section("Notifications") {
                    HStack {
                        Label("Approval Alerts", systemImage: client.notificationsAuthorized ? "bell.badge" : "bell.slash")
                        Spacer()
                        Text(client.notificationsAuthorized ? "On" : "Off")
                            .foregroundStyle(client.notificationsAuthorized ? .green : .secondary)
                    }
                    if !client.notificationsAuthorized {
                        Button("Open iOS Settings") { openSystemSettings() }
                    }
                } footer: {
                    if client.notificationsAuthorized {
                        Text("You'll be alerted when an agent needs approval while the app is in the background.")
                    } else {
                        Text("Notifications are off, so approval requests won't alert you when the app is in the background. Turn them on in iOS Settings to be notified.")
                    }
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
                                    .fill(client.connectionPhase.color)
                                    .frame(width: 8, height: 8)
                                    .accessibilityHidden(true)
                                Text(client.connectionDisplayLabel)
                            }
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel("Connection status: \(client.connectionDisplayLabel)")
                        }

                        if client.isConnected {
                            Button("Disconnect", role: .destructive) {
                                client.disconnect()
                            }
                        } else {
                            Button("Connect") { client.connect() }
                        }
                        Button("Re-pair") { isPairingPresented = true }
                    } else {
                        Text("Not paired")
                            .foregroundStyle(.secondary)
                        Button("Pair with your Mac") { isPairingPresented = true }
                    }
                }

                Section("About") {
                    LabeledContent("Version", value: RemoteClient.appVersion)
                }
            }
            .navigationTitle("Settings")
            .onAppear { client.refreshNotificationAuthorization() }
            .onChange(of: scenePhase) { _, newPhase in
                if newPhase == .active { client.refreshNotificationAuthorization() }
            }
        }
    }

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}
