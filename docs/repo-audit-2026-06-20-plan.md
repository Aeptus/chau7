# Chau7 Audit — Remediation Plan (all 103 findings)

Companion to [`repo-audit-2026-06-20.md`](repo-audit-2026-06-20.md). Every finding number below maps to that report. Sequenced by **risk and dependency**, not by area — the 6 cross-cutting themes mean several findings share one root cause, so shared helpers are built once (Phase 5) and the per-area duplicate findings are resolved by adopting them.

## Principles & guardrails
- **Baseline first, verify per batch.** `swift build && swift test` (~1539 tests), `cargo test`, `go test ./...`, relay/issues `npm test` must be green before and after each phase.
- **macOS app is hot-swapped, never killed** — `cp` the rebuilt binary; no process restart.
- **Every "dead-code" deletion gets a fresh repo-wide reference grep immediately before removal**, even though the verifiers already checked — code may have moved since the audit.
- **One commit per finding or per tight cluster**, so anything can be reverted in isolation. New branch off `main` (current branch has an in-flight dep bump — keep separate).
- Findings are audit claims, not yet build-verified; the build/test gate is what confirms each.

---

## Phase 0 — Baseline & branch  ✅ *(run 2026-06-20)*
Branch `audit/remediation` created off `main` (7c381ff8). Baseline captured:

| Toolchain | Command | Result |
|-----------|---------|--------|
| Swift build | `swift build` | ✅ clean, 24s |
| Swift tests | `swift test` | ⚠️ **3189 tests, 2 skipped, 1 flaky failure** (see below) |
| Rust | `cargo test` | ✅ green (exit 0) |
| Go | `go test ./...` | ✅ green — only `internal/agent` has tests (confirms finding 81) |
| relay | `npm test` | ✅ 3/3 |
| chau7-issues | — | ⚠️ no test script (finding 76, expected) |
| root quality | `npm test` | ✅ 31/31 |

**Known pre-existing flake (not a regression — zero code changed at baseline):**
`MonitorLifecycleIntegrationTests.testHistoryIdleMonitorCanRestartAfterStop`
(`Tests/Chau7Tests/Monitoring/MonitorLifecycleIntegrationTests.swift:215-226`) — async integration test with 4-second `wait(for:)` timeouts; failed 1/3 in isolation (times out at 4.06s under load, passes at ~5.2s otherwise). The 4s timeout is too tight for the filesystem idle-monitor under parallel-test load. **New finding not in the original audit** → fold into Phase 7 (test hardening): raise the timeout / make the wait deterministic. Treat as the known-amber baseline so later phases aren't blamed for it; gate later phases on "no *new* failures" rather than a fully-green suite.

