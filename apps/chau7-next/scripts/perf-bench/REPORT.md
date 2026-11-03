# macOS performance acceptance — 2026-10-30

## Reproduction and scope

Use the commands in [README.md](README.md). Build both bundles before measuring; run the collector
acceptance tests and interleave A/B/B/A trials. Every run uses a fresh private home, the real
bundled MCP bridge and the app-owned proxy. Only the fixture's own child PIDs are measured and
terminated. The installed production app is outside this experiment; no installation or relaunch is
part of the performance lab.

Host: macOS 27.2, arm64, 10 logical CPUs, 16 GiB RAM. Other development sessions remain active;
native memory-pressure notifications and host load are retained in raw evidence. CPU percentages use
one logical CPU as 100%. Memory below is physical footprint, separate from resident bytes. Wakeups
are native interrupt wakeups; they do not measure total energy or GPU activity.

Both bundles use the normal fast packaging profile: Rust 1.99.0, Go 1.27.3, opt-level 3, 64 codegen
units, no LTO, aarch64-apple-darwin target. Receipts and signed bundles remain under
`/private/tmp/chau7-perf-lab/`.

| Runtime | Source revision | Executable SHA-256 |
| --- | --- | --- |
| Baseline | `6f7ae4a2b54287dfaffe56e7810461028f49deb5` | `a9b554bb5d452612eb10e2374fdaa12cd42ae36adc3abec1caf03e6acb6e3cd6` |
| Candidate | `c2ee5f0a3b44def28e6f90157bb42af80b73dceb` | `b3f3392028317999655a28769f2d624d1c6f29e6f5a94191d3c68195251186ca` |

The baseline receipt marks the checkout dirty because the new harness was still uncommitted; runtime
source was the baseline revision. The candidate receipt is clean. Harness-only follow-ups do not
change the frozen executable bytes.

## Changes and measurement gaps closed

- Stop the Metal display link when no frame is requested; restart it on actual
  invalidation, presentation or animation demand. Keep the existing display-link
  lifetime guard for late native callbacks.
- Avoid the static workspace's once-per-second redraw and invisible cursor
  redraws. Time-bearing panels and provider/task states still refresh.
- Stop repeated hidden-tab activity from redrawing the whole workspace; preserve
  activity timestamps, immediate idle-tab revival and visible age surfaces.
- Park file tailers for their real 250/500 ms poll interval, with explicit
  shutdown wakeups, instead of waking every 50 ms to check cancellation.
- Replace the proxy's permanent 500 ms task-grace ticker with a cancellable
  timer for the earliest pending deadline.
- Validate native collector ABI and CPU units, exclude child CPU, and keep RSS,
  footprint, wakeups and missing private GPU/presentation measurements distinct.
- Warm up with printable output before idle timing. Silent terminals otherwise
  leave the animated startup overlay running. Pass workload controls explicitly
  because startup strips inherited CHAU7 environment variables.
- Keep MCP load within its enabled rate limit. Check every worker's emitted
  frames/bytes, request counts, hang-watchdog state and recent selected-terminal
  paint evidence. Reject incomplete or incompatible trials.
- Drive the external TUI with absolute deadlines and user-initiated QoS, without
  catch-up bursts. App and helper scheduling remain unchanged. Retain rejected
  phases and their synthetic profiles to diagnose missing surfaces or slow load
  generation rather than treating them as performance improvements.
- Exercise real local forwarding/SSE/task/SQLite paths separately from `/stats`.
  Require exact complete response bytes and distinguish first-byte latency from
  deliberately delayed stream completion.
- Keep hidden model/view output and danger scans from invalidating native windows; continue parsing, metadata delivery, tab reveals and hover previews.
- Restrict expensive process argument reads to subscribed terminal trees without changing native child detection or its cadence. Preserve frame timing signals before display-link shutdown clears them.
- Park stable hidden cursor timers and resume them on visibility, hover prewarming or settings changes while preserving suspension deadlines.
- Watch the bundled proxy parent with a native macOS process-exit event; retain portable polling when native event registration is unavailable.

## Four-tab repeated acceptance

A/B/B/A, two independent runs per binary; 30 seconds per phase after five seconds settling, plus
printable output warm-up. All per-run budgets and regression checks pass. Each run proves all
terminal surfaces remain present, every generator emits the required frames and bytes, and the
selected terminal paints recently with a healthy hang watchdog. Values are medians of per-run
measurements, baseline → candidate. CPU is percent of one logical CPU; peaks are sampled.

