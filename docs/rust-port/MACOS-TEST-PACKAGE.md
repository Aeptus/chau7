# Chau7 Next macOS test package

## Validated local package (2026-10-14)

The current local fast package is built from application source `f79eda39`.
Its standard bundle is `apps/chau7-next/target/bundle/Chau7 Next.app` in the
parity recovery worktree. It is ad-hoc signed and has not replaced the user's
installed app. The package receipt records source, mode and all seven helper
binaries. The final PR publication adds documentation only to this application
source; CI artifacts retain their own source revision and receipt.

The verified local ZIP is
`resume-20261014-grouping-native/final-macOS-test-package/Chau7-Next-macOS-arm64-f79eda39.zip`
under the evidence root documented in [PARITY.md](PARITY.md). Its archive receipt
checks all seven binary hashes against the standard package receipt.

Application source `f79eda39efb53912fc30d502ee864e92986884c2` (tree
`3f8594d279748a99a2ad557a963c0f8610548e10`) passed all 17 core checks:
3,084 Rust workspace tests (two ignored), 151 shared-terminal tests
(one ignored), formatting, strict Clippy with and without native fixtures,
Python/build-mode/CLI contracts, focused restore tests, seven EINTR checks and HUP.
The 21-case native matrix and both supplementary native keyboard selectors pass.
They use one exact native build and isolated profiles, without real providers or
paired devices. These are AppKit event and injected-composition checks; physical
keyboard and system-input-source acceptance remain separate.

The normal fast package built in 44.526 seconds with the existing cache.
This is one warm build observation, not a benchmark. Fast is the default;
`BUILD_MODE=diagnostic` retains symbols and full compiler diagnostics when needed.
An owned copy passed restore, contiguous split-repository grouping, exact
68-byte MCP input, performance persistence and graceful shutdown. It saved three
tabs, completed all ten shutdown phases, retired its process/socket/fake shells,
and preserved prior acceptance data. The Software snapshot reported three windows,
39 submitted frames and zero failed frames;
16 timers were active. Token-rate data remained empty
because only fake shells ran. No live throughput or CPU-improvement claim is made.

The previous `3b4b37c0` matrix remains a 20/21 negative result. A later
`8b8cf053` diagnostic reproduced it and identified the ruler's first
`NSTextView.layoutManager` access triggering text-system reconfiguration and
`fixAttributes` during composition. `SourceTextView::new` now selects the layout
manager before content or focus. The original strict marked-text assertion passes;
text-checking defaults and the line-number feature remain intact.

Implementation inventory: 1,309 of 1,309 rows finished (1,277 done,
32 not applicable, zero partial). This measures implementation coverage. Physical
AZERTY/dead-key/IME input, VoiceOver, multi-display interaction, real OS services,
Keychain prompts, print dialogs/devices, live providers and paired remote devices
still need the Mac hand-test. The user has deferred that test until this autonomous
work is finished. Existing installed applications were not replaced or relaunched.

Package identity: an Apple Silicon macOS test app called **Chau7 Next**,
installed beside Chau7. The user has now requested full current Swift parity;
track that active work in [PARITY.md](PARITY.md) and [HANDOFF.md](HANDOFF.md). This is an ad-hoc signed test package, not a notarized release.

## Migration evidence

The official `Aeptus/chau7:feat/chau7-next` contains the source head
`25c3acde6e4e612f060247b0089d1b3f3b6c3fb3` without rewriting its history.
That source includes all of official main `7733b1f0` plus 14 port commits.
The initial import `ae9ec24d` matches the old parity branch exactly for
`apps/chau7-next`, `docs/rust-port`, `spikes/gpui-tabbar` and both Next
workflows. The first app and inventory branches are in the parity branch's
ancestry. The separate spike spec was retained with its status updated.
Shared helper and viewer changes were reapplied by intent, as documented in
[REBASE-ON-AEPTUS.md](REBASE-ON-AEPTUS.md).

## Previous local package and runtime validation (2026-10-13)

