# Analytics

Swift: `apps/chau7-macos/Sources/Chau7/Analytics/` (4 Swift files; current API charts plus historical command/timeline sources)
Swift tests: `Analytics/TerminalAnalyticsTests` (app target only, and stale: it tests a `DailyStat` type that no longer exists, so it does not compile into any current target)
Wave: 3
Depends on: History (`PersistentHistoryStore`, `SessionRecorder`), Chau7Core (`CommandBlock`, `FrequentCommand`)

ANL-001 through ANL-007 retain the historical command-usage dashboard and timeline inventory. The current Swift `AnalyticsDashboardView` instead implements API Analytics, covered by ANL-008. No current Swift constructor call site opens that view or `TimelineScrubberView`. Next retains View > Terminal Analytics and exposes the API chart window from Proxy settings and Debug > Analytics. The separate Debug usage views come from Telemetry and Proxy (see TEL-013, TEL-014, PRX-020).

## Features

| ID | Feature | Swift source | Tests | Rust | Status | macOS API |
|---|---|---|---|---|---|---|
| ANL-001 | Dashboard summary cards: total commands in history, success rate (share of exit code 0 among the last 1000 records that have an exit code), average duration of those records. Never opened in Swift; Chau7 Next opens it from View > Terminal Analytics | `Analytics/TerminalAnalytics.swift`, `Analytics/AnalyticsDashboardView.swift` |  | chau7_next_core/src/terminal_analytics.rs, chau7_next/src/analytics.rs | done |  |
| ANL-002 | Dashboard "Most Used Commands": top 10 commands from history with count and a bar scaled to the most frequent one | `Analytics/TerminalAnalytics.swift`, `Analytics/AnalyticsDashboardView.swift` |  | chau7_next_core/src/terminal_analytics.rs, chau7_next/src/analytics.rs | done |  |
| ANL-003 | Timeline scrubber track: command blocks as colored segments (blue running, green success, red failure) placed by start time and duration over the session span; drag anywhere to scrub, with elapsed time `m:ss` shown | `Analytics/TimelineScrubberView.swift` |  | chau7_next/src/workspace/timeline.rs, chau7_next_core/src/session_recorder.rs | done |  |
| ANL-004 | Timeline mini-map above the track: activity density heatmap (4 px buckets), block overview and a viewport frame following the scrub position | `Analytics/TimelineScrubberView.swift` |  | chau7_next/src/workspace/timeline.rs | done |  |
| ANL-005 | Timeline replay controls: play/pause toggle, speed menu 0.5x / 1x / 2x / 4x, pulsing red dot while the session recorder is recording | `Analytics/TimelineScrubberView.swift` |  | chau7_next/src/workspace/timeline.rs | done |  |
| ANL-006 | Hovering a block shows a tooltip with the command, its duration and "exit N" (green for 0, red otherwise) | `Analytics/TimelineScrubberView.swift` |  | chau7_next/src/workspace/timeline.rs | done |  |
| ANL-007 | Timeline accessibility: adjustable element (VoiceOver increment/decrement moves 5%), labels per block ("Command: x, succeeded / failed with exit code N / running"). Chau7 Next: GPUI's AccessKit API; the track is a slider ("Timeline scrubber", value = elapsed time) whose Increment and Decrement actions move 5%, each block a label, the recording dot, play/pause and speed chips are labeled as in Swift; Left and Right arrows also move 5% | `Analytics/TimelineScrubberView.swift` |  | chau7_next/src/workspace/timeline.rs | done |  |

| ANL-008 | API Analytics window: five ranges and regional formats, rolling daily cost/token bars (Today KPIs start at local midnight), provider cost shares, top 15 models, latest 30 calls across all time, request duration/error rate, token categories and recorded cost/pricing coverage; read-only snapshot off the UI thread, bounded dimensions, coalesced 30-second/IPC refresh, local diagnostics JSON | `Analytics/APIAnalyticsCharts.swift`; `Analytics/AnalyticsDashboardView.swift`; `Proxy/ProxyAnalyticsStore.swift` | 8 `proxy::analytics` SQL fixtures, 2 GPUI helper tests; 2186 core + 345 app tests pass; strict workspace/all-target release Clippy | chau7_next_core/src/proxy/analytics.rs; chau7_next/src/proxy/analytics.rs; chau7_next/src/settings_window/proxy.rs; chau7_next/src/debug/tabs/analytics.rs | done | GPUI charts; native API window hand check pending |

## Notes

**Reachability and historical context.** The current Swift API dashboard and timeline have no constructor call sites. The module README still conflates command and API dashboards. Full parity work is authorized; Next preserves the historical command features and additionally opens the current API charts from existing settings/debug UI. ANL-008 source and isolated tests are complete; its native window hand check remains pending.

**Data sources.** `PersistentHistoryStore.shared.totalCount()`, `.recent(limit: 1000)` (fields `exitCode`, `duration`), `.frequentCommands(limit: 10)`. Chau7 Next already records command history (PARITY.md, History: partial), so ANL-001 and ANL-002 are a query plus a view once History has exit codes and durations.

**Timeline inputs.** The scrubber is a pure view: it takes a `SessionRecorder`, an array of `CommandBlock` (`startTime`, `duration`, `exitCode`, `isRunning`, `isSuccess`, `command`), session start and end, and bindings for scrub position (0 to 1), playing state and speed, and calls `onScrub(Date)`. Actual replay lives in the History module's `SessionRecorder`. Total duration is at least 1 s; block width is at least 0.5% of the track (4 px minimum on the main track, 2 px in the mini-map).

**Localization keys** used: `analytics.commands`, `analytics.successRate`, `analytics.avgDuration`, `timeline.*` (speed, status, exit code, play/pause labels).
