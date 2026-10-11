# Chau7 Next: handoff

Read this first when picking up Chau7 Next (the Rust/GPUI port of Chau7).
Last updated 2026-10-11.

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
   `Aeptus/chau7:feat/chau7-next`. The current milestone is a macOS test
   package called **Chau7 Next**, running beside Chau7. Full parity work
   remains a later milestone. See [MACOS-TEST-PACKAGE.md](MACOS-TEST-PACKAGE.md).
2. The push starts `.github/workflows/chau7-next.yml` (macOS, Linux,
   Windows). The macOS job uploads `Chau7-Next-macOS-arm64`. To run it:
   unzip, `xattr -dr com.apple.quarantine "Chau7 Next.app"`, open.
   Local build instead: `cd apps/chau7-next && ./scripts/bundle-macos.sh`
   (Rust, Xcode with the Metal toolchain, Go).
3. Open a draft PR `feat/chau7-next` into `main` once CI is green.

## 3. Status

- Against the **April 2026** Swift app: 1,174 of 1,175 inventory rows
  finished (1,129 done, 45 not needed in the Rust design). The one partial
  row is PRF-002: GPUI has no CPU renderer, so the "Metal Renderer" switch is
  saved and explained but cannot switch to CPU drawing.
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

1. **Get a Mac build and hand test it** (section 6). Fix what breaks.
2. **Inventory delta.** The Swift app grew a lot since April (124 new core
   files, Overlay split, settings stores and Permission Center, repository
   pane, hook installers, skills installer, usage and dashboard, event spine,
   `chau7` CLI, Spanish, plural rules). REBASE-ON-AEPTUS.md section 5 lists
   it by module. Add new rows to the inventory files (new IDs at the end of
   each file, never renumber) and update rows whose Swift behavior changed,
   then port them following AGENT-PLAYBOOK.md.
3. **Known gaps from the rebase** (REBASE-ON-AEPTUS.md section 4):
   - Remote control needs relay credentials now: add a UI that runs
     `chau7-remote identity` and `provision` into Chau7 Next's own
     credentials file; until then remote cannot reach a production relay.
   - The painter draws only the first character of multi-character grapheme
     clusters (emoji sequences, combining accents); `GridCopy` already
     carries the clusters.
   - Remote grid snapshots are full each time (Swift now sends deltas).
   - `CHAU7_CTO_OPTIM_ACTIVE` sentinel in the CTO wrappers.
4. **CI cost.** Every push runs macOS, Linux and Windows. Optionally run
   Linux and Windows only on demand.

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
- **Languages:** French, Arabic (right to left), System Default.

## 7. Prompt to start the next session (on `Aeptus/chau7`)

```text
Read docs/rust-port/HANDOFF.md, then AGENT-PLAYBOOK.md and
REBASE-ON-AEPTUS.md, on branch feat/chau7-next. Goal: Chau7 Next at full
parity with the CURRENT Swift app on macOS, running side by side with it.
Step 1: check CI on feat/chau7-next and fix any macOS build failure.
Step 2: do the inventory delta against the current Swift sources
(REBASE-ON-AEPTUS.md section 5), new rows at the end of each inventory
file, then port them in batches of parallel agents as in the playbook.
Follow CLAUDE.md (Aethyme broker, commit format). No em dashes.
```
