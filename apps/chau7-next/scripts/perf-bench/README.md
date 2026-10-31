# Isolated macOS performance lab

Build and measure the actual app, its bundled MCP bridge, and its app-owned Go
proxy. The default `run.py`/`loop.py` harness uses a fresh temporary home, synthetic terminals, private
sockets, free local ports and fresh result filenames. It never accepts the
production PID, installs into Applications, or reads production session data.
It terminates only the child app it started; results survive failed runs.

Latest measured results: [round 3](ROUND-3.md) (four completed idle trials;
full comparison stopped on swap pressure, no native gain established).

## Resource limits

Start with one total tab, terminal output at 3 Hz, MCP at 0.5 Hz and proxy
control at 1 Hz. Run one fixture at a time, with no concurrent compilation,
tests or live agents. `run.py` first observes host pressure for 60 seconds and
checks it every five seconds throughout startup, settling and measurement.
It stops if memory reserve falls below 25%, swap grows over 256 MiB in 30
seconds, or one-minute load exceeds the logical CPU count. Two consecutive
samples above 75% whole-host CPU, 35% of one core for the owned app/helpers,
or 200 owned interrupt wakeups/s also stop the run. Owned physical footprint
above 384 MiB stops immediately. These are safety limits, not acceptance
budgets. Existing swap alone is not a reason to reject a stable machine.

Stops preserve pressure samples and incomplete phase evidence, close the owned
bridge and terminate only the owned fixture. Verify all owned PIDs exited and
observe host stability before another admission. Never weaken a safety limit
to complete a capture. Increase load only after a successful small comparison
and an explicit capacity check. Use one build job if another build is needed.

When the operator confirms spare CPU capacity on a busy shared host, use
`--resource-policy owned-budget` on both `loop.py` and `run.py`. This records
whole-host CPU/load as contention evidence without using them as admission
stops. The fixture still stops above 35% of one logical CPU, 200 interrupt
wakeups/s or 384 MiB, and memory reserve/swap-growth checks remain unchanged.
On a ten-core machine this app/helper CPU ceiling is 3.5% of total host CPU,
well below a confirmed 20% headroom. Keep one fixture active at a time, with
no build or AI-agent workload. Strict host admission remains the default;
the selected policy and effective limits are retained in every capture.
Performance acceptance budgets are unchanged, and busy-host latency remains
part of the evidence rather than a reason to declare a speedup.

## Loop

1. Build a baseline with the normal packaging workflow and a dedicated cache:

   ```sh
   RUSTC_WRAPPER= CARGO_TARGET_DIR=/tmp/chau7-perf-target \
     OUT_DIR=/tmp/chau7-perf-baseline \
     bash apps/chau7-next/scripts/bundle-macos.sh
   ```

2. Run a discovery pass. Inspect every phase's snapshots, missing counters and
   workload proof. Fix capture gaps and rerun before treating it as a baseline.

   ```sh
   python3 apps/chau7-next/scripts/perf-bench/run.py \
     '/tmp/chau7-perf-baseline/Chau7 Next.app/Contents/MacOS/Chau7 Next' \
     baseline-1 --measure 30 --settle 5 --results /tmp/chau7-perf-results
   ```

3. Change one measured source of waste, rebuild to a fresh OUT_DIR, then run
   the exact same command with the candidate binary and a new label. Wait for
   builds to finish before final comparisons. Use interleaved baseline/candidate
   runs at least twice; retain raw samples, binary hashes, host load and arguments.
   Automate the interleaved A/B/B/A run and comparison after each rebuild:

   ```sh
   python3 apps/chau7-next/scripts/perf-bench/loop.py \
     '/tmp/chau7-perf-baseline/Chau7 Next.app/Contents/MacOS/Chau7 Next' \
     '/tmp/chau7-perf-candidate/Chau7 Next.app/Contents/MacOS/Chau7 Next' \
     --results /tmp/chau7-perf-iteration-1
   ```

4. Compare with `summary.py /tmp/chau7-perf-results/*.json` (select complete runs).
   Accept changes only when the repeat runs agree, workload proofs pass and
   output/request latency stays within budget. Reject regressions and repeat.
   Enforce repeat compatibility, regressions and budgets with:

   ```sh
   python3 apps/chau7-next/scripts/perf-bench/compare.py \
     --baseline /tmp/chau7-perf-results/baseline-{1,2}.json \
     --candidate /tmp/chau7-perf-results/candidate-{1,2}.json \
     --output /tmp/chau7-perf-results/comparison.json
   ```

   A failed budget exits nonzero and means another iteration is required.
   Active phases also require recent selected-terminal paint evidence and a
   healthy hang watchdog, so a frozen renderer cannot pass as an optimization.

