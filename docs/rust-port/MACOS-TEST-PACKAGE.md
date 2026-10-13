# Chau7 Next macOS test package

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

## Latest verified package (2026-10-13)

Download [`Chau7-Next-macOS-arm64`, artifact 11834575717 from run
38436092953](https://github.com/Aeptus/chau7/actions/runs/38436092953/artifacts/11834575717).
This package is for PR head `fd997ec51ce90519042636e864cf09ec910820dd`.
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

The application code is identical to the locally validated source
`69461e60cb6bb65fe1a764510519fff599018b60`; the subsequent changes were
documentation only. That source passed 3,051 Rust workspace tests (two
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

### Acceptance still open

The [Mac hand-test checklist](HANDOFF.md#6-hand-test-checklist-on-a-mac)
remains open. Start with the reported tab grouping, actual keyboard/IME,
multi-display dragging and restoration, then accessibility and system
integration. Test real CLI registration, proxy trust and relay pairing with
your own integrations. The PR remains a draft until the remaining checks have
results; inventory completion and fixture passes do not certify them.

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

Use the [latest verified package above](#latest-verified-package-2026-10-13).
For application changes after that checkpoint, choose an artifact from the
successful **Chau7 Next** workflow whose metadata matches the PR head:
[GitHub Actions](https://github.com/Aeptus/chau7/actions/workflows/chau7-next.yml).
Follow the [macOS installation instructions](../../apps/chau7-next/README.md#install-on-macos).

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
