# Integrated recovery validation, 2026-10-11

## Source and checks

Native source checkpoint: `8fe704068e300376b5040383c02e53de2c6f606c`.
The integrated release workspace passed 2,575 tests, with two ignored tests.
Strict release workspace/all-target Clippy, formatting and build passed.
The only build warning is upstream `block 0.1.6` future incompatibility.
All tracked shell scripts also pass ShellCheck. The two native-platform CI
Clippy failures and the Codex wrapper ShellCheck failures from `e6e04d75`
are corrected in this checkpoint; CI must verify the newer toolchain separately.

## Owned macOS acceptance

The isolated bundle contains seven signed executable helpers and passed deep
strict code-signature verification. Both source revision plist keys identify
`8fe70406`. Only the test bundle and its own profile were updated.

Actual automatic grouping shows one repository header containing both restored
shell tabs, with the repository branch chip. ANSI colors, bold, italic,
underline, combining accents, emoji sequences, flag and wide CJK characters
are visible in the owned window capture. Default grouping remains Off, matching
current Swift; this test profile explicitly uses Auto.

Real MCP performance snapshots expose both initial renderer registrations.
The selected terminal reports requested and actual GPU rendering. A separate
launch with the owned CPU preference reports requested and actual CPU drawing,
8,989,056 cached bitmap bytes and 35,627 CPU glyph-cache bytes. Its native
capture preserves the same styled Unicode fixture and repository grouping.
This proves both selectable terminal backends on this Metal-capable Mac;
automatic startup fallback on a Mac without Metal remains unsupported. The hidden,
never-painted view reports null actual renderer rather than inventing evidence.
Measured grid/string capacities and explicit native-ring estimates appear per
pane; private GPU and pending-native-image allocations remain unavailable.
Interactive focus and hidden/background refresh states are reported explicitly.
No hung-main-thread event occurred during these captures.

## Idle observation and limits

Baseline `e6e04d75`: two idle shells, 231.041 seconds, 1.650 percent of one
logical CPU for the app process. PTY callbacks were about 43.61 Hz per shell.
Candidate `8fe70406`: readiness waiting is separately instrumented and does not
hold parser locks. A later 53.177-second interval recorded 513 callbacks across
both shells, about 9.65 Hz combined, compared with 87.22 Hz combined in the
baseline. This establishes fewer idle callbacks in these captures.

It does not establish an equivalent CPU benchmark: native focus changed during
the candidate interval, baseline focus was not instrumented, builds ran
concurrently, and the observation lengths differ. The candidate app measured
1.565 percent of one logical CPU in that interval. No general CPU improvement
or interactive input-latency result is claimed. Profiler wall-time includes
waiting and must not be interpreted as CPU consumption.

A further 287.999-second interval with both snapshots reporting no focus
recorded 2,793 callbacks (9.698 Hz combined) and 0.717 percent of one logical
CPU. The same comparison limits apply.

The evidence directory contains `native-e6e04d75-performance-{a,b}.json`,
`native-8fe70406-performance-{a,b,c,d}.json`, both grouping screenshots, the
candidate bundle manifest, and integrated test/Clippy/fmt/build logs. These
numeric diagnostics contain no terminal transcript. Live-provider notification,
manual drag, VoiceOver and paired-device acceptance remain separate checks.

## Subsequent source checkpoint

OSC9 shell context, Windows path portability, the explicitly approved paired
push-frame patch, current notification reconciliation, shared native process
monitoring and Usage diagnostics are integrated after the native checkpoint.
Their source checks and native acceptance must be recorded separately; the
8fe70406 bundle is not evidence for those newer source changes.

## Rebuilt native checkpoint, 2026-10-12

Native source checkpoint: `10b774b797db94146549c1384889433406d9c2ff`.
The integrated locked release workspace passed 2,836 tests, with two existing
ignored tests. Strict release workspace/all-target Clippy, formatting, parity
and diff checks passed. All three Next executables were rebuilt from this
checkpoint. Four shared helpers retain their verified unchanged source and
hashes. All seven executables and the owned bundle passed deep strict signing.

