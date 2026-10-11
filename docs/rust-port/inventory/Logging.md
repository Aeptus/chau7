# Logging

Swift: `apps/chau7-macos/Sources/Chau7/Logging/` (7 files, 2,400 lines)
Swift tests: none
Wave: 5 (see README.md)
Depends on: none for the log itself; bug reports and snapshots need Overlay, AI (Claude sessions and events), Settings, MCP (`TerminalControlService.tabOutput` for terminal history)

The app writes one rolling log file, mirrors category logs to the macOS unified log, and offers tracing helpers for developers. This module also owns user-facing issue reporting: a privacy-first "Report an Issue" dialog that builds a Markdown report from opt-in diagnostics and submits it to an HTTPS endpoint, plus local bug reports and JSON state snapshots. PTY log files written by other modules are listed here because they share the log folder and size policy.

## Features

| ID | Feature | Swift source | Tests | Rust | Status | macOS API |
|---|---|---|---|---|---|---|
| LOG-001 | App log file `~/Library/Logs/Chau7.log`, appended, one line per entry `[Chau7][LEVEL] <ISO 8601 with ms> <message>` | `Logging/Log.swift` |  | chau7_next/src/logging/mod.rs, chau7_next/src/logging/writer.rs, chau7_next_core/src/logging.rs | done |  |
| LOG-002 | Levels INFO, WARN, ERROR, DEBUG always written; TRACE only with `CHAU7_TRACE=1` or `CHAU7_VERBOSE=1` | `Logging/Log.swift` |  | chau7_next/src/logging/mod.rs, chau7_next/src/logging/writer.rs, chau7_next_core/src/logging.rs | done |  |
| LOG-003 | Log lines echoed to stdout when `CHAU7_VERBOSE=1` or stdout is a terminal | `Logging/Log.swift` |  | chau7_next/src/logging/mod.rs, chau7_next/src/logging/writer.rs, chau7_next_core/src/logging.rs | done |  |
| LOG-004 | `CHAU7_LOG_FILE` overrides the log path | `Logging/Log.swift` |  | chau7_next/src/logging/mod.rs, chau7_next/src/logging/writer.rs, chau7_next_core/src/logging.rs | done |  |
| LOG-005 | Log size cap: every 200 writes, if the file is over `CHAU7_LOG_MAX_BYTES` (default 10 MB), retain five complete numbered archives and keep the newest line-aligned half active | `Logging/Log.swift`; `Chau7Core/LogRetentionPolicy.swift` | logging::writer::tests | chau7_next/src/logging/mod.rs, chau7_next/src/logging/writer.rs, chau7_next_core/src/logging.rs | done |  |
| LOG-006 | Writes are async on one queue; if the file handle fails it is reopened lazily | `Logging/Log.swift` |  | chau7_next/src/logging/mod.rs, chau7_next/src/logging/writer.rs, chau7_next_core/src/logging.rs | done |  |
| LOG-007 | Live log feed into the app (last N lines kept in memory) for the debug console | `Logging/Log.swift` (`Log.sink`), `App/AppModel.swift` |  | chau7_next/src/logging/mod.rs, chau7_next/src/logging/writer.rs, chau7_next_core/src/logging.rs | done |  |
| LOG-008 | (dev) Category logging with 12 categories (App, Tabs, Terminal, Render, Input, Notifications, Snippets, Network, Perf, Memory, Recovery, CTO): `<ts> [LEVEL][Category] [corr] message (12.34ms) [mem:123.4MB] {k=v}` plus `@file:line function` on TRACE and ERROR; per-category on/off | `Logging/LogEnhanced.swift` |  | chau7_next/src/logging/mod.rs, chau7_next_core/src/logging.rs | done |  |
| LOG-009 | (dev) Category logs mirrored to the macOS unified log (subsystem `com.chau7`, category lowercased) for Console.app | `Logging/LogEnhanced.swift` |  | chau7_next/src/platform/oslog.rs, chau7_next/src/platform/oslog_shim.c, chau7_next/build.rs | done | os_log |
| LOG-010 | (dev) Optional JSON-lines log output (`LogEntry` encoded) | `Logging/LogEnhanced.swift` |  | chau7_next/src/logging/mod.rs, chau7_next_core/src/logging.rs | done |  |
| LOG-011 | (dev) Correlation ids: scoped operations log Begin/End with a short id | `Logging/LogEnhanced.swift` (`LogCorrelation`) |  | chau7_next/src/logging/perf.rs, chau7_next_core/src/logging.rs | done |  |
| LOG-012 | (dev) Performance tracker: logs an operation's duration and memory change, WARN above 100 ms, TRACE otherwise | `Logging/LogEnhanced.swift` (`PerfTracker`) |  | chau7_next/src/logging/perf.rs | done | mach task_info |
| LOG-013 | (dev) Memory pressure monitor logs warning/critical with a small state snapshot | `Logging/LogEnhanced.swift` (`MemoryPressureMonitor`) | | | n/a | DispatchSource memory pressure |
| LOG-014 | (dev) Debug contexts: `[ID] START op`, events, `END op SUCCESS/FAILURE (N ms)` trace lines, child contexts, active and last 100 completed kept for reports | `Logging/DebugContext.swift` |  | chau7_next_core/src/debug_context.rs, chau7_next/src/debug/snapshot.rs | done |  |
| LOG-015 | (dev) Debug assertions: assert in debug builds, log "Check failed at file:line" in release | `Logging/DebugContext.swift` (`DebugAssert`) | | | n/a | |
| LOG-016 | State snapshot JSON: app and OS version, tabs (title, custom title, app, status, cwd, git), Claude sessions, last 20 events, feature flags, last 50 log lines, active debug contexts; saved to `~/.chau7/snapshots/chau7-snapshot-<yyyy-MM-dd_HH-mm-ss>.json` | `Logging/DebugContext.swift` (`StateSnapshot`) |  | chau7_next_core/src/bug_report.rs, chau7_next/src/debug/snapshot.rs | done |  |
| LOG-017 | Local bug report: Markdown with description, environment, every tab, Claude sessions, events, contexts, flags, last 50 log lines; saved to `~/.chau7/reports/chau7-bug-report-<ts>.md` along with a snapshot | `Logging/DebugContext.swift` (`BugReporter`) |  | chau7_next_core/src/bug_report.rs, chau7_next/src/debug/snapshot.rs | done |  |
| LOG-018 | Prefilled GitHub issue: opens `github.com/anthropics/chau7/issues/new` with title and body; used by the debug console and as fallback when the dialog cannot open | `Logging/DebugContext.swift`, `Logging/BugReportWindowController.swift` |  | chau7_next_core/src/bug_report.rs, chau7_next/src/debug/snapshot.rs, chau7_next/src/debug/tabs/report.rs | done | NSWorkspace |
| LOG-019 | Open the reports folder in Finder | `Logging/DebugContext.swift` |  | chau7_next/src/debug/tabs/report.rs | done | NSWorkspace |
| LOG-020 | "Report an Issue" window (menu item "Report Issue", `AppDelegate.reportIssue`): fresh snapshot each time, description box, live Markdown preview with Copy | `Logging/BugReportWindowController.swift`, `Logging/BugReportDialogView.swift`, `Logging/BugReportDraft.swift` |  | chau7_next/src/debug/report_window.rs, chau7_next_core/src/bug_report.rs | done |  |
| LOG-021 | Privacy-first diagnostics toggles: feature settings (on), application logs, recent events, tab metadata (with tab picker), terminal history (last 50 lines, with tab picker), AI session info for the chosen tab (all off); inline warnings; home paths shown as `~` | `Logging/BugReportDialogView.swift`, `Logging/BugReportDraft.swift` |  | chau7_next/src/debug/report_window.rs, chau7_next_core/src/bug_report.rs | done |  |
| LOG-022 | Optional contact name and GitHub/email, "Remember for future reports" saves them to settings | `Logging/BugReportDraft.swift` |  | chau7_next/src/debug/report_window.rs, chau7_next/src/settings/general.rs | done |  |
| LOG-023 | Submit: POST to the configured HTTPS endpoint, shows "Issue #N submitted" and closes after 1.5 s; errors for missing or non-HTTPS endpoint, rate limit (429), server and network errors | `Logging/BugReportDraft.swift`, `Logging/BugReportDialogView.swift` |  | chau7_next/src/debug/report_window.rs, chau7_next_core/src/bug_report.rs | done |  |
| LOG-024 | Save Locally from the dialog, then an alert with Show in Finder | `Logging/BugReportDialogView.swift`, `Logging/BugReportDraft.swift` |  | chau7_next/src/debug/report_window.rs | done | NSWorkspace |
| LOG-025 | "Who sees what" privacy sheet: data always sent vs opt-in, sub-processors (Cloudflare relay, GitHub storage) with role, location, data, retention and policy links, user rights, legal basis | `Logging/IssueReportingPrivacyView.swift` |  | chau7_next/src/debug/report_window.rs, chau7_next_core/src/issue_privacy.rs | done |  |
| LOG-026 | AI PTY logs: while an AI CLI runs, its terminal output and sanitized `[INPUT]` lines go to `~/Library/Logs/Chau7/<tool>-pty.log` (path overridable per tool); trimmed to the newest half above `CHAU7_PTY_LOG_MAX_BYTES` (default 10 MB) | `AI/AITerminalLogSession.swift`, `Terminal/Session/TerminalSessionModel+ShellIntegration.swift` |  | chau7_next/src/ai/session_log.rs, chau7_next_core/src/ai/pty_log.rs, chau7_next/src/terminal/session.rs | done |  |
| LOG-027 | On launch, `*-pty.log` files over 10 MB are cut to their last 5 MB | `App/AppDelegate.swift` (`purgeLargePTYLogs`) |  | chau7_next/src/logging/ai_pty.rs, chau7_next/src/main.rs | done |  |
| LOG-028 | (dev) Raw PTY dump with `CHAU7_PTY_DUMP=1` or `CHAU7_TRACE_PTY=true` to `~/Library/Logs/Chau7/pty-capture.log` (or `CHAU7_PTY_DUMP_PATH`), escaped bytes, trimmed to half above `CHAU7_PTY_DUMP_MAX_BYTES` (default 20 MB) | `Terminal/Rendering/TerminalOutputCapture.swift` |  | chau7_next/src/terminal/pty_capture.rs | done |  |