| Phase / process | CPU % | IRQ wakeups/s | Peak MiB | Final MiB |
| --- | ---: | ---: | ---: | ---: |
| idle / app | 1.814 → 0.581 | 223.7 → 44.6 | 133.6 → 118.3 | 132.0 → 68.1 |
| idle / mcp_bridge | 0.001 → 0.001 | 0.5 → 0.5 | 1.7 → 1.8 | 1.7 → 1.8 |
| idle / proxy | 0.022 → 0.007 | 12.0 → 0.7 | 10.6 → 10.8 | 10.6 → 10.8 |
| terminal / app | 11.212 → 4.981 | 217.0 → 55.7 | 134.0 → 121.3 | 134.0 → 121.2 |
| terminal / mcp_bridge | 0.001 → 0.001 | 0.5 → 0.5 | 1.7 → 1.8 | 1.7 → 1.8 |
| terminal / proxy | 0.023 → 0.005 | 12.9 → 0.4 | 10.6 → 10.9 | 10.6 → 10.9 |
| mcp / app | 2.132 → 0.682 | 223.7 → 45.1 | 134.0 → 121.3 | 134.0 → 68.1 |
| mcp / mcp_bridge | 0.009 → 0.009 | 0.5 → 0.5 | 1.7 → 1.8 | 1.7 → 1.8 |
| mcp / proxy | 0.023 → 0.005 | 13.6 → 1.4 | 10.6 → 10.9 | 10.6 → 10.9 |
| proxy / app | 1.930 → 0.564 | 224.0 → 45.0 | 134.0 → 121.3 | 133.5 → 68.0 |
| proxy / mcp_bridge | 0.001 → 0.001 | 0.5 → 0.5 | 1.7 → 1.8 | 1.7 → 1.8 |
| proxy / proxy | 0.383 → 0.392 | 87.8 → 85.3 | 12.0 → 11.7 | 12.0 → 11.7 |
| recovery / app | 1.863 → 0.489 | 222.7 → 43.3 | 133.6 → 120.4 | 133.6 → 67.3 |
| recovery / mcp_bridge | 0.001 → 0.001 | 0.5 → 0.5 | 1.7 → 1.8 | 1.7 → 1.8 |
| recovery / proxy | 0.020 → 0.003 | 12.2 → 0.8 | 12.1 → 11.7 | 12.1 → 11.7 |

| Request phase | Rate | Baseline p95 ms | Candidate p95 ms | Counts baseline; candidate |
| --- | ---: | ---: | ---: | --- |
| mcp | 2/s | 3.239 | 1.312 | [60, 60]; [60, 60] |
| proxy | 10/s | 1.864 | 1.961 | [282, 284]; [284, 283] |

Candidate app CPU repeat ranges: idle [0.557, 0.605], terminal [5.033, 4.93], recovery [0.473,
0.505].

Raw paired captures: `/private/tmp/chau7-perf-lab/final-native-abba/`.

## Scale and sustained acceptance

The final candidate also ran with one and twelve tabs at 12.5 Hz, sustained four-tab output and
recovery for 120 seconds each, and a separate 60 Hz one-tab stress case. These are single workload
checks, not paired speedup estimates. The 60 Hz case has a different workload and does not use the
12.5 Hz CPU ceiling.

| Workload / phase | Seconds | App CPU % | IRQ wakeups/s | Peak MiB | Final MiB |
| --- | ---: | ---: | ---: | ---: | ---: |
| one-tab / idle | 29.2 | 0.474 | 40.0 | 118.2 | 68.0 |
| one-tab / terminal | 29.2 | 3.703 | 52.8 | 122.7 | 122.7 |
| one-tab / recovery | 29.2 | 0.467 | 40.2 | 122.7 | 69.5 |
| twelve-tabs / idle | 39.2 | 0.622 | 51.3 | 131.3 | 78.1 |
| twelve-tabs / terminal | 39.2 | 7.222 | 55.8 | 134.9 | 134.9 |
| twelve-tabs / recovery | 39.2 | 0.628 | 53.4 | 134.9 | 81.7 |
| sustained-four-tabs / terminal | 119.8 | 4.821 | 57.1 | 124.3 | 124.3 |
| sustained-four-tabs / recovery | 119.7 | 0.523 | 47.6 | 123.6 | 70.4 |
| sixty-hz-one-tab / terminal | 29.2 | 10.586 | 102.4 | 123.0 | 123.0 |
| sixty-hz-one-tab / recovery | 29.2 | 0.481 | 44.6 | 122.3 | 69.2 |

Raw scale/soak captures: `/private/tmp/chau7-perf-lab/native-extended/`.

## Iteration history and rejected evidence

Discovery exposed stripped environment controls, an animated startup overlay, rate-limited MCP load
and missing proof of actual terminal output. The harness now closes those gaps and saves incomplete
captures and private synthetic profiles before rejecting them.

The previous candidate (`375a0fa4`) passed short four-tab A/B/B/A, but failed twelve-tab active CPU
(21.938%) and sustained four-tab active CPU (12.735%). Its twelve-tab profiler recorded 663 grid
paints in ten seconds despite 12.5 Hz visible output. Those results were rejected as final
acceptance. Hidden output notification and danger-scan fixes address that amplification; scoped
process argument reads address idle capture overhead. Earlier successful short results remain under
`final-quiet-abba/`; rejected scale/soak captures remain under `extended-results/`.

The next candidate (`50a53c9e`) reduced twelve-tab active CPU to 7.702% and grid paints to 124 per
ten seconds, but failed initial idle CPU at 1.472%. A longer-settling thread diagnostic also missed
at 1.116%, so memory pressure alone did not explain it. Hidden cursor callbacks remained active (209
per ten seconds); the final iteration parks them on stable hidden views and resumes via visibility,
hover or settings signals. Both rejected captures remain under `surface-extended/` and
`surface-diagnostic/`.

