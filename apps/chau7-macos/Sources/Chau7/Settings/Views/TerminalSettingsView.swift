import SwiftUI
import AppKit

// MARK: - Terminal Settings

struct TerminalSettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var settings = FeatureSettings.shared
    @State private var newDangerousPattern: String = ""

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

            // Dangerous Commands
            SettingsSectionHeader(L("settings.terminal.dangerousCommands", "Dangerous Commands"), icon: "exclamationmark.triangle")

            SettingsPicker(
                label: L("settings.terminal.dangerousCommands.scope", "Highlight Scope"),
                help: L("settings.terminal.dangerousCommands.scope.help", "Choose where risky patterns are highlighted"),
                selection: $settings.dangerousCommandHighlightScope,
                options: [
                    (value: .none, label: L("settings.terminal.dangerousCommands.scope.none", "None")),
                    (value: .aiOutputs, label: L("settings.terminal.dangerousCommands.scope.aiOutputs", "Only AI Outputs")),
                    (value: .allOutputs, label: L("settings.terminal.dangerousCommands.scope.allOutputs", "All Outputs"))
                ],
                width: 200
            )

            SettingsToggle(
                label: L("settings.terminal.dangerousCommands.lowPower", "Low-Power Highlighting"),
                help: L("settings.terminal.dangerousCommands.lowPower.help", "Reduce highlight work when CPU is saturated to keep the terminal responsive"),
                isOn: $settings.dangerousOutputHighlightLowPowerEnabled
            )

            Text(L("settings.terminal.dangerousCommands.help", "Commands in this list are highlighted based on the selected scope. Matching is case-insensitive and ignores extra spaces."))
                .font(.caption)
                .foregroundStyle(.secondary)

            SettingsRow(L("settings.terminal.dangerousCommands.patterns", "Patterns")) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(settings.dangerousCommandPatterns.indices, id: \.self) { index in
                        HStack(spacing: 8) {
                            TextField(
                                L("settings.terminal.dangerousCommands.patternPlaceholder", "Pattern"),
                                text: Binding(
                                    get: { settings.dangerousCommandPatterns[index] },
                                    set: { settings.dangerousCommandPatterns[index] = $0 }
                                )
                            )
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 240)
                            .font(.system(.caption, design: .monospaced))

                            Button {
                                settings.dangerousCommandPatterns.remove(at: index)
                            } label: {
                                Image(systemName: "trash")
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.borderless)
                            .help(L("settings.terminal.dangerousCommands.remove", "Remove pattern"))
                        }
                    }

                    HStack(spacing: 8) {
                        TextField(
                            L("settings.terminal.dangerousCommands.patternPlaceholder", "Pattern"),
                            text: $newDangerousPattern
                        )
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 240)
                        .font(.system(.caption, design: .monospaced))

                        Button(L("settings.terminal.dangerousCommands.add", "Add")) {
                            let trimmed = newDangerousPattern.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !trimmed.isEmpty else { return }
                            settings.dangerousCommandPatterns.append(trimmed)
                            newDangerousPattern = ""
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(newDangerousPattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }

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
