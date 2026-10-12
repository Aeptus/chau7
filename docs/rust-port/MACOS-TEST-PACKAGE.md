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

## Local package checked on 2026-10-11

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

## Final CI package checked

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

Open the latest successful **Chau7 Next** workflow on `feat/chau7-next`:
[GitHub Actions](https://github.com/Aeptus/chau7/actions/workflows/chau7-next.yml).
Download `Chau7-Next-macOS-arm64` and follow the
[macOS installation instructions](../../apps/chau7-next/README.md#install-on-macos).
The plist records the commit actually built, including for PR builds.

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

## Current exact-source acceptance, 2026-10-12

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