Source `8c2ef35ec39c5c3a199a9f9b199cc5f85422f847` (tree
`6c3424440386292c1e286af67d3f27027366d9b3`) passed the normal fast package
build in 4.212680584 seconds with the existing cache. This is one build
observation, not a performance benchmark.

An owned copy of the normal package passed isolated restore, MCP input,
Software-rendering, performance-persistence and graceful-quit checks. It
restored two fixture tabs, created a third, and observed the exact 68-byte
fake-shell input. Three Software windows submitted 234 frames with zero
failures. The configured 5-second performance cadence produced nine history
records at 5.005–5.120-second intervals, and the latest history entry
matched the persisted latest snapshot. Sixteen timers were active out of 17
records. The token-rate field was present
but empty because the fixtures used local fake shells.

Graceful quit returned zero and completed all ten shutdown phases. The owned
app, MCP socket and three fake-cat children retired without forced signals;
prior acceptance data was unchanged. No provider or device was contacted. A
PID-filtered WindowServer capture passed for the three owned windows. Visual
review showed red synthetic text in both restored terminal windows and the
Welcome window in the third; this is scoped to the isolated package run and
makes no physical-input claim. The cursor redraw change skips phase-change
notifications only while the exact paint focus handle is unfocused, and
restores the visible phase on focus regain. No CPU A/B measurement was run.

Four separate current-source native fixture extensions passed: Restore with
the Software renderer and with injected Auto-device failure, plus the
supplementary keyboard case with Software and Auto-device-failure selectors.
Restore reconstructed six tabs, including two selected PTYs and two split
leaves; it delivered two resume inputs without terminators or duplicates and
verified exact styled scrollback (`RESTORED_STYLE:é中❤️`) across worker
flush/reload together with native reveal and focus. Both activation
acknowledgements matched the same app PID and bundle; post-ack reveal measured
three Software frames with zero failures. The keyboard payload was
dispatched with `NSApplication.sendEvent` to fake PTYs: no-selection Cmd+C
sent exactly ETX byte 3, Ctrl+Tab changed the selected tab ID, and Cmd+D
created two horizontal leaves and focused the new leaf. Each run closed three
owned PTYs. The Auto-device-failure selector injected a renderer startup
failure and validated software fallback. Its summary records zero open windows
after the fixture closed its owned window before outer diagnostics; it validates
actual native CALayer/AppKit images and frames separately. The keyboard
supplement is not part of the existing 21-row native matrix, whose passing
receipt remains scoped to source `8cae8bdd`. These fixtures exercise AppKit
dispatch, not physical keys or a system input-source change.

The 8c2 native fixture binary built successfully with the `native-parity-fixture`
feature and has the same SHA-256 as the 8cae fixture binary. A recursive tree
comparison found 2,563 exact path/mode/type/object-ID matches out of 2,565
entries; the only changed paths are `apps/chau7-next/scripts/native-parity.py`
and `apps/chau7-next/scripts/test_native_parity.py`. This comparison does not
transfer the 8cae 21-row matrix result to 8c2. The earlier 8cae keyboard v2
attempt remains a negative wrapper result: its shortcut assertions ran, but
renderer sampling failed after fixture teardown with `window_count: 0`. The
current passing 8c2 keyboard v3 summaries are separate receipts and do not
erase that attempt.

