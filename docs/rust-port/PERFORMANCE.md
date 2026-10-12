# Chau7 Next performance diagnostics

## Access

- Open the Debug Console, then **Perf** for feature totals and export controls.
- **Lag** shows input, output and dangerous-command highlight latency.
- **Copy Performance JSON** captures all windows and terminal panes.
- **Save Latest Snapshot** queues the same snapshot to the background writer.
- **Open Performance Folder** opens Next's own reports directory.
- Through the Next MCP bridge, call `chau7_performance_snapshot` with `{}`.
  Call `chau7_runtime_info` for the running binary's version, revision and PID.
  The Swift `chau7` MCP connection addresses the Swift app; use the separate
  `chau7-next` entry to inspect Next.

Automatic persistence starts at launch and samples every five seconds:

```text
~/.chau7-next/reports/performance/latest.json
~/.chau7-next/reports/performance/history.jsonl
~/.chau7-next/reports/performance/history.1.jsonl
```

Paths come from `DataRoot`; Linux, Windows and isolated test roots use their
own application data locations. Disk work runs on one background worker with
one pending snapshot. A busy disk drops a queued sample rather than creating
an unbounded backlog. Each snapshot is capped at 1 MiB; the two history files
are capped at 8 MiB each. The latest file is replaced after serialization.
On Windows replacement removes the previous latest file before renaming.
History lines use `schema_version`, `timestamp`, `category` and `metrics`;
`latest.json` retains the full snapshot shape used by MCP and the UI.
Accepted records drain on the background quit worker. Repeated write failures
produce one operational warning until a successful write resets it.

## Measurements and limits

JSON schema version 1 contains:

- App identity and capture timestamp. An unpackaged development executable
  has null bundle metadata rather than claiming an unknown revision is real.
- App process resident memory in **bytes**, accumulated CPU time in **seconds**,
  and sampled CPU percentage. One logical CPU is 100 percent; multiple busy
  threads can exceed 100. Children and helper processes are excluded.
  The first CPU sample and unsupported platforms return null.
- Main-thread timer delay in **milliseconds**, sampled every five seconds,
  including the maximum observed delay. This detects a late scheduler callback;
  it does not measure every frame or replace a native stack profiler.
- Every terminal pane's input/output/highlight last value, average, p50, p95,
  maximum and sample count, in **milliseconds**. These are the existing rolling
  sample buffers (up to 120 samples), not estimates from rendered text.
  Output measurements expire when a hidden tab has no closing frame.
- Up to 16 recent lag events per pane. Lag event time is monotonic seconds,
  distinct from the capture timestamp and profiler Unix timestamps.
- Feature counts, total/average/maximum duration, and processed bytes over
  the last 10 and 60 seconds, plus up to 80 recent numeric feature events.
  Timers cover actual refresh processing, shell semantic processing,
  monitoring, remote output, terminal painting and dangerous-command scans.
  The monitoring feature includes AI and dev-server monitoring. Empty feature
  arrays mean no instrumented work in that window; missing work is not zero.
- On macOS, measured feature scopes also emit paired `os_signpost` intervals
  under subsystem `com.chau7.next`, category `performance`, for Instruments.
  Begin/end IDs match even when a scope exits early. Emission skips disabled
  signpost logs, and no terminal content enters interval names. Plain recorded
  elapsed values remain numeric aggregates; they are not fabricated intervals.
  Linux and Windows explicitly report native signposts as unsupported.

Snapshots include up to 128 panes and report `terminal_count` and
`terminals_truncated` explicitly. They exclude terminal output, command text,
repository paths, environment variables and caller-supplied profiler metadata.
The existing full bug report remains a separate diagnostic with different data.

## Work stages, callbacks and timer inventory

`work_profile` records actual instrumented work, wakeups and latency with static
operation, phase, visibility, caller and main/background queue labels. Entries
have lifetime, last-10-second and last-60-second aggregates. The profiler retains
at most 256 keys and 120 one-second buckets per key; dropped keys are reported.
Empty rolling aggregates are null. Durations are wall time in milliseconds,
including readiness waits where explicitly named. They are not per-stage CPU
time or completed GPU execution time. Missing CPU/GPU measurements stay null.

