# Settings

Swift: `apps/chau7-macos/Sources/Chau7/Settings/` (40 files, 15,540 lines)
Swift tests: `Settings/FeatureSettingsTests`, `Settings/KeybindingsManagerTests`, `Profiles/ProfileSwitchRuleTests`, `Utilities/ConfigFileParserTests` (Chau7Core), `Commands/DangerousCommandGuardTests`
Wave: 1
Depends on: none for the settings infrastructure. Rows that only toggle a feature (notifications, MCP, CTO, remote, proxy, editor, graphics, minimal mode, history) are done together with the module that owns that feature.

The Settings module holds every user preference (`FeatureSettings`, persisted in
UserDefaults), the settings window panes (23 sections in 6 groups, shown by
`StatusBar/MainPanelView.swift`), settings search, profiles, backup and iCloud
sync, the `config.toml` loader and watcher, and the customizable keybindings.

## Features

Rust paths are relative to `apps/chau7-next/crates/`. Keys in backticks are
UserDefaults keys (Swift) or `config.toml` keys (`[section] key`).

### Settings infrastructure

| ID | Feature | Swift source | Tests | Rust | Status | macOS API |
|---|---|---|---|---|---|---|
| SET-001 | Settings window (Cmd+,) with a sidebar of 23 sections in 6 groups (Essentials, Look & Feel, Terminal, Input & Productivity, Integrations, Monitoring); Rust has one scrolling page with 5 sections (Text, Colors, Tabs, Keyboard and mouse, Files) | `Settings/SettingsSearch.swift` (sections), `StatusBar/MainPanelView.swift` |  | `chau7_next/src/settings_window/mod.rs` (sidebar of 23 sections in 6 groups; sections not ported show a note), `chau7_next_core/src/settings_search.rs` | done |  |
| SET-002 | Search in settings: query filters sections by title, keywords and description, shows match counts per section (66 searchable entries) | `Settings/SettingsSearch.swift` |  | `chau7_next/src/settings_window/mod.rs` (search field, match counts), `chau7_next_core/src/settings_search.rs` (66 entries) | done |  |
| SET-003 | Changes apply live to every window and persist immediately | `Settings/FeatureSettings.swift` | | `chau7_next/src/settings_window/` (`update`), `chau7_next/src/settings/` (`save`) | done | |
| SET-004 | Reset All Settings to Defaults (General pane, with confirmation) | `Settings/Views/GeneralSettingsView.swift`, `FeatureSettings.resetAllToDefaults` |  | `chau7_next/src/settings_window/general.rs` (`confirm_reset_all`), `chau7_next/src/settings/mod.rs` (`reset_all`) | done |  |
| SET-005 | Per-section reset buttons: Font & Colors, Display, Shell, Terminal, Input, Tabs, Productivity, Editor, Dangerous Commands guard, notification trigger conditions | `FeatureSettings.reset*ToDefaults`, section views | `FeatureSettingsTests.testResetShortcutsToDefaults` | chau7_next/src/settings/mod.rs (reset_section), chau7_next/src/settings_window/mod.rs, chau7_next/src/settings_window/notifications.rs (condition Reset to defaults) | done |  |
| SET-006 | Export settings to a JSON file (`chau7-settings.json`, `ExportableSettings`) | `Settings/Views/ProfilesBackupSettingsView.swift`, `FeatureSettings.exportSettings` |  | `chau7_next/src/settings/export.rs` (`export_json`), `chau7_next/src/settings_window/backup.rs` | done |  |
| SET-007 | Import settings from a JSON file, with an error message on invalid files; missing fields keep backward-compatible defaults | `ProfilesBackupSettingsView.swift`, `FeatureSettings.importSettings` |  | `chau7_next/src/settings/export.rs` (`import_json`), `chau7_next/src/settings_window/backup.rs` | done |  |
| SET-008 | iCloud sync of settings: toggle (`sync.iCloudEnabled`), Sync Now, Restore from iCloud, debounced auto-sync (2 s), apply changes pushed from other Macs | `FeatureSettings.swift` (iCloud Sync), `ProfilesBackupSettingsView.swift` |  | `chau7_next/src/settings/sync.rs`, `chau7_next/src/platform/icloud.rs` (`CloudStore`, stub off macOS), `chau7_next/src/settings_window/backup.rs` | done | NSUbiquitousKeyValueStore |
| SET-009 | Settings profiles: create from current settings (name and icon), load, save current into a profile, delete, deactivate; profile selector menu at the top of the settings window (`settings.profiles`, `settings.activeProfile`) | `Settings/Views/ProfileSelectorBar.swift`, `FeatureSettings.swift` (Profile Management) |  | chau7_next/src/settings_window/mine/profiles.rs,chau7_next_core/src/settings_profiles.rs | done |  |
| SET-010 | Profile auto-switch rules: trigger on directory, git repo, SSH host, running process or environment variable; priority, enable flag, active rule banner, restore previous profile | `Settings/Views/ProfileAutoSwitchSettingsView.swift` | `ProfileSwitchRuleTests` | chau7_next/src/settings_window/mine/profiles.rs, chau7_next_core/src/settings_profiles.rs, chau7_next/src/profiles/mod.rs (rule_context: processes, SSH host, environment), chau7_next/src/platform/process.rs (process_args_env), chau7_next_core/src/procargs.rs | done |  |
| SET-011 | Global config file loaded at launch and applied over settings | `Settings/ConfigFileWatcher.swift`, `Chau7Core/ConfigFileParser.swift` | `ConfigFileParserTests` | `chau7_next_core/src/config.rs`, `chau7_next/src/settings/` (`load`) | done | |
| SET-012 | Config file reloads automatically when saved (file watch on write and rename) | `ConfigFileWatcher.startWatching` |  | `chau7_next/src/settings/config_files.rs` (`tick`: file stamp checked about once a second) | done |  |
| SET-013 | Per-repo `.chau7/config.toml` overrides the global config for the active tab's directory (re-resolved on tab switch); Create Per-Repo Config, Open in Editor, "Repo config active" indicator | `ConfigFileWatcher.swift`, `Settings/Views/ConfigFileSettingsView.swift` |  | `chau7_next/src/settings/config_files.rs` (`with_repo_overrides`), `chau7_next/src/settings_window/general.rs` (create, open, active indicator) | done |  |
| SET-014 | "Load Config Files" toggle (`feature.configFile`, default on) | `ConfigFileSettingsView.swift` |  | `chau7_next/src/settings/general.rs` (`load_config_files`), `chau7_next/src/settings_window/general.rs` | done |  |
| SET-015 | Config file status: path, last loaded time, last error | `ConfigFileSettingsView.swift` |  | `chau7_next/src/settings_window/general.rs` (path, last loaded, last error), `chau7_next/src/settings/config_files.rs` | done |  |
| SET-016 | Create Default Config, Open in Editor, Reload Now buttons | `ConfigFileSettingsView.swift` | | `chau7_next/src/main.rs` (`OpenConfigFile` writes the default file if missing, `ReloadConfig`), `settings_window/` ("Open config.toml", "Show data folder") | done | |
| SET-017 | (hidden) Stored keys with no UI and no reader: font weight (`terminal.fontWeight`), cursor color (`terminal.cursorColor`), cursor blink rate (`terminal.cursorBlinkRate`), Unicode ambiguous width (`terminal.unicodeAmbiguousWidth`), visual bell (`terminal.bellVisual`), bell rate limit (`terminal.bellRateLimitSeconds`), dangerous output highlight tuning (`terminal.dangerousOutputHighlight*`) | `Settings/FeatureSettings.swift` | | | n/a | |

### General

