# Chau7 Next parity with the current Swift app

## Validated implementation batch (2026-10-14)

The batch after `0121b9ab` corrects automatic grouping across repository changes
and splits, primary/displayed root inference on restore, read-only MCP grouping
diagnostics, native window integration retirement, tab-bar recovery, isolated
Keychain replacement, status-item anchoring, bundle-only CLI installation and
printing through the shared CPU painter.

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

The earlier `eb4baae5` local full-quality receipt passed nine selected
gates (two conditional checks not applicable), 4,586 macOS tests (three skipped,
zero failures) and 97 iOS tests. It retains its original revision. CI status for
the published PR head is available on [PR229](https://github.com/Aeptus/chau7/pull/229/checks);
that live status must not be inferred from an older local receipt.

Implementation inventory: 1,309 of 1,309 rows finished (1,277 done,
32 not applicable, zero partial). This measures implementation coverage. Physical
AZERTY/dead-key/IME input, VoiceOver, multi-display interaction, real OS services,
Keychain prompts, print dialogs/devices, live providers and paired remote devices
still need the Mac hand-test. The user has deferred that test until this autonomous
work is finished. Existing installed applications were not replaced or relaunched.

Current local receipts are under
`resume-20261014-grouping-native/{core-final-v6,package-final-v6,native-build-final-v6,native21-final-v6,keyboard-final-v6-software,keyboard-final-v6-auto-device-failure}`;
normal runtime is under
`resume-20261013-1433/normal-runtime/outputs/normal-grouping-f79eda39-final`.
All are rooted at
`/Volumes/T7-repositories/chau7-next-parity-recovery-evidence-20261011`.

## Previous implementation checkpoints (2026-10-13)

### Previous validated application source: `8c2ef35e`

Application source `8c2ef35ec39c5c3a199a9f9b199cc5f85422f847` (tree
`6c3424440386292c1e286af67d3f27027366d9b3`) was clean for all current-source
receipts. All 17 core checks passed: 3,059 Rust workspace tests (two ignored),
150 shared-terminal tests (one ignored), 46 native Python contracts,
formatting, build-mode and CLI-installer contracts, seven focused Restore
tests, strict Clippy in both feature modes, terminal HUP, and the actual
`reader_pool::retry_interrupted_tests::` EINTR filter (seven tests). The six
cursor-blink tests are included in the workspace total.

Local quality passed all nine selected gates uncached and unattested; the two
conditional drift checks were skipped as not applicable. The full local CI gate
reported 4,586 macOS tests (three skipped, zero failures) and 97 iOS tests
(zero failures). The focused FileMonitor/DirectoryMonitor run passed 13 tests;
those overlap the full Swift run and are not additional tests. The normal fast
package passed in 4.212680584 seconds with the existing cache. This is one
build observation, not a build-time benchmark.

An owned copy of the normal package passed isolated runtime acceptance. It
restored two fixture tabs, created a third, and observed the exact 68-byte fake
shell input. Three Software windows reported 234 submitted frames and zero
failed frames. The performance snapshot exposed 16 active timers out of 17
records; persistence at the configured five-second cadence produced nine
history records at 5.005–5.120-second intervals, whose latest entry matched
the persisted latest snapshot.
`token_rates_by_tab` was present but empty in this fake-shell run, so no
provider throughput result is claimed. The graceful quit completed all ten
shutdown phases; the owned app, MCP socket and three fake-cat children retired,
with no forced signals and no provider or device contact. Existing acceptance
data remained unchanged.

A PID-filtered WindowServer capture passed for the three owned windows. Visual
review found the red synthetic terminal text in both restored terminal windows
and the Welcome window in the third. This is visual evidence for the isolated
package run; it is not physical-input evidence.

The cursor change advances blink phase while a terminal view is unfocused but
skips `cx.notify()` for those phase changes; painting already shows a solid
cursor when that exact focus handle is unfocused. Focus regain restores the
visible phase. No CPU A/B measurement was run, so this change has no measured
CPU-improvement claim.

Four separate source-bound native fixture extensions passed on this source:
Restore with the Software renderer, Restore with injected Auto-device failure,
and the supplementary keyboard case with both selectors. The Restore cases
reconstructed six tabs including two initially selected PTYs and two split
leaves, delivered two resume inputs without line terminators or duplicates,
and verified styled scrollback and native reveal/focus. Both activation
acknowledgements matched the same app PID and bundle; post-ack reveal measured
three additional Software frames with zero failures. The style proof retains
`RESTORED_STYLE:é中❤️` across the worker flush/reload, including combining,
wide-character continuation and emoji cells. The keyboard cases dispatched
Cmd+C, Ctrl+Tab and Cmd+D through `NSApplication.sendEvent` to isolated fake
PTYs: with no selection Cmd+C delivered exactly byte 3, Ctrl+Tab changed the
selected tab ID, and Cmd+D made two horizontal leaves with the new leaf
focused. Each closed its three owned PTYs. The keyboard supplement is separate
from the existing 21-row parity matrix; its wrapper sees zero open windows
because the fixture closes its window before outer diagnostics, while the
receipts validate actual native CALayer/AppKit images and frames. The
Auto-device-failure selector injects a renderer startup failure and validates
the software fallback. These fixtures exercise AppKit event dispatch, not
physical keys or a system input-source change.

The existing strict 21-row native matrix remains scoped to source `8cae8bdd`;
it is not relabeled as an `8c2ef35e` matrix run. The 8c2 native fixture binary
built successfully and has the same SHA-256 as the 8cae fixture binary, while
four source-current extension cases above passed separately. The earlier 8cae
keyboard v2 attempt remains a negative wrapper result: its shortcut assertions
ran, but the outer renderer-counter check failed after teardown with
`window_count: 0`. The passing 8c2 v3 supplements are distinct receipts and do
not erase that attempt.

A recursive Git-tree comparison found 2,563 exact path/mode/type/object-ID
matches out of 2,565 entries between `8cae8bdd` and `8c2ef35e`. The only two
changed entries are `apps/chau7-next/scripts/native-parity.py` and
`apps/chau7-next/scripts/test_native_parity.py`; all other paths, including app
runtime sources, match. This narrows the source delta but does not transfer
source-bound matrix results between revisions.

The matching CI artifact is not linked yet. Follow draft
[Aeptus/chau7#229](https://github.com/Aeptus/chau7/pull/229) for publication
and attribute any CI report to its exact head and merge tree; no CI pass is
claimed for `8c2ef35e`. Physical Mac hand-testing is deferred until this
automated validation work is finished; no user hand-test result is claimed.
Real provider, credential, trust and paired-device acceptance also remain
open.

Receipts below are relative to
`/Volumes/T7-repositories/chau7-next-parity-recovery-evidence-20261011/resume-20261013-1433/`:

- `cursor-blink-review/core-8c2ef35e-v1/manifest.json` (SHA-256
  `13f6abfbe99d0f1c7fd8778f85dac24e362b8d6a8131e9781bd488be1269e374`).
- `cursor-blink-review/quality-8c2ef35e-v1/manifest.json` (SHA-256
  `718472d93587713eaf624105031d50d629e52a5bac565180eb1229c3ef193c3d`).
- `cursor-blink-review/package-8c2ef35e-v1/manifest.json` (SHA-256
  `c16de5a29b00f87408f3f3aad3f9d3d4c6aab8133e45a10859d45f1872b0a75a`).
- `cursor-blink-review/source-identity-8cae-to-8c2ef35.json` (SHA-256
  `1920a5fb318e1fd2e872363a3a1072f0e76fc25dbaef989304c4edbd3f4c7e0c`).
- `cursor-blink-review/native-build-8c2ef35e-v1/manifest.json` (SHA-256
  `147a4d7d24778d19a0b77df0ef3c75de3188f6712bc5c31da193d2864429482f`);
  its build receipt is
  `cursor-blink-review/native-build-8c2ef35e-v1/build-receipt.json` (SHA-256
  `7e13e5451180a59a8df74549b55341951e8e9af1b2761c430b450cb616b1c7c6`),
  artifact SHA-256
  `5176e0a1ba73cf40d822738910ec98cde8b0ea59337f36a7835e669d0536610a`.
- `normal-runtime/outputs/normal-8c2ef35e-v1/manifest.json` (SHA-256
  `7ca707022669906cb875aeb71d004be69de7e71453de7616be3dc6e2171b235b`).
- `normal-runtime/outputs/normal-8c2ef35e-v1/mcp-acceptance.json` (SHA-256
  `5e45b4fe066de6c2d22da0ae8d97fdf06f03a2c8e60542f430e53419c4f4f521`).
- `normal-runtime/outputs/normal-8c2ef35e-v1/quit.json` (SHA-256
  `a59bfe5dcea14273a2f0327ee1d3f08f91e262c140a76142cbd2ab2a74550ccd`).
- `normal-runtime/outputs/normal-8c2ef35e-v1/root-readonly-verifier.json`
  (SHA-256
  `066cfdceb34ca983651fe0675b3294cba8f8fa22cfafa07a0831a3d200cd78be`).
- `normal-runtime/outputs/normal-8c2ef35e-v1/windowserver-capture.json`
  (SHA-256
  `44bcd389493f0865156dafc97ef4be61d902c59879156ba975cbf4ce4a985d29`).
- `cursor-blink-review/native-restore-8c2ef35e-software-v1/manifest.json`
  (SHA-256 `aa23bd650572003686ba86ef786f44c91f79b74cec94a94f4e9e38dfe23a3f59`).
- `cursor-blink-review/native-restore-8c2ef35e-auto-device-failure-v1/manifest.json`
  (SHA-256 `44cd9b31f20efe2d4b827215c562145ed5c0679b0654a9049a7633b0f37f376e`).
- `cursor-blink-review/native-keyboard-8c2ef35e-software-v3/proposal-summary.json`
  (SHA-256 `f27fa897e4f4d008fba08a109f73eafe81b900812869daf262625336a57db419`).
- `cursor-blink-review/native-keyboard-8c2ef35e-auto-device-failure-v3/proposal-summary.json`
  (SHA-256 `12d6343a3f715641d96bc4a01884994b7a03a1601b250229c639e024ef3436b1`).

### Previous validated application source: `8cae8bdd`

Application source `8cae8bdde42aa234ce7301c498e87dae6597aeb9` (tree
`9f3eeac9448e98fc983e302255cfff5ac2065ddb`) passed all 17 core checks:
3,059 Rust workspace tests (two ignored), 150 shared-terminal tests (one
ignored), 35 native Python contracts, formatting, build-mode and CLI-installer
contracts, seven focused Restore tests, strict Clippy in both feature modes,
terminal HUP, and the actual `reader_pool::retry_interrupted_tests::` EINTR
filter (seven tests). The six new cursor-blink tests are included in the
workspace total.

Local quality passed all nine selected gates uncached and unattested; the two
conditional drift checks were skipped as not applicable. The full local CI gate
reported 4,586 macOS tests (three skipped, zero failures) and 97 iOS tests
(zero failures). The focused FileMonitor/DirectoryMonitor run passed 13 tests;
those overlap the full Swift run and are not additional tests. The normal fast
package passed in 41.146 seconds with the existing cache. This is one build
observation, not a build-time benchmark.

An owned copy of the normal package passed isolated runtime acceptance. It
restored two fixture tabs, created a third, delivered the exact 68-byte fake
shell input, and saved the three tabs on graceful quit. Three Software windows
reported 117 submitted frames and zero failed frames. The performance snapshot
exposed 16 active timers; persistence at the configured five-second cadence
produced five history records whose latest entry matched the persisted latest
snapshot. `token_rates_by_tab` was present but empty in this fake-shell run, so
no provider throughput result is claimed. The graceful quit completed all ten
shutdown phases; the owned app, MCP socket and three fake-cat children retired,
with no forced signals and no provider or device contact. Existing acceptance
data remained unchanged.

The cursor change advances blink phase while a terminal view is unfocused but
skips `cx.notify()` for those phase changes; painting already shows a solid
cursor when that exact focus handle is unfocused. Focus regain restores the
visible phase. No CPU A/B measurement was run, so this change has no measured
CPU-improvement claim.

The strict 21-row native matrix passed all 21 cases for this source. The
Editor case demonstrates that synthetic marked text survives actual native
frames. Its fixture receipts record
`os_ime_input_source_automation=false` and `clipboard_access=false`, so this
is not evidence for the macOS-selected input source, dead-key composition or
physical IME delivery.

A LaunchServices Software keyboard-fixture attempt executed all three
shortcut assertions through `NSApplication.sendEvent` to fake PTYs: Cmd+C with
no selection delivered exactly ETX byte 3 and left selection empty; Ctrl+Tab
changed the selected tab ID; Cmd+D created two horizontal leaves and focused
the new leaf. It started and closed three owned PTYs and captured a real native
surface image. The fixture's assertion outcome passed, but the outer wrapper
receipt is negative: window sampling happened after the fixture closed its
window (`window_count: 0`), so it reported `renderer frame samples are
missing`. Treat this as partial keyboard evidence, not a completed case pass.
The initial Software attempt failed during fixture-window startup before the
shortcut assertions. Corrected cases had not run at that checkpoint;
their separate passing 8c2 results are above. This exercises AppKit event dispatch,
not physical key input. Physical Mac hand-testing is deferred until this
validation work is finished; no user hand-test result is claimed. Real
provider, credential, trust and paired-device acceptance also remain open.

Receipts below are relative to
`/Volumes/T7-repositories/chau7-next-parity-recovery-evidence-20261011/resume-20261013-1433/`:

- `cursor-blink-review/core-8cae8bdd-v1/manifest.json` (SHA-256
  `e2a9d0fd6360cd492a9e73d8298654a317522916333593724ee1454bfb6e8fb5`).
- `cursor-blink-review/package-8cae8bdd-v1/manifest.json` (SHA-256
  `25d743378edf1555c9ef84dc99de966381a04b669559b060287abf062f4fd631`).
- `cursor-blink-review/quality-8cae8bdd-v1/manifest.json` (SHA-256
  `3bd01b4f2158df07c9cd6759918aa55a645d565e50ca69521ad54ad08ff993cc`).
- `normal-runtime/outputs/normal-8cae8bdd-v1/manifest.json` (SHA-256
  `6d2eb5979a3c1a9fa8c1d52038af79ce5312d6a4a396be47ad0e45234ea1877e`).
- `normal-runtime/outputs/normal-8cae8bdd-v1/mcp-acceptance.json` (SHA-256
  `c554e0eb2c1d43c3709784ccfbd732006202967365c2cb6f9d4d65fdd3667630`).
- `normal-runtime/outputs/normal-8cae8bdd-v1/quit.json` (SHA-256
  `0fbf07e6f12a790fd566109acc6504e3f263803ee793f8c74caadfcf2b48628b`).
- `normal-runtime/outputs/normal-8cae8bdd-v1/root-readonly-verifier.json`
  (SHA-256
  `a2f428878e8d2bb0244ab004ef06bfbd9d2bec5dd80f3ef0a302a66e2ce4c392`).
- `cursor-blink-review/native21-8cae8bdd-v1/native21-manifest.json` (SHA-256
  `22f222890d47eef542fa1c6d5b8a047527c3446e1c6440c1fee14721e2c1bcaf`).
- `cursor-blink-review/native-keyboard-ls-8cae-software-v2/retry-record.json`
  (SHA-256
  `def05489074f54cb14aca8195376566e57ccb7db9218d3c888aa85ebf424bcef`;
  shortcut assertions passed, outer renderer-sampling wrapper failed after
  fixture window teardown).

These application, package and runtime receipts remain scoped to source
`8cae8bdd`; they do not transfer to a later repository or validation-runner
revision. Attribute any subsequent CI report to the exact head and merge tree
reported by CI. The earlier `5d35776c` local validation and the separate
`fe0af6cc` CI/runtime evidence retain their own source scope; neither is
described as source-identical to this checkpoint.

### Previous validated application source: `5d35776c`

Application source `5d35776c0c65825f49bc005ee3168fae23285c0e` (tree
`be6a68ce39446bad269f69ca8d4b470f1b2a4277`) passed all 17 core checks: 3,053 Rust workspace
tests (two ignored), 150 shared-terminal tests (one ignored), 35 native Python
contracts, seven focused Restore tests, terminal HUP checks, formatting,
build-mode and CLI-installer contracts, and strict Clippy in both feature modes.
The normal fast package passed in 144.594 seconds with the existing cache after
application changes; this is one observation, not a build-time benchmark.
Local quality passed nine selected gates uncached, with two unrelated drift
gates skipped conditionally; the focused Swift monitor run passed 13 tests. The strict native
matrix passed all 21 cases using one source-bound fixture binary.

The core EINTR filter exited zero but executed no tests; that original result
is preserved and supplies no focused EINTR coverage. A supplemental run used
the same already-built source-bound terminal test binary with the actual
`reader_pool::retry_interrupted_tests::` filter and passed all seven tests,
without rebuilding. These tests also overlap the shared-terminal suite and
are not additional unique tests.

The separately signed standard package passed isolated restoration of two tabs,
creation of a third, exact 68-byte fake-shell input, Software window rendering,
performance access and persistence, and graceful quit. All ten shutdown phases
completed, the owned app, socket and fake-shell children retired, and prior
acceptance data remained unchanged. No provider or paired device was contacted.
The MCP sample exposed CPU/RSS, three Software windows with positive frames and
zero failures, and 17 timer records (16 active). Performance history had seven
records at the configured five-second cadence. The token-rate map was present
but empty in this fake-shell run; no provider throughput result is claimed.

This source fixes diagnostic path opening through native filesystem paths and
labels retained generation-rate measurements with their age and UTC timestamp.
Repository grouping defaults to Off in both Swift and Next; select
**Settings > Tabs > Repo Grouping > Automatic** to enable automatic grouping.

Receipts below are relative to
`/Volumes/T7-repositories/chau7-next-parity-recovery-evidence-20261011/resume-20261013-1433/`:

- `core-5d35776c-v1/manifest.json` (SHA-256 `aa9b446955852ed5476137240525a297f39b6a43ef3238ede61acb5d0b18469b`).
- `package-5d35776c-v1/manifest.json` (SHA-256 `688c20f2cbfb47a9bdcbda9ef5a30edac4bbb7e458cff18405bf90ee0bc15685`).
- `quality-5d35776c-v1/manifest.json` (SHA-256 `709f090d64a6c0fdfb2e6acc6d63a4463b3ca02412f5a0dff8b81e4d1273147a`).
- `native21-5d35776c-v1/native21-manifest.json` (SHA-256 `5d2069adc8792cc7d0e9c3cba23fa41716aacb9588fe3a8633bd6c682b87d7b5`).
- `normal-runtime/outputs/normal-5d35776c-v1/root-readonly-verifier.json` (SHA-256 `085611d3addc7f16b3d11f20422e534ee524c079065bf91ad1021cef03932129`).

- `normal-runtime/outputs/normal-5d35776c-v1/manifest.json` (SHA-256 `771d6efff083941e4edce41a2270f11636d46f8d53e6f2d17b06eafc73010167`).

- `terminal-eintr-5d35776c-supplement-v1/manifest.json` (SHA-256 `e9a997fe72c7a23006bf3692e1301713283b5141a56fe8ceffb33b7f24ab989e`).

The native build receipt is `native-build-5d35776c-v1/build-receipt.json`;
the standard package receipt is bound to source 5d35776c by SHA-256
`5d22a65fa121262f83aa6e520bba6ed75dfaff6f728ec9b1589717f242411fa1`.
All receipts in this block remain scoped to source `5d35776c`; the newer
`8cae8bdd` results are recorded separately above. Later CI results apply only
to their own reported source revision.
Physical keyboard/IME, VoiceOver, multi-display interaction and real provider,
credential, trust and paired-device acceptance remain open. Inventory counts
do not certify those checks. Historical results below retain their source scope.

### Previous source checkpoint: 69461e60, core and fast package passed

Source `69461e60cb6bb65fe1a764510519fff599018b60` (tree
`859d2497fa1bdfeb0fce634999b915cdf5ec851e`) was the clean source revision for the previous checkpoint. Its exact-head core run passed all 17 checks: 3,051 workspace
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
Source 69461e60 also passed all nine selected local quality gates,
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
in the worktree. The source-69461e60 native-parity fixture binary also built
successfully in fast release mode with the native-parity-fixture feature. Its
receipt is
`/Volumes/T7-repositories/chau7-next-parity-recovery-evidence-20261011/resume-20261013-1433/native-build-69461e60-v1/build-receipt.json` (SHA-256 `0bf4ba3c954cc7176a4694d11212b261c35211005ad6d20d9c07ab61b57842ec`); it binds artifact SHA-256
`47235c8b3bae1b227380f20a46eb1701c4bb8478724729723d2eaba33293287e` to the same source and tree. The source-69461e60 strict 21-row native matrix passed all 21 rows. Its
aggregate receipt is
`/Volumes/T7-repositories/chau7-next-parity-recovery-evidence-20261011/resume-20261013-1433/native21-69461e60-v1/native21-manifest.json` (SHA-256 `ac451af55851470bb9232a317843c5cdbe8ad1ec501a91fb6f3171b8fdaff8cb`); it binds the same source, clean
before/after state, and unchanged fixture binary. The source-69461e60 isolated normal-runtime v2 attempt was negative. The app
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

### Previous-source isolated normal-package runtime (69461e60): passed

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
v4 helper was then peer-reviewed and used for the passing source-69461e60 v3
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
negative observations; it is not the current-source result. The subsequent
69461e… strict native sequence passed all 21 rows, without altering the ACE
receipt or supplying Hebrew Settings product evidence for that earlier row.

A separate `real-profile-log-audit.json` examined a 2,000-line tail and found
zero errors and one notification warning. The installed log itself has an
October 11 timestamp, so this is not runtime evidence for `ace3659a`. The later 69461e60 native matrix and isolated normal-package runtime passed,
as recorded above. Physical Mac and real integration acceptance remain open.


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
| [App](inventory/App.md) | 1 | 85 | 85 | 0 | 0 | 0 | 0 | 0 |
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
| [Keyboard](inventory/Keyboard.md) | 1 | 70 | 70 | 0 | 0 | 0 | 0 | 0 |
| [Localization](inventory/Localization.md) | 5 | 9 | 9 | 0 | 0 | 0 | 0 | 0 |
| [Logging](inventory/Logging.md) | 5 | 30 | 28 | 0 | 0 | 2 | 0 | 0 |
| [MCP](inventory/MCP.md) | 3 | 63 | 63 | 0 | 0 | 0 | 0 | 0 |
| [Migration](inventory/Migration.md) | 5 | 6 | 6 | 0 | 0 | 0 | 0 | 0 |
| [Monitoring](inventory/Monitoring.md) | 2 | 24 | 24 | 0 | 0 | 0 | 0 | 0 |
| [Notifications](inventory/Notifications.md) | 2 | 45 | 45 | 0 | 0 | 0 | 0 | 0 |
| [Observability](inventory/Observability.md) | 3 | 5 | 5 | 0 | 0 | 0 | 0 | 0 |
| [Overlay](inventory/Overlay.md) | 1 | 121 | 119 | 0 | 0 | 2 | 0 | 0 |
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
| **Total** | | **1309** | **1277** | **0** | **0** | **32** | **0** | |

Finished (done, n/a or dropped): 1309 of 1309 rows (100%). Partial: 0.

<!-- parity:end -->

"Left with macOS APIs" counts unfinished rows that rely on a macOS-only API;
port those behind a platform trait (see `AGENTS.md`).
