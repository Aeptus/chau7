# RTK Upstream Sync Process

CTO (`chau7_optim`) is forked from [RTK](https://github.com/rtk-ai/rtk) by Patrick Szymkowiak, licensed under MIT (see `LICENSE-RTK`).

This document tracks upstream changes and provides a repeatable process for porting improvements.

## Fork Point

- **Forked from**: RTK commit `5b59700` (2026-02-22), pre-v0.23.0
- **Fork commit**: `7cb9485` ("Fork rtk into chau7_optim: built-in token optimizer")

## Sync Log

| Date | RTK Version | Reviewer | Commits Reviewed | Actions Taken |
|------|-------------|----------|------------------|---------------|
| 2026-03-05 | v0.24.0 (`7ac5bc4`) | Claude | `5b59700..7ac5bc4` (25 commits) | Initial audit — see "Upstream Changes Since Fork" below |
| 2026-03-05 | v0.24.0 (`7ac5bc4`) | Claude | (same range) | Ported 6 fixes: git exit codes, git show blob, Playwright serde, Go build failures, git global options, find native flags. Investigated `discover` — skipped (CTO wraps automatically, no "missed" commands). |
| 2026-03-05 | — | Claude | CTO-only | Added `swift_cmd.rs` (build/test optimizer), `python_cmd.rs` (module dispatcher + Django test filter), `discover.rs` (top unhandled commands scanner). Fixed `pytest_cmd` quiet-mode summary parsing. |

## Upstream Changes Since Fork (2026-02-22 → 2026-03-05)

### Already Implemented Independently in CTO
| RTK Change | CTO Equivalent |
|-----------|----------------|
| `772b501` — passthrough fallback when Clap parse fails | CTO grep: full manual flag parser (more comprehensive) |
| `7ac5bc4` — find accepts native flags (`-name`, `-type`) | Ported: `parse_native_find_args()` + `has_native_find_flags()` in `find_cmd.rs` |

### New Features to Consider Porting
| Commit | Description | Priority | Notes |
|--------|-------------|----------|-------|
| `b934466` — AWS CLI + psql modules | Medium | New `aws` and `psql` commands with token-optimized output |
| `2b550ee` — per-project token savings (`gain -p`) | Low | CTO has per-tab stats via debug console instead |
| `4eb6cf4` — Playwright JSON parser fix | **Ported** | Removed incorrect `#[serde(default)]` from `ok`, `status` fields |
| `5cfaecc` — git push/pull/fetch/stash/worktree exit codes | **Ported** | Added `std::process::exit()` in all 5 error branches |
| `a6f65f1` — git show blob passthrough | **Ported** | Added `is_blob_show_arg()` for `HEAD:path` detection |
| `b405e48` — Go test build failure NDJSON events | **Ported** | Added `build-output`/`build-fail` handling + `build_failed`/`build_errors` fields |
| `982084e` + `68ca712` — git global options (`-C`, `-c`, `--no-pager`, etc.) | **Ported** | `git_cmd()` helper + `global_args` threaded through all functions + `extract_git_global_args()` pre-parser |
| `a413e57` + `f2caca3` — hook integrity checks | Skip | RTK-specific hook system, not applicable to CTO wrappers |

### RTK-Only Features (evaluated, not porting)
| Feature | Reason for Skip |
|---------|-----------------|
| `discover` command (full RTK version) | RTK's version scans for "missed" optimizations. CTO ported a simplified version (`discover.rs`, ~330 lines) that scans Claude Code session JSONL for top unhandled commands — useful for prioritizing new optimizer modules. |
| `init` command | Injects RTK hooks + CLAUDE.md into projects. CTO uses macOS app settings + wrapper scripts instead. |
| `hook.rs` / `integrity.rs` | Claude Code hook system for RTK activation. CTO uses per-tab env var injection via `TerminalSessionModel`. |
| `learn` module | Session analysis for learning patterns. Not applicable to CTO's architecture. |
| `ccusage` / `cc_economics` | Claude Code usage/cost tracking. CTO has its own debug console + runtime telemetry. |

### CTO-Only Improvements (not in RTK)
- Manual grep flag parser (full `-i`, `-E`, `-F`, `-w`, `-q`, `-c`, `-l`, combined flags)
- PATH recursion prevention (`main.rs` strips `~/.chau7/cto_bin` from PATH)
- Wrapper stderr → `/dev/null` (prevents log pollution)
- 14 additional commands: `npm`, `npx`, `curl`, `wc`, `format`, `proxy`, `cargo clippy/check/install/nextest`, `docker compose`, `gh repo/api`, `pnpm build/typecheck`, `swift build/test`, `python -m <tool>/manage.py test`
- `--skip-env` global flag for Next.js/tsc/lint/prisma
- `swift` optimizer: filters build progress lines, groups diagnostics by file, compact test summaries
- `python` dispatcher: routes `python3 -m pytest/ruff/pip` to specialized optimizers, filters `manage.py test` (Django), falls through for one-liners/scripts
- `discover` command: scans Claude Code sessions for top unhandled commands with false-positive filtering

## Step-by-Step Sync Process

### 1. Check for New Upstream Commits

```bash
# From the repo root
gh api "repos/rtk-ai/rtk/commits?per_page=20" \
  --jq '.[] | "\(.sha[0:7]) \(.commit.committer.date[0:10]) \(.commit.message | split("\n")[0])"'
```

Compare against the last reviewed commit in the Sync Log above.

### 2. Review Each New Commit

```bash
# View a specific commit's diff
gh api repos/rtk-ai/rtk/commits/COMMIT_SHA --jq '.files[] | "\(.filename) +\(.additions) -\(.deletions)"'

# Read the full diff
gh api repos/rtk-ai/rtk/commits/COMMIT_SHA --jq '.files[] | "--- \(.filename) ---\n\(.patch)"'
```

For each commit, classify it:
- **Bug fix in shared code** → Port immediately (High priority)
- **New command module** → Evaluate usefulness, port if relevant (Medium)
- **RTK-specific feature** (hooks, init, discover, CLAUDE.md) → Skip
- **Already implemented in CTO** → Note in sync log, skip

### 3. Port a Change

```bash
# Fetch the raw file from RTK at a specific commit
gh api "repos/rtk-ai/rtk/contents/src/MODULE.rs?ref=COMMIT_SHA" \
  --jq '.content' | base64 -d > /tmp/rtk_module.rs

# Compare with CTO's version
diff /tmp/rtk_module.rs apps/chau7-macos/rust/chau7_optim/src/MODULE.rs
```

When porting:
1. **Never overwrite the entire file** — CTO may have diverged (renamed types, added features)
2. **Cherry-pick the specific fix/feature** by reading the RTK diff and applying the logic manually
3. **Adapt naming**: RTK uses `rtk` in tracking strings; CTO uses `rtk` too (for gain DB compat) but types are prefixed with `CTO`
4. **Run tests**: `cargo test -p chau7_optim --manifest-path apps/chau7-macos/rust/Cargo.toml`
5. **Build release**: `cargo build --release -p chau7_optim --manifest-path apps/chau7-macos/rust/Cargo.toml`
6. **Install**: `cp apps/chau7-macos/rust/target/release/chau7-optim ~/.chau7/bin/chau7-optim`

### 4. For New Command Modules

If RTK adds a new command (e.g., `aws`, `psql`):

1. Copy the new `src/MODULE_cmd.rs` file
2. Add `mod MODULE_cmd;` to `main.rs`
3. Add the `Commands::` variant to the clap enum in `main.rs`
4. Add the match arm in `fn main()`
5. Add the command to `ctoRewriteMap` in `Sources/Chau7Core/TokenOptimization.swift`
6. Rebuild both Rust and Swift: `cargo build --release -p chau7_optim && cd apps/chau7-macos && swift build`
7. Reinstall wrappers: restart the app or toggle CTO off/on in settings

### 5. Update the Sync Log

After reviewing, add a row to the Sync Log table:

```markdown
| YYYY-MM-DD | vX.Y.Z (`short_sha`) | Your Name | `last_reviewed..new_sha` | Summary of actions |
```

## RTK Release Tracking

RTK releases are tagged on GitHub. To check for new releases:

```bash
gh api repos/rtk-ai/rtk/releases --jq '.[0:5][] | "\(.tag_name) \(.published_at[0:10]) \(.name)"'
```

### Release History (at fork audit time)

| Version | Date | Notable Changes |
|---------|------|-----------------|
| v0.24.0 | 2026-03-04 | AWS CLI + psql modules |
| v0.23.0 | 2026-02-28 | Mypy, per-project gain |
| v0.22.2 | 2026-02-20 | Grep flag compat, Playwright fixes |
| v0.22.1 | 2026-02-19 | Git branch creation fixes |
| v0.22.0 | 2026-02-18 | `wc` command added |
| v0.21.1 | 2026-02-17 | GitHub run view fixes |
| v0.21.0 | 2026-02-17 | Docker Compose support |
| v0.20.0 | 2026-02-17 | Hook audit mode |

## File Mapping (RTK → CTO)

RTK and CTO share identical file names under `src/`. Key structural differences:

| RTK | CTO | Notes |
|-----|-----|-------|
| `src/main.rs` | `src/main.rs` | CTO adds PATH stripping, `--skip-env` flag |
| `src/grep_cmd.rs` | `src/grep_cmd.rs` | CTO has full manual flag parser (diverged significantly) |
| `src/*.rs` | `src/*.rs` | Most modules are 1:1 with minor tracking string differences |
| `src/init.rs` | — | RTK-only (hook/CLAUDE.md injection) |
| `src/discover.rs` | `src/discover.rs` | Simplified CTO version: top unhandled commands scan |
| `src/hook.rs` | — | RTK-only (Claude Code hook system) |
| — | `src/swift_cmd.rs` | CTO-only (Swift build/test output optimization) |
| — | `src/python_cmd.rs` | CTO-only (Python -m dispatch + Django test filter) |
| — | `CTOManager.swift` | CTO-only (wrapper script generation) |
| — | `CTOFlagManager.swift` | CTO-only (per-tab activation) |
| — | `CTORuntimeMonitor.swift` | CTO-only (runtime telemetry) |
