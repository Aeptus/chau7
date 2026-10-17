# Chau7 Next: playbook for porting agents

How the port was built (1,174 of 1,175 inventory rows against the April 2026
Swift app), so the next sessions can continue the same way. Repository rules
win over this file: in `Aeptus/chau7`, follow `CLAUDE.md` (Aethyme broker
worktrees, `type(scope): summary` commits with Problem / Decision / Rationale
/ Validation sections for `feat`, `fix`, `refactor`, `perf`).

## Roles

- **Coordinator** (one session): splits open inventory rows into packages,
  starts one agent per package in its own worktree, merges the branches, runs
  the checks, regenerates `PARITY.md`, pushes.
- **Porting agent** (one per package): owns a set of rows, ports them, marks
  them, commits, reports. Never pushes.
- **Integration agent** (after each batch): merges the batch in a given
  order, keeps both sides of every conflict, removes duplicate
  implementations, wires the seams agents left for each other, smoke-tests.
- **Independent reviewer** (read only): coexistence, security, robustness,
  and a sample of `done` rows checked against the code. Its findings are
  fixed before publishing.

Packages that worked well: 6 to 8 agents per batch, one module or one
cohesive area each (for example "notifications engine + events + its core
pipeline", "tab bar and overlays", "MCP server"), with explicit row IDs and
explicit file ownership, and the inventory rows of other modules that only
waited for that area.

## Porting agent instructions (give these with BASE_SHA and a short NAME)

1. Start from the integration commit: `git reset --hard BASE_SHA`.
2. Read `apps/chau7-next/README.md`, `docs/rust-port/inventory/README.md`
   and `FORMAT.md`, `apps/chau7-next/crates/chau7_next/src/platform/README.md`,
   `docs/rust-port/DUAL-SHIP.md`, and your rows
   (`apps/chau7-next/scripts/parity.py --todo <Module>`).
3. For each row:
   - Re-read the Swift source first; about 10% of rows had small mistakes
     (fix the row text). Swift is the source of truth for behavior, defaults,
     keys and UI strings.
   - Pure logic in `chau7_next_core` with the Swift tests ported; UI and
     wiring in `chau7_next`. Check `chau7_next_core` before writing logic:
     most of `Chau7Core` is already ported.
   - macOS-only APIs only through `src/platform/` (trait, macOS
     implementation, stub elsewhere). GPUI already covers dialogs,
     clipboard, opening URLs and windows.
   - Settings: same `config.toml` keys as Swift; keys Swift lacks go under
     `[next]`; one domain file in `settings/` plus its section in
     `settings_window/`.
   - Paths: only through `DataRoot` (`chau7_next_core/src/data_root.rs`); a
     test fails on any Swift-owned path elsewhere.
   - Shortcuts and menus as in Swift on macOS (a test checks every Swift
     default shortcut is bound exactly once); Cmd becomes Ctrl+Shift on
     Linux and Windows.
   - Mark the row: `parity.py --set <ID> done|partial <rust files>`. Never
     run `--write` (the coordinator does, to avoid conflicts on the table).
   - Never skip silently: closest equivalent plus an explanation.
4. Own build dir: `export CARGO_TARGET_DIR=$(apps/chau7-next/scripts/dev/mk-target.sh NAME)`.
   Never share a target dir between worktrees. Delete it at the end.
5. Before each commit: `cargo fmt --all`, `cargo clippy --workspace
   --all-targets -- -D warnings`, `cargo test --workspace`,
   `parity.py --check` (the stale-PARITY message is expected).
6. UI work: run the app under Xvfb with a fresh `CHAU7_NEXT_HOME_ROOT` and
   `HOME` (short path, so sockets fit), drive it with `xdotool` (Cmd is
   Ctrl+Shift on Linux), capture with `import -window root`, look at every
   screenshot. Kill only your own processes.
7. Commit every few rows; no em dashes anywhere; do not push.
8. Final report: branch, last commit, rows done / partial / missing with one
   line per non-done row, edits outside the area, what to test by hand on a
   Mac.

## Coordinator checklist per batch

1. Integration commit pushed; per-agent target dirs seeded from a fresh main
   build.
2. Start the agents (one message, several agents, each with BASE_SHA, NAME,
   rows, owned files, and the seams it must expose for others).
3. Merge in dependency order (or hand the batch to an integration agent with
   a notes file listing each branch's work, overlaps and seams). Helpers:
   union of `pub mod` lines for `chau7_next_core/src/lib.rs`; for inventory
   row conflicts keep, per ID, the most advanced status.
4. For a batch that defers checks, wait until all changes land, then freeze
   and record the integrated revision. Run aggregate compiler, test and native
   acceptance gates sequentially against it; keep read-only reviews parallel.
   Cargo's job setting controls in-command parallelism; every concurrent
   worktree needs a private target directory.
5. Clean build of local crates, all checks, `scripts/dev/mac-typecheck.sh`,
   Xvfb smoke test, `parity.py --write` and `--check`, push.

## Pitfalls already hit

- One shared `CARGO_TARGET_DIR` across worktrees mixes sources (path crates
  hash identically). Use `mk-target.sh`.
- Hard-linked `.cargo-*lock` files make every agent wait on the others
  (`mk-target.sh` removes them).
- The 10 minute limit per shell command: long builds go to the background
  (`nohup ... &`) and are polled.
- Disk: `target/debug/incremental` grows fast; delete it between batches.
- Two agents implementing the same feature from different rows (restore,
  minimal mode, clear screen, Cmd-click): name file ownership and seams
  explicitly in each package.
- Duplicate `actions!` declarations compile but crash at launch: the
  integration smoke test catches it (a test now does too).
- Tests that hard-code Linux paths or macOS tools: gate them with `cfg`.
