# Go proxy SSE accounting — 2026-10-31

Streaming metadata now merges from SSE lines as they arrive instead of retaining
and reparsing the complete response. The rate observer borrows complete lines
from each read and copies only unfinished fragments. Non-streaming buffering,
forwarded bytes, usage/cache semantics, SQLite accounting and rate sampling are
preserved. There is no new metadata event-size limit: large Responses completion
events can carry authoritative usage after their output.

## Results

Baseline runtime: `3da1fa81168c1060ba3a0f32ff2cfaaae4af3905`.
Candidate runtime: `e2f254de699b49cd80d5e0c1ff9a37768cf9d823`.
Both use Go 1.27.3, identical benchmark sources and optimized non-race test builds.

| Handler benchmark (median of three) | Baseline | Candidate | Change |
| --- | ---: | ---: | ---: |
| Allocated bytes / 16-delta stream | 177,064 | 65,588 | −63.0% |
| Allocated bytes / 1024-delta stream | 11,652,562 | 1,380,520 | −88.2% |
| Allocations / 1024-delta stream | 6,319 | 3,191 | −49.5% |

The handler benchmark exercises real forwarding, metadata, rate observation and
SQLite recording with a discard client writer. IPC has no database in this
microbenchmark; the standalone native fixture enables its database. Allocated
bytes are cumulative per request, not live physical memory. CPU benchmark times
had outliers and overlapping ranges; they do not establish a reliable CPU gain.

Native comparison used one loopback proxy at a time on this 16 GiB, ten-core M4,
`GOMAXPROCS=2`, 0.5 streams/s, 16 × 65,536-byte deltas, 1,050,500 response bytes,
5 ms event spacing, and 20 measured seconds after 5 seconds settling per phase.
Each streaming phase completed ten byte-exact responses. The frozen collector
and argument hashes match across the four accepted captures (A/B/B/A, with the
last A replaced by a pressure-checked retry).

| Streaming process metric (median of two runs) | Baseline | Candidate |
| --- | ---: | ---: |
| CPU (% of one logical core) | 0.6018 | 0.5067 |
| Peak physical footprint (MiB) | 17.1022 | 13.1022 |
| Interrupt wakeups/s | 120.10 | 106.86 |
| First-byte p95, each capture (ms) | 1.14 / 1.49 | 3.72 / 3.10 |

The repeated native streaming CPU values were lower (−15.8%) and footprint was
lower (−23.4%). These are short shared-host captures, not cross-machine guarantees.
Wakeup ranges overlap (baseline 108.00–132.19, candidate 104.08–109.64/s); no clear
wakeup gain is established. Candidate first-byte latency increased in these
captures and remains below the predeclared 10 ms budget. No latency speedup is
claimed. Candidate idle/recovery CPU stayed below 0.001% of one core and wakeups
below 0.27/s. All existing regression tolerances and proxy budgets passed.

## Safety and retained failures

No build, test suite or AI-agent load ran during captures. The operator-confirmed
`owned-budget` policy recorded shared-host CPU/load while enforcing memory reserve,
swap growth, owned CPU, footprint and interrupt-wakeup caps. Completed runs had
at least 35% reserve and zero measured swap growth. Every owned proxy exited.

A discovery run at 1 stream/s stopped on its 200/s interrupt-wakeup guard; the
rate was reduced identically for both builds. The first final baseline stopped
on 754 MiB swap growth/30 s and was retained as incomplete. Its cleanly stopped
proxy was followed by a fresh admission and successful retry. Neither failed
capture enters the accepted comparison. Limits were not relaxed.

## Verification and scope

Provider/chunk-boundary regressions cover Anthropic, OpenAI chat/Responses and
Gemini, Unicode/CRLF, malformed records, explicit zero cache counters, final lines
without newlines and a 2 MiB completion event. A handler integration test checks
byte-exact passthrough and persisted usage. Full Go race tests, focused final
rate-fragment tests, pinned golangci-lint 2.14.0 (zero issues), 22 Python collector
checks and staged quality gates passed. Runtime-head Linux and quality CI passed.

This fixture excludes the GUI, parent watcher, provider TLS and live model/agent
load. It does not measure end-to-end provider latency or whole-machine energy.
[Compact evidence](proxy-sse-evidence.json) includes binary/harness hashes,
arguments, repeated values, pressure maxima, rejected captures and private raw
artifact paths/checksums. Raw native samples and CPU/allocation profiles remain
under `/private/tmp/chau7-proxy-mcp-loop`; private artifacts are not durable after
temporary-directory cleanup.
