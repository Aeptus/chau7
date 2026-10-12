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

## Native animation and isolated normal app safe667 (2026-10-12)

Exact native source dee8163a passes all three real-platform cases with unchanged
source. Restore PID41178 closes five owned PTYs, removes profile/bundle and exits.
Worker failures are asserted zero, including rejecting a missing counter.
Settings PID43591 renders 99/99 anchors, 28 grouped summaries/114 cards and five
production InputState queries; every target observes one held retry and actual
callbacks for 220ms centered scroll, 120ms retry and 180ms highlight. Bounds and
observed offset share a prepaint, fixing callback-order double offset. Exact
42-grapheme compact paths and 50,000/clamped history summary budget are implemented
without changing stored settings. SET-137 closes these audited facets; physical
input, pixels, full AX and multilingual acceptance remain separately scoped.
Editor native composition/save/progress/disposal passes again.

Integrated source 66753ed1c99a879881fbf7c9f65d2ec0ede59197 passes 2,906 release workspace
tests (507 app, 2,399 core), two existing ignored tests/examples, strict release
normal/optional workspace all-target Clippy and fmt. No test/lint/workflow bypass
or retry was added.

The ordinary feature-free app builds all three Rust binaries from clean source
with exact artifact/fingerprint hashes. Four helpers retain verified unchanged
source lineage; all seven are arm64/minimum macOS13.0, individually signed, with
deep/strict bundle verification. Earlier 8b6a normal packaging succeeded but its
launch was rejected before execution for automatic notification permission and
provider health HTTP feeds; that package remains unlaunched. Safe667 removes
these automatic actions and global URL registration only in isolated test mode.
Normal launch and manual behavior are preserved.

The fresh UUID app launches through ordinary LaunchServices and reports exact
SHA/bundleID/PID60141 through read-only MCP. Two saved tabs restore; only the
selected terminal starts a PTY, whose input recorder stays zero. No provider
command executes. Two post-startup snapshots 37.61s apart measure 2.912%
of one logical CPU and 113,475,584 resident bytes at the later capture. Compilation
runs concurrently and provider services are disabled; this is no production
performance comparison. Sixteen heartbeat samples show last28.732ms and
maximum127.267ms scheduler delay. Hang count is zero; 32 work-profile entries keep
actual wall-time queues/stages and per-stage CPU/GPU values stay null.
Sixteen active timers include no shell loading or provider-health timer.
Journal19/19 is durable with no persistence error. Performance latest/history
are parseable schema1. Startup warnings only announce four missing files created
inside this owned profile; stderr is empty and no logged error is observed.
Normal AppleEvent quit exits the actual app, removes MCP socket, saves both tabs
and marks launch continuity running=false. No forced process signal was sent.
The owned app/profile/evidence are preserved; existing apps remain untouched.

Official c52a14ba macOS/Linux/Windows CI succeeds for both PR38196961269 and
push38196958433, verifying the later Linux checkpoint without proving the old
failure cause. Newer source CI is separately tracked. Local evidence prefixes:
native-dee8163a-*, source-safe667-*, normal-safe667-* in the recovery directory.

## Native Settings language matrix (2026-10-12)

Agent source `28b3dd9a6937db206b3500eeacf8a7d35f70520b`, integrated by
root `a53f6bf4`, passes four actual owned AppKit/GPUI Settings windows:
English, French, Arabic and System Default. All use binary SHA256
`8bbfae8adef9ba9725430a8c8e9bc51aabbbfe442029a5a51c8d950a882fe056`.
Each case proves 99/99 actual target rectangles visible, all 28 grouped
summaries/114 cards, three InputState search queries plus unmatched/empty
queries, bounded retry and actual animation/highlight frames. Arabic proves
the sidebar on the right and detail on the left through native prepaint bounds.
System Default remains selected and resolves to English from the actual
read-only macOS preferred languages `[en-US, fr-FR]`; no OS language changes.

