# Settings/Views

SwiftUI settings panels for each feature area, presented in the preferences window.

## Files

| File | Purpose |
|------|---------|
| `AIIntegrationSettingsView.swift` | AI CLI detection patterns and theming configuration |
| `AboutSettingsView.swift` | App info, version, and credits display |
| `AppearanceSettingsView.swift` | Shared appearance preview helpers used by font/color settings |
| `ConfigFileSettingsView.swift` | Config file (.chau7.toml) enable/disable, path display, and reload |
| `DangerousCommandSettingsView.swift` | Dangerous command guard toggle and pattern list editor |
| `DisplaySettingsView.swift` | Terminal output rendering toggles such as URLs, images, JSON, and timestamps |
| `EditorSettingsView.swift` | Text editor font size, tab size, word wrap, and bracket matching |
| `FontColorsSettingsView.swift` | Font, color scheme, app theme, opacity, ligatures, and live preview |
| `GeneralSettingsView.swift` | Startup, language, config file, status, app actions, and reset |
| `GraphicsSettingsView.swift` | Sixel and Kitty graphics protocol settings |
| `HoverCardSettingsView.swift` | Tab hover card visible-section toggles |
| `HistorySettingsView.swift` | Command history database size, retention, and export |
| `InputSettingsView.swift` | Input behavior, keyboard shortcuts, and preset selection |
| `LLMSettingsView.swift` | LLM provider selection, API key entry, endpoint, and connection testing |
| `LogsSettingsView.swift` | Diagnostic log paths, monitoring toggles, and active session display |
| `MCPSettingsView.swift` | MCP server enablement, limits, permissions, indicators, and profiles |
| `MinimalModeSettingsView.swift` | Minimal mode toggle and element visibility configuration |
| `NotificationsSettingsView.swift` | Alert triggers, actions, and sound configuration |
| `ProfileSelectorBar.swift` | Settings profile selector and save/load menu |
| `ProductivitySettingsView.swift` | Snippets, clipboard history, bookmarks, semantic search, and protected-folder permissions |
| `ProfileAutoSwitchSettingsView.swift` | Auto profile switching rule editor |
| `ProfilesBackupSettingsView.swift` | iCloud sync, profile auto-switching, and settings import/export |
| `PromptInjectionSettingsView.swift` | Per-repository AI prompt injection rules |
| `ProxySettingsView.swift` | API analytics proxy enable/disable and port configuration |
| `RepositoriesSettingsView.swift` | Per-repository metadata, labels, and favorite files |
| `RemoteSettingsView.swift` | Remote access relay, pairing, device, and agent status configuration |
| `ScrollbackPerfSettingsView.swift` | Scrollback, restore, rendering, and refresh performance settings |
| `SSHProfilesSettingsView.swift` | SSH profile list with import from ~/.ssh/config |
| `SettingsPageSummaryView.swift` | Shared per-page status strip for settings enabled state, health, key values, warnings, and counts |
| `ShellSettingsView.swift` | Shell, startup command, shell history, cursor, and bell settings |
| `TabsSettingsView.swift` | Tab behavior, close confirmation, and new tab position |
| `TokenOptimizationSettingsView.swift` | Context optimization mode and prefix with runtime/debug controls under Advanced |
| `TriggerActionsSettingsView.swift` | Notification trigger-to-action mapping editor |
| `WindowsSettingsView.swift` | App window mode, floating windows, overlay actions, fullscreen toolbar, and split panes |

## Key Types

- `GeneralSettingsView` — main settings entry with profile management and import/export
- `SettingsSection` / `SettingsSectionGroup` — sidebar grouping and detail routing metadata
- `SettingsAdvancedDisclosure` — shared progressive disclosure for non-daily settings, with search-driven expansion for hidden anchors
- `SettingsPageSummaryView` — shared compact status strip inserted by the settings detail shell for every routed page
- `SettingsButtonRow` / `SettingsEmptyStateView` / `SettingsStatusGrid` — shared alignment primitives for settings actions, empty lists, and status surfaces
- `SearchableSetting` anchors — stable IDs used by settings search to scroll to and highlight matching rows or section targets
- `FontColorsSettingsView` — visual customization with live terminal preview
- `ShellSettingsView` / `ScrollbackPerfSettingsView` — terminal shell, scrollback, and rendering configuration

## Dependencies

- **Uses:** Settings, App, AI, Appearance, Commands, Editor, History, Keyboard, Migration, Monitoring, Notifications, Profiles, Proxy, Remote, RustBackend, Snippets, Localization
- **Used by:** App (settings window), StatusBar