| LOG-029 | Bounded incident breadcrumbs record main-thread hang/recovery, memory pressure, proxy request high-water and restore payload; previous critical memory incident is surfaced once at launch | `Logging/IncidentBreadcrumbStore.swift`; `Performance/MainThreadHangRecoveryController.swift`; `Performance/MemoryPressureResponder.swift`; `App/AppDelegate+MultiWindow.swift` | IncidentBreadcrumbStoreTests; seven bounded store/admission/relaunch tests; local-report privacy and old snapshot compatibility; persistence boundary mutation regression | chau7_next_core/src/incidents.rs; chau7_next/src/incidents.rs; chau7_next/src/hang_watchdog.rs; chau7_next/src/memory_pressure.rs; chau7_next/src/proxy/process.rs; chau7_next/src/debug/snapshot.rs | done | Store and real producers use off-UI persistence and strict 256 KiB/200-entry limits, rechecked at the persistence boundary. Successful restore transactions report actual manifest/index/unique-context bytes and numeric window/tab/pane and largest payload measurements. Current Swift writes incidents but does not feed recentBreadcrumbs into its report/snapshot; Next additionally exposes local snapshot/report evidence and read-only performance diagnostics. Public draft defaults exclude it. |

| LOG-030 | Log/report retention caps count,total bytes,individual file bytes and age, tracks failures without unbounded repeat logging; directory watch retry survives rotation | `Chau7Core/FileRetentionBudget.swift`; `Chau7Core/LogRetentionPolicy.swift`; `Monitoring/LogFileCompactor.swift`; `Chau7Core/FileObservationRetryPolicy.swift` | logging::writer::tests; monitoring::log_compactor::tests; monitoring::file_monitor::tests; hang_watchdog::tests; session_store::tests | chau7_next/src/logging/writer.rs; chau7_next/src/monitoring/{file_monitor,watch_registry,log_compactor}.rs; chau7_next/src/hang_watchdog.rs; chau7_next/src/session_store.rs | done | Actual logger, startup, native watcher, hang bundle and restore archive consumers. |

