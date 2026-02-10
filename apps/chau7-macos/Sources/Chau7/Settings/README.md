# Settings

Core settings management: feature flags, keybindings, config files, and keyboard shortcuts.

## Files

| File | Purpose |
|------|---------|
| `ConfigFileWatcher.swift` | Watches ~/.chau7/config.toml and per-repo .chau7/config.toml for settings overrides |
| `EditorConfig.swift` | Codable configuration for the text editor (font size, tab size, word wrap, etc.) |
| `FeatureSettings.swift` | Central ObservableObject holding all feature flags, preferences, and UserDefaults bindings |
| `KeybindingsManager.swift` | Parses and evaluates keyboard shortcut strings into NSEvent-compatible bindings |
| `KeyboardShortcuts.swift` | Central registry documenting all keyboard shortcuts in the app |
| `KeyboardShortcutsEditor.swift` | SwiftUI editor for customizing keyboard shortcuts with conflict detection |
| `SettingsComponents.swift` | Reusable SwiftUI components (section headers, toggles, pickers, descriptions) |
| `SettingsSearch.swift` | Searchable settings metadata enabling fuzzy search across all settings panels |

## Key Types

- `FeatureSettings` — singleton ObservableObject centralizing all app feature flags and preferences
- `KeybindingsManager` — evaluates key binding strings against NSEvent for shortcut handling
- `ConfigFileWatcher` — watches TOML config files and applies settings overrides
- `KeyboardShortcut` — Codable model for a custom keyboard shortcut (action, key, modifiers)

## Dependencies

- **Uses:** Logging, Localization, Utilities (KeychainHelper)
- **Used by:** Nearly all modules (App, Overlay, Terminal, AI, Commands, Monitoring, etc.)