The preceding `b5857ef9` bundle aborted at startup: CTO registered a timer before
observability initialization. The `c1eed221` initialization-order correction
is included in `10b774b7`, whose real native launch now succeeds. The failed
bundle and the prior verified bundle are retained as local rollback evidence.

The isolated test bundle was replaced after a graceful quit. The version-one
restore index retained its one window and two saved tabs before and after quit.
Read-only MCP confirms both tabs after launch; the selected terminal activates
and the other remains deferred. Runtime source identity matches the bundle.
Its durable journal was fully processed with no journal error at capture.
The owned window screenshot again shows both tabs grouped under one repository,
the branch chip, ANSI styles, combining accents, emoji and wide characters.

Two real performance snapshots span 140.708 seconds with one active terminal,
one window and interactive refresh at both endpoints. App process CPU usage
is 2.488 percent of one logical CPU over that interval. Final resident memory
is 100,220,928 bytes. The watchdog records zero stalls and recoveries. These
measurements do not establish a general speedup over earlier captures with
different terminal counts and focus. Profiler wall time is not CPU time;
unavailable per-stage CPU and GPU completion times remain null.

The actual CPU renderer, per-pane retention estimates and work profiles are
available through read-only MCP. Performance reports persist every five seconds
in the owned profile: latest JSON, plus two JSONL history files bounded to
8 MiB each; individual snapshots are capped at 1 MiB. No terminal transcript
is needed for these numeric captures.

A timestamp-filtered audit of the new launch finds 98 log lines: 62 DEBUG,
34 INFO, two WARN and zero ERROR or panic records. One warning records the
previous interrupted launch. The other records the operating system refusing
notification permission for the test bundle. Notification acceptance therefore
remains outstanding; no OS permission was changed by this check.

Local evidence includes `native-10b774b797db-bundle-manifest.json`,
`native-10b774-runtime.json`, `native-10b774-performance-{a,b}.json`,
`native-10b774-timers.json`, `native-10b774-tabs.json` and the owned window
capture. Newer source changes to shared protection settings, Windows history
identity, timer retention, unsampled heartbeat reporting and restored terminal
geometry require their own combined checks and a subsequent native rebuild.
This checkpoint does not establish real-provider, paired-device, keyboard/IME
or accessibility acceptance.

## Native checkpoint 79748ee9 (2026-10-12)

- Clean source `79748ee9b62929af30196a62e229559174433e44` passes 2,885 release workspace tests with two existing ignored, strict release workspace/all-target Clippy, formatting, parity and diff checks. The future-compatibility warning is upstream `block 0.1.6`.
- Three Next executables were rebuilt from that exact source. Four shared helpers retain verified unchanged source and hashes. All seven arm64 executables and the bundle pass signing/deep/strict verification. Graceful replacement preserves one window and two saved tabs, with the prior owned bundle retained for rollback.
- LaunchServices opens only `com.chau7.next.parity-recovery.20261011` with the explicit owned isolated profile. Read-only MCP reports the exact source and PID 3607; the durable journal has processed all 181 events without a persistence error. The watchdog remains healthy with zero stalls or recoveries.
- The owned window capture shows automatic repository grouping and two restored tabs. It also exposes a pending startup acceptance issue: the fake shell remains on `Shell initializing`. A one-second sample of its owned PID3681 shows `getcwd` waiting in `open`; its CWD is the T7 worktree. Matching TCC events explicitly show a `SystemPolicyRemovableVolumes` prompt for the isolated bundle. The user was asked to respond to that OS prompt. No OS permission was changed, no denial was bypassed and no live-session input was sent.
- The 65.673-second numeric interval records 4.747% of one logical CPU and final RSS 143,671,296 bytes with one selected terminal and one window. Because the shell awaits filesystem consent, this is startup evidence, not a ready-terminal performance comparison or an optimization claim.
- Actual measured callbacks now distinguish classified idle work from activity that was not observed. PTY, remote, persistence, readiness, feedback and transcript callbacks expose idle counts; unclassified app/heartbeat/memory callbacks expose `activity_unknown_samples`. The bounded timer registry exposes its 128 inactive-lifetime limit separately from measured callback costs. Per-stage CPU and GPU completion remain null when unavailable.
- At audit time the new launch has 0 error rows and 0 panic rows. Warning categories are recorded numerically in the local evidence, including notification permission and incomplete Aethyme capture while T7 access awaits consent. Native acceptance is not promoted by this checkpoint.
- Local evidence: `native-79748ee9b629-bundle-manifest.json`, `native-79748-{runtime,perf-a,perf-b,timers,tabs}.json`, `native-79748-performance-and-launch-audit.json`, `chau7-next-native-79748.png`, the owned shell sample and scoped TCC log in the parity recovery evidence directory. Raw OS logs remain local; no report was sent externally.