## Notes

- Rust (`chau7_next/src/logging/`, `chau7_next_core/src/logging.rs`): a
  `log::Log` writer appends `[Chau7][LEVEL] <ISO ms> message` to
  `DataRoot::log_file()` (`CHAU7_NEXT_LOG_FILE` overrides it), on its own
  thread, reopening lazily and after external inode replacement. Every 200
  writes past `CHAU7_NEXT_LOG_MAX_BYTES`, five complete numbered archives
  are retained and the active file keeps its newest line-aligned half.
  Categories are log targets
  `chau7::cat::<Name>` written with `log_cat!`. The last 2000 lines are kept in
  memory for the console. LOG-009: the os_log call (`platform/oslog.rs`
  plus a C shim built by `build.rs`) compiles and runs only on macOS (the
  macOS CI job runs `logging_never_panics` through it); check the lines in
  Console.app (subsystem `com.chau7.next`) by hand.
- Swift line formats to match if tools grep them (the debug console filters
  on `[LEVEL]` and `[Category]` substrings, or `"level":"X"` / `"category":"X"` in JSON):
  - `Log`: `[Chau7][INFO] 2026-01-15T10:30:45.123Z message`
  - `LogEnhanced`: `2026-01-15T10:30:45.123Z [WARN][Tabs] [a1b2c3d4] message (12.34ms) [mem:123.4MB] {k=v} @File.swift:42 func()`
  - PTY dump: `2026-01-15T10:30:45Z | PTY | read | bytes=128 | \x1b[31mHello\x1b[0m\n`
    (ESC as `\x1b`, `\n`, `\r`, `\t`, printable ASCII as is, other bytes `\xHH`).