5. Repeat under 4/12 tabs and a sustained run only when capacity permits. Run regression checks,
   preserve a compact measured report, and publish through the broker workflow.

The default phases are idle, terminal, MCP, proxy and recovery. A five-second
output warm-up must complete terminal startup before any phase is timed;
silent terminals can otherwise leave the animated startup overlay running. The safe default uses a
3 Hz alternate-screen TUI in one visible tab; `--tabs`
counts additional tabs. MCP issues runtime-info calls through the actual bridge.
Runtime-info has a sustainable server limit of 2 requests/s; the default is
0.5/s and server limits remain enabled.
Proxy exercises the local SQLite stats endpoint at 1 request/s by default; this is an
analytics/control workload, not a measurement of upstream model streaming.
The synthetic loop makes no external API or paid model calls.

## Measurement contract

`native.py` calls macOS `proc_pid_rusage` v4 directly once per second for each
owned PID. CPU uses Mach timebase conversion, excludes children, and is expressed
as percent of one logical CPU. Physical footprint and RSS are distinct byte
counters. Wakeups are interrupt and package-idle wakeup deltas per second, not
context switches or an estimate of whole-machine energy. A zero package-wakeup
reading on a busy machine does not prove that an app has no energy cost.
Host load averages are sampled alongside native process counters throughout each phase; retain them when interpreting trials on a shared developer Mac. Load average is contention context, not process CPU usage. Disk bytes and page-ins are cumulative deltas. PID/start-time changes, negative
deltas and unavailable native reads fail the run instead of becoming zero.

The TUI receives phase/progress paths as explicit arguments: startup deliberately
clears inherited `CHAU7_*` variables. Every worker reports frames and emitted
bytes. Idle/recovery must have zero frame deltas; terminal phases must have
positive byte deltas and frame counts within 20% of the configured rate for every
expected worker. The external TUI generator uses user-initiated QoS and absolute
frame deadlines, without catch-up bursts; measured app/helper scheduling is unchanged.
Rejected phases retain their raw samples, snapshots and synthetic private profile
(`failed_profile` in JSON) for diagnosis. Harness source hashes must match between
compared trials; keep the scripts unchanged until the paired run finishes. Full snapshots bracket each phase;
rolling latency percentiles must not be described as whole-phase percentiles.

Starting acceptance budgets on this host are idle app CPU <1%, app interrupt
wakeups <60/s, bridge CPU <0.1% and wakeups <1/s, proxy CPU <0.1% and wakeups <5/s,
app physical footprint <192 MiB for four tabs, and MCP/proxy p95 <10 ms at 2/10 Hz.
These are workload-specific targets, not cross-machine guarantees. Active
terminal output should remain <10% of one CPU and return to idle after output
stops. Memory should stabilize during a longer run; compare recovery and peak
separately. The snapshots explicitly identify unavailable private GPU allocation
and physical presentation timings; footprint is not a replacement for those.

Validate the collector before benchmarking:

```sh
python3 -m unittest discover -s apps/chau7-next/scripts/perf-bench -p 'test_*.py' -v
```

The native acceptance compares the ctypes ABI with the installed C SDK, checks
CPU units against getrusage, and verifies busy child CPU stays out of its parent.

Use `--threads` for a diagnostic pass. It records best-effort native thread CPU
attribution with nanosecond counters, excluding vanished, renamed or regressed
handles. Opaque handles can be recycled; this is attribution evidence, not a
substitute for process CPU totals. Leave it off for final comparisons.

## Local streaming proxy fixture

The app-owned proxy phase above measures control requests. Also measure the
real forwarding/SSE/task/SQLite paths with the opt-in test executable:

```sh
go -C services/chau7-proxy test -c -trimpath -ldflags='-s -w' \
  -o /tmp/chau7-proxy-perflab.test .
python3 apps/chau7-next/scripts/perf-bench/proxy_run.py \
  /tmp/chau7-proxy-perflab.test proxy-candidate-1 \
  --results /tmp/chau7-proxy-results
```

