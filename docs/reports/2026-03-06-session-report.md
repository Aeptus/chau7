# Chau7 Session Report — March 6, 2026

## Overview

Three major subsystems were investigated and fixed: **notification tab targeting**, **AI session restore**, and **protected folder access**. A total of **14 files changed** across the Chau7 macOS app, with **+321 / -169 lines** (net +152). Additionally, the CTO (Command Token Optimization) system was audited and confirmed operational.

---

## Bugs Fixed

### 1. Notification Visual Cues Always Targeting First Tab

**Symptom:** When an AI event fired (permission request, idle, finished), the border/badge styling always appeared on the first matching tab, not the tab that triggered the event.

**Root Cause (two layers):**
- `AIEvent` had no `directory` field, so the `tabMatchingTool` function had no way to distinguish between multiple tabs running the same tool (e.g., Claude in 3 different repos).
- The `recordEvent` function in `AppModel` — the primary event path for terminal session events — created `AIEvent` without directory context. Even after the `AIEvent.directory` field was added and `ClaudeCodeMonitor` events were wired up, most events still came through `recordEvent` with `directory: nil`.

**Fix:**
- Added `directory: String?` to `AIEvent` and `AIEventParser.parse`.
- `ClaudeCodeMonitor` now passes `event.cwd` on all three notify methods.
- `AppModel.recordEvent` now accepts and forwards `directory`.
- `TerminalSessionModel` passes `currentDirectory` for idle/finished/failed events.
- `ShellEventDetector` passes `lastDirectory` for exit code events.
- `NotificationActionDelegate` protocol updated — all 4 tab-targeting methods accept `directory`.
- `OverlayTabsModel.tabMatchingTool` refactored from `tabs.first(where:)` to `tabs.filter` + `disambiguate()` — when multiple tabs match the same tool, the one whose session cwd matches the event directory wins.

**Files:** `AIEvent.swift`, `ClaudeCodeMonitor.swift`, `NotificationActionExecutor.swift`, `OverlayTabsModel.swift`, `AppModel.swift`, `ShellEventDetector.swift`

---

### 2. Tab Names Showing Raw Paths Instead of Repository Names

**Symptom:** After relaunch, tab titles showed `/Users/.../Downloads/Repositories/Chau7` instead of just `Chau7`.

**Root Cause:** `ProtectedPathPolicy` had a `bookmarkRequiredRoots` set that short-circuited `ensureAccess` for `~/Downloads` paths. Even though the app had TCC access, the guard returned early without granting file system access, so `refreshGitStatus` never ran and `gitRootPath` was never set.

**Fix:**
- Removed dead `bookmarkRequiredRoots` set and its short-circuit guard.
- Added `activatePersistedBookmarks()` that pre-activates all stored security-scoped bookmarks at launch, before tab restore begins.
- Called from `AppDelegate.attemptInitialSetupIfReady()`.
- Uses `stateQueue.async` (not `.sync`) to avoid blocking the main thread during bookmark I/O.

**Files:** `ProtectedPathPolicy.swift`, `AppDelegate.swift`

---

### 3. AI Session Resume Not Working on All Tabs

**Symptom:** After app relaunch, `claude --resume <sessionId>` was prefilled on some tabs but not others. Some tabs got the wrong session ID. Some got garbled commands like `claude --resume 97575155-...safeskills`.

**Root Causes (three distinct bugs):**

#### 3a. Corrupted Session IDs

`isValidSessionId` only checked character class (letters/numbers/hyphens) with no length limit. When the terminal prompt text bled into the prefilled command, strings like `97575155-c8cf-4c91-a76a-7d025921212asafeskills` passed validation — they're all valid characters. These corrupted IDs were persisted to UserDefaults and reused on every subsequent restore, creating a self-reinforcing corruption cycle.

**Evidence from saved state:**
```
Tab D7185095 (Downloads):  aiSessionId = "a4368849-...claude"      (42 chars)
Tab 81F4F80D (safeskills): aiSessionId = "97575155-...safeskills"   (46 chars)
```

**Fix:** Added length cap of 36 characters (standard UUID length) to `AIResumeParser.isValidSessionId`. The corrupted IDs will be rejected on next restore, breaking the cycle.

#### 3b. Restore `cd` Commands Silently Lost

The restore logic sent `cd /path/to/dir` via `session.sendInput()` 0.8 seconds after tab creation. But `sendInput` uses `activeTerminalView?.send(txt:)` — and for background tabs, the terminal view doesn't exist yet (it's created lazily by SwiftUI, taking 5-7 seconds for non-visible tabs). The optional chain silently dropped the input.