The matching CI artifact is not linked yet. Follow the draft
[Aeptus/chau7#229](https://github.com/Aeptus/chau7/pull/229) for the package
and record the CI-reported PR head and merge commit/tree when it is published;
no CI pass is claimed for 8c2. Physical Mac hand-testing is deferred until
this automated validation work is finished. No user hand-test results are
claimed. Real provider, credential, trust and paired-device acceptance remain
open.

Evidence root:
`/Volumes/T7-repositories/chau7-next-parity-recovery-evidence-20261011/resume-20261013-1433/`

- `cursor-blink-review/package-8c2ef35e-v1/manifest.json` (SHA-256
  `c16de5a29b00f87408f3f3aad3f9d3d4c6aab8133e45a10859d45f1872b0a75a`).
- `normal-runtime/outputs/normal-8c2ef35e-v1/manifest.json` (SHA-256
  `7ca707022669906cb875aeb71d004be69de7e71453de7616be3dc6e2171b235b`).
- `normal-runtime/outputs/normal-8c2ef35e-v1/mcp-acceptance.json` (SHA-256
  `5e45b4fe066de6c2d22da0ae8d97fdf06f03a2c8e60542f430e53419c4f4f521`).
- `normal-runtime/outputs/normal-8c2ef35e-v1/quit.json` (SHA-256
  `a59bfe5dcea14273a2f0327ee1d3f08f91e262c140a76142cbd2ab2a74550ccd`).
- `normal-runtime/outputs/normal-8c2ef35e-v1/windowserver-capture.json`
  (SHA-256
  `44bcd389493f0865156dafc97ef4be61d902c59879156ba975cbf4ce4a985d29`).
- `cursor-blink-review/native-build-8c2ef35e-v1/build-receipt.json` (SHA-256
  `7e13e5451180a59a8df74549b55341951e8e9af1b2761c430b450cb616b1c7c6`);
  artifact SHA-256
  `5176e0a1ba73cf40d822738910ec98cde8b0ea59337f36a7835e669d0536610a`.
- `cursor-blink-review/native-restore-8c2ef35e-software-v1/manifest.json`
  (SHA-256 `aa23bd650572003686ba86ef786f44c91f79b74cec94a94f4e9e38dfe23a3f59`).
- `cursor-blink-review/native-restore-8c2ef35e-auto-device-failure-v1/manifest.json`
  (SHA-256 `44cd9b31f20efe2d4b827215c562145ed5c0679b0654a9049a7633b0f37f376e`).
- `cursor-blink-review/native-keyboard-8c2ef35e-software-v3/proposal-summary.json`
  (SHA-256 `f27fa897e4f4d008fba08a109f73eafe81b900812869daf262625336a57db419`).
- `cursor-blink-review/native-keyboard-8c2ef35e-auto-device-failure-v3/proposal-summary.json`
  (SHA-256 `12d6343a3f715641d96bc4a01884994b7a03a1601b250229c639e024ef3436b1`).

## Previous local package and runtime validation: `8cae8bdd` (2026-10-13)

Source `8cae8bdde42aa234ce7301c498e87dae6597aeb9` (tree
`9f3eeac9448e98fc983e302255cfff5ac2065ddb`) passed the normal fast package
build in 41.146 seconds with the existing cache. This is one build observation,
not a performance benchmark.

An owned copy of the normal package passed isolated restore, MCP input,
Software-rendering, performance-persistence and graceful-quit checks. It
restored two fixture tabs, created a third, and observed the exact 68-byte
fake-shell input. Three Software windows submitted 117 frames with zero
failures. The configured 5-second performance cadence produced five history
records, and the latest history entry matched the persisted latest snapshot.
The token-rate field was present but empty because the fixtures used local fake
shells.

Graceful quit returned zero and completed all ten shutdown phases. The owned
app, MCP socket and three fake-cat children retired without forced signals;
prior acceptance data was unchanged. No provider or device was contacted. The
cursor redraw change skips phase-change notifications only while the exact paint
focus handle is unfocused, and restores the visible phase on focus regain. No
CPU A/B measurement was run.

The strict 21-row native matrix for this source passed all 21 cases. The
Editor case shows synthetic marked text surviving actual native frames; fixture
receipts record OS input-source automation and clipboard access as disabled.
This is not evidence for the selected macOS input source, dead-key composition
or physical IME delivery. One LaunchServices Software keyboard-fixture attempt
executed the Cmd+C, Ctrl+Tab and Cmd+D assertions through
`NSApplication.sendEvent` to fake PTYs, including exact ETX byte 3, selected-tab
change, and a horizontal two-leaf split focused on the new leaf. The assertion
outcome passed, but the wrapper receipt failed while sampling renderer windows
after fixture teardown (`window_count: 0`; `renderer frame samples are
missing`). It is partial evidence, not a completed keyboard case pass. An
earlier Software attempt failed during fixture-window startup before shortcut
assertions. Corrected cases were not run for source `8cae8bdd`; their separate
8c2 results are recorded in the current section.
Physical Mac hand-testing is deferred until this validation work is finished.
No user hand-test results are claimed. Full local CI reported 4,586 macOS tests
(three skipped, zero failures) and 97 iOS tests (zero failures).

The matching CI artifact is not linked yet. Follow the draft
[Aeptus/chau7#229](https://github.com/Aeptus/chau7/pull/229) for the package
and record the CI-reported PR head and merge commit/tree when it is published;
no CI pass is claimed here. The older artifact below is historical and does
not contain this current source.

Evidence root:
`/Volumes/T7-repositories/chau7-next-parity-recovery-evidence-20261011/resume-20261013-1433/`

- `cursor-blink-review/package-8cae8bdd-v1/manifest.json` (SHA-256
  `25d743378edf1555c9ef84dc99de966381a04b669559b060287abf062f4fd631`).
- `normal-runtime/outputs/normal-8cae8bdd-v1/manifest.json` (SHA-256
  `6d2eb5979a3c1a9fa8c1d52038af79ce5312d6a4a396be47ad0e45234ea1877e`).
- `normal-runtime/outputs/normal-8cae8bdd-v1/quit.json` (SHA-256
  `0fbf07e6f12a790fd566109acc6504e3f263803ee793f8c74caadfcf2b48628b`).
- `cursor-blink-review/native21-8cae8bdd-v1/native21-manifest.json` (SHA-256
  `22f222890d47eef542fa1c6d5b8a047527c3446e1c6440c1fee14721e2c1bcaf`).
- `cursor-blink-review/native-keyboard-ls-8cae-software-v2/retry-record.json`
  (SHA-256
  `def05489074f54cb14aca8195376566e57ccb7db9218d3c888aa85ebf424bcef`; partial
  assertion success, outer renderer-sampling wrapper failed after teardown).

## Historical verified CI package checkpoint: `fd997ec5` (2026-10-13)

Download [`Chau7-Next-macOS-arm64`, artifact 11834575717 from run
38436092953](https://github.com/Aeptus/chau7/actions/runs/38436092953/artifacts/11834575717).
This older package checkpoint is for PR head `fd997ec51ce90519042636e864cf09ec910820dd`.
Its macOS, Linux, Windows, Quality gates and parity checks passed. GitHub built
the package from PR merge commit `2398fdfd5a9f74951e5794f17f56d969efa394f6`;
the merge and PR head have the same tree
`c51d4cfdf94c77ec7b7a7a18266cf91b567b5bad`.

Local verification confirmed all seven arm64 executable hashes and strict
signatures, the deep bundle signature, and GPUI license files. The downloaded
inner ZIP SHA-256 is
`211745fad124ca738866e09de950478f3f12a055e21c906fa410924d748bd215`.
The GitHub outer artifact digest was not independently verified. This CI
package was neither installed nor launched during that verification.

This artifact's application code is identical to the locally validated source
`69461e60cb6bb65fe1a764510519fff599018b60`; the subsequent changes were
documentation only up to fd997ec5. It does not include the later application
changes at 5d35776c. That earlier source passed 3,051 Rust workspace tests (two
ignored), 4,586 macOS Swift tests (three skipped), and all 21 strict native
fixture cases. A separately built, signed local package passed isolated MCP
input, restore/save, Software rendering, performance persistence and graceful
quit with three owned fake-shell tabs. Local and CI binaries are not claimed
to be identical. See [PARITY.md](PARITY.md) for receipts and exact scope.

### Inspect logs and performance

- Open **Help > Debug Console** or press **Option+Command+L**, then select
  **Logs** or **Perf**. Perf exposes the snapshot JSON, including token-rate
  readings when available.
- The main log is
  `~/Library/Application Support/Chau7 Next/chau7-next.log`.
- Persisted numeric reports are in `~/.chau7-next/reports/performance/`.
  They use Next's configuration root, which differs from the main log's
  Application Support directory. An isolated profile uses its own root.
- Through the `chau7-next` MCP connection, use `chau7_runtime_info` to identify
  the running build, `chau7_performance_snapshot` for measurements, and
  `chau7_timer_inventory` for active timers.

The isolated runtime check verified real process CPU/RSS, Software frame
counters and persisted snapshots. `token_rates_by_tab` was empty because the
fixture used local fake shells. This verifies access to diagnostics, without
establishing live provider throughput or performance thresholds. Missing token
rates mean unavailable data. The installed-profile log audited previously was
dated October 11, so it is not evidence for this package's runtime behavior.

### Acceptance still open for physical and system checks

The [Mac hand-test checklist](HANDOFF.md#6-hand-test-checklist-on-a-mac)
remains open. Physical user hand-testing is deferred until the current
validation work is finished; no user hand-test results are claimed. For source
`8cae8bdd`, the 21-row native matrix passed all cases, while its keyboard
supplement remained partial: one Software attempt reached and passed its
shortcut assertions but failed the wrapper's post-teardown renderer-window
sample, and an earlier attempt failed before those assertions. The four
separate 8c2 keyboard and restore extensions are recorded in the current
section; they are not backdated to 8cae. After this validation work, continue
with physical keyboard/IME, multi-display dragging and restoration,
accessibility, and system integration. Test real CLI registration, proxy trust
and relay pairing with your own integrations. The PR remains a draft until the
remaining checks have results; inventory completion and fixture passes do not
certify them.

## Historical c842 application artifact and scoped runtime checks (2026-10-13)

The validated application PR head is `c842a2412be33b8bda24bd61eeeb4acd79eb5029`,
which includes the token-rate provider-label correction. Five checks passed
for that head: macOS, Linux, Windows, Quality gates and parity. Its workspace
validation passed 3,024 tests (two ignored); one normal optimized build took
58.159 seconds with a warm cache. That is a single warm-build observation,
not a benchmark.

Download [`Chau7-Next-macOS-arm64`, artifact 11787133890 from workflow run
38341562278](https://github.com/Aeptus/chau7/actions/runs/38341562278/artifacts/11787133890).
The artifact was built from PR merge commit
`7ef81c7e4ac83398dfd60ee637f4ea2b37ccc241` (tree
`acffc43bdb669379507f91756335a94565d25672`), with PR head `c842a241` and base
`7733b1f0`. GitHub's PR build uses a merge commit, so the package's embedded
source revision is the merge commit rather than the PR head. Local artifact
validation confirmed the arm64 app bundle, hashes for all seven executables
and strict bundle signatures. The GitHub outer artifact digest was not
independently verified.

Separate isolated runtime checks used a copy of this artifact. Active text
replay v16 passed after the fixture selected its target tab in its saved
restore bundle; a second process read the marker from the live terminal buffer
using read-only MCP. `style_replay_verified=false`, so this does not establish
styled-text replay or normal UI selection persistence. Visual grouping v8
passed with repo-A=2, repo-B=1 and one ungrouped seed tab. A read-only
performance export contained 1,365 finite values and 17 timers (16 active,
one inactive). All owned fixture processes and profiles were retired. These
checks did not contact a real provider or paired device.

## Historical local package checked on 2026-10-11

Source revision: `edfe67aa649d0a5b00942148f3c279a1cc27643d`.
Host: macOS 27.2, Xcode 27.0, Rust 1.96.0, Apple Silicon.

- Release bundle build passed, with Go proxy and remote agent required.
- Display name and executable: `Chau7 Next`; identifier: `com.chau7.next`.
- Plist lint passed and `Chau7NextSourceRevision` matches the source commit.
- All six executable files are arm64 and pass strict signature verification;
  the whole bundle passes `codesign --verify --deep --strict`.
- Launched with `CHAU7_NEXT_HOME_ROOT` pointing to a fresh temporary profile;
  one terminal and the private MCP socket started successfully.
- The bundled bridge passed MCP initialization and `tools/list`: server name
  `chau7-next`, 30 tools, including `tab_list`.
- Normal application quit succeeded and saved a parseable temporary session.
- Swift restoration files remained parseable with 2 windows and 23 tabs
  before and after the isolated launch. The running Swift app was not quit.

The first release attempt exposed a macOS 27 loader error in stripped
proc-macro dylibs (`mis-aligned LINKEDIT string pool`, reported as missing
`zerofrom_derive`). Build tools are now unstripped. Next packaging applies
that override to the shared helper workspace without changing Swift's
profile. The failing macro release build passed after the correction.
The first CI run also exposed a new Rust 1.99 Clippy constant-chunk lint;
its one-line BGRA conversion fix retains the same behavior.

## Historical CI package checked (f5da7da5)

Code revision `f5da7da54240821222e5613c0886ad4c0130ab29` passed Next's
format, Clippy and workspace tests on all three platforms and produced the
`Chau7-Next-macOS-arm64` artifact:
[CI run 38124303567](https://github.com/Aeptus/chau7/actions/runs/38124303567).

| Platform | Passing tests | Ignored tests/examples |
|---|---:|---:|
| macOS | 2,167 | 2 |
| Linux | 2,184 | 2 |
| Windows | 2,141 | 1 |

Earlier Windows runs exposed path assertions that assumed Unix strings and a
binary lookup fixture that used POSIX PATH semantics with Windows drive
letters. These test corrections leave runtime behavior unchanged.

The corrected release core suite at `f5da7da5` passed all 1,917 tests on the
local Mac, including the Swift-path isolation audit. Shell generation tests
use POSIX fixtures; the POSIX PATH/executable lookup test remains enabled on
Unix and is excluded on Windows. Other expectations use native path joins.

Broker branch pushes are checked when their PR opens, avoiding duplicate
matrix runs, and failed jobs retain dependency caches for later corrections.

The final GitHub artifact was downloaded and extracted on the same Mac:
plist identity and source SHA, all executable signatures, and bundle signature
passed. Isolated startup, MCP initialization/tool list, an actual `tab_list`
response containing one tab, normal quit and saved session all passed.
The final app, ZIP and SHA-256 file are available locally in
`~/Downloads/Chau7-Next-CI-f5da7da5/`.

## Obtain a package

Choose an artifact from the successful **Chau7 Next** workflow whose embedded
source metadata matches the current PR head (or its verified PR merge tree):
[GitHub Actions](https://github.com/Aeptus/chau7/actions/workflows/chau7-next.yml).
The [historical package checkpoint above](#historical-verified-ci-package-checkpoint-fd997ec5-2026-10-13)
is the older fd997ec5 package, not a package of the current application
source. Follow [PR #229](https://github.com/Aeptus/chau7/pull/229) for a CI
artifact matching the current source. Follow the [macOS installation
instructions](../../apps/chau7-next/README.md#install-on-macos).

Local builds use `apps/chau7-next/scripts/bundle-macos.sh`. No production
Chau7 install or restart is needed. The local tested app and ZIP were copied
into `~/Downloads/Chau7-Next-test-edfe67aa/` with a SHA-256 file.

## Still to verify

The full [Mac hand-test checklist](HANDOFF.md#6-hand-test-checklist-on-a-mac)
remains open: keyboard/IME, dragging and splits, restoration across complex
sessions, accessibility, notifications, Keychain/login, helper registration
in real AI CLI configs, TLS trust and production relay pairing. The isolated
startup check does not establish full feature parity or production readiness.


## Historical parity batch validation (20f9eed5)

Committed app source `20f9eed5` passed 2,196 local macOS workspace tests
(261 app, 1,935 core), with two ignored tests/examples. The final combined
source also passes strict workspace/all-target Clippy and the parity schema
check. This batch includes current repository grouping, grapheme painting,
Spanish/plural backend, CTO sentinel, macOS file-watcher recovery and numeric
performance exports. At that checkpoint the current-source inventory was still
in progress; the later scoped PRF-002 status is recorded below. The separate
physical Mac checklist remains open.

A separately identified local diagnostic app was assembled from the committed
new app/bridge binaries and the previously verified CI helpers. This is an
isolated runtime check, not a replacement for the complete CI bundle build.
The user's running Next and Swift apps remain untouched.


The owned diagnostic app passed native launch, MCP initialization and all 32
tool registrations. `chau7_runtime_info` returned its actual source SHA,
unique test bundle ID and PID. Live and persisted snapshots contained real
CPU/RSS, main-thread timer delay and nonempty feature timings, and excluded
commands and terminal content. Automatic sampling and graceful owned-app
quit/session save passed. Diagnostic profile: `/private/tmp/c7perf-5af6659b5d`.
The performance reports path is `~/.chau7-next/reports/performance`, through
`DataRoot::reports_dir`, rather than the main log's App Support location.

## Earlier owned diagnostic package, 2026-10-12 (66753ed1)

Source66753ed1 builds three normal Rust binaries without native fixture features.
Clean source, matching Cargo artifact/fingerprint hashes, arm64/minimum macOS13.0,
seven individual helper signatures and deep/strict bundle verification pass.
A fresh UUID package launches in a new synthetic profile, exposes exact runtime
SHA/PID and numeric diagnostics, restores two tabs and quits normally with session
and performance persistence intact. Existing apps/profiles remain untouched.
This owned diagnostic package is separate from the complete CI build artifact.
See [recovery validation](RECOVERY-VALIDATION-20261011.md) for scope and limits.

## Earlier normal software-window test package, 2026-10-12 (7bd54649)

Clean source 7bd54649 produces a normal feature-free signed arm64/macOS13.0
package with all seven helpers and GPUI notices/licenses. It launches in a fresh
synthetic profile through LaunchServices using the saved Software preference,
exposes verified runtime/whole-window diagnostics, accepts exact owned MCP
Unicode input and saves all three tabs on graceful quit. Existing apps/profiles
remain untouched. At this earlier checkpoint the scoped test did not yet close native
resize/fallback acceptance or replace the full CI package; the later
exact-source acceptance below supersedes that status. See recovery validation
for both chronology and scope.

## Historical exact-source acceptance, 2026-10-12 (68294293)

Frozen clean source `68294293c3cea30a565d9d300781fcac9a6586c8` (tree
`51588684fcc60f98f74eaa00f2e3e2943c6f094b`) passes all nine compiler stages
and the strict native matrix: Software 4/4, Auto unavailable-device 4/4 and
localized Settings 6/6. The feature-free signed normal package selects the
whole-window Software backend and passes owned MCP input, numeric performance
observation and graceful quit/session persistence. A separate isolated fake
CLI run passes completed-run persistence and independent read-only post-quit
database verification. No provider or device was contacted. Full
receipt detail and scope limits are in
[recovery validation](RECOVERY-VALIDATION-20261011.md).

PRF-002 is complete for this scoped inventory behavior. The native and runtime
receipts do not establish independence from normal WindowServer composition,
hot GPU-loss recovery, or completion of the separate [Mac hand-test checklist](HANDOFF.md#6-hand-test-checklist-on-a-mac).
Full `--full` quality and CI inspection for the final docs-only revision are
not represented by these receipts.

A successful workflow run for this exact source head reports macOS, Linux and
Windows passing. Its 29,549,422-byte `Chau7-Next-macOS-arm64` artifact is
available from [run 38302279668](https://github.com/Aeptus/chau7/actions/runs/38302279668)
([artifact 11771389619](https://github.com/Aeptus/chau7/actions/runs/38302279668/artifacts/11771389619)).
The artifact was not downloaded or verified locally in this acceptance. A
separate pull-request workflow run still had Quality/macOS checks running at
the latest status read. Check [PR #229](https://github.com/Aeptus/chau7/pull/229)
for the final docs-only revision's current checks and artifact; the successful
run above is for source head `68294293`, before the documentation-only closeout.
