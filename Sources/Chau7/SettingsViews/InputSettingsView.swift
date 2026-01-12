import SwiftUI

// MARK: - Input Settings

struct InputSettingsView: View {
    @ObservedObject private var settings = FeatureSettings.shared
    @State private var editingShortcut: KeyboardShortcut? = nil
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
            SettingsSectionHeader("Keyboard", icon: "keyboard")

            SettingsPicker(
                label: "Keybinding Preset",
                help: "Choose a keyboard shortcut preset that matches your workflow",
                selection: presetBinding,
                options: [
                    (value: "default", label: "Default"),
                    (value: "vim", label: "Vim"),
                    (value: "emacs", label: "Emacs")
                ]
            )

            Divider()
                .padding(.vertical, 8)

            // Keyboard Shortcuts Editor (NEW)
            SettingsSectionHeader("Keyboard Shortcuts", icon: "command")

            Text("Click on a shortcut to customize it. Conflicts will be highlighted.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.bottom, 4)

            VStack(alignment: .leading, spacing: 4) {
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
            }
            .padding(8)
            .background(Color.secondary.opacity(0.05))
            .cornerRadius(8)

            HStack {
                Button("Reset Shortcuts to Defaults") {
                    settings.resetShortcutsToDefaults()
                }
                .foregroundColor(.orange)
            }

            Divider()
                .padding(.vertical, 8)

            // Mouse
            SettingsSectionHeader("Mouse", icon: "computermouse")

            SettingsToggle(
                label: "Copy on Select",
                help: "Automatically copy text to clipboard when you select it with the mouse",
                isOn: $settings.isCopyOnSelectEnabled
            )

            SettingsToggle(
                label: "Cmd+Click Paths",
                help: "Open file paths in your editor when you Cmd+click them in the terminal",
                isOn: $settings.isCmdClickPathsEnabled
            )

            if settings.isCmdClickPathsEnabled {
                SettingsPicker(
                    label: "URL Handler",
                    help: "Choose which browser opens when Cmd+clicking a URL",
                    selection: $settings.urlHandler,
                    options: URLHandler.allCases.map { (value: $0, label: $0.displayName) }
                )

                SettingsTextField(
                    label: "Default Editor",
                    help: "Editor to open files with (leave empty for system default or $EDITOR)",
                    placeholder: "/usr/local/bin/code",
                    text: $settings.defaultEditor,
                    width: 250,
                    monospaced: true
                )
            }

            SettingsToggle(
                label: "Option+Click Cursor",
                help: "Move cursor to clicked position by pressing Option and clicking (like iTerm2)",
                isOn: $settings.isOptionClickCursorEnabled
            )

            Divider()
                .padding(.vertical, 8)

            // Broadcast
            SettingsSectionHeader("Broadcast", icon: "antenna.radiowaves.left.and.right")

            SettingsToggle(
                label: "Broadcast Input",
                help: "Send keyboard input to all open tabs simultaneously (useful for multi-server commands)",
                isOn: $settings.isBroadcastEnabled
            )

            Divider()
                .padding(.vertical, 8)

            // Reset Button
            HStack {
                Spacer()
                Button("Reset Input to Defaults") {
                    settings.resetInputToDefaults()
                }
                .foregroundColor(.red)
            }
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
            Text("Edit Shortcut: \(KeyboardShortcut.actionDisplayName(shortcut.action))")
                .font(.headline)

            Divider()

            HStack {
                Text("Key")
                Spacer()
                TextField("Key", text: $key)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
                    .font(.system(.body, design: .monospaced))
            }

            Text("Modifiers")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            HStack(spacing: 16) {
                Toggle("⌘ Cmd", isOn: $useCmd)
                Toggle("⇧ Shift", isOn: $useShift)
                Toggle("⌃ Ctrl", isOn: $useCtrl)
                Toggle("⌥ Opt", isOn: $useOpt)
            }

            // Preview
            HStack {
                Text("Preview:")
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
                    Text("Conflicts with: \(conflicts.map { KeyboardShortcut.actionDisplayName($0.action) }.joined(separator: ", "))")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
            }

            Divider()

            HStack {
                Button("Cancel") {
                    onDismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Save") {
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