| ID | Feature | Swift source | Tests | Rust | Status | macOS API |
|---|---|---|---|---|---|---|
| SET-018 | Launch at Login (`app.launchAtLogin`) | `Settings/Views/GeneralSettingsView.swift`, `Migration/LaunchAtLoginManager.swift` |  | `chau7_next/src/settings_window/general.rs` (`set_launch_at_login`), `chau7_next/src/platform/login_item.rs` | done | LaunchAgent |
| SET-019 | Default directory for new sessions, with Choose... picker (`terminal.defaultStartDirectory`, `[general] default_directory`) | `GeneralSettingsView.swift` |  | chau7_next/src/settings/general.rs, chau7_next/src/settings_window/shell.rs (choose_directory) | done |  |
| SET-020 | App language picker (`app.language`) | `GeneralSettingsView.swift` |  | crates/chau7_next/src/settings/general.rs | done |  |
| SET-021 | Status rows: notification permission, event, history and terminal monitoring states | `GeneralSettingsView.swift` |  | `chau7_next/src/monitoring_status.rs`, `chau7_next/src/settings_window/general.rs`, `chau7_next/src/ai/hub.rs` (events), `chau7_next/src/history/monitor.rs` (history, terminal), `chau7_next/src/notifications/banner.rs` (permission) | done |  |
| SET-022 | Action buttons: Show Overlay, Reset Window Positions (overlay offsets per workspace, `overlay.positions.map`), Debug Console | `GeneralSettingsView.swift`, `FeatureSettings.resetOverlayOffsets` |  | chau7_next/src/settings_window/general.rs, chau7_next/src/debug/mod.rs | done |  |
| SET-023 | Current Windows page exposes menu bar only mode (restart to apply accessory/Dock policy) and floating window (live); Next persists own config values, with read-only fallback to its existing native preference | `FeatureSettings.swift`, `App/Chau7App.swift`, `App/AppDelegate.swift` | settings::export::tests::current_windows_values_survive_both_owned_formats; settings::tests::current_appearance_pages_reset_only_their_own_values | chau7_next/src/settings_window/windows.rs; chau7_next/src/settings/appearance.rs; chau7_next/src/settings/export.rs; chau7_next/src/app_actions.rs; chau7_next/src/workspace/window.rs | done | NSApplication.ActivationPolicy; NSWindow.level; isolated native acceptance pending |
| SET-024 | About pane: version, bundle ID, build date, macOS version, architecture, `$SHELL`, links (GitHub, issues, docs), log path with Reveal in Finder and Debug Console, acknowledgments; Rust "About" only logs the version and opens the config folder | `Settings/Views/AboutSettingsView.swift` |  | `chau7_next/src/settings_window/about.rs` | done |  |

### Font & Colors

| ID | Feature | Swift source | Tests | Rust | Status | macOS API |
|---|---|---|---|---|---|---|
| SET-025 | Font family picker listing installed fonts from a curated list of 79 monospace fonts, each name drawn in its own typeface (`terminal.fontFamily`, `[appearance] font_family`) | `Settings/Views/FontColorsSettingsView.swift`, `FeatureSettings.availableFonts` | `FeatureSettingsTests.testDefaultFontFamily` | `chau7_next_core/src/font_catalog.rs`, `chau7_next/src/settings_window/text.rs` | done | NSFontManager |
| SET-026 | Custom font family field with live validation (check or cross icon), applied on Enter (`terminal.customFontFamily`) | `FontColorsSettingsView.swift` |  | `chau7_next/src/settings_window/mod.rs`, `chau7_next/src/settings_window/text.rs` (`validate_font`) | done | NSFontManager |
| SET-027 | Font size, 8 to 72 pt (`terminal.fontSize`, `[appearance] font_size`) | `FontColorsSettingsView.swift` | `FeatureSettingsTests.testDefaultFontSize` | `chau7_next/src/settings_window/`, `chau7_next/src/settings/` | done | |
| SET-028 | Default zoom for new sessions, 50 to 200% (`terminal.defaultZoomPercent`) | `FontColorsSettingsView.swift` | `FeatureSettingsTests.testDefaultZoomPercent` | `chau7_next/src/settings/appearance.rs` (`default_zoom_percent`, `zoomed_font_size`), `chau7_next/src/settings_window/text.rs` | done |  |
| SET-029 | Font ligatures toggle (`terminal.enableLigatures`) | `FontColorsSettingsView.swift` |  | `chau7_next/src/settings_window/text.rs`, `chau7_next/src/settings/appearance.rs` | done |  |
| SET-030 | Live terminal preview panel and font preview line in the pane | `FontColorsSettingsView.swift`, `Settings/Views/AppearanceSettingsView.swift` (`LiveTerminalPreview`) |  | `chau7_next/src/settings_window/colors.rs` (`live_preview`), `chau7_next/src/settings_window/text.rs` | done |  |
| SET-031 | Color scheme picker with palette preview, 8 presets: Default, Solarized Dark, Solarized Light, Dracula, Nord, Monokai, Gruvbox Dark, Tokyo Night (`terminal.colorSchemeName`, `[appearance] color_scheme`) | `FontColorsSettingsView.swift`, `AppearanceSettingsView.swift` (`ColorSchemePreview`) | `FeatureSettingsTests.testDefaultColorSchemeName`, `testCurrentColorSchemeIsNotNil` | `chau7_next/src/settings_window/`, `chau7_next_core/src/color_schemes.rs` | done | |
| SET-032 | Custom color scheme named "Custom" (`terminal.customColorScheme`, JSON); no editor, only set through import or profiles | `FeatureSettings.swift` |  | `chau7_next_core/src/color_schemes.rs`, `chau7_next/src/settings/appearance.rs`, `chau7_next/src/settings_window/colors.rs` | done |  |
| SET-033 | Window opacity, 30 to 100% (`window.opacity`, `[appearance] opacity`) | `FontColorsSettingsView.swift` | `FeatureSettingsTests.testDefaultWindowOpacity` | `chau7_next/src/settings_window/`, `chau7_next/src/settings/` | done | |
| SET-034 | App appearance: System, Light, Dark (`app.theme`) | `FontColorsSettingsView.swift` | `FeatureSettingsTests.testDefaultAppTheme` | `chau7_next/src/settings_window/colors.rs`, `chau7_next/src/settings/appearance.rs` (`AppTheme`) | done |  |

### Display

| ID | Feature | Swift source | Tests | Rust | Status | macOS API |
|---|---|---|---|---|---|---|
| SET-035 | Syntax highlighting of terminal output (`feature.syntaxHighlight`) | `Settings/Views/DisplaySettingsView.swift` |  | `chau7_next/src/settings_window/display.rs`, `chau7_next/src/settings/appearance.rs` (`DisplayOptions`) | done |  |
| SET-036 | Clickable URLs toggle (`feature.clickableURLs`); Swift only reads it in the log view highlighter, Chau7 Next also stops Cmd+click on plain-text URLs (OSC 8 links stay clickable) | `DisplaySettingsView.swift` |  | `chau7_next/src/settings_window/display.rs`, `chau7_next/src/terminal/view.rs` (`url_at`) | done |  |
| SET-037 | Inline images (iTerm2 imgcat) toggle (`feature.inlineImages`) | `DisplaySettingsView.swift` |  | `chau7_next/src/settings_window/display.rs`, `chau7_next/src/terminal/images.rs` | done |  |
| SET-038 | Pretty print JSON output (`feature.jsonPrettyPrint`) | `DisplaySettingsView.swift` |  | `chau7_next/src/settings_window/display.rs`, `chau7_next/src/settings/appearance.rs` | done |  |
| SET-039 | Line timestamps and timestamp format (`feature.lineTimestamps`, `feature.timestampFormat`, default `HH:mm:ss`) | `DisplaySettingsView.swift` | `FeatureSettingsTests.testDefaultTimestampFormat` | `chau7_next_core/src/line_timestamps.rs`, `chau7_next/src/terminal/paint.rs`, `chau7_next/src/settings_window/display.rs` | done |  |
| SET-040 | Enable Split Panes toggle (`feature.splitPanes`, `[next] split_panes`); off blocks new terminal splits | `DisplaySettingsView.swift` |  | chau7_next/src/pane.rs,chau7_next/src/settings/terminal.rs,chau7_next/src/settings_window/panes.rs | done |  |
| SET-041 | Always Show Toolbar in Fullscreen is visible on the current Windows page, persisted and reset in the Windows domain; current Swift only stores/exports this flag and has no rendering consumer, as does Next | `Settings/Views/WindowsSettingsView.swift` |  | chau7_next/src/settings/tabs.rs; chau7_next/src/settings_window/windows.rs; chau7_next/src/settings/mod.rs | done | Current source search confirms the Swift flag has no rendering consumer |

