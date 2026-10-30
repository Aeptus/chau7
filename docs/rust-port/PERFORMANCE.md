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
The `metrics` value in each history record is that full snapshot, so
`telemetry.token_rates_by_tab` readings present at capture time are included
in both persisted files. The performance files retain these readings under the
size limits and rotation described above; the in-memory token-rate store prunes
to 384 readings after exceeding 512. When a reading changes, a separate
token-rate entry is emitted at debug level and follows the configured
`CHAU7_NEXT_LOG` level.
Accepted records drain on the background quit worker. Repeated write failures
produce one operational warning until a successful write resets it.

## Persistence admission and completion

The schema1 `persistence` object distinguishes queue admission from completed
writes. Its counters are `accepted`, `written`, `drop_full`, `failure`,
`disconnected`, `rejected_closed` and `worker_start_failure`. `accepted` means
that the nonblocking queue admitted a sample. `written` means the latest-file
replacement and history append/flush completed; it makes no fsync durability
claim. A snapshot cannot acknowledge its own subsequent write.

`state` is `running`, `draining`, `closed`, `disconnected` or `start_failed`.
Before initialization, state, availability and counters are null; availability
is true only while running. `last_error_category` uses a fixed I/O vocabulary,
contains no error text or paths, and retains the last observed failure even if
later writes succeed. Worker I/O and operational logging run outside the lock
used by snapshot capture. Quit closes admission on the UI thread and drains
accepted samples on the existing background quit worker.

## Aethyme subprocess capture

Actual bounded CLI captures emit background wall-time measurements under
`aethyme.delivery` / `subprocess_capture_wall`, with four static callers for
list, poll, claim and complete. They exclude the preceding polling interval and
subsequent logging or recipient delivery; elapsed capture time is not CPU time.
Consecutive incomplete captures of the same kind back off from30s to300s and
warn once until that kind succeeds. Successful list/poll operations do not
reset an incomplete claim/complete sequence. Shutdown cancellation produces no
outage warning. An incomplete capture is not proof of a particular cause.

## Delivery acceptance and history shutdown

An in-memory Aethyme acceptance ledger prevents rewriting a prompt after an
accepted terminal write whose CLI completion acknowledgement was incomplete.
It matches canonical root, item, parsed tab UUID, native AI session, and the
formatted prompt SHA256/byte length. Reclaimed generations acknowledge their
current validated claim without writing the accepted prompt again. Only a fully
captured successful Ready completion removes the acceptance record. A changed
prompt cannot overwrite an earlier accepted fingerprint. The ledger caps entries
at2,048 and key/digest payload at1MiB, rejects new writes when full, and never
silently evicts pending acknowledgements. This is a running-process safeguard;
it does not claim durable deduplication after a restart or exactly-once delivery
by an external protocol. Metadata overhead is additional to the payload budget.

Normal quit also closes history admission on the UI thread after producer
shutdown. The existing background quit worker joins the actual history writer,
then releases its writer-owned observer/store references before reporting clean
quit. Live readers may retain the store until their own teardown; normal shutdown
does not require exclusive ownership of every reader.
Accepted and failed records remain distinguished. Joining a writer is separate
from observing that a Weak reference no longer upgrades: SQLite destruction can
still be running, particularly with Windows file locks.

## Measurements and limits

JSON schema version 1 contains:

- App identity and capture timestamp. An unpackaged development executable
  has null bundle metadata rather than claiming an unknown revision is real.
- App process resident memory in **bytes**, accumulated CPU time in **seconds**,
  and sampled CPU percentage. One logical CPU is 100 percent; multiple busy
  threads can exceed 100. Children and helper processes are excluded.
  The first CPU sample and unsupported platforms return null.
- Memory-pressure incidents can originate from macOS system pressure even when
  Chau7's own resident memory is small. The native source subscribes to normal,
  warning and critical events: normal immediately ends the system-pressure
  hint, and warning ends critical cache shedding. Empty or unknown event flags
  do not create warnings. App physical-footprint protection is independent;
  system recovery cannot clear a high-footprint hint, and a low footprint
  cannot clear an active system warning. Without a recovery event, pressure
  hints expire after 90 seconds and critical shedding after 30 seconds.
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
- `telemetry.token_rates_by_tab` contains latest observed generation-speed
  readings keyed by local tab ID. Each typed reading preserves provider, tokens
  per second, output-token count, duration, source and `updatedAt`. Snapshot
  capture copies the existing bounded in-memory store; it performs no transcript,
  SQLite or provider query. An unavailable store is `null`; an initialized
  store with no readings is `{}`; tabs without observations are omitted, never
  assigned zero. This export does not apply a freshness filter, so a retained
  reading may be stale; use its timestamp when interpreting it. The tab-bar
  badge is shown only while AI is running and when the signed age's integer
  `num_seconds()` value is in the inclusive `0..=15` range. Debug Console
  Analytics lists retained readings without an age filter. The existing store
  prunes to 384 readings after exceeding 512. The field includes no prompts,
  provider session IDs, transcript paths or credentials.
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

