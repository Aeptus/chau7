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
| `SettingsNavigationModel.swift` | Small observable navigation model for section selection, search query, and deep-link anchor state |
| `SettingsRootView.swift` | Standalone settings window shell, sidebar, search bar, detail router, and search-result hint |
| `SettingsSearch.swift` | Settings section grouping and searchable metadata across all settings panels |
| `ShellSettingsStore.swift` | Shell selection, custom shell path, startup command, and ls color injection |
| `ShortcutSettingsStore.swift` | Custom shortcuts, shortcut helper hints, presets, and import/export |
| `TabDisplaySettingsStore.swift` | Tab behavior, tab indicators, hover-card sections, and fullscreen toolbar behavior |
| `TerminalAppearanceStore.swift` | Terminal font, zoom, and color scheme settings |
| `TerminalBehaviorStore.swift` | Cursor, scrollback, runtime limits, bell, command guard, and default directory settings |

## Key Types

- `FeatureSettings` — singleton ObservableObject centralizing all app feature flags and preferences
- Store-behind-facade settings stores — focused persisted domains forwarded by `FeatureSettings`
- `SettingsNavigationModel` — single source of truth for settings window selection, search, and deep-link anchors
- `SettingsWindowView` / `SettingsRootView` — standalone settings window opened from Cmd+, or the status bar panel
- `KeybindingsManager` — evaluates key binding strings against NSEvent for shortcut handling
- `ConfigFileWatcher` — watches TOML config files and applies settings overrides
- `KeyboardShortcut` — Codable model for a custom keyboard shortcut (action, key, modifiers)

## Navigation And Deep Links

Settings window routing is owned by `SettingsNavigationModel`.

- `AppDelegate.showSettings(section:anchorID:)` updates the model before creating or raising the settings window.
- `SettingsRootView` binds sidebar selection and search text to the model.
- `SettingsDetailView` passes `settingsCurrentSection` and `settingsHighlightedAnchorID` through the environment so child settings views can scroll to and highlight anchors.
- User sidebar selection clears the current anchor. Search updates clear deep-link anchors and may select the first matching section.

Known status-bar routes:

| Source | Section | Anchor |
|--------|---------|--------|
| Monitoring button | `.notifications` | `eventMonitoring` |
| Pinned snippets settings button | `.snippetsTools` | `snippets` |
| Footer Settings button | `.startHere` | none |

When adding a new route, add a `SearchableSetting` entry in `SettingsSearch.swift` and a matching `.settingsSearchAnchor(...)` in the destination view or summary surface. If the destination page has internal tabs, mirror the `NotificationsSettingsView` pattern: observe `settingsHighlightedAnchorID` and switch to the correct subtab.

## Search Anchors

Search anchors serve both settings search and deep links. Keep IDs stable; they are routing contracts, not display strings.

- Prefer short semantic IDs such as `eventMonitoring`, `snippets`, or `debugConsole`.
- Title-based lookup is section-scoped. Do not depend on a title that appears in multiple settings sections.
- Advanced/disclosure content should include its child anchor IDs so matching search/deep-link targets expand automatically.

## Regression Coverage

Settings navigation tests live in `Tests/Chau7Tests/Settings/SettingsSurfaceTests.swift`.

They cover:

- every section appearing in exactly one sidebar group
- every section having search metadata and page-summary items
- stable, unique search anchors
- section-scoped title resolution
- deep-link routing to explicit and inferred sections
- search clearing deep-link anchors
- disclosure expansion from child anchors

## Dependencies

- **Uses:** Logging, Localization, Utilities (KeychainHelper)
- **Used by:** Nearly all modules (App, Overlay, Terminal, AI, Commands, Monitoring, etc.)
