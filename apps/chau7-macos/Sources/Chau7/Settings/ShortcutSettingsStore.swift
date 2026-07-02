import Chau7Core
import Foundation

/// Owns the keyboard shortcut domain: the custom shortcut set, its
/// change-generation counter, one-time conflict migrations, preset
/// application, and import/export.
///
/// Extracted from `FeatureSettings` (which forwards) following the
/// store-behind-facade pattern of the other settings domains.
@Observable
final class ShortcutSettingsStore {

    enum Keys {
        static let customShortcuts = "keyboard.customShortcuts"
        static let shortcutHelperHint = "keyboard.shortcutHelperHint"
        /// Owned by the facade's keybinding-preset setting; read here only as
        /// the fallback source when no custom shortcuts are persisted.
        static let keybindingPreset = "feature.keybindingPreset"
    }

    @ObservationIgnored private let defaults: UserDefaults

    var customShortcuts: [KeyboardShortcut] {
        didSet {
            customShortcutsGeneration &+= 1
            if let data = JSONOperations.encode(customShortcuts, context: "customShortcuts") {
                defaults.set(data, forKey: Keys.customShortcuts)
            }
        }
    }

    /// Bumped whenever `customShortcuts` changes, so observers (KeybindingsManager)
    /// can detect changes with a cheap Int compare per key event instead of
    /// rebuilding and comparing a signature string.
    private(set) var customShortcutsGeneration = 0

    var isShortcutHelperHintEnabled: Bool {
        didSet { defaults.set(isShortcutHelperHintEnabled, forKey: Keys.shortcutHelperHint) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let loadedShortcuts: [KeyboardShortcut]
        if let data = defaults.data(forKey: Keys.customShortcuts),
           let shortcuts = JSONOperations.decode([KeyboardShortcut].self, from: data, context: "customShortcuts") {
            loadedShortcuts = shortcuts
        } else {
            let preset = defaults.string(forKey: Keys.keybindingPreset) ?? "default"
            loadedShortcuts = KeyboardShortcut.shortcuts(for: preset)
        }
        self.customShortcuts = Self.migratedShortcutsIfNeeded(loadedShortcuts)
        self.isShortcutHelperHintEnabled = defaults.object(forKey: Keys.shortcutHelperHint) as? Bool ?? true
    }

    // MARK: - Queries + mutations

    func shortcut(for action: String) -> KeyboardShortcut? {
        customShortcuts.first { $0.action == action }
    }

    func updateShortcut(_ shortcut: KeyboardShortcut) {
        if let index = customShortcuts.firstIndex(where: { $0.action == shortcut.action }) {
            customShortcuts[index] = shortcut
        }
    }

    func shortcutConflicts(for shortcut: KeyboardShortcut) -> [KeyboardShortcut] {
        customShortcuts.filter {
            $0.action != shortcut.action &&
                $0.key == shortcut.key &&
                Set($0.modifiers) == Set(shortcut.modifiers)
        }
    }

    /// Export keybindings to JSON data (for save-to-file workflows).
    func exportKeybindings() -> Data? {
        JSONOperations.encode(customShortcuts, context: "keybindings export")
    }

    /// Import keybindings from JSON data. Returns true on success.
    @discardableResult
    func importKeybindings(from data: Data) -> Bool {
        guard let shortcuts = JSONOperations.decode([KeyboardShortcut].self, from: data, context: "keybindings import") else {
            return false
        }
        customShortcuts = shortcuts
        return true
    }

    func applyPreset(_ preset: String) {
        customShortcuts = KeyboardShortcut.shortcuts(for: preset)
    }

    // MARK: - One-time conflict migrations

    static func migratedShortcutsIfNeeded(_ shortcuts: [KeyboardShortcut]) -> [KeyboardShortcut] {
        var updated = shortcuts
        var didUpdate = false
        let hasOpenTextEditor = updated.contains { $0.action == "openTextEditor" }
        if !hasOpenTextEditor {
            updated.append(KeyboardShortcut(action: "openTextEditor", key: "e", modifiers: ["cmd", "opt"]))
            didUpdate = true
        }

        if let debugIndex = updated.firstIndex(where: { $0.action == "debugConsole" }),
           let splitIndex = updated.firstIndex(where: { $0.action == "splitVertical" }) {
            let debugShortcut = updated[debugIndex]
            let splitShortcut = updated[splitIndex]
            let debugKey = debugShortcut.key.lowercased()
            let splitKey = splitShortcut.key.lowercased()
            let debugModifiers = Set(debugShortcut.modifiers.map { $0.lowercased() })
            let splitModifiers = Set(splitShortcut.modifiers.map { $0.lowercased() })

            let isLegacyConflict = debugKey == "d"
                && splitKey == "d"
                && debugModifiers == ["cmd", "shift"]
                && splitModifiers == ["cmd", "shift"]

            if isLegacyConflict {
                updated[debugIndex] = KeyboardShortcut(action: "debugConsole", key: "l", modifiers: ["cmd", "opt"])
                didUpdate = true
            }
        }

        if let nextIndex = updated.firstIndex(where: { $0.action == "nextTab" }) {
            let nextShortcut = updated[nextIndex]
            let nextModifiers = Set(nextShortcut.modifiers.map { $0.lowercased() })
            if nextShortcut.key.lowercased() == "]", nextModifiers == ["cmd", "opt"] {
                updated[nextIndex] = KeyboardShortcut(action: "nextTab", key: "]", modifiers: ["cmd", "shift"])
                didUpdate = true
            }
        }

        if let previousIndex = updated.firstIndex(where: { $0.action == "previousTab" }) {
            let previousShortcut = updated[previousIndex]
            let previousModifiers = Set(previousShortcut.modifiers.map { $0.lowercased() })
            if previousShortcut.key.lowercased() == "[", previousModifiers == ["cmd", "opt"] {
                updated[previousIndex] = KeyboardShortcut(action: "previousTab", key: "[", modifiers: ["cmd", "shift"])
                didUpdate = true
            }
        }

        return didUpdate ? updated : shortcuts
    }
}