French and Arabic queries use source catalog titles. Restored Scrollback uses
the same English fallback as the current Swift catalog; this is recorded
explicitly rather than counted as a translated title. The earlier French
`1cc745dada19` negative fixture is retained: its sidebar test-support ID was
not registered. The follow-up only exposes that ID for test/native-fixture
builds; it adds no style/layout changes and removes no assertion.

All four processes exit successfully, close their owned resources and remove
their fresh profiles. Evidence: `native-settings-localized-matrix-28b3dd9a6937-20261012-053732.json`
and its four referenced JSON files/logs in the recovery evidence directory.
This proves native geometry and constructed widget events. Physical input,
pixel acceptance and full accessibility acceptance remain separate hand tests.
Agent-source release tests pass (505 app + 2,399 core, two existing ignored),
strict Clippy with default and optional native features and formatting pass.
These are exact agent-source checks; combined root checks follow integration.

## Integrated restore clock regression (2026-10-12)

Official3c4caf73 has mixed CI results: Next push38199570549 passes macOS,
Linux and Windows; PR38199574152 fails one macOS restore test while its Linux
and Windows jobs pass. The failing parked-metadata assertion used real
Instant time alongside virtual executor timers, so an assertion intended
before450ms could run after450ms. Agent `aec3542c482b`, integrated as root
`fccea88e6b49b8ab58c3dc3100577dc29ca155a8`, uses the same executor monotonic
clock for selection timestamps and timer deadlines, including production.
Profiler wall time is unchanged. The real-PTY regression retains its exact
resume bytes/once-only assertions and adds delayed dispatch: stale at449ms
before/after draining, metadata admitted at450ms with zero parked PTYs.
No retry, extra sleep, skipped assertion or relaxed gate is introduced.

Exact combined root source passes 2,908 release workspace tests (509 app and
2,399 core), with two pre-existing ignored tests, strict release all-target
Clippy for default and optional native builds, and formatting. All three
actual owned native cases pass using original binary SHA256
`8225ccc549738a290f439815caca51e2af38780fd265716b58bd371889c7935a`.
Restore PID76026 is admitted at460ms against450ms, retains two exact resume
prefills without terminators or duplicates, starts no transient/parked PTYs
and closes all five owned PTYs. Settings PID81839 retains99/99 visible
targets/28 summaries/114 cards/five queries. Editor PID1645 retains native
composition/undo/redo/save and owned-surface disposal. All actual PIDs are
verified gone and owned profiles/resources are removed/closed. The restore
application exit code remains unknown; its LaunchServices waiter exits0.
The existing one finalLF history difference remains explicitly recorded.
Evidence prefixes: `native-fccea88e6-*` and `source-fccea88e6-*`; original
macOS CI negative remains `ci-3c4-macos-pr-failed.log`.

Quality38199574215 runs all affected/full-suite/staged gates successfully,
then fails its check that staged gates did not rewrite source. Ruff reformats
`apps/chau7-next/scripts/native-parity.py`; this is a separate format-only
correction and must be verified in a later official CI run.

The proposed three GPUI forks have a separate independent provenance audit:
all195 original files/9,848,773 bytes match their manifest SHA256/length and
the locked local registry byte for byte. The two subsequent normalization
changes have matching before/after hashes and preserve non-whitespace bytes.
This verifies provenance only; it is not software-backend acceptance.

## Quality correction and measured persistence integration (2026-10-12)

Official7a13ed78 passes quality run38201979320 and Next PR run38201979374,
including macOS/Linux/Windows and macOS packaging. The formatter-only follow-up
therefore resolves the earlier staged-source-rewrite failure without changing
assertions or gates. Swift main remains7733b1f0c4440c0193915b036c38d5b83f31a1b3
when checked again on2026-10-12.

Root45146bad validates the Aethyme incomplete-capture backoff and static
subprocess wall-time instrumentation:10 focused tests and2,914 release workspace
tests (515 app +2,399 core; two existing ignored), strict default and optional
all-target Clippy, formatting and diff checks pass. Independent adapter review
also passes. These tests use owned fake CLIs; no existing app, provider or real
broker delivery was changed by testing.

