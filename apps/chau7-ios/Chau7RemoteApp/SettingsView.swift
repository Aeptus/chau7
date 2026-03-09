import SwiftUI

struct RemoteSettingsView: View {
    @ObservedObject var client: RemoteClient
    @Binding var isPairingPresented: Bool

    @AppStorage("hold_to_send") private var holdToSend = true
    @AppStorage("append_newline") private var appendNewline = true
    @AppStorage("render_ansi") private var renderANSI = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Input") {
                    Toggle("Hold to Send", isOn: $holdToSend)
                    Toggle("Append Newline", isOn: $appendNewline)
                }

                Section("Display") {
                    Toggle("Render ANSI Colors", isOn: $renderANSI)
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
                    LabeledContent("Version", value: "1.1.0")
                }
            }
            .navigationTitle("Settings")
        }
    }
}
