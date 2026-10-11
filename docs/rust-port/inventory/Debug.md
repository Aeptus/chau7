# Debug

Swift: `apps/chau7-macos/Sources/Chau7/Debug/` (3 files, 2,539 lines)
Swift tests: none
Wave: 5 (see README.md)
Depends on: Logging, Overlay, Terminal, Settings, TokenOptimization, Telemetry, Proxy, Analytics, Repository, Notifications, Performance (FeatureProfiler), SplitPanes (diff viewer, file preview)

The Debug Console is a separate window with nine tabs that shows live app state, token optimizer health, AI events, input/output lag spikes, per-feature timings, the log file with filters, bug report and snapshot actions, usage analytics and a health dashboard. The module also holds the last-command badge model shown on tabs and the Changed Files panel listing files an AI command touched.

## Features

| ID | Feature | Swift source | Tests | Rust | Status | macOS API |
|---|---|---|---|---|---|---|
| DBG-001 | (dev) Debug Console window (700x500, resizable), toggled with Cmd+Opt+L (`debugConsole` keybinding), the menu item, the command palette, or buttons in General and About settings; follows the app appearance | `Debug/DebugConsoleView.swift` (`DebugConsoleController`) |  | chau7_next/src/debug/console.rs, chau7_next/src/debug/mod.rs, chau7_next_core/src/debug_console.rs | done |  |
| DBG-002 | (dev) Auto-refresh switch: refreshes the visible tab every second (Perf, Token Optimizer, Logs, Analytics) | `Debug/DebugConsoleView.swift` |  | chau7_next/src/debug/console.rs | done |  |
| DBG-003 | (dev) State tab, Application box: monitoring on/paused, tab count, active tab, Claude session count, event counts | `Debug/DebugConsoleView.swift` |  | chau7_next/src/debug/tabs/state.rs | done |  |
| DBG-004 | (dev) State tab, Tabs box: per tab title, AI app, directory, status, input/output/highlight lag, git branch, active marker | `Debug/DebugConsoleView.swift` |  | chau7_next/src/debug/tabs/state.rs, chau7_next/src/workspace/debug.rs | done |  |
| DBG-005 | (dev) State tab: p50/p95 input, output and highlight latency for the active tab | `Debug/DebugConsoleView.swift` |  | chau7_next/src/debug/tabs/state.rs | done |  |
| DBG-006 | (dev) State tab: live controls for low-power dangerous-output highlighting, highlight idle delay (0 to 5,000 ms) and max interval (250 to 10,000 ms) | `Debug/DebugConsoleView.swift` |  | chau7_next/src/debug/tabs/state.rs, chau7_next/src/settings/dangerous_commands.rs, chau7_next/src/terminal/view/danger.rs | done |  |
| DBG-007 | (dev) State tab: feature flags (snippets, repo snippets, broadcast, clipboard history, bookmarks) | `Debug/DebugConsoleView.swift` |  | chau7_next/src/debug/tabs/state.rs, chau7_next/src/debug/snapshot.rs | done |  |
| DBG-008 | (dev) Token Optimizer tab: period picker (Session, Today, 7 Days, All Time), hero metrics (command rate, token rate, tokens saved, optimized, fallthrough, skipped) | `Debug/DebugConsoleView.swift` |  | chau7_next/src/cto/debug_source.rs | done |  |
| DBG-009 | (dev) Token Optimizer tab: per-tab table (commands, optimized, fallthrough, skipped, rate, in/out tokens, cost, CTO saved) and provider consumption | `Debug/DebugConsoleView.swift` |  | chau7_next/src/cto/debug_source.rs (data: telemetry token_usage_per_tab, consumption_per_provider), chau7_next/src/cto/mod.rs (refresh_gain), chau7_next/src/debug/tabs/cto.rs | done |  |
| DBG-010 | (dev) Token Optimizer tab: last 20 optimized commands with outcome color and exit code | `Debug/DebugConsoleView.swift` |  | chau7_next/src/cto/debug_source.rs | done |  |
| DBG-011 | (dev) Token Optimizer tab: Advanced Telemetry (health state and score, recalculations, flag changes, change rate, decisions/min, uptime, deferred stats, health issues, decision reasons, recent decisions), Refresh and Reset Monitor buttons | `Debug/DebugConsoleView.swift` |  | chau7_next/src/cto/debug_source.rs | done |  |
| DBG-012 | (dev) Events tab: all AI events or Claude events only, newest first, colored by type | `Debug/DebugConsoleView.swift` |  | chau7_next/src/debug/tabs/events.rs, chau7_next/src/debug/registry.rs, chau7_next/src/seams.rs (record_debug_event, called by the notification ingress) | done |  |
| DBG-013 | (dev) Lag tab: timeline of input/output/highlight lag spikes (ms, average, p50/p95, sample count, tab, app, cwd) for the active tab or all tabs, with Clear | `Debug/DebugConsoleView.swift` |  | chau7_next/src/debug/tabs/lag.rs, chau7_next/src/workspace/debug.rs | done |  |
| DBG-014 | (dev) Perf tab: per-feature totals (total, avg, max, count) for the last 10 s and 60 s, recent events (up to 160, "slow only" hides under 8 ms) | `Debug/DebugConsoleView.swift` |  | chau7_next/src/debug/tabs/perf.rs | done |  |
| DBG-015 | (dev) Logs tab: last 200 lines of the log file, newest first, text filter, level chips (TRACE, DEBUG, INFO, WARN, ERROR), category chips, All and Errors presets, Refresh, Open File, entry count, app memory | `Debug/DebugConsoleView.swift` |  | chau7_next/src/debug/tabs/logs.rs, chau7_next/src/logging/mod.rs, chau7_next_core/src/debug_console.rs | done | NSWorkspace |
| DBG-016 | (dev) Report tab: description box, Generate Github Report (opens a prefilled GitHub issue), Save Report (to `~/.chau7/reports/`), Open Reports Folder, shows the last path | `Debug/DebugConsoleView.swift` |  | chau7_next/src/debug/tabs/report.rs, chau7_next/src/debug/snapshot.rs | done | NSWorkspace |
| DBG-017 | (dev) Report tab quick actions: Capture Snapshot (to `~/.chau7/snapshots/`), Copy State JSON to the clipboard, Clear Event History | `Debug/DebugConsoleView.swift` |  | chau7_next/src/debug/tabs/report.rs, chau7_next/src/debug/snapshot.rs | done |  |
| DBG-018 | (dev) Analytics tab, API Calls: proxy call count and tokens, per provider, daily trend, recent calls | `Debug/DebugConsoleView.swift` |  | chau7_next/src/debug/tabs/analytics.rs, chau7_next/src/debug/registry.rs, chau7_next/src/telemetry.rs (analytics_data) | done |  |
| DBG-019 | (dev) Analytics tab, AI Runs: per provider, per tab, daily cost trend, totals, Rebuild Transcript Metrics button | `Debug/DebugConsoleView.swift` |  | chau7_next/src/debug/tabs/analytics.rs, chau7_next/src/debug/registry.rs, chau7_next/src/telemetry.rs (analytics_data, rebuild) | done |  |
| DBG-020 | (dev) Analytics tab, Repos: per repo commands, runs, last activity, top tools | `Debug/DebugConsoleView.swift` |  | chau7_next/src/debug/tabs/analytics.rs, chau7_next/src/debug/registry.rs, chau7_next/src/telemetry.rs (analytics_data) | done |  |
| DBG-021 | (dev) Health tab: tab count with idle (over 10 min, not selected) and active, shell integration coverage, suspended tabs | `Debug/DebugConsoleView.swift` |  | chau7_next/src/debug/tabs/health.rs | done |  |
| DBG-022 | (dev) Health tab: sizes of `~/Library/Logs/Chau7/*.log` (PTY logs), red above 10 MB | `Debug/DebugConsoleView.swift` |  | chau7_next/src/debug/tabs/health.rs | done |  |
| DBG-023 | (dev) Health tab: rendering info (atlas mode, ligatures) and notification reliability (completed, dropped, retries, rate limited, authoritative, over the last 100) | `Debug/DebugConsoleView.swift` |  | chau7_next/src/debug/tabs/health.rs, chau7_next/src/debug/registry.rs, chau7_next/src/seams.rs (reliability_rows), chau7_next_core/src/notifications/history.rs (ReliabilitySummary) | done |  |
| DBG-024 | Last-command badge on the tab: "..." while running, then "✓ 1.2s" or "✗ 340ms" (ms, s, m s, h m); hover card shows the command text and exit code; setting to hide the badge | `Debug/LastCommandInfo.swift`, `Overlay/OverlayTabsModel.swift`, `Overlay/TabHoverCard.swift` |  | chau7_next/src/workspace/ (command_badge, hover_card.rs), chau7_next/src/terminal/session.rs (LastCommand) | done |  |
| DBG-025 | Changed Files panel (`showChangedFiles` action, no default key): floating list of files the last AI command changed, filter box, git diff stats, file icons, context menu Open Diff / Preview File / Copy Path / Copy All Paths, Copy All button | `Debug/ChangedFilesPanel.swift`, `App/AppDelegate.swift` |  | chau7_next/src/panes/changed_files.rs | done | NSPanel |

