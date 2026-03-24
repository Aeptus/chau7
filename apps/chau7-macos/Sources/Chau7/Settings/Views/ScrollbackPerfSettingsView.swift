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

            SettingsToggle(
                label: L("settings.terminal.smartScroll", "Smart Scroll"),
                help: L("settings.terminal.smartScroll.help", "Preserve scroll position when new output arrives while scrolled up"),
                isOn: $settings.isSmartScrollEnabled
            )

            SettingsStepper(
                label: L("settings.terminal.restoredScrollback", "Restored Scrollback"),
                help: L("settings.terminal.restoredScrollback.help", "Lines of scrollback restored when recovering tabs (0 = disabled)"),
                value: $settings.restoredScrollbackLines,
                range: 0 ... 10000
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
                help: L("settings.terminal.suspendBackgroundRendering.help", "Pause rendering for inactive tabs to reduce CPU/GPU usage. Tabs resume instantly when selected. Disabled by default for the fastest experience."),
                isOn: $model.isSuspendBackgroundRendering
            )

            if model.isSuspendBackgroundRendering {
                SettingsTextField(
                    label: L("settings.terminal.suspendDelay", "Suspend Delay (seconds)"),
                    help: L("settings.terminal.suspendDelay.help", "Seconds after leaving a tab before rendering is paused. Higher values keep tabs responsive longer."),
                    placeholder: "5",
                    text: $model.suspendRenderDelayText,
                    width: 80
                )
            }

            Divider()
                .padding(.vertical, 8)

            // Rendering
            SettingsSectionHeader("Rendering", icon: "cpu")

            SettingsToggle(
                label: "Metal Renderer",
                help: "Use GPU-accelerated Metal rendering for the terminal. " +
                    "Falls back to standard rendering if Metal is unavailable. " +
                    "Changes take effect for new tabs only.",
                isOn: $settings.useMetalRenderer
            )

            if settings.useMetalRenderer {
                Text("New tabs will use Metal GPU rendering for display.")
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