### Tabs

| ID | Feature | Swift source | Tests | Rust | Status | macOS API |
|---|---|---|---|---|---|---|
| SET-042 | New tab position: at end or after current (`tabs.newTabPosition`, Rust `[next] new_tab_position`) | `Settings/Views/TabsSettingsView.swift` | `FeatureSettingsTests.testDefaultNewTabPosition` | `chau7_next/src/settings_window/`, `chau7_next_core/src/tabs_state.rs` | done | |
| SET-043 | New tabs use the current tab's directory (`tabs.newTabsUseCurrentDirectory`, Rust `[next] new_tabs_use_current_directory`) | `TabsSettingsView.swift` |  | chau7_next/src/settings/tabs.rs, chau7_next/src/settings_window/tabs.rs, chau7_next/src/workspace/mod.rs (inherited_start_directory) | done |  |
| SET-044 | Last tab close: keep window open with a new tab (default) or close window (`tabs.lastTabCloseBehavior`, Rust `[next] last_tab_close_behavior`); Swift never reads it: closing the last tab always asks "Close Window" or "New Tab", and Rust does the same | `TabsSettingsView.swift` | `FeatureSettingsTests.testDefaultLastTabCloseBehavior` | chau7_next/src/settings/tabs.rs, chau7_next/src/settings_window/tabs.rs, chau7_next/src/workspace/mod.rs (confirm_close_last_tab) | done |  |
| SET-045 | Warn when closing a tab with a running process (`tabs.warnOnCloseWithProcess`, Rust `[next] warn_on_close_running`) | `TabsSettingsView.swift` | `FeatureSettingsTests.testDefaultWarnOnCloseWithRunningProcess` | `chau7_next/src/workspace/`, `settings_window/` | done | |
| SET-046 | Always warn before closing any tab (`tabs.alwaysWarnOnTabClose`, Rust `[general] confirm_close`), with "Don't ask again" (a third button in Rust) | `TabsSettingsView.swift` |  | chau7_next/src/settings/tabs.rs (confirm_close), chau7_next/src/settings_window/tabs.rs, chau7_next/src/workspace/mod.rs | done |  |
| SET-047 | Always show tab bar, even with one tab (`tabs.alwaysShowTabBar`, Rust `[next] always_show_tab_bar`); Swift never reads it, Rust hides the tabs of a single-tab window when it is off | `TabsSettingsView.swift` | `FeatureSettingsTests.testDefaultAlwaysShowTabBar` | chau7_next/src/settings/tabs.rs, chau7_next/src/settings_window/tabs.rs, chau7_next/src/workspace/tab_bar_view.rs (tab_bar_visible) | done |  |
| SET-048 | Group idle tabs in a dropdown and idle threshold in minutes (`tabs.groupIdleTabs`, `tabs.idleTabThresholdMinutes`, Rust `[next] group_idle_tabs`, `idle_tab_minutes`) | `TabsSettingsView.swift` | | `chau7_next/src/settings_window/`, `chau7_next/src/workspace/` | done | |
| SET-049 | Repo grouping: Off, Automatic, Manual (`tabs.repoGroupingMode`, Rust `[next] repo_grouping_mode`; the old `auto_repo_grouping` key is still read) | `TabsSettingsView.swift` |  | chau7_next/src/settings/tabs.rs (RepoGroupingMode), chau7_next/src/settings_window/tabs.rs | done |  |
| SET-050 | Custom title only: a tab with a custom title hides icons, path and indicators (`tabs.display.customTitleOnly`, Rust `[next] custom_title_only`) | `TabsSettingsView.swift` |  | chau7_next/src/settings/tabs.rs, chau7_next/src/settings_window/tabs.rs, chau7_next/src/workspace/tab_bar_view.rs | done |  |
| SET-051 | Tab icons and AI product logos (`tabs.display.showIcons`, `feature.autoTabTheme`, Rust `[next] show_tab_icons`, `auto_tab_theme`) | `TabsSettingsView.swift` |  | chau7_next/src/settings/tabs.rs, chau7_next/src/settings_window/tabs.rs, chau7_next/src/workspace/tab_bar_view.rs (ai_logo) | done |  |
| SET-052 | Show working directory path in tabs (`tabs.display.showPath`, Rust `[next] show_tab_path`) | `TabsSettingsView.swift` |  | chau7_next/src/settings/tabs.rs, chau7_next/src/settings_window/tabs.rs, chau7_next/src/workspace/tab_bar_view.rs | done |  |
| SET-053 | Show git branch indicator in tabs (`tabs.display.showGitIndicator`, Rust `[next] show_tab_git_indicator`) | `TabsSettingsView.swift` |  | chau7_next/src/settings/tabs.rs, chau7_next/src/settings_window/tabs.rs, chau7_next/src/workspace/tab_bar_view.rs | done |  |
| SET-054 | Show broadcast indicator in tabs (`tabs.display.showBroadcastIndicator`, Rust `[next] show_tab_broadcast_indicator`) | `TabsSettingsView.swift` |  | chau7_next/src/settings/tabs.rs, chau7_next/src/settings_window/tabs.rs, chau7_next/src/workspace/tab_bar_view.rs | done |  |
| SET-055 | Last command badge in tabs (`feature.lastCommandBadge`, Rust `[next] last_command_badge`) | `TabsSettingsView.swift` |  | chau7_next/src/settings/tabs.rs, chau7_next/src/settings_window/tabs.rs, chau7_next/src/workspace/tab_bar_view.rs | done |  |
| SET-056 | CTO indicator in tabs (`tabs.display.showCTOIndicator`, no UI and nothing reads it in Swift) and Allow CTO Toggle in Hover Card (`tabs.display.allowCTOToggle`; Rust `[next] show_tab_cto_indicator`, `allow_tab_cto_toggle`) | `TabsSettingsView.swift` |  | chau7_next/src/settings/tabs.rs, chau7_next/src/settings_window/tabs.rs, chau7_next/src/workspace/hover_card.rs | done |  |
| SET-057 | Read-only list of tab keyboard shortcuts in the Tabs pane | `TabsSettingsView.swift` |  | chau7_next/src/settings_window/tabs.rs (TAB_SHORTCUTS) | done |  |

### Hover Card, Repositories, Minimal Mode

| ID | Feature | Swift source | Tests | Rust | Status | macOS API |
|---|---|---|---|---|---|---|
| SET-058 | Hover card section toggles (13): directory, git branch, last command, AI session, repo stats, file conflicts, processes, dev server, notification state, token optimization, shell integration, broadcast, footer (`hoverCard.*`, Rust `[next] hover_card_show_*`) | `Settings/Views/HoverCardSettingsView.swift` |  | chau7_next/src/settings/hover_card.rs, chau7_next/src/settings_window/hover_card.rs | done |  |
| SET-059 | Recent repositories list with a per-repo metadata editor: description, labels, favorite files (`feature.recentRepoRoots`, `RepoMetadataStore`; Rust keeps the list in `recent-repos.json` in its state folder and saves metadata edits to its own overlay, never to the repo) | `Settings/Views/RepositoriesSettingsView.swift` |  | chau7_next/src/settings_window/repositories.rs, chau7_next_core/src/repo_metadata.rs | done |  |
| SET-060 | Minimal mode toggle (Cmd+Shift+M) with Hide Tab Bar, Hide Title Bar, Hide Status Bar, Hide Sidebar options and a status list (`feature.minimalMode`, `minimal.*`; Rust `[appearance] minimal_mode`, `[next] minimal_hide_*`). Rust has no status bar or sidebar yet, so those two options have nothing to hide | `Settings/Views/MinimalModeSettingsView.swift`, `Appearance/MinimalMode.swift` |  | chau7_next/src/settings/minimal_mode.rs, chau7_next/src/settings_window/minimal_mode.rs, chau7_next/src/workspace/tab_bar_view.rs (tab_bar_visible) | done |  |

### Shell

