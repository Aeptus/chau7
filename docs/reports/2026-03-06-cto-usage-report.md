# CTO Usage Report — March 5-6, 2026

## Executive Summary

The Command Token Optimization (CTO) system has been active for **1.2 days** across **28 sessions**, intercepting **12,743 commands**. The overall hit rate is **95.0%** (12,112 commands optimized), with a weighted byte-reduction rate of approximately **70-75%** on optimized output.

The system is dominated by `ls` (88.7% of all commands), which has a **100% optimization rate** and **70-83% byte reduction**. This single command accounts for the vast majority of token savings. `grep` (7.9%) has a mixed 49% hit rate due to flag incompatibilities, and `diff` (0.7%) has a **0% hit rate** — a known gap.

**Estimated total token savings**: ~8.5 million characters of output reduced to ~2.3 million, saving approximately **6.2 million characters** (roughly 1.5M tokens) in 28 hours.

---

## System Architecture

CTO works via shell shims in `~/.chau7/cto_bin/` that shadow real binaries (`ls`, `grep`, `find`, `diff`, `cat`, `curl`). When a tab has CTO active (`CHAU7_CTO_SESSION` env var + flag file in `~/.chau7/cto_active/`), commands route through `chau7-optim` which produces compact output.

**Exit code protocol:**
| Code | Meaning | Action |
|------|---------|--------|
| 0 | Successfully optimized | Use optimized output |
| 2 | Can't optimize | Fall through to real binary |
| 3 | Intentional skip (piped input) | Fall through silently |

Each command invocation is logged to `~/.chau7/cto_data/commands.log` with format: `timestamp|session_id|command|exit_code|status`.

---

## Global Statistics

| Metric | Value |
|--------|-------|
| **Total commands intercepted** | 12,743 |
| **Successfully optimized** | 12,112 (95.0%) |
| **Fell through to real binary** | 631 (5.0%) |
| **Skipped (exit 3)** | 0 |
| **Unique sessions** | 28 |
| **Active period** | Mar 5, 14:49 - Mar 6, 18:58 |
| **Days tracked** | 1.2 |

---

## Per-Command Breakdown

| Command | Count | Share | Hit Rate | Fallthrough | Byte Reduction |
|---------|------:|------:|---------:|------------:|---------------:|
| `ls` | 11,309 | 88.7% | **100.0%** | 0 | **70-83%** |
| `grep` | 1,011 | 7.9% | 49.1% | 515 | **87%** (when hit) |
| `find` | 264 | 2.1% | 90.9% | 24 | **78%** |
| `diff` | 90 | 0.7% | **0.0%** | 90 | 0% (all fallthrough) |
| `cat` | 45 | 0.4% | 95.6% | 2 | ~20-50% |
| `curl` | 16 | 0.1% | 100.0% | 0 | **4%** |
| `swift` | 8 | 0.1% | 100.0% | 0 | ~30% |

### Measured Byte Reduction (Sampled)

| Command | Raw Output | Optimized | Reduction |
|---------|-----------|-----------|-----------|
| `ls -la` (6 files) | 578 B | 170 B | **70%** |
| `ls -la` (32 items) | 2,350 B | 381 B | **83%** |
| `find -type f` | 619 B | 130 B | **78%** |
| `grep -rn` | 15,865 B | 1,986 B | **87%** |
| `diff` | 6,577 B | 2,495 B | **62%** |
| `curl -sI` | 246 B | 234 B | **4%** |
| `cat` | Variable | Compact | ~20-50% |

### What Each Optimizer Strips

- **ls**: Permissions, owner/group, timestamps, `.`/`..` entries. Outputs names + sizes only.
- **grep**: Trims context lines, deduplicates repeated matches, abbreviates file paths.
- **find**: Abbreviates common path prefixes, removes `./` prefix.
- **cat**: Trims trailing whitespace, collapses empty line runs, adds line count summary.
- **curl**: Strips redundant headers, keeps status + content-type + key headers.
- **swift**: Compacts build output, collapses progress lines.

---

## Temporal Analysis

### Daily Volume

| Day | Commands | Hit Rate |
|-----|----------|----------|
| **Mar 5** | 12,556 | 95.2% |
| **Mar 6** | 187 | 86.6% |

