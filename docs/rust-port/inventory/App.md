# App

Swift: `apps/chau7-macos/Sources/Chau7/App/` (5 files, 3994 lines)
Swift tests: `App/AppDelegateTests`, `App/AppModelEventRoutingTests`
Wave: 1 (see README.md)
Depends on: none (this module wires the others; their own features are listed in their own files)

The app entry point: launch sequence, window creation and lifecycle, the whole
menu bar (App, File, Edit, View, Window, Help), app level shortcuts, session
save and restore, the `chau7://` URL scheme, and `AppModel`, which starts the
AI monitors (event log, history idle monitors, PTY log tailers, Claude Code
hooks) and owns the notification permission state.

## Features

| ID | Feature | Swift source | Tests | Rust | Status | macOS API |
|---|---|---|---|---|---|---|
| APP-001 | Launch opens the restored windows, or one new window when nothing was saved | `App/AppDelegate.swift` (`attemptInitialSetupIfReady`, `restoreAdditionalWindows`) | | `chau7_next/src/main.rs` | done | |
| APP-002 | Closing the last window does not quit the app | `App/AppDelegate.swift` (`applicationShouldTerminateAfterLastWindowClosed`) | `AppDelegateTests` | `chau7_next/src/main.rs` (`on_window_closed`, quits only off macOS) | done | |
| APP-003 | Clicking the Dock icon with no visible window brings the terminal back. Swift re-shows the hidden window with its live tabs; Rust opens a fresh window | `App/AppDelegate.swift` (`applicationShouldHandleReopen`, `showOverlay`) | `AppDelegateTests` | `chau7_next/src/main.rs` (`on_reopen`), `chau7_next/src/app_actions.rs` (`show_overlay`: restores the hidden window) | done | NSApplicationDelegate |
| APP-004 | Close Window (and closing the last tab) only hides the window: its shells keep running and the window comes back on Dock click or the next shortcut | `App/AppDelegate.swift` (`closeWindow`, `windowShouldClose`, `onCloseLastTab`) | `AppDelegateTests` | `chau7_next/src/workspace/window.rs` (`close_window`, `hide_on_close`: tabs parked, shells kept), `chau7_next/src/workspace/app_data.rs` (`ParkedWindow`) | done | NSWindow |
| APP-005 | Shortcuts such as Cmd+T work with no window open: a window is created on demand | `App/AppDelegate.swift` (`ensureActiveOverlayModel`) |  | `chau7_next/src/app_actions.rs` (`register_window_fallbacks`: window created on demand) | done |  |
| APP-006 | Quit asks for confirmation when processes run in any tab, listing their names ("3 running processes will be terminated: ...") | `App/AppDelegate.swift` (`applicationShouldTerminate`) |  | `chau7_next/src/app_actions.rs` (`request_quit`), `chau7_next_core/src/app_shell.rs` (`quit_confirmation`) | done | NSAlert |
| APP-007 | All windows' tabs are saved on quit and every 30 seconds | `App/AppDelegate.swift` (`saveAllWindowStates`, `startMultiWindowAutoSaveTimer`) | | `chau7_next/src/main.rs` (`save_session`, every 15 s), `chau7_next/src/session_store.rs` | done | |
| APP-008 | Restore brings back every window and, per tab, directory, custom title, color and repo group | `App/AppDelegate.swift`, `Overlay/OverlayTabsModel.swift` (`SavedTabState`) | `OverlayTabsModelTests` | `chau7_next/src/session_store.rs`, `chau7_next/src/workspace/` (`snapshot`) | done | |
| APP-009 | Restore also brings back scrollback, split layout (including editor panes), focused pane, selected tab marker, token optimizer override and AI session resume command (done except the token optimizer override, TOK) | `Overlay/OverlayTabsModel.swift` (`SavedTabState`) | `OverlayTabsModelTests` | chau7_next/src/workspace/mod.rs | done |  |
| APP-010 | Tab state is also written to disk backups (latest plus archived copies) and restored from them when the saved state is missing | `Overlay/OverlayTabsModel+SessionFinder.swift` (`persistWindowStateBackups`), `App/AppDelegate.swift` |  | chau7_next/src/session_store.rs (write_backups, load), chau7_next/src/main.rs (save_session) | done |  |
| APP-011 | Windows that are hidden at quit time are not saved; with no visible window the saved state is cleared | `App/AppDelegate.swift` (`saveAllWindowStates`) |  | `chau7_next/src/main.rs` (`save_session`: hidden windows not saved, cleared at quit when none visible) | done |  |
| APP-012 | Move a tab or a repo group to another window or a new window (menu and drag); emptied windows are hidden | `App/AppDelegate.swift` (`moveTab`, `moveGroup`, `handleTabDrop`, `handleGroupDrop`) | `OverlayWindowDropResolverTests` | `chau7_next/src/workspace/` (`move_tabs_to`), `chau7_next/src/main.rs` (`open_window_with_tabs`) | done | |
| APP-013 | App Nap is disabled while running (latency critical activity) so the first keystroke after idle is not delayed | `App/AppDelegate.swift` (`activityToken`) |  | `chau7_next/src/platform/power.rs`, `chau7_next/src/main.rs` | done | ProcessInfo.beginActivity |
| APP-014 | `CLAUDECODE` is removed from the environment so Claude Code starts inside tabs when Chau7 was launched from a Claude Code session | `App/AppDelegate.swift` |  | `chau7_next_core/src/shell_env.rs` (`inherited_cleanup`) | done |  |
| APP-015 | Broken pipe writes never kill the app (SIGPIPE ignored) | `App/AppDelegate.swift` | | Rust runtime ignores SIGPIPE by default | done | |
| APP-016 | Background services start at launch and stop at quit: API proxy and its IPC server, token optimizer wrappers, MCP server, remote control agent | `App/AppDelegate.swift` (`applicationDidFinishLaunching`, `applicationWillTerminate`) |  | chau7_next/src/main.rs (mcp::start, mcp::stop, scripting::stop, cto::init, cto::teardown, proxy::init), chau7_next/src/proxy/mod.rs (init, on_app_quit), chau7_next/src/cto/mod.rs (init, teardown), chau7_next/src/remote/mod.rs (init, on_app_quit) | done | Unix sockets |
| APP-017 | PTY logs over 10 MB in `~/Library/Logs/Chau7/` are trimmed to their last 5 MB at launch | `App/AppDelegate.swift` (`purgeLargePTYLogs`) | | | n/a | |
| APP-018 | Dock icon from the bundle (`AppDockIcon`), with a generated bell icon when running unbundled | `App/AppIcon.swift` |  | apps/chau7-next/scripts/bundle-macos.sh (bundle icon), chau7_next/src/app_icon.rs, chau7_next/src/platform/attention.rs (set_unbundled_app_icon), chau7_next_core/src/app_icon.rs | done | NSApplication.applicationIconImage |
| APP-019 | Only one instance can run (`LSMultipleInstancesProhibited`) | `Scripts/build-app.sh` |  | apps/chau7-next/scripts/bundle-macos.sh (`LSMultipleInstancesProhibited`) | done | Info.plist |
| APP-020 | Menu bar only mode (hidden preference `window.menuBarOnlyMode`): no Dock icon, app lives in the status item | `App/Chau7App.swift` |  | `chau7_next/src/app_actions.rs` (`apply_menu_bar_only_mode`), `chau7_next/src/platform/defaults.rs` | done | NSApplication.ActivationPolicy |
| APP-021 | Floating window (hidden preference `window.floating`): terminal windows stay above other apps | `App/AppDelegate.swift` (`createOverlayWindow`) |  | `chau7_next/src/workspace/window.rs` (`apply_window_style`), `chau7_next/src/platform/window_style.rs` (`set_window_floating`), `chau7_next/src/settings/appearance.rs` (`window_floating`) | done | NSWindow.level |
| APP-022 | App theme setting (System, Light, Dark) applies to every window, settings, splash and debug console, live | `App/AppDelegate.swift` (`applyAppTheme`) |  | `chau7_next/src/theme.rs` (`app_is_dark`, `Chrome::panels`), `chau7_next/src/platform/window_style.rs` (`set_app_theme`), `chau7_next/src/settings/appearance.rs` (`app_theme`) | done | NSAppearance |
| APP-023 | Window opacity applies live to every terminal window; window background is always a blurred HUD material | `App/AppDelegate.swift` (`applyWindowOpacity`, `createOverlayWindow`) |  | `chau7_next/src/workspace/window.rs` (`background_appearance`: blurred on macOS), `chau7_next/src/workspace/mod.rs` (`reload_settings`: live) | done | NSVisualEffectView |
| APP-024 | Full screen keeps the tab bar visible and auto-hides the menu bar | `App/AppDelegate.swift` (`windowWillEnterFullScreen`, `willUseFullScreenPresentationOptions`) |  | `chau7_next/src/workspace/` (tab bar is window content, so it stays in full screen; macOS hides the menu bar) | done | NSWindow |
| APP-025 | Clicking a `chau7://run/<base64 command>` link asks for confirmation, then runs the command in a new tab | `App/AppDelegate.swift` (`handleChau7URL`, `confirmAndRun`) |  | `chau7_next/src/app_actions.rs` (`handle_url`, `confirm_and_run`), `chau7_next_core/src/app_shell.rs` (`parse_url`) | done | CFBundleURLTypes, NSApplicationDelegate open urls |
| APP-026 | `chau7://ssh/user@host[:port]` opens a new tab running `ssh` to that host | `App/AppDelegate.swift` (`handleChau7URL`) |  | `chau7_next/src/app_actions.rs` (`handle_url`), `chau7_next_core/src/app_shell.rs` | done | CFBundleURLTypes |
| APP-027 | `chau7://cd/<path>` opens a new tab in that directory | `App/AppDelegate.swift` (`handleChau7URL`) |  | `chau7_next/src/app_actions.rs` (`handle_url`), `chau7_next_core/src/app_shell.rs` | done | CFBundleURLTypes |
| APP-028 | `chau7://open/<path>` opens the file in an editor pane of the current tab | `App/AppDelegate.swift` (`handleChau7URL`) |  | chau7_next/src/app_actions.rs,chau7_next/src/workspace/panes.rs | done | CFBundleURLTypes |
| APP-029 | App menu: About Chau7 shows the standard About panel with version, build number and credits | `App/AppDelegate.swift` (`showAbout`) |  | `chau7_next/src/settings_window/about.rs` (`open_about`: About window with version, build and credits) | done | NSApplication.orderFrontStandardAboutPanel |
| APP-030 | App menu: Settings... (Cmd+,) opens the settings window, or brings it to front | `App/Chau7App.swift`, `App/AppDelegate.swift` (`showSettings`) | | `chau7_next/src/actions/`, `chau7_next/src/settings_window/` | done | |
| APP-031 | App menu: standard items Services, Hide Chau7 (Cmd+H), Hide Others (Cmd+Opt+H), Show All | SwiftUI default app menu |  | `chau7_next/src/actions/menus.rs`, `chau7_next/src/app_actions.rs` (Services, Hide, Hide Others, Show All) | done | NSApplication |
| APP-032 | App menu: Quit Chau7 (Cmd+Q) saves the session and quits | SwiftUI default app menu, `App/AppDelegate.swift` | | `chau7_next/src/actions/`, `chau7_next/src/main.rs` | done | |
| APP-033 | File menu: New Window (Cmd+N) | `App/Chau7App.swift` | | `chau7_next/src/actions/` (Shell menu) | done | |
| APP-034 | File menu: New Tab (Cmd+T) | `App/Chau7App.swift` | | `chau7_next/src/actions/` (Shell menu) | done | |
| APP-035 | File menu: SSH Connections... (Cmd+Shift+O) opens the SSH connection manager | `App/Chau7App.swift` |  | chau7_next/src/actions/menus.rs, chau7_next/src/actions/keymap.rs (cmd-shift-o), chau7_next/src/commands.rs, chau7_next/src/profiles/ssh_manager.rs | done |  |
| APP-036 | File menu: Close Tab (Cmd+W) | `App/Chau7App.swift` | `AppDelegateTests` | `chau7_next/src/actions/` | done | |
| APP-037 | File menu: Close Window (Cmd+Shift+W) | `App/Chau7App.swift` | `AppDelegateTests` | `chau7_next/src/workspace/window.rs` (`close_window`) | done |  |
| APP-038 | File menu: Close Other Tabs (Cmd+Opt+W) | `App/Chau7App.swift` |  | `chau7_next/src/workspace/mod.rs` (`close_other_tabs`), `chau7_next/src/actions/keymap.rs` | done |  |
| APP-039 | File menu: Reopen Closed Tab (Cmd+Shift+T) | `App/Chau7App.swift` | | `chau7_next/src/actions/`, `chau7_next/src/workspace/` (`reopen_closed`) | done | |
| APP-040 | File menu: Export Text... (Cmd+Shift+S) saves the terminal buffer to a `.txt` file through a save panel | `App/AppDelegate.swift` (`exportText`) |  | `chau7_next/src/workspace/keys.rs` (`export_text`) | done | NSSavePanel |
| APP-041 | File menu: Print... (Cmd+P) prints the terminal through the print panel | `App/AppDelegate.swift` (`printTerminal`) |  | `chau7_next/src/workspace/keys.rs` (`print_terminal`), `chau7_next/src/platform/print.rs` | done | NSPrintOperation |
| APP-042 | Edit menu: Cut (Cmd+X) copies in a terminal, cuts in text fields | `App/AppDelegate.swift` (`cut`) | `AppDelegateTests` | `chau7_next/src/terminal/input.rs` (Cut copies), `chau7_next/src/actions/keymap.rs` | done |  |
| APP-043 | Edit menu: Copy (Cmd+C) and Paste (Cmd+V) | `App/AppDelegate.swift` (`copyOrInterrupt`, `paste`) | | `chau7_next/src/actions/`, `chau7_next/src/terminal/view.rs` | done | |
| APP-044 | Edit menu: AutoFill from Passwords... inserts a password from the macOS Passwords app | `App/AppDelegate.swift` (`autofillFromPasswords`) |  | `chau7_next/src/terminal/input.rs` (`autofill`), `chau7_next/src/platform/autofill.rs` | done | NSResponder password autofill |
| APP-045 | Edit menu: Paste Escaped (Cmd+Opt+V) pastes the clipboard shell escaped | `App/AppDelegate.swift` (`pasteEscaped`) |  | `chau7_next/src/terminal/input.rs` (`paste_escaped`), `chau7_next_core/src/input/paste_escaper.rs` | done |  |
| APP-046 | Edit menu: Select All (Cmd+A) selects the current command (with wrapped rows); a second Cmd+A within 0.4 s selects the whole buffer | `App/AppDelegate.swift` (`selectAll`) |  | chau7_next/src/terminal/input.rs (select_all: line selection type 3 at the cursor, whole buffer on a second Cmd+A within 400 ms) | done |  |
| APP-047 | Edit menu: Find..., Find Next, Find Previous (Cmd+F, Cmd+G, Cmd+Shift+G) | `App/Chau7App.swift` | | `chau7_next/src/actions/` | done | |
| APP-048 | Edit menu: Use Selection for Find (Cmd+E) | `App/AppDelegate.swift` (`useSelectionForFind`) |  | `chau7_next/src/workspace/keys.rs` (UseSelectionForFind), `chau7_next/src/workspace/find.rs` (`search_for`) | done |  |
| APP-049 | Edit menu: Snippets... (Cmd+;) | `App/Chau7App.swift` |  | `chau7_next/src/actions/keymap.rs` (Cmd+;) | done |  |
| APP-050 | Edit menu: Command Palette... (Cmd+Opt+P) | `App/Chau7App.swift` |  | `chau7_next/src/actions/keymap.rs` (Cmd+Opt+P, Cmd+Shift+P kept) | done |  |
| APP-051 | View menu: Data Explorer (Cmd+Shift+D) | `App/Chau7App.swift` |  | chau7_next/src/app_actions.rs,chau7_next/src/data_explorer.rs | done |  |
| APP-052 | View menu: Enter Full Screen (Cmd+Ctrl+F) | `App/Chau7App.swift` | | `chau7_next/src/actions/` | done | |
| APP-053 | View menu: Zoom In, Zoom Out, Actual Size (Cmd+=, Cmd+-, Actual Size on the key labeled "à") | `App/Chau7App.swift` | | `chau7_next/src/actions/` (Bigger, Smaller, Actual Size on Cmd+0) | done | |
| APP-054 | View menu: Clear Screen (Cmd+K) sends Ctrl-L to the shell and clears the selection | `App/AppDelegate.swift` (`clearScreen`) |  | `chau7_next/src/terminal/input.rs` (`clear_screen`: Ctrl-L, clears the selection), `chau7_next/src/actions/keymap.rs` (Cmd+K) | done |  |
| APP-055 | View menu: Clear Scrollback (Cmd+Opt+K) | `App/AppDelegate.swift` (`clearScrollback`) |  | `chau7_next/src/terminal/view.rs` (`clear_scrollback`), `chau7_next/src/actions/keymap.rs` (Cmd+Opt+K) | done |  |
| APP-056 | View menu: Previous Input Line / Next Input Line (Cmd+Up, Cmd+Down) jump between prompts | `App/AppDelegate.swift` (`scrollToPreviousInputLine`) |  | `chau7_next_core/src/input/input_lines.rs`, `chau7_next/src/terminal/input.rs` (`jump_input_line`), `chau7_next/src/actions/keymap.rs` (Cmd+Up, Cmd+Down) | done |  |
| APP-057 | View menu, Panes: Split Horizontally (Cmd+D), Split Vertically (Cmd+Opt+D) | `App/Chau7App.swift` |  | `chau7_next/src/actions/keymap.rs` (Cmd+D split right, Cmd+Opt+D split down) | done |  |
| APP-058 | View menu, Panes: Open Text Editor (Cmd+Opt+E), Open File Preview (Cmd+Opt+O), Open Diff Viewer (Cmd+Opt+Shift+D, file from the last AI command or first dirty file), Append Selection to Editor (Cmd+Opt+Shift+E) | `App/AppDelegate.swift` |  | chau7_next/src/workspace/panes.rs,chau7_next/src/app_actions.rs | done |  |
| APP-059 | View menu, Panes: Close Pane (Cmd+Ctrl+W) | `App/Chau7App.swift` |  | `chau7_next/src/actions/keymap.rs` (Cmd+Ctrl+W) | done |  |
| APP-060 | View menu, Panes: Focus Next Pane, Focus Previous Pane (Cmd+Opt+], Cmd+Opt+[) | `App/Chau7App.swift` |  | `chau7_next/src/actions/keymap.rs` (Cmd+Opt+], Cmd+Opt+[) | done |  |
| APP-061 | View menu: Show Changed Files (Cmd+Opt+G) lists files changed by the last AI command | `App/AppDelegate.swift` (`showChangedFiles`) |  | chau7_next/src/workspace/panes.rs,chau7_next/src/panes/changed_files.rs | done |  |
| APP-062 | Window menu: Minimize (Cmd+M) and Zoom | system Window menu | | `chau7_next/src/actions/` | done | |
| APP-063 | Window menu: Rename Tab... (Cmd+Opt+R) | `App/Chau7App.swift` | | `chau7_next/src/actions/` (Shell menu) | done | |
| APP-064 | Window menu: Show Next Tab, Show Previous Tab (Cmd+Shift+], Cmd+Shift+[) | `App/Chau7App.swift` | | `chau7_next/src/actions/` | done | |
| APP-065 | Window menu: Move Tab Right, Move Tab Left (Cmd+Opt+Shift+], Cmd+Opt+Shift+[) | `App/AppDelegate.swift` |  | `chau7_next/src/workspace/mod.rs` (MoveTabLeft, MoveTabRight), `chau7_next/src/actions/keymap.rs` | done |  |
| APP-066 | Window menu: Select Tab submenu listing tab names, tabs 1 to 9 on Cmd+1..9, later tabs without shortcut | `App/Chau7App.swift` |  | `chau7_next/src/actions/menus.rs` (Select Tab submenu from tab titles), `chau7_next/src/workspace/mod.rs` (`sync_window_menu`) | done |  |
| APP-067 | Window menu: Refresh Tab Bar (Cmd+Opt+Shift+R) rebuilds a stale toolbar tab bar | `App/AppDelegate.swift` (`refreshTabBar`) | | | n/a | |
| APP-068 | Window menu: system window list and Bring All to Front | system Window menu |  | chau7_next/src/actions/menus.rs (Window menu, Bring All to Front), chau7_next/src/app_actions.rs (bring_all_to_front) | done | NSApplication windows menu |
| APP-069 | Help menu: Welcome to Chau7 reopens the welcome screen | `App/AppDelegate.swift` (`showWelcomeFromMenu`) |  | chau7_next/src/views/launch.rs | done |  |
| APP-070 | Help menu: Chau7 Help opens the help window | `App/AppDelegate.swift` (`showHelp`) |  | chau7_next/src/views/help_window.rs | done |  |
| APP-071 | Help menu: Technology, Licenses & Acknowledgments opens that help topic | `App/AppDelegate.swift` (`showTechnologyLicenses`) |  | chau7_next/src/views/help_window.rs | done |  |
| APP-072 | Help menu: Keyboard Shortcuts... (Cmd+/) opens the shortcuts window | `App/AppDelegate.swift` (`showKeyboardShortcuts`) |  | `chau7_next/src/settings_window/shortcuts.rs` (`open`), `chau7_next/src/workspace/keys.rs` | done |  |
| APP-073 | Help menu: Report Issue (Cmd+Opt+I) opens the bug report window | `App/AppDelegate.swift` (`reportIssue`) |  | chau7_next/src/debug/mod.rs, chau7_next/src/actions/menus.rs | done |  |
| APP-074 | (dev) Help menu: Debug Console (Cmd+Opt+L) | `App/Chau7App.swift` |  | chau7_next/src/debug/mod.rs, chau7_next/src/actions/menus.rs | done |  |
| APP-075 | Ctrl+Tab and Ctrl+Shift+Tab switch to the next and previous tab on macOS | `App/AppDelegate.swift` (`handleKeyEvent`) |  | `chau7_next/src/actions/keymap.rs` (Ctrl+Tab, Ctrl+Shift+Tab) | done |  |
| APP-076 | Cmd+Opt+Right and Cmd+Opt+Left switch tabs while the default tab shortcuts are unchanged and no text field has focus | `App/AppDelegate.swift` (`handleKeyEvent`, `shouldUseAlternateTabNavigationShortcuts`) |  | `chau7_next/src/actions/keymap.rs` (`bind_shortcut_settings`) | done |  |
| APP-077 | Escape closes the find bar, then the rename field | `App/AppDelegate.swift` (`handleKeyEvent`) | | `chau7_next/src/actions/`, `chau7_next/src/workspace/` | done | |
| APP-078 | Notification permission is requested once at first launch; status, warnings ("Alerts are disabled for Chau7...") and a test notification are available to Settings | `App/AppModel.swift` (`requestNotificationPermission`, `refreshNotificationStatus`, `sendTestNotification`) |  | chau7_next/src/notifications/mod.rs, chau7_next/src/notifications/banner.rs, chau7_next/src/platform/notifications.rs, chau7_next/src/settings_window/notifications.rs | done | UNUserNotificationCenter |
| APP-079 | Banners, sounds and badges are shown while the app is in front, following the user's notification settings | `App/AppModel.swift` (`userNotificationCenter willPresent`) |  | chau7_next/src/platform/notifications.rs (will_present) | done | UNUserNotificationCenter |
| APP-080 | AI event log `~/.ai-events.log` is tailed and its events feed notifications and the activity timeline (on by default) | `App/AppModel.swift` (`startTailer`) |  | chau7_next/src/ai/hub.rs | done |  |
| APP-081 | Codex and Claude `history.jsonl` are watched; a session idle for 5 s raises an "idle" event, sessions go stale after 180 s | `App/AppModel.swift` (`startIdleMonitors`, `notifyIdle`) | `AppModelEventRoutingTests` | chau7_next/src/history/monitor.rs, chau7_next/src/ai/hub.rs | done |  |
| APP-082 | Codex and Claude PTY logs are tailed into per tool line buffers (200 lines prefilled) for the log views | `App/AppModel.swift` (`startTerminalMonitors`) |  | chau7_next/src/history/monitor.rs (TERMINAL_PREFILL_LINES), chau7_next/src/ai/log_view.rs | done |  |
| APP-083 | Claude Code hook events drive session state, and a "waiting for input" event is synthesized when Claude finishes without a hook notification | `App/AppModel.swift` (`startClaudeCodeMonitor`, `scheduleClaudeWaitingInputFallback`) | `AppModelEventRoutingTests` | chau7_next/src/ai/hub.rs (schedule_claude_fallback), chau7_next_core/src/monitoring/claude_code.rs | done |  |
| APP-084 | API proxy calls (provider, model, tokens, cost) appear in the event timeline | `App/AppModel.swift` (`handleAPICallEvent`) |  | chau7_next/src/proxy/mod.rs (timeline_event) | done |  |

