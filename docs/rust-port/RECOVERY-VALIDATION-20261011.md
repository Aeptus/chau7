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
