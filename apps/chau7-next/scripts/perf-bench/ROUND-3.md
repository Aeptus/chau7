# Performance loop, round 3

Four serial, single-tab idle trials completed and passed the existing budgets.
The candidate removed idle transcript polling, but native CPU, wakeups and
physical-footprint ranges overlap. **No native performance gain is established.**
The five-phase comparison remains incomplete after three swap-pressure stops.

## Admission and provenance

The operator confirmed about 20% spare host CPU on October 31. The explicit
`owned-budget` policy records shared-host CPU/load without rejecting unrelated
activity. It retains the 25% memory-reserve floor, 256 MiB/30 s swap-growth stop,
384 MiB owned physical-footprint ceiling, and sustained limits of 35% of one
logical CPU and 200 owned interrupt wakeups/s. Strict host admission remains
the default. On this ten-core Mac, 35% of one core is 3.5% of total host CPU.

Every fixture used a fresh private home, one synthetic tab, 3 Hz terminal
output, 0.5 Hz MCP and 1 Hz proxy control, with a 60-second pressure admission,
five-second warmup, ten-second settling and 30-second measurement per phase.
Only one app was active at a time. No builds, tests or live AI agents ran during
the captures. Host CPU contention remained recorded; limits were not raised.

Frozen runtime sources and app SHA-256:

| Build | Source | App SHA-256 |
| --- | --- | --- |
| Baseline | `0d63c238530e75724a22d994789a21d9d2f00bbe` | `8b3071c03ea8e18cdb40db7d40c9b500ade3195b6b5ec97971ec3881f653993c` |
| Candidate | `b13d3b26b550e006568e86d52bafcc2be5ba100d` | `877a8d3dc75374eef3b72fd661a3a08ce1c61437605ff2ec30f0d39756a48150` |

The candidate contains the transcript-worker change merged in #307. Neither
bundle was rebuilt during this batch. Captures used unchanged harness source
at `09892f3e99255c3166b67827257c795d47180739`; source hashes, helper hashes,
arguments, native process summaries, callback deltas, workload proofs and
pressure samples are retained in [round-3-evidence.json](round-3-evidence.json).
Full raw captures remain under `/private/tmp/chau7-perf-loop3/`, with their
paths and SHA-256 hashes in that evidence file.

## Completed idle A/B/B/A

Values below are medians of two independent runs per build. CPU is percent of
one logical CPU; memory is native physical footprint, not RSS.

| App metric | Baseline median (range) | Candidate median (range) |
| --- | --- | --- |
| CPU | 0.478% (0.459–0.497%) | 0.449% (0.429–0.470%) |
| Interrupt wakeups/s | 40.708 (40.656–40.760) | 40.472 (40.178–40.766) |
| Peak footprint, MiB | 120.59 (118.08–123.09) | 118.94 (118.27–119.61) |
| Transcript poll callbacks per 30 s | 146 (146–146) | 0 (0–0) |

The no-regression/budget comparison accepted these idle trials with no findings.
The apparent median changes (CPU -6.0%, wakeups -0.6%, footprint -1.4%) are small
absolute differences with overlapping ranges on a shared host. Callback
elimination proves worker parking; it does not prove equivalent kernel wakeup
or CPU savings. Idle trials contain no MCP/proxy requests and establish no
request-latency result.

The idle MCP bridge stayed below 0.002% CPU and 0.516 wakeups/s. The proxy
stayed below 0.022% CPU and 2.234 wakeups/s. All four trials passed the pressure
limits; the largest app/helper CPU sample was 2.19% of one core, about 0.219%
of total host capacity. Minimum memory reserve was 30%; maximum observed
30-second swap growth was 60.5 MiB.

## Incomplete full runs

The retry protocol preserved every failure, closed its owned fixture and waited
30 seconds before a new 60-second pressure admission. It stopped after three
pressure failures without changing limits.

| Five-phase attempt | Outcome | Maximum swap growth within 30 s |
| --- | --- | --- |
| 1 | Idle completed; stopped during terminal phase | 265.63 MiB |
| 2 | Stopped after startup, before a measured phase completed | 276.19 MiB |
| 3 | Rejected before app launch | 1044.82 MiB |

An earlier full baseline also stopped before recovery on 262.57 MiB swap
growth. Its completed diagnostic phases recorded idle CPU 0.550%, terminal CPU
1.288%, MCP p95 4.744 ms (15 requests), and proxy-control p95 9.552 ms
(30 requests). That incomplete run is retained separately and excluded from
comparisons. No complete candidate full run exists in this batch.

One private launch wrapper initially selected only idle while announcing a full
run. It was interrupted before app admission, retained as incomplete, corrected
to explicitly select all five phases, and restarted in a new directory. It
provides no performance evidence.

All 21 recorded owned app/bridge/proxy PIDs from this batch were verified absent
after cleanup. Production Chau7 was not installed, stopped or relaunched.

## Remaining work

Complete the five-phase paired comparison when swap growth stabilizes, then
consider four-tab and sustained recovery tests before increasing load. The
five serial Luna Max issue-research tasks across six repositories have not
started. The local proxy-control endpoint is not model streaming; upstream
latency, live CLI load, private GPU allocation and physical presentation timing
remain outside this result.

Idle feedback, readiness, persistence and app polling callbacks still run.
Their counts identify scheduling work to investigate; attribution and a new
paired native measurement are required before selecting or claiming the next
optimization. The app is not declared fully optimized.
