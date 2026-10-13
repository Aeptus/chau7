# Chau7 Next parity with the current Swift app

## Current implementation follow-up (2026-10-13)

### Latest committed source: core and fast package passed

Source `69461e60cb6bb65fe1a764510519fff599018b60` (tree
`859d2497fa1bdfeb0fce634999b915cdf5ec851e`) is the latest committed, clean
source revision. Its exact-head core run passed all 17 checks: 3,051 workspace
tests (two ignored), 150 shared-terminal tests (one ignored), 35 native Python
contract tests, seven focused Restore tests run exactly once, terminal EINTR
and HUP checks, formatting, build-mode and CLI-installer contracts, and strict
default and native-feature Clippy. The receipt is
`/Volumes/T7-repositories/chau7-next-parity-recovery-evidence-20261011/resume-20261013-1433/core-69461e60-v1/manifest.json` (SHA-256
`206179bbe4f67101bc73e08eaf6496e7892a1003919399edef34554093c7d2d4`).

The exact-head normal fast package also passed in 5.033 seconds with the
current cache state. This is one build observation, not a speed benchmark. Its
receipt is
`/Volumes/T7-repositories/chau7-next-parity-recovery-evidence-20261011/resume-20261013-1433/package-69461e60-v1/manifest.json` (SHA-256
`af167986ad8447c01069b3c69b314c75b0ae97340b4f823bd8b598e792a43caf`). The
standard bundle receipt is
`apps/chau7-next/target/bundle/Chau7-Next-aarch64-apple-darwin-fast.json`
(SHA-256 `2115316bf63d0d770dbbfe0b0cc066b04402421c0539bb0c0a50864ac83af64c`).
The current source also passed all nine selected local quality gates,
uncached and unattested; only the two conditional drift gates were skipped as
not applicable. The full local CI result reports 4,586 macOS Swift tests (three
skipped, zero failures), and the iOS result reports 97 tests (zero failures).
The focused FileMonitor/DirectoryMonitor run also passed. Quality receipt:
`/Volumes/T7-repositories/chau7-next-parity-recovery-evidence-20261011/resume-20261013-1433/quality-69461e60-v1/manifest.json` (SHA-256
`820b32ce1cdb23d74f8f70ee437a400089c5257d3423c3393d41c1bd863a5bc5`); its
structured result is
`/Volumes/T7-repositories/chau7-next-parity-recovery-evidence-20261011/resume-20261013-1433/quality-69461e60-v1/quality-local.log` (SHA-256
`61f8daca016bdf1b34a62b400b91ee34fe58768d135b90897e9afb32eab0b6ab`). The
external proposal records source gate log paths and hashes only; raw logs stay
in the worktree. The current-source native-parity fixture binary also built
successfully in fast release mode with the native-parity-fixture feature. Its
receipt is
`/Volumes/T7-repositories/chau7-next-parity-recovery-evidence-20261011/resume-20261013-1433/native-build-69461e60-v1/build-receipt.json` (SHA-256 `0bf4ba3c954cc7176a4694d11212b261c35211005ad6d20d9c07ab61b57842ec`); it binds artifact SHA-256
`47235c8b3bae1b227380f20a46eb1701c4bb8478724729723d2eaba33293287e` to the same source and tree. The current-source strict 21-row native matrix passed all 21 rows. Its
aggregate receipt is
`/Volumes/T7-repositories/chau7-next-parity-recovery-evidence-20261011/resume-20261013-1433/native21-69461e60-v1/native21-manifest.json` (SHA-256 `ac451af55851470bb9232a317843c5cdbe8ad1ec501a91fb6f3171b8fdaff8cb`); it binds the same source, clean
before/after state, and unchanged fixture binary. The current-source isolated normal-runtime v2 attempt was negative. The app
launch included a read-only `runtime_info` query. Its subsequent SavedWindow
preflight expected the first window at y=20 but read it back at y=34 after
macOS applied the visible-frame clamp; the second window remained at y=92. The
harness stopped before state-changing MCP operations and did not produce an
`mcp-acceptance.json`. The v2 cleanup receipt was negative; a separate
read-only verifier confirmed the app, socket and two sink-backed cats were
gone, prior acceptance files were unchanged, and no forced signals were sent.
That verifier has no AppleScript quit exit code, so it did not complete runtime
acceptance. A later geometry-aware, cat-aware helper passed the full isolated
runtime sequence; its evidence is recorded below. The ACE-bound results remain
historical and do not validate this source.