Agent cache checkpoint07e5752b7309896faaf87cd727d4e9364a259661 has real native
acceptance: actual PID13069, binary SHA256
a8f7a720219b91d0125f6d90ebd1273e41375ad9dfd8027d3102d147311a53cd,
exit0 and verified removed owned profile/closed resources. Three actual Settings
pages paint, real FSEvents observes valid/invalid/valid and a revision-fenced
rename, real history writer insert/clear changes held statistics, a quiescent
missing-primary error preserves last success and recovers, snippet read errors
show Unknown and recover, and close/reopen observes exactly two snippets.
Central cleanup waits for monitor/read/write completion and final SQLite close
before deleting the owned profile. No injected cache values or ordinary provider
history initialization. Source integrated as5fe39a846; combined checks follow.
Evidence: `next-native-cache-20261012-062859.json` and its stdout/stderr.

## Integrated cache and persistence acceptance (2026-10-12)

Combined Rust source5fe39a846 passes2,934 release workspace tests (533 app,
2,401 core; two existing ignored), strict default and optional-native all-target
Clippy and formatting. Subsequent runner/document changes leave Rust sources
unchanged. Exact source424cd1d2a3c5beecb160c69587fd6065e5f20f9d passes all four
native cases with original binary SHA256
0243aec3f21dc4e87cd607712408f446813100c894c42bcb0aa3a6e01c71041b.
Restore actual PID80059 uses ordinary LaunchServices; settings PID82017,
editor PID84342 and cache PID84361 exit0. All four real PIDs are verified gone,
profiles removed and resources closed. Restore app exit code remains unknown,
with the launcher separately exiting0. Source stays clean/unchanged throughout.
Evidence prefixes `source-5fe39-*` and `native-424cd1d2-*` retain complete receipts.
The runner now includes the cache in `--case all` and uses the repository's
explicit `scripts/ruff.toml` configuration, checked idempotent.

Fresh bounded read-only inspection of the unchanged old79748ee9 app at04:35UTC
finds305 warnings, including301 incomplete Aethyme captures, and zero error
lines in the trailing256KiB window. No arbitrary log lines are exported.
The separate performance capture reports PID3607,72,302,592 resident bytes,
5.314% of one logical CPU, healthy watchdog and zero stalls/recoveries. These
are scoped observations of the old T7-consent-waiting app, not a benchmark or
new-source acceptance. The cause of incomplete CLI capture is unproven.
Evidence: `chau7-old797-readonly-20261012-summary.json`.

Independent final GPUI prerequisite-ledger audit at2e2179b0627e verifies all
four modified package paths, original/current SHA256 and complete before/after
change chains. Provenance acceptance remains separate from software rendering.
Evidence: `chau7-gpui-2e-ledger-root-audit.json`.

## Integrated shutdown, acknowledgement and Windows correction (2026-10-12)

Exact root1814234842f6e6d6d14a0ddb9b1ef8f1016ee13a passes2,947 release
workspace tests (544 app,2 public GPUI prerequisite integration, 2,401 core;
two existing ignored), strict default and optional-native all-target Clippy,
formatting and diff checks. This integrates normal history shutdown/drain,
nonblocking descriptor-checked snapshot reads, the bounded Aethyme acceptance
ledger and a Windows test cleanup correction. Focused fake-CLI tests retain
accepted prompts across incomplete completion and changed-generation reclaim;
FIFO tests use producer-free pipes and a deterministic file-to-FIFO replacement.
No real provider, paired device or existing app/profile was changed in testing.

Officialc514f379 passes quality run38204650284 and Next macOS/Linux jobs in
PR run38204650295 and push run38204646194. Both Next runs fail their Windows
history observer test while deleting an owned SQLite folder. The test previously
waited for Weak disappearance rather than completed destruction. The integrated
039265a78665 test-only change joins the actual writer on a background thread,
keeps both outside-store-lock observer assertions, and asserts processed1/failed0
before deletion. Actual Windows confirmation is pending a later official run.

