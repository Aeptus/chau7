# Chau7 Next: handoff

Read this first when picking up Chau7 Next (the Rust/GPUI port of Chau7).
Last updated 2026-10-12.

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
   (Rust, Xcode with the Metal toolchain, Go).
3. Continue the existing draft PR [Aeptus/chau7#229](https://github.com/Aeptus/chau7/pull/229). Keep all parity work in that PR; it is not ready to merge.

## 3. Status

- Current source66753ed1 passes 2,906 release workspace tests and strict
  normal/optional all-target Clippy. Native dee8163a restore/settings/editor pass,
  including 99 search anchors and production animations. SET-137 closes; retention
  default and unavailable-Metal window startup remain two partial inventory rows.
  A fresh ordinary feature-free app launches/quits with numeric performance and
  session persistence verified. Exact scope and limits are in
  [RECOVERY-VALIDATION-20261011.md](RECOVERY-VALIDATION-20261011.md).
- The current-source audit indexes all 652 Swift source files at official main
  `7733b1f0`, appends the current feature delta and reopens changed behaviour.
  [PARITY.md](PARITY.md) is the current status, including missing features.
- First current parity batch: ordinary/restored repository grouping, complete
  grapheme painting, CTO recursion sentinel, Spanish/plural backend and macOS
  file-watcher recovery. Numeric performance exports are described in
  [PERFORMANCE.md](PERFORMANCE.md). Independent native hang sampling, bounded
  sampled metrics history, native Instruments intervals and memory retention
  are implemented. Native emoji/style acceptance passes at e8f32e6014b0;
  current-source parity and the complete Mac checklist remain in progress.
- Historical result against the **April 2026** Swift app: 1,174 of 1,175 inventory rows
  finished (1,129 done, 45 not needed in the Rust design). The one partial
  row was PRF-002. That historical limitation is superseded: Next now has a
  terminal CPU rasterizer and a working renderer switch. GPUI window startup
  without a platform graphics device remains an open facet.
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

1. Remove concrete render-time I/O found during animation review: snippet
   filesystem scans and history SQLite/metadata reads need observed snapshots
   produced off UI, bounded event invalidations and truthful pending/error.
2. Extend owned native Settings verification to French, Arabic RTL and actual
   System Default without changing macOS global language or existing apps.
3. Resolve TEL-024's retention-default policy and PRF-002's macOS window backend
   limitation. Preserve existing history and never mark unsupported behavior done.
4. Finish remaining Mac hand-test facets below. Native fixtures prove exact
   geometry/events/lifecycle, not physical keyboard/IME, pixels or full AX.
   Never stop the user's running Next/Swift or change their profiles.
5. Keep work in draft PR229; verify complete macOS/Linux/Windows and quality
   checks for published commits, including the identity of built artifacts.

## 5. Decisions waiting for Christophe

1. "Create Per-Repo Config" still writes `<repo>/.chau7/config.toml` on an
   explicit click (as Swift does). Everything else in repo `.chau7/` is read
   only for Chau7 Next. Keep, or make it read only too?
2. PRF-002 (CPU renderer switch): keep as partial with the explanation, or
   mark `dropped`.
3. Security issue in the **Swift** app, not fixed there:
   `apps/chau7-macos/Sources/Chau7/App/AppDelegate+URLScheme.swift` turns
   `chau7://ssh/<target>` into `ssh '<target>'` with no confirmation, so a
   web link with `-oProxyCommand=...` runs any command. Chau7 Next rejects
   such targets, uses `ssh --` and asks first; the Swift fix is the same few
   lines.

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
Finish missing and partial rows with real caller wiring and tests; do not
claim current parity from the historical April percentage. Inspect current
Next logs safely and use PERFORMANCE.md for numeric diagnostic access.
Preserve running Next/Swift sessions and production restore data. Validate in
an isolated bundle/profile, continue PR229, and record actual Mac results.
Follow CLAUDE.md (Aethyme broker, commit format). No em dashes.
```