### Current-source isolated normal-package runtime: passed

The isolated runtime run passed for source
`69461e60cb6bb65fe1a764510519fff599018b60`, tree
`859d2497fa1bdfeb0fce634999b915cdf5ec851e`, and the standard bundle receipt
SHA-256 `2115316bf63d0d770dbbfe0b0cc066b04402421c0539bb0c0a50864ac83af64c`.
It used the peer-reviewed helper SHA-256
`b08bc8894656bf5ce947a0632527e414be504a1dd089f758f7b611ae98dd126c` and a
private synthetic HOME with a unique owned bundle identifier. The run restored
two saved tabs, created a third, sent a 68-byte fixture payload, and verified
its bytes exactly. It preserved both original sink inputs and the existing
acceptance baseline. The app, MCP socket and three fake-cat children retired;
the graceful quit returned zero, and all ten shutdown phases completed without
failure. No provider or device was contacted.

The full, source-bound run manifest is
`/Volumes/T7-repositories/chau7-next-parity-recovery-evidence-20261011/resume-20261013-1433/normal-runtime/outputs/normal-69461e60-v3/manifest.json`
(SHA-256 `10befc3fdc90e737470b5bcd3351f8cfd0561c8db5f766bbba98f7b7d560dd31`).
The MCP, quit and read-only root-verifier receipts have SHA-256 values
`13618e1de1a5bf0658e04b49244aab65671c3fd7c91fb8cd1ffe78baf57892fe`,
`76f07265ef05d47bc505cce7215111dd445c5eb055a4f5ba2e4a1582ab477f0f`, and
`caf4861b2f532566c87e10e7b1ee28f030fbc609cc40012f683b58bd119b0826`.

Read-only MCP performance snapshots and the actual timer inventory were
archived in the run evidence. The report exposed `token_rates_by_tab`, but the
synthetic run had zero token-rate readings, so it demonstrates field access,
not a measured generation rate. The captured process sample reported
157,958,144 resident bytes and 38.72% CPU on the documented one-logical-CPU
basis. Software rendering was selected and all three sampled windows reported
positive frames: 56, 51 and 5 (112 total), with zero failed frames. The timer
inventory contained 17 records, 16 active, spanning 80–300,000 ms. Automatic
performance persistence used the configured 5-second cadence; the archived
history had four records and its latest entry matched the persisted latest
snapshot. The receipt records the isolated profile paths; archived artifacts
include the before/after MCP snapshots, timer inventory, and persisted latest
and history files with per-file hashes. These are access and measured-counter
observations, not performance thresholds or a benchmark.

Archived performance files and hashes:

- MCP snapshot before fixture input:
  `normal-runtime/outputs/normal-69461e60-v3/performance-mcp-before.json`
  (`04071f8c5909d689b3def6184e9378f8b5e3f8ecbda9e4fa524729b2a60377c2`).
- MCP snapshot after fixture input:
  `normal-runtime/outputs/normal-69461e60-v3/performance-mcp-after.json`
  (`dc113e5ef1069b8fbced2c960b52cd4828c6d43ae57311fa00d0a7ca5001d03f`).
- Timer inventory:
  `normal-runtime/outputs/normal-69461e60-v3/performance-timer-inventory.json`
  (`61776539e4bcdcf688b95c527a2e6814bfbe2e20ff95fa0d634acc12f6121dde`).
- Persisted latest snapshot copied from the synthetic profile's
  `~/.chau7-next/reports/performance/latest.json`:
  `normal-runtime/outputs/normal-69461e60-v3/performance-profile-latest.json`
  (`e8a020ecff02338ec7d7a475a351b693634f8bd474ea829bf51225b75f6e8bdc`).
- Persisted history copied from the same profile's
  `~/.chau7-next/reports/performance/history.jsonl`:
  `normal-runtime/outputs/normal-69461e60-v3/performance-profile-history.jsonl`
  (`7bb540dff0dc62f499e8856d6601b7f4b931605b4cfdbbb948f8e6d5c9e9a6ad`).

