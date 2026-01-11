import SwiftUI
import AppKit
import Carbon

// MARK: - Keyboard Shortcuts Editor View

struct KeyboardShortcutsEditorView: View {
    @ObservedObject private var settings = FeatureSettings.shared
    @State private var editingShortcut: KeyboardShortcut?
    @State private var searchText = ""
    @State private var showConflictAlert = false
    @State private var conflictingShortcuts: [KeyboardShortcut] = []

    private var filteredShortcuts: [KeyboardShortcut] {
        if searchText.isEmpty {
            return settings.customShortcuts
        }
        let query = searchText.lowercased()
        return settings.customShortcuts.filter {
            $0.action.lowercased().contains(query) ||
            KeyboardShortcut.actionDisplayName($0.action).lowercased().contains(query)
        }
    }

    private var groupedShortcuts: [(String, [KeyboardShortcut])] {
        let groups: [(String, [String])] = [
            ("Tabs", ["newTab", "closeTab", "nextTab", "previousTab", "renameTab"]),
            ("Edit", ["copy", "paste", "find", "findNext", "findPrevious", "snippets"]),
            ("View", ["zoomIn", "zoomOut", "zoomReset", "clear"]),
            ("Window", ["newWindow", "splitHorizontal", "splitVertical", "debugConsole"])
        ]

        return groups.compactMap { (name, actions) in
            let shortcuts = filteredShortcuts.filter { actions.contains($0.action) }
            return shortcuts.isEmpty ? nil : (name, shortcuts)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Keyboard Shortcuts")
                    .font(.headline)

                Spacer()

                Button("Reset to Defaults") {
                    settings.resetShortcutsToDefaults()
                }
                .buttonStyle(.link)
            }
            .padding()

            // Search
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("Search shortcuts...", text: $searchText)
                    .textFieldStyle(.plain)
            }
            .padding(8)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(8)
            .padding(.horizontal)

            Divider()
                .padding(.top, 8)

            // Shortcut list
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(groupedShortcuts, id: \.0) { group, shortcuts in
                        ShortcutGroupView(
                            title: group,
                            shortcuts: shortcuts,
                            editingShortcut: $editingShortcut,
                            onUpdate: { updated in
                                updateShortcut(updated)
                            }
                        )
                    }
                }
                .padding()
            }

            // Footer
            HStack {
                Image(systemName: "info.circle")
                    .foregroundColor(.secondary)
                Text("Click a shortcut to edit. Press the new key combination to change it.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))
        }
        .alert("Shortcut Conflict", isPresented: $showConflictAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            let names = conflictingShortcuts.map { KeyboardShortcut.actionDisplayName($0.action) }.joined(separator: ", ")
            Text("This shortcut is already used by: \(names)")
        }
    }

    private func updateShortcut(_ shortcut: KeyboardShortcut) {
        // Check for conflicts
        let conflicts = settings.shortcutConflicts(for: shortcut)
        if !conflicts.isEmpty {
            conflictingShortcuts = conflicts
            showConflictAlert = true
            return
        }

        settings.updateShortcut(shortcut)
        editingShortcut = nil
    }
}

// MARK: - Shortcut Group View

private struct ShortcutGroupView: View {
    let title: String
    let shortcuts: [KeyboardShortcut]
    @Binding var editingShortcut: KeyboardShortcut?
    let onUpdate: (KeyboardShortcut) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.secondary)
                .textCase(.uppercase)

            VStack(spacing: 0) {
                ForEach(shortcuts) { shortcut in
                    ShortcutRowView(
                        shortcut: shortcut,
                        isEditing: editingShortcut?.action == shortcut.action,
                        onStartEdit: {
                            editingShortcut = shortcut
                        },
                        onUpdate: onUpdate,
                        onCancel: {
                            editingShortcut = nil
                        }
                    )

                    if shortcut.id != shortcuts.last?.id {
                        Divider()
                    }
                }
            }
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(8)
        }
    }
}

// MARK: - Shortcut Row View

private struct ShortcutRowView: View {
    let shortcut: KeyboardShortcut
    let isEditing: Bool
    let onStartEdit: () -> Void
    let onUpdate: (KeyboardShortcut) -> Void
    let onCancel: () -> Void

    @State private var recordedKey: String?
    @State private var recordedModifiers: [String] = []

    var body: some View {
        HStack {
            Text(KeyboardShortcut.actionDisplayName(shortcut.action))
                .font(.system(size: 13))

            Spacer()

            if isEditing {
                // Recording state
                HStack(spacing: 8) {
                    ShortcutRecorderView(
                        onRecord: { key, modifiers in
                            recordedKey = key
                            recordedModifiers = modifiers
                        }
                    )

                    Button("Save") {
                        if let key = recordedKey {
                            var updated = shortcut
                            updated.key = key
                            updated.modifiers = recordedModifiers
                            onUpdate(updated)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(recordedKey == nil)

                    Button("Cancel") {
                        onCancel()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            } else {
                // Display state
                Button {
                    onStartEdit()
                } label: {
                    Text(shortcut.displayString)
                        .font(.system(size: 12, design: .monospaced))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color(NSColor.separatorColor).opacity(0.3))
                        .cornerRadius(4)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }
}

// MARK: - Shortcut Recorder View

private struct ShortcutRecorderView: NSViewRepresentable {
    let onRecord: (String, [String]) -> Void

    func makeNSView(context: Context) -> ShortcutRecorderField {
        let field = ShortcutRecorderField()
        field.onRecord = onRecord
        return field
    }

    func updateNSView(_ nsView: ShortcutRecorderField, context: Context) {}
}

// MARK: - Shortcut Recorder Field (NSView)

final class ShortcutRecorderField: NSTextField {
    var onRecord: ((String, [String]) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        isEditable = false
        isSelectable = false
        isBordered = true
        bezelStyle = .roundedBezel
        alignment = .center
        font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        stringValue = "Press shortcut..."
        placeholderString = "Press shortcut..."

        // Make it focusable
        focusRingType = .exterior
    }

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        stringValue = "Press shortcut..."
        return super.becomeFirstResponder()
    }

    override func keyDown(with event: NSEvent) {
        // Ignore modifier-only presses
        guard let chars = event.charactersIgnoringModifiers, !chars.isEmpty else {
            return
        }

        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifierNames: [String] = []

        if modifiers.contains(.control) { modifierNames.append("ctrl") }
        if modifiers.contains(.option) { modifierNames.append("opt") }
        if modifiers.contains(.shift) { modifierNames.append("shift") }
        if modifiers.contains(.command) { modifierNames.append("cmd") }

        // Get the key
        let key = chars.lowercased()

        // Build display string
        var display: [String] = []
        if modifiers.contains(.control) { display.append("⌃") }
        if modifiers.contains(.option) { display.append("⌥") }
        if modifiers.contains(.shift) { display.append("⇧") }
        if modifiers.contains(.command) { display.append("⌘") }
        display.append(key.uppercased())

        stringValue = display.joined()
        onRecord?(key, modifierNames)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Capture all key equivalents when focused
        if window?.firstResponder === self {
            keyDown(with: event)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

// MARK: - Keyboard Shortcuts Window Controller

final class KeyboardShortcutsWindowController {
    static let shared = KeyboardShortcutsWindowController()

    private var window: NSWindow?

    private init() {}

    func show() {
        if let existing = window, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            return
        }

        let view = KeyboardShortcutsEditorView()
        let hostingView = NSHostingView(rootView: view)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 600),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Keyboard Shortcuts"
        window.contentView = hostingView
        window.center()
        window.makeKeyAndOrderFront(nil)

        self.window = window
    }
}