### Budgets: where to start optimizing

Every stage has a per-sample wall-time budget (`work_profiler::budget_ms`).
Main-thread work without its own budget gets one 60 Hz frame (16.7 ms);
background work and waits other than output dispatch have none. Each aggregate
reports `over_budget_samples`, `over_budget_ms` (time past the budget) and
`p50_ms`/`p95_ms`/`p99_ms` (upper bounds of a 15-bucket histogram, capped by the
maximum), and each entry its `budget_ms`.

`work_profile.budgets.worst_last_60s` ranks the stages by `over_budget_ms` in
the last minute. Start at the top: it is the work that most delays frames and
input right now. Explicit budgets:

| Stage | Budget |
|---|---:|
| `terminal_painter/grid_paint` | 8 ms |
| `terminal_painter/row_pass` (all rows: reuse and submission) | 6 ms |
| `terminal_painter/row_prepare` (changed rows only) | 3 ms |
| `terminal_painter/prepaint_snapshot`, `terminal_view/view_build`, `session_refresh/deferred_grid_copy` | 2 ms |
| `session_refresh/output_processing` | 4 ms |
| `session_refresh/get_grid` | 1.5 ms |
| `session_refresh/get_grid_shape` | 0.25 ms |
| `output_dispatch/event_dispatch_congestion` (latency) | 16.7 ms |

`event_dispatch_wait` is the whole delay from PTY capture to processing,
including the refresh pump's deliberate pacing hold (up to one interval of
the active or inactive frame-rate cap), so it has no budget.
`event_dispatch_congestion` subtracts that hold: it is the main thread's own
cost to the output.

A budget is a target for a stage's share of a frame, not a guarantee: GPU
glyph submission inside `grid_paint` has no cheaper path in GPUI.

### Incremental row painting and hidden grids

GPUI emits every primitive each frame, but a row's text runs, grapheme
segmentation and shaping are prepared once and reused while its cells,
clusters and style are unchanged (`terminal/row_cache.rs`, compared exactly).
`row_prepare` samples one per frame with `total_items` = rows prepared, so
`total_items / sample_count` is the average number of changed rows per frame.
Per-pane renderer diagnostics include `row_cache` with `rows_reused`,
`rows_prepared` and `reuse_ratio`.

A surface that is neither on screen nor prewarmed reads only its grid shape
(`get_grid_shape`) on output; its cells are copied once
(`deferred_grid_copy`) before it is next painted or snapshotted. Per-pane memory
diagnostics report `grid_cells_deferred`.

### Window frames and what invalidates them

GPUI redraws a window when any view rendered in it, or any entity such a view
read while rendering, is notified. `window_frame/workspace_render` samples the
root view's render, so its count is the number of window frames. Compare it
with `terminal_painter/grid_paint` (terminal repaints) and
`session_refresh/output_processing` (output batches): frames per batch is the
quickest check that background work is not redrawing the window.

The tab bar reads every tab's terminal view and session, so a notify from a
hidden tab redraws the whole window. Rules that keep hidden tabs from doing so:

- A terminal view is embedded as a cached view: unless it was notified or the
  window refreshed (focus, settings), its previous frame is replayed.
- A hidden session's output notify joins one shared flush at the next whole
  second; title, status, shell, AI, bell, clipboard and exit changes still
  notify at once.
- Output on a tab redraws the window only when it moves the tab out of the
  idle group (`TabsState::touch`).
- A hidden view marks its dangerous-output scan due for its next frame instead
  of scheduling a timer that notifies.

### Measured with an isolated instance (2026-10-30)

A synthetic AI-agent TUI (alternate screen, a panel redrawn at 12.5 Hz, a
transcript line every 2 s) ran as the profile shell in 13 tabs, one visible
at 201x58 cells, in an isolated diagnostic release build, 60 s per run, on a
machine with a load average of 22 to 36. Because load changes how much output
the TUIs produce, compare per output batch:

| Build | CPU ms per batch | Main-thread ms per batch | Window frames per batch |
|---|---:|---:|---:|
| main before this change | 4.21 | 5.52 | (not measured) |
| row cache, hidden grids, cached terminal view | 3.24 | 0.61 | |
| + activity redraws only on idle exit | 1.36 | 0.69 | 0.155 |
| + hidden danger scans without timers | 1.12 | 0.53 | 0.110 |

Reproduce or extend it with `apps/chau7-next/scripts/perf-bench`: build each
variant (`BUILD_MODE=diagnostic` keeps symbols for `--sample`), then

    python3 run.py <binary> <label> [--tabs 12 --hz 12.5 --measure 60 --sample 10]
    python3 summary.py perf-results/a.json perf-results/b.json

`run.py` starts an isolated instance (own home root under `/tmp`, its own MCP
socket, the TUI as its shell), never the installed app, and removes it after
the run. Do not measure while compiling.