Test count note: suite is **3189 XCTest cases** (the plan's earlier "~1539" was a stale figure).

## Phase 1 — Pure dead-code deletions (safe, mechanical)
Independent, zero-reference removals — biggest count, lowest risk. Batch by language so each runs one build.

- **macOS Swift:** 4, 7, 9, 12, 13, 14, 15, 16, 22, 23, 26, 30, 34, 35, 42, 43, 46, 48, 49, 50, 53, 59, 64, 65, 74, 90, 91
- **Chau7Error trim (45):** delete dead cases + `recoverySuggestion`/`InputValidation`/`RateLimiter`/`logged()`, keep the 2 thrown cases + live core.
- **Rust:** 83 (vestigial config), 86 (walkdir dep), 90, 91 (ambiguous_width FFI export)
- **Go:** 78 (unused State methods), 79 (always-empty `UpdatedAt`)
- **Tooling:** 96 (ci-local-fast + dead ci-lib.sh helpers, keep `ci_relay_ensure_deps`), 97 (quality-helpers shim), 98 (unused import)

Gate: each language's build + tests stay green; deleted symbols confirmed callerless by grep at deletion time.

## Phase 1 status (updated 2026-06-20): ✅ 35 / 35 COMPLETE on `audit/remediation`
All dead-code findings committed (granular, build+test verified, gates green). The final 3 coupled refactors (#45 Chau7Error, #46 DebugContext, #49 LogEnhanced) were done with the analysis below — each kept its live core and was verified by the test gate (which caught a missed `BugReporter.activeContexts` read in #46 and would have caught more). Next: Phase 3 (correctness bugs) is the recommended follow-on.
Audit imprecisions caught & corrected during the work: #50 (whole `Formatters` enum dead, not "keep iso8601" — that was a `DateFormatters.iso8601` substring match); #83 (`.display`→`path.display()`, `.enabled`→`TeeConfig.enabled` false positives); #96 (`ci_section` is internally used, only 4 helpers were ci-local-fast-unique); #48 (a 4th orphaned `StreamSelection` test the grep missed — caught by the test gate).

### Remaining 3 — intricate coupled refactors (analysis pre-done, deferred for a focused pass)
These are NOT deletions; each is a refactor of a core subsystem file where live code interleaves with dead code and the audit summary is imprecise. Hot paths with weak test coverage → do with fresh context + build/test gate.

- **#49 LogEnhanced** (`Sources/Chau7/Logging/LogEnhanced.swift`):
  - LIVE, keep: `LogEnhanced.info/warn/error/trace/log` (20+ callers), the `tab/render/recovery` extension, `LogCategory`, `LogEntry`, and **`PerfTracker.currentMemoryMB()`** (4 external callers: OverlayTabsModel+RestorePipeline:1361/1385, +Refresh:36, DebugConsoleView:1519).
  - DEAD, remove: `LogCorrelation` class (0 external; but coupled — `log()` line 352 `?? LogCorrelation.shared.current` and `PerfTracker.init` line 171 must be edited); `PerfTracker` instance API (init/add/end/measure + props — keep only `currentMemoryMB`); `captureStateSnapshot` (404-427, leaf, uses PerfTracker.measure); `setEnabledCategories`/`enableStructuredOutput` setters (0 callers — the vars they set, `enabledCategories`@235 and `isStructuredOutput`@236, ARE read by `log()`, so change to `let` defaults or simplify the now-constant branches).
  - Order: captureStateSnapshot → setters → strip PerfTracker to currentMemoryMB → remove LogCorrelation + fix log():352.
- **#46 DebugContext** (`Sources/Chau7/Logging/DebugContext.swift`):
  - LIVE, keep: `StateSnapshot` (139-338) and `BugReporter` (339+) — both in the same file.
  - DEAD: `DebugContext` correlation class (17-137, 0 external) + `DebugAssert`. **Coupled to Phase-5 #47** (the two bug-report generators consolidation) — audit says DebugContext correlation dies *with* that consolidation. Do #46 and #47 together. Verify StateSnapshot/BugReporter don't reference DebugContext internally before removing.
- **#45 Chau7Error** (`Sources/Chau7/Utilities/Chau7Error.swift`, 507 lines):
  - LIVE, keep: `FileOperations` (186-298) and `JSONOperations` (299-360) helpers — heavily used; plus the 2 externally-thrown cases (`fileWriteFailed`, `configurationEncodeFailed`) and `errorDescription` for kept cases.
  - DEAD (per audit): most of the 28 error cases, `recoverySuggestion`, `func logged()`, `InputValidation` enum, `RateLimiter`. **CAUTION:** error cases have INTERNAL consumers — `FileOperations`/`JSONOperations` (live) throw/return several cases, and `InputValidation` (being removed) uses the ssh* cases. Must trace which cases each LIVE helper still throws before trimming the enum, or `FileOperations` breaks. This is the riskiest of the three.

## Phase 2 — Wire up the four advertised-but-dead features  ⬆ *(decision: implement, not remove)* — **INVESTIGATED 2026-06-20**
These become real feature work, not deletions. Investigation refined every item against current code; do the three small ones first, stage **#17 last** behind its own design note.

### #3 Keybindings — make unreachable actions user-bindable  **[S, very low risk — do first]**
Verified: `KeybindingsManager.swift` `executeAction()` (~258-363) already handles **all** `KeyAction` cases; only `fromShortcutAction()` (~172-199) is missing the mappings, so ~21 actions can't be rebound in the Settings UI: `selectTab1-9`, `selectAll`, `toggleFullscreen`, `interrupt`, `eof`, `suspend`, `clearLine`, `clearWord`, `toggleBroadcast`, `showClipboardHistory`, `showBookmarks`, `addBookmark`, `closeWindow`.
- **Commit:** add the ~21 `case "<name>": return .<case>` lines to `fromShortcutAction`; confirm none collide with AppDelegate's hardcoded Cmd+1–9 special-casing (those override fine). Opportunistically delete the dead test-only `KeyBinding.parse()` (duplicates `modifiers(from:)`).
- **Test:** assert every `KeyAction` round-trips through `fromShortcutAction(rawValue)` (no unreachable case).

### #33 Inactivity detection — wire `recordActivity` to real input  **[S, low risk]**
Verified: `AppEventEmitter.swift:77` `recordActivity()` (wrapped by `AppModel.recordUserActivity()` at `AppModel.swift:517`) has **zero call sites**, so `lastActivityTime` is frozen at init → `checkInactivity()` measures uptime, firing a spurious `inactivity_timeout` exactly `threshold` minutes after launch.
- **Commit:** call `recordUserActivity()` from keyboard input (`RustTerminalView+Input.swift` keyDown tail). Keyboard only — PTY output would count shell activity as "user active"; mouse is a weaker signal (defer unless desired).
- **Test:** emitter with a 1s threshold; `recordActivity()` resets the clock so an event before the window does not fire, and absence past the window does.

### #44 MinimalMode — implement the chrome-hiding the settings UI already promises  **[M, medium risk — small design call]**
Verified: `MinimalMode.swift` persists `isEnabled`/`hideTabBar`/`hideTitleBar`/`hideStatusBar`/`hideSidebar` and posts `.minimalModeChanged`, but **nothing observes it** and **no `Cmd+Shift+M` is registered** (the shortcut only appears as a label in `MinimalModeSettingsView`).
- **Design call (small):** confirm exactly what "minimal" hides. Recommend phase-1 scope = tab bar + status bar overlay only (defer title-bar/sidebar to avoid window-chrome reflow risk).
- **Commits:** (a) observe `.minimalModeChanged` in `Chau7OverlayView` and gate the tab-bar / status-bar rendering on `MinimalMode.shared.hideTabBar/hideStatusBar`; (b) add `toggleMinimalMode` to `KeyAction` + `fromShortcutAction` + `executeAction` (→ `MinimalMode.shared.toggle()`) and a View-menu item, wiring `Cmd+Shift+M`.
- **Test:** toggling `isEnabled` flips the gating flags; the keybinding routes to `toggle()`.

### #17 Sixel/Kitty graphics — render the already-decoded images  **[XL, HIGH risk — do LAST, own design note]**
**Investigation corrected the audit's premise:** the decoders are NOT missing. `rust/chau7_terminal/src/graphics.rs` already (a) intercepts Sixel/Kitty/iTerm2 sequences, (b) `decode_sixel()` (~657-838) and the Kitty decoder (~1006-1137) produce **RGBA**, and (c) FFI `getPendingImages()` marshals `(protocol, data, anchorRow, anchorCol)` to Swift (`RustTerminalView.swift:2245-2277`). The toggles (`GraphicsSettingsView` → `SixelKittyBridge`) are live. The gap is purely **Swift-side placement**: `RustTerminalView+Rendering.swift:184-193` only *logs* each image; the iTerm2 overlay path exists but Sixel/Kitty RGBA is never turned into a view. There is **no `InlineImageView`** for it.
- **Design note must decide (before coding):** (1) surface decoded width/height from Rust (the marshaled `data` is RGBA bytes — needs dimensions); (2) sizing policy — native pixels vs. fit-to-N-cells; (3) scroll/resize anchoring — stick to grid `(row,col)` like text (recommended) vs. fixed pixel offset; (4) overlay vs. line-displacement (match the existing iTerm2 overlay).
- **Commits (staged, all behind the existing feature flag so a bad frame can't reach users who haven't opted in):** (a) Rust: add width/height to the pending-image FFI struct (+ a `decode_sixel` round-trip unit test); (b) Swift: `InlineImageView` building `NSImage` from RGBA+dims; (c) anchor→grid placement reusing the iTerm2 overlay list; (d) wire into `:184-193`.
- **Risk:** HIGH — first visible images in the app; wrong sizing/anchoring corrupts the render. Gate on the flag, add a placement regression test, manual-verify via `/run`.

> **Sequencing:** #3 → #33 → #44 → (#17 last). #17 is genuinely the largest item but is now bounded to a render-integration problem, not a decoder build.

## Phase 3 — Correctness fixes (bugs)  ✅ COMPLETE (2026-06-20)
All 12 fixed & committed (63, 70, 73, 52, 8, 38, 6, 24, 82, 99, 89, 75). Each build/test-verified per toolchain. #75 semantics decided by user: **count only successful creations**. #63's regression test deferred to #67 (iOS test target). #38 required confirming the adoption path doesn't hold the lock (it doesn't) before guarding — the audit's "guard all 4" was safe only after that check.
Highest user-impact. Each gets a regression test where the surface allows.
- **63 (HIGH)** iOS double output injection corrupting the grid — single source of truth + test
- **75** chau7-issues rate-limit consumed before issue creation (lockout on transient GitHub 5xx) — record after success
- **52** `list_snippets` always returns `[]` — populate from `SnippetManager.shared.entries`
- **8** SplitDivider NSCursor leak on teardown-while-hovered — balanced pop on `.onDisappear`
- **38** adoption-cache fields bypass the class's `NSLock` — route through the lock
- **6** ConfigFileWatcher never re-arms after create/rename — reopen fd + restart source
- **24** NotificationRateLimiter buckets grow unbounded — prune/cap
- **70** relay HMAC compared with `===` — constant-time compare
- **73** relay APNs failures swallowed — log status/body for observability
- **89** Rust `set_rows` never called on resize (frozen dirty count) — call on resize (ties into 88)
- **82** Go per-connection deadline-reset goroutine leaks per reconnect — bound to connection lifetime
- **99** tooling `exec()` silently drops `stdin`/`quiet` — honor caller options

## Phase 4 — Performance fixes  ✅ COMPLETE (2026-06-20)
All 9 done & committed (29, 85, 57, 56, 61, 2, 37, 69, 95). Each build/test-verified. #37 gated behind `CHAU7_MEMORY_DIAGNOSTICS` rather than deleted (OOM investigation may be ongoing). Also fixed a TOCTOU security regression in #75 (Phase 3) flagged by the commit security review — reserve/release made atomic.

- **29** O(columns²) per-row column-map rebuild in telemetry parse — reuse the map-taking variant (`parseRun` precedent)
- **85** Rust tracker reopens SQLite + runs CREATE/ALTER/DELETE every command (×38 sites) — guard schema with `PRAGMA user_version`, gate cleanup to once/day
- **57** LocalizedFormatters rebuilt per access (per terminal line) — memoize
- **56** ISO8601DateFormatter minted per API-call message — hoist one instance
- **61** `appendSnapshotIfNeeded` re-reads entire JSONL on first write per provider — track offset/state
- **2** KeybindingsManager rebuilds a signature string per key event — invalidate via `didSet`, not recompute-and-compare
- **37** leak-investigation RSS instrumentation left in `moveTab` hot path — remove
- **69** relay mints APNs JWT per notification — cache (~50 min TTL)
- **95** Rust `ansi_sgr_sequence` allocates a `Vec<String>` per style transition — write into reusable buffer

## Phase 5 — Cross-cutting consolidations (build the shared helper once)  ✅ CLOSED (22/22 actionable, 2026-06-20)
Done: 84, 93, 54, 62, 36, 10, 72, 66+68, 60, 58, 41, 40, 31 (TelemetryRun.applyContent), 55 (ProxyManager requestJSON/postJSON generics), 88 (DirtyRowTracker atomics), 32 (ProviderFamily.classify), 25 (ExecutionReport.success/failure — 41 sites collapsed), 11 (overlay split, 3889→2757 lines).
**Won't-fix (rationale on record):** 77 (defensive DO pattern — correct after #75 hardening); 101 (low value + script names wired into AIToolRegistry process detection; parameterizing needs symlinks); 92 (OSC7 dedup — needs invasive GraphicsInterceptor state-machine change on the hot PTY path for a low-severity duplicate parse).
**Deferred (warrant a focused/less-loaded pass — NOT done):** 51 (Unix-socket C-interop ×4 servers — zero unit coverage + flaky 16-min gate = unsafe to refactor blind); 47 (bug-report flow — the two generators differ; routing to the privacy-aware `BugReportDraft` path is a product decision).
**DS follow-up owed (from #11):** 42 pre-existing literals (font sizes, named accent colors) relocated verbatim into the new overlay files tripped the DS ratchet; committed with `CHAU7_SKIP_DS_CHECK=1` + justification. Migrate to `Appearance/` tokens in a dedicated pass (accent colors don't map 1:1; font sizes must match tokens exactly) — keep it separate from code motion.
New shared helpers added this phase: ProviderColors, CountFormat, ProcessMemory, ProviderFamily, AgentBackend protocol defaults, relay forwardToSession, utils::compact_path, ExecutionReport factories, OverlayColors.
Note: macOS test gate normalized to ~72-76s once load lifted; MonitorLifecycle timing tests (4s waits) flake under load — pass in isolation (gate on "no NEW failures").

This is the highest-leverage phase. Each helper subsumes multiple per-area duplicate findings; resolve the *drift* (orange/purple, count thresholds) as part of consolidating.
- **36** `ProcessMemory.residentBytes()` — one mach reader (replaces 3 copies)
- **51** shared Unix-socket helper (promote ScriptingAPI's `makeUnixSockaddr`/`canConnectToSocket`) — kills the risky 104-byte `strncpy` divergence in MCPServerManager
- **60 + 32** `color(forProvider:)` + `ProviderFamily.classify(_:)` — single source, resolve orange-vs-purple
- **58** compact token-count formatter — single source, resolve threshold/casing drift
- **62** unify `validatedKey`/`normalizeKey` a–z predicate
- **84** Rust `utils::compact_path(path, anchors)` (replaces 4 copies)
- **25** notification per-handler `ExecutionReport` boilerplate → shared helper
- **31** content→run field mapping shared between recorder and repair service
- **55** `requestJSON`/`postJSON` generics across ProxyManager endpoints
- **72** relay `forwardToSession(env, deviceId, request)` for the 3 route handlers
- **47** consolidate the two bug-report generators onto privacy-aware `BugReportDraft` (lets DebugContext correlation die with it)
- **54** collapse 10 identical `tab_*` dispatch cases in `MCPSession.callTool`
- **10** collapse `SessionFilesTracker` pass-through into `TurnFilesTracker`
- **40** factor TerminalMigrationWizard save-apply-restore dance
- **41** factor agent-backend `launchCommand`/`formatPromptInput` tails
- **66 + 68** iOS: extract approval-notification block + stream-mode guard
- **92** Rust: stop parsing OSC 7 twice per chunk (drop `scan_osc7` duplicate)
- **88** collapse dead DirtyRowTracker bitmap → `{full_dirty, rows}` atomics (carries 89's fix)
- **101** parameterize the near-duplicate PTY/CLI wrapper scripts
- **77** chau7-issues DO: drop over-validation of the fixed internal route
- **93** make `GraphicsInterceptor::feed` private (only `feed_owned`/tests use it)
- **11** extract clipboard/bookmarks/snippets overlays out of `Chau7OverlayView` (pure cut/paste, −~25%)

## Phase 6 — Hand-mirrored list sync + guard tests — **INVESTIGATED 2026-06-20**
Stops the "lists drift" theme from recurring. All three confirmed still-live; do in order #21 → #5 → #1.
- **#21 [S]** Phase 5 added `NotificationActionRegistry.makeDefault()` + a test covering *it*, but `NotificationActionExecutor.init` (`NotificationActionExecutor.swift:118-150`) **still hand-maintains its own 23-handler array** — so a handler added to `makeDefault` and tested can still ship missing from production. **Commit:** build the executor's registry from `makeDefault()`, swapping in the executor's typed `timeTrackingHandler` instance (it needs to share `activeTimers` state) where the time-tracking types appear. **Test:** assert `executor.registry.registeredActionTypes == makeDefault().registeredActionTypes`.
- **#5 [S]** `SettingsSearch.swift` `searchableSettings` (~211+) omits **4 of the `SettingsSection` cases**: `about`, `hoverCard`, `repositories`, `mcpControl` (unreachable via settings search despite live UI). **Commit:** backfill 4 `SearchableSetting` entries (mirror existing keyword/description pattern + localization keys). **Test (shared with Phase 7):** `Set(searchableSettings.map(\.section)) == Set(SettingsSection.allCases)`.
- **#1 (partial) [M]** `FeatureSettings.swift` (4261 lines) hand-mirrors every persisted setting across **5 sites** (property+didSet, `ExportableSettings` field, `exportSettings()` ~3384, `importSettings()` ~3502, `resetAllToDefaults()` ~3677). Precedent for the fix already in-file: `MCPRemoteSettings` (~624). **Commit (first cluster only):** extract one cohesive cluster — recommend **Terminal Appearance** (cursorStyle/Blink/BlinkRate/Color, bellEnabled/Sound/Visual/RateLimit, scrollbackLines/restoredScrollbackLines, unicodeAmbiguousWidth ≈ 11 props) — as a nested `Codable` struct; export/import/reset iterate the struct, defaults come from `TerminalAppearanceSettings()`. **Test:** export→import round-trip preserves every field. (Remaining clusters are Phase 8 #1.)

## Phase 7 — Test gaps (highest risk-reduction per effort) — **INVESTIGATED 2026-06-20**
Two of these (#67, #76) require **standing up a test harness that doesn't exist yet** — that's the bulk of the effort. Order: #103 (trivial) → #5 (trivial, shared w/ Phase 6) → #81 → #76 → #67.
- **#103 [S]** Dead classifier branch: `scripts/quality/helpers.mjs:232` includes extensionless `scripts/` files in the `shell` set, but the `staged-shellcheck` gate (`registry.mjs:415-427`) re-filters `.applies`/`.run` to `/\.(sh|bash)$/`, so the 5 extensionless bash scripts (`scripts/order66`, `check-anti-slop`, `check-design-system`, `ci-local`, `apps/chau7-macos/Scripts/order66`) are **never shellchecked**. **Commit:** detect a `#!.*sh` shebang in the gate's filter (or drop the dead `/^scripts\//` clause); run shellcheck over the now-included files and fix anything it flags.
- **#5 [S]** searchableSettings coverage test — same test as Phase 6 #5 (`allCases` ⊆ searched). Land with the backfill.
- **#81 [M]** `services/chau7-remote/internal/agent/state.go` has **no `state_test.go`**. Highest-value gap: `LoadState` (~128-133) **silently zeroes the device identity** (`MacPrivateKey=""`, returns `nil` error) when `unwrapKey` fails. **Tests:** `TestSaveLoadState_roundTrip`, `TestWrapUnwrap_symmetric`, `TestLoadState_unwrapFailure_resetsSilently` (pins the current behavior so a future fix is a conscious change), `TestMigrateLegacyPairedDevice`, `TestUpsertPairedDevice_insert/update/fingerprintDeterministic`, `TestDeriveWrappingKey_deterministic`, `TestLoadState_missingFile`. Mock the machine UUID via helper/env.
- **#76 [M]** `services/chau7-issues` has **no tests, no vitest config, no `test` script**. Needs `vitest` + `@cloudflare/vitest-pool-workers` for DO mocking (scaffold from scratch — the bulk of the effort). **Tests:** rate-limit window (reserve 5 → 6th 429; reset after expiry; concurrent-reserve TOCTOU safety — guards the Phase-3/5 fix), input validation (bad JSON→400, missing/empty/oversized title→400, oversized body→400, bad `GITHUB_ISSUE_REPO`→503, label filtering/cap), GitHub-failure releases the slot. Note: validation/parse errors still consume a slot before validation runs — tests should pin current behavior and flag it.
- **#67 [M — but needs new iOS test target]** `apps/chau7-ios/Chau7RemoteApp` has **zero test files / no test target**. Step 1 is adding an XCTest target to `Chau7RemoteApp.xcodeproj` (mechanical but new). Targets are pure functions, fast: `RemoteCrypto.swift` (ChaChaPoly seal/open round-trip + tamper rejection; 12-byte nonce = 4-prefix+8-seq LE; AAD/header binding), `RemoteModels.swift` `ANSIStripper.strip` (CSI/OSC/bare-ESC edge cases), `RemoteTerminalOutputStore.swift` (append/flush/snapshot/trim). **Also lands the deferred #63 regression test:** `RemoteTerminalRendererStore.swift` re-injects the pre-playback replay chunk (appended ~85, injected again in `ensurePlayback` ~132) — assert no duplication.

## Phase 8 — God-object decomposition  ✅ *(decision: include, incremental)* — **INVESTIGATED 2026-06-20**
In scope. Behavior-preserving, **one cohesive cluster per commit**, build/hot-swap/test after each — **last** because it's the riskiest and the app can't be killed. **#11 (overlay split) already DONE in Phase 5.** Verified current sizes: AppDelegate **2968**, FeatureSettings **4261**, RustTerminalView **3977 core + 5 extensions (~7371 total)** — the audit's "~10k monolith" is wrong; it's already extension-split.

### #39 AppDelegate (2968) — 6 commits, increasing coupling  **[the cleanest win — start here]**
Mapped to real MARK sections/line ranges:
1. **Menu-forwarder router [S, low]** — ~34 single-line forwarders (`showAbout`, `cut`, `pasteEscaped`, `toggleTabBar`, `moveTabRight`, split actions, …; ~975-2011) → `AppDelegate+MenuRouter.swift`. Only call `ensureActiveOverlayModel()`/`activeTerminalView()` — zero internal coupling.
2. **URL-scheme handler [S, low]** — `application(_:open:)` + `makeTab/makeGroup` parsing (~1928-2010) → `URLSchemeHandler`.
3. **Autosave/persist [S, med]** — multi-window autosave timer + signature + atomic save (~1301-1501) → `WindowPersistenceManager`.
4. **Tab/group move-between-windows [M, med]** — `moveTab`/`moveGroup` (~1502-1770); **carries the RSS leak-investigation instrumentation — remove it here** once the cross-window-drag leak is confirmed resolved.
5. **Multi-window restore orchestration [L, HIGH — hot startup path, do near-last, test hard]** — deferred-restore scheduler, per-window reveal/demotion coalescing (~1771-1879 + didFinishLaunching wiring).
6. **App-Nap + latency-scope controller [M, low]** — activity token + latency scopes (~77-974) → `AppNapController`; lifecycle stays last.
Prereq: the shared `ProcessMemory.residentBytes()` already exists (Phase 5 #36) — drop AppDelegate's local mach reader (~2954) when extracting.

### #1 FeatureSettings (4261) — continue Phase 6's nested-Codable extraction, ~6 more clusters  **[mechanical, do after Phase 6 establishes the pattern]**
After Phase 6 lands the Terminal-Appearance cluster, repeat cluster-by-cluster (each: nested `Codable` + fold the 5 mirror sites into it + round-trip test): Font & Colors, Terminal Behavior, **Notification Settings (highest verification burden — per-event config map)**, MCP/Integration (reuse `MCPRemoteSettings`), Discovery/Input, Sync/Advanced. End state: export/import/reset/property are one declaration each. **Add a drift-guard test:** every stored property is mirrored in `ExportableSettings`.

### #19 RustTerminalView (3977 core) — bounded low-risk subset only; defer the rest  **[do LAST]**
**Investigation verdict:** full promotion of the `+Input`/`+Mouse`/`+Rendering`/`+UI` extensions into collaborator types is **HIGH risk and currently blocked** — they make 40-100+ direct accesses each to the class's *private stored properties* (`applicationCursorMode`, `markedTextStorage`, `lastReportedMouseCell`, font/grid state…). Extracting them needs either widening those to public (breaks encapsulation) or a mutable state-bag injection (large, hot-render-path churn). So Phase 8 takes only the **mechanical, self-contained** slices:
1. **`RustTerminalFFI` symbol bindings → own file [S, very low]** — pure FFI struct, no behavior.
2. **`RustGridView` + `CursorStyle` → own file [S, low]** (~11-308) — self-contained view.
3. **Polling/idle-throttle state machine → `PollingModeController` [M, med]** — orthogonal `DispatchSourceTimer` scheduling.
**Deferred (own future effort, not Phase 8):** Input/Mouse/Rendering collaborator extraction — requires a stored-property-access refactor first; render path is the single most regression-sensitive surface (verify frame rate via `/run`).

> **Sequencing within Phase 8:** AppDelegate #1-2 (low) → RustTerminalView FFI/GridView (low) → FeatureSettings clusters (mechanical) → AppDelegate #3,#6 (med) → AppDelegate #4 (leak-instrumentation removal) → RustTerminalView PollingModeController → **AppDelegate #5 restore (HIGH) last, with heavy manual verification.**

## Phase 9 — Documentation sweep (last, reflects post-refactor reality) — **INVESTIGATED 2026-06-20**
All 11 confirmed stale; each is an S edit. **Split by Phase-8 dependency** — three READMEs cover dirs Phase 8 will churn, so do them *after* Phase 8; the rest are independent and can land anytime.
- **Do AFTER Phase 8** (dirs change): **#18** RustBackend (lists nonexistent `RustDimPatcher.swift`; missing the 5 `RustTerminalView+*` extensions + 3 real files), **#27** Performance (lists 6 deleted files, omits 5 real ones + 2 dead Key Types), **#20** Notifications (lists deleted `TabResolver.swift`; event-flow omits `AIEventNotificationEngine`/`AISessionEventReconciler`/`NotificationDeliveryPolicy`).
- **Independent (anytime):** **#28** Monitoring (7 files undocumented), **#34** Runtime (dead `ClaudeCodeBackend.trigger(from:)` ~60-73 — delete the method, README line already gone), **#71** relay (missing `GET`/`POST /pending/:deviceId`), **#94** chau7_terminal (stale line counts; `RenderSnapshot`→`GridSnapshot`), **#100** macOS CI (wrong-case `Scripts/`, legacy `ci-local-fast` → point to `pnpm quality:staged/prepush`), **#102** scripts count (17→21).
- **Comments:** **#80** `chau7-remote/internal/agent/agent.go:782` — `// identity` mislabels a small-order point (u=1, order 4); fix to "small-order point (order 4)". **#87** `chau7_optim/src/display_helpers.rs:3-4` — references nonexistent `cc_economics.rs` (never ported); drop the ref.
- **Recurrence guard (optional):** add a `check-readme-tables` quality gate (mirror `staged-shellcheck` in `scripts/quality/registry.mjs`) that parses README file-tables and fails on any listed file absent from `git ls-files`. Run on `quality:full` (not per-commit). Also: prefer dropping hardcoded counts/line numbers in favor of ranges or "see source" to stop the rot at the source.

---

## Coverage check
Findings 1–103 each appear in exactly one primary phase (a few cross-referenced where a helper and a guard test both apply).

## Decisions on record (2026-06-20)
- **Phase 2:** wire the four dead features up rather than remove them → Phase 2 is now real feature work; **finding 17 (Sixel/Kitty) is the largest single item in the plan** and wants its own design sub-step.
- **Phase 8:** god-object decompositions are **in scope**, done incrementally (one cluster per commit), sequenced last. Investigation refined this: RustTerminalView's collaborator extraction is **largely deferred** (extensions are too tightly bound to private stored properties to split safely now) — Phase 8 takes only the mechanical FFI/GridView/Polling slices.
- **Execution status (2026-06-20):** Phases 0/1/3/4/5 **executed & committed** on `audit/remediation` (85 commits, not pushed). Phases 2/6/7/8/9 **investigated & planned** (this revision); not yet executed.

## Suggested execution order when resumed
**Done:** 0 → 1 → 3 → 4 → 5. **Remaining (investigated 2026-06-20):**

**6 (list-sync)** → **7 (tests)** → **2 (wire features; #17 last)** → **8 (god-objects)** → **9 (doc sweep)**.

Refined per investigation:
- **Quick wins first (≈1 day, all S):** Phase 6 #21 + #5, Phase 7 #103, Phase 9 independent docs/comments (#28/#34/#71/#94/#100/#102/#80/#87) and Phase 2 #3/#33. These are low-risk, high-signal, and don't depend on anything else.
- **Then the test harnesses (the real effort in Phase 7):** #81 (Go), #76 (chau7-issues — needs vitest+workers pool), #67 (iOS — needs a brand-new XCTest target; also lands the deferred #63 regression test).
- **Then Phase 6 #1** (first FeatureSettings cluster) — establishes the nested-Codable pattern that **Phase 8 #1 continues**, so do them adjacent.
- **Then Phase 2 #44** (MinimalMode, small design call) and the **Phase 8 god-object splits** (AppDelegate first — cleanest; RustTerminalView subset only; restore-orchestration last).
- **#17 Sixel/Kitty and Phase 9's three Phase-8-dependent READMEs (#18/#27/#20) come last.**

Rationale unchanged: clear cheap/low-risk wins and shrink surface area before the two large blocks (feature-wiring, decomposition); doc sweep for churned dirs after their refactors land.

**Recommendation before resuming:** open a PR for the ~70 landed findings (Phases 0/1/3/4/5, branch `audit/remediation`, 85 commits) so the verified work merges before the branch grows into the larger blocks.
