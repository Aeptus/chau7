# Changelog

All notable changes to Chau7 will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed
- **Process-Tree Scan Goes Native (No Subprocess)**: The live AI-tool process-tree snapshot used to shell out to `ps` on a 1.5s timer — and a second `ps` scan added with argv-based detection had doubled the spawn rate, making the scanner the app's top CPU consumer in a live sample. The snapshot now enumerates the process table in-process via libproc (`proc_listallpids` + `proc_pidinfo`) and reads argv via `KERN_PROCARGS2` only for interpreter processes (`node`/`python`/`ruby`/`npx`), eliminating the recurring `ps` fork/exec entirely. A single `ps -axo pid,ppid,args` scan remains as a fallback if native enumeration ever fails, and a shared `buildSnapshot` keeps both paths producing identical results.
- **Terminal Poll Skips Trace Bookkeeping in Release**: `RustTerminalFFI.pollEvents` runs on the background-drain hot path (up to 60×/s per terminal) and unconditionally did per-poll counter/clock bookkeeping for trace logging even when trace was disabled. That work is now gated behind `Log.isTraceEnabled` (a cached `static let`), so a release build does no per-poll logging work.
- **Memory Pressure Now Reclaims Memory Instead of Only Logging**: OS memory-pressure signals were previously just logged — no cache shrank in response. A new `MemoryPressureCoordinator` fans the signal out to registered `MemoryReclaimable` caches: `.warning` sheds cheap, regenerable memory while `.critical` releases aggressively, and the bytes reclaimed are recorded on the memory-pressure breadcrumb so the response is observable. Per-tab terminal transcript rings (up to ~10 MB each, fully regenerable backfill data) are the first registrant — trimmed by half on warning, released entirely on critical. The dead, never-started `MemoryPressureMonitor` was removed.

### Fixed
- **Tab Restore Stops Writing Multi-MB Blobs to UserDefaults on Autosave**: Session autosave (every 30s) re-serialized the entire preferences plist on the main thread by writing ~7 MB of tab/scrollback state into UserDefaults — the source of the recurring large-restore-payload breadcrumb (~176×/day). The file-based, integrity-checked restore bundle is now the primary store and is read first on launch for both the primary window and additional windows; UserDefaults is written only at termination as a one-version downgrade-safety mirror, with on-disk JSON backups kept as the final fallback. The bundle read is all-or-nothing (a corrupt sidecar falls through to the UserDefaults/backup chain), so restore safety is preserved.
- **Proxy High-Water Breadcrumb No Longer Floods**: The `proxy_request_high_water` incident breadcrumb fired on nearly every AI turn — request bodies grow a few KB per turn as conversation context accumulates, so a strictly-greater high-water gate tripped constantly (~90 `warning` entries/day). It now requires a material step over the prior mark and is recorded at `info` severity: it is diagnostic context correlated against memory-pressure incidents, not a warning condition.

## [0.3.0] - 2026-06-04

### Added
- **Terminal Runtime Facts**: The Rust terminal now exposes alternate-screen state through the Swift FFI and debug-state snapshot. Higher layers can distinguish full-screen TUI surfaces from normal shell scrollback without hardcoding provider names, and the alternate-screen regression test now asserts the state transition around `?1049h` / `?1049l`.
- **Generic TUI Scroll Policy**: Chau7Core now owns a pure `TerminalScrollPolicy` that chooses between normal scrollback, forwarding scroll to mouse-aware TUIs, and transcript history for alternate-screen surfaces with no terminal scrollback. Focused tests cover shell scrollback, mouse-reporting TUIs, alternate-screen transcript fallback, and visible transcript overlay scrolling.
- **Per-Tab Terminal Transcript Capture**: Terminal sessions now retain a bounded PTY transcript ring and mark command boundaries so output detected after an AI tool launches can be backfilled into the AI PTY log. The transcript ring is lock-protected, byte-bounded, and covered by tests for trimming, command-boundary backfill, and boundary behavior after trims.
- **TUI Transcript Scrollback Overlay**: Alternate-screen TUIs that do not expose normal terminal scrollback now get a generic transcript overlay when the user scrolls up, while mouse-reporting TUIs still receive scroll events directly. Terminal diagnostics and MCP `tab_output(source: "pty_log")` can now fall back to the in-memory transcript when no durable AI PTY log exists yet.
- **Registry-Driven Quality Firewall**: Git hooks now enter through thin Husky shims and delegate to `pnpm quality:*`, where a central Node runner executes gates declared in `scripts/quality/registry.mjs`. The new system adds staged-file secret/dependency/Python/JS guardrails, affected-surface pre-push scoping, conservative full-suite triggers, live dependency audits, registry-backed quality runner tests, content-hash caching, per-gate rerun commands, failure logs, dirty-worktree handling, release-only GitHub Actions policy validation, and focused runner/registry tests.
- **Grapheme-Cluster-Aware Terminal Model**: The Rust→Swift FFI snapshot now ships UTF-8 grapheme cluster bytes alongside the cell array, so ZWJ emoji (`👨🏽‍💻`), regional-indicator flags (`🇫🇷`), VS16 emoji presentation (`❤️ ✈️`), and NFD-decomposed sequences (`e + ́` → `é`) all survive end-to-end instead of being truncated to their first codepoint. Cell layout (`width`, `continuation`) is now explicit from Rust's `WIDE_CHAR` / `WIDE_CHAR_SPACER` flags — the Metal renderer no longer probes glyph advance to decide cell span, and wide glyphs tile correctly across two cells. NFC normalization runs in the snapshot loop via the `unicode-normalization` crate, so decomposed and precomposed forms share one atlas slot. The Metal glyph atlas is re-keyed by cluster bytes (`Data`) instead of codepoint; multi-codepoint clusters share a single atlas slot. The fragment shader gains a `colorGlyphFlag` (bit 12) branch that samples color-bitmap atlas slots (sbix / COLR / CBDT) directly as RGBA, with the per-glyph detection helper (`isColorGlyph`) left as a focused follow-up. Remote-snapshot wire format bumped CHG1 v1 → CHG2 v2 to carry the cluster buffer; iOS playback updated to match.
- **Split Restore Bundle Sidecar**: Tab autosave now dual-writes an integrity-checked restore bundle under Application Support. Critical tab, pane, split-layout, and AI resume identity fields stay in a compact manifest, while heavier scrollback, command blocks, and preview data move to SHA-256/byte-count-verified sidecar context files.
- **Full Disk Access Guardrails**: Chau7 now detects when it loses macOS Full Disk Access — which silently breaks every spawned CLI (codex, claude, shells) with "Operation not permitted" in protected folders like `~/Downloads` while the app itself looks fine — and surfaces a one-click-fixable alert deep-linking to the Full Disk Access settings pane, both proactively (a probe at launch and on app activation) and reactively (attributing a child-process `EPERM` in a protected folder to FDA via a two-factor classifier). A build-time `check-signing.sh` warns when a rebuild or re-sign would orphan the app's TCC grants, and Productivity → Permissions shows a Full Disk Access status row.

### Changed
- **Event Emitters Depend on a Publishing Boundary**: App-level and shell event emitters now depend on a narrow `AIEventPublishing` protocol instead of concrete `AppModel` state. Construction sites use the explicit `eventPublisher:` label, keeping detection/emission components focused on event production while `AppModel` remains the owner of routing, notification ingestion, observability, and recent-event storage.
- **Event Source Adapter Policy Centralized**: Generic AI, terminal-session, fallback-history, shell, app, API proxy, and unknown-source notification events now share one mapped-source adaptation path with source-specific policy isolated in a small registry strategy. Raw-type preservation, routing identity requirements, fallback reliability, and unsupported-event reasons stay covered by focused registry tests, reducing drift between event sources without changing the public `AIEvent` model.
- **CTO Read Optimization Pipeline Centralized**: File-backed reads and stdin-backed reads now share the same `chau7-optim read` filtering, truncation, non-empty-output preservation, and line-number formatting pipeline. This reduces drift between `cat`/file reads and stdin reads while keeping the previously added non-empty read guard in one tested place.
- **Restoration Autosave Reuses Idle Snapshots**: Autosave now routes pane scrollback persistence through the bounded tail export and keeps a versioned restoration cache while the terminal is idle. Real PTY output, injected buffer changes, and scrollback clears invalidate the cache, so restoration stays current without repeating idle full-buffer work.
- **Bounded Styled Scrollback Export**: The Rust terminal now exposes a bounded ANSI-styled tail export for restoration paths, so callers can request the recent terminal tail without constructing a multi-megabyte full-buffer string first.
- **Notification Banners Show Project Context**: Native and AppleScript fallback notifications now keep the title focused on the tool/state while adding a subtitle with repo, tab, or directory context when available, e.g. `Claude: Finished` with `Repo: Chau7 · Tab: Mockup`.
- **Deferred Restore Scheduling Is Selection-Aware**: Background identity hydration now backs off briefly after user tab switches and chooses the nearest pending tab to the selected tab instead of blindly draining FIFO. Restore telemetry records stage timings, payload bytes, and RSS deltas per tab so startup and fast-switch pressure can be diagnosed from logs.
- **AI Detection Simplified**: Removed the `.restored`-phase output-match lock, `shouldAllowRestoredProviderOverride`, and the `allowRestoredProviderOverride` parameter on `AIDetectionState.handleOutputMatch`. These existed to prevent output patterns from flipping persisted tab identity, but they also blocked legitimate provider switches when persistence drifted. Identity is now owned by the live process-tree signal; output patterns are gated by an explicit `authoritativeAppName` hint only. Public API of `AIDetectionState` is narrower — callers on the old parameter must drop it.