In the last build the main thread was 88 % idle in a 10 s stack sample; GPU
glyph submission (2.4 %), window layout (1.4 %) and the scene sort (1.2 %)
remained. Repainting unchanged rows from cached row bands instead of
resubmitting their glyphs is the next step if more is needed.

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

## Whole-window renderer diagnostics

Runtime and performance MCP exports include window_renderer with immutable
startup policy, selected backend, bounded initial failure stage and whether an
optional fixture injected it. Per-window records expose actual backend,
submitted/failed image counts, last primitive counts, measured CPU submission
microseconds and retained software image/atlas pixel bytes. GPU and compositor
allocations and OS display completion are null when unmeasured. Image submission
to an ordinary CALayer does not establish completed display presentation.

A normal feature-free 7bd54649 owned app requests Software from the saved
use_metal_renderer=false preference; both windows and the CPU terminal run,
receive exact synthetic MCP Unicode input and quit normally with three saved
tabs. Latest main-window submit 139,217 us and 42.101% app-process CPU after 66.88s
show that software rendering has a measurable cost. Concurrent compilation and
the synthetic workload prevent a controlled idle comparison. Intermittent native
frame/resize barriers remain under investigation. See the recovery validation
for exact source, observations and limits.

### Telemetry startup and Aethyme capture diagnostics (2026-10-12)

The additive `telemetry` object in the existing performance snapshot reads
atomic store state, ordered writer counters and bounded in-memory cache/activity
counts. It performs no SQLite query and exports no keys, values, repository
paths or transcript content. Store states distinguish loading, ready, failed
and closed; accepted queue jobs are not presented as durable writes. Combined
validation and the reviewed missing-writer shutdown correction remain pending.

Aethyme incomplete-capture warnings now include the actual timeout, output-limit,
read-failure and cancellation flags, optional exit status, static caller and
stdout/stderr byte lengths. They contain no command, root, prompt or output
bytes. Existing 15-second/4 MiB bounds, one-warning outage suppression and
30-to-300-second retry backoff are retained. The work profiler separately
measures actual `aethyme.delivery` subprocess capture wall time on background
workers. Old generic warnings cannot retrospectively identify those flags.

### Token-rate performance export (2026-10-13)

The performance snapshot now includes `telemetry.token_rates_by_tab`. It reads
the existing bounded in-memory token-rate store and is available through
`chau7_performance_snapshot` and Debug Console Perf's Copy Performance JSON
and Save Latest Snapshot controls. It preserves each reading's source and
update timestamp; retained readings may be stale. Capture performs no transcript,
SQLite or provider query.


## Latency diagnosis and session correlation (2026-10-14)

Read the terminal measurements separately:

- Input response runs from input submission to the next PTY output. It includes
  the CLI's own processing and does not prove that those bytes echo the input.
  It is neither model time to first token nor a pure UI responsiveness measure.
- Input dispatch measures the app's input handling and enqueue work. Background
  PTY queue wait (`pty_input_queue`) and native send calls
  (`pty_input_send_bytes`) are separate numeric work-profile entries. Send-call
  completion is not an OS acknowledgement; aborted and rejected sends have
  separate `pty_input_send_aborted` and `pty_input_enqueue_failure` entries.
- Output latency ends after GPUI terminal paint work. This is a CPU-side boundary;
  GPU completion, compositor completion and physical display presentation remain
  unmeasured. Hidden time must not become a visible-render latency sample.

The PTY reader waits on output readiness, disconnection and explicit interrupts.
Its fallback deadline bounds health checks; it is not a delay before reading
new output. Idle timeout wakeups do not require an empty parser drain. Closing,
focus and input retain their explicit wakeups.

The `full_buffer_ansi` / `autosave` main-thread work entry reports exported byte
and call counts. Compare these with background `save_restore_transaction` work
to identify repeated captures without changed persisted contexts. No terminal
text is included. No restore cache is keyed only to PTY bytes: resize, clear,
replay and retention compaction can also change the saved buffer.

Provider session association must use the owning tab when available. A folder
match alone cannot distinguish simultaneous runs in the same repository, and
an old history record must not attach to a newer run. Missing provider identity
or transcript data remains missing; PTY fallback preserves readable content but
does not manufacture detailed turns, tokens, cost or generation speed.

The performance export includes aggregate `telemetry.extraction` counters for
provider availability, extraction attempts/successes, missing session identity,
missing transcripts, PTY/terminal fallbacks, and associated/ambiguous/unmatched/
conflicting/unresolved-tab identity events. These counters contain no provider
identifiers, paths or terminal text. Each stored run records its extraction
outcome and fallback source independently of the token-metric provenance.

Recent ended-run identity matching is bounded to 64 records for two minutes.
Events must match the provider and exact CWD, and their timestamp must fit the
run window. Explicit unresolved tabs cannot fall back to CWD matching. Owned
Claude SessionStart identity retries are bounded to five seconds and 20 attempts;
they do not replay notifications, install hooks or alter monitoring preferences.