| ID | Feature | Swift source | Tests | Rust | Status | macOS API |
|---|---|---|---|---|---|---|
| SET-061 | Shell picker: System, Zsh, Bash, Fish (Apple Silicon), Fish (Intel), Custom with path field; shows the current shell (`terminal.shellType`, `terminal.customShellPath`) | `Settings/Views/ShellSettingsView.swift` | `FeatureSettingsTests.testDefaultShellType`, `testDefaultCustomShellPath` | chau7_next/src/settings/terminal.rs (shell_type), chau7_next/src/settings_window/shell.rs | done |  |
| SET-062 | Startup command run in each new session (`terminal.startupCommand`, `[general] startup_command`) | `ShellSettingsView.swift` | `FeatureSettingsTests.testDefaultStartupCommand` | chau7_next/src/settings/terminal.rs (startup_command), chau7_next_core/src/shell_integration.rs | done |  |
| SET-063 | ls colors: set CLICOLOR and LSCOLORS for new sessions (`terminal.lsColorsEnabled`) | `ShellSettingsView.swift` | `FeatureSettingsTests.testDefaultLsColorsEnabled` | chau7_next/src/settings/terminal.rs (ls_colors), chau7_next_core/src/shell_env.rs | done |  |
| SET-064 | Cursor style: Block, Underline, Bar (`terminal.cursorStyle`, `[appearance] cursor_style`) | `ShellSettingsView.swift` | `FeatureSettingsTests.testDefaultCursorStyle` | `chau7_next/src/settings_window/`, `chau7_next/src/settings/` | done | |
| SET-065 | Cursor blink (`terminal.cursorBlink`, `[appearance] cursor_blink`) | `ShellSettingsView.swift` | | `chau7_next/src/settings_window/` | done | |
| SET-066 | Bell enabled (`terminal.bellEnabled`, `[terminal] bell_enabled`): plays the bell sound | `ShellSettingsView.swift` |  | chau7_next/src/settings/terminal.rs, chau7_next/src/terminal/session.rs (ring_bell) | done |  |
| SET-067 | Bell sound: Default, Subtle, Visual Only (`terminal.bellSound`, `[terminal] bell_sound`) | `ShellSettingsView.swift` |  | chau7_next/src/settings/terminal.rs (BellSound), chau7_next/src/settings_window/shell.rs | done | NSSound |

### Scrollback & Performance

| ID | Feature | Swift source | Tests | Rust | Status | macOS API |
|---|---|---|---|---|---|---|
| SET-068 | Scrollback buffer size, 100 to 100,000 lines (`terminal.scrollbackLines`, `[terminal] scrollback_lines`) | `Settings/Views/ScrollbackPerfSettingsView.swift` | `FeatureSettingsTests.testDefaultScrollbackLines` | chau7_next/src/settings/terminal.rs, chau7_next/src/settings_window/shell.rs | done |  |
| SET-069 | Smart scroll: keep the scroll position when output arrives while scrolled up (`feature.smartScrollEnabled`) | `ScrollbackPerfSettingsView.swift` |  | chau7_next/src/settings/terminal.rs (smart_scroll), chau7_next/src/terminal/session.rs | done |  |
| SET-070 | Restored scrollback lines when tabs are recovered, 0 to 10,000, 0 disables (`terminal.restoredScrollbackLines`) | `ScrollbackPerfSettingsView.swift` | `FeatureSettingsTests.testDefaultRestoredScrollbackLines` | `chau7_next/src/settings/terminal.rs` (`restored_scrollback_lines`), `chau7_next/src/settings_window/panes.rs`, `chau7_next/src/restore.rs` (`capture_tab`), `chau7_next_core/src/session_restore.rs` (`capture_scrollback`) | done |  |
| SET-071 | Local echo: draw typed characters before the PTY echoes them (`feature.localEchoEnabled`) | `ScrollbackPerfSettingsView.swift` |  | `chau7_next/src/settings/input.rs` (`local_echo`), `chau7_next/src/settings_window/keyboard.rs`, `chau7_next/src/terminal/input.rs` | done |  |
| SET-072 | Suspend background rendering and suspend delay in seconds (AppModel keys) | `ScrollbackPerfSettingsView.swift`, `App/AppModel.swift` | | | n/a | |
| SET-073 | Metal renderer toggle (`feature.useMetalRenderer`) | `ScrollbackPerfSettingsView.swift` | | | n/a | Metal |

### Dangerous Commands

| ID | Feature | Swift source | Tests | Rust | Status | macOS API |
|---|---|---|---|---|---|---|
| SET-074 | Command guard: confirmation dialog before a risky command is sent on Enter (`DangerousCommandGuard.isEnabled`) | `Settings/Views/DangerousCommandSettingsView.swift`, `Commands/DangerousCommandGuard.swift` | `DangerousCommandGuardTests` | chau7_next/src/settings_window/mine/dangerous.rs | done |  |
| SET-075 | Highlight scope: Disabled, AI Outputs Only, All Outputs (`terminal.dangerousCommandHighlightScope`); Rust has an on/off toggle that covers all output (`[next] highlight_dangerous_commands`) | `DangerousCommandSettingsView.swift` | `FeatureSettingsTests.testDefaultDangerousCommandHighlightScope` | chau7_next/src/settings_window/mine/dangerous.rs | done |  |
| SET-076 | Risky pattern list editor: add, edit, remove (`terminal.dangerousCommandPatterns`, about 190 defaults); Rust uses the defaults with no way to edit them | `DangerousCommandSettingsView.swift` | `FeatureSettingsTests.testDefaultDangerousCommandPatternsNotEmpty`, `testDangerousCommandPatternsContainCommonThreats` | chau7_next/src/settings_window/mine/dangerous.rs | done |  |
| SET-077 | Always Allowed and Always Blocked command lists: view, remove, clear all, add a blocked command | `DangerousCommandSettingsView.swift` | `DangerousCommandGuardTests` | chau7_next/src/settings_window/mine/dangerous.rs | done |  |

### Graphics

| ID | Feature | Swift source | Tests | Rust | Status | macOS API |
|---|---|---|---|---|---|---|
| SET-078 | Sixel protocol toggle (`feature.sixelEnabled`, `[terminal] sixel_enabled`) | `Settings/Views/GraphicsSettingsView.swift`, `RustBackend/SixelKittyBridge.swift` |  | `chau7_next/src/settings_window/graphics.rs`, `chau7_next/src/settings/appearance.rs` | done |  |
| SET-079 | Kitty graphics toggle and image cache size, 64 to 1024 MB (`feature.kittyGraphicsEnabled`, `feature.kittyCacheLimitMB`, `[terminal] kitty_graphics`) | `GraphicsSettingsView.swift` |  | `chau7_next/src/settings_window/graphics.rs`, `chau7_next/src/terminal/images.rs` (`enforce_limit`) | done |  |
| SET-080 | (dev) Render Test Image button and protocol info with test commands | `GraphicsSettingsView.swift` |  | `chau7_next/src/settings_window/graphics.rs`, `chau7_next/src/terminal/images.rs` (`test_image_png`) | done |  |

### Keyboard & Mouse