### Fixed
- **Telemetry Repair No Longer Exhausts Memory**: The deferred telemetry repair sweep read entire agent rollout JSONL files into memory (as `Data` *and* `String`); a single multi-GB Codex session drove the app to a 30+ GB footprint and triggered system out-of-memory kills (jetsam / WindowServer watchdog death). Transcript reads are now byte-bounded (oversized files parse only a trailing tail), the repair is idempotent — a new `transcript_repair_attempted_at` column stops it re-reading the same runs every sweep when metrics can't be derived — and JSON-parse churn is drained between runs.
- **Side-Panel Notes Autosave Immediately**: Opening a default text side panel now creates/loads the tab-scoped `.chau7/sessions/<tab-id>/note.md` immediately instead of leaving the editor untitled until the first manual save. Dirty note content is also flushed before the side panel is closed, so quick type-and-close workflows do not lose the note before the debounce fires.
- **CTO Read Optimization No Longer Returns Empty Output for Non-Empty Reads**: `chau7-optim read` now preserves the original command output whenever filtering would collapse a non-empty file, stdin payload, or selected range to whitespace-only output. This prevents comment-only/config-like files from making `cat`/read-style commands appear broken to Claude/Codex while preserving true empty-range behavior such as `sed` reads past EOF.
- **Detached HEAD No Longer Appears as a Branch Named `HEAD`**: Git branch reports now pass through one normalization policy before reaching repository models, identity cache, or passive tab chrome. Live git probes and shell OSC 9 reports suppress the detached-head sentinel and explicitly clear cached branch identity when the shell reports `HEAD`, preventing stale or misleading branch badges.
- **Branch Detection Survives Split OSC 9 Reads**: Chau7 now buffers OSC 9 terminal metadata across PTY chunks before dispatching branch, repo-root, exit, and foreign notification events, so startup repo metadata is not lost when escape sequences are split across reads.
- **Branch Detection No Longer Mutates Previous Repo Models**: Shell-reported repo-root changes now swap the terminal session onto the shared model for the reported root before applying branch updates, so moving from one repo to another cannot leak the new branch into the old repo's tabs.
- **Metal TUI Symbols Keep ANSI Color**: Metal color-glyph detection now honors emoji presentation before sampling embedded RGBA glyph data, so Codex/Claude text symbols like `✳` and `⏺` remain ANSI-tinted while real emoji such as `✅`, `🧪`, and achromatic FE0F symbols still render with embedded color. Grapheme atlas bearings are stored in baseline-local coordinates instead of leaking atlas packing positions.
- **Deferred Restore Now Hydrates Background Tabs Without Making Them Live**: The background restore scheduler no longer performs the full interactive tab restore for non-selected tabs. It now applies only factual AI identity metadata (provider/session ID) for routing and labels, leaves the saved state parked, and defers command-block restore, active AI state, startup bootstrap tracking, and resume-prefill delivery until the user selects the tab. Parked state is still used for export, close/reopen, and cross-window transfer, so autosave does not drop resume input or command history while avoiding live-render pressure from old restored tabs.
- **AI Session Routing Uses an Indexed Fact Table Before Recovery Scans**: Notification delivery, history adoption, and runtime strict-session lookup now route through a cached cross-window `TabRoutingIndex` keyed by explicit tab ID, AI session ID, provider/tool identity, and directory. The index is built from live terminal sessions plus deferred restore state, so background tabs with persisted Claude/Codex session IDs can be addressed before full restore runs. `TabResolver` remains as a recovery fallback, but normal authoritative events no longer start with repeated all-tab deep scans that produced ambiguous routing loops under many restored AI tabs.
- **ChatGPT Detection Stricter**: Tightened the output patterns for ChatGPT to require CLI-style indicators (e.g. `chatgpt cli`, `openai.com/v1`). This prevents false positives in projects named `Mockup` where proxy or analytics logs mentioning `openai.com` would incorrectly trigger a tab rename.
- **Attention Diagnostics Expose State/Style Split**: Tab summaries, state snapshots, and reconciliation logs now include a compact `attentionReport` with each tab's effective statuses, desired attention kind, state-owned marker, visible style summary, and selection state. Bug reports can now show cases like `status=waitingForInput` plus `style=none` directly instead of requiring separate log correlation.
- **Tab Highlights Now Reconcile From Live Session State**: Overlay tabs now run a state-only attention reconciler on terminal readiness changes, tab selection, initialization, and the tab-bar watchdog. If any pane in a tab is `waitingForInput` or `approvalRequired`, Chau7 applies a persistent orange attention style directly from session state without dispatching notification banners, sounds, or dock bounces. When the state resolves, only the style owned by this reconciler is cleared, so unrelated success/error/conflict notification styles are left alone.
- **State-Driven Tab Attention Policy Added**: Chau7 now has pure, tested rules for deriving tab attention from terminal session state (`waitingForInput` / `approvalRequired`) instead of treating notification delivery as the only source of truth. The policy defines precedence across split-pane sessions, repair behavior when a state-owned highlight disappears, and conservative clearing rules that avoid removing unrelated notification styles.
- **Terminal Wait-Pattern Detection Now Backstops Provider Notification Delays**: When an AI TUI output pattern transitions a terminal session from `running` / `stuck` into `waitingForInput` or `approvalRequired`, Chau7 now emits a provider-scoped heuristic attention event immediately instead of waiting solely for Claude/Codex hook delivery. This closes the gap where render telemetry already knew a tab was `waitingForInput`, but the tab was not highlighted until a later provider `waiting_input` event arrived. The heuristic event keeps existing resume-prefill and restored-session suppressions, carries the exact tab/session identity when available, and remains lower confidence than authoritative provider hooks so normal duplicate/fallback suppression still applies.
- **Waiting-Input Attention No Longer Gets Cleared by Follow-Up Events**: The notification pipeline used to clear persistent tab attention at event ingress for any authoritative non-permission event before duplicate/rate-limit/drop handling ran. A repeated `waiting_input` event could therefore clear the `bell.fill` highlight and then be dropped as a duplicate, leaving an agent waiting for input with no tab marker. Persistent attention is now cleared only by real resolution states; `permission`, `waiting_input`, `attention_required`, and Claude idle messages that explicitly say "waiting for input" keep the attention marker intact. Claude raw `idle` payloads with waiting-input wording are canonicalized as `waiting_input` instead of being routed through disabled idle actions.
- **iPhone Remote App Keeps Approval Sync Alive Across Relay URL and Background Edges**: The iOS remote app now derives its pending-approval polling URL from the relay base even when pairing stores a websocket `/connect` URL, ends the approval keepalive once no approval responses remain regardless of app foreground state, and hardens background-task expiration handling so an expired task cannot be ended twice or orphan the active task identifier. The project also drops the notification auth request back to alert/sound/badge and records explicit push-entitlement / iOS 18 deployment settings in the Xcode project.
- **Dangerous Output Highlighting Now Ignores Prose Mentions**: The dangerous-command highlighter used the same substring matcher for executable command lines and rendered output rows, so explanatory text like “do not run rm -rf” or “DROP TABLE appears in the migration notes” could be highlighted as if it were an actual command. Output scanning now strips prompt/markdown decorations, requires token boundaries plus an executable-style prefix, and keeps command-line matching permissive for real shell input. Focused tests cover wrapper commands, prompt-prefixed commands, and prose false positives.
- **Metal Now Forces Full Cell Refreshes in Scroll Storms and Visible Noninteractive Windows**: The corrupted shell line reports were consistent with stale Metal cell instances surviving throttled partial redraws: if a near-full-grid burst or background noninteractive refresh arrived with an incomplete dirty-row set, the renderer could legally reuse old cell instances for untouched rows and visually mix old glyphs with new command text. `RustMetalDisplayCoordinator` now upgrades those risky sync frames to full Metal instance refreshes whenever the tab is already in a scroll storm, is visible but noninteractive, or is already touching most rows. The normal interactive incremental path stays intact, and focused unit tests pin the full-refresh policy thresholds.
- **Shared Metal Coordinator No Longer Replays Stale Render Requests Across Tab Handoffs**: `RustMetalDisplayCoordinator` reuses a shared Metal render path across terminal views, but switching the coordinator to a different view left pending sync/present state in `TerminalRenderRequestCoalescer`. Under width changes or rapid tab switches, the new tab could briefly present work scheduled for the previous view before its own grid sync caught up, producing visibly wrong `Redb` frames. Cross-view handoff now resets pending render-request state and related retry/deferred-sync bookkeeping before the new view takes ownership, and a focused coalescer regression test pins the reset behavior.
- **Speculative Local Echo No Longer Survives Shell Redraws or View Demotion**: The duplicate-character reports were caused by Chau7 keeping speculative local-echo overlay cells alive after authoritative shell redraw output or after the view stopped being live/interactive. The real shell echo then appeared elsewhere while the optimistic copy remained on-screen. Local echo now immediately yields to redraw-style PTY output (`ESC`/cursor-motion or carriage-return rewrites) and is also cleared whenever a terminal leaves live presentation or interactivity, so predicted input cannot linger into passive snapshots or shell-owned repaints. Regression tests cover both redraw bypass and render-phase cleanup.
- **Deferred Codex/OpenAI Run Extraction No Longer Blocks Run Finalization**: `TelemetryRecorder.endRun` used to do provider transcript extraction synchronously before finalizing the run row. For Codex/OpenAI sessions that meant tab-close and run-end bookkeeping could sit behind history parsing and PTY fallback work on the hot path. Completed runs for those providers now finalize immediately with any already-known metrics, then perform transcript/tool-call extraction on a background utility queue and rewrite the completed run if richer content is found. Claude and deferred-shutdown paths stay synchronous, and a focused unit test now pins the provider/content-mode gating rule.
- **Metal Local Echo Presents and Clears Immediately**: The Metal bridge now consumes local-echo overlay cells, but local-echo overlay changes still only invalidated the CPU `RustGridView`. Active Metal tabs therefore waited for the next PTY/grid sync before predicted input appeared or cleared, defeating local echo's latency-hiding path and risking stale predicted characters after Enter/Ctrl+C. Metal-active overlay updates and clears now mark the grid dirty and call the display-sync callback immediately, while CPU rendering keeps its existing `needsDisplay` invalidation.
- **TerminalOutputCapture No Longer Aborts the App on Disk-Full / Closed-FD**: Thread `com.chau7.ptycapture` raised an uncaught `NSFileHandleOperationException` from `-[NSConcreteFileHandle writeData:]` at `TerminalOutputCapture.swift:71` and aborted the process (crash report 2026-05-10 09:45:15, disk at 97 % full, ENOSPC propagating into the write). `record(data:source:)` and `recordMarker(_:)` were calling the legacy `FileHandle.write(_: Data)` overload, which bridges to ObjC `writeData:` and **raises NSFileHandleOperationException** on `ENOSPC` / `EIO` / `EBADF` / `EPIPE`. Swift cannot catch ObjC exceptions, so the throw walked straight to `objc_exception_throw → __cxa_throw → abort()`. Both call sites now route through a private `appendOrDisable(_:)` helper that uses the throwing `write(contentsOf:)` API (already in use in the trim path on the same file), and on any error closes the handle, sets a session-scoped `isCaptureSuspended` flag, and short-circuits all further writes for the rest of the session. Reopening on every error would just reproduce the disk-full case forever; this is a debug-only capture path (`CHAU7_PTY_DUMP=1`), so failing closed beats crashing the app or spinning the same syscall.
- **OSC 7 Now Fires Before `CHAU7_STARTUP_CMD` Seizes the PTY**: Restored Claude / Codex tabs hit the resume-prefill OSC-7 watchdog (`Resume prefill: force-clearing isShellLoading after 8 retries`) on every launch, costing ~13 s on the prefill path before the watchdog finally cleared `isShellLoading`. The integration scripts (zsh, bash, fish) ran the user-supplied `CHAU7_STARTUP_CMD` *before* defining/running `smartoverlay_precmd` and registering `precmd` / `chpwd` / `--on-variable PWD` hooks. For AI-tab restoration the startup command IS the AI launcher, which seizes the PTY indefinitely — so the inline OSC 7 emission and hook registrations that come after it never executed at all, and alacritty's `onDirectoryChanged` callback (the path that calls `handlePromptDetected` and clears `isShellLoading` when shell integration is silent) never fired. The script blocks now define the integration and emit OSC 7 inline first, then run the startup command last; bash/fish gained an explicit inline `smartoverlay_precmd` call (zsh already had one). Side effect: also closes the "View 6 slow .zshrc / missing OSC 7" pattern seen in the same log sweep — slow rc files no longer delay the initial OSC 7 past the watchdog threshold.
- **RuntimeSession `.processCrashed` Now Valid From `.ready`**: When `RuntimeSession.handleApprovalTimeout` hit its 3rd consecutive timeout (`approvalTimeoutFailureThreshold`), it called `failTurn(reason: "approval_timeout")` first — which transitions `.awaitingApproval` → `.ready` via `.turnCompleted` — *then* attempted `transition(.processCrashed("approval_timeout_stuck"))`. The state-machine table didn't have a `(.ready, .processCrashed)` rule, so the failure transition was silently rejected and the session sat in `.ready` with `consecutiveApprovalTimeouts == 3`. Every subsequent approval re-tripped the same loop, logging `"approval timed out 3x but failed transition was rejected in state=ready"` indefinitely on `rs_7544542c` (sub-session). `.ready → .processCrashed → .failed` is now an accepted transition: a backend process can absolutely crash while idle, and the gap was the only non-terminal state missing from the crash path. Covered by a new state-machine unit test (`testReadyToFailed_processCrashed`); the existing `testRepeatedApprovalTimeoutsMarkSessionFailed` integration test now actually verifies what it claims.
- **Codex Quits Cleanly Instead of Riding the SIGKILL Path**: AI TUIs (Codex, Claude Code, …) implement a "Press Ctrl+C again to exit" confirmation, so the single SIGINT the termination ladder sent to the shell process group put Codex in its quit-prompt state but never exited it. The 2 s SIGTERM that followed bypassed Codex's own shutdown handler — it never tore down the WebSocket session or its `codex-darwin-arm64` PTY child cleanly — and the chain rode all the way to the 5 s SIGKILL stage on every Codex tab close (logs on 2026-05-08: `close_requested_ms ≈ 8500`, full SIGINT → SIGTERM → SIGKILL ladder, child `codex --model gpt-5.3-codex` left orphaned for the descendant kill). `forceTerminateShellProcessGroupIfNeeded` now schedules a second SIGINT 600 ms after the first one for AI sessions only — the standard double-Ctrl+C exit pattern — and surfaces a `second_sigint_ms` field in the `terminationDiagnosticsSummary` so future SIGKILL warnings show whether the second SIGINT actually fired. Plain shells are unchanged (they exit on the first SIGINT) and the SIGTERM/SIGKILL backstops are preserved.
- **Multi-Window Startup Live-Frame Race**: Per-window `OverlayTabsModel` registers its `terminalSessionVisibleFrameReady` observer in `init`, but the SwiftUI terminal view's first paint can fire the notification synchronously *before* the second window's init completes. The observer never sees it, the `StartupRestoreCoordinator` stops waiting, and the 5 s fallback synthesizes a live-frame call for every multi-window launch (`fallback_5s_no_live_frame` warning, both windows, exactly 5 s elapsed). The model now exposes `replaySelectedTabLiveFrameIfAlreadyPresented(reason:)`, called from `AppDelegate.showOverlayWindow` immediately after `noteWindowVisible` arms the fallback timer; if the selected session has a tracked visible-frame marker (`lastVisibleFramePresentedAt != nil`), it dispatches the live-frame note synchronously, and the fallback timer cancels itself. The timeout force-live path now preserves the next real visible-frame handoff instead of canceling it, so a late Metal frame can still reach startup restore naturally. Idempotent (the coordinator dedups), safe on single-window launches (the observer fires naturally there).
- **Tab cwd Tracks Claude Code Session Directory**: Tabs hosting Claude Code's TUI used to keep their `currentDirectory` stuck at the pre-TUI value when the user `cd`'d inside Claude. The host shell's `chpwd` hook can't fire for `cd`s typed into the alt-screen TUI — Claude takes over the PTY and the shell never sees a `cd` execute, so no `OSC 7` round-trip happens. Symptom on 2026-05-09: a tab's reported pwd matched the directory the shell launched in, not where the user moved Claude to. Claude's hook events already carry the session's authoritative cwd; `handleClaudeCodeMonitorEvent` and `handleClaudeCodeSessionIdle` now push it onto the bound tab's session via the new `TerminalControlService.updateSessionDirectoryAcrossWindows(tabID:directory:)` helper, so tab-pwd-derived UI (snippet context, repo grouping, telemetry tags) and the `currentDirectory` shown in tab metadata stay in sync as Claude moves between projects.
- **Wire Metal Coordinator on First switchToView After Init**: `RustMetalDisplayCoordinator.init(terminalView:gridProvider:)` pre-sets `self.terminalView = terminalView`, so the immediate `coordinator.switchToView(focusedRustView, ...)` call from the create branch in `OverlayTabsModel+Refresh.swift` had `newView === oldView`. The early guard treated that as a redundant call and returned without wiring `onDisplaySyncNeeded`, `isMetalRenderingActive`, or the container's `metalCoordinator`. The coordinator was created but never drew — the tab silently fell through to the CG fallback path inside `RustTerminalView`, which uses different geometry math and produced visible corruption ("text duplicated 4 lines above" on the front tab on 2026-05-09). The guard now only fast-paths when the view is *also* `isMetalRenderingActive`, and the disconnect block is gated on `oldView !== newView` so a same-view first-attach doesn't clobber its own active flag. Symptom in the live-views render summary: polls > 0, changed > 0, draws = 0, syncCalls = 0 across the entire session.
- **Granular Prompt Injection Triggers**: Per-repository prompt injection rules can now target every prompt, the first matching prompt in a shell session, or the first matching prompt after `/compact` or `/clear`. Trigger state is now consumed only when a matching repo rule actually injects, shell launches rotate their proxy correlation session id, and slash-command reinjection events are recorded before terminal input is forwarded so the next matching AI request sees the intended rule.
- **Disable Local-Echo Prediction for TUI Tabs**: Local-echo overlays predicted-input characters at the cursor position and suppresses the matching PTY echo when it arrives, hiding round-trip latency for plain shells. TUI apps (Claude Code, Codex, …) don't echo typed bytes back as plain ASCII — they redraw their own input box at a cursor-positioned location, which the prediction layer can't match. The overlay then stranded the typed characters at stale positions: user types `hello`, sees `hello` once from local echo, then Claude renders `hello` in its own input box, and on Enter the local-echo overlay still showed the original characters. The view now skips local-echo when `hostsAITUI` is set (the same live process-tree signal that already governs scrollback flush), eliminating "input appears twice" / "input remains after Enter" symptoms in AI tabs. Renamed `hostsAIToolForScrollback` → `hostsAITUI` to reflect its broadened role.
- **Stop Scroll-Storm Flapping Caused by the Throttle's Own Deferred Sync**: Entry into the storm required 3 consecutive high-dirty frames; exit required only 1 low-dirty frame. The throttle's coalesced deferred re-fire (66 ms) lands a sync with whatever's in the triple buffer — often unchanged, so dirty ≈ 0. That single low-dirty frame was enough to exit the storm, the next PTY burst re-entered it, and the cycle repeated. 819 enter/exit transitions logged in 2 h on 2026-05-05; effective frame rate stayed ~30 fps instead of the intended 15 fps and the app pressured to ~1.4 GB resident with 7+ s input lag spikes. Exit now requires the same 3-frame run as entry, making the hysteresis symmetric.
- **Codex MCP Config Now Self-Heals on Every Launch**: `upsertCodexMCPSection` previously inserted `command` and `args` only when the `[mcp_servers.chau7]` section was missing entirely; if the section existed but had stale fields (e.g. an `args = ["-c", ...]` from an early-development bridge that took flags, or hand-edits from a debugging session), the writer left those fields alone and Codex would launch the bridge with bogus arguments. The writer now always overwrites both `command` and `args` fields when the chau7 section exists, so any manual or out-of-date setting is corrected on the next Chau7 launch. Multi-line array literals for `args` are not yet recognised.
- **MCP Bridge Survives Chau7 Restarts**: `chau7-mcp-bridge` previously failed-fast if `~/.chau7/mcp.sock` wasn't already listening at startup, and exited the moment the socket dropped. Either condition caused the AI tool's MCP integration to mark chau7 dead until the user restarted the AI session — common when the user rebuilds and relaunches Chau7 with Claude Code or Codex already running. The bridge now (1) retries the initial connect for up to 30 s, so AI tools that race ahead of Chau7 at boot still attach, and (2) reconnects transparently on socket EOF / error, replaying the saved `initialize` request and any stdin queued during the gap so the AI tool sees an uninterrupted MCP channel across Chau7 restarts.
- **Wrapper Now Updates cwd on Chained `cd X && tui-app` Commands**: The bundled zsh and fish shell-integration wrappers registered `smartoverlay_precmd` only on prompt events (`precmd` / `fish_prompt`). Those fire *before* the next prompt is rendered, so a chained command like `cd ~/repo && codex` skipped the hook entirely — `cd` succeeded, the TUI seized the PTY, and the prompt-render that would have emitted OSC 7 never happened. The tab kept showing the pre-`cd` directory until the TUI exited. The wrapper now also registers on `chpwd` (zsh) / `--on-variable PWD` (fish), which fire immediately on directory change regardless of what command runs next.
- **Skip Scrollback Flush/Reload for TUI Tabs**: `ScrollbackMemoryManager`'s `flush()` captured the grid via `full_buffer_text` (row text only — no SGR colors, no cursor positioning, no preserved TUI state). On `reload()` after a hidden→warm transition, `replayBuffer` cleared the screen with `ESC[2J ESC[H` and replayed the flattened text. For shell tabs that's correct; for tabs running Claude Code, Codex, Aider, or any other long-running TUI, it destroyed the application's UI invariants — boxes/spinners/menus that the app had drawn went away, and subsequent in-place updates from the still-running TUI landed on a blank screen, producing visibly corrupted display. The view now flips `hostsAIToolForScrollback` based on the live process-tree signal (`liveAgentName`), and the manager skips flush/reload for those tabs while still resizing the ring (memory tracking unchanged for these phases).
- **Scroll-Storm Threshold Now Catches Near-Full Frames**: The previous classifier required `dirtyCells == frameCells` (every cell dirty) to enter the throttle, which exact-matches a synthetic case but misses the actual workload — AI TUIs leave a stable status/prompt row, so real streaming sits around 98–99 % dirty. A Claude session on 2026-05-04 was rendering 21294 / 21567 ≈ 98.7 % dirty for sustained windows and pressured the app to 1.2 GB resident before being force-quit. Threshold now triggers at ≥ 95 % dirty, which captures the real cases without false-firing on normal interactive use (where dirty is typically a handful of cells).
- **Cap Renderer Rate When Whole Viewport Is Dirty**: AI TUIs that stream log-style output (Codex, Claude Code, build watchers) dirty every row of the visible grid every frame, defeating dirty-tracking and uploading a full ~1.6 MiB instance buffer to the GPU per frame. At 30+ fps on a fullscreen viewport that's ~50 MB/s of GPU sync per visible tab — enough to saturate the Metal command queue and stall the main thread (multi-second input lag observed in 2026-04-30 freeze trace). The Metal coordinator now classifies a "scroll storm" after three consecutive full-grid redraws and throttles `setNeedsSync` to ~15 fps until the dirty rate drops below half the viewport, with a coalesced deferred fire so the final frame of a chunk still renders.
- **Drop Queued Metal Frames for Tabs Switched Away From**: A `metalView.needsDisplay = true` set just before the bound view's `notifyUpdateChanges` flipped to false (the synchronous side-effect of `applyRenderPhase(.warm)` during tab switching) would still trigger one `draw(in:)` at the next CADisplayLink tick, syncing the outgoing tab's grid to the GPU. During rapid tab switching with a chatty AI tab on the previous slot, those leaked frames added tens of MB of sync work per second to an already-saturated Metal command queue. The coordinator now bails early when the bound view is in drain-only mode.
- **Tab Restoration Backup Isolation**: Production tab-state backups keep the legacy recovery directory while dev and unidentified bundles write to bundle-scoped backup directories. Relaunch also retains the multi-window UserDefaults recovery payload until the next real save replaces it, so additional windows remain recoverable if startup exits early.
- **Render Lifecycle Focus Hardening**: Visible selected tabs now treat only the key window as input-priority outside startup restore, and selected-tab in-place refreshes reapply the full render phase before repainting. This closes a focus/drag path where main-but-not-key windows could keep full live Metal/event-drain rendering after another window took input.
- **Background Window Render Backpressure**: Selected tabs in visible background windows now stay in a passive-visible render phase and use the shared background drain instead of full event-driven live presentation. This prevents multiple non-key windows from multiplying full-grid Metal sync work while preserving the retained visible surface and restoring full live rendering when the window becomes input-priority.
- **Hidden Scrollback Reclamation Safety**: Hidden-tab scrollback reclamation now shrinks the Rust ring only after the scrollback cache is written, read back, and decoded successfully. Settings-driven scrollback changes also route through the render-phase manager, so hidden tabs stay at their memory floor instead of being expanded by a direct settings update.
- **Scrollback Retention Across Tab Phases**: Active, passive-visible, and warm tabs now keep the configured terminal scrollback capacity instead of shrinking to small render-tier caps during tab switches. Hidden tabs still flush scrollback to disk before reclaiming RAM, so memory savings no longer truncate visible tab history.
- **Tab Labels Reflect the Actually-Running Agent**: The tab's displayed AI tool (label, logo, color) is now derived live from the session's shell process tree instead of persisted metadata. A tab restored with stale provider metadata — for example, one saved as "Codex" where the user is now running Claude — self-heals within ~1.5s of the real tool appearing in the process tree. Persisted provider metadata still drives explicit resume prefills; it no longer drives display.

