# Settings/Views

SwiftUI settings panels for each feature area, presented in the preferences window.

## Files

| File | Purpose |
|------|---------|
| `AIIntegrationSettingsView.swift` | AI CLI detection patterns and theming configuration |
| `AboutSettingsView.swift` | App info, version, and credits display |
| `AppearanceSettingsView.swift` | Font, color scheme, live preview, and visual customization |
| `ConfigFileSettingsView.swift` | Config file (.chau7.toml) enable/disable, path display, and reload |
| `DangerousCommandSettingsView.swift` | Dangerous command guard toggle and pattern list editor |
| `EditorSettingsView.swift` | Text editor font size, tab size, word wrap, and bracket matching |
| `GeneralSettingsView.swift` | Startup, profile management, import/export, and reset |
| `GraphicsSettingsView.swift` | Sixel and Kitty graphics protocol settings |
| `HistorySettingsView.swift` | Command history database size, retention, and export |
| `InputSettingsView.swift` | Input behavior, keyboard shortcuts, and preset selection |
| `LLMSettingsView.swift` | LLM provider selection, API key entry, endpoint, and connection testing |
| `LogsSettingsView.swift` | Log path, monitoring toggle, and history display |
| `MinimalModeSettingsView.swift` | Minimal mode toggle and element visibility configuration |
| `NotificationsSettingsView.swift` | Notification triggers, actions, and sound configuration |
| `ProductivitySettingsView.swift` | Productivity feature toggles (bookmarks, timestamps, copy-on-select) |
| `ProfileAutoSwitchSettingsView.swift` | Auto profile switching rule editor |
| `ProxySettingsView.swift` | API analytics proxy enable/disable and port configuration |
| `RemoteSettingsView.swift` | Remote control agent status and configuration |
| `SSHProfilesSettingsView.swift` | SSH profile list with import from ~/.ssh/config |
| `TabsSettingsView.swift` | Tab behavior, close confirmation, and new tab position |
| `TerminalSettingsView.swift` | Shell selection, scrollback, and terminal emulation options |
| `TriggerActionsSettingsView.swift` | Notification trigger-to-action mapping editor |
| `WindowsSettingsView.swift` | Window behavior, restore, and multi-monitor settings |

## Key Types

- `GeneralSettingsView` — main settings entry with profile management and import/export
- `AppearanceSettingsView` — visual customization with live terminal preview
- `TerminalSettingsView` — shell and terminal emulation configuration

## Dependencies

- **Uses:** Settings, App, AI, Appearance, Commands, Editor, History, Keyboard, Migration, Monitoring, Notifications, Profiles, Proxy, Remote, RustBackend, Snippets, Localization
- **Used by:** App (settings window), StatusBar