Mar 5 was an intense AI-assisted coding day. Mar 6 had lower volume — mostly manual work with a few AI sessions.

### Hourly Distribution

```
Mar 5 14:00   367  opt=  4.1%  |||||||
Mar 5 15:00  6,773  opt= 98.8%  ||||||||||||||||||||||||||||||||||||||||||||||||||  (PEAK)
Mar 5 16:00  4,780  opt= 98.3%  ||||||||||||||||||||||||||||||||||||
Mar 5 17:00    76  opt= 86.8%  |
Mar 5 18:00   229  opt= 87.3%  ||
Mar 5 19:00   230  opt= 89.6%  ||
Mar 5 20:00    67  opt= 67.2%  |
Mar 5 21:00    34  opt= 73.5%
---
Mar 6 06:00    22  opt= 59.1%
Mar 6 07:00    51  opt= 92.2%  |
Mar 6 08:00    29  opt= 62.1%
Mar 6 09:00    26  opt=100.0%
Mar 6 10-12    19  opt=100.0%
Mar 6 16-19    40  opt= 97.5%
```

**Key observations:**
- **Peak hour**: 15:00 on Mar 5 with **6,773 commands** — almost entirely `ls` calls from AI sessions doing deep directory scans.
- **Low hit-rate at 14:00**: The first hour had only 4.1% optimization because session `24D69DA5` was running `grep` with flags the optimizer couldn't handle (362/369 fallthrough).
- **Off-peak hours** (20:00-06:00) show lower hit rates due to more `diff` and `grep` usage relative to `ls`.

---

## Session Analysis

### Session Tiers

| Tier | Sessions | Total Commands |
|------|----------|----------------|
| **Heavy** (>1,000 cmds) | 2 | 11,331 (88.9%) |
| **Medium** (100-1,000) | 4 | 1,088 (8.5%) |
| **Light** (10-100) | 9 | 253 (2.0%) |
| **Minimal** (<10) | 13 | 71 (0.6%) |

Two sessions account for **89%** of all CTO activity — both were heavy AI coding sessions.

### Top 5 Sessions by Volume

| Session | Commands | Duration | Rate | Hit Rate | Primary Command |
|---------|----------|----------|------|----------|----------------|
| `83686409` | 6,675 | 50 min | 132.7/min | **99.8%** | ls (99.5%) |
| `76CD21BC` | 4,656 | 2.9 hrs | 27.1/min | **98.5%** | ls (96.9%) |
| `24D69DA5` | 376 | 34 min | 10.9/min | 3.7% | grep (98.1%) |
| `8BD94F26` | 303 | 13.4 hrs | 0.4/min | **90.8%** | grep (51.5%) |
| `3DA589D1` | 246 | 16.9 hrs | 0.2/min | **91.1%** | grep (61.4%) |

### Burst Analysis (Session 83686409)

This session hit **362 commands per second** at peak — an AI agent running rapid-fire `ls` operations during codebase exploration.

| Rate | Seconds at Rate |
|------|----------------|
| 10+ cmds/sec | 31 seconds |
| 2-4 cmds/sec | 1 second |
| 1 cmd/sec | 31 seconds |

The optimizer handled this load without any failures (99.8% hit rate, 11 fallthrough out of 6,675).

---

## Fallthrough Analysis