### Added
- **Repo-Scoped Split-Pane Session Notes**: An untitled side text pane in a repo-backed tab can now save directly to `.chau7/sessions/<tab-id>/note.md` inside the active repository. The same tab ID can keep separate notes per repo, and restore/reopen paths now auto-load the note for the tab's currently active repo when that file exists.
- **Fixed-Delay Startup Reveal**: Chau7 once again reveals restored windows after a short splash delay instead of blocking the whole app on full restore-drain completion, restoring the lighter startup contract from the stable release path.
- **Per-Repository Prompt Injection**: The proxy can now inject content into API requests on a per-repository basis. Configure rules in `~/.chau7/prompt-rules.json` matching by repository name (portable across machines) or absolute path. Each rule specifies a position: prepend to user message (default), append, or inject into system prompt. Works with Anthropic Messages, OpenAI Chat Completions, OpenAI Responses (Codex CLI), and Gemini. Rules auto-reload every 30 seconds without proxy restart.
- **Adaptive Render-Loop Throttling**: The active terminal now drops to a ~10 Hz polling cadence after a short stretch of no PTY activity, snapping back instantly on the first new byte, keystroke, mouse click, scroll, or IME commit. Idle tabs also skip redundant per-frame tint and cursor-blink work. Big reduction in wakeups/CPU for sessions that are mostly waiting on AI agents.
- **Active Tab Refresh Cap Setting**: New Settings → Terminal → Rendering picker (Display Native / 60 Hz / 30 Hz) caps how fast the focused tab drives its render loop. Default matches current behavior (display native up to 120 Hz on ProMotion). Lower caps trade a bit of scroll smoothness for battery life.
- **Lower Passive-Tab Polling Cadence**: Passive-visible tabs (split panes, unfocused windows) now poll at 15 Hz instead of 30 Hz — still smooth for glance-reading, half the wakeups.
- **Tier-Based Graphics Memory Release**: Background tabs (`.warm`/`.hidden` phases) now release NSImage snapshot caches and mark Metal textures/buffers volatile, cutting per-tab graphics footprint for unselected tabs and letting the OS reclaim GPU memory under pressure.
- **Spanish Language Support**: Full Spanish (es) locale with 2,612 translated keys and 41 .stringsdict plural entries. Informal "tú" form, standard Spanish computing vocabulary. Accessible from Settings > General > Language.
- **Verbose Pre-Commit Review Flow**: `scripts/pre-commit-review` now traces each tab/scripting step, retries transient socket reads, confirms prompt visibility before submit, and falls back to raw newline submission when needed.
- **Stored Review Event Query**: The scripting socket now exposes repo-scoped AI event queries with full messages and filtering, allowing review automation to consume Chau7’s stored finished result instead of scraping only terminal text.
- **Background Transcript Restore Fallback**: Background tabs can reuse cached remote transcript text when no live terminal view is attached, and interactive notification planning now covers elicitation and explicit tool/response failures consistently.
- **MCP `tab_wait_ready`**: New MCP wait helper blocks until a tab reaches deterministic exec-acceptance state (`can_accept_exec=true`) and returns the last observed tab status snapshot on timeout, so eval orchestrators can gate launch submission without maintaining their own polling heuristic.
- **MCP Observability Tools**: Added `chau7_runtime_info`, `chau7_runtime_events`, and `chau7_timer_inventory` so external observers can identify the exact Chau7 build/process, correlate app-owned lifecycle plus unified AI events, and inspect Chau7-owned timer/display-link state without scraping process heuristics alone.
- **MCP Snapshot + Subscription Feed**: Added `chau7_state_snapshot`, `chau7_subscribe`, and `chau7_unsubscribe` so external observers can switch from polling fan-out to one aggregated read plus a long-lived JSON-RPC delta stream with monotonic sequence replay.
- **Eval MCP Contract Hardening**: Snapshot and subscription payloads now expose explicit observer contract metadata, stable replay bounds, effective topic scopes, subscription health fields, and additive heartbeat notifications so eval clients can treat Chau7 MCP as a deterministic observer surface instead of relying on implicit timing heuristics.

