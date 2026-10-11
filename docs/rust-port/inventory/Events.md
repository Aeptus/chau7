# Events

Swift: `apps/chau7-macos/Sources/Chau7/Events/` (1 file, 291 lines)
Swift tests: none
Wave: 2
Depends on: Notifications (rules and delivery), App (`AppModel.recordEvent`), Settings (`appEventConfig`)

`AppEventEmitter` produces app-level events that are not tied to a terminal:
user-defined schedules (every N minutes, daily, hourly), an inactivity timeout
and an app memory threshold. Each event goes through the same pipeline as
terminal and AI events, so notification rules can act on it. The Notes list
every event type in the app, who emits it and who consumes it.

## Features

| ID | Feature | Swift source | Tests | Rust | Status | macOS API |
|---|---|---|---|---|---|---|
| EVT-001 | Scheduled event, interval: fires every N minutes (default 60) with the schedule's name as message | `Events/AppEventEmitter.swift` (`calculateSchedule`, `.interval`) |  | chau7_next/src/notifications/app_events.rs, chau7_next_core/src/notifications/app_events.rs | done |  |
| EVT-002 | Scheduled event, daily: fires at a time of day (local calendar), then every 24 h | `Events/AppEventEmitter.swift` (`.daily`) |  | chau7_next/src/notifications/app_events.rs, chau7_next_core/src/notifications/app_events.rs | done |  |
| EVT-003 | Scheduled event, hourly: fires at minute M (0 to 59) of every hour | `Events/AppEventEmitter.swift` (`.hourly`) |  | chau7_next/src/notifications/app_events.rs, chau7_next_core/src/notifications/app_events.rs | done |  |
| EVT-004 | Schedules can be disabled one by one; a schedule disabled since its timer was set is skipped when it fires | `Events/AppEventEmitter.swift` (`fireScheduledEvent`) |  | chau7_next/src/notifications/app_events.rs (fire_schedule) | done |  |
| EVT-005 | Schedules, inactivity and memory timers rebuild whenever settings change | `Events/AppEventEmitter.swift` (`observeConfigChanges`, `setupTimers`) |  | chau7_next/src/notifications/app_events.rs (sync_timers) | done |  |
| EVT-006 | Inactivity timeout: "No activity for N minutes" once after the threshold (checked every minute; 0 turns it off) | `Events/AppEventEmitter.swift` (`checkInactivity`), `App/AppModel.swift` (`recordUserActivity`) |  | chau7_next/src/notifications/app_events.rs, chau7_next_core/src/notifications/app_events.rs (InactivityTracker), chau7_next/src/workspace/mod.rs (Input) | done |  |
| EVT-007 | Memory threshold: app memory checked every 30 s; fires above the threshold (MB), re-arms after dropping 50 MB (hysteresis setting) below it, at most once per 5 min | `Events/AppEventEmitter.swift` (`checkMemory`, `getCurrentMemoryUsageMB`) |  | chau7_next/src/notifications/app_events.rs, chau7_next_core/src/notifications/app_events.rs (MemoryMonitor), chau7_next/src/platform/process.rs | done | mach task_info |
| EVT-008 | Tab opened and tab closed events with the tab count (both off by default) | `Overlay/OverlayTabsModel+TabSwitchOptimization.swift`, `Settings/FeatureSettings.swift` (`AppEventConfig.notifyOnTabOpen`, `notifyOnTabClose`) |  | chau7_next/src/notifications/app_events.rs (tab_opened, tab_closed), chau7_next/src/workspace/mod.rs | done |  |
| EVT-009 | App events enter the shared pipeline as source `app`, tool `App`, with notify on: notification ingress, then notification rules and actions, then the recent events list (last 25) | `Events/AppEventEmitter.swift` (`emitEvent`), `App/AppModel.swift` (`recordEvent`, `publishUnifiedEvent`) |  | chau7_next/src/notifications/mod.rs (record_event, record_app_event, recent_events) | done |  |
| EVT-010 | Settings page for app events: inactivity minutes, memory threshold, tab open and close toggles (scheduled events and memory hysteresis exist in `AppEventEmitter` but have no UI in Swift) | `Settings/Views/NotificationsSettingsView.swift` |  | chau7_next/src/settings_window/notifications.rs (Thresholds), chau7_next/src/settings/notifications.rs | done |  |

