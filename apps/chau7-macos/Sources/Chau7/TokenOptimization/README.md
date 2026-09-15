# TokenOptimization

Command Token Optimization (CTO) -- intercepts CLI output to reduce token usage when AI coding tools read terminal content. Wrapper scripts shadow real binaries via PATH prepend; an optimizer binary rewrites verbose output into compact summaries.

## Files

| File | Purpose |
|------|---------|
| `CTOManager.swift` | Manages wrapper scripts, optimizer binary, PATH injection, and token-savings stats |
| `CTOFlagManager.swift` | Per-session flag files that activate/deactivate optimization; also extends `TokenOptimizationMode` with display names |
| `CTORuntimeMonitor.swift` | Runtime diagnostics: decision counts, deferred flushes, session tracking, debug summary |
| `CTONotifications.swift` | Notification names for mode changes and flag recalculations |

## Key Types

- `CTOManager` -- singleton that generates wrapper scripts in `~/.chau7/cto_bin/`, installs the `chau7-optim` optimizer, and prepends the wrapper directory to PATH
- `CTOFlagManager` -- enum with static methods for flag file CRUD in `~/.chau7/cto_active/`; `recalculate()` decides whether a session should be active based on global mode, per-tab override, and AI detection state
- `CTORuntimeMonitor` -- singleton tracking decision history, deferred activations, and per-session state for the debug console

## Architecture

1. Shell launch: `CTOManager` prepends `~/.chau7/cto_bin/` to PATH
2. Flag creation deferred until first prompt (avoids interfering with shell init)
3. `TerminalSessionModel.recalculateCTOFlag()` calls `CTOFlagManager.recalculate()` on `activeAppName` changes
4. Wrapper scripts check flag file existence; when active, route through `chau7-optim`

## Dependencies

- **Uses:** Chau7Core (TokenOptimizationMode, TabTokenOptOverride, RuntimeIsolation, Log)
- **Used by:** Terminal/Session (flag lifecycle), Settings (mode picker), Overlay (bolt icon)

## Migration note: retire the `chau7_optim` fork, vendor upstream rtk

`chau7-optim` is a hard fork of [rtk](https://github.com/rtk-ai/rtk) (~23k lines,
relicensed AGPL). Upstream is now fast-moving (v0.43+, multi-agent) while the fork
is a stale snapshot with only ~4 files of real Chau7 divergence
(`main.rs`, `tracking.rs`, `gain.rs`, `discover.rs`). The plan is to **keep CTO's
delivery layer** (PATH-shadow + per-tab + AI-detection — none of which rtk's
per-agent `rtk init` hook provides) and **swap the engine to vendored stock rtk**,
deleting the fork.

**De-risked empirically** against rtk 0.43.0 — CTO's wrapper contract survives
nearly as-is:

| Case | rtk exit | Wrapper action | OK |
|------|----------|----------------|----|
| optimized | `0` | `exit 0` | ✅ |
| `grep` no-match / `diff` differ | `1` | `exit 1` (real semantics) | ✅ |
| bad flag / parse error | `2` | falls through to real binary | ✅ (unchanged) |
| skip | *never emitted* | `exit 3` branch is dead code | ✅ |
| piped stdin | `0` | bypassed by `[ ! -t 0 ]` anyway | ✅ |

**Remaining work (no blockers):**
1. **Per-session gain → Swift.** `--session-id` is fork-only. `CTOSessionActivity`
   / `aggregateSessionActivity` (in `CTOManager`) already move per-session
   *activity* off the binary by reading `command.log`. Per-session *token totals*
   need either global-only stock-rtk stats or an upstreamed `--session-id`.
2. **Silence rtk's one-time "run `rtk init -g`" stderr nag** (env/flag or wrapper).
3. **Config, not code:** point at `rtk` + its DB (`~/.local/share/rtk/`) vs
   `chau7-optim` + `~/.chau7/`.
4. **Vendor** the stock rtk binary in the bundle; drop the `rust/chau7_optim` crate.

Gain JSON schema already matches (the fork inherited it), so `CTOGainStats` /
`DailyGainEntry` decode stock rtk's `gain --format json` unchanged. License is
fine: Apache-2.0 → AGPL is a permitted one-way combine.