### Fixed
- **Visible Tab Stability Reset**: Selected tabs now use a single live presentation path again. Snapshot/cursor handoff overlays no longer stack on top of the live terminal, non-selected tabs no longer stay attached just because they are MCP-controlled, and deferred background restores no longer start mutating tabs immediately after reveal.
- **MCP Tab Readiness Contract**: `tab_status` and `tab_create` now expose deterministic exec-acceptance fields (`can_accept_exec`, `exec_acceptance_mode`) alongside stricter prompt-ready fields (`ready_for_exec`, `readiness_reason`, `has_terminal_view`), and `tab_exec` is documented as bootstrap-queueable so launchers can start commands immediately instead of serially waiting on shell-loading heuristics.
- **Retained-Frame Tab Reveal Timing**: Snapshot-backed tab switches now keep the retained frame visible until the selected terminal reports its first live sync, eliminating the brief grey flash caused by the previous fixed 16ms handoff guess.
- **Cold Tab Snapshot Synthesis**: When a target tab still has a retained Rust terminal view but no cached frame yet, Chau7 now captures a retained snapshot before the switch and reuses the same live-frame-ready callback for reused terminal views, closing the remaining grey-flash path for cold tabs.
- **Cold Tab Switch Handoff**: Inactive tabs now fall back to a retained last-rendered frame during selection handoff, and restore-bootstrap phase changes immediately re-evaluate suspension so restored tabs cool down promptly instead of staying live longer than intended.
- **Codex Rollout Quota Parsing**: Telemetry now parses pretty-printed Codex rollout JSON objects in addition to one-line JSONL, so quota snapshots and rate-limit windows are recovered reliably from multiline history files.
- **Legacy Scripting Session API Removed**: The local scripting socket no longer exposes `create_session`, `get_session_events`, `submit_session_turn`, `get_session_result`, or `stop_session`. Review automation now relies on the existing tab-first scripting methods plus repo events/output instead of the runtime-backed session wrapper layer.
- **MCP Runtime Surface Removed**: `runtime_*` tools are no longer callable through MCP. Public MCP clients now get a strictly tab-first live-control surface plus telemetry/history tools, while runtime orchestration remains internal to the app.
- **MCP Live vs Telemetry Session Contract**: `tab_list` and `tab_status` are now documented as Chau7's primary live discovery/control path for active AI work, while `session_list` and `session_current` are explicitly framed as telemetry/history views instead of the live source of truth.
- **MCP Lifecycle and Tool Error Semantics**: The embedded MCP server now enforces initialize/initialized ordering, negotiates supported protocol versions, returns JSON-RPC protocol errors for unknown tools and malformed tool calls, and marks execution failures with `result.isError` plus structured content instead of reporting every tool failure as plain success text.
- **MCP Tool Abuse Guardrails**: Chau7 now ships a dedicated per-tool MCP rate limiter with more generous budgets for high-frequency polling tools, reducing same-user client hammering without breaking normal runtime/status polling.
- **SwiftPM Docs Scan Cleanup**: Local package builds now exclude `Sources/Chau7/Performance/SIMDTerminalParser.swift` from the docs/resource scan so the performance source file is not misclassified as bundled documentation.
- **PTY Log Output Normalization**: `tab_output(source: "pty_log")` now flushes the active AI PTY log first and normalizes ANSI redraws plus backspaces before parsing, improving live Codex/Claude transcript extraction from interactive sessions.
- **Visible MCP Runtime Launch Failures**: `runtime_session_create` now fails explicitly when Chau7 cannot create a user-visible tab, returning structured `visible_tab_creation_failed` metadata instead of silently validating a hidden PTY-only launch path. MCP client connections also stay open longer during slower eval/debug workflows to reduce idle `Transport closed` disconnects.
- **MCP Tab Window Routing**: `tab_create` now defaults to the active overlay window instead of always targeting the first registered window, so MCP-created tabs appear in the window the user is currently looking at.
- **Tab Restore and Creation Regressions**: Rolled back the render-tier startup path and direct scrollback injection restore path after they caused slow `Cmd+T` tab creation and corrupted fresh post-restore AI history layout. Restore keeps artifact filtering but now replays scrollback through the shell again for stable geometry.
- **Tab Highlight Coverage**: `waiting_input`, `tool_failed`, `response_failed`, and `elicitation` events now highlight tabs. Added trigger catalog entries for the 3 new event types. Enabled `idle` trigger by default. Elicitation participates in repeat dedup.
- **Power Efficiency**: Adaptive clipboard polling (1s foreground, 5s background), shared background drain timer (1 timer for N tabs instead of N timers), event-driven focus/DND detection (zero polling), timer leeway on all fixed timers, and wakeup stats logging every 5 minutes.
- **Dev Server Detection Reliability**: Fixed 6 issues — server restarts now re-detected (removed early bail), extended burst timing to 25s for slow Docker starts, commandDidFinish discovers new servers, added 30s liveness polling, and dynamic netstat PID column parsing.
- **Pre-Commit Review Hook Context Flow**: `scripts/pre-commit-review` now drives the real tab/app lifecycle through the scripting socket — create tab, wait for shell, launch Codex, wait for interactive readiness, send the staged-diff prompt, submit it, poll PTY output for the final JSON block, and close the tab. The hook no longer depends on the brittle delegated-session shortcut path for staged reviews.
- **Deterministic Pre-Commit Review Completion**: `scripts/pre-commit-review` now polls stored repo events for the authoritative final review payload before falling back to terminal transcript scraping, eliminating the mismatch where Chau7 had already recorded the result but `get_output` still returned incomplete redraw text.
- **Pane-Owned AI Resume Restore**: Split tabs now restore AI resume commands per saved terminal pane instead of routing a single resume prefill through whichever pane ends up focused after rebuild, preventing one pane from inheriting another pane’s restore command.
- **Restore Ownership Validation**: Resume prefills now verify the target pane’s directory and restored AI identity before insertion, and skip stale or drifted pane matches instead of guessing and injecting the wrong resume command.
- **Restore Delivery Ledger**: Resume restore now records per-pane scheduled, queued, delivered, rejected, and superseded outcomes so stale retries and ownership failures are explicit in logs and tests instead of silent.
- **Restore Supersession Guard**: Late stale retry callbacks no longer overwrite a newer pane’s delivered restore outcome with a superseded marker, so the restore ledger preserves the final winning pane state.
- **Shortcut Helper Positioning**: Moved helper hint box closer to tab bar — 4pt gap from both tab bar bottom and window right edge for consistent spacing.
- **Pricing Table Accuracy**: Fixed wrong prices for Claude Opus 4.6 ($15→$5/$75→$25), Haiku 4.5 ($0.80→$1/$4→$5), and Gemini 2.0 Flash (free→$0.10/$0.40 paid tier). Added ~20 missing models (GPT-5.x, GPT-4.1, o3/o4-mini, Gemini 2.5). Unknown models now log a warning with the model name instead of failing silently. Gemini fallback uses Flash pricing instead of free tier.
- **Dashboard Polling Waste**: Dashboard now polls adaptively — 2s when agents are active, 5s when idle, 10s with no agents — instead of a fixed 2s interval that wasted CPU even with zero agents running.
- **Cost Lock Safety**: Replaced bare `costLock.lock()/unlock()` pairs with `defer` pattern to prevent lock leaks on unexpected errors.
- **Commit Success Stale**: The "Committed successfully" banner now auto-dismisses after 3 seconds instead of persisting indefinitely.
- **IPC Data Loss**: Proxy IPC socket now retries once on a broken connection before giving up, preventing silent data loss after app restarts.
- **Event Buffer Performance**: Replaced O(n) `insert(at: 0)` in ProxyIPCServer's event buffer with O(1) append + reverse-on-read.
- **DB Query Performance**: Added compound index `(timestamp, cost_usd)` for `dailyTrend()` queries. Added `ANALYZE` after migrations to update SQLite's query planner. Added automatic pruning of API call records older than 180 days.
- **Proxy Health Monitoring**: Dashboard now calls the proxy's existing (but unused) `/health` endpoint every 5th poll cycle and shows a warning triangle in the header when unhealthy.
- **Dashboard Sheet Sizing**: Start Agent and Review Commits sheets now use adaptive widths (min/ideal/max) instead of hardcoded pixel values that broke on small displays.
- **Timeline Pagination**: Dashboard timeline now shows a "Show more..." button when more than 50 events exist, instead of silently truncating.
- **Bug Report Success Feedback**: The in-app issue reporter now formats the relay-returned issue number correctly in its success banner and falls back to a generic success message if no number is returned.
- **Inherited Repo Group Stickiness**: Tabs created from a grouped tab now drop inherited repo-group membership once they move to a different repository, instead of staying stuck to the original group.
- **Directory-Based Inherited Repo Groups**: `newTab(at:)` now installs the same repo-group observer as standard new tabs, so grouped tabs opened directly into another directory also detach correctly when they resolve to a different repository.
- **Dashboard Accessibility**: Agent cards now have combined accessibility labels (backend, state, tokens). Batch action buttons have accessibility hints. Health indicator uses localized strings.
- **Custom Pricing Documentation**: `~/.chau7/pricing.json` format is now documented with a JSON example in code comments. Malformed files now log a warning instead of being silently ignored.
- **Telemetry Active-Run Queries**: `run_list` and `run_get` no longer duplicate active runs that were already inserted into SQLite at `runStarted`. MCP telemetry responses now consistently annotate `run_state` (`active` or `completed`) and `content_state` (`missing`, `partial`, `final`) so orchestrators can distinguish live partial data from finalized runs.
- **Active Codex Transcript Visibility**: `run_transcript` now surfaces live Codex prompts from `~/.codex/history.jsonl` before `runEnded`, with PTY-log fallback for active sessions that do not yet have persisted turns. Active Codex runs no longer appear as empty shells while the session is still in progress.
- **Session Rollup Clarity**: `session_list` now includes `active_run_count`, `completed_run_count`, `latest_run_id`, and `latest_run_state`, making resumed session IDs with multiple historical runs easier to interpret.
- **Forced Shell Termination Diagnostics**: SIGTERM/SIGKILL escalation logs now capture close-to-signal timing, PTY log state, and a process-tree snapshot with command lines so stuck shell shutdowns are actionable instead of opaque.
- **Full Token Tracking**: Proxy now extracts cache creation, cache read, and reasoning tokens from Anthropic, OpenAI, and Gemini API responses (both streaming and non-streaming). Previously hardcoded to 0, causing dashboard to drastically underreport usage with prompt caching.
- **Accurate Cost Calculation**: Cost now accounts for provider-specific cache pricing — Anthropic cache reads at 0.1x input rate, cache writes at 1.25x; OpenAI cached tokens at 0.5x. Previously all tokens were billed at full input rate.
- **Token Estimation Fallback**: When metadata extraction fails on a 200 response, proxy estimates tokens from request/response body sizes (~4 chars/token) instead of silently recording 0.
- **Dashboard Token Display**: Agent cards now show total tokens including cache, with hover tooltip showing per-type breakdown (input/output/cache write/cache read). Per-agent and total cost shown in header.
- **IPC Cache Token Propagation**: `ProxyIPCServerData` and `APICallEvent` now carry `cacheCreationInputTokens`, `cacheReadInputTokens`, and `reasoningOutputTokens` through the full pipeline (proxy → IPC socket → Swift app → dashboard).
- **Recent Proxy Call Context**: Debug Console analytics now shows each recent proxy call with local hour, repo name, and endpoint context so API activity can be tied back to a project quickly.

