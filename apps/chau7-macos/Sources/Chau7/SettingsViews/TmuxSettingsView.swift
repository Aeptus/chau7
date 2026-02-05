import SwiftUI

struct TmuxSettingsView: View {
    @ObservedObject private var settings = FeatureSettings.shared
    @StateObject private var tmux = TmuxControlMode()
    @State private var detectedSessions: [String] = []
    @State private var selectedSession: String?
    @State private var isDetecting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsSectionHeader(L("settings.tmux.status", "Status"), icon: "rectangle.split.3x1")
            statusRow

            SettingsSectionHeader(L("settings.tmux.integration", "Integration"), icon: "gearshape.2")
            SettingsToggle(
                label: L("settings.tmux.enable", "Enable tmux Integration"),
                help: L("settings.tmux.enable.help", "Use tmux control mode to map tmux windows to Chau7 tabs"),
                isOn: $settings.isTmuxIntegrationEnabled
            )

            SettingsToggle(
                label: L("settings.tmux.autoAttach", "Auto-attach on Launch"),
                help: L("settings.tmux.autoAttach.help", "Automatically attach to the last tmux session when opening a new window"),
                isOn: $settings.isTmuxAutoAttachEnabled,
                disabled: !settings.isTmuxIntegrationEnabled
            )

            SettingsSectionHeader(L("settings.tmux.sessions", "Sessions"), icon: "list.bullet.rectangle")
            sessionsView

            SettingsSectionHeader(L("settings.tmux.actions", "Actions"), icon: "play.rectangle")
            actionsRow
        }
    }

    private var statusRow: some View {
        SettingsRow(L("settings.tmux.connection", "Connection")) {
            VStack(alignment: .leading, spacing: 4) {
                Text(tmux.isConnected
                    ? L("settings.tmux.connected", "Connected")
                    : L("settings.tmux.disconnected", "Disconnected"))
                    .fontWeight(.semibold)
                if let session = tmux.sessionName {
                    Text(L("settings.tmux.session", "Session: %@", session))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let error = tmux.lastError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                if !tmux.windows.isEmpty {
                    Text(L("settings.tmux.windowCount", "%d window(s)", tmux.windows.count))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var sessionsView: some View {
        SettingsRow(
            L("settings.tmux.availableSessions", "Available Sessions"),
            help: L("settings.tmux.availableSessions.help", "Detected running tmux sessions on this machine")
        ) {
            VStack(alignment: .leading, spacing: 8) {
                if isDetecting {
                    ProgressView()
                        .controlSize(.small)
                } else if detectedSessions.isEmpty {
                    Text(L("settings.tmux.noSessions", "No tmux sessions detected"))
                        .foregroundStyle(.secondary)
                        .font(.caption)
                } else {
                    ForEach(detectedSessions, id: \.self) { session in
                        HStack {
                            Image(systemName: selectedSession == session ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(selectedSession == session ? .blue : .secondary)
                            Text(session)
                                .font(.system(.body, design: .monospaced))
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            selectedSession = session
                        }
                    }
                }

                Button(L("settings.tmux.refresh", "Refresh")) {
                    detectSessions()
                }
                .controlSize(.small)
            }
        }
    }

    private var actionsRow: some View {
        SettingsRow(L("settings.tmux.controls", "Controls")) {
            HStack(spacing: 12) {
                Button(L("settings.tmux.connect", "Connect")) {
                    tmux.connect(sessionName: selectedSession)
                }
                .disabled(tmux.isConnected || !settings.isTmuxIntegrationEnabled)

                Button(L("settings.tmux.disconnect", "Disconnect")) {
                    tmux.disconnect()
                }
                .disabled(!tmux.isConnected)

                Button(L("settings.tmux.newSession", "New Session")) {
                    tmux.connect(sessionName: nil)
                }
                .disabled(tmux.isConnected || !settings.isTmuxIntegrationEnabled)
            }
        }
    }

    private func detectSessions() {
        isDetecting = true
        DispatchQueue.global(qos: .userInitiated).async {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            task.arguments = ["tmux", "list-sessions", "-F", "#{session_name}"]
            let pipe = Pipe()
            task.standardOutput = pipe
            task.standardError = Pipe()

            var sessions: [String] = []
            do {
                try task.run()
                task.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if let output = String(data: data, encoding: .utf8) {
                    sessions = output.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
                }
            } catch {
                Log.warn("TmuxSettings: failed to detect sessions: \(error.localizedDescription)")
            }

            DispatchQueue.main.async {
                detectedSessions = sessions
                isDetecting = false
            }
        }
    }
}