The inventory audit found six stale n/a classifications. Background suspension,
the renderer controls and CPU fallback were already implemented. This follow-up
adds the missing localized hover-card suspension row and the SIGINT stage for
owned helper shutdown. The inventory contains 1,273 done and 36 n/a rows; these
implementation counts do not certify physical Mac acceptance.

Performance JSON and MCP expose the existing bounded in-memory token-rate
readings with their source and timestamps. Unavailable measurements remain
null or absent, and retained readings may be stale. The FileMonitor atomic-write
test waits for its watch to arm instead of assuming a 200 ms scheduling delay.

The native Restore fixture now has a first ordered-front activation stage. It
requires the stage-specific ACK and active NSApplication state under one
five-second deadline before continuing to the existing surface reveal and
later deminiaturization, rendered-frame, focus and live-state checks. This is a
fixture-only acceptance change; it does not establish a production focus fix
or explain the earlier intermittent failures.

### Previous exact-head core checkpoint: `ace3659a` (2026-10-13)

Source `ace3659a4830d186ce9e273cfed275d006a2a250` (tree
`1a0b84775c3fa2ec91a6e0bc8f5b90850ed96256`) passed all 17 recorded core
checks. The workspace run passed 3,050 tests (two ignored); the shared terminal
workspace passed 150 tests (one ignored). Each of seven focused Restore tests
executed exactly once. Format, 30 native Python contract tests, build-mode and
CLI installer contracts, strict default and native-feature Clippy, terminal
EINTR and HUP checks also passed.

The full workspace command used the debug profile with explicit target
`aarch64-apple-darwin`; it took 932.503 seconds on this cold-ish cache. This is
not the normal optimized package build and is not a normal-build speed result.
The durable core receipt is
`/Volumes/T7-repositories/chau7-next-parity-recovery-evidence-20261011/resume-20261013-1433/core-ace3659-v1/manifest.json`; it binds the exact helper SHA-256
`693eeb0edffade9d35fc74792077977df0efaa444f7e61cfd20e7bc336162941`.

The normal fast package passed for this exact source. The first
`bash scripts/bundle-macos.sh` run completed in 342.609 seconds; a second
same-source, warm-cache package run completed in 8.452 seconds. These are
individual execution observations, not build-time benchmarks. Both receipts
bind the same revision, tree and helper SHA-256. The package logs show all six
helper binaries and the app satisfying their designated code-signing
requirements. The first receipt is
`/Volumes/T7-repositories/chau7-next-parity-recovery-evidence-20261011/resume-20261013-1433/package-ace3659-v1/manifest.json`;
the latest package receipt is
`/Volumes/T7-repositories/chau7-next-parity-recovery-evidence-20261011/resume-20261013-1433/package-ace3659-warm-v1/manifest.json`.

Full local quality validation **PASSED** for this ACE-bound source in run
`quality-ace3659-v3`. The runner selected nine gates; all nine returned PASS
with `cached=false` and `attested=false`. It skipped only the two conditional
drift checks, `always-openapi-drift` and `always-generated-artifact-drift`, as
not applicable to the changed files. The v3 runner result JSON and manifest are
`/Volumes/T7-repositories/chau7-next-parity-recovery-evidence-20261011/resume-20261013-1433/quality-ace3659-v3/quality-local.log` and
`/Volumes/T7-repositories/chau7-next-parity-recovery-evidence-20261011/resume-20261013-1433/quality-ace3659-v3/manifest.json`; their hashes are recorded in the external docs proposal manifest.

The v3 `full-local-ci` result reports 4,586 macOS Swift tests, three skipped,
and zero failures. The `ios-app-tests` result reports 97 tests and zero
failures. The runner used the exact-head quality helper whose SHA-256 is
`d65b35f89abb37eea68ed3e996bb5ea94df463debc95db1a04bf22d960689b5c`; its
isolated `golangci-lint` is v2.14.0 built with Go 1.27.2, binary SHA-256
`7a6d5c7cb663bac7ae451407c0828ed4e19af2dcfc8ed0ec4ce5feb051439fbb`. The
source gate logs remain under the worktree's `.aeptus-cache/quality/outputs`;
the proposal records their paths and SHA-256 values only and does not copy the
raw logs.