| ID | Feature | Swift source | Tests | Rust | Status | macOS API |
|---|---|---|---|---|---|---|
| SET-081 | Keybinding preset: Default, Vim (Ctrl+H/L tabs), Emacs (Ctrl+N/P tabs) (`feature.keybindingPreset`) | `Settings/Views/InputSettingsView.swift`, `KeyboardShortcut.shortcuts(for:)` | `FeatureSettingsTests.testApplyKeybindingPresetVim`, `testApplyKeybindingPresetEmacs`, `KeybindingsManagerTests.testKeyboardShortcutPresets*` | `chau7_next/src/settings/input.rs` (`[next] keybinding_preset`), `chau7_next/src/settings_window/keyboard.rs` | done |  |
| SET-082 | Copy on select (`feature.copyOnSelect`, Rust `[next] copy_on_select`) | `InputSettingsView.swift` | | `chau7_next/src/terminal/view.rs`, `settings_window/` | done | |
| SET-083 | Cmd+click file paths opens them (`feature.cmdClickPaths`) | `InputSettingsView.swift` |  | chau7_next/src/settings_window/mine/links.rs | done |  |
| SET-084 | URL handler: System, Safari, Chrome, Firefox, Edge, Brave, Arc (`feature.urlHandler`); Rust always uses the system default | `InputSettingsView.swift` | `FeatureSettingsTests.testDefaultUrlHandler` | chau7_next/src/settings_window/mine/links.rs | done | NSWorkspace |
| SET-085 | Default editor for Cmd+click (empty means `$EDITOR`) and Open in Internal Editor (`feature.defaultEditor`, `feature.cmdClickOpensInternalEditor`) | `InputSettingsView.swift` |  | chau7_next/src/settings_window/mine/links.rs,chau7_next/src/terminal/links.rs | done |  |
| SET-086 | Option+click moves the cursor on the command line (`feature.optionClickCursor`); Option-drag still selects a block in Chau7 Next | `InputSettingsView.swift` |  | `chau7_next/src/settings/input.rs` (`[next] option_click_cursor`), `chau7_next/src/terminal/mouse.rs` | done |  |
| SET-087 | Mouse reporting toggle, off by default, Shift forces selection (`feature.mouseReporting`) | `InputSettingsView.swift` |  | `chau7_next/src/settings/input.rs` (`[terminal] mouse_reporting`), `chau7_next/src/terminal/mouse.rs` | done |  |
| SET-088 | Click to position cursor on the input line (`feature.clickToPosition`) | `InputSettingsView.swift` |  | `chau7_next/src/settings/input.rs` (`[next] click_to_position`), `chau7_next/src/terminal/mouse.rs` | done |  |
| SET-089 | Broadcast input feature toggle (`feature.broadcastEnabled`); as in Swift the value is only stored (Broadcast Input to All Tabs works from its menu item either way) | `InputSettingsView.swift` |  | chau7_next/src/settings/input.rs (broadcast_enabled), chau7_next/src/settings_window/keyboard.rs | done |  |
| SET-090 | Custom keyboard shortcuts: list in the Input pane, edit sheet (key plus Cmd/Shift/Ctrl/Opt toggles), conflict highlight (`keyboard.customShortcuts`); Chau7 Next edits them in the Keyboard Shortcuts window (key recorder) and stores `[keybindings]` in config.toml | `InputSettingsView.swift`, `Settings/KeybindingsManager.swift`, `FeatureSettings.swift` | `KeybindingsManagerTests`, `FeatureSettingsTests.testShortcutConflictDetection` | `chau7_next/src/settings_window/keyboard.rs`, `chau7_next/src/settings_window/shortcuts.rs`, `chau7_next/src/settings/input.rs` (`[keybindings]`) | done |  |
| SET-091 | Keyboard shortcuts editor window: search, grouped list, key recorder field, conflict alert | `Settings/KeyboardShortcutsEditor.swift` |  | `chau7_next/src/settings_window/shortcuts.rs` | done |  |
| SET-092 | Shortcut helper hint in the top-right corner of the terminal (`keyboard.shortcutHelperHint`) | `InputSettingsView.swift` | `FeatureSettingsTests.testShortcutHelperHintDefault` | chau7_next/src/settings/input.rs ([next] shortcut_helper_hint), chau7_next/src/settings_window/keyboard.rs, chau7_next/src/workspace/keys.rs (render_shortcut_hint) | done |  |

### Snippets & Tools

| ID | Feature | Swift source | Tests | Rust | Status | macOS API |
|---|---|---|---|---|---|---|
| SET-093 | Enable snippets toggle, user and repo counts, Manage Snippets window (`feature.snippetsEnabled`); Rust snippets are always on, no editor | `Settings/Views/ProductivitySettingsView.swift` |  | chau7_next/src/settings_window/mine/productivity.rs | done |  |
| SET-094 | Repository snippets toggle and snippets path (`feature.repoSnippetsEnabled`, `feature.repoSnippetPath`, default `.chau7/snippets`); Rust reads the repo folder and the old `<git root>/.chau7/snippets.json`, and writes edits to its own per-repo overlay | `ProductivitySettingsView.swift` | `FeatureSettingsTests.testDefaultRepoSnippetPath` | chau7_next/src/settings_window/mine/productivity.rs | done |  |
| SET-095 | Allow protected folders (Documents, Desktop, Downloads) with Grant Access and Open System Settings buttons (`feature.allowProtectedFolderAccess`) | `ProductivitySettingsView.swift` |  | chau7_next/src/settings_window/mine/productivity.rs | done | TCC (Files and Folders) |
| SET-096 | Snippet insert mode: Expand (type) or Paste (`feature.snippetInsertMode`) | `ProductivitySettingsView.swift` | `FeatureSettingsTests.testDefaultSnippetInsertMode` | chau7_next/src/settings_window/mine/productivity.rs | done |  |
| SET-097 | Snippet placeholder navigation (`feature.snippetPlaceholders`); Rust fills placeholder defaults with no navigation | `ProductivitySettingsView.swift` |  | chau7_next/src/settings_window/mine/productivity.rs | done |  |
| SET-098 | Clipboard history enable and maximum items, 1 to 1000 (`feature.clipboardHistory`, `feature.clipboardHistoryMax`); Rust has `[next] clipboard_history_max` (0 to 500) in config only | `ProductivitySettingsView.swift` | `FeatureSettingsTests.testDefaultClipboardHistoryMaxItems` | chau7_next/src/settings_window/mine/productivity.rs | done |  |
| SET-099 | Bookmarks enable and maximum per tab, 1 to 200 (`feature.bookmarksEnabled`, `feature.maxBookmarks`) | `ProductivitySettingsView.swift` | `FeatureSettingsTests.testDefaultMaxBookmarksPerTab` | chau7_next/src/settings_window/mine/productivity.rs, chau7_next/src/settings/productivity.rs, chau7_next/src/workspace/bookmarks.rs (add_bookmark) | done |  |
| SET-100 | Semantic scrollback search (`feature.semanticSearch`) | `ProductivitySettingsView.swift` |  | chau7_next/src/settings_window/mine/productivity.rs, chau7_next/src/workspace/find.rs (Cmd toggle), chau7_next_core/src/semantic_search.rs | done |  |
| SET-101 | Find defaults: case sensitive, regex (`search.defaultCaseSensitive`, `search.defaultRegex`) | `ProductivitySettingsView.swift` |  | chau7_next/src/settings_window/mine/productivity.rs, chau7_next/src/workspace/find.rs (toggle_search) | done |  |

### Text Editor

| ID | Feature | Swift source | Tests | Rust | Status | macOS API |
|---|---|---|---|---|---|---|
| SET-102 | Built-in editor settings: font size, tab size, use spaces, auto-indent, word wrap, line numbers, highlight current line, minimap, bracket matching, theme (Default, Dark, Light, Solarized, Monokai) (`editor.config`, JSON) | `Settings/Views/EditorSettingsView.swift`, `Settings/EditorConfig.swift` |  | chau7_next/src/settings/editor.rs,chau7_next/src/settings_window/editor.rs | done |  |

### AI Detection, Token Optimization

