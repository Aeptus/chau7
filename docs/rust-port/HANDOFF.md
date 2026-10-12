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

- Integrated source bc1bf7dd passes 2,962 release workspace tests, strict
  normal/optional all-target Clippy and 33 macOS fork plus 13 Apple tests.
  A normal feature-free 7bd54649 package runs the complete software window
  backend, receives exact synthetic Unicode input through MCP and saves all
  three owned tabs on graceful quit. Full native software resize/frame
  acceptance and post-prune telemetry maintenance remain in progress; two
  inventory rows stay partial. Evidence and limits are in
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
  terminal CPU rasterizer and a working renderer switch. The complete software
  window backend now starts in an ordinary signed app;
  native resize/frame and injected-failure acceptance remain open facets.
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

1. Finish actual software window frame/resize progress and the existing four
   native cases under explicit Software and Auto with unavailable-device
   injection. Keep actual frame callbacks and unchanged five-second deadlines.
2. Finish TEL-024 post-prune VACUUM and ordered background telemetry writes,
   demand-coalesced read snapshots, explicit database close and error-aware
   shutdown. The approved new-installation policy is implemented and tested:
   30 days only for positively fresh profiles; preserve existing zero/custom
   values, configuration and history. Ambiguous/invalid files retain zero.
3. Settings/snippet/history render getters now consume bounded background
   snapshots. Keep the real cache FSEvents/SQLite error/recovery regression and
   Settings English/French/Arabic RTL/System Default checks in acceptance.
4. Finish remaining Mac hand-test facets below. Existing native evidence
   proves scoped geometry/events/lifecycle, not every physical keyboard/IME,
   multi-display, provider or full AX interaction. Preserve running apps.
5. Continue draft PR229. Official 34a16789 passes Next PR macOS/Linux/Windows,
   parity and quality CI; later integrated source requires its own CI run.

## 5. Approved decisions and retained behavior

- New installations default to 30 days. Existing settings/history are preserved,
  including explicit zero. Local factory resets respect installation policy.
- PRF-002 includes a usable whole GPUI window without Metal and startup fallback.
  CPU terminal drawing alone does not close it. Ordinary AppKit/WindowServer
  composition and hot GPU loss have separate boundaries.
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
Finish missing and partial rows with real caller wiring and tests; do not
claim current parity from the historical April percentage. Inspect current
Next logs safely and use PERFORMANCE.md for numeric diagnostic access.
Preserve running Next/Swift sessions and production restore data. Validate in
an isolated bundle/profile, continue PR229, and record actual Mac results.
Follow CLAUDE.md (Aethyme broker, commit format). No em dashes.
```