The parked-timer candidate (`f5151022`) then passed twelve-tab app CPU at 0.746% idle, 8.438% active
and 0.838% recovery, with zero hidden cursor callbacks, but bundled-proxy recovery wakeups missed at
5.545/s. The final proxy iteration replaces its two-second parent polling timer with a native macOS
process-exit event and preserves the portable fallback. That rejected run remains under
`parked-extended/`.

## Validation

Native collector, workload controls and comparison rejection tests pass. Focused Rust checks cover
file-tail delivery/rotation/Unicode and shutdown races, workspace clock invalidation, cursor
behavior, and parked-frame reactivation including nested animation callbacks. Strict core Clippy,
proxy race tests, proxy vet and the pinned Go linter pass. Full vendor GPUI library tests are
blocked by pre-existing missing font fixtures and test macro dependencies; app-level GPUI tests and
real bundled-app paint checks provide scoped coverage.

Additional focused checks pass: eleven core process-tree tests, eight app process-monitor tests,
eight workspace GPUI regressions, eleven cursor/view tests and one real hidden-timer test. Strict
core Clippy, staged gates and vendor hash-chain checks pass. Native proxy process-exit,
ownership-loss and invalid-PID tests pass under the full race suite; vet and the pinned Go linter
pass. The hidden-output regression requires zero native frame wakes from background output and
proves fresh grid contents after actual selection, visible output, hover prewarming and hidden OSC
metadata. A real timer regression proves hidden blink callbacks stay parked and resume on reveal.

## Limits

MCP traffic here covers connection setup, tab control, snapshots and sustained runtime-info reads;
it does not cover long-lived event subscriptions or every tool family. Synthetic local traffic does
not establish real model/provider TLS latency. The standalone SSE fixture excludes app-parent
monitoring and IPC delivery; its numbers must stay separate from the app-owned proxy. Private Metal
memory, physical display presentation and machine-wide energy are unavailable. A zero package-wakeup
counter on this busy host is not evidence of zero energy cost.

## Standalone forwarding/SSE acceptance

A/B/B/A, two repeats per test executable, 30 seconds per phase after five seconds settling. Each
active phase completed 60 byte-verified streams through the real forwarding, task and SQLite code.
All candidate runs met CPU, footprint and first-byte latency budgets.

| Phase | CPU % (baseline → candidate) | IRQ wakeups/s | Peak MiB |
| --- | ---: | ---: | ---: |
| idle | 0.0274 → 0.0008 | 9.67 → 0.07 | 10.96 → 10.92 |
| streaming | 0.7041 → 0.6687 | 213.38 → 194.87 | 13.81 → 13.79 |
| recovery | 0.0202 → 0.0003 | 10.30 → 0.07 | 13.81 → 13.79 |

Candidate first-byte p95: 8.764 ms, 5.563 ms. Completion p95 includes the fixture’s deliberate
per-event delay; it is not provider response latency. Streaming CPU and memory remained similar; the
clear reduction is idle timer work. Active wakeup and latency repeat ranges vary on the shared
development host, so these data do not establish a streaming latency improvement.

Frozen test-executable SHA-256:

- baseline: `bca4bf2befb7c1c7e6eee23e010d2fcd879910284249ae7caaf28a6af0090c65`
- candidate: `651544fcdd1f284b4b793ba99525576da5ab3644d2d85fdbe4630f91a5cc5b0c`

The exact opt-in fixture was compiled against baseline runtime source and candidate runtime source.
The fixture and collector sources remained unchanged throughout all four trials. Source hashes
recorded for that frozen implementation:

- `services/chau7-proxy/perf_fixture_test.go`: `fc95b6176c41d0aef551edf3296dd8a99066f89f80feaf19f353c89176c29a82`
- `apps/chau7-next/scripts/perf-bench/proxy_run.py`: `3b621675210689be4a6534441ff51fa15bb3a4f5c72b3fa15d4c8bad76084191`
- `apps/chau7-next/scripts/perf-bench/native.py`: `7548c7cd30793f853f5f9ffc11949968d20c76e83a38fd08af33ebb5e28d55c7`

Raw standalone proxy evidence: `/private/tmp/chau7-perf-lab/proxy-final/`. These measurements
exclude the app-parent watcher and IPC and remain separate from the bundled-proxy table.

The later native parent-watcher change affects `main.go` and platform watcher files. Forwarding,
task and SQLite implementation bytes used by this frozen fixture remain unchanged; the parent
watcher is excluded here and is measured in the final bundled-proxy runs. The native watcher also
passes owned-process exit/ownership tests under the full proxy race suite, vet/lint and a Linux
fallback build.

## Retained evidence

[evidence-2026-10-30.json](evidence-2026-10-30.json) retains numeric native measurements, workload
proofs, host/geometry arguments, collector and executable hashes, paired comparison and standalone
SSE repeats. Sustained app samples retain the memory trajectory. Full snapshots and failed synthetic
profiles remain private under the raw capture paths above. No private transcript/profile contents
are published.