## Reproducible native fixture checkpoint 76887725 (2026-10-12)

Clean source `76887725e37bdd506e0a6f0db599ffa085cf29b1` passes
2,886 release workspace tests with two existing ignored tests. Strict default
release workspace/all-target Clippy, formatting, parity and diff checks pass
using the installed Rust 1.96.0 toolchain. The upstream `block 0.1.6`
future-compatibility warning remains separate from these checks.

`apps/chau7-next/scripts/native-parity.py` builds the opt-in acceptance feature
in a separate target directory. It records the exact source, compiler and
binary SHA-256, then requires one positive case report, exit zero and removal
of that case's owned temporary profile. It cannot accept empty stdout as a
successful native test. Feature-enabled fixture binaries are not app packages.

The actual native run has one passing case and two failures. Restore passes
with real platform frames, real owned PTYs, selected-first split activation,
no transient-selection or parked-metadata PTYs, and two readiness-bound resume
deliveries without terminators or duplicates. Settings fails at the loaded
`promptInjection` target. Editor fails at its fixture's editor materialization
step. Each case emits an explicit result and removes its owned profile; the
overall manifest is false. These failures do not promote the inventory.

Local evidence is retained as `native-768877-manifest.json`, the three case
stdout/stderr pairs and build log, plus `source-768877-pinned-*` check logs in
the recovery evidence directory. Subsequent anchor and fixture corrections
require their own native rerun. No user session or global permission changed.

## Combined native checkpoint f9e4c17b (2026-10-12)

Clean source `f9e4c17bcfe7cd999e7df2fd0be5649ae0367ba7` passes
2,887 release workspace tests with two existing ignored tests, strict default
release workspace/all-target Clippy, formatting, parity and diff checks.
The installed fixed Rust 1.96.0 toolchain is used throughout.

The reproducible native driver passes restore, settings and editor on this
single revision. Its separate optional-feature binary SHA-256 is
`ce322f9d5ee111b0e1fdfa4955e1ca3db2017147e4d29e601797a67590d2a590`.
Every case has explicit positive JSON, exit zero and owned profile removal.
Restore observes identity admission 453ms after rapid selection, with no parked
or transient PTYs and two exact resume deliveries without terminators or
duplicates. Its registry-based graceful-close count remains zero; the runner
closes sessions through the quit fallback. A stronger ordinary-registry
mount and per-PTY closure assertion are required before closing that facet.

Settings has 99 unique targets. All99 intersect the actual viewport on both
axes with scroll offsets inside bounds after three real frame callbacks each.
The production alias fix covers the loaded AI Context caption. This proves
explicit result jumps; per-page summaries and automatic first query-match
scrolling/highlighting still require implementation and evidence. SET137
remains partial.

