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

- Start with one tab at 3 Hz output, 0.5 Hz MCP and 1 Hz proxy control. Use
  interleaved A/B/B/A, two independent runs per binary, 30 seconds per phase
  and ten seconds settling. Preserve identical workload and harness hashes.
- Retain the existing per-run budgets: idle/recovery app CPU below 1% of one
  logical CPU, interrupt wakeups below 60/s, bridge below 0.1% and 1 wakeup/s,
  proxy below 0.1% and 5 wakeups/s; four-tab physical footprint below 192 MiB.
  Active 12.5 Hz output stays below 10% app CPU; MCP/proxy p95 stays below 10 ms.
- Require repeatable lower idle wakeups, without a CPU/footprint regression under
  the existing comparison tolerances. Report memory peaks separately from final
  footprint and RSS. Do not claim a memory reduction if none is established.
- Exercise larger tab counts and sustained output/recovery only after the
  small comparison passes and host capacity permits. Keep real output byte
  and frame proofs, recent selected-terminal paints and a healthy hang watchdog.
- The real transcript-worker regression must show initial discovery, no idle
  callbacks, immediate restart on run admission, active polling before native
  identity is known, late identity binding, appended transcript ingestion, last
  exit cleanup/reparking, coalesced lifecycle signals and cancellation.

## Live AI workload

Supplement the deterministic paired trials with five serial `gpt-6-luna`
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
results, tab/run identities and native app/bridge/proxy samples. Verify each completed turn and close its owned fixture before admitting the
next; never infer task completion from a running CLI or an echoed prompt. Separate
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

The candidate's 29 telemetry tests and strict app/test Clippy passed. The
signed candidate is clean source `b13d3b26b550e006568e86d52bafcc2be5ba100d`,
app SHA-256 `877a8d3dc75374eef3b72fd661a3a08ce1c61437605ff2ec30f0d39756a48150`.
The ten-second candidate idle check had zero transcript callbacks, compared
with roughly five callbacks/s in the baseline. This proves worker parking,
not a whole-app CPU, wakeup or memory gain; paired measurements remain required.

After the user reported saturation, the protocol switched to serial admissions
and the resource limits documented in README. Eight safety/profile regression tests pass alongside the ten existing collector
checks. On October 31 the first gentle
one-tab baseline stopped before timing idle: swap grew 347.81 MiB within 30
seconds. The last owned app/helper interval used 1.74% of one CPU, 43.91 interrupt
wakeups/s and 83.91 MiB total physical footprint. Every owned PID exited after
the safety stop. Retain the rejected capture at
`/private/tmp/chau7-perf-loop2/gentle-abba/gentle-baseline-1.json`; it is not a
valid baseline. No round-2 native performance gain is claimed. Do not launch
live agents or larger workloads while host pressure is unstable.

Two abandoned temporary HTTP servers (deleted serving directories, no clients
or children) were stopped with TERM and verified exited. Production Chau7,
active agents and configured user services were preserved.


After cleanup, a separate 90.31-second passive observation (no owned test app,
bridge or proxy running) recorded another 1906.56 MiB of swap growth. No second
trial or live agent was admitted. The admission window was extended to 60 seconds
and cleanup now still terminates the owned app if closing its bridge raises.
See `round-2-safety-stop.json` for bounded numerical evidence. No compilation or
production relaunch was performed during this restart.


The earlier Linux run failed only `data_root::tests::no_swift_app_paths_outside_data_root`
because `live_agents.py` duplicated the isolated channel paths. Both drivers now
reuse the existing configuration writer in `run.py`; the Rust rule is unchanged.
An added test verifies both config files remain beneath the owned home. A static
reproduction of the current rule passes. Native Linux CI must still confirm the
new head. A cached macOS core executable was excluded: its compiled manifest
points at an older, different worktree, so it cannot validate this source.