### Added
- **Metal Rendering Parity Audit and Fixes**: Added an explicit `MetalRenderParityAudit` manifest for wide glyphs, emoji fallback fonts, ligatures, OSC8 link underlines, selection, local echo overlays, inline images, and command-block tinting. Metal now applies local-echo overlay cells before GPU conversion and draws OSC8 link underlines for link cells that do not already carry an explicit SGR underline. Regression tests cover the bridge behavior and audit coverage/statuses.
- **Render Surface Diagnostics v2**: Bug reports now include a richer render-surface snapshot with window content size, terminal bounds, surface frame, grid origin, raw/effective/max rows and columns, cell size, point and pixel remainders, Metal view bounds, drawable size, last presented frame age, render coalescing counters, and typed retry state. The formatter is covered by regression tests so future geometry investigations get stable field names.
- **Metal Retry Policy for Transient Render Failures**: Metal draw retries now flow through a typed `TerminalRenderRetryPolicy` with concrete reasons for font setup, missing grid snapshots, zero-size views, missing drawables, zero-cell layouts, and commit failures. Retries stay responsive for short fullscreen/drawable transitions, back off under repeated failures, and reset after a committed frame; new unit tests cover delay, log sampling, reason changes, and recovery reset.
- **Metal Render Coalescing Diagnostics**: `TerminalRenderRequestCoalescer` now tracks pending sync/present work, total requested work, and coalesced request counts so heavy AI-output bursts can be audited as latest-frame-wins instead of one GPU upload per obsolete intermediate state. Regression tests cover sync bursts, present-only bursts, and newer requests arriving while an older draw commits.
- **CPU/Metal Render Layout Parity Harness**: `TerminalRenderGeometry` now exposes the grid origin, whole-cell rectangles, and scale-adjusted remainder pixels from the single pure geometry contract used by both render paths. New parity tests assert that CPU and Metal layout decisions agree for rows/columns, mouse-cell mapping, cursor rectangles, and fractional remainder handling before visual QA.
- **Telemetry Query Projection Helpers**: Added shared projection helpers for live-history Codex parsing, active/stored run deduplication, and telemetry content-state evaluation, with regression coverage for duplicate active runs and active transcript parsing.
- **Scripting Review Automation API**: The local scripting socket now exposes `start_review`, `wait_review`, and `get_review_result` so external tools can launch delegated code reviews, wait on completion, and fetch structured findings without speaking MCP directly.
- **Pre-Commit Delegated Code Review**: Added `scripts/pre-commit-review` plus a registered staged quality gate that reviews staged diffs through Chau7 when the scripting socket is available, prints structured findings in hook-friendly output, and can skip open when Chau7 is unavailable.
- **Repo-Level Pre-Commit Review Policy**: Repositories can now ship `.chau7/pre-commit-review.conf` to set the delegated review gate mode (`off`, `advisory`, `high`, `any`), timeout, backend, and optional model override, with environment-variable overrides for CI and local workflows.
- **Default Pre-Commit Reviewer Model**: Delegated staged-diff reviews now default to `gpt-5.3-codex` on the `codex` backend unless the repo config, environment, or CLI flags override the model selection.
- **Structured Delegated Results**: Runtime sessions can now carry JSON-schema-like result contracts, extract structured results from completed turns, and expose them via MCP `runtime_turn_result` with transcript-derived fallback when needed.
- **Delegated Session Policies**: Runtime sessions now support policy objects for max turns, max duration, child delegation, depth limits, and tool allow/block rules. Runtime-owned limits are enforced directly and policy metadata is propagated into child session environments.
- **Delegated Session Lifecycle Tools**: MCP now includes `runtime_session_children`, `runtime_session_cancel_children`, `runtime_session_retry`, and `runtime_turn_wait` so orchestrators can manage delegated task trees without polling raw event streams alone.
- **Dashboard Review Workflow**: The multi-agent dashboard now surfaces delegated lineage and structured-result summaries, and adds a built-in Codex commit-review launcher with a default review schema and review-safe policy defaults.
- **Delegated Runtime Session Metadata**: MCP-created runtime sessions now accept generic delegation fields (`purpose`, `parent_session_id`, `parent_run_id`, `task_metadata`, `delegation_depth`) so parent agents can launch child tasks with explicit lineage instead of repo-wide heuristics.
- **Delegated Telemetry Lineage**: Runtime-managed AI runs now persist delegation lineage and task metadata into telemetry, and MCP `run_list` can filter by `parent_run_id` to fetch exact child runs for a parent task.
- **Staged-Diff Review Templates**: The built-in code review task template now supports staged-diff prompts with explicit staged file lists and patch payloads, so orchestrators can review what is about to be committed instead of only previously created commits.
- **Locale Coverage Completion for New L() Keys**: English, French, Arabic, and Hebrew bundles now include the remaining shipped UI strings added during the recent localization sweep, including settings search/help copy, dashboard copy, alert text, snippets examples, and long-form in-app help topics. Localization parity and translation completeness are back to green with format-specifier safety checks passing.
- **Locale Identity Cleanup Pass**: Final locale polish translated the remaining user-facing labels, alerts, and help titles that were still left in English after the bulk sweep. The remaining identical strings are now limited to intentional identities such as product names, browser names, file paths, protocol literals, and placeholder-only formats.
- **Remote Docs Colocation**: Moved the remote protocol spec next to `services/chau7-remote` and split iOS-specific remote UX and Live Activity notes into `apps/chau7-ios/docs`, removing the old orphaned top-level `docs/remote-control` folder.
- **Doc Ownership Cleanup**: Added a canonical documentation map, collapsed the stale macOS-specific contributing guide into a pointer doc, and removed planning and assessment docs from the public repository so public docs and working notes stop competing.
- **Repository Pane**: Full git UI as a split pane (⌘⌥B). Stage/unstage files, commit (⌘Enter), switch/create/delete branches, push/pull, stash save/pop/drop, commit history with search, merge conflict resolution (accept ours/theirs). Ahead/behind indicator, branch/stash hover tooltips, conventional commit prefix chips, commit message persistence. Session-aware mode: when an AI agent is active, shows only agent-touched files with diff stats, turn summary (tools, tokens, duration), "Ask Agent" commit message button, and resets after push. All operations run via background `Process` with inline error display. Persists across tab restore.
- **Technology, Licenses & Acknowledgments Help Page**: New help topic documenting the monorepo layout, languages, Rust crates, bundled binaries, third-party dependencies (swift-atomics, RTK fork), system frameworks, and notice file locations. Accessible from Help menu and About settings.
- **Third-Party Notices**: Added `THIRD_PARTY_NOTICES.md` and `LICENSE-RTK-APACHE` for RTK dual-license tracking (MIT + Apache-2.0 upstream ambiguity).
- **Privacy-First Bug Report Dialog**: New in-app issue reporter (⌥⌘I) with all sensitive sections off by default, per-toggle tab pickers, live markdown preview, inline privacy warnings, and optional remembered contact info. Submits privately via Cloudflare Worker relay.
- **Issue Reporting Privacy Page**: In-app GDPR-compliant privacy disclosure accessible from the bug report dialog. Lists sub-processors (Cloudflare, GitHub) with data categories, retention, legal basis (Art. 6(1)(f)), international transfer coverage, DPA links, and data subject rights.
- **Relay /issue Endpoint**: Cloudflare Worker `POST /issue` proxies to GitHub Issues API with server-side PAT, Durable Object rate limiting (5/hour/IP), repo path sanitization, and CORS support.
- **Repo-Level Aggregated Metrics**: Per-repository stats (command count, success rate, AI runs, tokens, cost, providers, top tools) computed on demand from both SQLite stores. Surfaced in Debug Console "Repos" analytics tab, Data Explorer enriched rows, and TabHoverCard condensed line (togglable via `hoverCardShowRepoStats`).
- **Click-to-Copy Document Name**: Clicking the file name in the text editor pane header copies it to the clipboard.
- **Notification Delivery Ledger**: Every AI notification event now records an explicit delivery lifecycle (ingested, coalesced, retry scheduled, prepared, dropped, rate-limited, actions executed, completed) with resolved tab, drop reason, and banner/style outcomes.
- **Notification Reliability Dashboard**: Debug surfaces now summarize recent notification completions, drops, retries, rate limits, and authoritative deliveries for faster triage.
- **Repository Tab Grouping**: Tabs can be grouped by git repository (Off/Auto/Manual modes). Grouped tabs show an inline repo-name tag chip with a thin connecting line overlaying their top borders, and suppress the redundant repo path from individual tab titles. Auto mode groups by detected gitRootPath; Manual mode lets users right-click to add/remove tabs from groups. Free drag reorder preserved.
- **Split Pane File Preview**: Read-only file viewer with syntax highlighting for text and native rendering for images (png/jpg/gif/svg/webp). Opens via Cmd+Opt+P or Changed Files context menu.
- **Split Pane Diff Viewer**: Unified git diff view with colored additions/deletions, dual line numbers, and Working/Staged mode toggle. Opens via Cmd+Opt+Shift+D or Changed Files "Open Diff" context menu.
- **Remote iPhone Efficiency Pass**: Chau7 Remote now processes incoming frames off the main actor, adds `os_signpost` instrumentation for remote frame processing and ANSI stripping, requests a fresh active-tab snapshot on foreground resume, and preserves approvals/prompts when the background keepalive expires.
- **Selected-Tab Remote Streaming**: The macOS remote sender now streams terminal output and snapshots only for the tab currently selected on iPhone, reducing background traffic and receive-side render work.
- **Remote Background Approval Mode**: The Chau7 Remote iPhone app now keeps a short-lived background session alive in approvals-only mode so pending approvals and detected interactive prompts can still sync after the app backgrounds.
- **Remote Push Approval Delivery**: The Cloudflare relay and Go remote helper now support APNs-backed push registration and push-triggered approval delivery for the Chau7 Remote iPhone app when the phone is no longer actively connected.
- **Experimental iPhone Terminal Renderer**: Chau7 Remote can now render a real Rust-backed terminal grid on iPhone behind a toggle, while keeping the text renderer as a fallback.
- **Interactive Remote Prompts**: iPhone remote clients now surface detected Claude and Codex terminal prompts in the Approvals tab and can reply with a mapped option directly to the originating tab. Destructive options require a second confirmation on iPhone.
- **MCP `tab_output` source=pty_log**: New `source` param on `tab_output` reads the ANSI-stripped PTY output log instead of the terminal buffer. Captures full AI session output including alternate-screen content that TUI-based tools discard on exit. Works for all AI providers.
- **MCP `wait_for_stable_ms`**: New param on `tab_output` polls the terminal buffer until content settles, fixing the race where `is_at_prompt` fires before the agent's final response finishes rendering
- **PTY Log Fallback Transcript**: `run_transcript` now falls back to the ANSI-stripped PTY output log when provider-specific extraction fails, capturing full agent output including alternate-screen content from TUI-based tools
- **Terminal Buffer Fallback Transcript**: Secondary fallback captures the terminal scrollback at run-end time for non-TUI agents
- **Menu Bar Only Mode**: New setting hides Chau7 from Dock and Cmd+Tab (activation policy `.accessory`)
- **Floating Window Mode**: New setting keeps the terminal window above other apps (`.floating` window level)
- **Angle Bracket Matching**: Editor now matches `<>` pairs and supports jump-to-matching-bracket
- **Whole-Word Terminal Search**: New toggle wraps search query in `\b` word boundaries
- **Relative/Hybrid Line Numbers**: Editor gutter supports absolute, relative, and hybrid line number modes with dynamic width
- **Cursor Blink Rate**: Configurable blink interval (0.3–2.0s) and custom cursor color (hex)
- **Visual Bell + Rate Limiting**: Bell can flash the screen (combinable with audible), with configurable minimum interval
- **Keybindings JSON Export/Import**: Standalone export/import methods for keybindings separate from full settings
- **Custom API Pricing**: `~/.chau7/pricing.json` overrides the built-in model pricing table
- **TTFT Latency Tracking**: Time-to-first-token measured via firstByteReader wrapper. Stored in SQLite, logged, and sent via IPC.
- **Font Ligature Rendering**: Metal renderer now shapes multi-character sequences via CoreText. Fonts with OpenType ligature tables (Fira Code, JetBrains Mono, Cascadia Code) automatically display ligatures. Configurable via `enableLigatures` setting.
- **OSC 133 Shell Integration**: FinalTerm/iTerm2 shell integration markers parsed in Rust interceptor. Provides authoritative prompt/command/output region tracking with exit codes. Feeds ShellEventDetector for accurate command lifecycle. When present, heuristic detection (echo-based start, timeout-based finish, OSC 7 prompt inference) is suppressed.
- **TelemetryStore Resilience**: SQLite insert failures now log the actual error message (was logging only the record ID). Database integrity check on startup with automatic recreation on corruption.
- **TabResolver Accuracy**: Directory disambiguation now prefers the most recently active tab instead of the first match. Fallback uses most recently active tab instead of most recently created. Eliminates most ambiguous matches.
- **Watchdog Tolerance**: Tab bar health check now allows ±2 tolerance in rendered count to prevent false recovery triggers during transitions.
- **Log Noise Reduction**: Toolbar lifecycle events (appeared/disappeared/visibility) downgraded from WARN/INFO to TRACE.
- **Show Changed Files**: Git diff snapshot at command start (OSC 133 C) and finish (OSC 133 D) identifies files modified by each command. View > Show Changed Files (Cmd+Option+G) or via keybinding.
- **File Drag & Drop**: Drop files onto terminal to paste shell-escaped paths. Option+drop images for base64 data URI (for AI CLIs). 10MB size cap.
- **chau7:// URL Handler**: `chau7://ssh/user@host`, `chau7://run/<base64>`, `chau7://cd/path`, `chau7://open/path` open tabs or files from external apps. Run commands require user confirmation.
- **Markdown Runbooks**: Open a .md file in the editor pane → auto-renders with executable code blocks. Click "Run" on each block or "Run All" to execute in the adjacent terminal.
- **Idle Tabs Dropdown**: Tabs idle 10+ minutes are collected into a dropdown chip at the start of the tab bar. Hover shows tab hover card. Click to select, "Close All Idle" to clean up. Configurable in Settings > Tabs.
- **Keyboard Shortcut Standardization**: All Chau7-specific shortcuts now use Cmd+Option. Standard macOS shortcuts unchanged. Tab selection (Cmd+1-9) internationalized for all keyboard layouts.
- **API Analytics Fix**: Streaming response metadata (model, tokens, cost) now correctly parsed for Anthropic and OpenAI. Tab names shown instead of UUIDs.
- **Debug Console Tab Labels**: Per-tab token and CTO sections now use repo-aware labels, and split sessions add a disambiguator when a tab title would otherwise collide.
- **Profile Auto-Switch Wired Up**: `evaluateRules()` now fires on directory change with git branch and process context
- **API Analytics Tab**: Debug console (Cmd+Shift+L) now shows per-provider cost, per-tab tokens, and aggregate totals
- **Hyperlink Protocols**: Clickable links now detect file://, ssh://, ftp://, sftp:// in addition to http/https
- **Clipboard Persistence + Search**: Clipboard history persists across restarts, supports substring search, cap raised to 1000 items
- **Unicode Ambiguous-Width Config**: Per-profile setting for East Asian ambiguous character width (1=single, 2=double) with Rust FFI support
- **Font Weight Setting**: Configurable NSFont weight (0=ultralight to 14=ultra-heavy)
- **JSON-RPC API Complete**: All 7 stubbed methods (list_tabs, get_tab, run_command, get_output, create_tab, close_tab, run_snippet) now implemented
- **Timeline Density Heatmap**: Minimap shows activity hotspots via bucketed opacity overlay
- **Remote Live Activity State**: Chau7 now projects one authoritative remote AI activity over the remote-control channel so the iPhone client can render a native Live Activity / Dynamic Island state for the most relevant task
- **Isolated Test App Builder**: Added a dedicated isolated app build that runs with its own bundle ID, home root, keychain prefix, logs, and app support directories for safe manual testing alongside the main app
- **MCP Terminal Key Tools**: Added `tab_press_key` for real terminal key events and `tab_submit_prompt` as an Enter-key convenience for interactive TUIs like Claude Code
- **Tab Bar Staleness Detection**: Watchdog now detects when NSHostingView becomes disconnected (preference keys stop firing) and forces recovery
- **Clickable File Paths**: Cmd+Click on file paths in terminal output to open in right panel editor (planned)
- **Runtime Turn Send for Adopted Sessions**: MCP clients can now send prompts through `runtime_turn_send` even when the runtime session was adopted from an existing tab

