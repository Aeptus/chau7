# iOS Terminal Rendering — Phased Plan

Owner surface: `apps/chau7-ios` (renderer), `apps/chau7-macos/rust/chau7_terminal`
(shared terminal crate), plus a small Mac-side frame emit.

Companion to `ARCHITECTURE.md` and `HARDENING-PLAN.md`. This plan supersedes the
ad-hoc width work landed in PR #128 and sequences the remaining rendering work.

> **Environment note.** This repo's environment does build, but device-level
> visual verification is not automatable here. Every phase below therefore has a
> **device gate** that a human must clear. Treat an unverified phase as
> unlanded.

---

## Where we are, honestly

PR #128 re-composed wide terminal output on the phone: the Mac announces its PTY
width per tab, the iOS engine ingests at that width (so no hard-wrap scrambles
the TUI), and the canvas folds each source row down to phone-width rows.

That fixed the corruption. It is **readable, not correct**:

- It folds each **physical** row independently. A TUI draws with absolute cursor
  positioning into a `sourceCols × rows` grid, so box-drawing and multi-column
  layouts are cut at every fold line. Text stays in reading order; the layout
  does not survive.
- A paragraph the TUI soft-wrapped at column 100 is treated as two independent
  lines, so it is chopped mid-sentence at each fold.

The root cause of both: **the fold lives in Swift, one layer above the layer that
knows the answer.** `RustGridSnapshot` exposes bold/italic/underline/strike/
inverse/dim/hidden — and no wrap bit — even though `chau7_terminal` tracks
wrapped rows internally when exporting text.

### The strategic constraint

A 120-column TUI cannot be made *correct* on a 390pt screen. That is geometry.
So the phone should not be trying to be a terminal. Two surfaces:

1. **Semantic (primary).** Tool calls, diffs, prompts, status as native views.
   Correct at any width. This is most of what remote use actually is.
2. **Terminal (secondary, explicit "take over").** For actually driving a live
   session, the only correct answer is the Mac rendering *at the phone's width*.

The current re-wrap is the correct **fallback** for the common case of
*observing* a session the Mac is driving — where you need to read it, not pixel-
match it. It is not the destination.

---

## Cross-cutting rules

These apply to every phase and exist because they were violated or costly in the
preceding work.

| Rule | Why |
|---|---|
| **No concurrent SwiftPM/Xcode builds.** All builds via `safe-build.sh` with `--jobs 2`. Reap orphans before starting. | An orphaned 4,330-test `xctest` runner caused a 3 GB+ memory drain. |
| **One PR per phase.** Each must be independently revertable. | Blast radius on a shared crate. |
| **No `--no-verify`.** If a gate is red, fix it or prove it pre-existing in that PR. | PR #128 needed it; PR #129 then fixed the cause. |
| **No phase may regress phone readability.** | The current state is already better than main was. |
| **Device gate before merge.** Screenshots attached to the PR. | Non-obvious regressions here are invisible to `swift test`. |
| **Additive wire changes stay additive.** New optional fields; never repurpose. | Mixed-version clients exist during rollout. |

---

## Phase 0 — Observability and device verification harness

*No behaviour change. Everything below is unverifiable without it.*

Today the only way to see what the renderer is doing is to read the code. Add a
debug overlay (Debug settings / `#if DEBUG` only) that renders, for the active
tab:

- source `cols × rows` vs display `cols × displayRows`, and `chunksPerRow`;
- fold boundaries as hairlines;
- **soft-wrap boundaries** (needs Phase 2 to be meaningful — start with fold
  boundaries only, add wrap flags after);
- per-frame cost: Core Graphics draw duration, cell decode count, and bytes
  copied, split by phase.

Also add a scripted device smoke test (launch → connect → subscribe → stream →
approve → background/foreground) so each later phase can be compared against a
known-good capture rather than by eye.

