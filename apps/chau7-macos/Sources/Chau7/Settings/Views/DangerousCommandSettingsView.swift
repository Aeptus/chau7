import SwiftUI
import AppKit

// MARK: - Dangerous Command Guard Settings

/// Settings panel for configuring the dangerous command guard.
///
/// Provides:
/// - Master toggle to enable/disable the guard
/// - Pattern list editor (add/remove risky command patterns)
/// - Allow list management (view/remove always-allowed commands)
/// - Block list management (view/remove always-blocked commands)
/// - Reset to defaults button
struct DangerousCommandSettingsView: View {
    @Bindable private var guard_ = DangerousCommandGuard.shared
    @Bindable private var settings = FeatureSettings.shared
    @State private var newPattern = ""
    @State private var newBlockCommand = ""
    @State private var showResetConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Master toggle
            masterToggleSection

            Divider()
                .padding(.vertical, 8)

            // Pattern list editor
            patternListSection

            Divider()
                .padding(.vertical, 8)

            // Allow list
            allowListSection

            Divider()
                .padding(.vertical, 8)

            // Block list
            blockListSection

            Divider()
                .padding(.vertical, 8)

            // Reset
            resetSection
        }
    }

    // MARK: - Master Toggle

    private var masterToggleSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsSectionHeader(L("settings.dangerousGuard.title", "Command Guard"), icon: "shield.lefthalf.filled")

            SettingsToggle(
                label: L("settings.dangerousGuard.enabled", "Enable Dangerous Command Guard"),
                help: L("settings.dangerousGuard.enabled.help", "Show a confirmation dialog before executing commands that match risky patterns"),
                isOn: $guard_.isEnabled
            )

            Text(L(
                "settings.dangerousGuard.description",
                "When enabled, pressing Enter on a command that matches a risky pattern will show a confirmation dialog before the command is sent to the shell."
            ))
            .font(.caption)
            .foregroundStyle(.secondary)

            SettingsPicker(
                label: L("settings.dangerousGuard.highlightScope", "Highlight Scope"),
                help: L("settings.dangerousGuard.highlightScope.help", "Which terminal outputs are scanned for dangerous command patterns"),
                selection: $settings.dangerousCommandHighlightScope,
                options: [
                    (value: DangerousCommandHighlightScope.none, label: L("settings.dangerousGuard.scope.none", "Disabled")),
                    (value: DangerousCommandHighlightScope.aiOutputs, label: L("settings.dangerousGuard.scope.aiOutputs", "AI Outputs Only")),
                    (value: DangerousCommandHighlightScope.allOutputs, label: L("settings.dangerousGuard.scope.allOutputs", "All Outputs"))
                ],
                disabled: !guard_.isEnabled
            )
        }
    }

    // MARK: - Pattern List

    private var patternListSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsSectionHeader(L("settings.dangerousGuard.patterns", "Risky Patterns"), icon: "text.magnifyingglass")

            Text(L("settings.dangerousGuard.patterns.help", "Commands containing any of these patterns will trigger the confirmation dialog. Matching is case-insensitive."))
                .font(.caption)
                .foregroundStyle(.secondary)

            SettingsRow(L("settings.dangerousGuard.patterns.label", "Patterns")) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(settings.dangerousCommandPatterns.indices, id: \.self) { index in
                        HStack(spacing: 8) {
                            TextField(
                                L("settings.dangerousGuard.patterns.placeholder", "Pattern"),
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
                            .help(L("settings.dangerousGuard.patterns.remove", "Remove pattern"))
                        }
                    }

                    HStack(spacing: 8) {
                        TextField(
                            L("settings.dangerousGuard.patterns.placeholder", "Pattern"),
                            text: $newPattern
                        )
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 240)
                        .font(.system(.caption, design: .monospaced))
                        .onSubmit { addPattern() }

                        Button(L("settings.dangerousGuard.patterns.add", "Add")) {
                            addPattern()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(newPattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
        }
    }

    // MARK: - Allow List

    private var allowListSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsSectionHeader(L("settings.dangerousGuard.allowList", "Always Allowed"), icon: "checkmark.shield")

            Text(L("settings.dangerousGuard.allowList.help", "Commands in this list will never trigger the confirmation dialog, even if they match risky patterns."))
                .font(.caption)
                .foregroundStyle(.secondary)

            if guard_.allowList.isEmpty {
                Text(L("settings.dangerousGuard.allowList.empty", "No commands in the allow list."))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .italic()
                    .padding(.leading, 4)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(guard_.allowList).sorted(), id: \.self) { command in
                        HStack(spacing: 8) {
                            Text(command)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(width: 240, alignment: .leading)

                            Button {
                                guard_.removeFromAllowList(command)
                            } label: {
                                Image(systemName: "xmark.circle")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.borderless)
                            .help(L("settings.dangerousGuard.allowList.remove", "Remove from allow list"))
                        }
                    }

                    Button(L("settings.dangerousGuard.allowList.clearAll", "Clear All")) {
                        guard_.clearAllowList()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .padding(.top, 4)
                }
            }
        }
    }

    // MARK: - Block List

    private var blockListSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsSectionHeader(L("settings.dangerousGuard.blockList", "Always Blocked"), icon: "xmark.shield")

            Text(L("settings.dangerousGuard.blockList.help", "Commands in this list will always be blocked, regardless of patterns."))
                .font(.caption)
                .foregroundStyle(.secondary)

            if guard_.blockList.isEmpty {
                Text(L("settings.dangerousGuard.blockList.empty", "No commands in the block list."))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .italic()
                    .padding(.leading, 4)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(guard_.blockList).sorted(), id: \.self) { command in
                        HStack(spacing: 8) {
                            Text(command)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.red)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(width: 240, alignment: .leading)

                            Button {
                                guard_.removeFromBlockList(command)
                            } label: {
                                Image(systemName: "xmark.circle")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.borderless)
                            .help(L("settings.dangerousGuard.blockList.remove", "Remove from block list"))
                        }
                    }

                    Button(L("settings.dangerousGuard.blockList.clearAll", "Clear All")) {
                        guard_.clearBlockList()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .padding(.top, 4)
                }
            }

            // Add to block list
            HStack(spacing: 8) {
                TextField(
                    L("settings.dangerousGuard.blockList.placeholder", "Command to block"),
                    text: $newBlockCommand
                )
                .textFieldStyle(.roundedBorder)
                .frame(width: 240)
                .font(.system(.caption, design: .monospaced))
                .onSubmit { addToBlockList() }

                Button(L("settings.dangerousGuard.blockList.add", "Block")) {
                    addToBlockList()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(newBlockCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    // MARK: - Reset

    private var resetSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsSectionHeader(L("settings.dangerousGuard.reset", "Reset"), icon: "arrow.counterclockwise")

            Button(L("settings.dangerousGuard.resetDefaults", "Reset to Defaults")) {
                showResetConfirmation = true
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .alert(
                L("settings.dangerousGuard.resetConfirm.title", "Reset Guard Settings?"),
                isPresented: $showResetConfirmation
            ) {
                Button(L("settings.dangerousGuard.resetConfirm.cancel", "Cancel"), role: .cancel) {}
                Button(L("settings.dangerousGuard.resetConfirm.reset", "Reset"), role: .destructive) {
                    resetToDefaults()
                }
            } message: {
                Text(L("settings.dangerousGuard.resetConfirm.message", "This will reset all patterns to their defaults and clear the allow and block lists."))
            }
        }
    }

    // MARK: - Actions

    private func addPattern() {
        let trimmed = newPattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        settings.dangerousCommandPatterns.append(trimmed)
        newPattern = ""
    }

    private func addToBlockList() {
        let trimmed = newBlockCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard_.addToBlockList(trimmed)
        newBlockCommand = ""
    }

    private func resetToDefaults() {
        guard_.isEnabled = true
        guard_.clearAllowList()
        guard_.clearBlockList()
        settings.resetTerminalToDefaults()
        Log.info("DangerousCommandSettingsView: reset to defaults")
    }
}