### Changed
- **Chau7 Remote Now Targets iOS 20**: Raised the Chau7 Remote app and widget deployment target from iOS 17.0 to iOS 20.0, and aligned the Rust terminal static-library build script with the same default minimum so Xcode and Cargo keep emitting compatible iPhone artifacts.
- **RTL Layout Direction at All Hosting Sites**: `.localized()` now applied at every `NSHostingView`/`NSHostingController` boundary (13 sites), propagating layout direction to all SwiftUI views. Previously only 4 settings views had it. Removed redundant inner `.localized()` from settings child views that now inherit from their hosting root.
- **Complete i18n Translation Coverage**: Filled all pre-existing translation gaps — French cognates reviewed (6 keys updated: snippets, tags, tokens), Arabic statusBar namespace fully translated (38 keys: session states, timeline events, tool names), Hebrew statusBar namespace fully translated (33 keys). All 4 locales now have zero English-identical values except for legitimate cognates and brand names.
- **Localize All Remaining Hardcoded Strings**: Wrap 75+ user-facing strings with L() across 16 files — NSMenuItem context menus (tab rename/close/move/group), terminal right-click menu, hover card section labels/status, agent dashboard, migration wizard, theme names, about settings, default tab titles, dev server names, and data explorer empty states.

### Fixed
- **Claude Strict Live-Tab Fallback**: When runtime-owned Claude session bindings are missing or stale, authoritative Claude events now fall back to a strict live-session resolver instead of dropping immediately. This recovers exact permission and waiting-input routing from current tab session metadata without reopening heuristic cross-tab matches.
- **Stale Style Delivery Suppression**: Tab-style delivery now checks whether an explicit target tab is still live before trying to style it, and quietly skips vanished tabs after exact-session recovery is exhausted. This removes spurious missing-tab warnings when a tab disappears between notification preparation and style execution.
- **Claude Exact Session Binding**: Claude notification routing now treats exact session IDs as authoritative even when the event cwd is a nested path under the tab repo root or when temporary live-tab metadata lacks `ai_provider=claude`. This prevents real `permission` and `waiting_input` events from dropping just because the tab and hook report slightly different working directories.
- **Notification Auto-Clear on Dead Tabs**: Delayed tab-style cleanup now checks whether the target tab still exists and retries once via exact session lookup before clearing. This removes follow-up `applyNotificationStyle ... not found` noise after a valid notification when a tab moved or closed.
- **Restored Session Prompt Fallback Leak**: Restored AI tabs now suppress terminal prompt `waiting_input` fallback as soon as their provider metadata is restored, not only after resume-prefill delivery. This stops startup tab highlights caused by restored Codex/Claude sessions before any real user command runs.
- **Notification Action Outcome Accounting**: Notification delivery no longer counts tab-scoped actions as successful just because they were requested. Focus, style, badge, and snippet actions now report real success/failure into the delivery ledger and logs, so a notification is always explainable end-to-end.
- **Bug Report Hardening**: Fixed rate limit bypass in relay `/issue` endpoint (DO errors no longer skip throttle), added title length cap, HTTPS enforcement on submission endpoint, removed AI session fallback that leaked all sessions, tab title path redaction, stale window reference cleanup on close, and background-thread terminal history capture.
- **Restore Prefill Notification Noise**: System-injected resume prefills no longer arm prompt-return `waiting_input` notifications during launch/restore. Fallback waiting-input delivery stays suppressed until a real user command runs after the restore flow.
- **Tailed `terminal_session` Notification Spam**: Terminal-session events replayed from the event log no longer re-enter user-facing notification delivery. They still appear in the unified event stream, but live notifications now only come from canonical ingress, not from tailed echoes.
- **History Monitor False Finishes**: Prompt-only Codex and Claude history entries no longer synthesize `finished` events after the idle timeout. History-monitor completions now require response-side activity instead of treating every new user prompt as completed work.
- **Default AI Notification Policy**: AI-facing notification defaults are now stricter. Finished, failed, and permission requests remain enabled by default, while noisy events-log passthrough triggers like `needs_validation`, custom `notification`, and wildcard `other` no longer ship enabled.
- **Runtime Failure Classification**: Non-success runtime exits now emit `failed` instead of generic `error`, so they follow the same default notification and tab-style policy as other AI task failures.
- **Persistent History Clear Ordering**: `clearAll()` now runs on the history queue so queued async inserts cannot repopulate the database after a wipe.
- **Stale Window State Cleanup**: Quitting after all overlay windows are hidden or closed now clears persisted tab/window state and backup files instead of restoring stale windows on next launch.
- **Native Text Pane Edit Shortcuts**: Cut, copy, and paste now try the focused responder first, restoring standard macOS shortcuts inside split-pane text editors before falling back to terminal behavior.
- **International Option Text Input**: Option-based programming characters such as brackets now flow through macOS text input instead of being forced into Meta/Alt escape sequences, fixing entry on international keyboard layouts.
- **TabResolver Session Precedence**: Notification routing now resolves exact AI session IDs before broad tool-label matching and most-recent fallback, which reduces ambiguous matches and helps Codex events reach the correct tab.
- **History Monitor Tab Routing**: Claude and Codex history-monitor idle/finished events now resolve their working directory from session metadata before notifying, so tab styling and notifications can target the correct repo tab.
- **Runtime Session Startup**: Newly created MCP runtime sessions now transition to `ready` after launch, and `attach_tab_id` sessions start usable immediately instead of staying stuck in `starting`.
- **MCP Command Filter Parsing**: Permission checks now split on background operators, tabs, and newlines, closing command-separator bypasses such as `cmd & dangerous` and multiline payloads.
- **Backend Launch Environment Validation**: Runtime backends now ignore invalid environment variable names before building shell launch strings, closing command injection through hostile JSON-RPC env keys.
- **Notification Identity Scoping**: Notification coalescing and rate limiting are now scoped by tab, session, or directory identity instead of only trigger/tool matching. One noisy tab no longer suppresses the same notification on another tab.
- **Approval Attention Lifecycle**: Persistent approval styling now clears when the approval is actually resolved, and split-created terminal sessions inherit the same owner/callback wiring as the original pane so permission indicators do not get stuck.
- **File Conflict Notifications**: Cross-tab file conflicts now emit real `app.file_conflict` events for each affected tab, so the configured notification trigger and orange tab styling actually fire on first detection.
- **Data Explorer Refresh**: Reopening the singleton Data Explorer window now rebuilds its SwiftUI content instead of showing stale history and telemetry from the first time the window was opened.
- **Session Explorer Metadata**: Session rows now derive provider and repo from the latest run for that session instead of SQLite's arbitrary non-grouped values, fixing incorrect badges in the Sessions explorer.
- **AI Tool Detection**: Fixed false positive detecting "Cline" on Claude Code sessions — bare `cline` pattern matched substrings. Command-based detection now gates output pattern scanning to prevent race conditions.
- **Dangerous Command Guard Hardening**: Unicode homoglyph detection, multiline paste protection, per-directory allowlists
- **MCP Audit-Only Mode**: New `auditOnly` permission mode allows execution but logs for review. Per-agent profile scoping via agentAllowlist.
- **Process Exit Confirmation**: Cmd+Q now lists running process names and asks for confirmation before quitting
- **Idle Tab Event Spam**: `HistoryIdleMonitor` now fires idle exactly once per session — heartbeat entries no longer reset the dedup flag. Scheduler backs off to the stale deadline for already-idle sessions.
- **Redundant Tab Highlights**: Notification executor tracks applied presets per tab and skips re-applies when the same style is already active with a pending auto-clear timer.
- **MCP `tab_output` Line Cap**: Raised from 5000 to 10000 to match default scrollback depth
- **Claude Code JSONL Discovery**: Provider now scans session root directory when `subagents/` is empty, supporting older Claude Code versions
- **Shell Termination Timeouts**: AI sessions get longer grace periods (3s+2s) vs plain shells (1s+0.5s) to avoid SIGKILL escalation during cleanup
- **Tab Restoration for Background Tabs**: Tabs outside the nearby rendering range now delegate prefill to the session level instead of burning 55s of retries
- **Claude Code Prompt Submission via MCP**: `tab_send_input` remains raw text while the new keypress path now sends real Enter-style terminal input, fixing prompt submission in TUIs that distinguish pasted newlines from the Return key
- **Isolated Test App Startup**: Disabled notification-center initialization in isolated mode and corrected the embedded isolated-home launcher path to prevent startup crashes
- **AI Tool Detection**: Fixed false positive detecting "Cursor" on Codex sessions - patterns now more specific to avoid matching generic text like "cursor position"
- **Build Errors**: Fixed Swift 6 actor isolation error in `handleOutput()` and optional binding on non-optional Data
- **Tab Reordering Preview**: Fixed dragged tabs causing sibling tabs to slide early with a visible offset in the toolbar
- **Phantom Window on Launch**: Closed windows no longer reappear on relaunch — disabled macOS native state restoration (`isRestorable = false`) and hardened the save filter with explicit hidden-window tracking

