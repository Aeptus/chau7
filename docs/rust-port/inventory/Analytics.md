# Analytics

Swift: `apps/chau7-macos/Sources/Chau7/Analytics/` (3 files, 452 lines)
Swift tests: `Analytics/TerminalAnalyticsTests` (app target only, and stale: it tests a `DailyStat` type that no longer exists, so it does not compile into any current target)
Wave: 3
Depends on: History (`PersistentHistoryStore`, `SessionRecorder`), Chau7Core (`CommandBlock`, `FrequentCommand`)

Command-usage dashboard (total commands, success rate, average duration, most used commands) and a timeline scrubber for replaying a recorded terminal session. Neither view is opened from anywhere in the current app: no window, menu, settings page or status bar item creates `AnalyticsDashboardView` or `TimelineScrubberView`. The AI and API usage numbers users actually see live in the Debug console and come from Telemetry and Proxy (see TEL-013, TEL-014, PRX-020).

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

## Notes

**Not reachable in the Swift app.** Before porting, ask the user whether these rows should be ported (and where they would be opened from) or marked `dropped`. The module README claims the dashboard shows AI API usage and is used by Settings and StatusBar; the code does neither.

**Data sources.** `PersistentHistoryStore.shared.totalCount()`, `.recent(limit: 1000)` (fields `exitCode`, `duration`), `.frequentCommands(limit: 10)`. Chau7 Next already records command history (PARITY.md, History: partial), so ANL-001 and ANL-002 are a query plus a view once History has exit codes and durations.

**Timeline inputs.** The scrubber is a pure view: it takes a `SessionRecorder`, an array of `CommandBlock` (`startTime`, `duration`, `exitCode`, `isRunning`, `isSuccess`, `command`), session start and end, and bindings for scrub position (0 to 1), playing state and speed, and calls `onScrub(Date)`. Actual replay lives in the History module's `SessionRecorder`. Total duration is at least 1 s; block width is at least 0.5% of the track (4 px minimum on the main track, 2 px in the mini-map).

**Localization keys** used: `analytics.commands`, `analytics.successRate`, `analytics.avgDuration`, `timeline.*` (speed, status, exit code, play/pause labels).
