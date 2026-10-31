# MCP subscription wakeups — 2026-10-31

Subscription workers now wait for a bounded journal-change signal instead of
replaying every 100 ms. A capacity-one nonblocking channel coalesces changes;
the existing replay cursor remains authoritative, so event payloads are not
queued in the signal. Weak listeners are reclaimed on registration/publication.
Initial response arming, cancellation and the actual heartbeat deadline also
wake the worker. Serial delivery, explicit replay expiry and bounded frame-write
timeouts remain in effect.

## Status: native acceptance incomplete

The planned serial A/B/B/A comparison completed A/B/B. The final baseline could
not pass admission: its initial attempt and all three permitted retries exceeded
the unchanged 256 MiB swap-growth/30 s cap **before launching an app**. No further
fixture was launched. The original acceptance checks applied to the available
captures also found candidate 2's proxy recovery wakeups above its 5/s budget
(5.65/s). Overall acceptance is **false**; this is not a completed paired result.

The runtime implementation and tests are ready for review. A complete matched
comparison and resolution of the recovery proxy budget remain before declaring
the MCP performance protocol passed. CPU and memory gains are not established.

## Available observations

| Process / phase metric | Baseline A1 | Candidate B1 / B2 |
| --- | ---: | ---: |
| App subscribed-idle CPU (% of one core) | 0.4595 | 0.5575 / 0.4705 |
| App subscribed-idle interrupt wakeups/s | 50.20 | 46.14 / 40.05 |
| App change-phase interrupt wakeups/s | 55.70 | 44.00 / 40.49 |
| Event delivery p95 (ms) | 100.38 | 3.09 / 3.34 |
| Runtime-info request p95 (ms) | 1.04 | 5.23 / 3.77 |
| Unsubscribe duration (ms) | 1.18 | 0.57 / 3.35 |
| App subscribed-idle peak footprint (MiB) | 68.80 | 69.75 / 69.08 |
| Proxy recovery interrupt wakeups/s | 6.45 | 4.15 / 5.65 |

The two candidates delivered events faster and had fewer subscription wakeups
than the available baseline. One baseline cannot establish the planned repeated
comparison or separate host drift. Tool latency increased in these captures,
remaining below the predeclared 10 ms budget. Candidate unsubscribe stayed below
100 ms. App CPU was under 1% of one core in every measured phase. Candidate change-phase peak footprints were 120.00 / 119.55 MiB, with a
120.27 MiB maximum in any phase. Compressed/page-in accounting varies with
host pressure, so no footprint reduction is claimed.
Both bridges stayed below 0.01% of one core, 0.51 interrupt wakeups/s and 2 MiB.

The Go proxy source is unchanged between these MCP bundles. These observations
are separate from the Go streaming optimization and do not validate the combined
branches. The baseline itself also exceeded 5 proxy recovery wakeups/s. That
context does not waive the candidate's predeclared process budget.

## Frozen builds and workload

Candidate runtime: `00cdfaedcacddba920567ce0604956c15977dac2`.
Baseline bundle runtime: `b13d3b26b550e006568e86d52bafcc2be5ba100d`, equivalent
to base `3da1fa81168c1060ba3a0f32ff2cfaaae4af3905` for application code,
dependencies, vendor files and resources. The full diff contains only ten
performance-lab scripts/reports. Reusing its signed bundle avoided another build.
Both bundles have verified artifact hashes and signatures, use Rust 1.99.0,
Go 1.27.3 and matching fast optimization settings. Candidate compilation used
one job; baseline used two. Compilation finished before native captures.

One isolated app, one synthetic idle terminal and two owned bridge connections
ran on a 16 GiB, ten-core M4. The five phases measured 20 seconds after 3 seconds
settling: unsubscribed idle, subscribed idle with the default 15 s heartbeat,
changes, runtime-info requests and unsubscribed recovery. Changes alternate one
second-client subscribe/unsubscribe every two seconds, with at most two active
subscriptions. Ten real timer registration/cancellation journal events per
capture prove delivery. Tools run at 0.5 Hz (ten requests). There are no provider
turns, production inputs or artificial production event-injection APIs.

The original discovery capture had all required workload/native/cleanup data;
no missing field required a harness change. Its reuse as A1 was declared before
the first candidate run. The collector and workload hashes match across all
three complete captures. The driver stopped at its original pressure retry
limit; neither caps nor acceptance tolerances were relaxed. The evidence keeps
the original plan and distinguishes the partial comparison generated after
that stop from the planned complete comparison.

## Capture validation, safety and scope

The collector continuously drains notifications, validates delivery sequence,
zero drops, matching event/timer identity and health, and requires notifications
to stop after unsubscribe. Every measured phase verified one live synthetic
terminal and zero emitted terminal frames/bytes. Native app, proxy and both
bridges are measured separately, alongside notification/tool timing, pressure,
workload proof and cleanup. Full numeric snapshots and raw samples remain private.

Completed captures had minimum memory reserves of 30%, 30% and 29%, with maximum
30 s swap growth of 69.19, 144.31 and 20.06 MiB. All completed fixture guards
passed. Failed admissions recorded 379.31, 275.94, 269.25 and 290.07 MiB growth.
No compilation, test suite or AI-agent workload ran during native capture.
Cleanup verified exit of every owned app and helper; PID reuse observed later
was distinguished by process identity. The production app was not installed,
quit or restarted.

Core validation passed 2,580 tests and Clippy with warnings denied. Seven actual
macOS observer tests passed, covering initial arming, racing/burst replay,
heartbeat, cancellation and replay expiry alongside frame-write behavior.
Seventeen collector/native/safety checks, pinned Ruff 0.17.0 and six staged
quality gates passed. Runtime-head Linux and quality CI passed, including
workspace tests and Clippy. A packaging retry regenerated a confirmed incomplete
SQLite build-cache entry; source/flags were unchanged and the final bundle's
signature and receipt were verified before launch.

This fixture does not cover live AI output, large slow-reader backpressure,
many simultaneous subscribers or whole-machine energy use. Interrupt wakeups
are distinct from scheduler wakeups. Short shared-host captures do not establish
cross-machine performance guarantees.

[Compact evidence](mcp-subscription-evidence.json) retains build receipts,
argument/harness hashes, original budgets, all observed values, the incomplete
acceptance findings and checksummed raw artifact paths. Raw private captures are
under `/private/tmp/chau7-proxy-mcp-loop`; they are temporary, not durable after
that directory is cleaned.