| ID | Feature | Swift source | Tests | Rust | Status | macOS API |
|---|---|---|---|---|---|---|
| SET-103 | Custom AI detection rules: pattern, display name, tab color; add and remove (`ai.customDetectionRules`); the pane also lists the built-in detected CLIs | `Settings/Views/AIIntegrationSettingsView.swift` |  | chau7_next/src/settings/ai.rs, chau7_next/src/settings_window/ai.rs | done |  |
| SET-104 | LLM provider: OpenAI, Anthropic, Ollama, Custom; API key, endpoint, model, max tokens, Test Connection | `Settings/Views/LLMSettingsView.swift` |  | chau7_next/src/settings/ai.rs, chau7_next/src/settings_window/ai.rs, chau7_next/src/ai/llm.rs | done | Keychain |
| SET-105 | Enable "Explain This Error" (`feature.errorExplainEnabled`) | `LLMSettingsView.swift` |  | chau7_next/src/settings/ai.rs, chau7_next/src/settings_window/ai.rs | done |  |
| SET-106 | Token optimization mode: Off, All Tabs, AI Only, Manual (`cto.mode`) | `Settings/Views/TokenOptimizationSettingsView.swift` |  | chau7_next/src/settings_window/token_optimization.rs | done |  |
| SET-107 | CTO input prefix enable and text (`feature.ctoEnabled`, `feature.ctoPrefix`) | `TokenOptimizationSettingsView.swift` | `FeatureSettingsTests.testCTODefaultTabOverridesEmpty` | chau7_next/src/settings_window/token_optimization.rs | done |  |
| SET-108 | Optimizer install status, wrapper script health check, Reinstall from Bundle | `TokenOptimizationSettingsView.swift` |  | chau7_next/src/settings_window/token_optimization.rs | done |  |
| SET-109 | Per-tab CTO override control and optimized commands list (`feature.ctoTabOverrides`) | `TokenOptimizationSettingsView.swift` |  | chau7_next/src/settings_window/token_optimization.rs | done |  |
| SET-110 | (dev) CTO runtime telemetry, recent optimizer commands, token savings stats | `TokenOptimizationSettingsView.swift` |  | chau7_next/src/settings_window/token_optimization.rs | done |  |

### MCP, Remote Control, API Proxy

| ID | Feature | Swift source | Tests | Rust | Status | macOS API |
|---|---|---|---|---|---|---|
| SET-111 | MCP: enable, require approval, max tabs 1 to 50, show tab indicator (`mcp.enabled`, `mcp.requiresApproval`, `mcp.maxTabs`, `mcp.showTabIndicator`) | `Settings/Views/MCPSettingsView.swift` |  | `chau7_next/src/settings/mcp.rs`, `chau7_next/src/settings_window/mcp.rs` | done |  |
| SET-112 | MCP command permissions: permission mode, allowed and blocked command lists (`mcp.permissionMode`, `mcp.allowedCommands`, `mcp.blockedCommands`) | `MCPSettingsView.swift` |  | `chau7_next/src/settings/mcp.rs`, `chau7_next/src/settings_window/mcp.rs` | done |  |
| SET-113 | MCP profiles: name, enable, priority, trigger (directory, repo, SSH host, process, env var), permission mode, own allowed and blocked lists (`mcp.profiles`) | `MCPSettingsView.swift` |  | `chau7_next/src/settings/mcp.rs`, `chau7_next/src/settings_window/mcp.rs` | done |  |
| SET-114 | Remote control: enable, relay URL, remote agent and IPC status (`remote.enabled`, `remote.relayURL`) | `Settings/Views/RemoteSettingsView.swift` |  | chau7_next/src/settings_window/remote.rs, chau7_next/src/settings/remote.rs | done |  |
| SET-115 | Remote pairing: pairing code, copy pairing JSON or code, regenerate; paired devices list with revoke | `RemoteSettingsView.swift` |  | chau7_next/src/settings_window/remote.rs | done |  |
| SET-116 | SSH config sync pane: list `~/.ssh/config` entries, import one or all, export Chau7 connections to SSH config, file watch status; Rust only opens hosts from `~/.ssh/config` in a picker | `Settings/Views/SSHProfilesSettingsView.swift` |  | chau7_next/src/settings_window/mine/profiles.rs | done |  |
| SET-117 | API analytics proxy: enable, log prompt previews, route OpenAI-compatible clients, port (`analytics.api.*`, Swift default port 18080; Chau7 Next keys `api_analytics_*` in `[next]`, default port 18090) | `Settings/Views/ProxySettingsView.swift` | `FeatureSettingsTests.testDefaultApiAnalyticsPort` | chau7_next/src/settings/proxy.rs, chau7_next/src/settings_window/proxy.rs | done |  |
| SET-118 | Proxy data: Open Database Folder, Clear All Data | `ProxySettingsView.swift` |  | chau7_next/src/settings_window/proxy.rs, chau7_next/src/proxy/mod.rs | done |  |

### Notifications

| ID | Feature | Swift source | Tests | Rust | Status | macOS API |
|---|---|---|---|---|---|---|
| SET-119 | Notification status and permissions: status, Request Permission, System Settings, Send Test | `Settings/Views/NotificationsSettingsView.swift` |  | chau7_next/src/settings_window/notifications.rs (status), chau7_next/src/notifications/banner.rs | done | UNUserNotificationCenter |
| SET-120 | AI tool notification cards: per tool on/off with Banner, Highlight Tab, Sound, Dock Bounce toggles | `NotificationsSettingsView.swift` |  | chau7_next/src/settings_window/notifications.rs (AI Tools) | done | NSApplication.requestUserAttention |
| SET-121 | Notification triggers: enable each trigger by category and source, AI coding group triggers (`notifications.triggerState`; the legacy `notifications.filters` mirror is not kept) | `NotificationsSettingsView.swift` | `FeatureSettingsTests.testNotificationFilterDefaultsOnlyEnableFinishedFailedAndPermission`, `testLegacyNotificationFilters*`, `testNotificationTriggerStateMaps*` | chau7_next/src/settings_window/notification_triggers.rs, chau7_next/src/settings/notifications.rs | done |  |
| SET-122 | Trigger actions editor: add, configure, enable or remove actions (24 types, from show notification to webhooks, scripts, Docker, timers) per trigger and per group (`notifications.triggerActionBindings`, `notifications.groupActionBindings`) | `Settings/Views/TriggerActionsSettingsView.swift`, `FeatureSettings.swift` | `FeatureSettingsTests.testActionsForUnknownTriggerReturnsDefault` | chau7_next/src/settings_window/notification_triggers.rs | done |  |
| SET-123 | Per-source trigger overrides | `NotificationsSettingsView.swift` |  | chau7_next/src/settings_window/notification_triggers.rs (overrides) | done |  |
| SET-124 | Detection thresholds: long-running seconds, directory change, git branch change; app inactivity minutes, memory MB, tab open, tab close (`shell.eventConfig`, `app.eventConfig`); the shell thresholds are read by the shell event detector (MON-008, MON-010) | `NotificationsSettingsView.swift` |  | chau7_next/src/settings_window/notifications.rs (Thresholds), chau7_next/src/settings/notifications.rs | done |  |
| SET-125 | Event monitoring: Monitor AI Events, event log path, Restart Monitor, Reveal in Finder | `NotificationsSettingsView.swift` |  | chau7_next/src/settings_window/notifications.rs (Monitoring), chau7_next/src/settings/notifications.rs, chau7_next/src/ai/hub.rs (restart_event_monitor, follows the path), chau7_next/src/seams.rs | done |  |
| SET-126 | Rate limiting: max per minute, burst allowance, cooldown seconds (`notifications.rateLimitConfig`) | `NotificationsSettingsView.swift` |  | chau7_next/src/settings_window/notifications.rs (Behavior) | done |  |
| SET-127 | Trigger conditions: respect Focus/DND, only when app is in background, only when the tab is not selected (`notifications.triggerConditions`, `notifications.groupConditions`) | `NotificationsSettingsView.swift` |  | chau7_next/src/settings_window/notifications.rs (Behavior), chau7_next_core/src/notifications/pipeline.rs | done |  |
| SET-128 | Notification history: last 100 events, clear | `NotificationsSettingsView.swift` |  | chau7_next/src/settings_window/notifications.rs (History) | done |  |

### Logs & History