## Notes

- **Config** (`FeatureSettings.appEventConfig`, Codable `AppEventConfig`):
  `scheduledEvents` (`ScheduledEvent`: `id`, `name`, `scheduleType`
  interval/daily/hourly, `intervalMinutes` 60, `dailyTime`, `hourlyMinute` 0,
  `isEnabled` true), `inactivityThresholdMinutes` 0 (off),
  `memoryThresholdMB` 0 (off), `memoryHysteresisMB` 50, `notifyOnTabOpen`
  false, `notifyOnTabClose` false.
- **Chau7 Next** (ported): `chau7_next::notifications::app_events`. Typing resets the inactivity clock; timers rebuild only when the app event config changes. As in Swift, the provider adapters drop `scheduled` and `inactivity_timeout` at ingress (not in the app adapter's list), so those two reach the log but never notify.
- **Swift quirks** (decide before porting):
  - `AppModel.recordUserActivity()` has no caller, so the inactivity clock
    starts at launch and never resets: EVT-006 fires once, N minutes after
    launch, whatever the user does. Chau7 Next should reset it on key input.
  - The config observer listens to every `UserDefaults` change, so any setting
    change (even unrelated) restarts all schedules; an interval schedule then
    waits a full interval again.
  - Memory is the app's own resident size (`mach_task_basic_info`), not the
    shells'.
- **Event shape.** Everything in the app is an `AIEvent`
  (`Chau7Core/AIEvent.swift`): `source` (`AIEventSource`), `type` (string),
  `tool`, `message` (escape sequences stripped), ISO 8601 `ts`, optional
  `directory`, `tabID`, `sessionID`, `producer`, `reliability`
  (authoritative, fallback, heuristic). `AppModel.recordEvent` resolves the tab,
  then `NotificationIngress.ingest` accepts or drops it; accepted events go to
  `NotificationManager.notify` (when notify is true) and `recentEvents`.
- **Event catalog** (type, source, emitter, module):
  - `scheduled`, `inactivity_timeout`, `memory_threshold`: `app`,
    `AppEventEmitter` (this module).
  - `tab_opened`, `tab_closed`: `app`, `OverlayTabsModel` (Overlay).
  - `finished`, `failed` on shell exit: `terminal_session`,
    `TerminalSessionModel.handleProcessTermination` (Terminal, TRM-008).
  - `waiting_input` fallback: the AI tool's source (for example
    `claude_code`, `codex`), `TerminalSessionModel` (Terminal, TRM-043).
  - `process_started`, `process_ended`, `command_finished` (only when
    "notify on all command completion" is on), `command_failed`,
    `exit_code_match` (watched exit codes), `directory_changed`,
    `git_branch_changed`, `long_running` (tiered durations), and custom output
    pattern types (rate-limited): `shell`, `ShellEventDetector` (Monitoring),
    fed by the Terminal session.
  - AI tool events (permission, tool_called, finished ...): `claude_code`,
    `codex`, `cursor`, `windsurf`, `copilot`, `aider`, `cline`,
    `continue_ai`, `history_monitor`, `events_log`, `runtime`, `api_proxy`
    (AI, History, Runtime, Proxy modules).
  - Also written to `~/.ai-events.log` by the AI PTY logger: `info`,
    `finished`, `failed` (Terminal, TRM-045).
- **Consumers.** `NotificationManager` (rules, trigger actions, system
  notifications, tab styles), the recent events list (status bar and debug
  console), MCP and remote control through `AppModel`.
- **Chau7 Next today** has no shared event type. GPUI events stay local:
  `SessionEvent` (`Output`, `MetadataChanged`, `Bell`, `CommandFinished`,
  `Exited`, `ClipboardStore`) in `terminal/session.rs`, re-emitted as
  `PaneEvent` (`Activity`, `MetadataChanged`, `Bell`, `CommandFinished`,
  `Input`, ...) in `pane.rs`, and `TerminalViewEvent` (`Focused`, `Input`) in
  `terminal/view.rs`. `workspace/` turns `Bell` and `CommandFinished` into
  tab styles and a system notification for commands over 10 s while the
  window is inactive. Porting this module needs an `AIEvent` equivalent in
  `chau7_next_core` first (Notifications module).
