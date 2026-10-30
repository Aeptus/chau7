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

## Live AI workload

Supplement the deterministic paired trials with five concurrent `gpt-6-luna`
providers using `model_reasoning_effort="max"`. Cover six repositories: Aethyme,
Chau7, Aetower, Mockup, product-design and website-and-content; one provider
handles two repositories sequentially. Freeze the ten newest issues per
repository at task preparation, and assign one issue from each list. Fewer than
ten existing issues is valid. A closed issue stays closed.

The authorized useful work is an evidence-backed enrichment comment: inspect the
issue and existing discussion, identify relevant current source, clarify gaps and
acceptance criteria, and publish at most one non-duplicate findings comment per
repository. No implementation, deployment or issue-state change is part of this
workload. If an assigned repository has no useful issue remaining, the user
also authorizes a replacement cybersecurity-news research/content issue in
`Aeptus/website-and-content`. Follow its `marketing-content-creator` skill and
content engine, deduplicate existing material, cite current original sources
with verified dates, and propose a specific audience, editorial angle and
acceptance criteria. Keep CMS and published content unchanged. Keep existing
repository publication rules and provider approvals.

Use an owned isolated app profile, preserve actual agent launch/submission
results, tab/run identities and native app/bridge/proxy samples. Verify overlap
rather than assuming that five launched CLIs means five active turns. Separate
CLI child CPU from app CPU. Keep this observational live run separate from the
reproducible synthetic comparison: model latency, external tools and issue
contents vary, and repeated publication would create duplicate comments. Retain
comment URLs and failures as task-completion evidence. Do not start compilation
or the final paired baseline/candidate captures while this workload is running.

## Status

The frozen baseline completed all five 30-second phases with valid workload and
render/hang proofs. App idle CPU was 0.742%, interrupt wakeups 43.538/s, terminal
CPU 5.521%, MCP p95 5.409 ms and proxy-control p95 6.742 ms. Final recovery
physical footprint was 74.80 MiB. Host load was sampled throughout; the idle
one-minute load ranged from 37.69 to 47.91 on this busy shared Mac. These are
baseline observations, not new gains. The baseline receipt's dirty flag covers
harness/docs changes only; runtime source remained at the stated revision.

The candidate worker regression and final measurements are pending. No round-2
speedup is claimed yet. Final measurements and limitations will replace this
status.