**Gate:** on a physical device, reproduce and capture (a) the current readable
prose state, (b) the TUI fold artifact on Claude Code. These become the visual
baseline. **Requires a human.** *(This is the step that was skipped before, and
it is why the current implementation's correctness could only be reasoned about.)*

---

## Phase 1 — Width out of the tab inventory

*Small, no dependencies, removes live fragility. Do this first.*

`terminalCols`/`terminalRows` currently ride on `RemoteTabDescriptor` — a
rendering concern in an inventory frame. It works only incidentally: the
emission gate compares whole payloads, so a Mac window resize changes the
payload and incidentally re-emits. That coupling is invisible and will rot.

- Add a dedicated `TERMINAL_SIZE` frame, scoped per tab, emitted when a tab's
  dimensions change. `scheduleGridSnapshot(for:)` already exists in
  `RemoteControlManager` and is the natural hook — dimensions change on the same
  layout signal as the grid.
- Stop populating `terminalCols`/`terminalRows` on the descriptor.
- Client applies it in `RemoteClient` → `RemoteTerminalRendererStore.setSourceColumns`.
- Check whether the Go relay must recognise the new frame type; it is otherwise
  an opaque passthrough.

Files: `RemoteWirePayloads.swift`, `RemoteTabRegistry.swift`,
`RemoteControlManager.swift`, `RemoteClient.swift`,
`RemoteTerminalRendererStore.swift`, `RemoteModels.swift`, possibly
`services/chau7-remote/internal/protocol/frame.go`.

**Compat:** a pre-Phase-1 phone loses the width field and falls back to sizing
its engine to the phone viewport — degraded (the old scrambling), never broken.
Acceptable, and call it out in release notes.

**Gate:** resizing the Mac window updates the phone's engine width promptly;
older Mac (no field) still pairs and renders; full macOS + iOS suites green.

---

## Phase 2 — Export soft-wrap from the shared terminal crate

*Additive. Unblocks correctness and performance in one move.*

`chau7_terminal` knows which physical rows continue a previous logical line; it
just does not expose it.

- Reserve a wrap bit in the cell flags (`1 << 7`, "continues previous row") in
  `RustGridSnapshot`, `include/chau7_terminal.h`, and `cbindgen.toml`.
- Populate from alacritty's per-line wrapped flag.
- Mirror the new bit on both consumers: iOS
  `RemoteRustTerminalPlayback.swift` (`rustCellFlagWrapped`) and macOS
  `RustFFITypes.swift` / `RustTerminalView.swift`. Verify no existing bit shifts.

**Gate:** `cargo fmt`/`clippy`/`test`; a new Rust test asserts a soft-wrapped line
sets the bit on continuation rows; existing snapshot tests unchanged (additive);
macOS and iOS suites green. **This touches a shared crate — run the macOS build
alone, never concurrently.**

---

## Phase 3 — Move the fold into Rust; make the canvas a blitter

*The highest-risk phase. Flag it, measure both paths.*

Today `draw(_:)` re-derives `row*cols + col` through a source→display remap and
calls `clusterString(for:)` — a `Data` slice decoded to `String` — **per cell,
per frame**, at up to 120 Hz. That is both the correctness problem and a
performance problem, and it is why fixing it in Swift was a dead end.

- New FFI export: `export_display_rows(terminal, width_cols, out, out_cap)`
  returning `{ rows, total_bytes, row_offsets[] }`. It folds **on logical lines**
  using the Phase 2 wrap bit, trims trailing blanks per logical line, and
  preserves per-cell attributes and clusters in one contiguous buffer.
- iOS calls it on viewport change and on frame publish; caches the buffer.
- `RemoteTerminalCanvasView.draw(_:)` becomes a blit: walk display rows, draw
  runs of same-foreground cells. Delete the fold from the draw path.
- Keep `RemoteTerminalWrapGeometry` only if scroll math still needs it; prefer
  moving scroll-offset conversion into Rust alongside the rows.

**Gate (all required):**
- Prose is **strictly better** — soft-wrapped paragraphs no longer chopped.
- TUI is **not worse** than Phase 1 capture.
- Frame cost measurably down (Phase 0 overlay), with numbers in the PR.
- Scroll correctness preserved in both directions at `chunksPerRow > 1`.
- Ship behind a flag, keep the old path for one release.

**Abort criterion:** if TUI layout is *still* wrong after logical-line folding,
the conclusion is that **no fold can save a TUI**. Stop folding for TUI content,
accelerate the semantic surface, and make takeover (§5) the only correct
terminal mode. Do not keep tuning the fold.

---

## Phase 4 — Semantic surface *(separate initiative)*

The primary surface, and the largest piece of work. Largely independent of the
rendering track; run in parallel if bandwidth allows.

> **Correction (added after Phase 0–3 landed).** This phase was originally scoped
> as "tool calls, diffs, prompts and status as native views", which implied a
> stream of semantic events already reaches the phone. It does not. The Mac
> publishes **one `RemoteActivityState` snapshot per tab** — tool, status,
> headline, detail, and any pending approval — and the phone already decoded it,
> but used it only to drive the lock-screen Live Activity. There is no history
> and no per-tool-call event stream.
>
> So Phase 4 splits in two, and the first half is much smaller than planned:
>
> - **4a — current state (shipped, #135).** A native card above the terminal
>   showing the running tool, its status, and the pending command with
>   Approve/Deny. Built entirely from data already arriving. This is what makes
>   "what is it doing, and does it need me?" answerable without a terminal.
> - **4b — timeline (not started).** A history of past tool calls and diffs.
>   This needs **new Mac-side event publishing**, not just a client change, plus
>   a product decision about how much history the phone retains and how it is
>   paged. Treat it as its own project, not a view-layer task.

Approval actions in 4a deliberately render only for a request the phone actually
holds: `respondToApproval` queues a decision for an unknown id and applies it if
the request later appears, so a button bound to a stale id would let someone
believe they had approved something that is still blocked.

---

## Phase 5 — Scoped, opt-in takeover width negotiation — **REJECTED**

**Decision (2026-09-29, product owner): the phone must never resize the Mac's
terminal.** This phase is cancelled, not deferred.

The original argument was that a 120-column TUI cannot be made correct on a
390pt screen, and that the Mac rendering at the phone's width is the only way to
get a correct TUI. That reasoning still holds — and the decision rejects it
anyway. The Mac terminal belongs to the person sitting at the Mac. A remote
companion silently changing it is not a trade worth making, whatever it buys on
the phone.

### What this settles

The phone is a permanent **observer** of a Mac-driven terminal. That constrains
everything downstream, so record it plainly:

1. **A full-screen TUI will never render correctly on the phone.** Not "not yet"
   — it is geometrically impossible while the Mac keeps its own width.
   Box-drawing and multi-column layouts are cut at fold seams no matter how
   clever the fold gets. The Rust fold (§3) makes *prose* read continuously,
   which is the achievable goal, and that is all it promises.
2. **The semantic surface is therefore the primary surface, not an
   enhancement.** Phase 4a exists; 4b is not optional polish. The terminal is the
   "something looks off, let me read raw output" view; the structured surface is
   how you normally find out what the agent did. This raises 4b's priority
   considerably.
3. **The display fold stays as the permanent terminal mechanism** — there is no
   takeover mode to hand off to. Do not remove the §3 fallback on the theory
   that a better path is coming. There isn't one.

---

## Phase 6 — Cleanup

- Delete the Swift-side fold and the now-dead heuristic paths.
- Retire `remoteCols` scroll-math duplication.
- Update `ARCHITECTURE.md`, `PROTOCOL.md`, `FEATURES.md`; remove the fallback
  description once the takeover path has shipped and aged.

---

## What this plan deliberately does not do

- **Make the Swift canvas smarter.** Every fix layered there treats a symptom one
  level above the cause. This is the mistake the current code already makes.
- **Add protocol to width negotiation.** No challenge-response, no version
  handshake — the same lesson as the pairing fix (#130): prefer invariants the
  system already has over new wire protocol.
- **Build a general-purpose terminal emulator for iOS.** The engine is fine; the
  gap is layout information.
- **Chase sub-cell typography or ligatures before correctness.** Fold boundaries
  beat glyphs.

---

## Traceability

| Item | Phase | Device gate | Human required |
|---|---|---|---|
| Visual/debug harness | 0 | yes | yes |
| `TERMINAL_SIZE` frame | 1 | prompt resize | yes |
| Wrap bit in FFI | 2 | no | no |
| Rust-side fold + blit | 3 | **yes, heavily** | yes |
| Activity card (4a) | 4a | yes | yes |
| Event timeline (4b) — needs Mac-side publishing | 4b | yes | yes |
| Takeover negotiation — **rejected** | 5 | n/a | decided |
| Cleanup — do not remove the §3 fallback | 6 | yes | yes |

Phases 0–4a are merged. Phase 3's device gate and 4b are outstanding.
