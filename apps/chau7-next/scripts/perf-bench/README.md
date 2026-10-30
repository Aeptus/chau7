# Isolated macOS performance lab

Build and measure the actual app, its bundled MCP bridge, and its app-owned Go
proxy. The harness uses a fresh temporary home, synthetic terminals, private
sockets, free local ports and fresh result filenames. It never accepts the
production PID, installs into Applications, or reads production session data.
It terminates only the child app it started; results survive failed runs.

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

5. Repeat under 1, 4 and 12 total tabs and a sustained run. Run regression checks,
   preserve a compact measured report, and publish through the broker workflow.

The default phases are idle, terminal, MCP, proxy and recovery. Terminal uses a
12.5 Hz alternate-screen TUI in one visible and three hidden tabs; `--tabs`
counts additional tabs. MCP issues runtime-info calls through the actual bridge.
Runtime-info stays at its sustainable limit of 2 requests/s; the server limits remain enabled.
Proxy exercises the local SQLite stats endpoint at 10 requests/s; this is an
analytics/control workload, not a measurement of upstream model streaming.
No external API or paid model calls are made.

## Measurement contract

`native.py` calls macOS `proc_pid_rusage` v4 directly once per second for each
owned PID. CPU uses Mach timebase conversion, excludes children, and is expressed
as percent of one logical CPU. Physical footprint and RSS are distinct byte
counters. Wakeups are interrupt and package-idle wakeup deltas per second, not
context switches or an estimate of whole-machine energy. A zero package-wakeup
reading on a busy machine does not prove that an app has no energy cost.
Disk bytes and page-ins are cumulative deltas. PID/start-time changes, negative
deltas and unavailable native reads fail the run instead of becoming zero.

The TUI receives phase/progress paths as explicit arguments: startup deliberately
clears inherited `CHAU7_*` variables. Every worker reports frames and emitted
bytes. Idle/recovery must have zero frame deltas; terminal phases must have
positive deltas for every expected worker. Full snapshots bracket each phase;
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