| ID | Feature | Swift source | Tests | Rust | Status | macOS API |
|---|---|---|---|---|---|---|
| SET-129 | History log monitoring: toggle, idle and stale seconds, Codex and Claude history paths, Restart Monitors, Clear History | `Settings/Views/LogsSettingsView.swift` |  | chau7_next/src/settings_window/logs.rs, chau7_next/src/settings/history.rs, chau7_next/src/history/monitor.rs | done |  |
| SET-130 | Terminal log monitoring: toggle, normalize output, render ANSI styling, Codex and Claude terminal log paths, Reload Last Lines, Clear Logs | `LogsSettingsView.swift` |  | chau7_next/src/settings_window/logs.rs, chau7_next/src/settings/history.rs, chau7_next/src/history/monitor.rs | done |  |
| SET-131 | Active sessions list | `LogsSettingsView.swift` |  | chau7_next/src/settings_window/logs.rs, chau7_next/src/history/monitor.rs (session_statuses) | done |  |
| SET-132 | Persistent command history: enable, maximum records, statistics (count, database size), export and import, clear older than N days, clear all (`feature.persistentHistory`, `history.maxRecords`) | `Settings/Views/HistorySettingsView.swift` |  | chau7_next/src/settings_window/logs.rs, chau7_next/src/settings/history.rs, chau7_next_core/src/history_store.rs | done |  |
| SET-133 | Bug report contact name, handle and issue endpoint remembered between reports (`bugReport.*`) | `FeatureSettings.swift`, `Logging/BugReportDraft.swift` |  | chau7_next/src/settings/general.rs, chau7_next/src/debug/report_window.rs | done |  |
| SET-134 | Reusable settings controls (section headers, toggles, pickers, steppers, sliders, directory field, shortcut rows) | `Settings/SettingsComponents.swift` | | `chau7_next/src/settings_window/` (`section`, `row`, `toggle`, `stepper`, `chip`) | n/a | |
| SET-135 | Shortcut registry documentation (constants only) | `Settings/KeyboardShortcuts.swift` | | | n/a | |

| SET-136 | Start Here summarizes launch/profile, actual MCP/remote/notification service state, native notification/full disk/protected access evidence and paths; Next provides a working Permission Center deep link | `Settings/Views/StartHereSettingsView.swift`; `Settings/SettingsRootView.swift` | l10n::tests::next_status_defaults_have_current_swift_source_evidence; settings_search::tests; settings_window::anchors::tests | chau7_next/src/settings_window/start_here.rs; chau7_next/src/settings_window/mod.rs; chau7_next_core/src/settings_search.rs | done | 6cbc7607 integrated in coordinator86bc8550; cached snapshots only; native visual acceptance pending |
| SET-137 | Search result focus navigates to setting anchor and grouped page summaries; nonempty search selects the first matching section, empty search clears the anchor while retaining selection | `Settings/SettingsNavigationModel.swift`; `Settings/SettingsRootView.swift`; `Settings/Views/SettingsPageSummaryView.swift` | settings_search::tests::navigation_matches_current_swift_selection_and_anchor_rules; settings_window::anchors::tests::title_aliases_are_section_scoped_and_scopes_restore | chau7_next_core/src/settings_search.rs; chau7_next/src/settings_window/{mod,anchors,widgets}.rs | partial | Current 28 pages/6 groups/99 localized entries, first-match navigation, real result actions and GPUI scroll anchors implemented. Reset-all now renders on Sync & Backup; scrollback/smart-scroll and refresh cap controls render on their actual searchable performance page. Full 99-control/native acceptance audit pending |
| SET-138 | Permission Center refreshed notification/full-disk/protected-folder state, explicit grants/regrants/cooldown and System Settings links; diagnose child process access | `Settings/PermissionCenterModel.swift`; `Settings/FullDiskAccessGuard.swift`; `Chau7Core/FullDiskAccessProbe.swift` | permission_center::tests (8 policy/denial/PTY-bound tests); app source localization key test | chau7_next_core/src/permission_center.rs; chau7_next/src/{permission_center,protected_paths}.rs; chau7_next/src/settings_window/permission_center.rs; chau7_next/src/terminal/session.rs; chau7_next/src/workspace/mod.rs | done | 4494e8a1 +6770943a integrated in coordinator86bc8550: open-only conservative FDA evidence, cached-root protected snapshots, native notification state, actual grant/settings/refresh controls, proactive activation/startup and reactive failed-command guard with five-minute throttle. Native grant/denial acceptance pending |
| SET-139 | Domain stores publish consistent settings changes and do not poll/reset unaffected options; import/export/reset cover new keys and domains | `Settings/TabDisplaySettingsStore.swift`; `Settings/ShellSettingsStore.swift`; `Settings/MCPRemoteSettingsStore.swift`; `Settings/NotificationSettingsStore.swift` | settings::tests::current_appearance_pages_reset_only_their_own_values; settings::export::tests::current_windows_values_survive_both_owned_formats | chau7_next/src/settings/; chau7_next/src/settings_window/windows.rs | partial | Windows/FontColors/Display resets are now independent and current Windows keys survive config/JSON formats. Current Shell/Performance shared terminal reset now covers shell/cursor/scrollback/bell/usage/start directory/rate caps, preserves split/window/font/rendering selections, and restores current low-power defaults. Current typed Swift JSON scalar/display/hover-card/notification/shortcut/AI-rule mappings now export actual preferences and import without the Next extension. Versioned domain-owned Next config preserves editor/proxy/history/usage/optimizer preferences and legacy shell/clipboard-off values; future versions reject before mutation. Actual import/export file I/O is off the UI thread and displays format errors.16 focused tests and integrated2726 tests/2 ignored plus strict all-target Clippy/fmt pass. Input/Productivity reset ownership now matches current link ownership; Dangerous Commands resets the shared terminal domain and owned guard lists. Protected-folder default is false as in current Swift. Portable Next exports exclude remembered report contacts and imports preserve the local values, including older documents; all96 focused settings tests pass. Productivity and Reset All now clear owned recent roots and known identities through a generation-fenced background worker. The isolated actual disk fixture covers stale bootstrap/recent/Git probes and fresh observations. Shared JSON preserves the provider-health border. Integrated2766 tests/2 ignored and strict all-target Clippy/fmt pass. Newly discovered terminal/protection fields and all99 targets remain under audit |
| SET-140 | Usage/provider status/prompt injection/dashboard settings and current permission navigation are included in search, reset and config persistence | `Settings/SettingsSearch.swift`; `Settings/FeatureSettings.swift` |  | chau7_next_core/src/settings_search.rs; chau7_next/src/settings_window/{mod,start_here,windows,injection,permission_center}.rs; chau7_next/src/settings/ | partial | Current localized 99-entry Swift search catalog and all28 sidebar routes implemented; prompt rules/current access navigation persisted and linked. Complete current-domain reset/import and all control targets remain covered by SET137/139, not yet closed |

## Notes

- Storage differs by design. Swift keeps every setting in UserDefaults and
  only reads `~/.chau7/config.toml` as an override layer (it never writes it
  from the settings window). Chau7 Next keeps everything in
  `~/.chau7-next/config.toml` (`DataRoot`), and the settings window writes it.
  Keys that only Chau7 Next reads go in a `[next]` section, which the Swift
  parser ignores: `option_as_meta`, `new_tab_position` ("end" or "after"),
  `idle_tab_minutes`, `group_idle_tabs`, `auto_repo_grouping`,
  `copy_on_select`, `warn_on_close_running`, `highlight_dangerous_commands`,
  `clipboard_history_max`, `padding`. Tabs, hover card and minimal mode add `new_tabs_use_current_directory`, `last_tab_close_behavior`, `always_show_tab_bar`, `always_show_toolbar_in_fullscreen`, `repo_grouping_mode`, `custom_title_only`, `show_tab_icons`, `auto_tab_theme`, `show_tab_path`, `show_tab_git_indicator`, `show_tab_cto_indicator`, `allow_tab_cto_toggle`, `show_tab_broadcast_indicator`, `last_command_badge`, `hover_card_show_*` and `minimal_hide_*`; `[general] confirm_close` is "Always Warn Before Closing Tab" and `[appearance] minimal_mode` turns minimal mode on. Option as Meta, padding and line height
  have no Swift setting.
- Keys the Swift `ConfigFileWatcher.applyConfigToSettings` applies:
  `[general] startup_command, default_directory`, `[appearance] font_family,
  font_size, color_scheme, cursor_style, cursor_blink`, `[terminal]
  scrollback_lines, bell_enabled, bell_sound`. It ignores `shell`,
  `close_on_exit`, `confirm_close`, `opacity`, `minimal_mode`, `word_wrap`,
  `mouse_reporting`, `sixel_enabled`, `kitty_graphics`, `[keybindings]` and
  `[profile.*]`. Chau7 Next applies `shell`, `default_directory`,
  `close_on_exit`, the appearance keys, `opacity`, `scrollback_lines`,
  `bell_enabled`, `confirm_close` (always warn before closing a tab),
  `minimal_mode` and `[keybindings]`; it parses but ignores
  `startup_command`, `bell_sound` and
  `[profile.*]`.
