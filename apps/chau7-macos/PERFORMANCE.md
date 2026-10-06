# Responsiveness release checks

Run `swift test` and `swift build` from this directory. The existing macOS CI
suite includes `ResponsivenessRegressionTests`; no additional GitHub Actions
runner is required. The tests enforce remote-grid encoding p95 < 50 ms and
p99 < 100 ms for 19 switched 160×50 viewports, main-queue input probes < 100 ms
while 240×100 frames encode in the background, off-main encoding, unchanged
frame suppression, Unicode preservation, and a 4 MiB retained viewport cache.
Routine memory maintenance also caps estimated cold search/scrollback caches
across all tabs at 64 MiB, in addition to the existing 16 MiB per-tab limit.
Selected panes stay hot; their working set may exceed the global target.
The backend's authoritative terminal content and restoration state stay intact.
`terminal_cache_budget` telemetry records estimated ownership and evictions;
`remote_grid_cache` records retained viewport bytes only when they change.

These are component regression checks, not measurements of end-to-end typing.

For release validation, use a separately launched candidate build with 19 tabs
across two windows. Preserve all sessions in the installed app. Record an
Instruments Hangs/Time Profiler trace plus the structured performance log for:

1. A 60-second idle interval: no unnecessary terminal redraws; compare idle CPU
   to the same-machine baseline (~1% in the original investigation).
2. Sustained TUI output while typing/clicking and switching between both windows.
3. Large paste, window resize, scrollback navigation and Home/End input.
4. Foreground remote grid viewing, tab switching and disconnect/reconnect.
5. Return to idle and check that allocation growth stabilizes.

End-to-end targets are input-to-paint p95 < 50 ms and p99 < 100 ms. Investigate
all main-thread stalls >= 250 ms; a candidate should have none in this workload.
Do not claim these targets are met from the component tests alone. Record the
build SHA, OS, hardware, terminal size, workload duration, sample count and
baseline alongside the result. Profile retained allocation owners before
claiming a leak or setting a total-process memory budget.

Use `HistoryAdoption` and `RoutingRebuild` signposts to attribute model work.
History adoption logs include changed field names, without command contents.
`terminal_work` telemetry separates `remoteGridSnapshot` backend reads from
`remoteGridEncode` background assembly. New backends return dirty rows; older
libraries retain the full-grid fallback and report `remoteGridSnapshotLegacy`.
A disconnected or switched client cannot receive an old asynchronous frame.

The heartbeat paint circuit opens at 2 seconds. The watchdog now starts sample
capture at the same threshold, instead of 4 seconds; sampling is limited to one
capture per stall and a 60-second cooldown across replacement watchdogs. This
improves attribution of short freezes without changing PTY/session ownership.