All 631 fallthroughs had **exit code 2** (optimizer can't handle this invocation). Zero exit-code-3 skips were recorded, meaning the pipe-filter bypass was never triggered during the logging period.

### Fallthrough by Command

| Command | Fallthrough | Total | Rate | Root Cause |
|---------|-------------|-------|------|------------|
| `grep` | 515 | 1,011 | **50.9%** | Flag combinations optimizer can't replicate |
| `diff` | 90 | 90 | **100%** | Diff optimizer always exits 2 |
| `find` | 24 | 264 | 9.1% | Complex `-exec` or path patterns |
| `cat` | 2 | 45 | 4.4% | Edge cases (binary files?) |

### grep Fallthrough Variability

The `grep` optimizer's hit rate varies dramatically by session:

| Session | grep Hit Rate | grep Commands |
|---------|--------------|---------------|
| `24D69DA5` | **2%** | 369 |
| `86F36B94` | 29% | 41 |
| `76CD21BC` | 64% | 110 |
| `3DA589D1` | 85% | 151 |
| `8BD94F26` | 82% | 156 |
| `8184B2B5` | **94%** | 31 |

This suggests the optimizer handles common `grep -rn` and `grep -r` well, but fails on:
- Complex flag combos (e.g., `-P` for Perl regex, `--include`, multiple patterns)
- Piped grep chains
- Binary file handling flags (`-I`, `-a`)

### diff: Complete Gap

The `diff` optimizer has **0% hit rate** across all 90 invocations. Every call falls through to the real `diff`. This is the most significant optimization gap — diff output from AI coding sessions can be large, and it's all being passed unoptimized.

---

## CTO Mode & Override Analysis

From the application log, CTO operated in `allTabs` mode (enabled for all tabs by default). Key observations:

- **10 flag files** were cleared during a teardown at 14:42:35 (app quit)
- **8 sessions** re-activated at 14:43:48 (app relaunch) — all with `mode=allTabs`
- **1 manual override** was recorded: tab `81F4F80D` (SafeSkills) was toggled to `forceOff` twice before being returned to default — likely user testing the CTO toggle UI
- **Health status**: The CTO runtime reported `healthState=healthy` with a decision recalc interval of ~162 seconds

---

## Weighted Token Savings Estimate

Using measured byte reduction rates and command volumes:

| Command | Commands (opt) | Avg Raw Bytes | Reduction | Bytes Saved |
|---------|---------------|---------------|-----------|-------------|
| `ls` | 11,309 | ~800 B | 75% | **~6.8 MB** |
| `grep` | 496 | ~5,000 B | 87% | **~2.2 MB** |
| `find` | 240 | ~400 B | 78% | **~75 KB** |
| `cat` | 43 | ~2,000 B | 35% | **~30 KB** |
| `curl` | 16 | ~250 B | 4% | **~160 B** |
| `swift` | 8 | ~3,000 B | 30% | **~7 KB** |

**Estimated total bytes saved: ~9.1 MB** over 28 hours of operation.

At ~4 characters per token, this translates to roughly **2.3 million tokens saved** — or approximately **$7-15 in API costs** at typical Claude/GPT-4 pricing (input token rates).

---

## Recommendations

### 1. Fix the diff Optimizer (High Impact)
The diff optimizer has 0% hit rate — it always falls through. With 90 invocations and potentially large output per diff, fixing this would capture meaningful savings. The optimizer exists in `chau7-optim` but apparently always exits 2.

### 2. Improve grep Flag Coverage (Medium Impact)
grep has a 51% fallthrough rate overall, but it varies by session. Profiling which specific flag combinations trigger fallthrough (likely `-P`, `--include`, multi-pattern) would allow targeted fixes.

### 3. Add Directory Context to CTO Log (Low Effort, High Value)
The current log format (`timestamp|session_id|command|exit_code|status`) doesn't include the working directory. Adding it would enable per-repo breakdowns, which is currently impossible for historical data. Format: `timestamp|session_id|command|exit_code|status|directory`.

### 4. Consider Reducing ls Frequency
The heaviest session ran 6,645 `ls` commands in 50 minutes (133/min). While CTO handles this gracefully, it suggests the AI agent may be running excessive directory listings. This might be addressable at the AI tool level.

### 5. Monitor Exit-Code-3 Usage
Zero exit-code-3 (pipe skip) events were recorded despite the feature existing. Either piped CTO commands aren't happening, or the detection isn't triggering. Worth verifying.

---

## Limitations

1. **No per-repo breakdown**: CTO session IDs are ephemeral (regenerated per app launch) and the log doesn't record the working directory. Sessions from prior app launches can't be mapped to specific repositories.

2. **Byte reduction estimates are sampled**: The reduction percentages come from manual testing of representative commands, not from measuring every intercepted command's actual input/output delta.

3. **Short observation window**: 1.2 days of data from a single user. Patterns may differ with longer usage or different work styles.

4. **No pipe/redirect tracking**: The log doesn't distinguish between interactive and piped command usage, so we can't measure how often optimized output feeds into subsequent processing.
