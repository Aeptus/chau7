import SwiftUI

// MARK: - Input Settings

struct InputSettingsView: View {
    @ObservedObject private var settings = FeatureSettings.shared
    @State private var editingShortcut: KeyboardShortcut?
    @State private var showShortcutEditor = false

    private var presetBinding: Binding<String> {
        Binding(
            get: { settings.keybindingPreset },
            set: { newValue in
                settings.keybindingPreset = newValue
                settings.applyKeybindingPreset(newValue)
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Keyboard
            SettingsSectionHeader(L("settings.input.keyboard", "Keyboard"), icon: "keyboard")

            SettingsPicker(
                label: L("settings.input.keybindingPreset", "Keybinding Preset"),
                help: L("settings.input.keybindingPreset.help", "Choose a keyboard shortcut preset that matches your workflow"),
                selection: presetBinding,
                options: [
                    (value: "default", label: L("settings.input.default", "Default")),
                    (value: "vim", label: "Vim"),
                    (value: "emacs", label: "Emacs")
                ]
            )

            Divider()
                .padding(.vertical, 8)

            // Mouse (before shortcuts table for better flow)
            SettingsSectionHeader(L("settings.input.mouse", "Mouse"), icon: "computermouse")

            SettingsToggle(
                label: L("settings.input.copyOnSelect", "Copy on Select"),
                help: L("settings.input.copyOnSelect.help", "Automatically copy text to clipboard when you select it with the mouse"),
                isOn: $settings.isCopyOnSelectEnabled
            )

            SettingsToggle(
                label: L("settings.input.cmdClickPaths", "Cmd+Click Paths"),
                help: L("settings.input.cmdClickPaths.help", "Open file paths in your editor when you Cmd+click them in the terminal"),
                isOn: $settings.isCmdClickPathsEnabled
            )

            if settings.isCmdClickPathsEnabled {
                SettingsPicker(
                    label: L("settings.input.urlHandler", "URL Handler"),
                    help: L("settings.input.urlHandler.help", "Choose which browser opens when Cmd+clicking a URL"),
                    selection: $settings.urlHandler,
                    options: URLHandler.allCases.map { (value: $0, label: $0.displayName) }
                )

                SettingsTextField(
                    label: L("settings.input.defaultEditor", "Default Editor"),
                    help: L("settings.input.defaultEditor.help", "Editor to open files with (leave empty for system default or $EDITOR)"),
                    placeholder: "/usr/local/bin/code",
                    text: $settings.defaultEditor,
                    width: 250,
                    monospaced: true
                )

                SettingsToggle(
                    label: L("settings.input.openInInternalEditor", "Open in Internal Editor"),
                    help: L("settings.input.openInInternalEditor.help", "Open Cmd+clicked file paths in the built-in editor instead of an external application"),
                    isOn: $settings.cmdClickOpensInternalEditor
                )
            }

            SettingsToggle(
                label: L("settings.input.optionClickCursor", "Option+Click Cursor"),
                help: L("settings.input.optionClickCursor.help", "Move cursor to clicked position by pressing Option and clicking (like iTerm2)"),
                isOn: $settings.isOptionClickCursorEnabled
            )

            SettingsToggle(
                label: L("settings.input.mouseReporting", "Mouse Reporting"),
                help: L(
                    "settings.input.mouseReporting.help",
                    "Allow terminal apps (vim, tmux, etc.) to capture mouse events. When enabled, hold Shift to force text selection. When disabled, text selection always works."
                ),
                isOn: $settings.isMouseReportingEnabled
            )

            SettingsToggle(
                label: L("settings.input.clickToPosition", "Click to Position Cursor"),
                help: L("settings.input.clickToPosition.help", "Click on the input line to move cursor (like modern text editors). Click+drag still selects text."),
                isOn: $settings.isClickToPositionEnabled
            )

            Divider()
                .padding(.vertical, 8)

            // Broadcast
            SettingsSectionHeader(L("settings.input.broadcast", "Broadcast"), icon: "antenna.radiowaves.left.and.right")

            SettingsToggle(
                label: L("settings.input.broadcastInput", "Broadcast Input"),
                help: L("settings.input.broadcastInput.help", "Send keyboard input to all open tabs simultaneously (useful for multi-server commands)"),
                isOn: $settings.isBroadcastEnabled
            )

            Divider()
                .padding(.vertical, 8)

            // Keyboard Shortcuts Editor
            SettingsSectionHeader(L("settings.input.keyboardShortcuts", "Keyboard Shortcuts"), icon: "command")

            Text(L("settings.input.shortcutsHelp", "Click on a shortcut to customize it. Conflicts will be highlighted."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.bottom, 4)

            ForEach(settings.customShortcuts) { shortcut in
                KeyboardShortcutRow(
                    shortcut: shortcut,
                    hasConflict: !settings.shortcutConflicts(for: shortcut).isEmpty,
                    onEdit: {
                        editingShortcut = shortcut
                        showShortcutEditor = true
                    }
                )
            }

            SettingsToggle(
                label: L("settings.input.shortcutHelperHint", "Shortcut Helper Hint"),
                help: L("settings.input.shortcutHelperHint.help", "Show the shortcut helper hint in the bottom-right corner of the terminal"),
                isOn: $settings.isShortcutHelperHintEnabled
            )

            Divider()
                .padding(.vertical, 8)

            // Reset Button
            SettingsButtonRow(buttons: [
                .init(title: L("settings.input.resetToDefaults", "Reset Input to Defaults"), style: .plain) {
                    settings.resetInputToDefaults()
                }
            ], alignment: .trailing)
        }
        .sheet(isPresented: $showShortcutEditor) {
            if let shortcut = editingShortcut {
                ShortcutEditorSheet(shortcut: shortcut, settings: settings) {
                    showShortcutEditor = false
                    editingShortcut = nil
                }
            }
        }
    }
}

// MARK: - Keyboard Shortcut Row

struct KeyboardShortcutRow: View {
    let shortcut: KeyboardShortcut
    let hasConflict: Bool
    let onEdit: () -> Void

    var body: some View {
        Button(action: onEdit) {
            HStack {
                Text(KeyboardShortcut.actionDisplayName(shortcut.action))
                    .foregroundColor(hasConflict ? .orange : .primary)
                Spacer()
                Text(shortcut.displayString)
                    .font(.system(.body, design: .monospaced))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(hasConflict ? Color.orange.opacity(0.2) : Color.secondary.opacity(0.1))
                    .cornerRadius(4)
                    .foregroundColor(hasConflict ? .orange : .primary)
            }
        }
        .buttonStyle(.plain)
        .padding(.vertical, 2)
    }
}

// MARK: - Shortcut Editor Sheet

struct ShortcutEditorSheet: View {
    let shortcut: KeyboardShortcut
    @ObservedObject var settings: FeatureSettings
    let onDismiss: () -> Void

    @State private var key: String
    @State private var useCmd: Bool
    @State private var useShift: Bool
    @State private var useCtrl: Bool
    @State private var useOpt: Bool

    init(shortcut: KeyboardShortcut, settings: FeatureSettings, onDismiss: @escaping () -> Void) {
        self.shortcut = shortcut
        self.settings = settings
        self.onDismiss = onDismiss
        _key = State(initialValue: shortcut.key)
        _useCmd = State(initialValue: shortcut.modifiers.contains("cmd"))
        _useShift = State(initialValue: shortcut.modifiers.contains("shift"))
        _useCtrl = State(initialValue: shortcut.modifiers.contains("ctrl"))
        _useOpt = State(initialValue: shortcut.modifiers.contains("opt"))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L("settings.input.editShortcut", "Edit Shortcut:") + " \(KeyboardShortcut.actionDisplayName(shortcut.action))")
                .font(.headline)

            Divider()

            HStack {
                Text(L("settings.input.key", "Key"))
                Spacer()
                TextField(L("settings.input.key", "Key"), text: $key)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
                    .font(.system(.body, design: .monospaced))
            }

            Text(L("settings.input.modifiers", "Modifiers"))
                .font(.subheadline)
                .foregroundStyle(.secondary)

            HStack(spacing: 16) {
                Toggle(L("⌘ Cmd", "⌘ Cmd"), isOn: $useCmd)
                Toggle(L("⇧ Shift", "⇧ Shift"), isOn: $useShift)
                Toggle(L("⌃ Ctrl", "⌃ Ctrl"), isOn: $useCtrl)
                Toggle(L("⌥ Opt", "⌥ Opt"), isOn: $useOpt)
            }

            // Preview
            HStack {
                Text(L("settings.input.preview", "Preview:"))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(previewString)
                    .font(.system(.body, design: .monospaced))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.secondary.opacity(0.1))
                    .cornerRadius(4)
            }

            // Conflict warning
            if !conflicts.isEmpty {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text(L("settings.input.conflictsWith", "Conflicts with:") + " \(conflicts.map { KeyboardShortcut.actionDisplayName($0.action) }.joined(separator: ", "))")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
            }

            Divider()

            HStack {
                Button(L("button.cancel", "Cancel")) {
                    onDismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button(L("button.save", "Save")) {
                    saveShortcut()
                    onDismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(key.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 400)
    }

    private var modifiers: [String] {
        var mods: [String] = []
        if useCtrl { mods.append("ctrl") }
        if useOpt { mods.append("opt") }
        if useShift { mods.append("shift") }
        if useCmd { mods.append("cmd") }
        return mods
    }

    private var previewString: String {
        var parts: [String] = []
        if useCtrl { parts.append("⌃") }
        if useOpt { parts.append("⌥") }
        if useShift { parts.append("⇧") }
        if useCmd { parts.append("⌘") }
        parts.append(key.uppercased())
        return parts.joined()
    }

    private var conflicts: [KeyboardShortcut] {
        let testShortcut = KeyboardShortcut(action: shortcut.action, key: key, modifiers: modifiers)
        return settings.shortcutConflicts(for: testShortcut)
    }

    private func saveShortcut() {
        let updated = KeyboardShortcut(action: shortcut.action, key: key, modifiers: modifiers)
        settings.updateShortcut(updated)
    }
}