The provenance-aware duplication check excludes only191 byte-identical locked
upstream originals, verified by pinned manifest SHA256, regular ancestors and
file hashes. Modified originals and new sources remain scanned at the unchanged
2% threshold. Seven fail-closed regressions pass; the actual root181 scan reports
0.90% duplicated lines. No blanket vendor ignore or threshold increase.

The full local JavaScript quality suite remains negative: first run110/111,
second109/111, with unchanged Swift package-graph tests timing out at120seconds.
All four tests pass in an isolated invocation. An owned manifest-process sample
shows a CoreServices bootstrap wait during Foundation directory enumeration;
it does not establish a TCC, working-directory or source-code cause. No test,
gate, timeout, OS permission or Swift manifest was changed to conceal this.
Both failures, the isolated success and the owned process sample are retained.

The earlier rootd0e12e54b prerequisite source passes2,936 release workspace tests
and8 actual Apple initialization/ownership tests. These validate nullable initial
Metal device/library/pipeline resources, not a usable software window. Original
Cocoa deprecation warnings and the missing precompiled-Metal-toolchain result
remain visible; no component installation or warning suppression was added.

After the user reports granting removable-volume access, bounded read-only
inspection of the old797 app at05:10UTC still finds347 warnings,343 incomplete
captures and zero errors in the trailing256KiB window. Its separate performance
capture reports PID3607,79,233,024 resident bytes,6.814% of one logical CPU,
healthy watchdog and zero stalls/recoveries. Permission delivery and restored
terminal readiness are unproven; this is neither a benchmark nor new-source
acceptance. Only bounded numeric summaries are retained for this observation.

Evidence: `source-181423-*`, `source-d0e12-*`, the named local quality/test/sample
logs, `chau7-ci-c514-next-failed.log` and
`chau7-old797-after-volume-consent-summary.json` in the private evidence folder.

## Integrated CPU scene prerequisites, not window acceptance (2026-10-12)

Exact rootbd6269459be60aaf88147dec13dd849b06e93417 passes2,948 release
workspace tests (544 app,3 public GPUI integration, 2,401 core; two existing
ignored), strict default and optional-native all-target Clippy, formatting and
diff checks. Separate actual platform tests pass15 software renderer cases and
13 Apple cases on the owned native target with release LTO disabled. These cover
checked CPU atlas/frame/path storage, primitive families, actual CoreVideo read
lease release, transformed sprite pixels, retained CGImage/ordinary CALayer
ownership, and actual Metal initial viewport/pool/atlas preparation. Source stays
clean and unchanged during all checks. The17-file current modification ledger
and all before/after hash chains pass independent root verification. Actual
duplication scan remains0.90% with188 byte-identical originals excluded; every
modified/new renderer source stays eligible at the unchanged2% limit.

The independent scene/resource/presenter reviews find no confirmed ownership or
rendering blocker. Two descriptions require correction before diagnostics are
exposed: image channel conversion remains premultiplied, and CALayer contents
updates measure CPU submission, not completed OS presentation. The Metal alias
is still selected at this checkpoint. These are staged prerequisites and do not
close PRF-002 or prove startup/usable windows without Metal.

The next actual seven-family CPU/Metal comparator finds a sprite sampling
mismatch in the staged agent implementation: separate CPU texture edge clamping
produces255 where the packed Metal atlas produces224. A matching packed CPU
allocator corrects that actual comparison to mean/max byte error0 in the agent
worktree; its checkpoint, integration and full native window acceptance remain
pending. No tolerance was widened. The initial non-IOSurface video fixture
constraint and comparator negative are preserved separately.

Normal history shutdown releases writer-owned references after the actual join;
other live readers can retain the store until their own teardown. The isolated
observer test drops its separate reader first, so its completed join establishes
SQLite close before directory removal. Do not infer the fixture's exclusive
ownership condition for every ordinary live window.

Evidence: `source-bd626-*`, `chau7-root-bd626-software15.log`,
`chau7-root-bd626-apple13.log`, `chau7-root-bd626-duplication.log` and
`chau7-gpui-bd626-ledger-root-audit.json` in the private evidence folder.