- Env vars (Swift): `CHAU7_LOG_FILE`, `CHAU7_LOG_MAX_BYTES`, `CHAU7_VERBOSE`,
  `CHAU7_TRACE` (plus legacy names in `Utilities/Utilities.swift` `EnvVars`),
  `CHAU7_PTY_LOG_MAX_BYTES`, `CHAU7_PTY_DUMP`, `CHAU7_TRACE_PTY`,
  `CHAU7_PTY_DUMP_PATH`, `CHAU7_PTY_DUMP_MAX_BYTES`. Chau7 Next uses the
  `CHAU7_NEXT_` prefix; keep that so a shell started inside one app does not
  configure the other.
- Paths: everything under `~/Library/Logs/Chau7*` and `~/.chau7/{reports,snapshots}`
  belongs to the Swift app. Chau7 Next must add `DataRoot` paths for logs dir,
  PTY logs, reports and snapshots (the coexistence test rejects `.chau7/`
  outside `data_root.rs`). `tab_output source=pty_log` (MCP-025) reads these PTY logs.
- Bug report submit wire format: `POST <bugReport.issueEndpoint>`,
  `Content-Type: application/json`, body `{"title":"Bug report from Chau7 <version>","body":"<markdown>"}`,
  15 s timeout; 200 or 201 is success, response `{"issue_number": N}` (missing
  means success with no number); 429 is rate limited. Endpoint must be `https`.
  `bugReport.issueEndpoint` defaults to empty, so Submit fails with "Issue
  reporting endpoint is not configured." unless set.
- LOG-030: bounded suffix reads use the observed length, drop incomplete leading records (including a suffix with no newline) and cannot grow with concurrent appends. Unique atomic replacements preserve permissions, refuse direct symlinks and leave unrelated temporary files intact; failed archive publication restores the original when possible. Writer failures emit one initial diagnostic and at most one numeric suppression summary per minute. Owned helper queues compact only during quiescent startup at 16 MiB/8 MiB; shared Swift/provider files are untouched. FileMonitor uses the native shared registry and parent fallback, with 0.2-to-5-second retries limited to 60 seconds, then event-only recovery and stop/generation fencing. Hang reports retain at most 40 recognized bundles, 64 MiB total, 8 MiB plus 64 KiB per bundle and 7 days; equal modification times sort by descending key, preserving latest/unrelated files. Restore archives retain at most 120, 128 MiB total, 16 MiB per effective manifest/context bundle and 30 days, protecting latest/current contexts. These are actual consumers rather than unused generic retention helpers. Coordinator source 12be3f77 includes hang tie regression bdf64232 and restore transaction dbb6218e; writer/compactor 7ec05264 and watch recovery e6bd7ff1 passed thirteen logging, three compactor and twelve real-native/isolated-failure watch tests plus full 377 app/2,250 core suites and strict workspace Clippy/fmt. Native window/provider and Windows acceptance remain separate.
- Settings keys: `bugReport.contactName`, `bugReport.contactHandle`, `bugReport.issueEndpoint`.
- Dialog Markdown sections, in order: `# Chau7 Bug Report` + Generated,
  `## Contact` (if any), `## Description`, `## Environment` (version, macOS,
  tab count), then opt-in `## Feature Flags`, `## Tab: <title>`,
  `## Terminal History`, `## AI Sessions` (only sessions whose project matches
  the tab's cwd), `## Recent Events (last N)`, `## Recent Logs (last N lines)`.
  Paths under the home folder are rewritten to `~`.
- The GitHub fallback URL owner/repo is hardcoded `anthropics/chau7`; confirm
  the right repo before porting.
- LOG-013 is `n/a`: `MemoryPressureMonitor.start()` is never called in the
  Swift app. LOG-015 is `n/a`: Rust has `debug_assert!` and `log::error!`.
- LOG-010 (JSON output) is never switched on in the Swift app, and
  `LogEnhanced.setEnabledCategories` has no caller; both are developer hooks.
- The dialog window title in Swift uses an en/em dash; write "Report an Issue"
  plus the app name without it.
