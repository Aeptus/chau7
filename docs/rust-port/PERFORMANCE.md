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
~/Library/Application Support/Chau7 Next/reports/performance/latest.json
~/Library/Application Support/Chau7 Next/reports/performance/history.jsonl
~/Library/Application Support/Chau7 Next/reports/performance/history.1.jsonl
```

Paths come from `DataRoot`; Linux, Windows and isolated test roots use their
own application data locations. Disk work runs on one background worker with
one pending snapshot. A busy disk drops a queued sample rather than creating
an unbounded backlog. Each snapshot is capped at 1 MiB; the two history files
are capped at 4 MiB each. The latest file is replaced after serialization.
On Windows replacement removes the previous latest file before renaming.
Persistence failures appear in the application log.

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

Snapshots include up to 128 panes and report `terminal_count` and
`terminals_truncated` explicitly. They exclude terminal output, command text,
repository paths, environment variables and caller-supplied profiler metadata.
The existing full bug report remains a separate diagnostic with different data.

The added export does not yet establish parity for Swift's complete durable
runtime event spine, timer registry or all component health fields. Those
features remain separate rows in the current-source inventory.

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