## Whole software scene, policy and normal app checkpoint (2026-10-12)

Exact root bc1bf7ddaa80 passes 2,962 default-feature release workspace tests
(558 app, 3 public GPUI integration, 2,401 core; two existing ignored), strict
normal/optional all-target Clippy, fmt and diff guards. All 33 macOS fork tests
and 13 Apple tests pass separately on clean unchanged source. These include
packed atlas lifetime/COW/bounds, seven-family actual Metal image comparison
with visible shadow coverage, real CoreVideo reads and checked explicit sRGB
CGImage/profile ownership. Root capture validates comparator assertions without
changing thresholds; exact per-family mean/max values are not printed in that
root capture. No AppKit window launches in these unit runs.

The approved retention policy is integrated: only positively absent owned config
and state roots can establish the durable 30 day installation default. Existing
profiles, explicit zero/custom values, partial imports and local resets retain
appropriate prior choices. Ambiguous, malformed and misplaced settings remain
zero. Independent review caught inline-comment section headers that could hide
explicit zero from the legacy parser; conservative validation plus owned
load/import regressions correct that case without rewriting existing files.
Post-prune VACUUM and ordered background writer/close work remain pending; TEL-024
stays partial.

A normal feature-free package at 7bd54649ddfd builds the three Rust binaries from
clean source with matching Cargo artifact/fingerprint hashes. Four helpers have
unchanged verified source lineage; seven arm64/minimum macOS13.0 executables are
individually signed and the bundle passes deep/strict verification. The required
GPUI original/modification manifests, notices and licenses are in the signed
bundle. The native fixture feature is absent.

The uniquely owned app launches through ordinary LaunchServices as actual
PID 32659 with verified source/bundle UUID, synthetic profile and provider/remote
services disabled. Saved use_metal_renderer=false selects Software before
window setup without injection; both measured window backends are Software and
the terminal uses CPU. After 66.88s the main window has 199 submitted images and
the auxiliary window 5, with zero failed frames. Latest measured CPU submission
is 139,217 us and 17,157 us respectively. App-process CPU snapshot 42.101% uses one
logical CPU as 100%; RSS 144,457,728 bytes and watchdog zero stalls are observed.
Compilation runs concurrently, so this is not an idle benchmark or a performance
gain. GPU/compositor memory and display completion stay null.

Authorized synthetic MCP tab_create adds one tab to the two restored tabs.
Only after its local cat sink is ready, tab_send_input sends 68 Unicode bytes
without an appended newline or shell evaluation. Exactly those bytes are
observed in that tab's owned input file; the other input file remains empty.
No provider/device is contacted. Normal AppleEvent quit removes the actual PID
and MCP socket, saves all three tabs, marks continuity running=false and leaves
input files unchanged. No POSIX signal or forced quit is used; package/profile
and evidence are retained, and existing apps/profiles remain untouched.

Actual isolated native surface probes expose intermittent five-second frame
barrier failures, including after resize; the Metal control has the same timeout.
AppKit source/capture colors pass after explicit sRGB image and empty capture
profile ownership corrections, with thresholds unchanged. That does not prove
all software interaction cases. These negatives remain preserved. PRF-002 stays
partial pending actual frame demand/resize progress and all four cases under
explicit Software and Auto unavailable-device fallback.

Official 34a16789 passes the Next PR matrix38209626232, parity and quality
38209626235. Its quality correction uses process.stdout.write instead of
console.log without changing duplication pin/coverage/threshold. The earlier
Windows join correction is confirmed by d1081dad Next PR38207094216 and
push38207091081 across all three platforms. These CI successes apply to their
exact published revisions, not the later local backend checkpoints.

Evidence: chau7-root-bc1bf-* release/vendor receipts and logs,
chau7-root-7bd546-* build/package/MCP receipts, normal-7bd546-* identity,
performance and graceful-quit records in the private recovery evidence folder.

## 2026-10-12: reviewed followups and retained negative results

