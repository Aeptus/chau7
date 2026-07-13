# Settings

Core settings management: feature flags, keybindings, config files, and keyboard shortcuts.

## Files

| File | Purpose |
|------|---------|
| `AppChromeSettingsStore.swift` | App theme, language, launch-at-login, menu bar mode, floating windows, opacity, and ligatures |
| `ConfigFileWatcher.swift` | Watches ~/.chau7/config.toml and per-repo .chau7/config.toml for settings overrides |
| `EditorConfig.swift` | Codable configuration for the text editor (font size, tab size, word wrap, etc.) |
| `FeatureSettings.swift` | Central ObservableObject holding all feature flags, preferences, and UserDefaults bindings |
| `KeybindingsManager.swift` | Parses and evaluates keyboard shortcut strings into NSEvent-compatible bindings |
| `KeyboardShortcuts.swift` | Central registry documenting all keyboard shortcuts in the app |
| `KeyboardShortcutsEditor.swift` | SwiftUI editor for customizing keyboard shortcuts with conflict detection |
| `MCPRemoteSettingsStore.swift` | MCP, remote control, and token optimization settings |
| `NotificationSettingsStore.swift` | Notification triggers, actions, conditions, rate limits, and muted repositories |
| `ProductivitySettingsStore.swift` | Clipboard, snippets, bookmarks, broadcast, path-click, and productivity toggles |
| `SettingsComponents.swift` | Reusable SwiftUI components (section headers, toggles, pickers, descriptions) |
| `SettingsSearch.swift` | Settings section grouping and searchable metadata across all settings panels |
| `ShellSettingsStore.swift` | Shell selection, custom shell path, startup command, and ls color injection |
| `ShortcutSettingsStore.swift` | Custom shortcuts, shortcut helper hints, presets, and import/export |
| `TabDisplaySettingsStore.swift` | Tab behavior, tab indicators, hover-card sections, and fullscreen toolbar behavior |
| `TerminalAppearanceStore.swift` | Terminal font, zoom, and color scheme settings |
| `TerminalBehaviorStore.swift` | Cursor, scrollback, runtime limits, bell, command guard, and default directory settings |

## Key Types

- `FeatureSettings` — singleton ObservableObject centralizing all app feature flags and preferences
- Store-behind-facade settings stores — focused persisted domains forwarded by `FeatureSettings`
- `KeybindingsManager` — evaluates key binding strings against NSEvent for shortcut handling
- `ConfigFileWatcher` — watches TOML config files and applies settings overrides
- `KeyboardShortcut` — Codable model for a custom keyboard shortcut (action, key, modifiers)

## Dependencies

- **Uses:** Logging, Localization, Utilities (KeychainHelper)
- **Used by:** Nearly all modules (App, Overlay, Terminal, AI, Commands, Monitoring, etc.)