- Swift `config.toml` path is `~/.chau7/config.toml`; per-repo is
  `<directory>/.chau7/config.toml` of the selected tab. The watcher only
  watches the global file and only if it exists at launch.
- Keybinding action names: the Swift Input pane stores `customShortcuts` with
  names such as `find`, `findNext`, `findPrevious`, `snippets`,
  `debugConsole`, `openTextEditor`, `previousInputLine`, `nextInputLine`,
  `refreshTabBar` (mapped by `KeyAction.fromShortcutAction`). Rust
  `action_for_swift_name` accepts the `KeyAction` raw values (`toggleSearch`,
  `nextMatch`, `previousMatch`, `showSnippets`, `selectTab1` to `selectTab9`,
  ...), not those shortcut names. `exportKeybindings` and `importKeybindings`
  exist in `FeatureSettings` but no UI calls them.
- Default differences to keep in mind: Swift copy on select is `true` on a
  fresh install (init) but `false` in `defaultExportableSettings` and reset;
  Rust defaults to `false`. Swift mouse reporting defaults to off; Rust always
  reports. Swift font size range is 8 to 72, Rust 6 to 72. Swift idle
  threshold UI range is 1 to 60 minutes, Rust 1 to 240.
- `ExportableSettings` (import, export, profiles, iCloud) covers most keys but
  not: font weight, ligatures, cursor blink rate and color, ambiguous width,
  bell visual and rate limit, repo grouping, idle tabs, menu bar only,
  floating window, mouse reporting, click to position, Metal, local echo,
  smart scroll, API analytics, CTO mode, LLM settings, bug report contact,
  config file toggle.
- SET-017 and the other hidden keys: no settings UI writes them and (except
  menu bar only and floating window, SET-023) no code reads them, so they have
  no visible effect in Swift today.
- SET-072 and SET-073 are `n/a`: GPUI always renders on the GPU and only
  paints the visible tab, so the Metal toggle and background render
  suspension have no equivalent to port.
- SET-134 and SET-135 are `n/a`: UI building blocks and documentation, not
  user features.
- `WindowsSettingsView` (overlay window buttons, fullscreen toolbar, split
  panes) is not shown by any sidebar section; its split panes toggle is
  duplicated in Display.

### Current source checkpoint (2026-10-11)

- Settings source `6cbc7607` is integrated in coordinator `86bc8550`: the current sidebar has 28 pages in six groups and 99 localized search entries. Release validation passed 290 app tests plus one existing ignored test, 2,089 core tests plus one existing ignored test, and strict all-target Clippy. The combined coordinator merge also passes strict all-target Clippy.
- Done denotes implemented current-source behavior with test evidence. Native settings/access interaction acceptance remains separate. SET-137, SET-139 and SET-140 retain their specific remaining control/reset/import facets; these rows are not blanket declarations of full settings parity.

| SET-141 | Active terminal refresh cap supports Display Native/60 Hz/30 Hz; visible unfocused views use a persisted 1-120 fps cap with default 42 | `Settings/Views/ScrollbackPerfSettingsView.swift`; `Settings/FeatureSettings.swift` | settings::appearance::tests::refresh_caps_default_parse_and_bounds_match_current_swift; settings::export::tests::current_terminal_and_refresh_values_survive_owned_formats | chau7_next/src/settings/appearance.rs; chau7_next/src/settings_window/rendering.rs; chau7_next/src/settings/export.rs; chau7_next/src/terminal/session.rs; chau7_next/src/terminal/view.rs | done | Actual settings controls, config/JSON persistence and shared terminal reset plus focused/visible inactive pacing wired through TerminalView and TerminalSession |
| SET-142 | Provider service-health border defaults on; fresh official degradation is a thin orange border and outage a thicker red border, only for the focused AI pane in the key window | `Settings/TabDisplaySettingsStore.swift`; `Settings/Views/TabsSettingsView.swift`; `Overlay/Chau7OverlayView.swift`; `ProviderStatus/ProviderStatusMonitor.swift` | settings::tabs::tests::{round_trips,swift_defaults}; workspace::provider_health::tests::{focused_provider_and_setting_control_actual_alert,tool_names_match_the_current_official_vendor_sources} | chau7_next/src/settings/tabs.rs; chau7_next/src/settings_window/tabs.rs; chau7_next/src/workspace/provider_health.rs; chau7_next/src/usage.rs | done | 98cd9cb4: persisted model/toggle, actual input-transparent terminal painting and accessible observed status; cached official evidence only, unrelated/unknown/future/expired suppressed; independent bounded poll publication when quota monitoring is off. 2729 workspace tests and strict release all-target Clippy/fmt passed. Native pointer/accessibility acceptance pending; current-format export bridge tracked separately by SET-139 |


| SET-145 | iCloud uses Swift-compatible exportedAt dates, refuses documents not strictly newer than the device watermark, keeps legacy untimestamped restores and records successful synchronization only | `Settings/FeatureSettings.swift:2613`; `Settings/FeatureSettings.swift:2664` | settings::cloud_freshness::tests; settings::sync::tests::only_successful_actual_upload_advances_the_device_watermark | chau7_next/src/settings/cloud_freshness.rs; chau7_next/src/settings/sync.rs; chau7_next/src/settings/export.rs; chau7_next/src/platform/{defaults,icloud}.rs | done | 102 focused settings tests pass using local fake-store fixtures, with no live iCloud access. Export fingerprints exclude only the date, preventing unchanged uploads. Local bundle preferences persist the device watermark; native cloud synchronization failures propagate. Signed iCloud entitlement and multi-device acceptance remain unverified. |

| SET-143 | Protect Chau7 defaults enabled and Blocking; selectable verbose logging/warning/blocking, configurable protected-process targets, reset and complete submitted-input approval fenced to the actual terminal context | `Settings/TerminalBehaviorStore.swift`; `Settings/FeatureSettings.swift:1530`; `Settings/Views/DangerousCommandSettingsView.swift`; `Commands/DangerousCommandGuard.swift`; `Chau7Core/SelfProtectiveCommandDetection.swift`; `Chau7Core/DeferredInputApproval.swift` | settings::dangerous_commands::tests::current_managed_process_defaults_and_owned_round_trip; command_risk::self_protect::tests; command_risk::admission::tests; terminal::view::guard::tests::{actual_admission_holds_full_plan_and_fences_approval,recalled_grid_command_is_guarded_but_running_program_owns_enter} | chau7_next/src/settings/dangerous_commands.rs; chau7_next/src/settings_window/mine/dangerous.rs; chau7_next_core/src/command_risk/{self_protect,admission}.rs; chau7_next/src/terminal/{command_guard,session,view/guard}.rs; chau7_next/src/{pane,remote/env,mcp/tools/tabs}.rs | done | 257d2aa8 policy/model/UI and 81db003a actual delivery. Shared boundary holds the whole plan before any write, reports held input honestly and rejects stale approvals/continuations; running-program Enter ownership and visible shell-history recall preserved. Cached shared process names avoid UI process scans. Owned config extension persists settings without inventing nonexistent Swift JSON fields. 2779 release workspace tests passed, two existing ignored; strict all-target Clippy/fmt passed. Native interactive approval/modal acceptance remains pending. |
| SET-144 | Shell history maximum lines defaults 1000 and clamps 0-1000000; setting controls the cumulative closed-tab zsh/bash history budget independently of SQLite command history | `Settings/TerminalBehaviorStore.swift`; `Settings/Views/ShellSettingsView.swift`; `Terminal/Session/TerminalSessionModel.swift:1866` | current-source audit | pending | missing | The existing SQLite history/TSV controls do not supply this setting or the shell-history pruning producer. Implementation reserved with HIS-017; existing active/restorable tab histories must remain protected. |
