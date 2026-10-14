# Chau7 Next: handoff

## Current release status (2026-10-14)

The Rust/GPUI production transition is in preparation. The published stable
Chau7 app remains the SwiftUI/AppKit build; PR #229 is still a draft and no Rust
production release is claimed. The documentation baseline is feature source
`21a57d003f2a85897430f7139d8c60f15e11aaf5`. Historical checks below are tied
to their own source revisions and do not validate this baseline or authorize a
release.

The parity inventory records implementation coverage, not complete release
acceptance. Exact-source release-candidate evidence, physical Mac acceptance,
real-service integration, and migration acceptance remain open. See
[DUAL-SHIP.md](DUAL-SHIP.md), [PARITY.md](PARITY.md), and the
[production release guide](PRODUCTION-RELEASE.md).

## Historical checkpoint reported 2026-10-14 (unverified here)

A previous handoff reported that application source `f79eda39` passed the 17
core checks, 21-case native matrix, both native keyboard selectors, normal fast
package, and isolated normal runtime. It also reported the ruler-triggered
marked-composition fix, grouping, restore, and CPU-painter printing coverage.
The referenced raw receipts are not available in this worktree, so this
historical checkpoint is not independently verified here and does not validate
the documentation baseline above. See [PARITY.md](PARITY.md) for the preserved
historical report and its caveats.

The historical report also recorded 1,309 inventory rows complete, with
physical Mac and real-service acceptance still open. Synthetic AppKit input was
not physical IME coverage, fake-shell metrics were not provider throughput, and
no app installation, production relaunch, real provider, or paired-device
contact occurred during that work.

Read this first when picking up Chau7 Next (the Rust/GPUI port of Chau7).
Last updated 2026-10-14.

## 1. Where things are

| What | Where |
|---|---|
| Code, on the current Aeptus base | `Aeptus/chau7`, branch `feat/chau7-next`. Source branch `schiste/chau7:feat/chau7-next-aeptus` was copied at `25c3acde` with all 14 commits preserved |
| The app | `apps/chau7-next/` (`crates/chau7_next` GPUI app, `crates/chau7_next_core` pure logic, MCP bridge crate, `scripts/`) |
| Plan for running both apps side by side | `docs/rust-port/DUAL-SHIP.md` |
| Feature inventory and status | `docs/rust-port/inventory/` (one file per Swift module), summary `docs/rust-port/PARITY.md` |
| What changed when moving to the Aeptus base | `docs/rust-port/REBASE-ON-AEPTUS.md` |
| How the port was built with agents | `docs/rust-port/AGENT-PLAYBOOK.md` |
| Older history (April base, not needed anymore) | `schiste/chau7`: PRs #5 (first app), #6 (inventory), #7 (full parity) |

## 2. First steps

1. Continue work on `Aeptus/chau7:feat/chau7-next` and draft PR #229. Keep
   the preview app isolated while the production transition is prepared. The
   current published stable app remains SwiftUI/AppKit until the exact-source
   release candidate and migration pass their gates. See [DUAL-SHIP.md](DUAL-SHIP.md),
   [PARITY.md](PARITY.md), and [PRODUCTION-RELEASE.md](PRODUCTION-RELEASE.md).
2. The push starts `.github/workflows/chau7-next.yml` (macOS, Linux,
   Windows). The macOS job uploads `Chau7-Next-macOS-arm64`. To run it:
   unzip, `xattr -dr com.apple.quarantine "Chau7 Next.app"`, open.
   Local build instead: `cd apps/chau7-next && ./scripts/bundle-macos.sh`
   (Rust, Xcode command-line tools, Go; Metal shaders compile at runtime).