### Changed
- **SwiftTerm References Removed**: All docs, README, architecture diagrams, and code comments now reference the native Rust terminal backend. `SWIFTTERM_FORK.md` deleted. `ARCHITECTURE.md` dependency table updated from SwiftTerm to swift-atomics.
- **RTK License Provenance**: `UPSTREAM-SYNC.md` now documents the MIT/Apache-2.0 ambiguity in RTK upstream and the dual notice file strategy.
- **CI gofmt Check**: `ci-lib.sh` gofmt check now uses explicit binary paths to avoid PATH shadowing.
- **Canonical Notification Coverage for All Sources**: The provider adapter layer now covers every notification source, including shell, app, terminal-session, history-monitor, events-log, and API-proxy events. The shared notification system no longer has pass-through sources outside the canonical adapter boundary.
- **Single Notification Ingress Handoff**: `AppModel` now ingests events once and hands accepted canonical events directly to `NotificationManager`, eliminating the previous double-ingest path between the unified event stream and notification delivery.
- **Strict Notification Delivery Boundaries**: Notification ingress now runs through one shared adapter-backed contract, and tab-targeting actions (`styleTab`, `badgeTab`, `focusTab`, snippet insertion, persistent-style clearing) require an explicitly resolved `tabID`. Notification delivery no longer falls back to late `TabResolver` heuristics inside overlay styling or NotificationCenter side channels.
- **Provider Adapter Notification Layer**: AI provider events are now canonicalized before they enter the shared notification stream. App-level event publishing, event-log tailing, and Claude hook delivery now all flow through provider adapters so settings, history, and tab styling operate on one semantic event model instead of mixed raw provider events.
- **Canonical Notification Name Normalization**: Shared semantic notification mapping now preserves word boundaries when normalizing provider hook names, so values like `permission prompt`, `idle-prompt`, and `auth success` consistently map onto the canonical trigger keys used by adapters and settings.
- **Canonical Notification Ingress**: Provider events are now canonicalized before the delivery ledger and coalescing queue record them, so notification history, debug views, and timeline surfaces keep canonical semantics plus raw-type notes instead of mixing raw provider event names into shared state.
- **Claude Hook Ownership**: Claude `notification` hooks are now the sole user-facing owner for waiting-input and attention-required delivery. Raw Claude `response_complete` events are treated as state-only and no longer light up tabs or fire notifications by themselves.
- **Notification Routing Hardening**: Core AI attention events (`finished`, `failed`, `permission`) now prefer authoritative runtime/hook producers, retry exact routing before fallback, and suppress later fallback duplicates when an authoritative delivery already fired for the same session/tab.
- **AI Notification Settings Simplification**: Notifications settings now open on an AI-first overview with direct controls for Finished, Failed, and Permission Request behavior. The raw trigger/source matrix remains available under Advanced instead of leading the screen.
- **Settings UX Overhaul**: 15 UX fixes — separate Font & Colors / Display reset, Tabs reset button, configurable idle tab threshold (1-60 min), LLM settings with proper help text, mouse settings above shortcuts table, consolidated Input reset, ligatures toggle promoted, SSH Profiles elevated, MCP Appearance before Profiles, Persistent History at top and defaulting to on, Token Optimization "How It Works" visible when off, AI Detection actionable-first layout, Render Test Image feedback
- **Chau7 Remote Branding**: The iPhone app now uses the Chau7 dock icon and in-app branding assets so macOS and iOS share the same visual identity.
- **Queued Terminal Input Ordering**: Terminal sessions now preserve order between queued raw text input and queued key presses when a tab is created or restored before its view attaches
- **Runtime Path Isolation**: Chau7-owned paths and keychain service names can now be redirected through `RuntimeIsolation`, allowing safe test builds without touching the main app's storage
- **Output Detection Patterns**: Made patterns more specific (URLs with slashes, version strings, box-drawing banners) to reduce false positives

---

## [0.5.0] - 2026-01-21

### Added
- **Tab Notification Styling**: New `TabNotificationStyle` with color, italic, bold, pulse, and icon properties
  - Predefined styles: `.waiting`, `.error`, `.success`, `.attention`
  - Integration with notification action system (`styleTab` action type)
  - Auto-clear timer support with race condition prevention

