import SwiftUI

// MARK: - Scrollback & Performance Settings

struct ScrollbackPerfSettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var settings = FeatureSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Scrollback
            SettingsSectionHeader(L("settings.terminal.scrollback", "Scrollback"), icon: "scroll")

            SettingsNumberField(
                label: L("settings.terminal.bufferSize", "Buffer Size"),
                help: L("settings.terminal.bufferSize.help", "Number of lines to keep in scrollback history (100-100,000)"),
                value: $settings.scrollbackLines,
                width: 100
            )

            Divider()
                .padding(.vertical, 8)

            // Performance
            SettingsSectionHeader(L("settings.terminal.performance", "Performance"), icon: "gauge.with.dots.needle.33percent")

            SettingsToggle(
                label: L("settings.terminal.localEcho", "Local Echo"),
                help: L("settings.terminal.localEcho.help", "Render typed characters immediately when the PTY has echo enabled (can reduce perceived input lag)"),
                isOn: $settings.isLocalEchoEnabled
            )

            SettingsToggle(
                label: L("settings.terminal.suspendBackgroundRendering", "Suspend Background Rendering"),
                help: L("settings.terminal.suspendBackgroundRendering.help", "Pause rendering for inactive tabs to reduce CPU usage"),
                isOn: $model.isSuspendBackgroundRendering
            )

            if model.isSuspendBackgroundRendering {
                SettingsTextField(
                    label: L("settings.terminal.suspendDelay", "Suspend Delay"),
                    help: L("settings.terminal.suspendDelay.help", "Seconds of inactivity before suspending background tabs"),
                    placeholder: "30",
                    text: $model.suspendRenderDelayText,
                    width: 80
                )
            }

            Divider()
                .padding(.vertical, 8)

            // Backend
            SettingsSectionHeader("Terminal Backend", icon: "cpu")

            SettingsToggle(
                label: "Use Rust Terminal (Experimental)",
                help: "Use the Rust-based terminal renderer instead of SwiftTerm. " +
                      "Changes take effect for new tabs only.",
                isOn: $settings.isRustTerminalEnabled
            )

            if settings.isRustTerminalEnabled {
                if RustTerminalView.isAvailable {
                    Text("New tabs will use the Rust terminal backend. Existing tabs are not affected.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.leading, 20)
                } else {
                    Text("Rust terminal library not found. The SwiftTerm backend will be used.")
                        .font(.caption)
                        .foregroundColor(.orange)
                        .padding(.leading, 20)
                }
            }

            SettingsToggle(
                label: "Metal Renderer (Experimental)",
                help: "Use GPU-accelerated Metal rendering for the SwiftTerm backend. " +
                      "Falls back to standard rendering if Metal is unavailable. " +
                      "Changes take effect for new tabs only.",
                isOn: $settings.useMetalRenderer
            )

            if settings.useMetalRenderer {
                Text("New SwiftTerm tabs will use Metal GPU rendering. The terminal still processes via SwiftTerm — Metal only handles display.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.leading, 20)
            }

            Divider()
                .padding(.vertical, 8)

            // Reset Button
            SettingsButtonRow(buttons: [
                .init(title: L("settings.terminal.resetToDefaults", "Reset Terminal to Defaults"), style: .plain) {
                    settings.resetTerminalToDefaults()
                }
            ], alignment: .trailing)
        }
    }
}
