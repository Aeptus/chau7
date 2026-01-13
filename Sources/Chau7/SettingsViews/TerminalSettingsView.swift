import SwiftUI
import AppKit

// MARK: - Terminal Settings

struct TerminalSettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var settings = FeatureSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Shell Settings (NEW)
            SettingsSectionHeader(L("settings.terminal.shell", "Shell"), icon: "terminal")

            SettingsPicker(
                label: L("settings.terminal.shell", "Shell"),
                help: L("settings.terminal.shell.help", "Choose which shell to use for new terminal sessions"),
                selection: $settings.shellType,
                options: ShellType.allCases.map { (value: $0, label: $0.displayName) }
            )

            if settings.shellType == .custom {
                SettingsTextField(
                    label: L("settings.terminal.customShellPath", "Custom Shell Path"),
                    help: L("settings.terminal.customShellPath.help", "Full path to your preferred shell executable"),
                    placeholder: "/usr/local/bin/fish",
                    text: $settings.customShellPath,
                    width: 250,
                    monospaced: true
                )
            }

            // Shell info
            SettingsInfoRow(label: L("settings.terminal.currentShell", "Current Shell"), value: currentShellDisplay, monospaced: true)

            SettingsTextField(
                label: L("settings.terminal.startupCommand", "Startup Command"),
                help: L("settings.terminal.startupCommand.help", "Command to run automatically when a new terminal session starts"),
                placeholder: "neofetch",
                text: $settings.startupCommand,
                width: 250,
                monospaced: true
            )

            SettingsToggle(
                label: L("settings.terminal.lsColors", "ls Colors"),
                help: L("settings.terminal.lsColors.help", "Enable colored ls output by setting CLICOLOR and LSCOLORS for new sessions"),
                isOn: $settings.isLsColorsEnabled
            )

            Divider()
                .padding(.vertical, 8)

            // Cursor
            SettingsSectionHeader(L("settings.terminal.cursor", "Cursor"), icon: "cursorarrow")

            SettingsPicker(
                label: L("settings.terminal.style", "Style"),
                help: L("settings.terminal.style.help", "Choose the cursor shape displayed in the terminal"),
                selection: $settings.cursorStyle,
                options: [
                    (value: "block", label: L("settings.terminal.cursorBlock", "Block")),
                    (value: "underline", label: L("settings.terminal.cursorUnderline", "Underline")),
                    (value: "bar", label: L("settings.terminal.cursorBar", "Bar"))
                ]
            )

            SettingsToggle(
                label: L("settings.terminal.cursorBlink", "Cursor Blink"),
                help: L("settings.terminal.cursorBlink.help", "Animate the cursor with a blinking effect"),
                isOn: $settings.cursorBlink
            )

            Divider()
                .padding(.vertical, 8)

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

            // Bell
            SettingsSectionHeader(L("settings.terminal.bell", "Bell"), icon: "bell")

            SettingsToggle(
                label: L("settings.terminal.bellEnabled", "Bell Enabled"),
                help: L("settings.terminal.bellEnabled.help", "Play a sound when the terminal bell character is received"),
                isOn: $settings.bellEnabled
            )

            if settings.bellEnabled {
                SettingsPicker(
                    label: L("settings.terminal.bellSound", "Bell Sound"),
                    help: L("settings.terminal.bellSound.help", "Choose the sound to play for terminal bell"),
                    selection: $settings.bellSound,
                    options: [
                        (value: "default", label: L("settings.terminal.bellDefault", "Default")),
                        (value: "subtle", label: L("settings.terminal.bellSubtle", "Subtle")),
                        (value: "none", label: L("settings.terminal.bellVisualOnly", "Visual Only"))
                    ]
                )
            }

            Divider()
                .padding(.vertical, 8)

            // Performance
            SettingsSectionHeader(L("settings.terminal.performance", "Performance"), icon: "gauge.with.dots.needle.33percent")

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

            // Reset Button
            SettingsButtonRow(buttons: [
                .init(title: L("settings.terminal.resetToDefaults", "Reset Terminal to Defaults"), style: .plain) {
                    settings.resetTerminalToDefaults()
                }
            ], alignment: .trailing)
        }
    }

    private var currentShellDisplay: String {
        switch settings.shellType {
        case .system:
            return ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        case .custom:
            let path = settings.customShellPath.trimmingCharacters(in: .whitespacesAndNewlines)
            return path.isEmpty ? "(not set)" : path
        default:
            return settings.shellType.rawValue
        }
    }
}
