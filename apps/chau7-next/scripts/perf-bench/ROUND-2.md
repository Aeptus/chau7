# Performance loop, round 2

## Baseline and process

Start from `0d63c238530e75724a22d994789a21d9d2f00bbe`, the installed Rust production
revision. This includes the earlier performance work through squash merge
`db18b3b7` (#303), followed by the terminal row-paint and hidden-grid work in
#290. Original branch ancestry alone does not establish whether a fix shipped.
The proxy source now lives under `services/chau7-proxy`.

Use the existing isolated lab and normal fast packaging profile. Freeze the
baseline bundle before editing runtime source. Every fixture has a fresh private
profile, owned app/bridge/proxy PIDs, synthetic terminals and local control
traffic. Builds and tests finish before the final paired captures. The installed
app and its restoration data are outside the experiment.

The discovery run used a private copy of the installed bundle, 12 tabs, five
15-second phases and thread attribution. All workload proofs passed. Compilation
was concurrent, so its CPU/memory values are diagnostic, not a comparison result.
Raw discovery: `/private/tmp/chau7-perf-loop2/discovery/discovery-current.json`.
In the idle phase, transcript monitoring made 73 empty callbacks and repository
persistence made 58. The first proposed change parks only the transcript worker
when no AI run exists; a silent live CLI must retain its 200 ms cadence.

Discovery also exposed missing host-load evidence within phases. The collector
now samples load averages alongside each native process sample and retains them
on rejection. Ten collector/workload/ABI checks pass. Load average describes
shared-host contention; it is not app CPU usage or an automatic acceptance gate.

## Acceptance before claiming an improvement

- Interleaved A/B/B/A, two independent runs per binary, 30 seconds per phase,
  five seconds settling and unchanged printable warm-up/workload generation.
- Retain the existing per-run budgets: idle/recovery app CPU below 1% of one
  logical CPU, interrupt wakeups below 60/s, bridge below 0.1% and 1 wakeup/s,
  proxy below 0.1% and 5 wakeups/s; four-tab physical footprint below 192 MiB.
  Active 12.5 Hz output stays below 10% app CPU; MCP/proxy p95 stays below 10 ms.
- Require repeatable lower idle wakeups, without a CPU/footprint regression under
  the existing comparison tolerances. Report memory peaks separately from final
  footprint and RSS. Do not claim a memory reduction if none is established.
- Exercise 1/12-tab scaling and sustained output/recovery. Keep real output byte
  and frame proofs, recent selected-terminal paints and a healthy hang watchdog.
- The real transcript-worker regression must show initial discovery, no idle
  callbacks, immediate restart on run admission, active polling before native
  identity is known, late identity binding, appended transcript ingestion, last
  exit cleanup/reparking, coalesced lifecycle signals and cancellation.

## Status

Baseline packaging and runtime acceptance are in progress. No round-2 speedup is
claimed yet. Final measurements and limitations will replace this status.