| APP-085 | Single application instance lock and launch continuity distinguish deliberate relaunch from crash; Next locks and restoration data remain independent | `App/ApplicationInstanceLock.swift`; `App/LaunchContinuityTracker.swift`; `Chau7Core/LaunchContinuityPolicy.swift` | LaunchContinuityPolicyTests | chau7_next/src/session_store.rs | partial |  |

## Notes

- Menus compared with `chau7_next/src/actions/` (`app_menus`). Chau7 Next
  names its menus "Chau7 Next", Shell, Edit, View, Window; it has no Help menu.
  Items only in Chau7 Next: Open config.toml, Reload Settings, Broadcast Input
  to All Tabs, Clipboard History..., Command History..., Load Demo Tabs (debug).
- Shortcut conflicts to resolve when porting the missing items: Rust uses
  Cmd+Shift+D for Split Down (Swift: Data Explorer), Cmd+Shift+S for Snippets
  (Swift: Export Text), Cmd+Opt+W for Close Pane (Swift: Close Other Tabs),
  Cmd+K for Clear Scrollback (Swift: Clear Screen), Cmd+]/[ for pane focus.
- The Swift Actual Size shortcut is bound to the "à" key (French layout), which
  is Cmd+0's position on an AZERTY keyboard.
- Launch: Swift keeps windows hidden behind the splash for 1.5 s while shells
  start, then shows them (see `Views.md`). Swift does not restore window
  frames; new windows are 1100x640 (capped to the screen) centered near the top.
  Chau7 Next restores frames and opens 980x620 centered.
- Session restore storage: Swift writes window 0 to UserDefaults key
  `com.chau7.savedTabState`, all windows to `com.chau7.savedMultiWindowState`
  (only when more than one window), plus JSON backups on disk. The multi window
  key is removed after restore so a crash does not duplicate windows, and an
  extra window whose tab IDs overlap window 0 by more than half is skipped
  (n/a for the Rust single `session.json` design).
- Hidden preferences with no UI in Swift: `window.menuBarOnlyMode`,
  `window.floating` (only read at window creation; the `windowFloatingChanged`
  notification has no observer).
- APP-024 is partial because only the toggle was checked in Rust; whether the
  GPUI titlebar tab bar stays visible in full screen is not verified.
- APP-017 is n/a while Chau7 Next writes no PTY logs; port it with PTY logging.
- APP-067 is a workaround for the Swift NSToolbar hosting view going stale; the
  GPUI tab bar does not need it.
- URL scheme: Swift registers `chau7` (`CFBundleURLName` `com.chau7.terminal`).
  Per DUAL-SHIP.md, Chau7 Next must register its own scheme while both apps ship.
  `chau7://ssh` and `chau7://cd` quote the argument with single quotes; `run`
  shows at most 500 characters of the command in the confirmation.
- No Dock menu (`applicationDockMenu`), no Services provider and no Finder
  integration (document types, "New Terminal at Folder") exist in the Swift
  app, so there is nothing to port there. The Dock's default window list comes
  from macOS for both apps.
- AppModel settings keys (UserDefaults): `isMonitoring`, `logPath`,
  `isIdleMonitoring`, `idleSeconds` (5), `staleSeconds` (180),
  `isTerminalMonitoring`, `codexTerminalPath`, `claudeTerminalPath`,
  `isTerminalNormalize`, `isTerminalAnsi`, `isSuspendBackgroundRendering`,
  `suspendRenderDelaySeconds`, `codexHistoryPath`, `claudeHistoryPath`. Each
  path can be overridden by an environment variable (see `Utilities.md`).
  AppModel also prunes history, session statuses and events older than 7 days
  every hour and keeps the last 25 events for the status bar timeline.
- `AppConstants.swift` limits (font 9 to 22 pt, 100 closed tabs, 50 clipboard
  items, 400 search matches) are applied by the features that use them.
- APP-068: gpui-pre-macos calls `setWindowsMenu_` on the menu named "Window", so AppKit appends the window list; Bring All to Front is an explicit item (`BringAllToFront`). To check on a Mac: the window list appears.