Editor passes actual native marked-text preservation and composition commit,
ordinary key delivery, Undo/Redo, saving the synthetic owned file, real GPUI
dialog/sheet/popup detach, preview remount and owning-window closure. The
initial hidden-window materialization failure and nested fixture Root lease
panic were corrected in the acceptance fixture. OS IME source switching,
candidate panels, hardware input and accessibility are not established here.

Local evidence includes `native-f9e4c1-manifest.json`, case stdout/stderr pairs,
build log and `source-f9e4c1-*` checks. Each case records its owned PID/profile.
No existing user session, permission or provider setting changed.

## Native key-state checkpoint 29ac30b3 (2026-10-12)

Clean source `29ac30b38e1cfd865a8260f9e49f73310d61c95e` passes
2,888 release workspace tests with two existing ignored tests. Strict default
and optional-native-feature release workspace/all-target Clippy, formatting,
parity and diff checks pass with fixed Rust1.96.

The separate actual native runner still passes all99 explicit settings target
jumps and the editor case. Editor stderr is empty after the production UTF-16
ruler bounds fix. The bounded workspace animation clock and real pane animation
FPS cap are integrated; these results do not establish a matched CPU benchmark.

The strengthened restore case fails its actual AppKit key-window assertion in
an inactive fixture process. Visible/front/frame checks had passed in the prior
agent-native checkpoint, but makeKeyWindow alone did not make this inactive
process's window key. The failure emits explicit false JSON, exits nonzero and
removes its profile. It is preserved as negative acceptance evidence. The next
fixture must exercise ordinary activation of its own isolated application;
the key assertion is retained rather than substituted with a successful API
call. No production key/reactivation defect is established by this failure.

Evidence: `native-29ac-manifest.json`, case stdout/stderr/build logs and
`source-29ac-*` default/optional check logs in the local recovery directory.
The overall native manifest remains false and inventory rows are not promoted.

## Current editor and query acceptance 9a4b5730 (2026-10-12)

Clean integrated source `9a4b5730e2b0bed9ec9aea188be4095e3306504a`
passes 2,890 release workspace tests (492 app, 2,398 core), with two existing
ignored tests. Strict release workspace/all-target Clippy passes in both
default and optional-native-feature builds, along with formatting and parity.
The native feature remains separate from ordinary app packaging.

Independent native editor and settings runs use the same exact source and
optional binary, real platform frames and new synthetic profiles. Both emit
explicit passed JSON, exit zero and remove their own profiles. Editor stderr
is empty. Production source composition, constructed native key delivery,
Undo/Redo/Save, dialog/sheet/focused-popup detach, preview/remount and disposal
pass. A production paint observer additionally verifies the actual header has
no task-free counter, then paints 1/2 and 2/2 after real NSTextView insertions,
excluding a fenced task sample. EDT-013 closes its specific native source and
modal acceptance blocker. New SPL-027 records the current Swift header display
behavior that was absent from the earlier inventory.

The native settings run verifies all99 explicit target jumps and four actual
InputState Change deliveries. Matching queries derive and visibly lay out the
first anchor with highlight prepaint; unmatched and empty queries retain the
selected page and clear active highlight. Centered geometry is checked when
content allows it. Pixel-level highlight, OS keyboard/pointer and accessibility
acceptance are not claimed. SET-137 stays partial while the current 28-page
summary grid and Swift search animation/retry behavior are being implemented.

This does not supersede the negative restore key-window evidence at29ac30b3:
an unbundled fixture cannot yet become an active key application. Its actual
key assertion remains required; a fresh owned LaunchServices fixture is being
prepared. Hover/deferred restore, full Hidden persistence/reload and memory
acceptance are reported at their exact independent checkpoints.

A read-only MCP sample at2026-10-12T02:01:40Z confirms installed source79748ee9,
PID3607, journal181/181 with no persistence error, zero watchdog stalls and
17 registered active tasks. Process CPU is6.346% of one logical CPU and RSS is
75,890,688 bytes. The restored T7 shell remains consent-blocked; this is not a
ready-terminal performance comparison, and the new bounded loading animation
is not installed in that bundle. Runtime/performance/task snapshots remain
accessible without terminal input or creation of a live tab.