The earlier exact-head negative attempts remain historical evidence. V1 had
one Swift `BoundedSocketWriterTests` length failure: 2,097,152 bytes received
instead of 2,097,160. A separate focused six-test run passed that case, but
does not establish the cause or a fix. V2 passed Swift (4,586 tests, three
skipped, zero failures) and the shared Rust suite, then its older linter failed
to decode Go 1.27.2 export-data version 5 with a maximum supported version of
4. The v3 run with the isolated, toolchain-matched linter passed; this does not
establish a cause or fix for the earlier socket-writer failure.

The first exact-head isolated normal-runtime attempt is negative. It
returned two restored tab UUIDs but found only one of the two required empty
fixture input sinks, so the runner stopped before any MCP mutation
(`writes_started=false`). Its graceful cleanup receipt records the app and
socket gone, a successful quit request, no forced signals, and unchanged prior
acceptance evidence. That ACE-bound v1 receipt remains negative and unchanged.
The ACE-bound v1 runtime attempt above remains negative and source-scoped.
The later 69461e… v2 attempt failed the strict geometry preflight before
state-changing MCP work; its separate cleanup verifier confirmed retirement
but did not establish a successful quit-request exit code. The geometry-aware
v4 helper was then peer-reviewed and used for the passing current-source v3
runtime run summarized above. These later runs do not revise the ACE v1
receipt.

The completed 21-row native sequence for source
`ace3659a4830d186ce9e273cfed275d006a2a250` returned 18 passes and three
failures after attempting every row. Its source-bound receipt is
`/Volumes/T7-repositories/chau7-next-parity-recovery-evidence-20261011/resume-20261013-1433/native21-ace3659-v1/native21-manifest.json` (SHA-256
`1f5b6e9b5260709d487f79abd5f40787fc6c22917d9d6536db1af1380d3c4133`). Software
Restore row 01 and Auto-device-failure Restore row 05 failed in the
LaunchServices wrapper before an app process launched. Both captured
`_LSOpenURLsWithCompletionHandler() failed with error -10810`.
The sanitized read-only launchd diagnosis is
`/Volumes/T7-repositories/chau7-next-parity-recovery-evidence-20261011/resume-20261013-1433/launchservices-stdout-diagnosis.json` (SHA-256
`e9e3f6a3bad8ac23f0bc94605d5216c16086ceb3d3c48c0446d17661076f68a6`); it binds
the matrix manifest and records `Operation not permitted` while opening each
external stdout path before app spawn. No app-level Restore outcome was
recorded, so these are failed fixture launches, not a demonstrated product
Restore failure. Software Settings row 14
failed because the existing settings fixture rejected `he` as an unsupported
native Settings language. Hebrew Accessibility row 21 passed. This is a
Settings-fixture locale mismatch; row 14 supplies no Hebrew Settings product
acceptance result. The ACE-bound matrix remains a historical 18/21 result with those three
negative observations; it is not the current-source result. The current
69461e… strict native sequence passed all 21 rows, without altering the ACE
receipt or supplying Hebrew Settings product evidence for that earlier row.

A separate `real-profile-log-audit.json` examined a 2,000-line tail and found
zero errors and one notification warning. The installed log itself has an
October 11 timestamp, so this is not runtime evidence for `ace3659a`. The current-source strict native matrix is complete at 21/21. A passing
isolated normal-package runtime, the physical Mac and the real integration
checklist remain open.


### Previous local validation checkpoint: `c6ccad2e` (2026-10-13)

Source c6ccad2e4df1a8ed40378b95b5814acf5d0ad2fa passed all nine compiler/package
stages, 3,042 Rust tests (two ignored), seven focused feature tests and ten local
quality gates. The first full quality run had one unchanged Swift FileMonitor
startup-ordering timeout. Its old `/private/tmp` output and receipt are
unavailable in this resumed workspace. The historical record says all 13
focused FileMonitor tests and the full rerun passed: Swift build, 4,586 tests, three skipped, zero
failures. The warm normal build took 65.931 seconds on this execution; this is
an observation, not a benchmark.

