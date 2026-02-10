import SwiftUI
import AppKit

struct RemoteSettingsView: View {
    @ObservedObject private var settings = FeatureSettings.shared
    @ObservedObject private var remote = RemoteControlManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsSectionHeader(L("settings.remote.status", "Status"), icon: "antenna.radiowaves.left.and.right")
            statusRow

            SettingsSectionHeader(L("settings.remote.access", "Remote Access"), icon: "lock.shield")
            SettingsToggle(
                label: L("settings.remote.enable", "Enable Remote Control"),
                help: L("settings.remote.enable.help", "Allow Chau7 to be controlled from the iOS app"),
                isOn: $settings.isRemoteEnabled
            )

            SettingsSectionHeader(L("settings.remote.relay", "Relay"), icon: "network")
            SettingsRow(L("settings.remote.relayUrl", "Relay URL"), help: L("settings.remote.relayUrl.help", "WebSocket relay base URL")) {
                TextField("", text: $settings.remoteRelayURL)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 360)
            }

            SettingsSectionHeader(L("settings.remote.pairing", "Pairing"), icon: "qrcode")
            pairingView
        }
    }

    private var statusRow: some View {
        SettingsRow(L("settings.remote.agent", "Remote Agent")) {
            VStack(alignment: .leading, spacing: 4) {
                Text(remote.isAgentRunning ? L("status.running", "Running") : L("status.stopped", "Stopped"))
                    .fontWeight(.semibold)
                if let error = remote.lastError, !error.isEmpty {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let status = remote.sessionStatus, !status.isEmpty {
                    Text(String(format: L("remote.sessionStatus", "Session: %@"), status))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text(remote.isIPCConnected ? L("remote.ipc.connected", "IPC connected") : L("remote.ipc.disconnected", "IPC not connected"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var pairingView: some View {
        if let info = remote.pairingInfo {
            let payload = info.qrPayloadString()
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(String(format: L("remote.deviceId", "Device ID: %@"), info.deviceID))
                        .font(.system(size: 12, design: .monospaced))
                    Text(String(format: L("remote.pairingCode", "Pairing Code: %@"), info.pairingCode))
                        .font(.system(size: 16, design: .monospaced))
                        .fontWeight(.semibold)
                    Text(String(format: L("remote.expiresAt", "Expires: %@"), info.expiresAt))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(String(format: L("remote.relayUrl", "Relay: %@"), info.relayURL))
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 12) {
                        Button(L("Copy Pairing JSON", "Copy Pairing JSON")) {
                            guard let payload else { return }
                            let pasteboard = NSPasteboard.general
                            pasteboard.clearContents()
                            pasteboard.setString(payload, forType: .string)
                        }
                        Button(L("Copy Pairing Code", "Copy Pairing Code")) {
                            let pasteboard = NSPasteboard.general
                            pasteboard.clearContents()
                            pasteboard.setString(info.pairingCode, forType: .string)
                        }
                    }
                    .buttonStyle(.bordered)
                }

                Spacer()
            }
        } else {
            Text(L("Pairing info will appear once the remote agent connects.", "Pairing info will appear once the remote agent connects."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
