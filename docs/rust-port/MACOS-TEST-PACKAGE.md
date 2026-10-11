# Chau7 Next macOS test package

Current milestone: an Apple Silicon macOS test app called **Chau7 Next**,
installed beside Chau7. Current Swift feature parity remains in the handoff
backlog. This is an ad-hoc signed test package, not a notarized release.

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

The final code revision `adda113b105a8fb540266e9b34066f6d774b01f7`
passes Next's format, Clippy and workspace tests on macOS, Linux and Windows:
[CI run 38122553605](https://github.com/Aeptus/chau7/actions/runs/38122553605).
It also produces `Chau7-Next-macOS-arm64` on macOS. The Windows correction
uses native path joins in an existing CTO test; runtime behavior is unchanged.
Broker branch pushes are checked when their PR opens, avoiding duplicate
matrix runs, and failed jobs retain dependency caches for later corrections.

The final GitHub artifact was downloaded and extracted on the same Mac:
plist identity and source SHA, all executable signatures, and bundle signature
passed. Isolated startup, MCP initialization/tool list, an actual `tab_list`
response containing one tab, normal quit and saved session all passed.
The final app, ZIP and SHA-256 file are available locally in
`~/Downloads/Chau7-Next-CI-adda113b/`.

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