Official `2f089af2ac1505bb91a981b9899a70ffaaaf240c` completes the Next
PR/push macOS, Linux and Windows matrix, parity and quality checks. Push Next
run `38213719047` reports success; official Swift main remains
`7733b1f0c4440c0193915b036c38d5b83f31a1b3`. Broker read operations 1491/1492
and the numeric receipt `chau7-root-official-ci-source-0719.json` retain this
verification. These results do not validate later local checkpoints.

Integrated followups include ordered telemetry writes/snapshots/VACUUM/close
(`9b8a5547`), native marked text and attachment generations (`a8244843`,
`e98210ea`), actual Settings failure diagnostics (`70ade37c`) and the opaque
integer-rectangle CPU path (`e1451554`). Independent source review finds the
fast path equivalent to scalar quantization/clipping/order, with fractional,
nonopaque, rounded and bordered cases retaining scalar rendering. The root
26-file current-hash/change-chain receipt is durable as
`chau7-root-opaque-e145-ledger-audit.json`; this is provenance validation, not
a performance benchmark. The author reports 37 fork tests including unchanged
actual Metal comparisons; combined root gates remain pending.

Checked background initialization and memory-only telemetry diagnostics are
integrated at `584c40a6`, with confirmed-corruption documentation at `93b3dfdd`.
The author reports 2,959 workspace tests and both strict variants passing.
Independent review found one blocking shutdown path: if the writer thread
cannot start, the absent JoinHandle could incorrectly authorize a clean marker.
The focused correction `a80350049d0cde392e3df64b9f259d162155065b` is published,
independently reviewed and integrated at `2e905aef`. The author reports 2,961
workspace tests plus two existing ignored tests, both strict variants and two
focused failure regressions passing. Actual SQLite close must retain the
missing-writer error; failed initialization cannot become successful shutdown.
Combined-root validation and normal app verification remain pending; TEL-024
stays partial.

Native Software Settings still has an actual 500 ms negative, including a
prior run without concurrent compilation. The first optimized-source editor
launch produced no fixture JSON within 75 seconds; subsequent profile logs
show ordinary startup rather than fixture entry, consistent with a normal
workspace build replacing the optional runner artifact. Its receipt/profile
is retained at `chau7-backend-native-owned-kl8rnyt3`; the owned PID was already
absent before sampling. No app kill, provider call or input occurred. This
negative does not establish a Settings or frame-waker failure. The next
launch must verify a matching executable hash and optional-feature fingerprint
after the final build. Five-second frame and 500 ms animation limits remain
unchanged; the eight-case Software/Auto matrix is still pending.

Read-only observation of the preserved older `79748ee9` app at 07:18 UTC
verifies PID 3607 and its exact executable, then reads a bounded 256 KiB log
tail: 2,054 lines, 342 warnings, 341 incomplete-capture warnings and no errors.
The numeric snapshot reports 2.073558% of one logical CPU, 31,801,344 resident
bytes and a healthy watchdog with zero stalls/recoveries. Other lane compilation
was active: this is not a benchmark. Numeric-only metadata is retained as
`chau7-old797-readonly-0719-summary.json`; raw log lines are not exported.
The warning is from Aethyme delivery capture, whose older generic text cannot
distinguish timeout, truncation, read failure or cancellation. Current code
already uses bounded retry backoff and one warning per outage. The root adds
actual result flags/status/static caller/byte counts to that warning without
changing capture or acknowledgement behavior.

The byte-equivalent opaque-pixel store followup
`bd00bfe7f5ba117bf8c7e74a269428c931921ffb` is independently reviewed and
integrated at `5ec3472b`. The author reports 38 software renderer tests, strict
checks and 26 ledger chains passing. The native Software editor scenario
passes on that exact author source. A quiet Software Settings run still fails
the original 500 ms limit at 529,208 us over seven frames (26,772 us latest
CPU submission, zero failed frames). A separate Restore scenario fails its
application activation deadline. These distinct negatives remain preserved;
neither permits promoting PRF-002. The eight-case matrix remains incomplete.