All 21 strict native rows passed across Software, injected Metal device failure,
settings languages/number formats and accessibility. The legacy single-settings
child wrapper reports an incomplete four-case matrix; the 21-case aggregator
separately validates the actual requested settings row, exact locale/number
evidence and native frames. It records those child exit statuses transparently.
Both Editor fixtures report that real OS IME input-source automation is false;
these passes do not explain the earlier intermittent composition failure.

The sealed normal package passed exact 68-byte isolated terminal input and
graceful app/child quit. Its performance export validated 1,477 finite values,
16 timers and two Software windows with 12 and 5 submitted frames and zero
failures. These samples establish access and measured counters, not speed
thresholds. No provider or remote device was contacted. These C6 outcomes and
the earlier quality timeout remain historical summaries. Their associated
`/private/tmp` acceptance receipts are unavailable in this resumed workspace,
so the claims were not independently revalidated here. The physical Mac and real
integration checklist remains open.

### Previous local validation checkpoint: `07098279` (2026-10-13)

Source `07098279263c086a7b639bdc5ba94b8485506991` passed all nine
compiler/package stages, 3,042 Rust tests (two ignored), seven focused
feature tests and ten local quality gates. Swift validation passed its build
and executed 4,586 tests (three skipped, no failures).

The sealed normal package runtime read 1,783 finite values and 16 timers.
The process CPU sample was available, and both Software windows reported
13 and 5 submitted frames with zero failures. The owned diagnostics directory was verified, and
the app and child quit gracefully.

Strict native Software acceptance passed 4/4. The first Auto-device-failure
run passed 2/4; the unchanged binary passed 4/4 on a fresh repeat. The
marked-text failure is intermittent in these runs; the repeat does not
identify its cause or demonstrate a fix. The full 21-case native sequence
remains open.

The fixture-only follow-up requests owned GPUI foreground activation and
adds editor focus/window-context diagnostics using the existing 96-entry
cap. It awaits compilation and native verification and changes no
production IME behavior. Complete native acceptance and the physical Mac checklist remain
open.

### Previous local validation checkpoint: `51c9e761` (2026-10-13)

Source `51c9e761e43a51ce3a0558464b30f7973b8ee7f1` passed all nine
compiler/package stages, 3,042 Rust tests (two ignored), seven focused
feature tests and ten full local quality gates. Swift validation passed its
build and executed 4,586 tests (three skipped, no failures). The normal
optimized build took 51.4346 seconds with a warm cache. This is an
observation, not a benchmark.

The sealed normal package passed an owned runtime check: the exact 68-byte
input was observed, the existing tab inputs remained unchanged, and no provider
or device was contacted. Performance validation checked 1,684 numeric values,
confirmed CPU samples and counters from both Software windows (11 and 5
submitted frames, zero failed), and read 16 timers. The owned diagnostics
directory was verified; the app and owned child quit gracefully without forced
signals. These checks validate access to runtime data and clean retirement, not
performance thresholds or a benchmark.

The 21-row native-only sequence stopped during the Software matrix. Settings,
Editor and Cache passed. Restore failed with `owned window has no rendered
accessibility tree`; all owned fixture processes retired. Auto, locale and
accessibility cases were not launched. This identifies a fixture activation
and accessibility-tree gap. It does not establish a production application
defect or explain the earlier delayed stall. A follow-up fixture change bootstraps a real
NSView accessibility tree before repeating the strict Restore baseline;
its compiled and native validation is pending.

