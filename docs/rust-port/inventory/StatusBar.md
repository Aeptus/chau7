# StatusBar

Swift: `apps/chau7-macos/Sources/Chau7/StatusBar/` (2 files, 1950 lines)
Swift tests: `StatusBar/StatusBarControllerTests`
Wave: 5 (see README.md)
Depends on: App, Notifications, Monitoring, AI, Snippets, Settings

The menu bar bell icon and its "command center" popover: which AI sessions
need input, live sessions, a recent activity timeline, pinned snippets, the
monitoring switch and Quit. The module also holds the shell of the Settings
window (sidebar, search, profile bar) that every settings pane sits in.

## Features

| ID | Feature | Swift source | Tests | Rust | Status | macOS API |
|---|---|---|---|---|---|---|
| STB-001 | Bell icon in the macOS menu bar while the app runs; click opens or closes the command center popover (400 pt wide) under the icon | `StatusBar/StatusBarController.swift` (`setup`, `togglePopover`) | `StatusBarControllerTests` | chau7_next/src/status_bar/, chau7_next_core/src/command_center.rs | done | NSStatusItem, NSPopover |
| STB-002 | Popover closes on any click outside it, in Chau7 or in another app | `StatusBar/StatusBarController.swift` (global and local event monitors) |  | chau7_next/src/status_bar/, chau7_next_core/src/command_center.rs | done | NSEvent global monitor |
| STB-003 | Icon shows state: outline bell when monitoring is off, filled badge bell when on, plus the number of AI sessions waiting for input next to it | `StatusBar/StatusBarController.swift` (`updateBadgeAndIcon`) | `StatusBarControllerTests` | chau7_next/src/status_bar/, chau7_next_core/src/command_center.rs | done | NSStatusItem |
| STB-004 | Menu bar alert: a notification action can flash the icon (alert bell) for N seconds, optionally pulsing | `StatusBar/StatusBarController.swift` (`flashAlert`) |  | chau7_next/src/status_bar/, chau7_next_core/src/command_center.rs | done | NSStatusItem |
| STB-005 | Top of the popover: "N sessions need attention" with up to 3 sessions and a Go button each, or "All clear" with the live session count and an Active/Paused dot | `StatusBar/StatusBarController.swift` (`HeroZoneView`) | `StatusBarControllerTests` | chau7_next/src/status_bar/, chau7_next_core/src/command_center.rs | done |  |
| STB-006 | Live Sessions: up to 5 AI sessions (working, waiting for input, no recent output) newest first, with title, state, tool name, folder and "N minutes ago"; click shows the window and focuses that tab | `StatusBar/StatusBarController.swift` (`CommandCenterSessionSummary.collectLiveSessions`, `LiveSessionCard`, `focusSession`) | `StatusBarControllerTests` | chau7_next/src/status_bar/, chau7_next_core/src/command_center.rs | done |  |
| STB-007 | Activity: last 8 entries merged from notification history and recent AI events (duplicates within 2 s dropped), each with icon, color, readable title ("Needs permission", "Running file write"...), detail and time; rate-limited notifications are dimmed | `StatusBar/StatusBarController.swift` (`unifiedTimeline`, `TimelineRow`) |  | chau7_next/src/status_bar/, chau7_next_core/src/command_center.rs | done |  |
| STB-008 | Quick Commands: the first 3 pinned snippets; click inserts the snippet in the selected tab, or copies it when no tab exists | `StatusBar/StatusBarController.swift` (`quickCommandsSection`, `executeSnippet`) |  | chau7_next/src/status_bar/, chau7_next_core/src/command_center.rs | done | NSPasteboard |
| STB-009 | Monitoring switch in the popover turns AI event monitoring on or off and updates the icon | `StatusBar/StatusBarController.swift` (`QuickSettingToggle`) | `StatusBarControllerTests` | chau7_next/src/status_bar/, chau7_next_core/src/command_center.rs | done |  |
| STB-010 | "All Settings" button opens the settings window | `StatusBar/StatusBarController.swift` |  | chau7_next/src/status_bar/, chau7_next_core/src/command_center.rs | done |  |
| STB-011 | Footer shows the app version and "Quit Chau7" with a confirmation popover | `StatusBar/StatusBarController.swift` (`footerSection`) |  | chau7_next/src/status_bar/, chau7_next_core/src/command_center.rs | done |  |
| STB-012 | Session list and badge refresh every second | `StatusBar/StatusBarController.swift` (`CommandCenterViewModel`) | `StatusBarControllerTests` | chau7_next/src/status_bar/, chau7_next_core/src/command_center.rs | done |  |
| STB-013 | Settings window: grouped sidebar of sections, one section shown at a time, minimum 860x650, only one window (brought to front when reopened) | `StatusBar/MainPanelView.swift` (`SettingsRootView`, `SettingsDetailView`), `App/AppDelegate.swift` (`showSettings`) |  | chau7_next/src/settings_window/ | done |  |
| STB-014 | Settings search: filters sections, shows a match count per section, selects the first match and lists matching settings | `StatusBar/MainPanelView.swift` (`SettingsSearchBar`, `SearchResultsHint`) |  | chau7_next/src/settings_window/ | done |  |
| STB-015 | Settings profile bar at the top of the settings window to switch settings profiles | `StatusBar/MainPanelView.swift` (`ProfileSelectorBar` in `SettingsRootView`) |  | chau7_next/src/settings_window/ | done |  |
| STB-016 | Legacy menu bar panel (stream picker for history, TTY and verbose logs, quick toggles, Reveal Log) | `StatusBar/MainPanelView.swift` (`MenuBarPanelView`, `StreamView`) | `StatusBarControllerTests` | | n/a | |

| STB-017 | Command Center panel session summary and timeline show current provider/token/cost/approval state with tab focus and actions | `StatusBar/CommandCenterSessionSummary.swift`; `StatusBar/CommandCenterTimeline.swift` |  | chau7_next/src/status_bar/popover.rs; chau7_next/src/workspace/command_center.rs | partial |  |

## Notes

- STB-016 is n/a: `MenuBarPanelView` is no longer shown anywhere (the status
  item uses `StatusBarPanelView`) and `StreamView` has no other caller. Tests
  still cover `StreamSelection`.
- Live sessions are read from the first window's tabs only
  (`AppDelegate.overlayModel`), not from every window. Decide whether to keep
  that or fix it in the port.
- A session counts when its pane has an AI app name, provider or session id and
  its status is running, waiting for input or stuck. Title order: custom tab
  title, else the tab title unless it is "Shell", "Editor" or the tool name,
  else the folder name.
- The timeline uses the tool agnostic `AIEvent` stream (`AppModel.recentEvents`,
  last 25), never Claude Code specific events.
- The icon reacts to the `MonitoringStateChanged` notification and to
  `AppModel.isMonitoring`.
- Settings pane contents are inventoried in `Settings.md`; STB-013 to STB-015
  only cover the window shell.
- GPUI has no status item API; this needs an AppKit `NSStatusItem` behind a
  trait in `chau7_next` (stub on Linux and Windows, or a tray icon there).