3. Continue the existing draft PR [Aeptus/chau7#229](https://github.com/Aeptus/chau7/pull/229). Keep all parity work in that PR; it is not ready to merge.

## 3. Status

- This handoff's source baseline is `21a57d003f2a85897430f7139d8c60f15e11aaf5`;
  no test, build, package, or release result is claimed here for that exact head.
  Validation entries below are historical and remain scoped to their named source
  revisions. The `f79eda39` report above is unverified in this worktree because
  its raw receipts are unavailable. Inventory rows marked done describe
  implementation evidence, not release readiness; physical Mac and real-service
  acceptance remain separate.
- Previous application source `8c2ef35ec39c5c3a199a9f9b199cc5f85422f847`
  (tree `6c3424440386292c1e286af67d3f27027366d9b3`) passed all 17 core
  checks: 3,059 Rust workspace tests (two ignored), 150 shared-terminal tests
  (one ignored), 46 native Python contracts, seven focused Restore tests,
  terminal HUP and the actual seven-test EINTR filter. Six cursor-blink tests
  are included in the workspace total. All nine selected local quality gates
  passed; two conditional drift checks were skipped as not applicable. Full
  local CI reported 4,586 macOS tests (three skipped, zero failures) and 97
  iOS tests (zero failures); the focused 13 monitor tests overlap that run.
  The normal fast package passed in 4.212680584 seconds with the existing
  cache, a single observation rather than a build benchmark. See
  [PARITY.md](PARITY.md) for source-bound receipts.
- The owned 8c2 normal package passed isolated runtime acceptance: two tabs
  restored, a third created, exact 68-byte fake-shell input observed, and three
  Software windows reported 234 submitted frames with zero failures. Nine
  performance history records used the configured 5-second cadence at
  5.005–5.120-second intervals. Graceful
  quit completed ten phases and retired the owned app, socket and three fake-cat
  children without forced signals. PID-filtered WindowServer capture passed;
  visual review showed red synthetic text in both restored terminals and
  Welcome in the third window. No provider or device was contacted. The empty
  token-rate map is not a throughput result, and no CPU improvement is claimed
  for the cursor redraw change.
- Four separate source-bound native fixture extensions passed on 8c2: Restore
  with Software, Restore with injected Auto-device failure, and the
  supplementary keyboard case with both selectors. Restore reconstructed six
  tabs, including two selected PTYs and two split leaves, delivered two resume
  inputs without terminators or duplicates, and preserved exact styled
  scrollback and native reveal/focus. Both activation acknowledgements matched
  the same app PID/bundle; post-ack reveal measured three Software frames
  with zero failures. Keyboard fixtures dispatched Cmd+C,
  Ctrl+Tab and Cmd+D through `NSApplication.sendEvent` to fake PTYs: with no
  selection Cmd+C delivered byte 3, Ctrl+Tab changed the selected tab ID, and
  Cmd+D created two horizontal leaves and focused the new leaf. Each closed
  three owned PTYs. These four receipts are separate from the 21-row native
  matrix, which remains scoped to 8cae. The 8c2 fixture binary has the same
  SHA-256 as the 8cae binary; a tree comparison found only the two native
  validation Python scripts changed between those sources. The prior 8cae
  keyboard v2 attempt remains recorded as a negative wrapper result after
  teardown; the passing 8c2 v3 summaries are separate evidence. These fixtures
  exercise AppKit dispatch, not physical keys or the system input source.
- For that previous 8c2 checkpoint, no CI artifact or CI pass was claimed.
  Continue draft PR #229 and record the exact CI head and merge tree when
  available. Physical Mac hand-testing remains deferred until the automated
  validation is finished; no user hand-test results are claimed. Real provider,
  credential, trust and paired-device acceptance remain open.
- Previous validated application source `8cae8bdde42aa234ce7301c498e87dae6597aeb9`
  (tree `9f3eeac9448e98fc983e302255cfff5ac2065ddb`) passed all 17 core
  checks: 3,059 Rust workspace tests (two ignored), 150 shared-terminal tests
  (one ignored), 35 native Python contracts, seven focused Restore tests,
  terminal HUP and the actual seven-test EINTR filter. Six cursor-blink tests
  are included in the workspace
  total. All nine selected local quality gates passed; two conditional drift
  checks were skipped as not applicable. Full local CI reported 4,586 macOS
  tests (three skipped, zero failures) and 97 iOS tests (zero failures). The
  focused FileMonitor/DirectoryMonitor run passed 13 overlapping tests. The
  normal fast package passed in 41.146 seconds with the existing cache, a
  single observation rather than a build benchmark. See
  [PARITY.md](PARITY.md) for source-bound receipts.
- An owned copy of the 8cae normal package passed fixture runtime acceptance:
  two tabs restored, a third created, exact 68-byte fake-shell input observed,
  and three Software windows produced 117 frames with zero failures. Five
  persisted performance records used the configured 5-second cadence. Graceful
  quit completed ten phases and retired the owned app, socket and three fake-cat
  children without forced signals. No provider or device was contacted. This
  single run makes no CPU improvement claim for the cursor redraw change.
- The strict 21-row native matrix passed all 21 cases for `8cae8bdd`. The
  Editor case shows synthetic marked text surviving actual native frames;
  fixture receipts record OS input-source automation and clipboard access as
  disabled. This does not establish input from the selected macOS source,
  dead-key composition or physical IME delivery. One LaunchServices Software
  keyboard-fixture attempt executed the Cmd+C, Ctrl+Tab and Cmd+D assertions
  through `NSApplication.sendEvent` to fake PTYs: no-selection Cmd+C delivered
  ETX byte 3 and preserved the empty selection, Ctrl+Tab changed the selected
  tab ID, and Cmd+D created two horizontal leaves and focused the new leaf. It
  closed three owned PTYs and captured a real native surface image. The
  assertion outcome passed, but the outer wrapper receipt failed because its
  renderer-window sampling ran after fixture teardown (`window_count: 0`;
  `renderer frame samples are missing`). This is partial evidence, not a full
  keyboard case pass. An earlier Software attempt failed during fixture-window
  startup before assertions. Corrected cases were not run for 8cae;
  their separate 8c2 results are above. These fixtures exercise AppKit dispatch,
  not physical keys.
  Physical Mac hand-testing remains deferred until this validation work is
  finished; no user hand-test results are claimed. Real provider, credential,
  trust and paired-device acceptance remain open. See [PARITY.md](PARITY.md)
  for the source-bound matrix and keyboard receipts.
- Previous local source `5d35776c0c65825f49bc005ee3168fae23285c0e` (tree
  `be6a68ce39446bad269f69ca8d4b470f1b2a4277`) passed its own 17 core checks
  (3,053 Rust workspace tests), normal fast package, local quality, 21 native
  cases and isolated fake-shell runtime checks. Its diagnostic path, token-rate
  labeling and grouping results remain scoped to `5d35776c`; they are not
  reattributed to the current source. See [PARITY.md](PARITY.md) for that
  checkpoint's receipts. The separate `fe0af6cc` CI/runtime evidence also keeps
  its original source scope.
- Previous source checkpoint `69461e60cb6bb65fe1a764510519fff599018b60` (tree
  `859d2497fa1bdfeb0fce634999b915cdf5ec851e`) passed all 17 exact-head core
  checks: 3,051 workspace tests (two ignored), 150 shared-terminal tests (one
  ignored), 35 native Python contract tests, seven focused Restore tests run
  exactly once, terminal EINTR/HUP checks, format, build-mode and CLI installer
  contracts, and strict default/native-feature Clippy. Core receipt:
  `/Volumes/T7-repositories/chau7-next-parity-recovery-evidence-20261011/resume-20261013-1433/core-69461e60-v1/manifest.json`
  (SHA-256 `206179bbe4f67101bc73e08eaf6496e7892a1003919399edef34554093c7d2d4`).
  The same source passed normal fast packaging in 5.033 seconds with its
  current cache state; this is one observation, not a build-time benchmark.
  Package receipt:
  `/Volumes/T7-repositories/chau7-next-parity-recovery-evidence-20261011/resume-20261013-1433/package-69461e60-v1/manifest.json`
  (SHA-256 `af167986ad8447c01069b3c69b314c75b0ae97340b4f823bd8b598e792a43caf`);
  standard bundle receipt:
  `apps/chau7-next/target/bundle/Chau7-Next-aarch64-apple-darwin-fast.json`
  (SHA-256 `2115316bf63d0d770dbbfe0b0cc066b04402421c0539bb0c0a50864ac83af64c`).
  Source-69461e60 local quality passed all nine selected gates uncached and
  unattested; the two conditional drift gates were skipped as not applicable.
  The full local CI result reports 4,586 macOS Swift tests (three skipped,
  zero failures), and the iOS result reports 97 tests (zero failures). Focused
  FileMonitor/DirectoryMonitor tests passed. Quality receipt:
  `/Volumes/T7-repositories/chau7-next-parity-recovery-evidence-20261011/resume-20261013-1433/quality-69461e60-v1/manifest.json`
  (SHA-256 `820b32ce1cdb23d74f8f70ee437a400089c5257d3423c3393d41c1bd863a5bc5`);
  structured result:
  `/Volumes/T7-repositories/chau7-next-parity-recovery-evidence-20261011/resume-20261013-1433/quality-69461e60-v1/quality-local.log`
  (SHA-256 `61f8daca016bdf1b34a62b400b91ee34fe58768d135b90897e9afb32eab0b6ab`).
  The proposal records source log paths and hashes only; raw logs remain in the
  worktree. The source-69461e60
  native-parity fixture build passed in fast release mode with
  the `native-parity-fixture` feature. Receipt:
  `/Volumes/T7-repositories/chau7-next-parity-recovery-evidence-20261011/resume-20261013-1433/native-build-69461e60-v1/build-receipt.json` (SHA-256 `0bf4ba3c954cc7176a4694d11212b261c35211005ad6d20d9c07ab61b57842ec`), artifact SHA-256
  `47235c8b3bae1b227380f20a46eb1701c4bb8478724729723d2eaba33293287e`. The source-69461e60 strict 21-row native matrix passed all 21 rows. Its
  aggregate receipt is `/Volumes/T7-repositories/chau7-next-parity-recovery-evidence-20261011/resume-20261013-1433/native21-69461e60-v1/native21-manifest.json` (SHA-256 `ac451af55851470bb9232a317843c5cdbe8ad1ec501a91fb6f3171b8fdaff8cb`); it binds the
  same source, clean before/after state, and unchanged fixture binary. The
  first source-69461e60 normal-runtime v2 attempt failed a strict SavedWindow
  check: it expected y=20 and read back y=34 after macOS clamped the window to
  the visible frame. Launch included a read-only `runtime_info` query; the
  subsequent preflight stopped before state-changing MCP operations and did
  not write an MCP acceptance receipt. A separate cleanup verifier confirmed
  the app, socket and two sink-backed cats were gone, prior acceptance files
  were unchanged, and no forced signals were sent, but it recorded no quit
  exit code. The later geometry-aware v4 helper passed the complete isolated
  runtime flow; see PARITY.md for exact counters and hashes. The ACE-bound
  results below remain historical and do not validate this source.
- On the ACE checkpoint, normal fast packaging passed. `bash scripts/bundle-macos.sh`
  completed in 342.609 seconds on the first run and in 8.452 seconds on a
  second same-source, warm-cache run. These are run observations, not build-time
  benchmarks. Both receipts bind the same source revision, tree and helper
  SHA-256. Their logs show all six helper binaries and the app satisfying their
  designated code-signing requirements. The first receipt is
  `/Volumes/T7-repositories/chau7-next-parity-recovery-evidence-20261011/resume-20261013-1433/package-ace3659-v1/manifest.json`;
  the latest warm package receipt is
  `/Volumes/T7-repositories/chau7-next-parity-recovery-evidence-20261011/resume-20261013-1433/package-ace3659-warm-v1/manifest.json`.
  ACE-bound local quality passed in v3: all nine selected gates passed
  uncached and unattested; the two conditional drift gates were skipped as not
  applicable. The macOS Swift suite reported 4,586 tests, three skipped and
  zero failures; the iOS suite reported 97 tests and zero failures. The run
  used the isolated `golangci-lint` v2.14.0 built with Go 1.27.2. See
  [PARITY.md](PARITY.md) and its external evidence manifest for exact result
  paths and hashes; raw source gate logs were not copied into the proposal.
  V1's socket-writer Swift failure and v2's incompatible older-linter failure
  remain historical negative observations. The separate six-test socket-writer
  rerun does not establish a cause or fix. The first ACE-bound isolated normal-runtime
  attempt also failed before mutating MCP calls because only one empty fixture
  sink was available for two restored tabs; that v1 receipt remains negative.
  The separate 69461e… v2 attempt failed a strict SavedWindow geometry check
  before state-changing MCP work; its cleanup state was separately verified,
  but no full acceptance passed. The later source-69461e60 v3 runtime run passed
  the isolated MCP/input/performance/quit checks; physical Mac and real
  integration acceptance remain open. The latest ACE-bound strict
  native sequence attempted all 21
  rows and returned 18 passes and three failures (receipt SHA-256
  `1f5b6e9b5260709d487f79abd5f40787fc6c22917d9d6536db1af1380d3c4133`). Both
  Restore failures occurred before app launch: the LaunchServices wrapper
  logged `-10810`. The sanitized read-only launchd diagnosis receipt (SHA-256
  `e9e3f6a3bad8ac23f0bc94605d5216c16086ceb3d3c48c0446d17661076f68a6`), bound
  to the same matrix manifest, records `Operation not permitted` opening each
  external stdout path before app spawn. Settings row 14 rejected Hebrew (`he`) as unsupported
  by that fixture; Hebrew Accessibility row 21 passed. These ACE-bound results do not establish an app-level Restore failure or a
  Hebrew Settings product result. The later exact-head `69461e60` native matrix
  passed all 21 rows (aggregate receipt SHA-256 `ac451af55851470bb9232a317843c5cdbe8ad1ec501a91fb6f3171b8fdaff8cb`); this does not
  change the earlier ACE receipt. The source-69461e60 v2 normal-runtime
  attempt later failed the strict geometry preflight; its cleanup state was
  separately verified without a quit-request exit code. The peer-reviewed v4
  helper (SHA-256 `b08bc8894656bf5ce947a0632527e414be504a1dd089f758f7b611ae98dd126c`)
  then passed source-69461e60 v3 runtime acceptance. Exact receipts and observed
  performance fields are documented in the previous-source checkpoint in PARITY.md; these
  results remain scoped to source 69461e60 and do not rewrite ACE history.
  A separate 2,000-line installed-profile-log audit found zero errors and one
  notification warning, but the source log is dated October 11 and does not
  validate runtime behavior on `ace3659a`. The previous validated source was
  `69461e60cb6bb65fe1a764510519fff599018b60` (tree
  `859d2497fa1bdfeb0fce634999b915cdf5ec851e`) and passed all 17 core checks
  plus normal fast packaging. Source-69461e60 local quality passed, and the strict
  native matrix passed 21/21. Source-69461e60 isolated normal-runtime v3
  acceptance also passed; previous ACE receipts do not validate it.
- Previous local checkpoint `c6ccad2e` passed its nine compiler/package
  stages, 3,042 Rust tests (two ignored), seven focused tests and ten quality
  gates. Its Swift rerun passed 4,586 tests (three skipped, zero failures), all
  21 strict native rows passed, and its sealed normal package passed the
  isolated input/runtime checks listed in PARITY.md. These are historical C6
  summary claims, not current application-source results. Their associated `/private/tmp`
  receipts are unavailable in this resumed workspace, so the claims were not
  independently revalidated here.
- Previous local checkpoint source `07098279` passed all nine compiler/package
  stages, 3,042 Rust tests (two ignored), seven focused feature tests and ten
  local quality gates. Swift build and tests passed: 4,586 executed, three
  skipped, zero failures. The sealed normal runtime read 1,783 finite values
  and 16 timers; the process CPU sample was available, and both Software
  windows reported 13 and 5 frames with zero failed frames. The owned app and child quit gracefully.
  Strict native Software acceptance passed 4/4. The first Auto-device-failure
  run passed 2/4; the same unchanged binary passed 4/4 on repeat. This makes
  the marked-text failure intermittent in these runs, without establishing a
  cause or fix. The full 21-case native sequence and physical Mac checklist
  remain open. The fixture-only follow-up requests owned GPUI foreground
  activation and adds capped editor focus/window-context traces. It awaits
  compilation and native verification; no production IME behavior change
  is claimed.
- Previous local checkpoint source `51c9e761` passed all nine compiler/package
  stages, 3,042 Rust tests (two ignored), seven focused feature tests and ten
  full quality gates. The Swift build and 4,586-test suite passed, with three
  skipped and no failures. Its normal optimized warm build took 51.4346
  seconds; this is one build observation, not a performance claim.
  The sealed normal package passed the exact 68-byte input check, preserved
  existing tab inputs, made no provider or device contact, and quit gracefully
  with its owned child. Performance validation checked 1,684 numeric values,
  sampled CPU data and Software counters for both windows (11 and 5 submitted
  frames, zero failed), validated 16 timers, and verified the owned diagnostics
  directory. These checks validate observability and clean retirement, not
  performance thresholds or a benchmark.
  The 21-row native-only sequence stopped during the Software matrix: Settings,
  Editor and Cache passed; Restore failed with `owned window has no rendered
  accessibility tree`. All owned fixture processes retired. Auto, locale and
  accessibility cases were not launched. A fixture bootstrap for a real NSView
  accessibility tree is being prepared before repeating the strict Restore
  baseline. This is a fixture activation gap, not evidence of a production app
  defect or an explanation for the historical stall. The bootstrap is not yet
  validated. Complete native acceptance and the physical Mac checklist remain
  open. The [parity workflow run 38391863656](https://github.com/Aeptus/chau7/actions/runs/38391863656)
  passed; the [Quality run 38391863489](https://github.com/Aeptus/chau7/actions/runs/38391863489)
  and [platform matrix run 38391863625](https://github.com/Aeptus/chau7/actions/runs/38391863625)
  remain in progress. The earlier Python 3.15 CI failure is not yet resolved.
- Previous local source `916bbfd8` passed all nine compiler/package stages,
  3,042 Rust tests (two ignored) and ten full quality gates. Swift build and
  4,586 tests passed (three skipped). Its normal warm build took 77.382
  seconds. At that checkpoint, follow-up Restore focus and measured
  post-deminiaturization frame assertions awaited validation; the 51 checkpoint
  above records the later fixture attempt. The earlier source's isolated
  68-byte MCP input and graceful quit are revision-scoped to `916bbfd8`.
- Published source `84f82eb3` passed 3,037 Rust tests (two ignored), nine
  compiler/package stages and ten local quality gates. Its macOS, Linux,
  Windows and parity CI checks passed, but general Quality CI failed the
  Python stdio response deadline. Fresh Software diagnostic runtime passed
  68-byte input, 305-second probes and graceful quit. A fresh fast-package
  copy subsequently passed that same isolated scenario and retired cleanly.
  Native Settings, Editor
  and Cache passed; Restore timed out on app activation/key status while its
  surfaces were visible and drawing. Full native and physical acceptance
  remain open. See the current checkpoint in [PARITY.md](PARITY.md).
- Preceding validated application source checkpoint is `c842a2412be33b8bda24bd61eeeb4acd79eb5029`
  (2026-10-13), including the token-rate provider-label correction. Its
  workspace validation passed 3,024 tests (two ignored); a normal optimized
  build took 58.159 seconds with a warm cache. This is one warm observation,
  not a build-speed benchmark. Five checks passed for the PR head: macOS,
  Linux, Windows, Quality gates and parity.
- The published `Chau7-Next-macOS-arm64` artifact is [artifact 11787133890
  from workflow run 38341562278](https://github.com/Aeptus/chau7/actions/runs/38341562278/artifacts/11787133890).
  It was built from PR merge commit `7ef81c7e4ac83398dfd60ee637f4ea2b37ccc241`
  (tree `acffc43bdb669379507f91756335a94565d25672`) for PR head `c842a241`
  and base `7733b1f0`; the merge commit is distinct from the PR head. Local
  artifact validation confirmed the arm64 bundle, all seven executable hashes
  and strict bundle signatures. The outer GitHub artifact digest was not
  independently verified.
- Scoped runtime checks used an isolated copy of that artifact. Active text
  replay v16 passed after the fixture selected its target tab in its saved
  restore bundle: phase two read the marker from the live terminal buffer using
  read-only MCP. `style_replay_verified=false`; this is not proof of normal UI
  selection persistence or styled-text replay. Visual grouping v8 passed with
  repo-A=2, repo-B=1 and one ungrouped seed tab. A read-only performance export
  contained 1,365 finite values and 17 timers (16 active, one inactive). All
  owned fixture apps and profiles were retired. Manual acceptance in section 6
  remains open; the earlier composition failure has no established cause or
  production fix.

- Preceding validated checkpoint `c8ede4d4662a3b38a25bfe6f4885978769454ab1`
  passed all nine fast compiler/package stages, ten separate full-quality gates
  and 3,023 Rust tests (two ignored). The normal build took 50.614 seconds with
  a warm cache. Software native acceptance passed 4/4; Auto with unavailable
  Metal passed Restore, Settings and Cache but failed Editor composition (3/4).
  The sequence stopped before locale and accessibility cases. The separate
  keyboard fixture passed. No cause or production fix is established for the
  composition loss between frame callbacks. All eight matrix apps retired.
- On c8ede4d, two-process deferred-tab MCP acceptance passed: known parked
  terminals returned blocked read-only readiness and empty buffer and PTY-log
  snapshots without starting the target shell or granting control. Saved
  tab/pane identity and styled scrollback persisted through two graceful quits;
  live emulator replay remains unverified. The normal package passed exact
  68-byte MCP input, active-child graceful quit, numeric validation of 1,868
  values and 16 persisted performance rows, and all five synthetic RunData
  checks. All owned test apps retired; no provider or device was contacted.
- Preceding fixture-only source `e0cd62d9761e1d76580adb47aa92f6b2c7c78300`
  (tree `6c01fea08b58eabfc7d7db69693bc50dd067c773`) passed commit operation
  1968 and publication operation 1969, five selected gates each. Its separate
  exact-head full-quality run passed ten gates in 136.210 seconds with the
  source clean before and after (log SHA256
  `0f52b8ced0c3cc8c3f649f39bfb142a633f8d322673345770d42af76fff6c49a`).
  The optional `native-parity-fixture` IME-diagnostic build then failed at
  `native_markdown/fixture.rs:433` with E0277: `?` was applied to the returned
  `FixtureStorageObserver` after `cx.update(...).map_err(error)`. The app was
  not launched, and there is no native diagnostic result for e0cd62d. This
  remains a historical pre-launch failure. On `4d8f55b1`, the corrected fixture compiled with Cargo exit 0, and its
  focused diagnostic case passed; the original binary-only DWARF check remains
  a preserved negative. The separate fast sequence passed all nine compiler
  stages and all 21 isolated native cases. That later trace does not establish a
  cause or production fix for the earlier composition failure.

Older checkpoint results below retain their original scope and do not replace
or weaken the preserved `4d8f55b1` checkpoint evidence.


- Exact source `baf03cb83fdc6925849e82e9345a4c443929339f` passed all nine
  compiler/package stages, separate ten-gate full quality, 3,019 workspace
  tests (two ignored), all 21 isolated native outcomes, and the separate
  keyboard fixture. Normal-package MCP input, numeric performance persistence,
  active-child graceful quit, and all five synthetic RunData stages passed.
  All seven PR checks passed. The normal optimized build took 39.319 seconds
  with a warm cache; no cold-build or speed-gain claim is made.
- An additional two-process normal-app test preserved its styled scrollback
  sidecar unchanged after both graceful shutdowns. It exposed a read-only MCP
  gap for existing deferred background tabs: lookup succeeded, but status and
  buffer output required a live terminal session and reported a missing tab.
  The follow-up recognizes those tabs without activating a shell or granting
  control. Status preserves blocked caller readiness; buffer output is empty
  until a terminal is attached, matching Swift. The c8 checkpoint above validates this
  correction with the parked-tab acceptance. Saved sidecar persistence does not prove second-process
  live emulator replay. All owned test app processes have retired.
- Source `d8a04d4944a36556bf3346390b497d11814bf402` passed five staged
  commit gates, five publication gates, ten separate full-quality gates and
  the exact optional keyboard-case unit test. Its fast workspace tests, normal
  strict Clippy, formatting and build/installer contracts passed. Native-feature
  Clippy rejected a redundant closure in the new fixture-only input-context
  trace. The nine-stage compiler sequence stopped at its first stage: no
  compiler seal, package or fixture launch was produced for this source.
  The follow-up correction passes the associated function directly and retains
  strict warnings. Fresh compiler and runtime validation remains pending.

- Follow-up source `0f40436372eb13684a09e9449e35b24aad8ad2eb` passed seven
  staged commit gates, nine full-suite publication gates and four Python parser
  tests. Its focused optional Rust unit-test compilation failed on two
  `Entity::read` calls receiving `AsyncApp` instead of `App` in the keyboard
  fixture. No fixture app was launched, and the nine-stage compiler sequence
  was not started. The follow-up source correction routes those two unchanged
  liveness assertions through `cx.update`; its exact unit test passed on d8a04d49.
- Earlier compiled checkpoint `ab64761304b0339cdace38413bed241432e7e1a7` (tree
  `9e6987d719189b415113e0fe1671aa9f52b46a4a`) passed all nine fast compiler
  stages and 3,019 workspace tests (two ignored). The isolated native Software
  matrix passed Restore, Settings and Cache (3/4); the Editor case observed the
  marked composition disappear between repaint frames. The runner stopped after
  this matrix, so Auto, localized Settings and the optional accessibility case
  were not attempted.
- GitHub workflow run `38313846802` reports its macOS, Linux and Windows matrix
  jobs successful for this exact source. Artifact metadata identifies
  `11776452820` at 29,556,237 bytes; the artifact was not downloaded or locally
  verified. Quality run `38313846806` and the three parity checks also passed.
  All seven expected checks succeeded; the three cancelled jobs belong to the
  redundant matrix run stopped by shared concurrency.
- The follow-up fixture-only diagnostic code extends the earlier 64-event
  trace to a 96-event bound. It records input-context identities, native frame
  geometry and attachment decisions, marked-state around existing frame
  setters, and pending mirror/focus state around existing focus delivery. It
  captures no source text and changes no production behavior, acceptance
  assertions or deadlines. This new source batch still needs compiler and
  runtime validation.
- The same batch adds an explicit-only `keyboard` native fixture.
  It installs the production keymap, app actions and native menus, then sends
  owned AppKit events for Cmd+C without selection, Ctrl+Tab and Cmd+D. Local
  fake shells record the exact interruption byte and prove two distinct split
  PTYs with focus on the new leaf. The original four-case default matrix and
  its assertions/deadlines stay unchanged. This fixture does not establish
  physical keyboard, dead-key or input-method behavior.
- Separate from that failure, the signed normal package selected Software for
  its live windows. MCP delivered the exact 68-byte input to a newly created
  third tab and left earlier tab input unchanged. The writer receipt reported
  accepted 1, completed 1, failed 0 and pending 0; the performance snapshot
  reported two Software renderer surfaces with zero failed frames and 16 active
  timers. Read-only metadata inspection confirmed the persisted snapshot and
  all 34 history records carry the ab647613 build SHA; this is not a benchmark.
- An owned `/bin/cat` child (PID 19542, parent app PID 19228) was present
  before the existing graceful-quit path ran once. Both processes were gone
  afterward; the observer used no process signals. A separate five-stage
  synthetic run-data sequence passed: a local owned fake `claude` executable
  produced one completed assistant turn (exit 0) with a unique marker; ten
  shutdown phases passed, and a read-only SQLite check matched the run and turn
  records. That isolated run made no network or provider/device contact.
  These scoped receipts do not establish physical input, VoiceOver, production
  provider behavior or a complete native matrix; the section 6 Mac checklist
  remains open.

- Earlier checkpoint: frozen source
  `afc66fa27460213c54e29c381e3fe50e08554ef2` passed nine commit gates and ten
  full-suite publication gates. Its fast workspace execution passed 3,019 tests
  (two ignored), normal strict Clippy, format and build/installer contracts.
  Native-feature Clippy failed because the accessibility fixture inferred a
  borrowed error type where an owned String was required; that sequence
  stopped before vendor/package/native stages and launched no fixture app.
  The later source revision and its exact compiler/native outcomes are recorded
  above. The afc failure remains historical and was not treated as a pass.

- Published docs revision `e4715bd23a50d033f306c6a3da6a2fb39c6cf35d`
  passed all seven reported PR checks, including macOS, Linux, Windows and
  quality CI. Next workflow run `38305507183` produced macOS artifact
  `11772693726`. The separate ten-gate local full-quality execution passed
  on that clean revision, including 4,586 Swift tests (three skipped) and iOS.
  These results apply to e471, not to subsequent source changes.
- A subsequent source audit found hardcoded English tab/timeline accessibility
  labels and the dashboard Timeline title. The follow-up batch routes them
  through the existing five-language Swift catalog and adds pure locale
  assertions. An optional app-local native accessibility fixture checks the
  rendered tab/slider tree and actual AppKit press/increment/decrement actions
  without changing system accessibility settings. It remains separate from
  the original Software/Auto matrix. The fixture compiled in the ab647613 gates,
  but its runtime case was not reached after the Software editor failure.
  VoiceOver speech/navigation and physical input still require the separate
  section 6 checklist.

- Frozen clean source `68294293c3cea30a565d9d300781fcac9a6586c8` passes all
  nine compiler stages and the strict native matrix: Software 4/4, Auto
  unavailable-device 4/4 and localized Settings 6/6. All 14 fixture PIDs and
  owned homes were retired. Its feature-free signed normal package selected
  Software for the whole window, passed exact 68-byte MCP input, exposed a
  performance snapshot and 16 active timers, and quit gracefully with three
  tabs saved and read-only SQLite `quick_check` passing. A separate isolated
  synthetic CLI run persisted one completed assistant turn, exit status 0 and
  a unique marker; ten shutdown phases, two saved tabs and independent
  post-quit row/turn verification passed. Neither run contacted a provider or
  device. PRF-002 is done for this scoped inventory behavior. Full `--full`
  quality and CI results for the final docs-only revision are not included in
  these receipts. The separate Mac hand-test checklist remains open; these
  results do not establish WindowServer independence or hot GPU-loss recovery.
  The inventory now reports 1,309/1,309 finished rows: 1,267 done, 42 n/a,
  zero partial, zero missing and zero dropped. This inventory count does not
  imply completion of the separate physical Mac checklist. The earlier b639
  marked-composition failure remains historical; no cause or fix is claimed.

- Historical combined source `feb5e199` passes 2,992 release workspace tests
  (two existing ignored), strict normal/optional all-target Clippy, format, 38
  macOS fork and 13 Apple tests, including seven actual Metal comparison cases.
  Its eight-case Software/Auto matrix records six passes and two failures:
  Software editor marked composition and Software Restore deminiaturized reveal.
  Both Settings cases pass the unchanged 500 ms limit. All eight
  actual processes/profiles retired; no retries or reinterpretation. These
  historical outcomes remain preserved in
  [RECOVERY-VALIDATION-20261011.md](RECOVERY-VALIDATION-20261011.md).
- Frozen source `d3df6a48` passes 3,017 Next tests, 539 helper tests,
  focused HUP and seven injected EINTR cases, strict Clippy, and all 36 macOS
  and 23 Apple vendor tests. Its atomic publication passed six hook gates;
  an explicit subsequent full-quality run passed ten gates, including Swift
  and iOS. These are separate executions on the same clean source.
- The signed normal d3df6a48 app runs two entire Software windows with zero
  failed frames, accepts exact Unicode input via MCP and saves three tabs on
  graceful quit. A separate local fake agent passes completed-run persistence
  and independent post-quit SQLite verification. Performance snapshots and
  16 active timer records are accessible via MCP.
- Native d3df6a48 Software Settings and Cache pass. Restore passes its data,
  split, PTY and resume checks but fails the final active/key-window reveal;
  Editor fails the ordinary keyDown text assertion after successful marked
  composition. All four native processes/profiles retired. PRF-002 remains
  partial pending the complete eight-case Software/Auto acceptance. Original
  outcomes and receipts are preserved in
  [RECOVERY-VALIDATION-20261011.md](RECOVERY-VALIDATION-20261011.md).
- The next combined source `2386e7e8` passes all nine compiler stages, with
  the canonical seal produced directly. Its native Software matrix passes
  Restore, Settings, Editor and Cache. Auto unavailable-device Settings,
  Editor and Cache pass; Restore times out waiting for the ordinary background
  Warm phase before pressure injection. All eight PIDs/profiles retired.
  No locale cases ran after the stopped matrix. The failing receipt lacks
  memory-state values; the next batch adds failure diagnostics with the same
  predicate and deadline. PRF-002 remains partial.
- Historical frozen source `ca46d51d5ab00ab4f913eed25246b87e192db26b` passes all nine
  compiler stages and the canonical seal. It passes 3,017 Next tests (two
  existing ignored), strict normal/native Clippy and format/contracts; vendor
  tests pass at 36 macOS and 23 Apple, and the helper workspace passes 539
  tests (three ignored) plus focused HUP and seven EINTR cases. The normal
  build, four fresh helpers, seven-artifact signed package, package verifier
  and optional fixture build pass. Native Software Restore, Settings and Cache
  pass; the Editor case observed marked composition disappear between repaint
  frames. All four fixture processes are gone and owned homes are removed. The
  complete Auto matrix,
  localized Settings cases and full-prepush quality did not run. A separate
  one-case Auto Restore probe passes but its aggregate is incomplete. PRF-002
  remains partial; see [RECOVERY-VALIDATION-20261011.md](RECOVERY-VALIDATION-20261011.md).
  Earlier diagnostic: a feature-gated, fixture-only 64-event AppKit trace was
  integrated in a follow-up source change, not included in the ca46 receipts.
  It records fixed sites and ranges/booleans without text, preserves superclass
  calls, and is diagnostic only; no cause or product fix is established. The
  current follow-up proposal is the separate 96-event trace described above;
  it remains uncompiled and unrun.
- Historical frozen source `b6394868425f65b91de0d7960e9940c78bb2af6e` passes all
  nine compiler/test/package stages. Its canonical compiler seal is
  `51313bfde37ef0dd89f224998b3c90a0e21730b4912d713166ac6d29f6c199ea`.
  The native Software cases pass Restore, Settings and Cache; the Editor case
  observed its marked range disappear between repaint frames. The mark is present
  before that frame and absent before style/attachment synchronization. No
  native unmark, responder or detach callback appears, and recorded app/window/
  responder focus remains valid. This narrows the interval but proves no cause.
  The run stopped on the Software Editor failure: Auto, localized Settings and
  full-prepush quality did not run. All four case processes and owned profiles
  retired. PRF-002 remains partial.
- The same source's signed, feature-free normal package opened two whole
  Software windows with zero failed frames. Its owned MCP acceptance appended
  exactly 68 bytes without a newline, left previous tab inputs unchanged, and
  increased the tab count from two to three. Graceful quit preserved all three
  tabs and passed read-only SQLite `quick_check`; telemetry Ready reported one
  accepted/completed write, zero pending and zero failed. Runtime output
  exposes numeric performance snapshots and 16 active timer records; these
  are observations, not a benchmark. A separate owned fake-Claude run persisted
  one completed assistant turn with exit status zero and a unique marker; its
  ten shutdown phases, two saved tabs, process/socket exit and post-quit
  `quick_check` passed. Neither run contacted a provider or device. Receipts
  are in `/private/tmp/chau7-fast-acceptance-luna-b6394868-normal-runtime`,
  `/private/tmp/chau7-fast-acceptance-luna-b6394868-run-data-v3` and
  `/private/tmp/chau7-fast-acceptance-luna-b6394868-native-sequence-fast-revision-v6`.
- A standalone stock `NSTextView` control provides a bounded comparison, not
  app or Japanese-IME acceptance. Its direct API mode retained the synthetic
  mark through two actual draw turns. The synthetic Option+E
  `NSApplication.sendEvent` mode produced no marked-text callback (and one
  insert callback); its JSON reports `success: false` and
  `input-context-did-not-produce-nonempty-mark`, despite process exit code 0.
  Treat the JSON status as authoritative. The control did not change the active
  input source and proves neither physical keyboard nor Japanese IME behavior.
  The first compile's default macOS 27.2 target failed to load its standard
  library; the preserved retry targeting macOS 13 with the installed macOS 27.0
  SDK compiled in 5.405 seconds; signatures passed. Both processes retired.
  Receipts are under `/private/tmp/chau7-marked-text-control-b6394868-v3`.
- Published source checkpoint `ee46222185ae4779b1a5e9ac1f0def13a21513ae`
  passes the release workspace, strict normal workspace Clippy, formatting,
  build-mode contract and CLI-installer contract checks. Strict native fixture
  Clippy stopped at four deprecated `msg_send!` argument-separator diagnostics;
  `-D warnings` makes them errors. Broker operation 1838 published the checkpoint
  after six normal prepush gates passed, and a subsequent gh check at operation
  1839 verified the PR head. Those publication gates do not change the native
  Clippy result: the compiler sequence stopped before the normal build, fresh
  package, optional fixture build or native acceptance, with no ee compiler
  seal or runtime result. Nine exact-gate receipt/log files are preserved in
  `/private/tmp/fast-ee462221-exact-gates-negative-20261012`; manifest SHA256 is
  `96c1052e45e53846ebd4f1b56218195ddfef74e02fe01d69223a3294cd5f536d`.
  The follow-up source batch corrects the four separators and adds idempotent
  layout reconciliation with bounded geometry assertions; the completed batch
  is covered by the later frozen `68294293` compiler/native acceptance above.
  Earlier b639 outcomes remain scoped to b639.
- The current-source audit indexes all 652 Swift source files at official main
  `7733b1f0`, appends the current feature delta and reopens changed behaviour.
  [PARITY.md](PARITY.md) is the current status, including missing features.
- First current parity batch: ordinary/restored repository grouping, complete
  grapheme painting, CTO recursion sentinel, Spanish/plural backend and macOS
  file-watcher recovery. Numeric performance exports are described in
  [PERFORMANCE.md](PERFORMANCE.md). Independent native hang sampling, bounded
  sampled metrics history, native Instruments intervals and memory retention
  are implemented. Native emoji/style acceptance passes at e8f32e6014b0;
  At checkpoint `4d8f55b1`, the scoped inventory was complete at 1,309/1,309
  rows (1,267 done, 42 n/a, zero partial, missing or dropped). The separate
  physical Mac checklist in section 6 remains open.
- Historical result against the **April 2026** Swift app: 1,174 of 1,175 inventory rows
  finished (1,129 done, 45 not needed in the Rust design). The one partial
  row was PRF-002. That historical limitation is superseded: Next now has a
  terminal CPU rasterizer and a working renderer switch. The complete software
  window backend now starts in an ordinary signed app;
  at that historical checkpoint, native resize/frame and injected-failure
  acceptance were open facets. The later `68294293` evidence is summarized at
  the top of this section.
- Rebased on `Aeptus/chau7` main (2026-10-09), with the coexistence rules
  updated for the newer Swift app (relay credentials, parent PID, prompt
  rules, per-tab history, Codex wrapper, attribution headers, CHG2 grid
  snapshots). See REBASE-ON-AEPTUS.md section 3.
- Checks on Linux: fmt, clippy `-D warnings`, about 2,200 Rust tests,
  `chau7_terminal` (C header byte-identical to Aeptus's), `chau7_optim`, Go
  agent (`-race`, golangci-lint), relay (`npm test`). macOS code type-checks
  (`scripts/dev/mac-typecheck.sh`). Three tests fail on Linux exactly as on
  untouched `aeptus/main` (a `/private/tmp` path, two need macOS `ioreg`).
- **A macOS Apple Silicon test bundle has now been built and launched.**
  Bundle/helper signatures, isolated startup, MCP initialization/tool list,
  graceful quit and session save passed on macOS 27.2. The full hand-test
  checklist below remains open. See [MACOS-TEST-PACKAGE.md](MACOS-TEST-PACKAGE.md).

## 4. Next work, in order

1. Follow the packaging and CI evidence in PR #229. The real Xcode failure
   on `37c51cc3` rejected `dsymutil --out-file`; the script now uses supported
   `-o output input`. Source contracts passed with an executable fake that
   requires the rejected option to exit 2 with its expected error. Real-symbol
   integration receipts remain separate from application acceptance evidence.
2. Complete the separate physical Mac checklist below, especially actual
   keyboard/dead-key/IME input, multi-display interactions, accessibility and
   real helper/provider integrations. The c842 active-text fixture reads its
   marker from a restored live terminal buffer only after selecting that tab in
   the fixture's saved restore bundle. Its `style_replay_verified=false` result
   does not establish normal UI selection persistence or styled-text replay.
   Isolated native fixtures and the fake local CLI run do not cover physical
   input or production integrations.
3. Keep the e0 E0277 and b639/ab647/c8 composition failures and their original
   diagnostics in recovery history. The `4d8f55b1` native matrix passed all 21
   cases; the c842 scoped runtime results are summarized above. No cause or
   production fix is established for the earlier composition traces. Preserve
   their receipts, assertions and deadlines.
4. Continue PR #229 and update this handoff only with evidence from the exact
   revision tested. Preserve prior negative receipts and the distinction
   between scoped fixture acceptance and manual acceptance.

The layout fixture validates an initial geometry result after the existing
composition/input/editor assertions finish, then takes a fresh post-preview
baseline for equal-bounds, one-pixel resize/restore and same-host detach/reattach
checks. A sibling-host reparent and an independent content-width-only change
with unchanged outer bounds are not covered. No performance gain or composition
cause/fix is claimed.

## 5. Approved decisions and retained behavior

- New installations default to 30 days. Existing settings/history are preserved,
  including explicit zero. Local factory resets respect installation policy.
- PRF-002 remains `done` for the scoped implementation and its accepted
  `68294293` evidence. The `4d8f55b1` native matrix passed all 21 cases,
  superseding the partial ab647613 Software-only run; the c842 scoped runtime
  checks are listed above. These results do not establish ordinary
  AppKit/WindowServer composition, hot GPU-loss recovery, normal saved UI
  selection persistence, styled-text replay or completion of the physical Mac
  checklist.
- Explicit Create Per-Repo Config retains Swift behavior. Automatic Next reads
  of repository `.chau7/` remain read only. No additional user decision is needed
  to continue the authorized parity work.

The inherited Swift URL handler observation remains present in the current
comparison source: `AppDelegate+URLScheme.swift` shell-quotes the SSH target but
does not reject leading options or ask for confirmation. Next rejects such
targets, uses `ssh --` and confirms. This observation is retained for the Swift
app; no current user decision or unsafe matching behavior is required for Next.

## 6. Hand-test checklist on a Mac

Run Chau7 and Chau7 Next at the same time for all of these, and check that
nothing new appears under `~/.chau7` or `~/Library/Application Support/Chau7`.

- **Basics:** typing, AZERTY Option keys (Option+5 types `[`, Option+B
  moves back a word), dead keys and IME, Cmd+C with no selection
  interrupts, Ctrl+Tab, tab drag between windows on two displays, splits,
  quit with running processes, relaunch restores tabs, splits, scrollback
  and `claude --resume` prefill.
- **System integration:** notification permission prompt and banners, Focus
  mode, Dock bounce and badge, menu bar item and its popover, launch at
  login, Keychain (LLM keys, SSH passwords), Services menu, Password
  AutoFill, printing, drag of a PNG from Safari, VoiceOver on the timeline,
  Increase Contrast, the HUD tab bar on light schemes.
- **Helpers in the bundle:** MCP bridge installed to `~/.chau7-next/bin`
  and registered as `chau7-next` in Claude Code, Codex, Cursor and
  Windsurf (the `chau7` entries untouched); Claude Code calling `tab_*`
  tools; API proxy on port 18090 while Swift's runs on 18080, certificate
  trust; token optimizer modes and `~/.chau7-next/cto_bin`; remote agent
  pairing (after credentials, see 4.3) with both apps showing as separate
  hosts; helper signatures (`codesign --verify --deep`).
- **AI CLI features:** Claude Code and Codex detection, hook events,
  "waiting for input" style, notifications on finish, dev server port
  badge, Explain This Error with a real provider.
- **Languages:** French, Spanish, Arabic (right to left), System Default; regional number format independent of UI language.

## 7. Prompt to start the next session (on `Aeptus/chau7`)

```text
Read docs/rust-port/HANDOFF.md, then AGENT-PLAYBOOK.md and
REBASE-ON-AEPTUS.md, on branch feat/chau7-next. Goal: full parity with the
CURRENT official Swift app, retaining the isolated macOS Chau7 Next package.
Check PARITY.md and current source baseline before choosing the next batch.
Recheck new findings against current sources and record evidence-backed
inventory changes. Do not infer physical Mac acceptance from scoped fixtures
or from the historical April percentage. Inspect current
Next logs safely and use PERFORMANCE.md for numeric diagnostic access.
Preserve running Next/Swift sessions and production restore data. Validate in
an isolated bundle/profile, continue PR229, and record actual Mac results.
Follow CLAUDE.md (Aethyme broker, commit format). No em dashes.
```