The source retains blank and clustered text borrowing, bounded
`cpu_glyph_cache_release` and `cpu_bitmap_cache_reclaim` spans in the
performance snapshot, diagnostic-build CTO filter bypass, and stage/status/
bounded-stderr details for stdio failures. Cache byte/item values are
pre-release cached weight, not RSS or memory actually freed. The Python 3.15
CI failure remains unresolved until new exact-head CI evidence exists. The
[parity workflow run 38391863656](https://github.com/Aeptus/chau7/actions/runs/38391863656)
passed. The [Quality run 38391863489](https://github.com/Aeptus/chau7/actions/runs/38391863489)
and [platform matrix run 38391863625](https://github.com/Aeptus/chau7/actions/runs/38391863625)
are still in progress.

Complete native and physical acceptance remain open. The previous local and
published checkpoints are retained below.

### Previous local validation checkpoint: `916bbfd8`


Source `916bbfd8a0d8266a587cdfed187066379ca2d2df` passed all nine
compiler/package stages, 3,042 Rust tests (two ignored) and ten full local
quality gates. The Swift build passed and its suite executed 4,586 tests,
with three skipped and no failures. The normal optimized build took 77.382
seconds with a warm cache; this is an observation, not a benchmark.

The sealed normal package also passed isolated 68-byte Unicode MCP input
and graceful quit with its owned fake-shell child. No provider or device was
contacted; the original delayed-stall cause remains unproven.

This source borrows blank and clustered painted text and exposes bounded
`cpu_glyph_cache_release` and `cpu_bitmap_cache_reclaim` work through the
existing performance snapshot. Their byte counts measure cache weight,
not process memory released. Diagnostic builds bypass CTO filtering so
compiler output remains available. The stdio test now identifies response
stage, child exit status and a bounded stderr tail; CI retains failure logs.
The Python 3.15 CI failure remains unresolved until new CI evidence exists.

Ten native driver unit tests passed on that checkpoint. Restore activation
uses an owned bundle handshake and exact PID verification. The follow-up
fixture requires final foreground/key-window state and measured rendered
frames after deminiaturization; its compiled and native validation is pending.
Complete native and physical acceptance remain open. The previous published
checkpoint is retained below.

## Published checkpoint and open acceptance (2026-10-13)

Published source `84f82eb302e45b84f7c7eb0ca55eabccaf946767` preserves settings
scroll deadlines for subpixel layout changes. Local validation passed 3,037
Rust tests (two ignored), all nine compiler/package stages and ten separate
full-quality gates. The normal optimized build took 61.133 seconds with a warm
cache. The separate diagnostic build took 321.243 seconds with a cold cache.
These are individual observations, not a comparative build-speed benchmark.

The macOS, Linux, Windows and parity checks passed. General Quality CI failed
in the Python stdio MCP test on Python 3.15; its existing five-second response
deadline expired without identifying the request stage. The local quality run
passed on its separate Python environment. This is an unresolved CI failure.

The [macOS artifact from run 38374191149](https://github.com/Aeptus/chau7/actions/runs/38374191149/artifacts/11801801582)
was locally verified for arm64, seven executable hashes and strict signatures.
Its recorded revision is PR merge commit `3371f885b871642d827306188bd752e6b7b64142`,
with parents main `7733b1f0` and PR head `84f82eb3`. Its tree
`318fa7f3c35540fd9560e525fca674f00f42a153` equals the validated local tree.
The artifact was not installed or launched; the GitHub outer digest was not
independently verified.

Fresh diagnostic app copies passed read-only startup and graceful quit on GPU
and Software. The Software copy also passed two owned fake-shell children,
an exact 68-byte Unicode input, four read-only MCP exports after 305 seconds
and graceful quit in 0.386 seconds. Performance exports contained finite
numeric values, actual Software frames, timer inventory and watchdog data.
This diagnostic result does not establish a fix for the earlier fast-app
stall. That old process is now absent but its socket remains; clean graceful
retirement was not verified.

A fresh isolated copy of the sealed fast package also passed the same exact
68-byte input, four read-only exports after 305.001 seconds and graceful quit.
Both fake-shell children and the MCP socket were gone afterward. It used no
provider or device, performed no build and sent no forced app signal. This
independent reproduction does not establish the cause or a fix for the older
stall or replace that package's incomplete retirement evidence.

An independent native Software matrix passed Settings, Editor and Cache.
Restore failed the strict foreground/key-window requirement after
programmatic deminiaturization, although the window and both terminal
surfaces were visible and drawing live frames. The sequence stopped before
Auto, locale and accessibility cases. Keep this negative evidence and all
existing deadlines. The complete native matrix and physical Mac checklist
remain open; inventory completion below means implementation coverage.

## Earlier validated application checkpoint (2026-10-13)

The earlier validated application source is `c842a2412be33b8bda24bd61eeeb4acd79eb5029`,
including the token-rate provider-label correction. Its workspace validation
passed 3,024 tests (two ignored). A normal optimized build took 58.159 seconds
with a warm cache; this is one observation, not a build-speed benchmark. Five
checks passed for that PR head: macOS, Linux, Windows, Quality gates
and parity.

The published `Chau7-Next-macOS-arm64` artifact is [artifact 11787133890 from
workflow run 38341562278](https://github.com/Aeptus/chau7/actions/runs/38341562278/artifacts/11787133890).
Its package revision is PR merge commit `7ef81c7e4ac83398dfd60ee637f4ea2b37ccc241`
(tree `acffc43bdb669379507f91756335a94565d25672`), built for PR head `c842a241`
and base `7733b1f0`; the package revision is not the PR head. Local validation
confirmed the arm64 bundle, hashes for all seven executables and strict bundle
signatures. The GitHub outer artifact digest was not independently verified.

Scoped runtime checks used an isolated copy of that artifact. Active text
replay v16 passed: after a graceful first quit, the fixture selected the target
tab in its own saved restore bundle, and a second process read the marker from
the live terminal buffer using read-only MCP. `style_replay_verified=false`;
this does not verify normal UI selection persistence or styled-text replay.
Visual grouping v8 passed with repo-A=2, repo-B=1 and one ungrouped seed tab.
A read-only performance export contained 1,365 finite values and 17 timers
(16 active, one inactive). All owned fixture processes and profiles were
retired.

These scoped passes do not establish a cause or fix for the earlier
intermittent Editor composition loss. Physical IME, multi-display, full
VoiceOver, real providers and paired devices remain manual checklist items.

## Source baseline and interpretation

Current comparison baseline: official `Aeptus/chau7` main
`7733b1f0c4440c0193915b036c38d5b83f31a1b3` (2026-10-11). Next baseline:
`3e1639a85fe9bb7a4cc9873996b8fade14525ac4`, before the current parity batches.
The original 1,175 rows described the April Swift app. Its 99% result is an
historical result, not evidence of parity with current Chau7. The current-source
audit appends delta rows and revises changed rows without changing their IDs.

`done` means implementation evidence exists. It does not mean the complete Mac
hand-test checklist has passed. Packaging, launch and MCP checks establish a
smaller validation scope. Platform-specific limitations remain explicit.

Parity is defined row by row in [`inventory/`](inventory/README.md): one file
per Swift module, one row per feature a user can see or rely on. A module is at
parity when all its rows are `done`, `n/a` or `dropped`. Only the user marks a
row `dropped`.

The table below is generated from those files; do not edit it by hand. After
changing a row's status, run:

```bash
apps/chau7-next/scripts/parity.py --write
```

CI runs `parity.py --check`, which fails on malformed rows, repeated IDs, or a
stale table.

<!-- parity:begin -->
<!-- Generated by apps/chau7-next/scripts/parity.py --write. Do not edit. -->

| Module | Wave | Rows | done | partial | missing | n/a | dropped | Left with macOS APIs |
|---|---|---|---|---|---|---|---|---|
| [AI](inventory/AI.md) | 2 | 17 | 17 | 0 | 0 | 0 | 0 | 0 |
| [Analytics](inventory/Analytics.md) | 3 | 8 | 8 | 0 | 0 | 0 | 0 | 0 |
| [App](inventory/App.md) | 1 | 85 | 83 | 0 | 0 | 2 | 0 | 0 |
| [Appearance](inventory/Appearance.md) | 1 | 16 | 16 | 0 | 0 | 0 | 0 | 0 |
| [CLI](inventory/CLI.md) | 3 | 3 | 3 | 0 | 0 | 0 | 0 | 0 |
| [Chau7Core](inventory/Chau7Core.md) | per row | 76 | 73 | 0 | 0 | 3 | 0 | 0 |
| [Commands](inventory/Commands.md) | 1 | 42 | 42 | 0 | 0 | 0 | 0 | 0 |
| [Dashboard](inventory/Dashboard.md) | 3 | 8 | 8 | 0 | 0 | 0 | 0 | 0 |
| [DataExplorer](inventory/DataExplorer.md) | 4 | 6 | 6 | 0 | 0 | 0 | 0 | 0 |
| [Debug](inventory/Debug.md) | 5 | 27 | 27 | 0 | 0 | 0 | 0 | 0 |
| [Editor](inventory/Editor.md) | 4 | 15 | 15 | 0 | 0 | 0 | 0 | 0 |
| [Events](inventory/Events.md) | 2 | 10 | 10 | 0 | 0 | 0 | 0 | 0 |
| [History](inventory/History.md) | 2 | 17 | 17 | 0 | 0 | 0 | 0 | 0 |
| [Keyboard](inventory/Keyboard.md) | 1 | 70 | 69 | 0 | 0 | 1 | 0 | 0 |
| [Localization](inventory/Localization.md) | 5 | 9 | 9 | 0 | 0 | 0 | 0 | 0 |
| [Logging](inventory/Logging.md) | 5 | 30 | 28 | 0 | 0 | 2 | 0 | 0 |
| [MCP](inventory/MCP.md) | 3 | 63 | 63 | 0 | 0 | 0 | 0 | 0 |
| [Migration](inventory/Migration.md) | 5 | 6 | 6 | 0 | 0 | 0 | 0 | 0 |
| [Monitoring](inventory/Monitoring.md) | 2 | 24 | 24 | 0 | 0 | 0 | 0 | 0 |
| [Notifications](inventory/Notifications.md) | 2 | 45 | 45 | 0 | 0 | 0 | 0 | 0 |
| [Observability](inventory/Observability.md) | 3 | 5 | 5 | 0 | 0 | 0 | 0 | 0 |
| [Overlay](inventory/Overlay.md) | 1 | 121 | 118 | 0 | 0 | 3 | 0 | 0 |
| [Performance](inventory/Performance.md) | 1 | 18 | 14 | 0 | 0 | 4 | 0 | 0 |
| [Profiles](inventory/Profiles.md) | 1 | 20 | 20 | 0 | 0 | 0 | 0 | 0 |
| [Proxy](inventory/Proxy.md) | 3 | 22 | 22 | 0 | 0 | 0 | 0 | 0 |
| [Remote](inventory/Remote.md) | 3 | 34 | 33 | 0 | 0 | 1 | 0 | 0 |
| [Rendering](inventory/Rendering.md) | 1 | 7 | 4 | 0 | 0 | 3 | 0 | 0 |
| [Repository](inventory/Repository.md) | 2 | 19 | 19 | 0 | 0 | 0 | 0 | 0 |
| [Runtime](inventory/Runtime.md) | 3 | 33 | 33 | 0 | 0 | 0 | 0 | 0 |
| [RustBackend](inventory/RustBackend.md) | 1 | 62 | 58 | 0 | 0 | 4 | 0 | 0 |
| [Scripting](inventory/Scripting.md) | 3 | 15 | 15 | 0 | 0 | 0 | 0 | 0 |
| [Settings](inventory/Settings.md) | 1 | 145 | 142 | 0 | 0 | 3 | 0 | 0 |
| [Skills](inventory/Skills.md) | 3 | 6 | 6 | 0 | 0 | 0 | 0 | 0 |
| [Snippets](inventory/Snippets.md) | 1 | 37 | 37 | 0 | 0 | 0 | 0 | 0 |
| [SplitPanes](inventory/SplitPanes.md) | 1 | 27 | 27 | 0 | 0 | 0 | 0 | 0 |
| [StatusBar](inventory/StatusBar.md) | 5 | 17 | 16 | 0 | 0 | 1 | 0 | 0 |
| [Telemetry](inventory/Telemetry.md) | 3 | 24 | 24 | 0 | 0 | 0 | 0 | 0 |
| [Terminal](inventory/Terminal.md) | 1 | 68 | 66 | 0 | 0 | 2 | 0 | 0 |
| [TokenOptimization](inventory/TokenOptimization.md) | 3 | 24 | 23 | 0 | 0 | 1 | 0 | 0 |
| [Usage](inventory/Usage.md) | 3 | 8 | 8 | 0 | 0 | 0 | 0 | 0 |
| [Utilities](inventory/Utilities.md) | 1 | 13 | 7 | 0 | 0 | 6 | 0 | 0 |
| [Views](inventory/Views.md) | 5 | 7 | 7 | 0 | 0 | 0 | 0 | 0 |
| **Total** | | **1309** | **1273** | **0** | **0** | **36** | **0** | |

Finished (done, n/a or dropped): 1309 of 1309 rows (100%). Partial: 0.

<!-- parity:end -->

"Left with macOS APIs" counts unfinished rows that rely on a macOS-only API;
port those behind a platform trait (see `AGENTS.md`).
