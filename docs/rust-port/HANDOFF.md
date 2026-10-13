# Chau7 Next: handoff

Read this first when picking up Chau7 Next (the Rust/GPUI port of Chau7).
Last updated 2026-10-13.

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

1. The branch is now in the official repository: check out
   `Aeptus/chau7:feat/chau7-next`. The current goal is **full parity with
   current Chau7**, retaining the isolated macOS test app named **Chau7 Next**.
   The user expanded the packaging milestone on 2026-10-11. See
   [PARITY.md](PARITY.md) and [MACOS-TEST-PACKAGE.md](MACOS-TEST-PACKAGE.md).
2. The push starts `.github/workflows/chau7-next.yml` (macOS, Linux,
   Windows). The macOS job uploads `Chau7-Next-macOS-arm64`. To run it:
   unzip, `xattr -dr com.apple.quarantine "Chau7 Next.app"`, open.
   Local build instead: `cd apps/chau7-next && ./scripts/bundle-macos.sh`
   (Rust, Xcode command-line tools, Go; Metal shaders compile at runtime).
3. Continue the existing draft PR [Aeptus/chau7#229](https://github.com/Aeptus/chau7/pull/229). Keep all parity work in that PR; it is not ready to merge.

## 3. Status

- Latest application checkpoint `4d8f55b1b3db7c47109426222455c2236a7b70fa`
  passed nine compiler/package stages, 3,023 Rust tests (two ignored), ten
  separate full-quality gates, all six reported CI checks, all 21 isolated
  native cases and the separate keyboard fixture. Normal MCP/performance,
  five RunData stages and two-process deferred reads passed; live terminal
  replay remains unverified. All owned test apps retired.
- The subsequent packaging-only batch supplies a UUID-matched main-app dSYM
  beside diagnostic bundles, with its hash and tool paths in the metadata.
  Fast mode performs no symbol-tool work. Application Rust/Go source is
  unchanged from the checkpoint. Manual acceptance in section 6 stays open;
  the earlier composition failure has no established cause or production fix.

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
or weaken the latest `4d8f55b1` evidence.


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
   real helper/provider integrations. Also verify live terminal-emulator replay
   after restart: persisted styled scrollback and read-only deferred-tab
   responses do not prove that a restored emulator replays it. Isolated native
   fixtures and the fake local CLI run do not cover those physical or production
   integrations.
3. Keep the e0 E0277 and b639/ab647/c8 composition failures and their original
   diagnostics in recovery history. The later `4d8f55b1` native matrix passed
   all 21 cases, but no cause or production fix is established for the earlier
   composition traces. Preserve their receipts, assertions and deadlines.
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
  `68294293` evidence. The later `4d8f55b1` native matrix passed all 21 cases,
  superseding the partial ab647613 Software-only run. This scoped result does
  not establish ordinary AppKit/WindowServer composition, hot GPU-loss
  recovery, live post-restart emulator replay or completion of the physical
  Mac checklist.
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
