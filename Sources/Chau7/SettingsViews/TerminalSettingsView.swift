import SwiftUI
import AppKit

// MARK: - Terminal Settings

struct TerminalSettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var settings = FeatureSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Shell Settings (NEW)
            SettingsSectionHeader("Shell", icon: "terminal")

            SettingsPicker(
                label: "Shell",
                help: "Choose which shell to use for new terminal sessions",
                selection: $settings.shellType,
                options: ShellType.allCases.map { (value: $0, label: $0.displayName) }
            )

            if settings.shellType == .custom {
                SettingsTextField(
                    label: "Custom Shell Path",
                    help: "Full path to your preferred shell executable",
                    placeholder: "/usr/local/bin/fish",
                    text: $settings.customShellPath,
                    width: 250,
                    monospaced: true
                )
            }

            // Shell info
            SettingsInfoRow(label: "Current Shell", value: currentShellDisplay, monospaced: true)

            SettingsTextField(
                label: "Startup Command",
                help: "Command to run automatically when a new terminal session starts",
                placeholder: "neofetch",
                text: $settings.startupCommand,
                width: 250,
                monospaced: true
            )

            Divider()
                .padding(.vertical, 8)

            // Cursor
            SettingsSectionHeader("Cursor", icon: "cursorarrow")

            SettingsPicker(
                label: "Style",
                help: "Choose the cursor shape displayed in the terminal",
                selection: $settings.cursorStyle,
                options: [
                    (value: "block", label: "Block"),
                    (value: "underline", label: "Underline"),
                    (value: "bar", label: "Bar")
                ]
            )

            SettingsToggle(
                label: "Cursor Blink",
                help: "Animate the cursor with a blinking effect",
                isOn: $settings.cursorBlink
            )

            Divider()
                .padding(.vertical, 8)

            // Scrollback
            SettingsSectionHeader("Scrollback", icon: "scroll")

            SettingsNumberField(
                label: "Buffer Size",
                help: "Number of lines to keep in scrollback history (100-100,000)",
                value: $settings.scrollbackLines,
                width: 100
            )

            Divider()
                .padding(.vertical, 8)

            // Bell
            SettingsSectionHeader("Bell", icon: "bell")

            SettingsToggle(
                label: "Bell Enabled",
                help: "Play a sound when the terminal bell character is received",
                isOn: $settings.bellEnabled
            )

            if settings.bellEnabled {
                SettingsPicker(
                    label: "Bell Sound",
                    help: "Choose the sound to play for terminal bell",
                    selection: $settings.bellSound,
                    options: [
                        (value: "default", label: "Default"),
                        (value: "subtle", label: "Subtle"),
                        (value: "none", label: "Visual Only")
                    ]
                )
            }

            Divider()
                .padding(.vertical, 8)

            // Performance
            SettingsSectionHeader("Performance", icon: "gauge.with.dots.needle.33percent")

            SettingsToggle(
                label: "Suspend Background Rendering",
                help: "Pause rendering for inactive tabs to reduce CPU usage",
                isOn: $model.isSuspendBackgroundRendering
            )

            if model.isSuspendBackgroundRendering {
                SettingsTextField(
                    label: "Suspend Delay",
                    help: "Seconds of inactivity before suspending background tabs",
                    placeholder: "30",
                    text: $model.suspendRenderDelayText,
                    width: 80
                )
            }

            Divider()
                .padding(.vertical, 8)

            // Reset Button
            HStack {
                Spacer()
                Button("Reset Terminal to Defaults") {
                    settings.resetTerminalToDefaults()
                }
                .foregroundColor(.red)
            }
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