## 2026-10-12: exact combined gates and eight-case native matrix

Frozen clean source `feb5e1991bd24471e16dcd6583833512aabd3ada` passes
2,992 release workspace tests, zero failures and two existing ignored tests:
569 app, three public GPUI integration and 2,420 core tests. Normal and optional
strict all-target Clippy, format and diff checks pass. These normal gates use
thinLTO/codegen16. Fork gates pass 38 macOS and 13 Apple cases, including seven
actual Metal comparisons. All 26 modification chains/current hashes and 181
unlisted originals verify against the unchanged pinned upstream manifest.
Seven provenance tests pass; duplication is 0.907471% below the unchanged 2%.
Receipts use the `chau7-root-combined-feb5e199-*` prefix.

The Settings correction `273101d3`, integrated at `feb5e199`, preserves the
original deadline for repeated identical targets and skips only exact already
applied positions. Both actual Settings cases pass 99/99 visible targets and
28 summaries with the original 500 ms limit. The Restore activation diagnostic
`079ba0a1` is integrated at `a0a74b09`; the independent review also clears the
static numeric Aethyme capture diagnostics without changing capture or ACK.

The complete matrix attempts all eight independent cases on one verified
optional artifact, SHA256
`a39b514981b7a19307f8a7e7696f5268ed33528aa195c5aee0d82fd76d2a6458`:

| Case | Software | Auto unavailable-device fallback |
|---|---|---|
| Editor | FAIL: marked metadata gone after actual repaint; text intact | PASS |
| Settings | PASS, original 500 ms | PASS, original 500 ms |
| Restore | FAIL: deminiaturized surface reveal; earlier activation passed | PASS |
| Cache | PASS | PASS |

There are no retries and no known team compiler during the matrix. All eight
actual application PIDs are verified gone, all owned profiles deleted, and both
signed Restore bundles removed. Failure receipts leave resources-closed null
when not emitted. A LaunchServices waiter exit0 is not an application exit0;
that application exit field remains null. Six positives do not close PRF-002.
The matrix and every raw outcome remain in
`agent8-software-window-20261012-4icg291m/combined-feb5e199-native-matrix-20261012/`.

Readonly review finds no proven production cause yet. The editor fixture has no
active/key setup assertion before native composition. Restore invokes native
window mutations within an App borrow and does not establish activation after
minimizing the last window. Valid owned focus, safe foreground native mutation
and fixed boolean/numeric observations are the next correction; assertions,
original real-frame counts, five-second and 500 ms limits remain unchanged.

Both exact-source builds complete: normal three-bin feature-free thinLTO,
and optional native runner in a separate LTOoff/codegen16 target. The optional
runner's Cargo artifact and matching dependency hash/fingerprint are verified
before launch. This runner is not a normal performance benchmark. The new normal
app has not yet been packaged/launched; TEL-024 still needs normal Ready/drain,
clean marker and readonly post-close SQLite integrity evidence.

The official baseline recheck at 09:23 UTC still reports Swift main `7733b1f0`
and existing draft PR229 at `2f089af2`. Earlier green CI applies to that exact
published source, not these later checkpoints.

The preserved older `79748ee9` app's readonly refresh at 08:35 UTC verifies
its exact PID3607, executable and source before sampling. A bounded 256 KiB log
tail has 2,035 lines, 304 warnings (all incomplete capture) and zero errors.
Process CPU is 3.015911% of one logical CPU, RSS 31,064,064 bytes and main delay
3.137875 ms; the watchdog is healthy with zero stalls/recoveries. Compilation
runs concurrently, so this observation is not a benchmark or proof the T7 shell
is ready. The initial sandbox socket EPERM is retained; the same authorized
readonly probe succeeds with filesystem access. Only numeric summary
`chau7-old797-readonly-0834-summary.json` is exported, not raw log lines.

## 2026-10-12: d1f290ab current acceptance and TEL-024 close

