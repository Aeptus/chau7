import SwiftUI
import AppKit

struct RemoteSettingsView: View {
    @Bindable private var settings = FeatureSettings.shared
    @ObservedObject private var remote = RemoteControlManager.shared
    @State private var devicePendingRevocation: RemotePairedDevice?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // SSH Profiles first — most commonly used section
            SSHProfilesSettingsView()

            Divider()
                .padding(.vertical, 8)

            // Remote Control
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

            SettingsSectionHeader(L("settings.remote.devices", "Paired Devices"), icon: "iphone")
            pairedDevicesView
        }
        .confirmationDialog(
            L("settings.remote.revoke.confirm.title", "Revoke Pairing?"),
            isPresented: Binding(
                get: { devicePendingRevocation != nil },
                set: { if !$0 { devicePendingRevocation = nil } }
            ),
            presenting: devicePendingRevocation
        ) { device in
            Button(L("settings.remote.revoke.confirm.action", "Revoke Device"), role: .destructive) {
                remote.revokePairedDevice(id: device.id)
                devicePendingRevocation = nil
            }
            Button(L("common.cancel", "Cancel"), role: .cancel) {
                devicePendingRevocation = nil
            }
        } message: { device in
            Text(String(format: L("settings.remote.revoke.confirm.message", "This will remove %@ and force it to pair again before it can reconnect."), device.name))
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
                    if let connectedDevice = remote.pairedDevices.first(where: \.isConnected) {
                        Text(String(format: L("settings.remote.connectedDevice", "Connected device: %@"), connectedDevice.name))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
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
                        Button(L("Regenerate", "Regenerate")) {
                            remote.restartAgentIfRunning()
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

    @ViewBuilder
    private var pairedDevicesView: some View {
        if remote.pairedDevices.isEmpty {
            Text(L("settings.remote.devices.empty", "No paired devices yet."))
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(remote.pairedDevices) { device in
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                Text(device.name)
                                    .fontWeight(.semibold)
                                Text(device.isConnected ? L("status.connected", "Connected") : L("status.notConnected", "Not Connected"))
                                    .font(.caption)
                                    .foregroundStyle(device.isConnected ? .green : .secondary)
                            }
                            Text(String(format: L("settings.remote.deviceFingerprint", "Fingerprint: %@"), device.fingerprint))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                            if let pairedAt = device.pairedAt {
                                Text(String(format: L("settings.remote.devicePairedAt", "Paired: %@"), pairedAt))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            if let lastConnectedAt = device.lastConnectedAt {
                                Text(String(format: L("settings.remote.deviceLastConnectedAt", "Last connected: %@"), lastConnectedAt))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Button(L("settings.remote.revoke", "Revoke"), role: .destructive) {
                            devicePendingRevocation = device
                        }
                        .buttonStyle(.bordered)
                    }
                    if device.id != remote.pairedDevices.last?.id {
                        Divider()
                    }
                }
            }
        }
    }
}
