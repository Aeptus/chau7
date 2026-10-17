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
| STB-001 | Bell icon in the macOS menu bar while the app runs; click opens or closes the command center popover (380 pt wide) under the icon | `StatusBar/StatusBarController.swift` (`setup`, `togglePopover`) | `StatusBarControllerTests` | chau7_next/src/status_bar/, chau7_next_core/src/command_center.rs | done | NSStatusItem, NSPopover |
| STB-002 | Popover closes on any click outside it, in Chau7 or in another app | `StatusBar/StatusBarController.swift` (global and local event monitors) |  | chau7_next/src/status_bar/, chau7_next_core/src/command_center.rs | done | NSEvent global monitor |
| STB-003 | Icon shows state: outline bell when monitoring is off, filled badge bell when on, plus the count for primary attention (approval first, otherwise waiting for input) | `StatusBar/StatusBarController.swift` (`updateBadgeAndIcon`) | `StatusBarControllerTests` | chau7_next/src/status_bar/, chau7_next_core/src/command_center.rs | done | NSStatusItem |
| STB-004 | Menu bar alert: a notification action can flash the icon (alert bell) for N seconds, optionally pulsing | `StatusBar/StatusBarController.swift` (`flashAlert`) |  | chau7_next/src/status_bar/, chau7_next_core/src/command_center.rs | done | NSStatusItem |
| STB-005 | Top of the popover: approval, waiting input, monitoring paused, running or quiet hero in this precedence, with truthful counted detail | `StatusBar/StatusBarController.swift` (`HeroZoneView` in `StatusBarPanelView.swift`) | `StatusBarControllerTests` | chau7_next/src/status_bar/, chau7_next_core/src/command_center.rs | done |  |
| STB-006 | Action list: up to 5 AI sessions ordered approval, waiting input, running, stuck then newest activity; title, state, tool name, folder and age; click shows the window and focuses that tab | `StatusBar/StatusBarController.swift` (`CommandCenterSessionSummary.collectLiveSessions`, `ActionSessionRow`, `focusSession`) | `StatusBarControllerTests` | chau7_next/src/status_bar/, chau7_next_core/src/command_center.rs | done |  |
| STB-007 | Recent activity starts collapsed; last 8 entries merged from history and tool-agnostic events, deduplicated by UUID; canonical semantic icon/color/title and compact Unicode-safe detail; limited notifications are dimmed | `StatusBar/StatusBarController.swift` (`unifiedTimeline`, `TimelineRow`) |  | chau7_next/src/status_bar/, chau7_next_core/src/command_center.rs | done |  |
| STB-008 | Pinned snippets: first 5; click inserts in the selected terminal or copies when none exists, retaining the panel with copy feedback; direct snippet settings anchor | `StatusBar/StatusBarController.swift` (`quickCommandsSection`, `executeSnippet`) |  | chau7_next/src/status_bar/, chau7_next_core/src/command_center.rs | done | NSPasteboard |
| STB-009 | Paused hero Resume enables monitoring and updates the icon; direct Monitoring button opens notifications/eventMonitoring settings | `StatusBar/StatusBarController.swift` (`HeroZoneView` in `StatusBarPanelView.swift`) | `StatusBarControllerTests` | chau7_next/src/status_bar/, chau7_next_core/src/command_center.rs | done |  |
| STB-010 | Footer Settings opens Start Here; feature buttons open concrete monitoring/snippet anchors | `StatusBar/StatusBarController.swift` |  | chau7_next/src/status_bar/, chau7_next_core/src/command_center.rs | done |  |
| STB-011 | Footer shows the app version and "Quit Chau7" with a confirmation popover | `StatusBar/StatusBarController.swift` (`footerSection`) |  | chau7_next/src/status_bar/, chau7_next_core/src/command_center.rs | done |  |
| STB-012 | Session list and badge refresh every second | `StatusBar/StatusBarController.swift` (`CommandCenterViewModel`) | `StatusBarControllerTests` | chau7_next/src/status_bar/, chau7_next_core/src/command_center.rs | done |  |
| STB-013 | Settings window: grouped sidebar of sections, one section shown at a time, minimum 860x650, only one window (brought to front when reopened) | `StatusBar/MainPanelView.swift` (`SettingsRootView`, `SettingsDetailView`), `App/AppDelegate.swift` (`showSettings`) |  | chau7_next/src/settings_window/ | done |  |
| STB-014 | Settings search: filters sections, shows a match count per section, selects the first match and lists matching settings | `StatusBar/MainPanelView.swift` (`SettingsSearchBar`, `SearchResultsHint`) |  | chau7_next/src/settings_window/ | done |  |
| STB-015 | Settings profile bar at the top of the settings window to switch settings profiles | `StatusBar/MainPanelView.swift` (`ProfileSelectorBar` in `SettingsRootView`) |  | chau7_next/src/settings_window/ | done |  |
| STB-016 | Legacy menu bar panel (stream picker for history, TTY and verbose logs, quick toggles, Reveal Log) | `StatusBar/MainPanelView.swift` (`MenuBarPanelView`, `StreamView`) | `StatusBarControllerTests` | | n/a | |

| STB-017 | Command Center uses current live provider/native identity and approval/waiting states, canonical timeline, primary attention counts, prioritized actions, direct settings anchors and snippet copy fallback | `StatusBar/CommandCenterSessionSummary.swift`; `StatusBar/CommandCenterTimeline.swift` | canonical timeline UUID/Unicode/source regressions; hero precedence/primary attention/count cap tests | chau7_next/src/status_bar/popover.rs; chau7_next/src/workspace/command_center.rs | done | Current-source implementation; native menu item/popover acceptance remains explicit in RECOVERY-VALIDATION.md. Current Swift summary has no token or cost fields; API analytics covers those separately. |

## Notes

- STB-016 is n/a: `MenuBarPanelView` is no longer shown anywhere (the status
  item uses `StatusBarPanelView`) and `StreamView` has no other caller. Tests
  still cover `StreamSelection`.
- Next reads live sessions from all open windows and uses stable tab/pane identity.
  Clicking an action focuses its owning window and tab.
- A session counts when its pane has an AI app name, provider or session id and
  its status is running, approval required, waiting for input or stuck. Title order: custom tab
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

- Current-source delta replaces the April hero and quick controls with the current
  prioritized action list, paused resume/settings, five pinned snippets, collapsed
  recent activity and footer Settings. Distinct UUIDs are never removed merely
  because timestamps are close. Canonical titles share the notification vocabulary.