`idle_samples` counts callbacks explicitly observed to be idle.
`activity_unknown_samples` counts callbacks whose activity was not observed;
`activity_classified_samples` counts the remainder. Subtracting idle from all
samples would incorrectly label unknown samples active. Callbacks for app
actions, the hang-watchdog heartbeat, readiness and Codex feedback, repository
persistence and transcript-rate polling measure actual callback or worker work,
excluding the preceding executor timer wait. Capture, worker and apply phases
retain their actual queue labels. This covers instrumented producers; it does
not claim complete attribution for every runtime or third-party callback.

Call `chau7_timer_inventory` separately for registered timer lifetimes. Its
bounded inventory retains active registrations and recent inactive lifetimes;
prior deactivations remain in the event journal. A timer registration establishes
lifecycle and queue information, not a measured callback cost. The durable
runtime journal is also separate: runtime diagnostics report latest/processed
sequence, retained memory events, availability and persistence errors. A captured
latest sequence is durable only when processed sequence has caught up without
an error. Performance history and journal persistence are distinct writers.

The heartbeat's first unsampled delay and maximum are null. Actual renderer
selection and retained terminal/cache memory appear in per-pane diagnostics;
they do not establish unavailable-Metal fallback or identify GPU memory usage
that the platform has not measured.

## Observations from the running test package, 2026-10-11

Read-only inspection of the user's f5da7da5 CI package found three live tabs,
two with repository metadata, and no Next config file. This confirms default
settings and the grouping path bug; it does not warrant changing live tabs.

Anchored warning/error inspection found highlight/output spikes of 742/690 ms
and a macOS notification permission rejection. A process sample showed about
71 MiB resident memory. These are individual observations, not a benchmark.
The log includes PTY byte previews and AI history entries, so diagnostics must
avoid copying arbitrary log lines into public output.

This old running package exposes the earlier 30 MCP tools. The new diagnostics
require a newly built package; source integration alone cannot update a running
process. Preserve active Next and Swift sessions during installation/testing.

## Main-thread hang diagnostics

A separate monitor checks a main-thread progress token every 250 ms. A confirmed
stall lasting two seconds opens the terminal paint circuit breaker. PTY parsing,
input processing and persistence remain active; progress closes the breaker.
The live performance JSON includes `hang_watchdog` status, transition counts,
heartbeat interval and the diagnostics directory. MCP timeout snapshots expose
whether the breaker is open without waiting for the main thread.

On macOS a same-binary helper starts only during a confirmed stall. It captures
`/usr/bin/sample` for five seconds, with a ten-second helper deadline and an
8 MiB sample limit. It records heartbeat tokens before and after capture and
main-thread stack families as evidence, without asserting a deadlock or a cause.
Sampling has a 60-second cooldown scoped to the app launch. The child retires
once progress has stayed healthy for two seconds. Shutdown stops the monitor,
cancels an active diagnostic sample and reaps its child on the quit worker.
Linux and Windows retain token monitoring and the circuit breaker; the JSON
explicitly reports that the macOS external sampling helper is unavailable.

Files live in Next's own `reports/hangs/` directory:

- `main-thread-heartbeat.json` while the monitor runs.
- `latest-transition.json` with the last stall or recovery breadcrumb.
- `latest-hang.json` and paired `hang-*.json` / `hang-*.sample.txt` captures.

Recognized sample bundles are bounded to 40 bundles, 64 MiB total and seven days.
Unrelated files are retained. The helper is intercepted before app initialization,
so it never imports settings, installs integrations or starts a second GUI.

## Owned normal app observation, 2026-10-12

The ordinary feature-free 66753ed1 app exposes runtime identity, performance,
timer inventory and journal via read-only MCP. A fresh synthetic profile restores
two tabs, starts one selected PTY and settles with zero loading timers. Two
post-startup snapshots 37.61s apart measure 2.912% of one logical CPU;
resident memory is 113,475,584 bytes at the later capture. Sixteen active timers,
32 work-profile entries and journal19/19 have no reported persistence error or
hang. Per-stage CPU/GPU completion stay null. Schema1 performance latest/history
files parse, and normal quit drains workers and saves both tabs.

This is a scoped observation: provider services are disabled and compilation runs
concurrently. Main-thread scheduler delay reaches127.267ms across16 samples.
Native dee8163a additionally proves the actual80ms loading task cancels hidden,
has zero hidden callbacks, resumes once and stops at real prompt/disposal.
Its callback wall-time excludes interval waiting. Exact evidence and limits:
[recovery validation](RECOVERY-VALIDATION-20261011.md).