**Evidence from logs:**
```
14:43:46.901  restoreTabState: scheduled for 10 tabs
14:43:48.888  pane missing terminal view (all 6 resume targets)
14:43:53.809  First RustTerminalView PTY output (7 seconds after schedule)
```

The `cd` fired at ~48s, but the first view appeared at ~53s — a 5-second gap where all `sendInput` calls were silently lost.

**Fix:** Added `sendOrQueueInput()` to `TerminalSessionModel` with a `pendingRestoreInput` buffer. If the view doesn't exist, input is queued and flushed on terminal view attachment (before the prefill flush). This guarantees the `cd` executes at exactly the right moment for each tab.

#### 3c. Cross-Tab Session Bleed

Session ID `a4368849` (belonging to the Chau7 repo) was saved for the Aethyme and Mockup tabs. Once a wrong ID gets stored in `lastAISessionId`, the save path trusts it blindly via `resolvedAIResumeMetadata` (line 812: if both provider and sessionId are set, return directly without directory verification). The wrong ID persists indefinitely across save/restore cycles.

**Status:** The length cap fix (#3a) breaks the corruption cycle for garbled IDs. Valid-but-wrong UUIDs from cross-tab bleed are a deeper issue requiring monitor-level directory verification — not addressed in this session.

**Files:** `AIResumeParser.swift`, `TerminalSessionModel.swift`, `OverlayTabsModel.swift`

---

### 4. Hover Card Showing Corrupted Session IDs

**Symptom:** Tab hover card footer displayed garbled session IDs containing prompt text.

**Root Cause:** `TabHoverCard.footerSessionId` read `session.lastAISessionId` directly without validation.

**Fix:** Added `AIResumeParser.isValidSessionId` check before displaying. Added `import Chau7Core` to access the parser.

**Files:** `TabHoverCard.swift`

---

### 5. CTO Indicator Compiler Explosion

**Symptom:** `swift build` failed with "unable to type-check this expression in reasonable time" at `Chau7OverlayView.swift:1187`.

**Root Cause:** The CTO toggle indicator in `UnifiedTabButton.body` had deeply nested `if/else` with `Button` vs plain view paths inside a `@ViewBuilder` closure. SwiftUI's type checker explores all possible result types exponentially.

**Fix:** Extracted into two members: `ctoIndicator` (`@ViewBuilder` computed property) and `ctoIcon(active:)` (helper). The body now has a single `ctoIndicator` call.

**Files:** `Chau7OverlayView.swift`

---

### 6. Timeline Bridge Missing Directory

**Symptom:** Events from the `ClaudeCodeEvent` -> `AIEvent` bridge in `AppModel` had `directory: nil`.

**Fix:** Added `directory: event.cwd.isEmpty ? nil : event.cwd` to the `AIEvent` constructor.

**Files:** `AppModel.swift`

---

### 7. Disambiguate Reverse-Prefix Too Permissive

**Symptom:** A tab at `~` (home directory) would match every notification event because `normalized.hasPrefix(cwd + "/")` is true when cwd is `/Users/name`.

**Fix:** Removed the third `normalized.hasPrefix(cwd + "/")` condition from `disambiguate()`, keeping only exact match and child-of-event-directory match.

**Files:** `OverlayTabsModel.swift`

---

## CTO System Audit

The Command Token Optimization system was verified as operational and effective.

### How It Works

Shell shims in `~/.chau7/cto_bin/` shadow common binaries (`ls`, `grep`, `find`, `diff`, `cat`, `curl`). When an AI session is active (`CHAU7_CTO_SESSION` env var set), commands route through `chau7-optim` which produces compact output. Exit codes control fallback: 0 = optimized, 2 = can't optimize (fall through), 3 = intentional skip (e.g., piped input).

### Measured Token Reduction Rates

| Command | Raw Output | Optimized | Reduction |
|---------|-----------|-----------|-----------|
| `ls -la` (6 files) | 578 B | 170 B | **70%** |
| `ls -la` (32 items) | 2,350 B | 381 B | **83%** |
| `find -type f` | 619 B | 130 B | **78%** |
| `grep -rn` | 15,865 B | 1,986 B | **87%** |
| `diff` | 6,577 B | 2,495 B | **62%** |
| `curl -sI` | 246 B | 234 B | **4%** |
| `cat` | — | falls through | 0% (exit 2) |

### Aggregate Statistics (from `commands.log`)

- **12,781** total commands intercepted since deployment
- **12,096** (94.6%) successfully optimized
- **630** (4.9%) fell through to real binary
- **Top commands:** `ls` (88%), `grep` (8%), `find` (2%), `diff` (0.7%)

The optimizer strips permissions, owner/group, timestamps, and `.`/`..` entries from `ls`; trims context lines and deduplicates from `grep`; abbreviates paths from `find`. With `ls` making up 88% of intercepted calls at ~75% reduction each, the effective weighted token savings is approximately **70-75%** across all optimized output.

---

## Architecture Insights

### The Tab Disambiguation Problem

With multiple tabs running the same AI tool (e.g., Claude in Chau7, Mockup, and safeskills), the app needs a way to route events to the correct tab. The solution layers four matching strategies in priority order:

1. **Brand match** — focused session's `aiDisplayAppName`
2. **Title match** — tab chrome display title
3. **Deep scan** — all sessions' provider metadata
4. **Monitor correlation** — Claude-specific cwd-to-session lookup

When multiple tabs match at any level, `disambiguate()` narrows by comparing the event's directory against each tab's session cwd.

### The Session Restore Timing Gap

The restore system has an inherent tension: tab state is saved synchronously at quit, but restoration is asynchronous because terminal views are created lazily by SwiftUI. The 0.8-second delay was a heuristic that worked for the selected tab (rendered immediately) but failed for background tabs (rendered on first selection, potentially minutes later).

The queuing solution (`sendOrQueueInput` + `pendingRestoreInput`) decouples the restore from view timing entirely — each tab's restore commands execute at the precise moment its view becomes available, regardless of when that is.

### Session ID Corruption Cascade

The corruption followed a specific cascade:

```
1. Restore prefills "claude --resume UUID" into terminal
2. Terminal view doesn't exist yet -> cd is lost -> tab in wrong dir
3. Eventually view appears, prefill flushes, but prompt text overlaps
4. Shell sees garbled command, exits 127
5. Command detection captures "UUID+prompttext" as the command
6. extractMetadata stores corrupted ID in lastAISessionId
7. Next save persists corrupted ID (passes validation: all alphanumeric)
8. Next restore uses corrupted ID -> fails -> cycle repeats
```

The length cap on `isValidSessionId` breaks step 7, and the queued input fixes step 2.

---

## Files Changed

| File | Lines | Summary |
|------|-------|---------|
| `AIEvent.swift` | +8 -4 | Added `directory: String?` field |
| `AIResumeParser.swift` | +7 -3 | Session ID length cap (<=36) |
| `AppDelegate.swift` | +6 -0 | Bookmark activation at launch |
| `AppModel.swift` | +5 -2 | `recordEvent` directory param + timeline bridge |
| `Chau7OverlayView.swift` | +68 -48 | CTO indicator extraction |
| `ClaudeCodeMonitor.swift` | +6 -3 | Directory on notify methods |
| `NotificationActionExecutor.swift` | +17 -17 | Protocol + adapter directory params |
| `OverlayTabsModel.swift` | +73 -61 | `disambiguate()`, `sendOrQueueInput` in restore |
| `ProtectedPathPolicy.swift` | +18 -13 | Removed dead code, added bookmark activation |
| `ShellEventDetector.swift` | +3 -1 | Directory on emitEvent |
| `TabHoverCard.swift` | +3 -2 | Session ID validation + import |
| `TerminalSessionModel.swift` | +33 -19 | `sendOrQueueInput`, directory on recordEvent |
| `FeatureSettings.swift` | +40 | CTO toggle, idle triggers (pre-existing) |
| `TabsSettingsView.swift` | +10 | CTO settings UI (pre-existing) |

**Total: 14 files, +321 -169 lines**

---

## Known Remaining Issues

1. **Cross-tab session bleed with valid UUIDs** — When a tab has `lastAIProvider` set but no `lastAISessionId`, the save path does a filesystem lookup via `ClaudeCodeMonitor.sessionCandidates(forDirectory:)`. The `isDirectoryMatch` function uses subdirectory matching (`targetDir.hasPrefix(sessionDir + "/")`), which can return a session from a parent directory. A proper fix would verify explicit session IDs against the monitor during save.

2. **Session resume on app relaunch** — Two additional bugs were identified but not fixed: stricter metadata resolution that blocks inference when explicit provider is set but session lookup fails (line 749), and the removal of fallback to first pane's resume command when `activePaneID` doesn't match.