- **Snippet Variable Improvements**:
  - Picker support: `${input:name:opt1|opt2|opt3}` for single-select dropdowns
  - Multi-select support: `${multiselect:name:opt1|opt2|opt3}` with toggle buttons
  - FlowLayout for multi-select buttons

- **Manual Tab Bar Recovery**: Window menu → "Refresh Tab Bar" (Cmd+Option+R)

### Fixed
- **Major Tab Bar Resilience** (4 architectural fixes):
  1. Cache NSHostingView in TabBarToolbarDelegate - prevents state loss on toolbar recreation
  2. Visibility-based recovery - detects "rendered but invisible" tabs via geometry
  3. Stable view identity with UnifiedTabButton - prevents SwiftUI view recreation
  4. Model-owned watchdog lifecycle - runs regardless of view lifecycle events

- **Debug Console**: Fixed empty logs issue - category filter now allows logs without tags
- **Snippet Variable Dialog**: Fixed crash from ForEach indices binding - uses identity-based bindings

---

## [0.4.0] - 2026-01-20

### Added
- **Tab Bar Watchdog**: Timer-based health monitoring with automatic recovery
  - Reports rendered tab count from view to model
  - Limits refresh attempts to 3 to prevent log spam
  - Thread-safe with `dispatchPrecondition`

- **Smart Scroll**: Preserves user's scroll position when new output arrives
  - Only auto-scrolls if user is at/near bottom of terminal
  - New `isSmartScrollEnabled` setting (default: true)

- **Enhanced Logging System** (`LogEnhanced`):
  - 11 categories: App, Tabs, Terminal, Session, Network, Performance, etc.
  - Structured JSON output option
  - Correlation IDs for async operation tracing
  - `PerfTracker` for performance measurement
  - Memory pressure monitoring
  - OSLog integration for Console.app

- **Debug Console Improvements**:
  - Level filter chips (TRACE, INFO, WARN, ERROR)
  - Category filter chips with emojis
  - Quick presets ("All", "Errors Only")
  - Entry counter and memory display

### Fixed
- **Tab Bar Crash**: Removed `.drawingGroup(opaque: false)` causing Metal render corruption
- **ProxyManager Concurrency**: Fixed race condition (DispatchQueue.global → .main)
- **14 Build Warnings**: Unused vars, var→let, discarded results

### Changed
- **Logging Defaults**: Restored critical logs from TRACE to INFO (dev server, AI detection, stuck detection)
- **FileTailer Buffer**: Increased from 1MB to 4MB for verbose Codex output
- **Stale Timeout**: Reduced from 600s to 180s (3 min) for faster session close detection
- **History Idle Notification**: Disabled by default (was noisy)

---

## [0.3.0] - 2026-01-19

### Added
- **Tab Reordering**: Drag-and-drop tabs to reorder
- **Terminal Context Menu**: Right-click menu with common actions
- **Notification Event System**:
  - `ShellEventDetector` for shell events (exit codes, patterns, long-running commands)
  - `AppEventEmitter` for app events (scheduled, inactivity, memory pressure)
  - `NotificationActionExecutor` for executing trigger actions
  - Thread safety with serial queues and rate limiting
  - Memory hysteresis to prevent alert flooding

### Fixed
- **Terminal Focus**: Focus returns to terminal after snippet selection
- **Git Badge**: Fixed git icon/branch not showing on new tabs - use `updateCurrentDirectory()` instead of direct property assignment
- **Text Selection Bugs**:
  - `lastSelectionText` not clearing when user clicks to deselect
  - Mouse state not cleared when mouseUp is outside bounds/window
  - Lowered drag threshold from 3px to 1.5px for better detection

### Changed
- Keyboard shortcut updates

---

## [0.2.1] - 2026-01-15

### Added
- **v1.3 Shell Integration**: CLI header injection for AI tool detection
- **v1.2 Baseline Metrics**: Display in Swift UI with token savings estimation

### Fixed
- **v1.2 Code Review Bugs**:
  - Task assessments now forward to Mockup analytics
  - IPC notifications include TokensSaved from baseline
  - Mockup client wired to task manager

---

## [0.2.0] - 2026-01-14

### Added
- **API Proxy**: LLM token analytics and cost tracking
  - Intercepts API calls to track usage
  - Per-session and aggregate statistics

- **v1.1 Task Lifecycle Management**:
  - Task state machine (pending → running → completed/failed)
  - Automatic task detection from terminal output
  - Task duration tracking
  - Tests and UI wiring

- **Terminal Header Box**: Visual indicator for active AI sessions

### Fixed
- Overlay layout issues

---

## [0.2.0] - 2026-01-13

"One proud foot of code" release

### Added
- Complete settings system with all features wired
- Session handling improvements
- Settings layout refactoring

---

## [0.1.0] - 2026-01-11

Initial development release

### Added
- **Core Terminal**:
  - Terminal emulation
  - Startup line display before shell prompt
  - Terminal defaults wiring

- **AI CLI Detection**:
  - Automatic detection of Claude, Codex, Gemini, ChatGPT, Copilot, Aider, Cursor
  - Command-based detection from input
  - Output pattern detection for missed commands
  - Custom detection rules support

- **Snippets System**:
  - Template expansion with variables
  - `${input:name}`, `${input:name:default}` syntax
  - Quick-select keys (1-9)
  - Three scope levels: Global, Profile, Tab

- **Tab Management**:
  - Multiple tabs with Cmd+T/Cmd+W
  - Tab colors per AI tool
  - Tab renaming

- **Overlay Mode**:
  - Dropdown terminal (like iTerm2 hotkey window)
  - UX improvements

- **Split Panes**:
  - Horizontal and vertical splits
  - Text editor in right panel

- **Settings**:
  - Comprehensive settings UI
  - Import/export configuration

### Technical
- SwiftUI-based architecture
- macOS 13+ (Ventura) minimum
- Swift 5.9+ required

---

## Version History Summary

| Version | Date | Highlights |
|---------|------|------------|
| 0.5.32 | 2026-04-04 | App termination now reuses a recent cached multi-window snapshot instead of re-exporting every visible tab during quit, reducing synchronous shutdown stalls and beachball risk |
| 0.5.31 | 2026-04-04 | Ambiguous same-repo Codex save-time resolution now preserves a tab's explicit session metadata instead of clearing it, so restored tabs can keep their last-known resume command |
| 0.5.30 | 2026-04-03 | Localization bundles now include the missing shipped UI strings that were still being requested from Swift source, reducing fallback-to-key behavior across English, Arabic, French, and Hebrew |
| 0.5.29 | 2026-04-03 | Public docs now have a canonical ownership map, stale onboarding duplicates and planning artifacts were removed, and staged doc checks reject absolute filesystem links, stale repo URLs, and TODO markers in the public README |
| 0.5.28 | 2026-04-02 | Codex resume metadata now clears claimed stale explicit session IDs when no deterministic replacement exists, preventing repeated save/restore conflicts across same-repo tabs |
| 0.5.27 | 2026-04-02 | Tab-style delivery now revalidates stale explicit tab IDs against an exact live session match before failing, so banners can still highlight the recovered tab after window/tab registration drift |
| 0.5.26 | 2026-04-02 | Authoritative Claude notification events now keep exact runtime/session binding only, and fail closed instead of inheriting heuristic tab resolution when the owning tab is ambiguous |
| 0.5.25 | 2026-04-02 | Amp is now a first-class normalized AI notification source with dedicated triggers, settings coverage, and source labeling |
| 0.5.24 | 2026-04-02 | Mentat is now a first-class normalized AI notification source with dedicated triggers, settings coverage, and source labeling |
| 0.5.23 | 2026-04-02 | Goose is now a first-class normalized AI notification source with dedicated triggers, settings coverage, and source labeling |
| 0.5.22 | 2026-04-02 | Devin is now a first-class normalized AI notification source with dedicated triggers, settings coverage, and source labeling |
| 0.5.21 | 2026-04-02 | Amazon Q is now a first-class normalized AI notification source with dedicated triggers, settings coverage, and source labeling |
| 0.5.20 | 2026-04-02 | Cody is now a first-class normalized AI notification source with dedicated triggers, settings coverage, and source labeling |
| 0.5.19 | 2026-04-02 | ChatGPT is now a first-class normalized AI notification source with dedicated triggers, settings coverage, and source labeling |
| 0.5.18 | 2026-04-02 | Gemini is now a first-class normalized AI notification source with dedicated triggers, settings coverage, and source labeling |
| 0.5.17 | 2026-04-02 | Codex notify-hook events now export the owning overlay tab UUID, and authoritative stale tab IDs are corrected via exact session binding before notification delivery |
| 0.5.16 | 2026-04-02 | Arabic, French, and Hebrew localizations now include the new acknowledgments/about stack summary, license summary, and open-acknowledgments strings |
| 0.5.15 | 2026-04-02 | The website compare page now points directly at the hosted Chau7 DMG download and the shared footer test count reflects the latest suite size |
| 0.5.14 | 2026-04-02 | The issue-intake relay now serves a small landing page on issues.chau7.sh while keeping POST issue submission at the root endpoint for the app |
| 0.5.13 | 2026-04-02 | Restore-time shell commands now preserve waiting-input suppression, notification action delegates return real cross-window outcomes, and bug-report issue intake defaults to issues.chau7.sh |
| 0.5.12 | 2026-04-02 | Pre-release DMG packaging now defaults to an Apple Silicon artifact with a styled drag-to-install layout, removes duplicate proxy bundling, and keeps the larger universal helper build optional |
| 0.5.11 | 2026-04-02 | Claude runtime binding now fails closed on ambiguous same-repo tabs and uses exact tab session metadata before adopting or routing notification events |
| 0.5.9 | 2026-04-01 | Transcript-derived Claude/Codex run telemetry can now be rebuilt in place from the debug console to repair historical token corruption |
| 0.5.10 | 2026-04-02 | Codex notify hook installation now preserves existing user hooks, retains authoritative opaque thread IDs, and only disables prompt fallback when the Codex hook is actually installed |
| 0.5.8 | 2026-04-01 | Debug analytics now separates proxy API-call data from AI run telemetry, and proxy settings expose explicit OpenAI-compatible routing control |
| 0.5.7 | 2026-04-01 | Transcript-derived AI run metrics now use canonical token fields, run-local slicing, Claude usage deduplication, and invalidation of implausible historical totals |
| 0.5.6 | 2026-03-29 | Remote relay control frames now require encryption after handshake, and remote push registration uses HTTP(S) relay endpoints instead of websocket URLs |
| 0.5.5 | 2026-03-29 | Runtime Claude events now bind to exact session IDs and preserve multiple same-directory agent tabs without cwd collisions |
| 0.5.4 | 2026-03-29 | History store clears now serialize with queued async writes so pending inserts cannot resurrect deleted rows |
| 0.5.3 | 2026-03-29 | Reopen Closed Tab now preserves tab identity metadata, including tab ID, creation time, and repo grouping |
| 0.5.2 | 2026-03-29 | Shell runtime launch preserves argument boundaries; notification pipeline respects disabled single-action rules |
| 0.5.1 | 2026-03-19 | Richer remote approval context on iPhone: directory, recent command, project/branch, and MCP source notes |
| 0.5.0 | 2026-01-21 | Tab notification styling, major tab bar fixes |
| 0.4.0 | 2026-01-20 | Smart scroll, watchdog recovery, enhanced logging |
| 0.3.0 | 2026-01-19 | Tab reordering, notification events, selection fixes |
| 0.2.1 | 2026-01-15 | Shell integration, baseline metrics |
| 0.2.0 | 2026-01-14 | API proxy, task lifecycle, terminal header |
| 0.1.0 | 2026-01-11 | Initial release with core features |