For a baseline, build the same `perf_fixture_test.go` against the frozen baseline
source; keep all other source bytes unchanged. Interleave two runs per build.
The fixture redirects only its test transport to an owned loopback provider.
Production origin selection and credentials are unaffected. Every response must
match the complete synthetic SSE stream byte for byte. Two streams/s contain
19 flushed events with a deliberate 5 ms inter-event delay; record first-byte
latency separately from completion latency. Target proxy CPU <1%, footprint
<24 MiB, first-byte p95 <10 ms, and return to <0.1% CPU after streaming stops.

This separate fixture excludes the app-owned parent watcher, IPC delivery and
provider TLS. Keep its results separate from the bundled proxy process and do
not describe local fake-provider latency as real model latency.

## Authorized live agent workload

`live_agents.py` supplements the synthetic loop with real issue investigation.
The five task groups cover six issues, with one agent handling two repositories.
Each invocation starts exactly one GPT-6-Luna Max CLI in an owned isolated app.
It requires `--task-index 0..4` and a 60-second pressure admission check. Verify
completion and close the previous owned fixture before starting another group. Use it only for authorized live work: it
uses the current user's Codex credentials and session transcripts, incurs model
usage and can publish the issue comments requested in the task prompts. The
app's profile, restoration state and MCP socket remain private to the fixture.

Prepare a JSON array with exactly five objects. Each has `directory`, `prompt`
and `issues`; the issue lists total six entries. Freeze each assigned issue's
URL, number and repository alongside the source list of its ten newest issues.
Write prompts with bounded investigative work, evidence-backed findings and at
most one non-duplicate comment per issue, respecting repository publication and
provider approval rules. Do not implement code or alter issue state.

```sh
python3 apps/chau7-next/scripts/perf-bench/live_agents.py \
  '/tmp/chau7-perf-candidate/Chau7 Next.app/Contents/MacOS/Chau7 Next' \
  /tmp/authorized-live-tasks.json --results /tmp/chau7-live-load-1 --task-index 0 --seconds 600
```

Finish compilation before starting. Retain launch/submission evidence, native
app/bridge/proxy samples, host load, live lifecycle snapshots and resulting
comment URLs. Retain proxy request/usage counters before and during the workload
to establish whether model requests actually traversed the owned proxy. App CPU excludes CLI children. Retain lifecycle/transcript evidence
for each serial turn; a CLI process alone does not establish active work. The collector's `captured` status means capture finished, not that
all issue work succeeded. Check every result and permission failure.

The live admission check does not interrupt an in-flight publishing turn on
pressure. Admit no further work when pressure rises; resolve the current turn
and verify cleanup first. This run retains its owned fixture and private profile so that pending issue
work can finish. Verify completion before closing its tabs and app. It never
authorizes stopping the installed production app or unrelated sessions. Keep
full owned PTY tails and issue data private; publish only bounded numerical
evidence and comment links.

Live model and tool timing varies. Report this as observational stress evidence,
separately from deterministic A/B results, and do not rerun comment publication
to manufacture repeatability.


## MCP server subscription fixture

[Measured observations and acceptance status](MCP-SUBSCRIPTIONS.md) retain the
partial native comparison, including pressure-blocked admissions and the
unresolved proxy recovery budget.

`mcp_run.py` exercises the real app server through two owned bridge connections,
with one synthetic tab and no provider turns or terminal input. Unlike tool-only
polling, its reader drains event notifications continuously. It validates serial
delivery and zero dropped notifications, retains bounded notification evidence,
and fails explicitly on frame/evidence overflow or disconnect.

```sh
python3 apps/chau7-next/scripts/perf-bench/mcp_run.py \
  '/tmp/chau7-mcp-candidate/Chau7 Next.app/Contents/MacOS/Chau7 Next' \
  candidate-1 --results /tmp/chau7-mcp-results --measure 20 --settle 3
```

The five phases are unsubscribed idle, subscribed idle (15 s heartbeat), controlled
subscription changes, runtime-info tools at 0.5 Hz, and unsubscribed recovery.
The second client creates/cancels one subscription every two seconds; its actual
timer registration/cancellation journal events prove notification delivery to the
first client. This adds no artificial production event-injection API and never
requires control of an existing tab. Native app, proxy and both bridge counters,
notification latency, tool latency, unsubscribe duration, health, pressure and
cleanup are retained. Notifications must stop after completed unsubscribe.

Use identical arguments and frozen harness hashes for paired runs. The same
60-second admission, memory/swap/wakeup stops and explicit `owned-budget` option
apply. Run no compilation, other fixture or agent workload during captures.