Frozen clean source `d1f290ab129e2799133bb7b5cd2bdd7015d03a53` passed all 11 full-prepush gates. The Swift suite executed 4,586 tests, with 3 skipped and 0 failures; iOS app tests reported `TEST SUCCEEDED`. Broker operation 1773 records the successful atomic push, with both published branch refs at d1f290ab. The receipt is `fast-d1f290ab-prepush-success-20261012/receipt.json`.

The d1f290ab Next workspace validation passed 3,017 tests. The macOS helper workspace passed 539 tests, the focused HUP regression and all seven injected EINTR cases; its helper gate receipt records 11/11 checks passed. The vendor production check passed; its macOS and Apple test gates satisfied their 36-test and 23-test minimums. The normal fast build, helper builds and optional native build recorded 287.913 s, 93.600 s and 83.104 s, respectively. These are run observations and do not establish a controlled speedup. Receipts are under the `fast-d1f290ab-*` evidence directories.

Normal signed-package verification passed. The owned normal-app run accepted the exact 68-byte Unicode MCP input without contacting a provider or device, preserved existing input, and saved three tabs. Whole-window Software rendering opened two windows; each reported one submitted frame and zero failed frames. The telemetry writer reached Ready with accepted=1/completed=1/pending=0/failed=0. Graceful quit recorded 10 phases with nondecreasing counters, no observer timeout and a clean marker. The app PID and socket were gone afterward; read-only SQLite `quick_check` passed across 10 tables. Shutdown duration was 47,491 microseconds in that run, an observation rather than a bound.

A second owned MCP run persisted one completed assistant run with turn count 1, an end timestamp and exit status 0; no provider or device was contacted. The post-quit precision-aware verifier matched its run ID, provider, cwd, status and turn count, found the unique assistant marker, and passed read-only database integrity checks. Two saved tab UUIDs parsed successfully. The app PID/socket were gone, and shutdown again recorded 10 nondecreasing phases, a clean marker and no observer timeout. Source review confirms Swift `JSONEncoder` ISO-8601 serialization uses whole seconds while SQLite keeps fractional precision. The original exact-string post-quit verifier therefore failed on timestamp precision; the preserved result is a verifier-precision negative, not a product persistence failure. The independent root verifier passes. The receipts are in `fast-d1f290ab-run-data-v2-20261012/`.

Native Software Restore, Editor and Cache passed; Software Settings failed because the `number-format-fr` control was missing. The independent Auto run passed Editor and Cache, while Restore and Settings failed. All native-test PIDs were verified gone. PRF-002 remains partial with these native cases open. TEL-024 is complete: current retention-policy tests pass, and the signed app evidence verifies Ready, a persisted completed run, ordered writer drain, clean shutdown, process/socket exit and post-quit SQLite integrity.

## 2026-10-12: f077bf8f combined gate and private pasteboard negative

Frozen clean source `f077bf8ffedba729424bde207ac03738b5f2ed79` passes all six Next checks, including 3,017 workspace tests and strict normal/native Clippy. The integrated native fixture changes register regional controls for actual hit testing and wait for real selected split PTY activation; their native runtime acceptance has not run yet.

The serial compiler sequence stopped at vendor tests after a passing production check: 35 macOS tests passed and `pasteboard::tests::test_read_image` failed with two entries instead of one. The implementation emits two entries only for filenames plus their text representation, whereas this image fixture declares only PNG. Five private pasteboard tests were running concurrently. One six-test diagnostic observation with five workers and one with one worker both passed; these smaller observations neither resolve nor replace the failed 36-test acceptance result. No app was launched and no later compiler stage ran.

The reviewed correction adds a test-only mutex around those five private pasteboard tests and an initial-empty assertion for the image fixture. It preserves every existing assertion and the independent custom-type autorelease-pool test. Original vendor provenance stays immutable; the modification ledger records the source transition. Full combined validation remains pending. Original receipts are preserved in `fast-f077bf8f-gates-20261012`, `fast-f077bf8f-vendor-negative-20261012`, `fast-f077bf8f-compiler-sequence-negative-20261012` and `fast-f077bf8f-pasteboard-diagnostic-20261012`.