Local evidence: `native-9a4b-editor-*`, `native-9a4b-settings-*`,
`source-9a4b-*`, and `readonly-20261012-020140-*` in the recovery evidence
directory. Broader OS input-source, hardware keyboard, accessibility, real
provider and paired-device acceptance remain in the hand-test checklist.

## Combined native acceptance 5fa1e4c4 (2026-10-12)

Clean exact integrated source `5fa1e4c4f0561894fa51ddf5070e9c684a19e7d4` passes 2,895 default-feature
workspace tests in the debug profile, with 2 existing ignored tests. Strict
release workspace/all-target Clippy passes for both normal and optional native
builds; formatting, generated parity and diff checks pass. Earlier exact26b5d4fe
passes2,894 release workspace tests and the same strict gates. The native feature
remains outside normal app packaging.

One optional binary runs allthree actual native scenarios with explicit passed
JSON and unchanged source. Original binary SHA256 is `d05c93ba760d4b8a3e134146525c8f8fdea72f1e23b528877bbdccaee26c5e95`.
Restore uses a fresh signed, deeply/strictly verified UUID app via ordinary
LaunchServices; actual appPID72531 disappears, allfive owned PTYs close and its
profile and bundle are removed. The LaunchServices waiter exits zero; the actual
app exit code is unknown, rather than inferred from open -W. Settings/editor
actual processes exit zero and disappear, removing their profiles.

Restore verifies native active/key-window state, selected split admission,
451ms identity-only preparation, two exact readiness-bound resume prefills with
no Enter or duplicates, real hover expiry and hide/reveal/miniaturize frames.
Ordinary background history is Warm before injected Critical policy runs through
the real tick, disk worker and reload. All200 markers survive exactly once,
PTY output bytes remain4017 and input recorder remains zero; Hidden keeps50 native
ring rows and selected history stays intact. Before3799 bytes become3800 with
one final LF on shared emulator replay, retained as an explicit raw difference.
The actual worker reports zero failures. Raw/CHG2 remote snapshots continue
updating while UI presentation is suspended. OS pressure notification delivery
is not tested by policy injection.

The actual loading task is one80ms registration, cancels to zero while hidden
with no callbacks for240ms, resumes as one clock and yields five measured callback
samples, then stops at real prompt and disposal. Callback costs are wall time,
exclude interval waiting, and do not establish CPU or display FPS improvement.
A separate actual PTY regression proves clearing a ready terminal cannot restart
the loading indicator.

Settings proves99/99 target rectangles visible, all28 summary sections and114
current Swift card identities, and five real InputState Change queries. Values
use cached observations; SSH reads/watch setup and timezone conversion occur off
UI, with bounded coalescing and retained successful data on read failure. Search
animation/retry and two exact summary formatter facets remain followups, so
SET-137 stays partial. Editor again verifies actual native source composition,
Undo/Redo/Save, painted task progress, modal/sheet/popup detach and disposal.
This does not claim physical keyboard/pointer, OS input-source or full AX checks.

At the earlier published757d1523, the PR-event macOS/Linux/Windows workflow passes;
the push-event workflow at the same SHA passes macOS/Windows but fails the CTO
sentinel Linux fixture with only `sed` recorded. Root0f74f4ee makes the test-only
wrapper explicitly run through Bash and uses stable system executable symlinks,
retaining assertions and adding failure diagnostics. All24 CTO tests and20
concurrent full repeated runs pass locally. The old log lacks stderr, so a
fork/executable race is a hypothesis, not a proven diagnosis; new Linux CI must
verify this checkpoint. No retries, ignored tests or workflow gates were added.

Local exact evidence: `native-5fa1-*`, `source-5fa1-*` and `source-26b5-*` in the
recovery evidence directory. Negative29ac key-window evidence remains historical;
the ordinary bundled positive establishes the later observed active/key state.