| DBG-026 | (dev) Memory tab reports per-terminal grid/history/image/render allocations and shared process memory; refresh/export diagnostic snapshot | `Debug/DebugConsoleMemoryTabView.swift`; `Debug/TerminalMemoryReport.swift`; `Debug/TerminalDiagnostics.swift` | TerminalRenderSurfaceReportTests |  | missing |  |
| DBG-027 | (dev) Usage tab exposes quota/latency dashboard and capture status; existing Analytics and CTO tabs retained | `Debug/DebugUsageTabView.swift` | ProviderQuotaEvaluatorTests | chau7_next/src/debug/tabs/analytics.rs; chau7_next/src/debug/tabs/cto.rs | partial |  |

## Notes

- The console lives in `chau7_next/src/debug/` (`mod.rs` documents the
  registration API: `register_panel`, `record_event`, `set_token_optimizer_source`,
  `set_analytics_source`, `set_claude_sessions_source`, `register_health_section`).
  Cmd+Opt+L, the menu, the palette and the settings buttons all dispatch
  `ToggleDebugConsole`. The partial rows wait for data sources of other
  modules: Token Optimizer (DBG-008 to 011), Events (012), Analytics (018 to 020)
  and notification reliability (023). DBG-006: the sliders store
  `highlight_idle_delay_ms` and `highlight_max_interval_ms`, but the danger
  highlighter does not read them yet. DBG-025: Open Diff and Preview File
  dispatch the placeholder actions until the diff viewer and file preview exist.
- DBG-024 in Rust: badge ("...", check or cross with duration), the
  `lastCommandBadge` setting and the hover card (duration, exit code and the
  command text) are all there.
- AGENTS.md says Cmd+Shift+D for the console; the real default is Cmd+Opt+L
  (`FeatureSettings` default keybindings, and a migration that rewrites old
  bindings to it). Cmd+D is split right.
- `ChangedFilesPanel` comment says Cmd+Shift+G, but that key is
  `findPrevious`; `showChangedFiles` has no default binding. Files come from
  `CommandBlockManager.lastChangedFiles(tabID:)`; diff stats from `GitDiffTracker.diffStat`.
- Most tabs read data from modules that are not ported (TokenOptimization,
  Telemetry, Proxy, Analytics, Notifications history, FeatureProfiler). Each
  tab can be ported when its source module exists; the window and the
  State/Events/Logs/Report tabs need only ported modules plus Logging.
- The console window title is "Chau7 Next Debug Console" (Swift: "Chau7 Debug Console").
- Health tab reads `~/Library/Logs/Chau7/`; Chau7 Next must read its own state folder.
