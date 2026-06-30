# Chau7 Repo Audit — Simplification & Improvement Opportunities

_Generated 2026-06-20 via a 16-area parallel audit with per-area adversarial verification. 103 findings kept, 4 dropped as false._

## Executive Summary

The Chau7 monorepo is in fundamentally healthy shape: nearly every finding is low-to-medium severity maintainability debt rather than a functional defect, and the verification notes repeatedly confirm that live paths are correct while the cruft sits beside them. Two themes dominate. First, dead/vestigial code is pervasive and concentrated in the macOS app — entire files (AccessibilityUtilities, DangerousCommandConfirmationView, MinimalMode, TerminalStartupQueue), whole feature subsystems (DebugContext correlation, LogEnhanced sub-systems, much of Chau7Error and AppConstants), dozens of unreachable methods/enum cases, and the same pattern echoes into the Rust crates (DirtyRowTracker bitmap, ambiguous_width FFI knob), Go service (unused State methods), and tooling (ci-local-fast, re-export shims). Second, copy-paste duplication recurs across nearly every area: the same root cause shows up as the mach memory reader in 3 files, Unix-socket setup in 4 servers, provider classification/colors in 4-5 views, count-abbreviation in 5 views, compact_path in 4 Rust modules, and ExecutionReport/notification-handler boilerplate. These two themes are self-reinforcing — duplicated logic drifts (provider colors already disagree orange vs purple; count thresholds render inconsistently), and hand-mirrored lists (FeatureSettings export/import/reset, the 23-handler notification list) silently fall out of sync.

The highest-leverage work is therefore consolidation, not new features: collapsing the duplicated idioms into shared helpers and deleting the dead infrastructure would meaningfully shrink the surface area of the four god-objects (AppDelegate 2974 lines, FeatureSettings 4255, RustTerminalView ~10k, Chau7OverlayView 3889) that make the genuinely subtle logic hard to test. The two real correctness risks worth prioritizing are the iOS double-injection render-corruption bug (high) and the chau7-issues rate-limit-consumed-on-failure lockout (medium); alongside them, the systemic test gaps in the iOS app (zero tests) and the two backend services are the biggest risk-reduction opportunities. Per-folder README drift is rampant (8+ stale READMEs against the repo's own documented accuracy convention) and is almost entirely quick wins.

## Top Quick Wins (small effort, high value)

1. **Fix iOS pre-playback double output injection (render corruption)** — _iOS · Remote app_
   - High-severity correctness bug with a small fix: pre-playback chunks land in both replayByTabID and pendingReplayByTabID and both are injected into the Rust terminal, duplicating lines and corrupting the grid. Use one source of truth and add a regression test.
   - `apps/chau7-ios/Chau7RemoteApp/RemoteTerminalRendererStore.swift`
2. **Delete entirely-dead files (AccessibilityUtilities, DangerousCommandConfirmationView)** — _macOS · Utilities/Logging/UI-infra_
   - 523 lines across two files with zero references; the live confirmation UI is the NSAlert in DangerousCommandGuard. Pure deletion, no behavior change.
   - `apps/chau7-macos/Sources/Chau7/Utilities/AccessibilityUtilities.swift`, `apps/chau7-macos/Sources/Chau7/Commands/DangerousCommandConfirmationView.swift`
3. **Delete unused TerminalStartupQueue and dead terminal/render helpers** — _macOS · Terminal & Rendering_
   - TerminalStartupQueue advertises startup serialization that is never wired in; parseOSC7, the diagnostic/stress methods, and the inline-image helpers are all confirmed callerless dead code re-implementing live paths.
   - `apps/chau7-macos/Sources/Chau7/RustBackend/TerminalStartupQueue.swift`, `apps/chau7-macos/Sources/Chau7/RustBackend/RustTerminalView+Rendering.swift`, `apps/chau7-macos/Sources/Chau7/RustBackend/RustTerminalView+UI.swift`, `apps/chau7-macos/Sources/Chau7/Rendering/InlineImageSupport.swift`
4. **Unify notification handler list via makeDefault to close the no-test gap** — _macOS · Notifications_
   - The executor's 23-handler array (what actually runs) duplicates makeDefault() (what the completeness test covers), so a new handler added to the tested list silently goes missing in production. Have the executor call makeDefault with an override.
   - `apps/chau7-macos/Sources/Chau7/Notifications/NotificationActionExecutor.swift`, `apps/chau7-macos/Sources/Chau7/Notifications/Handlers/NotificationActionRegistry.swift`
5. **Remove the dead redundant ternary and dead overloads in TelemetryStore** — _macOS · Monitoring/Telemetry/Perf_
   - Line 2002 picks between two identical SQL strings (misleading); the per-row column-map rebuild in parseTurn/parseToolCall/parseUsageEvidence is O(columns^2) with a map-taking variant already proven by parseRun. Small fix, real parse-path win.
   - `apps/chau7-macos/Sources/Chau7/Telemetry/TelemetryStore.swift`
6. **Cache or hoist per-call formatters on hot/IPC paths** — _macOS · Features & Data_
   - LocalizedFormatters allocate a new DateFormatter/NumberFormatter on every access (read per terminal line render); ProxyIPCServer mints a fresh ISO8601DateFormatter per inbound api_call. Memoize/hoist a single instance, mirroring TelemetryQueryService.
   - `apps/chau7-macos/Sources/Chau7/Localization/Localization.swift`, `apps/chau7-macos/Sources/Chau7/Proxy/ProxyIPCServer.swift`
7. **Fix list_snippets always returning empty in the scripting API** — _macOS · MCP/AI/Proxy/Remote_
   - list_snippets is advertised and dispatched but unconditionally returns []; run_snippet already reads SnippetManager.shared.entries, so clients can run a snippet by name but never discover names. Populate from the same source.
   - `apps/chau7-macos/Sources/Chau7/Scripting/ScriptingAPI.swift`
8. **Refresh the 8 stale per-folder READMEs (and Rust/service docs)** — _macOS · Monitoring/Telemetry/Perf_
   - Multiple READMEs list nonexistent files (RustDimPatcher, TabResolver, 6 deleted Performance files, cc_economics) and omit real ones, directly violating the repo's documented per-folder README accuracy convention. All small doc edits.
   - `apps/chau7-macos/Sources/Chau7/Performance/README.md`, `apps/chau7-macos/Sources/Chau7/Monitoring/README.md`, `apps/chau7-macos/Sources/Chau7/RustBackend/README.md`, `apps/chau7-macos/Sources/Chau7/Notifications/README.md`, `apps/chau7-macos/Sources/Chau7/Runtime/README.md`, `apps/chau7-macos/rust/chau7_terminal/README.md`, `services/chau7-relay/README.md`
9. **Extract one shared mach resident-memory reader** — _macOS · App lifecycle/Runtime_
   - The mach_task_basic_info resident_size boilerplate is copy-pasted in three files differing only in return type. One ProcessMemory.residentBytes() helper removes the triplication.
   - `apps/chau7-macos/Sources/Chau7/App/AppDelegate.swift`, `apps/chau7-macos/Sources/Chau7/Events/AppEventEmitter.swift`, `apps/chau7-macos/Sources/Chau7/Logging/LogEnhanced.swift`
10. **Delete orphaned CI tooling (ci-local-fast, quality-helpers shim, dead import)** — _Tooling · scripts/CI/build_
   - ci-local-fast (legacy) has no live entry point and its ci-lib.sh helpers are used only by it; quality-helpers.mjs is an unimported re-export shim; runner.mjs imports an unused toolVersion. Keep ci_relay_ensure_deps (still used by ci-local).
   - `scripts/ci-local-fast`, `scripts/ci-lib.sh`, `scripts/git/quality-helpers.mjs`, `scripts/quality/runner.mjs`
11. **Use constant-time HMAC compare and add APNs failure logging in the relay** — _Service · chau7-relay (TS worker)_
   - verifyToken uses `===` on auth-critical HMAC strings (cheap to make constant-time); sendAPNSNotification discards the APNs body so 403/429/500 failures are invisible in production. Both small, both on critical paths.
   - `services/chau7-relay/src/worker.ts`, `services/chau7-relay/src/session.ts`
12. **Remove dead Go State methods and fix the Curve25519 'identity' comment** — _Service · chau7-remote (Go)_
   - MacPublicKeyBytes/IOSPublicKeyBytes/RemovePairedDevice (plus its sole-caller helper syncLegacyFromFirstPairedDevice) are callerless; the {1,0,...} vector is mislabeled 'identity' when it is a small-order point. Deletions plus a one-word doc fix.
   - `services/chau7-remote/internal/agent/state.go`, `services/chau7-remote/internal/agent/agent.go`

## Top High-Impact Improvements

1. **Fix iOS terminal double-injection render corruption** _(effort: small)_ — _iOS · Remote app_
   - The only HIGH-severity correctness finding in the audit: pre-playback output is injected into the Rust terminal twice, silently corrupting the grid (duplicate lines, wrong cursor) for the experimental renderer. Small fix, user-visible product defect.
   - `apps/chau7-ios/Chau7RemoteApp/RemoteTerminalRendererStore.swift`
2. **Add the first iOS test target (crypto, ANSI, output store)** _(effort: medium)_ — _iOS · Remote app_
   - The iOS app has zero tests while owning security/correctness-critical, fully deterministic logic: ChaChaPoly seal/open, hand-built 12-byte nonces, AAD header binding, and a hand-rolled ANSI CSI scanner. A framing or ANSI regression would break the product silently. The double-injection bug above is exactly the kind a test would have caught.
   - `apps/chau7-ios/Chau7RemoteApp/RemoteCrypto.swift`, `apps/chau7-ios/Chau7RemoteApp/RemoteModels.swift`, `apps/chau7-ios/Chau7RemoteApp/RemoteTerminalOutputStore.swift`, `apps/chau7-ios/Chau7RemoteApp/RemoteReconnectBackoff.swift`
3. **Fix the issues-worker rate-limit-on-failure lockout** _(effort: medium)_ — _Service · chau7-issues (TS worker)_
   - Quota is consumed before request parse, validation, and the GitHub call, with no refund path — a malformed payload or a transient GitHub 502 permanently burns one of 5 attempts/hour, locking a user out without ever creating an issue. Move the record to after successful creation (or split check/commit).
   - `services/chau7-issues/src/worker.js`
4. **Add test suites for the two backend services and state.go** _(effort: medium)_ — _Service · chau7-issues (TS worker)_
   - chau7-issues has no 'test' script at all; chau7-remote's state.go (atomic save, AES-GCM key wrap/unwrap by machine UUID, legacy migration, and a silent key-reset on unwrap failure that would destroy device identity) has no state_test.go. These cover the highest-risk security/persistence logic in the services where regressions ship silently.
   - `services/chau7-issues/src/worker.js`, `services/chau7-issues/package.json`, `services/chau7-remote/internal/agent/state.go`
5. **Promote a shared Unix-domain-socket helper across the four servers** _(effort: medium)_ — _macOS · MCP/AI/Proxy/Remote_
   - sockaddr_un construction + connect/retry logic is duplicated across four servers, with MCPServerManager using a hand-rolled 104-byte strncpy buffer variant that diverges from the others. ScriptingAPI already has the cleaner makeUnixSockaddr/canConnectToSocket factoring to promote. Removes a class of subtle, security-adjacent buffer bugs.
   - `apps/chau7-macos/Sources/Chau7/MCP/MCPServerManager.swift`, `apps/chau7-macos/Sources/Chau7/Proxy/ProxyIPCServer.swift`, `apps/chau7-macos/Sources/Chau7/Remote/RemoteIPCServer.swift`, `apps/chau7-macos/Sources/Chau7/Scripting/ScriptingAPI.swift`
6. **Wire or remove the dead inactivity-detection feature** _(effort: small)_ — _macOS · App lifecycle/Runtime_
   - recordActivity is never called, so lastActivityTime is frozen at launch and checkInactivity measures uptime, not inactivity — it will emit a spurious 'inactivity_timeout' notification thresholdMinutes after launch regardless of user activity whenever the threshold is configured. Either wire it to real input or delete the feature.
   - `apps/chau7-macos/Sources/Chau7/Events/AppEventEmitter.swift`, `apps/chau7-macos/Sources/Chau7/App/AppModel.swift`
7. **Decompose AppDelegate (2974 lines) into cohesive collaborators** _(effort: large)_ — _macOS · App lifecycle/Runtime_
   - A god-object mixing lifecycle, App Nap policy, multi-window create/restore/autosave, tab/group move-between-windows, URL schemes, telemetry repair, and ~60 menu forwarders. This concentration makes the genuinely subtle focus/render-lifecycle and startup-restore logic hard to isolate and test. Extract incrementally starting with the low-coupling autosave/persist and tab-move clusters.
   - `apps/chau7-macos/Sources/Chau7/App/AppDelegate.swift`
8. **Incrementally collapse FeatureSettings' multi-way setting mirroring** _(effort: large)_ — _macOS · Settings_
   - A 4255-line god-object where every persisted setting is hand-mirrored across property+didSet, ExportableSettings, exportSettings, importSettings, and resetAllToDefaults (which re-lists hardcoded defaults a third time). Lists drift out of sync. Extracting cohesive clusters into nested Codable value types (precedent: MCPRemoteSettings) collapses toward one declaration per cluster.
   - `apps/chau7-macos/Sources/Chau7/Settings/FeatureSettings.swift`
9. **Consolidate the two parallel bug-report generators** _(effort: medium)_ — _macOS · Utilities/Logging/UI-infra_
   - BugReporter.generateReport and BugReportDraft.saveLocally both build a '# Chau7 Bug Report' markdown doc and write chau7-bug-report-<date>.md with their own DateFormatters; both are reachable from the UI. Consolidating on the newer privacy-aware BugReportDraft removes a maintained-twice path and lets DebugContext's dead correlation system be deleted with it.
   - `apps/chau7-macos/Sources/Chau7/Logging/DebugContext.swift`, `apps/chau7-macos/Sources/Chau7/Logging/BugReportDraft.swift`
10. **Trim the over-engineered error/logging/debug subsystems** _(effort: medium)_ — _macOS · Utilities/Logging/UI-infra_
   - Large swaths are dead while live cores stay: Chau7Error has 24 cases but only 2 are thrown (plus unused recoverySuggestion/InputValidation/RateLimiter/logged); DebugContext/DebugAssert and several LogEnhanced sub-systems (LogCorrelation, PerfTracker public API, structured output) are callerless; MinimalMode is an inert feature with a live settings UI and a header claiming an unimplemented Cmd+Shift+M shortcut. Scoped deletion materially reduces misleading surface area.
   - `apps/chau7-macos/Sources/Chau7/Utilities/Chau7Error.swift`, `apps/chau7-macos/Sources/Chau7/Logging/DebugContext.swift`, `apps/chau7-macos/Sources/Chau7/Logging/LogEnhanced.swift`, `apps/chau7-macos/Sources/Chau7/Appearance/MinimalMode.swift`
11. **Collapse the dead DirtyRowTracker machinery in chau7_terminal** _(effort: medium)_ — _Rust · chau7_terminal + chau7_parse_
   - A ~150-line word-bitmap with RwLock and per-row math is only ever driven all-or-nothing (mark_all_dirty/clear); the granular get_dirty_rows path is fully unreachable and set_rows is never called on resize (latent frozen-count bug). Collapsing to {full_dirty, rows} atomics removes unreachable complexity and the latent resize bug together.
   - `apps/chau7-macos/rust/chau7_terminal/src/metrics.rs`, `apps/chau7-macos/rust/chau7_terminal/src/terminal.rs`
12. **Make per-command Rust tracker stop reopening SQLite and running a DELETE each call** _(effort: medium)_ — _Rust · chau7_optim + chau7_md_
   - track()/track_passthrough() call Tracker::new() per command, re-running CREATE TABLE, CREATE INDEX, two ALTER migrations, and a second index every invocation, then cleanup_old() runs a full DELETE scan after every insert — across 38 TimedExecution sites wrapping fast CLI commands. Guard schema setup with PRAGMA user_version and gate cleanup to once/day.
   - `apps/chau7-macos/rust/chau7_optim/src/tracking.rs`

## Cross-Cutting Themes

### 1. Hand-mirrored lists drift out of sync because there is no single source of truth
**Areas:** macOS · Settings, macOS · Notifications, macOS · App lifecycle/Runtime

The same root cause — a setting/handler must be declared in N parallel places — recurs across subsystems. FeatureSettings mirrors every persisted setting across property+didSet, ExportableSettings, export/import, and resetAllToDefaults (hardcoded defaults a third time). The notification subsystem maintains the 23-handler list in both the executor (runs in prod, untested) and makeDefault (tested). AppConstants is half-adopted, so 'magic numbers in one place' is drift while literals stay scattered. SettingsSearch's searchableSettings hand-mirrors the views with four sections uncovered and no sync test.

**Recommendation:** Make each list iterate one canonical declaration: nested Codable value types own their UserDefaults key+default in FeatureSettings; the executor builds via makeDefault; finish (or drop) AppConstants migration; add a coverage test asserting every SettingsSection has a searchable entry. Prefer a failing test guarding any list that must stay in sync.

### 2. The same provider/formatting logic is reimplemented per call site and has already drifted
**Areas:** macOS · Features & Data, macOS · Monitoring/Telemetry/Perf

Display-formatting helpers are copy-pasted across views and disagree: provider->Color is reimplemented in 4 views (dashboard says claude=.orange while explorers say .purple); count abbreviation is copy-pasted in 5 views with differing thresholds/casing (>1M vs >=1M, k vs K) so the same count renders inconsistently; per-access DateFormatter/NumberFormatter allocation repeats in LocalizedFormatters; and provider-family classification (lowercased contains claude/anthropic/codex/openai) is reimplemented with subtly different sets across the Telemetry recorder, repair service, and store.

**Recommendation:** Centralize one helper each: color(forProvider:), a compact-count formatter, memoized LocalizedFormatters, and a ProviderFamily.classify(_:) enum for the Swift call sites. Resolve the existing orange/purple and threshold/casing inconsistencies as part of the consolidation (SQL LIKE provider sites stay separate).

### 3. Low-level platform plumbing is copy-pasted with diverging implementations
**Areas:** macOS · App lifecycle/Runtime, macOS · MCP/AI/Proxy/Remote, Service · chau7-relay (TS worker), Rust · chau7_optim + chau7_md

Identical infrastructure boilerplate is duplicated, often with one copy that diverges dangerously. The mach resident-memory reader exists in 3 files; sockaddr_un setup + connect/retry is in 4 macOS servers with MCPServerManager using a hand-rolled 104-byte strncpy buffer instead of the safer MemoryLayout-based sizing the others use; ProxyManager repeats GET/POST request-decode-log boilerplate across 6 endpoints; the relay repeats DO-stub dispatch across 3 route handlers; and compact_path is independently defined in 4 Rust modules. The divergence (the strncpy buffer, the differing memory-reader sentinels) is where bugs hide.

**Recommendation:** Promote one shared helper per pattern: ProcessMemory.residentBytes(); a Chau7Core Unix-socket helper (makeUnixSockaddr/canConnectToSocket/retry); requestJSON/postJSON generics in ProxyManager; forwardToSession(env,deviceId,request) in the relay; utils::compact_path(path, anchors) in Rust. Prioritize the socket helper since its diverging copy is the riskiest.

### 4. Dead infrastructure advertises behavior that does not exist
**Areas:** macOS · Terminal & Rendering, macOS · Settings, macOS · App lifecycle/Runtime, Rust · chau7_terminal + chau7_parse, Service · chau7-remote (Go)

A recurring pattern of code/UI/config that implies a capability the live code never delivers — actively misleading, not merely unused. Sixel/Kitty settings toggles render nothing (images are only logged, with Phase 4 TODOs); the inactivity feature emits spurious notifications because recordActivity is never called; MinimalMode is an inert feature with a live settings UI and a header claiming a nonexistent shortcut; the Rust ambiguous_width FFI knob and set_ambiguous_width are a no-op with no Swift caller; ConfigFileWatcher silently stops watching after create/rename; the Go PendingStatePayload.UpdatedAt is always empty and discarded by the relay anyway; Rust config DisplayConfig/FilterConfig/tracking.enabled are serialized but never read.

**Recommendation:** For each, either wire it up or remove the advertised surface (hide the toggle, delete the feature/field/FFI export). Where the no-op is user-facing (Sixel/Kitty toggles, MinimalMode, inactivity notifications) prioritize, since the UI promises a feature the user cannot get.

### 5. Per-folder READMEs and doc comments have drifted from disk, violating the repo's own accuracy convention
**Areas:** macOS · Terminal & Rendering, macOS · Monitoring/Telemetry/Perf, macOS · Notifications, macOS · App lifecycle/Runtime, Rust · chau7_terminal + chau7_parse, Rust · chau7_optim + chau7_md, Service · chau7-relay (TS worker), Tooling · scripts/CI/build

The MEMORY convention says every folder README documents its files; in practice many list deleted files and omit real ones. RustBackend cites nonexistent RustDimPatcher; Notifications cites deleted TabResolver; Performance lists 6 missing files; Monitoring/Analytics omit 7+ real files; Runtime documents dead trigger(from:); chau7_terminal README has stale line counts and a wrong type name (RenderSnapshot vs GridSnapshot); chau7_optim references nonexistent cc_economics.rs; the relay README omits /pending routes; tooling READMEs cite legacy/wrong-case script paths and a wrong script count.

**Recommendation:** Sweep all folder READMEs to match disk in one pass and drop hardcoded counts/line numbers that rot (point to the source instead). Consider a CI check that flags README file tables listing nonexistent files, since this drift recurs.

### 6. Pure, deterministic, security-critical logic ships with no tests across iOS and both services
**Areas:** iOS · Remote app, Service · chau7-issues (TS worker), Service · chau7-remote (Go)

The same test-gap shape repeats in three independent components, all covering the highest-risk logic. The iOS app has zero tests over crypto framing (ChaChaPoly, hand-built nonces, AAD binding), ANSI stripping, and the output store. chau7-issues has no 'test' script over rate-limit windowing, 429/503 mapping, and input validation. chau7-remote's state.go has no tests over atomic save, AES-GCM key wrap/unwrap, legacy migration, and a silent key-reset that would destroy device identity. All three are platform-independent, fast, and would catch silent regressions (the iOS double-injection bug is a concrete example a test would have caught).

**Recommendation:** Stand up a minimal test target in each component focused on the pure security/correctness paths first (round-trip encrypt/decrypt + tamper rejection, rate-limit window edges, save/load round-trip + unwrap-failure fallback). Highest risk-reduction per unit effort in the repo.

## Findings by Area

- **macOS · Settings** (high:0 medium:1 low:5) — Healthy live behavior, but the 4255-line FeatureSettings god-object and several hand-mirrored lists (export/import/reset, searchableSettings) drive sync drift; minor dead keybinding code and a config-watcher arming edge case.
- **macOS · Tabs & Split panes** (high:0 medium:1 low:4) — Mostly dead code (runAll, agentCount, pass-through SessionFilesTracker) plus a medium cursor-leak on divider teardown-while-hovered and an oversized overlay view file that mixes feature overlays into the tab-bar code.
- **macOS · Terminal & Rendering** (high:0 medium:2 low:6) — Substantial confirmed dead code (TerminalStartupQueue, parseOSC7, diagnostic/image helpers, no-op stub); a no-op Sixel/Kitty toggle that advertises a non-functional feature; two large god-objects/architecture observations and a stale README.
- **macOS · Notifications** (high:0 medium:4 low:3) — A duplicated 23-handler list that bypasses the completeness test, an unbounded rate-limiter bucket map, several dead methods/inits and an unreachable guard, plus boilerplate and a stale README.
- **macOS · Monitoring/Telemetry/Perf** (high:0 medium:2 low:4) — An O(columns^2) per-row column-map rebuild in parse paths is the standout; plus duplicated content-mapping and provider-classification logic, a dead redundant ternary, and two badly-stale folder READMEs.
- **macOS · App lifecycle/Runtime** (high:0 medium:2 low:8) — A spurious-notification-emitting dead inactivity feature, the 2974-line AppDelegate god-object, an NSLock invariant violated by two cache fields, and several duplications (mach reader, backend tails, migration dance) plus left-in leak instrumentation.
- **macOS · Utilities/Logging/UI-infra** (high:0 medium:7 low:2) — The densest dead-code area: two fully-dead files, an inert MinimalMode with live UI, large dead swaths of Chau7Error/DebugContext/LogEnhanced, orphaned StatusBar types, and two parallel bug-report generators to consolidate.
- **macOS · MCP/AI/Proxy/Remote** (high:0 medium:1 low:5) — A medium correctness bug (list_snippets always empty), duplicated Unix-socket setup across 4 servers with a risky hand-rolled buffer, repetitive HTTP boilerplate, a collapsible 10-case dispatch, dead recentEvents, and a per-message formatter allocation.
- **macOS · Features & Data** (high:0 medium:1 low:5) — Per-access formatter allocation on render paths plus three already-drifted duplications (provider colors, count abbreviation, a-z key validation) and a small dead RTL modifier and double-read snapshot path.
- **iOS · Remote app** (high:1 medium:3 low:2) — Carries the only HIGH-severity bug (double output injection corrupting the grid) and has zero tests over crypto/ANSI/output logic; plus dead pairing models, an unused parameter, and duplicated approval-notification/stream-guard blocks.
- **Service · chau7-relay (TS worker)** (high:0 medium:0 low:6) — No functional defects, but non-constant-time HMAC compare, swallowed APNs failure bodies, per-notification JWT minting, duplicated DO dispatch, vestigial Env fields, and a stale routes README.
- **Service · chau7-issues (TS worker)** (high:0 medium:2 low:1) — A medium rate-limit-on-failure lockout (quota consumed before validation/GitHub call) and a complete absence of tests over its security-relevant windowing/validation logic; plus a low-value DO over-validation cleanup.
- **Service · chau7-remote (Go)** (high:0 medium:1 low:4) — A medium test gap over state.go persistence/key-wrap/migration (including a silent identity-destroying fallback), a per-reconnect goroutine leak, unused State methods, an always-empty payload field, and a mislabeled crypto comment.
- **Rust · chau7_optim + chau7_md** (high:0 medium:0 low:5) — A per-command SQLite reopen + DELETE on the hot CLI path is the main item; plus vestigial unread config sections, duplicated compact_path helpers, an unused walkdir dep, and a stale doc comment.
- **Rust · chau7_terminal + chau7_parse** (high:0 medium:0 low:8) — Dead DirtyRowTracker machinery with a latent resize-frozen-count bug, a no-op ambiguous_width FFI knob with no callers, OSC 7 parsed twice per chunk, an unused metrics field, a pub-vs-private API hazard, and an export-path allocation plus stale README.
- **Tooling · scripts/CI/build** (high:0 medium:1 low:7) — Orphaned legacy CI script and dead helpers/shims/imports, an exec wrapper silently dropping stdin/quiet options, extensionless scripts never shellchecked, and several stale doc/path references in READMEs.

---

# Appendix — All Verified Findings

## macOS · Settings

### FeatureSettings is a 4255-line god-object with parallel maintenance lists for every persisted setting
`architecture` · severity **medium** · effort **large** · confidence high

**Files:** `apps/chau7-macos/Sources/Chau7/Settings/FeatureSettings.swift`

FeatureSettings.shared declares ~137 didSet-backed UserDefaults properties and every persisted setting must be hand-mirrored across multiple places: the property+didSet, the init/reader path, the ExportableSettings Codable struct (line 3255), exportSettings() (3378), importSettings() (3496), and resetAllToDefaults() (3671) which re-lists hardcoded defaults a third time (e.g. fontFamily="SF Mono" at 3675, fontSize=11 at 3677). Confirmed: 137 didSet occurrences and the file is the single largest in the subsystem at 4255 lines. Adding one setting touches several of these lists, which drift out of sync.

**Fix:** Incrementally extract cohesive setting clusters into nested Codable value types that own their own UserDefaults key + default (the file already has a private MCPRemoteSettings struct at line 624 as precedent), so export/import/reset iterate over the value type rather than hand-mirroring each field. This collapses the multi-way duplication toward a single declaration per cluster. This is a large refactor and should be done cluster-by-cluster, not in one pass.

### KeybindingsManager recomputes a signature string on every key event
`performance` · severity **low** · effort **small** · confidence high

**Files:** `apps/chau7-macos/Sources/Chau7/Settings/KeybindingsManager.swift`, `apps/chau7-macos/Sources/Chau7/App/AppDelegate.swift`

actionForEvent(_:) (KeybindingsManager.swift:270) calls refreshBindings() unconditionally on every invocation, and AppDelegate.swift:2881 calls actionForEvent on every keyDown in an overlay window. refreshBindings (245-253) builds shortcutsSignature(for:) (255-259) by iterating all shortcuts, lowercasing keys, sorting+joining modifiers and joining the list into one string, then compares to the cached signature just to detect change. This allocates and discards a string on every key event. Confirmed against the source.

**Fix:** Invalidate the binding cache via FeatureSettings.customShortcuts.didSet (dirty flag or generation counter) instead of recomputing-and-comparing a signature string per key event; the event path then just reads precomputed activeBindings. Note this is a micro-optimization at human typing rates, so impact is small.

### ~21 KeyAction cases have unreachable executeAction branches (enum implies bindability that doesn't exist)
`dead-code` · severity **low** · effort **medium** · confidence high

**Files:** `apps/chau7-macos/Sources/Chau7/Settings/KeybindingsManager.swift`

executeAction is reached only from the customizable-keybinding path (handleEvent and AppDelegate.swift:2885), and an action can only get there if produced by KeyAction.fromShortcutAction (199-228), which only maps the action strings used by KeyboardShortcut.defaultShortcuts / the editor. The following KeyAction cases appear in neither fromShortcutAction's RHS nor defaultShortcuts, so their executeAction branches can never fire: selectTab1-9, selectAll, toggleFullscreen, interrupt, eof, suspend, clearLine, clearWord, toggleBroadcast, showClipboardHistory, showBookmarks, addBookmark, closeWindow. Verified: these real features are triggered via separate AppDelegate/menu/command-palette paths (e.g. selectTab via AppDelegate:820/2858 and the Select Tab menu), not via executeAction. (Note: the finding's claim that executeAction has 'no caller other than handleEvent' is imprecise — AppDelegate:2885 also calls it — but the unreachable-branch conclusion is correct.)

**Fix:** Either wire these actions into fromShortcutAction + defaultShortcuts so they become user-bindable, or delete the unreachable enum cases / executeAction branches so the enum reflects what is actually reachable through the keybinding path.

### KeyBinding.parse is production-dead and duplicates modifiers(from:)
`dead-code` · severity **low** · effort **small** · confidence high

**Files:** `apps/chau7-macos/Sources/Chau7/Settings/KeybindingsManager.swift`

KeyBinding.parse(_:action:) (lines 13-37) has zero production callers; grep over Sources returns no hits, and the only callers are KeybindingsManagerTests (13 call sites). The runtime binding path uses binding(from:) (261-265) which calls KeyBinding.modifiers(from:) (39-56). The modifier switch in parse (22-32) is identical to the one in modifiers(from:) (43-53), so the dead method is also duplicated logic.

**Fix:** Remove KeyBinding.parse (and its now-orphaned tests), or if a string-parse form is wanted, have it delegate to modifiers(from:) to eliminate the duplicated switch.

### searchableSettings table hand-mirrors the views with no sync test and four sections have zero search coverage
`test-gap` · severity **low** · effort **small** · confidence high

**Files:** `apps/chau7-macos/Sources/Chau7/Settings/SettingsSearch.swift`

FeatureSettings.searchableSettings is a large static metadata table that must be hand-kept in sync with the settings views, and nothing verifies coverage. SettingsSection.allCases has 24 cases (lines 66-97) but only 20 distinct sections appear in searchableSettings entries; .about, .hoverCard, .repositories, and .mcpControl have no searchable entries, so those panels are unreachable via the settings search field. No test references searchableSettings or searchSettings (grep over Tests returns nothing).

**Fix:** Add a test asserting every user-facing SettingsSection has at least one searchable entry (or is explicitly excluded), and backfill the four missing sections so search reaches every panel.

### ConfigFileWatcher only arms its watcher when the global config exists at launch and never re-arms after create/rename
`correctness` · severity **low** · effort **small** · confidence high

**Files:** `apps/chau7-macos/Sources/Chau7/Settings/ConfigFileWatcher.swift`

startWatching() guards on fileExists at line 182 and returns early if ~/.chau7/config.toml is absent. createDefaultConfig() (162-176) can create that file later but never calls stopWatching()/startWatching(), so a config file created during the session is not watched until app restart. The DispatchSource watches a single fd opened at start; on a .rename event the handler calls loadGlobalConfig/applyConfig (200-201) but does not reopen the fd, so after an editor replaces the file via rename the source points at a stale inode and subsequent edits stop flowing. This is an opt-in feature edge case (feature.configFile).

**Fix:** After createDefaultConfig() writes the global file, call stopWatching()/startWatching() to arm the source; on a .rename event, reopen the fd and restart the source so post-rename edits keep flowing.

## macOS · Tabs & Split panes

### Remove dead RunbookHost.runAll and dedupe block extraction
`dead-code` · severity **low** · effort **small** · confidence high

**Files:** `apps/chau7-macos/Sources/Chau7/SplitPanes/RunbookHost.swift`, `apps/chau7-macos/Sources/Chau7/SplitPanes/SplitPaneViews.swift`

RunbookHost declares runAll() (RunbookHost.swift:23) and RunbookHostAdapter implements it (:57-67), but nothing calls it. Repo-wide grep for runAll shows the only live caller is TextEditorPaneView.runAllMarkdownBlocks() (SplitPaneViews.swift:330/418), which re-implements the identical parseMarkdown -> compactMap codeBlock -> editor.runMarkdownBlocksSequentially loop inline. runAll() is both dead and a byte-for-byte duplicate of the live path. MarkdownRunbookView never invokes runAll.

**Fix:** Delete runAll() from the RunbookHost protocol and RunbookHostAdapter; optionally extract one shared block-extraction helper so runAllMarkdownBlocks() and any future caller reuse it. Removes ~12 dead lines plus a copy-paste.

### SplitDivider can leak a pushed NSCursor when torn down while hovered
`correctness` · severity **medium** · effort **small** · confidence medium

**Files:** `apps/chau7-macos/Sources/Chau7/SplitPanes/SplitPaneViews.swift`

SplitDivider.onHover (SplitPaneViews.swift:449-459) calls NSCursor.resizeLeftRight/resizeUpDown.push() on hover-in (:452/:454) and NSCursor.pop() only in the hover-out else branch (:457). There is no onDisappear safety pop (confirmed absent in the file). If the pane closes or the split collapses while the pointer is over the divider, SwiftUI removes the view without delivering onHover(false), so the pushed cursor is never popped and the resize cursor can persist over unrelated UI. Dividers are removed on closePane/promote, making the teardown-while-hovered window reachable.

**Fix:** Track a hovered flag and add .onDisappear { if hovered { NSCursor.pop(); hovered = false } }, or replace manual push/pop with a tracked cursor that is reset on disappear so the cursor stack stays balanced across teardown.

### OverlayTab.agentCount is dead code
`dead-code` · severity **low** · effort **small** · confidence high

**Files:** `apps/chau7-macos/Sources/Chau7/Overlay/OverlayTabsModel.swift`

OverlayTab.agentCount (computed property at OverlayTabsModel.swift:157-165, inside the OverlayTab struct that begins at line 84) walks the split tree via splitController.root.allSessions.reduce but has no callers. Repo-wide grep for .agentCount returns only AgentDashboardView.swift:73/75, which reference AgentDashboardModel.agentCount, a different type. The OverlayTab property is unreachable.

**Fix:** Delete the agentCount property from OverlayTab, or wire it into the tab UI if a multi-agent badge was intended. As-is it is dead.

### SessionFilesTracker is a pure pass-through wrapper over TurnFilesTracker
`simplify` · severity **low** · effort **small** · confidence medium

**Files:** `apps/chau7-macos/Sources/Chau7/SplitPanes/SessionFilesTracker.swift`

SessionFilesTracker (SessionFilesTracker.swift:106-145) holds a single private TurnFilesTracker and forwards every member verbatim (gitRoot get/set, touchedFiles, currentTurnID, currentTurnFiles, filesByTurn, fileTimeline, fileActions, update, reset) with no added behavior. TurnFilesTracker (same file, line 5) is referenced nowhere else in the repo. The doc comment on SessionFilesTracker ('Survives journal ring-buffer eviction') actually describes TurnFilesTracker's logic, so the split adds an indirection layer without a distinct responsibility. Callers are AgentDashboardModel and RepositoryPaneModel.

**Fix:** Collapse the two types into one (rename TurnFilesTracker to SessionFilesTracker, or point the two callers at TurnFilesTracker directly) to remove the forwarding layer. Keep both only if a second tracker type is genuinely planned.

### Three feature overlays (clipboard/bookmarks/snippets) inflate the tab-bar view file
`architecture` · severity **low** · effort **medium** · confidence high

**Files:** `apps/chau7-macos/Sources/Chau7/Overlay/Chau7OverlayView.swift`, `apps/chau7-macos/Sources/Chau7/Overlay/README.md`

Chau7OverlayView.swift is 3889 lines, but the Overlay README (README.md:24) describes its purpose as 'Tab bar SwiftUI views: segments, buttons, brackets, drag/drop, hit testing' only. MARK sections show the tail of the file is unrelated feature overlays: F16 Clipboard History (2758), F17 Bookmarks (2875), F21 Snippets (3000), plus Snippet Variable Input Dialog (3493) and Snippet Search Field (3743) — roughly the last 1000 lines. These overlay structs take an OverlayTabsModel and use shared DraggableOverlay/OverlayLayout, not the tab-bar rendering internals, so they are separable from the tab-bar code the README scopes the file to.

**Fix:** Move the three overlay views and the two snippet dialogs into their own files under Overlay/ (e.g. ClipboardHistoryOverlay.swift, BookmarksOverlay.swift, SnippetsOverlay.swift). Pure cut/paste; shrinks the tab-bar file ~25% and realigns it with its README.

## macOS · Terminal & Rendering

### Delete unused TerminalStartupQueue singleton
`dead-code` · severity **medium** · effort **small** · confidence high

**Files:** `apps/chau7-macos/Sources/Chau7/RustBackend/TerminalStartupQueue.swift`

TerminalStartupQueue is a singleton whose stated purpose is serializing shell launches at startup, but its public API (enqueue, currentTerminalReady) is referenced nowhere in Sources or Tests. Verified: grep across the whole repo returns only self-references inside TerminalStartupQueue.swift (the class definition, static.shared, and internal Log calls). The startup-serialization behavior the doc comment advertises does not actually exist anywhere in the live code.

**Fix:** Remove the file. The doc comment implies a 27-tab startup serialization behavior that is not wired into the app; if that behavior is still wanted it must be connected, otherwise this is misleading dead infrastructure.

### Remove dead parseOSC7(from:) byte-scanner
`dead-code` · severity **medium** · effort **small** · confidence high

**Files:** `apps/chau7-macos/Sources/Chau7/RustBackend/RustTerminalView+Rendering.swift`

parseOSC7(from:) (lines 863-908) manually scans raw PTY bytes for OSC 7 cwd sequences, but OSC 7 is now handled by the Rust ANSI parser via rust.getPendingCwd() at lines 80-83, which calls the shared processOSC7URL. Verified: grep for parseOSC7 across Sources and Tests matches only the definition at line 863 (no callers). The comment at line 199 explicitly states OSC 7 is now Rust-owned, closing the multi-view drain race. The dead function re-implements the same processOSC7URL dispatch and INFO log.

**Fix:** Delete parseOSC7(from:). processOSC7URL is shared by the live path and stays. Removes a stale duplicate of the now-Rust-owned OSC 7 path.

### Remove dead diagnostic/stress-test methods on RustTerminalView
`dead-code` · severity **low** · effort **small** · confidence high

**Files:** `apps/chau7-macos/Sources/Chau7/RustBackend/RustTerminalView+UI.swift`

getDebugState(), getFullBufferText(), resetPerformanceMetrics(), dumpDebugState(), stressTest(lineCount:lineLength:completion:), runDiagnostics(), and validateWideCharacterSupport() (RustTerminalView+UI.swift:644-810) have no callers. Verified: a grep for the method-call forms (.getDebugState(), .getFullBufferText(), .runDiagnostics(), .validateWideCharacterSupport(), .dumpDebugState(), .stressTest() returns zero matches across Sources and Tests. The higher raw match counts for getDebugState/getFullBufferText are the distinct FFI symbol-binding field names in RustTerminalView.swift, not calls to these wrappers. resetPerformanceMetrics() is called only by stressTest(), which is itself dead. maxLineLength (3 refs) stays. These wrap RustTerminalFFI.debugState()/fullBufferText()/resetMetrics().

**Fix:** Delete these methods. If a debug console needs them later, re-add as thin wrappers over the existing RustTerminalFFI calls they merely forward to.

### Remove dead inline-image helpers (ImgcatScript, containsImageSequence)
`dead-code` · severity **low** · effort **small** · confidence high

**Files:** `apps/chau7-macos/Sources/Chau7/Rendering/InlineImageSupport.swift`

InlineImageHandler.containsImageSequence(_:) (line 26) and the ImgcatScript enum (lines 274-369, an embedded bash script plus static script text) have no call sites. Verified: grep for containsImageSequence and ImgcatScript across Sources and Tests returns only their definitions. The live inline-image extraction path uses parseImageSequence (and extractInlineImages), not containsImageSequence. maxImageWidth/maxImageHeight (lines 18-19) are read internally at lines 145-146 but never assigned anywhere except their declaration, so they can be let-constants.

**Fix:** Delete containsImageSequence and the ImgcatScript enum. Change maxImageWidth/maxImageHeight to let (or static constants) since nothing reassigns them.

### SixelKittyBridge.configureTerminal is a no-op stub
`dead-code` · severity **low** · effort **small** · confidence high

**Files:** `apps/chau7-macos/Sources/Chau7/RustBackend/SixelKittyBridge.swift`

configureTerminal(_ terminalView: Any) (lines 26-31) takes an untyped Any, does nothing but emit one Log.info, and its body is comments describing what it 'would' set on a SwiftTerm-style terminal.options API that no longer exists. Verified: no call to SixelKittyBridge.configureTerminal anywhere; the only configureTerminal* matches are SplitPaneController's unrelated configureTerminalSession. Real image-protocol wiring is RustTerminalView reading the bridge's isSixelEnabled/isKittyGraphicsEnabled bools and calling rustTerminal.setImageProtocols (RustTerminalView.swift:3025-3027).

**Fix:** Delete configureTerminal. The bridge stays useful for its isSixelEnabled/isKittyGraphicsEnabled flags consumed at startup; this method is vestigial.

### Sixel/Kitty graphics settings have no rendering implementation
`architecture` · severity **low** · effort **large** · confidence medium

**Files:** `apps/chau7-macos/Sources/Chau7/RustBackend/RustTerminalView+Rendering.swift`, `apps/chau7-macos/Sources/Chau7/Settings/Views/GraphicsSettingsView.swift`

GraphicsSettingsView exposes user toggles 'Enable Sixel Protocol' and 'Enable Kitty Graphics' (bound to SixelKittyBridge.isSixelEnabled/isKittyGraphicsEnabled), and RustTerminalView registers those protocols with the Rust interceptor via setImageProtocols. But intercepted Sixel/Kitty images are only logged: the getPendingImages loop at RustTerminalView+Rendering.swift:184-193 builds a protocol name, logs the image size/anchor, and has two explicit TODOs ('Sixel decoding -> RGBA -> InlineImageView (Phase 4 future)', 'Kitty protocol state management (Phase 4 future)') plus 'For now, images are intercepted and logged.' Only iTerm2 images render, via the separate Swift extractInlineImages path. A user enabling the toggles sees nothing render.

**Fix:** Either implement Sixel/Kitty decode-to-NSImage (large), or hide/disable the Sixel/Kitty toggles in GraphicsSettingsView until decoding exists, so the settings UI does not advertise a non-functional feature. The toggle-hiding alternative is small effort.

### RustBackend README references nonexistent RustDimPatcher and stale file list
`doc` · severity **low** · effort **small** · confidence high

**Files:** `apps/chau7-macos/Sources/Chau7/RustBackend/README.md`

The README file table lists RustDimPatcher.swift ('Dynamic library loader that patches dim attribute rendering') and documents only 4 files, but that file does not exist and the directory contains 13 files. Verified: ls of RustBackend shows no RustDimPatcher.swift; grep for RustDimPatcher matches only README lines 10 and 17. Undocumented real files include BackgroundTerminalDrainService.swift, TerminalEventDrain.swift, TerminalStartupQueue.swift, RustFFITypes.swift, RustTerminalView+Input/Mouse/Rendering/UI/Transcript.swift. Per the repo's per-folder README accuracy convention this doc is stale.

**Fix:** Rewrite the README file table to match the 13 actual files and drop the RustDimPatcher entry.

### RustTerminalView is a ~10k-line god-object spread across one class
`architecture` · severity **low** · effort **large** · confidence medium

**Files:** `apps/chau7-macos/Sources/Chau7/RustBackend/RustTerminalView.swift`, `apps/chau7-macos/Sources/Chau7/RustBackend/RustTerminalView+Input.swift`, `apps/chau7-macos/Sources/Chau7/RustBackend/RustTerminalView+Mouse.swift`, `apps/chau7-macos/Sources/Chau7/RustBackend/RustTerminalView+UI.swift`, `apps/chau7-macos/Sources/Chau7/RustBackend/RustTerminalView+Rendering.swift`

RustTerminalView spans RustTerminalView.swift (verified 3977 lines, also containing RustGridView and the RustTerminalFFI symbol-binding struct) plus four extensions: +Mouse 997, +UI 904, +Rendering 983, +Input 678 lines (verified via wc -l). All share one class's mutable stored-property surface; the extensions reach into shared state declared in 'stored properties for extension files' MARK blocks. The class mixes FFI binding, rendering, polling policy, input encoding, mouse reporting, clipboard, history, drag&drop, and (now partly dead) diagnostics.

**Fix:** Incrementally extract cohesive collaborators that own their state: a TerminalInputEncoder for the keyCode->[UInt8] logic, a MouseReporter, and a PollingModeController; optionally move the RustTerminalFFI symbol-binding struct to its own file. Mechanical and low-behavioral-risk, but large. This is a maintainability observation, not a defect.

## macOS · Notifications

### Stale README: references nonexistent TabResolver.swift
`doc` · severity **medium** · effort **small** · confidence high

**Files:** `apps/chau7-macos/Sources/Chau7/Notifications/README.md`

README.md:12 lists `TabResolver.swift` in the Files table with a '5-tier tab resolution' description, but no such file or type exists. A repo-wide grep (excluding build artifacts) finds only doc comments referencing the concept and a `CodexSessionResolver.registerWithTabResolver()` no-op whose own comment states 'TabResolver itself was deleted.' The 5-tier resolution now lives behind NotificationDeliveryHost. The README's Event Flow (lines 16-21) also jumps from notify() to NotificationPipeline.evaluate(), omitting the now-real AIEventNotificationEngine, AISessionEventReconciler, and NotificationDeliveryPolicy stages (all confirmed to exist).

**Fix:** Delete the TabResolver.swift row (the file does not exist), retarget the resolution description at NotificationDeliveryHost / NotificationEventPreparation, and extend the Event Flow to include the engine, session reconciler, and delivery-policy steps.

### Duplicated 23-handler list between executor init and registry makeDefault
`duplication` · severity **medium** · effort **small** · confidence high

**Files:** `apps/chau7-macos/Sources/Chau7/Notifications/NotificationActionExecutor.swift`, `apps/chau7-macos/Sources/Chau7/Notifications/Handlers/NotificationActionRegistry.swift`

NotificationActionExecutor.init() hand-rolls a 23-element handler array (lines 111-135) that exactly mirrors NotificationActionRegistry.makeDefault() (lines 30-62), differing only in that the executor substitutes its shared `timeTrackingHandler` instance. makeDefault() is the version covered by the completeness assertion described in its comment (lines 26-28); the executor's copy is what actually runs in production and is NOT asserted, so a new handler added only to makeDefault would leave production missing it with no failing test. Confirmed makeDefault() is not invoked by the executor.

**Fix:** Have the executor build its registry via NotificationActionRegistry.makeDefault(...) with the shared timeTrackingHandler passed as an override, leaving one canonical list covered by the existing completeness test.

### Dead method NotificationHistory.markCanonicalized
`dead-code` · severity **low** · effort **small** · confidence high

**Files:** `apps/chau7-macos/Sources/Chau7/Notifications/NotificationHistory.swift`

markCanonicalized(eventID:semanticKind:rawType:notificationType:) at NotificationHistory.swift:92-102 has no callers anywhere in Sources/ or Tests/ (grep returns only the definition). The semanticKind/rawType/notificationType data it would set is already recorded at ingestion in begin(...) (lines 52-90).

**Fix:** Delete the method.

### Dead convenience initializer on AISessionEventReconciler
`dead-code` · severity **low** · effort **small** · confidence high

**Files:** `apps/chau7-macos/Sources/Chau7Core/Notifications/AISessionEventReconciler.swift`

The convenience init(strongerReplacementWindow:retentionSeconds:) at lines 47-56 is never called. All callsites (one production: AIEventNotificationEngine.swift:79; the rest tests) use AISessionEventReconciler() or AISessionEventReconciler(terminalRepeatWindow: 10). No callsite passes retentionSeconds:, including the iOS app and services. It is public but unused across the whole repo.

**Fix:** Remove the unused convenience initializer (lines 47-56).

### NotificationRateLimiter.buckets grows unbounded (no pruning/cap)
`performance` · severity **medium** · effort **small** · confidence high

**Files:** `apps/chau7-macos/Sources/Chau7/Notifications/NotificationRateLimiter.swift`, `apps/chau7-macos/Sources/Chau7Core/MonitoringSchedule.swift`

buckets is keyed by notificationRateLimitKey = `triggerID|notificationIdentityKey(event)` (MonitoringSchedule.swift:151-153), which embeds per-session/tab/CWD identity — and per its resolution order, falls back to the event UUID when no durable identity is available, so such events each create a never-repeating bucket. checkAndConsume inserts buckets (lines 55,62,68) but never prunes; reset() (line 73) is the only shrink path and only fires on settings change. By contrast NotificationDeliveryPolicy.pruneExpired and AISessionEventReconciler.prune both actively prune their time-windowed maps. The map is thus the one unbounded time-windowed structure in the subsystem. Note: each Bucket is tiny, so the practical memory impact is modest; the OOM-history linkage is more cautionary than demonstrated.

**Fix:** Opportunistically prune buckets whose lastRefill/lastFired exceed the refill-to-full window inside checkAndConsume, or cap the dictionary and evict oldest, mirroring pruneExpired.

### Per-handler ExecutionReport success/failure boilerplate
`simplify` · severity **low** · effort **medium** · confidence high

**Files:** `apps/chau7-macos/Sources/Chau7/Notifications/NotificationActionExecutor.swift`, `apps/chau7-macos/Sources/Chau7/Notifications/Handlers/DevOpsActionHandlers.swift`, `apps/chau7-macos/Sources/Chau7/Notifications/Handlers/IntegrationActionHandlers.swift`, `apps/chau7-macos/Sources/Chau7/Notifications/Handlers/ProductivityActionHandlers.swift`, `apps/chau7-macos/Sources/Chau7/Notifications/Handlers/AutomationActionHandlers.swift`

The three-line idiom `var report = NotificationActionExecutor.ExecutionReport(); report.recordSuccess(.x)/recordFailure("..."); return report` repeats throughout the handler files (verified ExecutionReport() construction counts: DevOps several, Integration 6, Productivity 9, Automation 8), differing only by action type or note string. Adding static factories success(_:)/failure(_:) on ExecutionReport (whose mutating recorders are already defined at NotificationActionExecutor.swift:45-57) would be behavior-preserving and shorten each return.

**Fix:** Add static factories `static func success(_ type:) -> Self` and `static func failure(_ note:) -> Self` on ExecutionReport so handlers can `return .success(.dockerBump)` / `return .failure("...")`.

### Unreachable guard in NotificationPipeline.evaluate
`dead-code` · severity **low** · effort **small** · confidence high

**Files:** `apps/chau7-macos/Sources/Chau7/Notifications/NotificationPipeline.swift`

Inside `if let trigger {` (lines 65-108), every branch returns (returns at 67, 75, 78, 84, 93, 95, 104, 107). Execution reaches line 111 only when trigger == nil, so `guard trigger == nil else { return .drop(reason: "Unexpected matched trigger state") }` can never take its else branch — the guard and its drop reason are dead.

**Fix:** Drop the redundant guard and fall through to the unmatched-trigger default handling, or restructure as `guard let trigger else { /* unmatched path */ }` at the top for a linear flow.

## macOS · Monitoring/Telemetry/Perf

### Performance/README.md lists 6 non-existent files and omits 5 real ones
`doc` · severity **low** · effort **small** · confidence high

**Files:** `apps/chau7-macos/Sources/Chau7/Performance/README.md`

The Performance folder README is out of sync with the directory, an actively misleading per-folder doc (against the MEMORY.md convention). It lists 6 files that do not exist on disk and documents 'Key Types' for deleted components, while omitting several real files.

**Fix:** Confirmed: IOSurfaceRenderer.swift, LockFreeRingBuffer.swift, LowLatencyInput.swift, PerformanceIntegration.swift, PredictiveRenderer.swift, ThreadPriority.swift are all MISSING from disk. Real files MemoryPressureCoordinator/MemoryPressureResponder/RenderPipelineProfiler/TerminalMemoryReclaimer/WakeupProfiler are undocumented. NOTE: the directory contains 12 .swift files, not 13 as the original recommendation states. Rewrite the file table to match the 12 present files and drop the deleted-component Key Types/Dependencies entries (LockFreeRingBuffer<T>, PredictiveRenderer, etc.).

### Monitoring/README.md omits 7 of its files
`doc` · severity **low** · effort **small** · confidence high

**Files:** `apps/chau7-macos/Sources/Chau7/Monitoring/README.md`

The Monitoring README file table documents only 7 of the 14 files present, leaving the per-folder doc incomplete against the stated convention.

**Fix:** Confirmed: ClaudeCodeEvent.swift, ClaudeSessionResolver.swift, CodexSessionResolver.swift, GitDiffTracker.swift, HistorySessionAdoption.swift, LogFileCompactor.swift, ProcessTreeSnapshotService.swift are all on disk but absent from README.md. Add table rows for them. Analytics/README.md similarly omits APIAnalyticsCharts.swift (verified present).

### Per-row column-map rebuild makes turn/tool-call/evidence parsing O(columns^2)
`performance` · severity **medium** · effort **small** · confidence high

**Files:** `apps/chau7-macos/Sources/Chau7/Telemetry/TelemetryStore.swift:2208`, `apps/chau7-macos/Sources/Chau7/Telemetry/TelemetryStore.swift:2234`, `apps/chau7-macos/Sources/Chau7/Telemetry/TelemetryStore.swift:2248`, `apps/chau7-macos/Sources/Chau7/Telemetry/TelemetryStore.swift:2288`, `apps/chau7-macos/Sources/Chau7/Telemetry/TelemetryStore.swift:2383`

parseRun was deliberately migrated to take a prebuilt column-index map, but parseTurn, parseToolCall, parseUsageEvidence and parseRemoteClientEvent still call the single-arg legacy colByName/intByName/doubleByName overloads, each of which rebuilds the ENTIRE column map (allocates a dictionary + iterates sqlite3_column_name) for every column access. parseUsageEvidence touches ~24 columns, rebuilding the map ~24 times per row.

**Fix:** Confirmed against code: legacy overloads at 2383-2393 delegate via columnIndexMap(stmt) per call; the comment at 2381-2382 already flags them as legacy to migrate. parseRun already has a map-taking variant used in hot paths (lines 740, 1577) including the N+1 _getTurns loop in _backfillCompletedRunLatencySamples (line 742). Have parseTurn/parseToolCall/parseUsageEvidence/parseRemoteClientEvent build the map once and pass it through, then delete the single-arg overloads.

### Dead redundant ternary in latencySamples SQL builder
`dead-code` · severity **low** · effort **small** · confidence high

**Files:** `apps/chau7-macos/Sources/Chau7/Telemetry/TelemetryStore.swift:2002`

A ternary picks between two identical strings, so it is pointless and misleading (reads as if the SQL fragment depends on whether `after` is set, but both branches are identical).

**Fix:** Confirmed at line 2002: `sql += after != nil ? " AND metric_kind = ?" : " AND metric_kind = ?"` inside `if metricKind != nil`. Replace with `sql += " AND metric_kind = ?"`. Behavior-preserving.

### Identical content->run field mapping duplicated between recorder and repair service
`duplication` · severity **low** · effort **medium** · confidence high

**Files:** `apps/chau7-macos/Sources/Chau7/Telemetry/TelemetryRecorder.swift:408`, `apps/chau7-macos/Sources/Chau7/Telemetry/TelemetryRepairService.swift:136`

The block copying sanitized content fields onto a TelemetryRun (model, six token totals, costUSD, four source/state fields, rawTranscriptRef, turnCount) is near-identical in TelemetryRecorder.extractCompletedRunContent (lines 408-421) and TelemetryRepairService.rebuildRun (lines 136-149). Both also independently build the same providers array [ClaudeCodeContentProvider(), CodexContentProvider()].

**Fix:** Confirmed: ~14 assignments are line-for-line identical; providers init duplicated at TelemetryRecorder:45-46 and TelemetryRepairService:25-26. CAVEAT: the trailing error_message handling differs (Recorder: sets 'invalidated implausible token metrics during extraction', no else-clear; RepairService: different message plus an else branch that clears it), so a shared helper must parameterize the message/clear behavior rather than copy verbatim. Extract a `mutating func applyContent(_:)` on TelemetryRun (with a message param) and a shared provider registry.

### Repeated ad-hoc provider name matching scattered across the subsystem
`duplication` · severity **low** · effort **medium** · confidence medium

**Files:** `apps/chau7-macos/Sources/Chau7/Telemetry/TelemetryRecorder.swift:516`, `apps/chau7-macos/Sources/Chau7/Telemetry/TelemetryRepairService.swift:44`, `apps/chau7-macos/Sources/Chau7/Telemetry/TelemetryRepairService.swift:176`, `apps/chau7-macos/Sources/Chau7/Telemetry/TelemetryStore.swift:714`

Provider-classification logic — lowercased contains 'claude'/'anthropic'/'codex'/'openai' (and SQL LIKE equivalents) — is reimplemented in several places with subtly different sets: shouldExtractRunContentInBackground checks only codex/openai; needsTranscriptRepair/repairRank check all four families; the backfill SQL uses LIKE on all four. Easy to drift.

**Fix:** Confirmed at all cited sites (TelemetryRecorder:516; TelemetryRepairService:44-47,176-179; TelemetryStore:714-718, plus an additional pair at TelemetryStore:1545-1546). Centralize a ProviderFamily.classify(_:) enum for the Swift call sites. CAVEAT: the SQL LIKE sites (TelemetryStore:714, 1545) run inside sqlite and cannot call the Swift helper, and the differing Recorder set (codex/openai only) may be intentional for background extraction — so unification is partial, not a single function for every site.

## macOS · App lifecycle/Runtime

### Inactivity-detection feature is dead: recordActivity is never called
`dead-code` · severity **medium** · effort **small** · confidence high

**Files:** `apps/chau7-macos/Sources/Chau7/Events/AppEventEmitter.swift`, `apps/chau7-macos/Sources/Chau7/App/AppModel.swift`

AppEventEmitter tracks inactivity via lastActivityTime (initialized at AppEventEmitter.swift:18 with `Date()`), only updated by recordActivity(). The single path to it, AppModel.recordUserActivity() (AppModel.swift:517), is never called anywhere in the repo. A whole-repo grep for recordUserActivity/recordActivity returns only the definitions and the one unused wrapper. So lastActivityTime is frozen at emitter-init time, and checkInactivity() (AppEventEmitter.swift:178-192) measures total uptime, not real inactivity — it will emit an 'inactivity_timeout' event thresholdMinutes after launch regardless of user activity, but only if config.inactivityThresholdMinutes > 0 (the timer is gated at line 64).

**Fix:** Either wire recordUserActivity() into the real activity path (terminal input / command execution), or remove the inactivity feature (setupInactivityTimer, checkInactivity, lastActivityTime, hasEmittedInactivity, recordActivity, AppModel.recordUserActivity) so it can't fire spurious notifications.

### ClaudeCodeBackend.trigger(from:) is dead code and its README is stale
`dead-code` · severity **low** · effort **small** · confidence high

**Files:** `apps/chau7-macos/Sources/Chau7/Runtime/Backends/ClaudeCodeBackend.swift`, `apps/chau7-macos/Sources/Chau7/Runtime/README.md`

The static method ClaudeCodeBackend.trigger(from: ClaudeSessionInfo.SessionState) -> Trigger? (ClaudeCodeBackend.swift:60-73) maps monitor session states to triggers, but a whole-repo grep for 'trigger(from:' returns only this definition and the README line. Nothing in the app or tests calls it. Runtime/README.md:25 still documents it as the parsing entry point ('Events from Claude Code hooks are parsed by ClaudeCodeBackend.trigger(from:)'), contradicting the actual flow which maps ClaudeCodeEvent.type values directly elsewhere.

**Fix:** Delete ClaudeCodeBackend.trigger(from:) (and the related doc-comment at the struct header) and update Runtime/README.md to describe the real event-type-based flow.

### AppConstants is mostly unused — two enums entirely dead, many members dead
`dead-code` · severity **low** · effort **small** · confidence high

**Files:** `apps/chau7-macos/Sources/Chau7/App/AppConstants.swift`

Confirmed by whole-repo grep: AppConstants.UI.* and AppConstants.Retention.* have zero references outside the definition file, so both enums are entirely dead. AppConstants.Intervals.* is used only for clipboardPoll/clipboardPollBackground (idleCheck, sessionCleanup, tailerPollMs, defaultIdleTimeout, staleSessionTimeout, partialLineThrottle, searchDebounce, animationFast/Normal/Slow all dead). AppConstants.Limits.* is used only for maxLogLines, maxHistoryEntries, maxTerminalLines, terminalPrefillLines, maxFontCacheSize, maxClosedSessions (maxClipboardItems, maxBookmarksPerTab, maxTailerBufferSize, defaultScrollbackLines, maxSearchMatches, maxSearchPreviewLines all dead). Only Network.defaultProxyPort is used in Network. The file's 'all magic numbers in one place' banner is misleading drift.

**Fix:** Prune the dead UI and Retention enums entirely plus the dead Limits/Intervals members, or finish migrating the scattered literals to reference AppConstants. Don't leave it half-adopted.

### Duplicated mach resident-memory reader in three files
`duplication` · severity **low** · effort **small** · confidence high

**Files:** `apps/chau7-macos/Sources/Chau7/App/AppDelegate.swift`, `apps/chau7-macos/Sources/Chau7/Events/AppEventEmitter.swift`, `apps/chau7-macos/Sources/Chau7/Logging/LogEnhanced.swift`

The mach_task_basic_info / MACH_TASK_BASIC_INFO resident_size-to-MB withUnsafeMutablePointer/withMemoryRebound/task_info boilerplate is copy-pasted in AppDelegate.currentResidentMB() (line 2954, returns Int?), AppEventEmitter.getCurrentMemoryUsageMB() (line 244, returns Int), and LogEnhanced.currentMemoryMB() (line 215, returns Double?). Three near-identical copies differing only in return type and failure sentinel.

**Fix:** Extract a single helper (e.g. ProcessMemory.residentBytes() -> UInt64? in Chau7Core or an Infrastructure file) and have all three call sites derive their MB value from it.

### Leak-investigation RSS instrumentation left in moveTab hot path
`performance` · severity **low** · effort **small** · confidence high

**Files:** `apps/chau7-macos/Sources/Chau7/App/AppDelegate.swift`

logRSSSample has 15 call sites in AppDelegate. moveTab schedules 6 extra delayed RSS samples via `for delay in [0.1, 1.0, 5.0, 15.0, 30.0, 50.0]` (line 1627) plus ~6 synchronous samples per tab drag. The helper's own doc (lines 2966-2968) states it is 'always logged (not gated by a diagnostic env var) because this is used for an active leak investigation — remove once the cross-window-drag leak is root-caused.' Each call does a mach syscall + unconditional INFO log, and the delayed timers keep work scheduled 50s after every drag.

**Fix:** If the cross-window-drag leak is resolved, delete the moveTab delayed-sample loop and the scattered logRSSSample calls. If still needed, gate it behind an EnvVars diagnostic flag (like the inputDiagnostics pattern at AppDelegate.swift:2846) instead of unconditional INFO logging.

### Adoption-cache fields bypass the NSLock the class claims to use
`correctness` · severity **low** · effort **small** · confidence high

**Files:** `apps/chau7-macos/Sources/Chau7/Runtime/RuntimeSessionManager.swift`

The class header (line 7) documents 'Thread-safe via NSLock', and ~25 methods guard their maps with `lock`. But recentlyFailedAdoptions and chronicOrphanTracking are read/mutated WITHOUT the lock in resetAdoptionCache() (line 636), shouldSkipAdoptionByCooldown (641), recordAdoptionFailure (646), and decideChronicOrphanLog (683). resetForTesting (1202) clears these same two maps UNDER the lock — directly contradicting resetAdoptionCache. Currently safe because these are reached only from main-thread handleClaudeEvent (plus tests), but resetAdoptionCache is internal API and a future off-main caller would race; the inconsistency undermines the documented invariant.

**Fix:** Guard recentlyFailedAdoptions and chronicOrphanTracking with the same `lock` as the other state (or document explicitly that these two are main-actor-confined and not lock-protected). At minimum make resetAdoptionCache consistent with resetForTesting.

### AppDelegate is a 2974-line god object mixing many unrelated responsibilities
`architecture` · severity **medium** · effort **large** · confidence high

**Files:** `apps/chau7-macos/Sources/Chau7/App/AppDelegate.swift`

AppDelegate (2974 lines, confirmed) owns app lifecycle, App Nap / latency-scope policy (lines ~671-760), multi-window create/show/hide/clamp, NSWindowDelegate callbacks, startup-restore orchestration and deferred-restore scheduling, multi-window autosave + termination snapshot reuse, tab/group move-between-windows (moveTab line 1556, moveGroup 1634), URL-scheme handling, telemetry repair scheduling, key-event monitoring + menu-shortcut matching, and ~60 menu-action forwarders that are one-line `ensureActiveOverlayModel()?.x()` calls. This concentration makes the genuinely subtle focus/render-lifecycle and startup-restore logic hard to isolate and test.

**Fix:** Extract cohesive collaborators incrementally (AppNapController, WindowRestorePersistence, TabWindowMover, KeyEventRouter), keeping AppDelegate a thin coordinator. Start with the autosave/persist and tab-move clusters, which have the least coupling to NSWindowDelegate.

### TerminalMigrationWizard importProfile/importProfiles duplicate the save-apply-restore dance
`duplication` · severity **low** · effort **small** · confidence high

**Files:** `apps/chau7-macos/Sources/Chau7/Migration/TerminalMigrationWizard.swift`

importProfile (lines 144-168) and importProfiles (170-198) each capture originalFont/Size/Cursor from FeatureSettings.shared, conditionally apply the profile's fontFamily/fontSize/cursorStyle, call createProfile(name: 'Imported: ...'), then restore the originals. The single-profile body is effectively one iteration of the batch loop, duplicated. (Minor note: the batch saves originals once and restores per-iteration, so a shared private applyAndCreate(profile:) helper is the cleaner factoring rather than importProfile literally calling importProfiles.)

**Fix:** Factor a private applyAndCreate(profile:) helper that both methods share, capturing/restoring originals once around it.

### Agent backend launchCommand/formatPromptInput share copy-pasted tails
`duplication` · severity **low** · effort **small** · confidence high

**Files:** `apps/chau7-macos/Sources/Chau7/Runtime/Backends/ClaudeCodeBackend.swift`, `apps/chau7-macos/Sources/Chau7/Runtime/Backends/CodexBackend.swift`, `apps/chau7-macos/Sources/Chau7/Runtime/Backends/GenericShellBackend.swift`

All three backends build a command then prepend an env prefix via the identical `if !envPrefix.isEmpty { return envPrefix + " " + command }` tail (ClaudeCodeBackend.swift:34-38, CodexBackend.swift:29-33, GenericShellBackend.swift:16-19, the last with an extra !cmd.isEmpty guard). ClaudeCodeBackend.formatPromptInput (41-47) and CodexBackend.formatPromptInput (36-42) are byte-for-byte identical (context+prompt or prompt+newline).

**Fix:** Add a small shared helper (free function or AgentBackend protocol extension) for prepending the env prefix, and a default formatPromptInput(prompt:context:) on the protocol that Claude/Codex inherit, leaving GenericShellBackend to override the raw-passthrough variant.

## macOS · Utilities/Logging/UI-infra

### Delete entirely-dead AccessibilityUtilities.swift
`dead-code` · severity **medium** · effort **small** · confidence high

**Files:** `apps/chau7-macos/Sources/Chau7/Utilities/AccessibilityUtilities.swift`

Confirmed: the 323-line file has zero external references. A grep for all 17 public symbols (scaledFont, scaledCustomFont, ScaledFontModifier, HighContrastModifier, highContrastForeground, ReduceMotionModifier, accessibleAnimation, accessibleControl, accessibleGroup, accessibleListItem, AccessibleColors, AccessibilityFocusHelper, MinimumTouchTargetModifier, minimumTouchTarget, KeyboardFocusRingModifier, keyboardFocusRing, AccessibilityAnnouncement) across apps/ returns 0 hits outside the file itself. Verified scaledFont (lines 19-27) returns Font.system(size:weight:design:).leading(.standard) with no Dynamic-Type scaling, so it is a no-op even if called.

**Fix:** Delete the file. Reintroduce only the specific modifiers if/when they are actually wired into views.

### Remove unused DangerousCommandConfirmationView SwiftUI sheet
`dead-code` · severity **medium** · effort **small** · confidence high

**Files:** `apps/chau7-macos/Sources/Chau7/Commands/DangerousCommandConfirmationView.swift`

Confirmed: the 200-line file's symbol DangerousCommandConfirmationView has 0 references anywhere outside its own definition (Sources and Tests). The live confirmation UI is the NSAlert built in DangerousCommandGuard.showConfirmation (DangerousCommandGuard.swift:265) + makeCommandAccessoryView (line 373).

**Fix:** Delete DangerousCommandConfirmationView.swift. (Do not keep both UIs; if a SwiftUI sheet is ever preferred, replace the NSAlert path rather than maintaining two.)

### MinimalMode is a fully inert feature with a live settings UI
`dead-code` · severity **medium** · effort **medium** · confidence high

**Files:** `apps/chau7-macos/Sources/Chau7/Appearance/MinimalMode.swift`, `apps/chau7-macos/Sources/Chau7/Settings/Views/MinimalModeSettingsView.swift`

Confirmed: isEnabled/hideTabBar/hideTitleBar/hideStatusBar/hideSidebar are read only inside MinimalModeSettingsView.swift (and tests). .minimalModeChanged is posted in MinimalMode.swift:19 and observed only in MinimalModeTests; no production addObserver consumes it. No production code hides any chrome based on these flags. The class header comment (MinimalMode.swift:3-9) claims a Cmd+Shift+M shortcut and menu item, but grep of Keyboard/Commands/AppDelegate/menu code finds no such wiring.

**Fix:** Either wire MinimalMode into window/tab-bar layout (consume flags + observe the notification) or remove the class, its settings view, and the misleading header comment. At minimum fix the header comment claiming an unimplemented Cmd+Shift+M shortcut and menu item.

### Chau7Error is heavily over-engineered: most cases plus recoverySuggestion/InputValidation/RateLimiter/logged() are dead
`simplify` · severity **medium** · effort **medium** · confidence high

**Files:** `apps/chau7-macos/Sources/Chau7/Utilities/Chau7Error.swift`

Confirmed with one correction: the Chau7Error enum declares 26 cases (lines 7-49), not 30 as the finding states. Of those, only fileWriteFailed and configurationEncodeFailed are constructed outside the definition (fileWriteFailed=2, configurationEncodeFailed=1 external hits; all SSH/clipboard/security/validation cases = 0). recoverySuggestion (lines 114+) has 0 external reads. The InputValidation enum (line 424) and RateLimiter class (line 358) in the same file have 0 external uses. logged() (line 177) has 0 external call sites. Note: the FileOperations (38 uses) and JSONOperations (51 uses) enums in this same file ARE live and must be kept; the finding correctly scopes deletion to the cases/recoverySuggestion/InputValidation/RateLimiter/logged.

**Fix:** Trim Chau7Error to the ~2 cases actually thrown plus any near-term planned ones, drop recoverySuggestion, and delete the unused InputValidation enum, RateLimiter class, and logged() helper. Keep FileOperations and JSONOperations.

### DebugContext correlation system and DebugAssert are dead
`dead-code` · severity **medium** · effort **small** · confidence high

**Files:** `apps/chau7-macos/Sources/Chau7/Logging/DebugContext.swift`

Confirmed: DebugContext is never instantiated externally (DebugContext( = 0 hits outside the file) and DebugContext.active/.history/.find = 0 external hits. DebugAssert = 0 references anywhere. StateSnapshot.capture references DebugContext.active internally (line 276), so activeContexts always feeds an empty list. StateSnapshot (the only definition, at line 139) and BugReporter are live and used widely (StateSnapshot has many external consumers), so the file must stay — only the DebugContext class, DebugAssert enum, and the activeContexts field/section should be removed.

**Fix:** Delete the DebugContext class and DebugAssert enum; drop the activeContexts field from StateSnapshot/ContextState and the empty bug-report section it feeds. Keep StateSnapshot and BugReporter.

### Two parallel bug-report generators duplicate markdown + save logic
`duplication` · severity **medium** · effort **medium** · confidence high

**Files:** `apps/chau7-macos/Sources/Chau7/Logging/DebugContext.swift`, `apps/chau7-macos/Sources/Chau7/Logging/BugReportDraft.swift`

Confirmed: BugReporter.generateReport (DebugContext.swift:367) and BugReportDraft.saveLocally (BugReportDraft.swift:283) both build a '# Chau7 Bug Report' markdown document and both write a 'chau7-bug-report-<date>.md' file into RuntimeIsolation.chau7Directory()/reports with their own DateFormatter. Both paths are reachable: DebugConsoleView.swift:2521-2535 drives BugReporter.shared (prefilledIssueURL/generateReport/openReportsFolder), while BugReportWindowController/BugReportDraft is the newer privacy-aware path. Genuine duplication.

**Fix:** Consolidate on BugReportDraft as the single report builder/saver and have DebugConsoleView's report buttons drive it (or open BugReportWindowController). Remove BugReporter's markdown/save duplication, keeping at most prefilledIssueURL if the GitHub-issue fallback is still wanted.

### Orphaned MenuBarPanelView/StreamView (+ StreamSelection) in StatusBar
`dead-code` · severity **medium** · effort **small** · confidence high

**Files:** `apps/chau7-macos/Sources/Chau7/StatusBar/MainPanelView.swift`, `apps/chau7-macos/Tests/Chau7Tests/StatusBar/StatusBarControllerTests.swift`

Confirmed: MenuBarPanelView (MainPanelView.swift:56) is only declared, never instantiated. StreamView (line 239) is referenced only at MainPanelView.swift:190 inside MenuBarPanelView. StreamSelection (line 20) is used only within MainPanelView.swift and StatusBarControllerTests.swift, so the StatusBarControllerTests StreamSelection tests exercise dead production code. The live menu-bar panel is StatusBarPanelView (StatusBarController.swift:55/836), a different type. MainPanelView.swift also contains other LIVE types (SettingsWindowView, SettingsRootView, etc.), so deletion must be scoped to the three dead types, not the whole file.

**Fix:** Delete MenuBarPanelView, StreamView, and StreamSelection plus their StreamSelection tests (leave the rest of MainPanelView.swift intact), unless the stream/log panel is intended to return.

### Dead LogEnhanced sub-systems: LogCorrelation, PerfTracker public API, structured/category config, captureStateSnapshot
`dead-code` · severity **low** · effort **medium** · confidence high

**Files:** `apps/chau7-macos/Sources/Chau7/Logging/LogEnhanced.swift`

Confirmed: LogCorrelation.shared/.scoped = 0 external hits, PerfTracker( and PerfTracker.measure = 0 external hits (PerfTracker.measure is only invoked from captureStateSnapshot at LogEnhanced.swift:411), captureStateSnapshot/setEnabledCategories/enableStructuredOutput = 0 external hits, none referenced in Tests. isStructuredOutput is set true only via the uncalled enableStructuredOutput (line 245), so the JSON branch at line 362 is unreachable. The live LogEnhanced.info/warn/error/trace/tab/render/recovery API has ~22 external call sites and must be kept.

**Fix:** Remove LogCorrelation, the PerfTracker public entry points (or PerfTracker entirely), captureStateSnapshot, setEnabledCategories/enableStructuredOutput, and the dead JSON-output branch; keep the live logging methods and category filtering.

### Dead Formatters entries and other small unused helpers
`dead-code` · severity **low** · effort **small** · confidence high

**Files:** `apps/chau7-macos/Sources/Chau7/Utilities/Formatters.swift`, `apps/chau7-macos/Sources/Chau7/Utilities/KeychainHelper.swift`, `apps/chau7-macos/Sources/Chau7/Appearance/TerminalColorScheme.swift`

Confirmed: Formatters.terminalLogin (Formatters.swift:9), Formatters.logTimestamp (line 17), and Formatters.debugTime (line 27) all have 0 external call sites, while Formatters.iso8601 has 32 uses. KeychainHelper.exists (KeychainHelper.swift:78) = 0 external hits. TerminalColorScheme.clearColorCache (TerminalColorScheme.swift:153) = 0 external hits.

**Fix:** Drop the three unused DateFormatter statics from Formatters, KeychainHelper.exists, and TerminalColorScheme.clearColorCache.

## macOS · MCP/AI/Proxy/Remote

### Deduplicate Unix-domain socket setup across four servers
`duplication` · severity **low** · effort **medium** · confidence high

**Files:** `apps/chau7-macos/Sources/Chau7/MCP/MCPServerManager.swift`, `apps/chau7-macos/Sources/Chau7/Proxy/ProxyIPCServer.swift`, `apps/chau7-macos/Sources/Chau7/Remote/RemoteIPCServer.swift`, `apps/chau7-macos/Sources/Chau7/Scripting/ScriptingAPI.swift`

The sockaddr_un construction (sun_family + copy of path into the fixed-size sun_path buffer + withMemoryRebound bind/connect) is repeated in MCPServerManager (twice: _start lines 377-393 and canConnectToSocket lines 577-593), ProxyIPCServer (start lines 113-129), RemoteIPCServer (start lines 52-66), and ScriptingAPI (makeUnixSockaddr lines 593-602). MCPServerManager uses a hand-rolled 104-byte pathBytes buffer variant with strncpy(...,103) rather than MemoryLayout.size(ofValue: addr.sun_path)-1 like the others. ScriptingAPI already factored this into makeUnixSockaddr and also has prepareSocketPathForBinding / canConnectToSocket / shouldRetryStart that MCPServerManager duplicates near-verbatim (MCPServerManager lines 556-603 vs ScriptingAPI lines 561-611).

**Fix:** Promote a shared helper (e.g. in Chau7Core alongside LocalSocketServerHealth) for makeUnixSockaddr(path:), canConnectToSocket(at:), prepareSocketPathForBinding, and shouldRetryStart, and have all four servers call it. The shared helper removes the hand-rolled 104-byte buffer in MCPServerManager and collapses the duplicated retry/connect logic.

### handleListSnippets always returns an empty list despite SnippetManager being populated
`correctness` · severity **medium** · effort **small** · confidence high

**Files:** `apps/chau7-macos/Sources/Chau7/Scripting/ScriptingAPI.swift`

list_snippets is advertised in publicSupportedMethods (line 30) and dispatched (line 290), but handleListSnippets() (lines 523-525) unconditionally returns ["result": [] as [[String: Any]]]. The sibling handleRunSnippet() (lines 527-536) reads SnippetManager.shared.entries and matches by entry.snippet.title, proving the data is available. A client can run a snippet by name but can never discover snippet names via the API.

**Fix:** Populate the result from SnippetManager.shared.entries, mapping each entry to at least its title (and optionally body/placeholders) so list_snippets and run_snippet are consistent.

### Dead recentEvents computed property, setter, and clearEvents on ProxyIPCServer
`dead-code` · severity **low** · effort **small** · confidence high

**Files:** `apps/chau7-macos/Sources/Chau7/Proxy/ProxyIPCServer.swift`

ProxyIPCServer exposes a recentEvents computed property (lines 22-25) whose getter reverses the whole eventsBuffer (O(n)) and whose setter re-reverses on assignment, plus clearEvents() (line 190). A repo-wide source search (apps/chau7-macos/Sources, apps/chau7-ios, services) finds no reader of ProxyIPCServer.shared.recentEvents and no caller of its setter or clearEvents. The other recentEvents matches all belong to unrelated types (AppModel, ClaudeCodeMonitor, FeatureProfiler, etc.). The eventsBuffer feeds consumers exclusively via the .apiCallRecorded NotificationCenter post; internal trimming uses eventsBuffer directly.

**Fix:** Remove the recentEvents computed property + setter and clearEvents(), keeping eventsBuffer private; or, if a future UI needs them, expose a cheap snapshot accessor instead of the O(n) reversing getter.

### Collapse 10 identical tab_* dispatch cases in MCPSession.callTool
`simplify` · severity **low** · effort **small** · confidence high

**Files:** `apps/chau7-macos/Sources/Chau7/MCP/MCPSession.swift`

In callTool (switch name at line 710), ten control-plane tools (tab_list, tab_create, tab_exec, tab_status, tab_wait_ready, tab_send_input, tab_press_key, tab_submit_prompt, tab_close, tab_output) each have a dedicated case (lines 780-808) whose body is identical except the string literal: return classifyToolResponse(controlPlane.call(name: "<name>", arguments: arguments)). The literal tool name always equals the case label, and controlPlane.call(name:arguments:) simply forwards the name string, so passing name through is behavior-preserving.

**Fix:** Replace with a single grouped case listing the ten control-plane tool names and pass name through: case "tab_list", "tab_create", ...: return classifyToolResponse(controlPlane.call(name: name, arguments: arguments)). tab_set_cto/tab_rename stay separate because they route to controlService with explicit arg validation.

### Repetitive HTTP request/decode boilerplate across ProxyManager endpoints
`duplication` · severity **low** · effort **medium** · confidence high

**Files:** `apps/chau7-macos/Sources/Chau7/Proxy/ProxyManager.swift`

getStats (447-479), getTaskCandidate (484-543), getCurrentTask (546-625), startTask (628-700), dismissCandidate (703-748), and assessTask (751-799) all repeat the same shape: guard isRunning, build apiURL (log on nil), URLSession.shared.data, guard httpResponse.statusCode == 200, decode, and a warning log in catch. The GET vs POST variants only differ in body encoding and the decoded type.

**Fix:** Add two small private generics, e.g. requestJSON<T: Decodable>(path:queryItems:) for GET and postJSON<Req: Encodable, Res: Decodable>(path:body:) for POST, handling the isRunning guard, URL construction, status check, and error logging once. Each public method then becomes a few lines of mapping.

### ISO8601DateFormatter allocated per API-call message
`performance` · severity **low** · effort **small** · confidence high

**Files:** `apps/chau7-macos/Sources/Chau7/Proxy/ProxyIPCServer.swift`

handleAPICallMessage constructs a fresh ISO8601DateFormatter() on every inbound api_call event (line 318) to parse data.timestamp. ISO8601DateFormatter init is comparatively expensive and this runs on the IPC read path for every proxied LLM request. TelemetryQueryService already caches a single reusable formatter as a stored property for the same reason.

**Fix:** Hoist a single private static let timestampFormatter = ISO8601DateFormatter() (or an instance stored property) and reuse it in handleAPICallMessage.

## macOS · Features & Data

### Cache LocalizedFormatters instances instead of rebuilding per access
`performance` · severity **medium** · effort **medium** · confidence high

**Files:** `apps/chau7-macos/Sources/Chau7/Localization/Localization.swift`, `apps/chau7-macos/Sources/Chau7/Terminal/Views/TerminalLineView.swift`

Every static property on LocalizedFormatters (shortDate, shortTime, decimal, percent, currency, integer, relative, etc.) is a computed `var` that allocates and configures a brand-new DateFormatter/NumberFormatter on every access (Localization.swift:249-352). DateFormatter/NumberFormatter creation is one of the more expensive Foundation operations. These are read on render paths: TerminalLineView.swift:79 calls LocalizedFormatters.shortTime.string(from:) on every terminal line render where showTimestamp is true, and dashboard/explorer cells call these per row.

**Fix:** Memoize the formatters keyed by the current language. Cache a single instance per formatter type and invalidate on the language-change notification that LocalizationManager already posts. Access is on the main thread, so a simple lazy cache reset on language change is sufficient. Note: only shortTime is confirmed on a true hot path; downgraded severity from high to medium accordingly.

### Extract duplicated token-count abbreviation helper
`duplication` · severity **low** · effort **small** · confidence high

**Files:** `apps/chau7-macos/Sources/Chau7/Dashboard/AgentDashboardModel.swift`, `apps/chau7-macos/Sources/Chau7/Dashboard/AgentDashboardView.swift`, `apps/chau7-macos/Sources/Chau7/DataExplorer/RunsExplorerView.swift`, `apps/chau7-macos/Sources/Chau7/DataExplorer/SessionsExplorerView.swift`, `apps/chau7-macos/Sources/Chau7/Analytics/APIAnalyticsCharts.swift`

The 'abbreviate a count as 1.2M / 1.2k' logic is copy-pasted across many sites and the implementations disagree. AgentDashboardModel.swift:632 uses `count > 1_000_000 ... "%.1fk"` (lowercase k, strict >), RunsExplorerView.swift:172 uses `count >= 1_000_000 ... "%.0fK"` (uppercase K, >=, zero fraction digits), SessionsExplorerView.swift:157 and AgentDashboardView.swift:533 and APIAnalyticsCharts.swift:271 each have their own variant. The threshold operator and suffix casing differ, so the same count renders inconsistently across screens.

**Fix:** Add a single shared compact-count formatter (e.g. LocalizedFormatters.formatCompactCount or an Int extension) and replace the inline copies, picking one threshold/casing convention.

### Remove unused flipForRTL view modifier
`dead-code` · severity **low** · effort **small** · confidence high

**Files:** `apps/chau7-macos/Sources/Chau7/Localization/Localization.swift`

The `View.flipForRTL()` extension (scaleEffect horizontal flip for RTL) at Localization.swift:236-238 has no callers. A whole-tree grep for `flipForRTL` across Sources and Tests returns only the declaration.

**Fix:** Delete the flipForRTL() modifier, or wire it where RTL mirroring is actually needed.

### Provider-to-color mapping duplicated across explorer/analytics/dashboard views
`duplication` · severity **low** · effort **small** · confidence high

**Files:** `apps/chau7-macos/Sources/Chau7/DataExplorer/RunsExplorerView.swift`, `apps/chau7-macos/Sources/Chau7/DataExplorer/SessionsExplorerView.swift`, `apps/chau7-macos/Sources/Chau7/Analytics/APIAnalyticsCharts.swift`, `apps/chau7-macos/Sources/Chau7/Dashboard/AgentDashboardView.swift`

The switch mapping provider name -> SwiftUI Color is reimplemented separately: RunsExplorerView.swift:161-169 providerColor (claude=.purple), SessionsExplorerView.swift:146 providerColor (claude=.purple), APIAnalyticsCharts.swift:364 free function providerColor, and AgentDashboardView.swift:511 backendColor (claude=.orange). The dashboard variant already disagrees on claude's color (orange vs purple), demonstrating the drift the finding warns about.

**Fix:** Centralize one static color(forProvider:) helper (next to UsageMonitor's provider display-name centralization) and call it from all sites, resolving the existing orange/purple inconsistency.

### appendSnapshotIfNeeded re-reads the entire JSONL file on first write per provider
`performance` · severity **low** · effort **small** · confidence high

**Files:** `apps/chau7-macos/Sources/Chau7/Usage/UsageMonitor.swift`

appendSnapshotIfNeeded (UsageMonitor.swift:624) seeds its per-provider cache via loadSnapshots(from: Self.snapshotsFilePath) at line 629, which reads and parses the whole provider-quotas.jsonl file with parseSnapshotLine per line. This runs the first time each provider is seen per launch (invoked from captureLatestClaudeSnapshot/captureLatestCodexSnapshot at lines 161/164). refreshNow's same DispatchQueue.global block then loads the full snapshot file again at line 167, so the file is parsed twice on the first capture cycle.

**Fix:** Seed lastSnapshotByProvider from the snapshots already loaded in refreshNow (pass the latest-per-provider dict into the capture helpers) rather than re-reading inside appendSnapshotIfNeeded. Low-impact: the file is small and this only doubles on the first cycle per provider.

### validatedKey and normalizeKey duplicate the a-z validation predicate
`duplication` · severity **low** · effort **small** · confidence medium

**Files:** `apps/chau7-macos/Sources/Chau7/Snippets/SnippetManager.swift`

Snippet.validatedKey (SnippetManager.swift:131-138) and SnippetManager.normalizeKey (757-763) both trim/lowercase a key and validate `char >= "a", char <= "z"`, duplicating the predicate. Important caveat: they are NOT semantically identical — validatedKey requires `normalized.count == 1` (rejects multi-char input), while normalizeKey takes `.first` of any-length input (so "ab" yields "a"). The recommendation to have normalizeKey delegate to validatedKey would therefore change behavior and must be done carefully (extract only the per-character a-z predicate, not the whole normalization).

**Fix:** Extract a single static a-z character validator and have both call it, without collapsing the differing length semantics. Minor; only worth doing to keep the predicate from diverging.

## iOS · Remote app

### Duplicate output injection when building a tab's terminal playback
`correctness` · severity **high** · effort **small** · confidence high

**Files:** `apps/chau7-ios/Chau7RemoteApp/RemoteTerminalRendererStore.swift`

In RemoteTerminalRendererStore.appendOutput, when no playback yet exists for a tab, each incoming chunk is unconditionally appended to replayByTabID via appendReplayChunk(chunk, to:) (line 88) AND also appended to pendingReplayByTabID (line 98). The playbacks[tabID] != nil early-return at lines 90-96 guarantees pendingReplayByTabID only ever accumulates pre-playback chunks. Later, ensurePlayback builds the RemoteRustTerminalPlayback and injects initialReplay = replayByTabID[tabID] (line 136) and then iterates pendingChunks injecting the same bytes again (lines 138-140). Any output received before the playback is instantiated is therefore fed into the Rust terminal twice, corrupting the grid render (duplicated lines, wrong cursor) for the experimental renderer. Confirmed: pre-playback chunks land in both buffers and both are injected; there is no dedup between them.

**Fix:** Use a single source of truth for pre-playback bytes. Either rebuild new playbacks solely from replayByTabID and drop the pendingReplayByTabID injection, or skip appendReplayChunk for chunks queued into pendingReplayByTabID. Add a regression test that injects output before the viewport/playback is established.

### Dead multi-device pairing models (StoredPairingsState / StoredPairingDevice)
`dead-code` · severity **medium** · effort **small** · confidence high

**Files:** `apps/chau7-ios/Chau7RemoteApp/RemoteModels.swift`

StoredPairingsState and StoredPairingDevice (nickname, lastKnownMacName, storedMacPublicKey, trustedIdentity, lastUsedAt, displayName, static .empty) model multi-device pairing the app never uses. A repo-wide grep across all Swift sources shows StoredPairingsState, StoredPairingDevice, and selectedDeviceID appear only inside their own definitions in RemoteModels.swift; .nickname/.displayName/.devices have no external references. The real client persists a single PairingInfo and TrustedPairingIdentity directly.

**Fix:** Delete StoredPairingsState and StoredPairingDevice (and their computed helpers) until multi-device support is actually built (~31 lines removed at RemoteModels.swift:42-72).

### Unused fallbackText parameter on RemoteTerminalRendererStore.setActiveTab
`dead-code` · severity **low** · effort **small** · confidence high

**Files:** `apps/chau7-ios/Chau7RemoteApp/RemoteTerminalRendererStore.swift`, `apps/chau7-ios/Chau7RemoteApp/RemoteClient.swift`, `apps/chau7-ios/Chau7RemoteApp/RemoteTerminalRendererView.swift`

setActiveTab(_:fallbackText:) (RemoteTerminalRendererStore.swift:67) never reads fallbackText — the body only sets activeTabID, calls ensurePlayback and refreshActiveState (lines 68-70). grep confirms fallbackText appears only at the signature plus three call sites that all pass outputText: RemoteClient.swift:301, RemoteClient.swift:686, and RemoteTerminalRendererView.swift:32. The parameter implies a fallback-render behavior that does not exist.

**Fix:** Remove the fallbackText parameter and drop it from the three call sites, or implement the intended fallback if one was meant.

### Duplicated approval local-notification scheduling block
`duplication` · severity **medium** · effort **small** · confidence high

**Files:** `apps/chau7-ios/Chau7RemoteApp/RemoteClient.swift`

The UNMutableNotificationContent setup for a new approval (title from flaggedCommand != command, body via approvalNotificationBody, sound .default, interruptionLevel .timeSensitive, relevanceScore 1, categoryIdentifier MCP_APPROVAL, userInfo request_id/open_approvals, 0.1s trigger) is duplicated verbatim in applyPendingApprovals (lines 1412-1429) and upsertPendingApproval (lines 1446-1463). Confirmed near-identical; any change (category id, interruption level) must be made in two places and can silently drift.

**Fix:** Extract a single private helper, e.g. scheduleApprovalNotification(for payload: ApprovalRequestPayload), and call it from both sites.

### No tests for any iOS Remote logic (crypto framing, ANSI stripping, output store)
`test-gap` · severity **medium** · effort **medium** · confidence high

**Files:** `apps/chau7-ios/Chau7RemoteApp/RemoteCrypto.swift`, `apps/chau7-ios/Chau7RemoteApp/RemoteModels.swift`, `apps/chau7-ios/Chau7RemoteApp/RemoteTerminalOutputStore.swift`, `apps/chau7-ios/Chau7RemoteApp/RemoteReconnectBackoff.swift`

find apps/chau7-ios -iname '*test*' returns nothing — the iOS app has zero test files/targets. Several pieces are pure, deterministic, and security/correctness-critical: RemoteCryptoSession (ChaChaPoly seal/open at RemoteCrypto.swift:48/74, makeNonce hand-builds a 12-byte nonce at lines 78-85, AAD header binding), ANSIStripper.strip (hand-rolled CSI scalar scanner at RemoteModels.swift:356-383), RemoteTerminalOutputStore (flush/snapshot/trim), and RemoteReconnectBackoff. A regression in framing or ANSI parsing would break the product silently.

**Fix:** Add a lightweight XCTest target covering encrypt/decrypt round-trips and header-tamper rejection, ANSIStripper on representative CSI/non-CSI sequences, and RemoteTerminalOutputStore append/flush/snapshot/trim. These are platform-independent and fast.

### appendOutput / storeSnapshot stream-mode guard duplicated across handlers
`duplication` · severity **low** · effort **small** · confidence high

**Files:** `apps/chau7-ios/Chau7RemoteApp/RemoteClient.swift`

The guard `guard currentAppState == .foreground, desiredStreamMode == .full else { return }` is repeated identically at appendOutput (line 720), storeSnapshot (line 751), storeGridSnapshot (line 761), and the same condition guards flushPendingOutput (line 1569, with extra task-cleanup in its else). The single concept 'only ingest terminal frames in foreground full mode' is scattered across four sites; a policy change requires editing all four.

**Fix:** Introduce a computed `private var isStreamingTerminalOutput: Bool { currentAppState == .foreground && desiredStreamMode == .full }` and use it at each guard. (flushPendingOutput keeps its extra else-branch cleanup; only the condition is shared.)

## Service · chau7-relay (TS worker)

### Cache APNs provider JWT instead of minting per notification
`performance` · severity **low** · effort **small** · confidence high

**Files:** `services/chau7-relay/src/session.ts:232-254`, `services/chau7-relay/src/session.ts:298-366`

handlePushNotify fans out over all registrations with Promise.all (session.ts:242), and sendAPNSNotification (session.ts:311) unconditionally calls createAPNSToken for every registration on every notify. createAPNSToken does crypto.subtle.importKey + crypto.subtle.sign (ECDSA P-256) each invocation (session.ts:353-364) with no caching. All registrations in a single DO share the same APNS_TEAM_ID/APNS_KEY_ID/APNS_PRIVATE_KEY from this.env, so the JWT is identical across the fan-out. APNs provider tokens are valid up to 1h and Apple penalizes excessive token regeneration (TooManyProviderTokenUpdates).

**Fix:** At minimum compute the APNs JWT once per handlePushNotify call (before Promise.all) since all registrations share team/key. Better: cache the imported CryptoKey and signed JWT on the DO instance with ~50min expiry and reuse across notifies. Confirmed N is bounded by registrations in one DO (one pairing), so the win is modest; severity reduced to low.

### Use constant-time comparison for HMAC token verification
`correctness` · severity **low** · effort **small** · confidence high

**Files:** `services/chau7-relay/src/worker.ts:76-80`

verifyToken compares the server-computed base64url HMAC against attacker-supplied signature with `expected === signature` (worker.ts:80), a short-circuiting string compare and a minor timing side-channel on an auth-critical path. Practical exploitability is limited by the 5-minute timestamp window and the timestamp being part of the signed message, but constant-time compare is cheap insurance.

**Fix:** Use crypto.subtle.verify against the raw HMAC bytes, or a length-checked constant-time byte comparison, instead of `===` on the base64url strings.

### Stale README route table omits /pending routes
`doc` · severity **low** · effort **small** · confidence high

**Files:** `services/chau7-relay/README.md:11-19`, `services/chau7-relay/src/worker.ts:161-171`

The README Routes table (README.md:13-18) documents GET /, WS /connect, POST /push/register, POST /push/notify but omits the GET /pending/:deviceId and POST /pending/:deviceId routes that worker.ts (line 161) and SessionDO (session.ts:120-128) implement. The worker.ts top-of-file doc comment (lines 8-9) does list them, so the README is the stale surface.

**Fix:** Add GET/POST /pending/:deviceId rows to the README Routes table to match the implemented surface.

### Duplicated DO stub dispatch across the three route handlers
`duplication` · severity **low** · effort **small** · confidence high

**Files:** `services/chau7-relay/src/worker.ts:145-147`, `services/chau7-relay/src/worker.ts:156-158`, `services/chau7-relay/src/worker.ts:168-170`

All three action branches (connect, push, pending) repeat the identical three-line incantation `idFromName(deviceId)` -> `get(id)` -> `stub.fetch(request)` (worker.ts:145-147, 156-158, 168-170), differing only by the deviceId variable name.

**Fix:** Extract a helper e.g. forwardToSession(env, deviceId, request) returning env.SESSION.get(env.SESSION.idFromName(deviceId)).fetch(request) and call it from all three branches.

### APNs failure responses discard body, no observability on push failures
`correctness` · severity **low** · effort **small** · confidence high

**Files:** `services/chau7-relay/src/session.ts:329-341`, `services/chau7-relay/src/session.ts:242-251`

sendAPNSNotification returns only response.status and never reads the APNs response body (session.ts:340), discarding the APNs `reason`. handlePushNotify only special-cases 400/410 for pruning (session.ts:245-248) and silently ignores all other non-2xx statuses (403 ExpiredProviderToken, 429 TooManyProviderTokenUpdates, 500) with no logging, making push delivery failures invisible in production.

**Fix:** On non-2xx, read the response body and console.warn/error the APNs reason + status so failures are diagnosable; optionally treat 403 ExpiredProviderToken as a signal to refresh a cached JWT.

### Unused APNS_* fields on worker.ts Env interface
`dead-code` · severity **low** · effort **small** · confidence high

**Files:** `services/chau7-relay/src/worker.ts:40-46`

The Env interface in worker.ts (lines 43-45) declares APNS_TEAM_ID, APNS_KEY_ID, APNS_PRIVATE_KEY but grep confirms worker.ts never reads env.APNS_* — only env.RELAY_SECRET and env.SESSION. The APNs bindings are consumed exclusively by SessionDO, which declares its own Env (session.ts:82-86). The worker.ts declarations are vestigial type annotations and removing them is type-only (the DO receives its env via the runtime binding, independent of worker.ts's Env type).

**Fix:** Drop the APNS_* fields from worker.ts's Env interface (keep SESSION and RELAY_SECRET), leaving session.ts's Env as the source of truth for APNs config. Cosmetic; low value.

## Service · chau7-issues (TS worker)

### Rate-limit quota is consumed before the issue is actually created
`correctness` · severity **medium** · effort **medium** · confidence high

**Files:** `services/chau7-issues/src/worker.js:57-58`, `services/chau7-issues/src/worker.js:88-175`

Verified. IssueRateLimitDO.fetch pushes the timestamp and persists it (lines 57-58, recent.push(now)/storage.put) as soon as recent.length < max. handleIssueCreate invokes the DO at lines 102-108, which is BEFORE request.json() (line 127), before the title/body validation (lines 132-145), and before the GitHub fetch (line 156). There is no decrement or refund path. So any request that fails on invalid JSON (400), missing/oversized fields (400), or a transient GitHub error (502 at line 170) still permanently consumes one of the 5 attempts/hour. A user can lock themselves out for an hour via a fat-fingered payload or a GitHub 502 without ever creating an issue.

**Fix:** Move the rate-limit record to after successful validation and only count on a successful GitHub creation (githubResponse.ok), OR split the DO into a read-only 'check' and a 'commit' call, committing only on success. The latter keeps cheap pre-validation rejection while still throttling abuse. Note: counting all POSTs (including malformed ones) is a defensible anti-spam choice, so confirm intended semantics before changing.

### No automated tests for the issue intake worker
`test-gap` · severity **medium** · effort **medium** · confidence high

**Files:** `services/chau7-issues/src/worker.js`, `services/chau7-issues/package.json`

Verified. The package has no test files anywhere (find for *test*/*spec* under the package returns nothing, no vitest config present) and package.json scripts are only format:check, format:write, build (wrangler dry-run), deploy, and cutover -- no 'test'. The worker carries non-trivial, security-relevant logic worth covering: per-IP sliding-window eviction (recent.filter(now - ts < windowMs), line 51), the 429-vs-503 mapping (lines 114-123), GITHUB_ISSUE_REPO regex validation (line 93), 256/65535 length bounds (lines 140-145), and labels.filter(...).slice(0,5) (line 148). Regressions in windowing or input validation would ship silently.

**Fix:** Add a minimal vitest + @cloudflare/vitest-pool-workers suite covering: rate-limit allows N then 429s and re-allows after the window, misconfigured/invalid repo -> 503, missing/oversized fields -> 400, label cap/type filtering, and OPTIONS -> 204 CORS headers. Wire a 'test' script into package.json.

### Durable Object over-validates a fixed internal route and trusts caller-supplied limits
`simplify` · severity **low** · effort **small** · confidence medium

**Files:** `services/chau7-issues/src/worker.js:40-60`, `services/chau7-issues/src/worker.js:104-107`

Verified factually. The DO re-parses url.pathname and rejects non-POST/non-/ratelimit/check requests (lines 42-45), and reads max/windowMs from the request body (line 47), even though the only caller is the worker, which always builds the exact fixed request 'https://internal/ratelimit/check' with method POST and passes the module constants ISSUE_RATE_MAX/ISSUE_RATE_WINDOW_MS (lines 104-107). The guard is effectively unreachable and the limits could be inlined into the DO. Caveat: this is borderline -- defensive path/method checks inside a DO fetch handler are a common Workers convention (a DO is addressable by anyone holding the binding), and threading the limits keeps them as single-source worker constants. The cleanup is real but low-value and arguably fights a reasonable defensive pattern.

**Fix:** If pursued, drop the path/method parsing in the DO and inline the limit constants there, passing only { ip }. Trades a few lines of redundancy for a slightly tighter contract; safe to skip if the team prefers defensive DO routing.

## Service · chau7-remote (Go)

### Remove unused exported State methods
`dead-code` · severity **low** · effort **small** · confidence high

**Files:** `services/chau7-remote/internal/agent/state.go:199`, `services/chau7-remote/internal/agent/state.go:206`, `services/chau7-remote/internal/agent/state.go:296`

MacPublicKeyBytes (state.go:199), IOSPublicKeyBytes (state.go:206), and RemovePairedDevice (state.go:296) are exported *State methods with no callers anywhere in the Go module (cmd/ or internal/, including agent_test.go). Confirmed via repo-wide grep for .MacPublicKeyBytes / .IOSPublicKeyBytes / .RemovePairedDevice -> only definitions match. By contrast MacPrivateKeyBytes is used at agent.go:811. These are internal Go helpers (not a cross-component wire contract), so removal is safe.

**Fix:** Delete the three unused methods. Removing RemovePairedDevice also drops the sole caller of syncLegacyFromFirstPairedDevice (state.go:357, called only at state.go:300), so that helper can be deleted too. Verified syncLegacyFromFirstPairedDevice has no other reference.

### PendingStatePayload.UpdatedAt is always empty (and ignored by relay)
`dead-code` · severity **low** · effort **small** · confidence high

**Files:** `services/chau7-remote/internal/agent/agent.go:200`, `services/chau7-remote/internal/agent/agent.go:1099`

PendingStatePayload (agent.go:197-201) has UpdatedAt `json:"updated_at,omitempty"`, but syncPendingState (agent.go:1099-1102) builds the payload with only Approvals and InteractivePrompts, so updated_at is always omitted. Repo-wide grep shows UpdatedAt is referenced only at the struct definition on the Go side. Confirmed the relay defines updated_at? on its own PendingStatePayload (session.ts:79) but unconditionally overwrites it with new Date().toISOString() in handlePendingSync (session.ts:292), so even if the agent populated it the relay would discard the value.

**Fix:** Remove the UpdatedAt field from the Go struct since the relay always stamps its own timestamp on sync (session.ts:292), making any agent-supplied value dead. (The original suggestion to populate it for relay staleness checks would be ineffective given the relay overwrite.)

### Misleading comment: second low-order vector is not the identity point
`doc` · severity **low** · effort **small** · confidence high

**Files:** `services/chau7-remote/internal/agent/agent.go:776`

In isLowOrderPoint (agent.go:773), the byte vector {1,0,...,0} is annotated `// identity` (agent.go:776). On Curve25519 the little-endian u-coordinate value 1 is a small-order point (order 4), not the neutral/identity element (u=0, the all-zero vector on line 775). The label is technically wrong. isLowOrderPoint is live code (called from validatedIOSPublicKey at agent.go:711, which is exercised by agent_test.go:62/68); the actual cryptographic guarantee is the all-zero-shared-secret check in establishSession (agent.go:823-835).

**Fix:** Correct the comment on agent.go:776 (e.g. 'small-order point (order 4)') rather than 'identity'. Purely a documentation fix; no behavior change. Note the all-zero shared-secret check in establishSession is what actually defends against low-order inputs, so this is cosmetic.

### No tests for state.go persistence, migration, and key-wrapping logic
`test-gap` · severity **medium** · effort **medium** · confidence high

**Files:** `services/chau7-remote/internal/agent/state.go`

Confirmed internal/agent/ contains only agent.go, agent_test.go, state.go (no state_test.go). state.go holds the highest-risk persistence logic: atomic SaveState (temp file + Sync + Chmod + Rename, lines 140-190), AES-GCM key wrap/unwrap keyed by machine UUID (wrapKey/unwrapKey/deriveWrappingKey, lines 62-103), legacy single-device migration (migrateLegacyPairedDevice, lines 336-350), and UpsertPairedDevice fingerprint derivation (lines 235-263). Notably LoadState silently resets MacPrivateKey/MacPublicKey to empty on unwrap failure (lines 121-134), so a regression there would silently destroy the device identity with no test to catch it.

**Fix:** Add state_test.go covering: SaveState->LoadState round-trip including the wrapped-key decrypt path; migrateLegacyPairedDevice promoting a legacy IOSPublicKey into PairedDevices; UpsertPairedDevice insert-vs-update behavior; and the unwrap-failure fallback (lines 128-133) that resets keys.

### Per-connection deadline-reset goroutine leaks until process shutdown on each IPC reconnect
`correctness` · severity **low** · effort **small** · confidence high

**Files:** `services/chau7-remote/internal/agent/agent.go:356`

readIPC (agent.go:353) spawns a goroutine (agent.go:356-359) that blocks on <-ctx.Done() and then sets a past read deadline to unblock the blocking read. On a normal IPC disconnect, readIPCFrame returns an error and readIPC returns (agent.go:367-373), but this goroutine stays parked because ctx is not cancelled on per-connection disconnect. ipcLoop reconnects in a loop (agent.go:330-350) calling readIPC each iteration, so one goroutine leaks per IPC reconnect for the lifetime of the process; only top-level ctx cancellation drains them.

**Fix:** Scope the goroutine to the connection: create a per-call done channel, `defer close(done)` in readIPC, and have the goroutine `select` on both ctx.Done() and done so it exits when this connection ends. Keeps the cancellation-unblock behavior without accumulating goroutines across reconnects.

## Rust · chau7_optim + chau7_md

### Remove vestigial unused config sections (display, filters, tracking flags)
`dead-code` · severity **low** · effort **small** · confidence high

**Files:** `apps/chau7-macos/rust/chau7_optim/src/config.rs`, `apps/chau7-macos/rust/chau7_optim/src/tracking.rs`

Config exposes DisplayConfig (colors/emoji/max_width), FilterConfig (ignore_dirs/ignore_files), and TrackingConfig.enabled/history_days serialized into ~/.config/rtk/config.toml but never read anywhere. Confirmed via grep: no read sites for config.display/.colors/.emoji/max_width, config.filters/ignore_dirs/ignore_files, or tracking.enabled/history_days outside config.rs. (The tee.rs:81 `config.enabled` is TeeConfig.enabled, a separate field.) Only tracking.database_path (tracking.rs:760) and the tee section are actually consumed. cleanup_old() uses a hardcoded const HISTORY_DAYS=90 (tracking.rs:41,331) instead of config.tracking.history_days. So a user setting tracking.enabled=false or display.colors=false has zero effect. Severity lowered to low: this is cosmetic/misleading config cruft with no functional bug; deleting is cleanup, not a fix.

**Fix:** Delete DisplayConfig, FilterConfig, and the TrackingConfig.enabled/history_days fields (and stop serializing them), since they are inherited-from-rtk cruft with no consumers. Alternatively wire them up (honor tracking.enabled, read history_days for cleanup), but deletion is simplest.

### Deduplicate copy-pasted compact_path helpers
`duplication` · severity **low** · effort **small** · confidence high

**Files:** `apps/chau7-macos/rust/chau7_optim/src/ruff_cmd.rs`, `apps/chau7-macos/rust/chau7_optim/src/format_cmd.rs`, `apps/chau7-macos/rust/chau7_optim/src/lint_cmd.rs`, `apps/chau7-macos/rust/chau7_optim/src/golangci_cmd.rs`

compact_path is defined independently in 5 modules (ruff_cmd:287, format_cmd:274, lint_cmd:554, golangci_cmd:173, grep_cmd:524). Verified ruff_cmd uses anchors src/lib/tests with identical rfind+slice+basename-fallback structure; golangci_cmd uses pkg/cmd/internal with the same structure. lint_cmd is a subset and format_cmd matches ruff_cmd. grep_cmd's version is genuinely different (middle-ellipsis) so it stays. A single utils::compact_path(path, anchors) would cover the four similar copies. There is no existing utils::compact_path today.

**Fix:** Add a single utils::compact_path(path: &str, anchors: &[(&str, usize)] or &[&str]) and have ruff/format/lint/golangci call it with their respective anchor sets, leaving grep_cmd's distinct helper alone.

### Tracker reopens SQLite and runs a DELETE on every single tracked command
`performance` · severity **low** · effort **medium** · confidence high

**Files:** `apps/chau7-macos/rust/chau7_optim/src/tracking.rs`

Confirmed: track() (tracking.rs:861) and track_passthrough() (:897) both call Tracker::new() per command. Tracker::new() (:226-269) runs CREATE TABLE IF NOT EXISTS, CREATE INDEX, two ALTER TABLE migration attempts, and a second CREATE INDEX every invocation. record() (:293) unconditionally calls cleanup_old() (:330), a full DELETE WHERE timestamp < cutoff scan, after each insert. With 38 TimedExecution::start sites wrapping fast CLI commands, this adds per-call DB open + schema churn + a delete to the hot path. The two ALTER migrations in particular never need to re-run after first launch.

**Fix:** Run schema setup/migrations once, idempotency-guarded via PRAGMA user_version, and gate cleanup_old() to at most once/day (date-check or marker row) rather than on every insert.

### Remove unused walkdir dependency
`dependency` · severity **low** · effort **small** · confidence high

**Files:** `apps/chau7-macos/rust/chau7_optim/Cargo.toml`

walkdir = "2" is declared at Cargo.toml:16 but grep for 'walkdir' / 'WalkDir' across src/ (and the whole crate) returns no references. Directory traversal uses the `ignore` crate instead. Dropping the line removes an unused dependency and its compile cost.

**Fix:** Delete the `walkdir = "2"` line from Cargo.toml.

### Stale doc comment references nonexistent cc_economics.rs
`doc` · severity **low** · effort **small** · confidence high

**Files:** `apps/chau7-macos/rust/chau7_optim/src/display_helpers.rs`

display_helpers.rs:3 module doc claims it 'Eliminates duplication in gain.rs and cc_economics.rs', but cc_economics.rs does not exist in the crate. Confirmed: the only repo references to cc_economics are this comment and an UPSTREAM-SYNC.md note documenting that the cc_economics/ccusage feature was intentionally not ported from the rtk fork. Misleading to readers tracing PeriodStats consumers.

**Fix:** Update the comment to reference only gain.rs, removing the cc_economics.rs mention.

## Rust · chau7_terminal + chau7_parse

### Remove dead per-row dirty-tracking machinery from DirtyRowTracker
`dead-code` · severity **low** · effort **medium** · confidence high

**Files:** `apps/chau7-macos/rust/chau7_terminal/src/metrics.rs:109-263`, `apps/chau7-macos/rust/chau7_terminal/src/terminal.rs:1178`, `apps/chau7-macos/rust/chau7_terminal/src/terminal.rs:2683`

DirtyRowTracker is a ~150-line word-bitmap with mark_dirty/mark_range_dirty/is_dirty/set_rows, but in production it is only driven all-or-nothing: every non-test caller calls mark_all_dirty() (terminal.rs:1178, 1466, 1951) or clear() (terminal.rs:2678, 2689). The only readers are dirty_count() (ffi.rs:1502, terminal.rs:2188) and get_dirty_rows(). Notably the get_dirty_rows() wrapper at terminal.rs:2683 has no caller at all (no FFI export, no Swift caller — confirmed by whole-repo grep), so the granular path is fully unreachable. mark_dirty/mark_range_dirty/is_dirty/set_rows appear only inside #[cfg(test)] mod tests (metrics.rs:281). The bitmap, RwLock, and per-row math carry no production weight.

**Fix:** Collapse DirtyRowTracker to a {full_dirty: AtomicBool, rows: AtomicU64} pair exposing mark_all_dirty/clear/dirty_count, delete the bitmap, RwLock, mark_dirty/mark_range_dirty/is_dirty/set_rows, the unused get_dirty_rows wrapper, and the now-redundant tests. If real partial-update tracking is a near-term goal, leave a TODO instead. Severity lowered to low: it is unreachable complexity, not a functional defect.

### set_rows is never called on resize, leaving the dirty-row count frozen
`correctness` · severity **low** · effort **small** · confidence high

**Files:** `apps/chau7-macos/rust/chau7_terminal/src/metrics.rs:254-262`, `apps/chau7-macos/rust/chau7_terminal/src/terminal.rs:878-959`

DirtyRowTracker::set_rows is meant to grow the bitmap and re-store the row count on resize, but Chau7Terminal::resize (terminal.rs:878) updates self.rows/self.cols atomics and term.resize without ever calling self.dirty_rows.set_rows(...). The tracker's `rows` field is frozen at creation height. This is masked today because the tracker is always full-dirty, so dirty_count() returns the stale rows value and the (uncalled) get_dirty_rows() would too. It is a latent bug: dirty_row_count in DebugState reports the original, not resized, height. set_rows is dead outside tests (confirmed: only metrics.rs:254 definition).

**Fix:** Wire self.dirty_rows.set_rows(rows as usize) into resize(), or — preferably, in tandem with the dirty-tracker cleanup finding — drop the per-row tracker so there is no row count to keep in sync. Low severity because the value is only consumed by debug reporting.

### Drop unused PerformanceMetrics.vte_process_time_us field
`dead-code` · severity **low** · effort **small** · confidence high

**Files:** `apps/chau7-macos/rust/chau7_terminal/src/types.rs:213`, `apps/chau7-macos/rust/chau7_terminal/src/terminal.rs:2670`

PerformanceMetrics.vte_process_time_us is declared (types.rs:213) and reset to 0 (terminal.rs:2670) but never incremented and never surfaced via DebugState or FFI. Whole-tree grep returns exactly two hits: the declaration and the store(0). No fetch_add, no reader.

**Fix:** Remove the field and its reset line. If VTE timing is wanted, wrap processor.advance in process_pty_data with an Instant and fetch_add there.

### ambiguous_width is stored but never read, and the FFI knob has no callers
`dead-code` · severity **low** · effort **small** · confidence high

**Files:** `apps/chau7-macos/rust/chau7_terminal/src/terminal.rs:319`, `apps/chau7-macos/rust/chau7_terminal/src/terminal.rs:1958-1962`, `apps/chau7-macos/rust/chau7_terminal/src/ffi.rs:1096-1106`

The ambiguous_width AtomicU64 (terminal.rs:319) is written by set_ambiguous_width (exposed as chau7_terminal_set_ambiguous_width FFI) but never .load()ed anywhere — width decisions are made inside alacritty and are not influenced by this field. The whole knob is a no-op. Stronger than the original finding claimed: a whole-repo grep finds NO Swift caller of chau7_terminal_set_ambiguous_width either, so the entire API surface (field + setter + FFI export + header entry chau7_terminal.h:702) is dead.

**Fix:** Either implement the intended behavior (feed the preference into alacritty's width handling) or remove the field, set_ambiguous_width, the FFI export, and the header entry so the API does not advertise an unimplemented, uncalled feature.

### OSC 7 cwd is parsed twice per chunk (scan_osc7 duplicates the interceptor's OSC scanner)
`duplication` · severity **low** · effort **medium** · confidence high

**Files:** `apps/chau7-macos/rust/chau7_terminal/src/terminal.rs:1239-1275`, `apps/chau7-macos/rust/chau7_terminal/src/terminal.rs:1318-1322`, `apps/chau7-macos/rust/chau7_terminal/src/graphics.rs:377-427`

process_pty_data runs a hand-rolled byte scan (scan_osc7, terminal.rs:1239) over every PTY chunk to extract OSC 7, then immediately runs GraphicsInterceptor::feed_owned over the same bytes (terminal.rs:1318 then 1322). The interceptor's State::Osc machine (graphics.rs:377) already accumulates the OSC prefix and passes through non-1337/133 OSCs (including OSC 7), so two independent ESC/OSC scanners walk identical data on the hot path. Verified the interceptor only special-cases 1337/133 and passes OSC 7 through.

**Fix:** Extend GraphicsInterceptor to surface OSC 7 (cwd) alongside its shell-events output and delete scan_osc7, capturing cwd in the single pass the interceptor already makes. Preserve the race-free pickup semantics documented at terminal.rs:1310-1317 when doing so.

### GraphicsInterceptor::feed is pub but only used internally by feed_owned and tests
`architecture` · severity **low** · effort **small** · confidence high

**Files:** `apps/chau7-macos/rust/chau7_terminal/src/graphics.rs:197-552`

GraphicsInterceptor::feed (the borrow-returning 320-line scanner, graphics.rs:197) has exactly one production caller: feed_owned at graphics.rs:541, which discards the returned borrow. Every other interceptor.feed(...) call is inside #[cfg(test)] mod tests (graphics.rs:1231+). Keeping feed public alongside feed_owned invites callers to pick the borrow API and trip over the lock-lifetime problem feed_owned exists to solve. (Note: graphics.rs:955 is a different feed on the kitty accumulator, unrelated.)

**Fix:** Make GraphicsInterceptor::feed private (fn, not pub fn). Tests in the same module can still call it. Update the doc-comment example at graphics.rs:130 to use feed_owned.

### Stale per-file line counts and wrong snapshot type name in chau7_terminal README
`doc` · severity **low** · effort **small** · confidence high

**Files:** `apps/chau7-macos/rust/chau7_terminal/README.md`

The README 'Source Files' table line counts are stale: lib.rs listed 15 (actual 22), terminal.rs ~2900 (actual 3804), ffi.rs ~1600 (actual 2099), graphics.rs ~1900 (actual 1700). The types.rs row references a 'RenderSnapshot' type that does not exist in the crate — the type is GridSnapshot (types.rs:96).

**Fix:** Refresh the counts (or drop precise numbers for approximate ranges that won't rot) and fix RenderSnapshot -> GridSnapshot.

### ansi_sgr_sequence allocates a Vec<String> per style transition
`performance` · severity **low** · effort **small** · confidence high

**Files:** `apps/chau7-macos/rust/chau7_terminal/src/terminal.rs:2599-2625`

For every cell style change during full_buffer_ansi_text / tail_buffer_ansi_text export, ansi_sgr_sequence builds a Vec<String> (terminal.rs:2600), pushes up to ~7 short heap Strings plus two format! allocations, then joins and formats again. On a styled full-buffer export with frequent color changes this is a lot of transient allocation for a fixed-format escape string. This is an export path, not 60fps, so severity is low.

**Fix:** Write directly into the caller's output String with write! / a small fixed byte buffer (codes are static &str literals and three u8 triplets), avoiding the Vec<String> and intermediate join.

## Tooling · scripts/CI/build

### Remove orphaned legacy ci-local-fast script and its dead ci-lib.sh helpers
`dead-code` · severity **medium** · effort **small** · confidence high

**Files:** `scripts/ci-local-fast`, `scripts/ci-lib.sh`, `scripts/README.md`

scripts/ci-local-fast (header 'Legacy fast local CI helper') has no live entry point: confirmed not referenced by .husky/, registry.mjs, .github/workflows/release.yml, or package.json — only by scripts/README.md and apps/chau7-macos/README.md. Its supporting helpers ci_collect_staged_files (ci-lib.sh:51), ci_should_run_for_paths (ci-lib.sh:57), and the CI_FAST_ALL/CI_STAGED_FILES machinery are used exclusively by ci-local-fast — grep for those symbols outside ci-lib.sh/ci-local-fast returns nothing.

**Fix:** Delete scripts/ci-local-fast plus the now-unreferenced ci_collect_staged_files / ci_should_run_for_paths / CI_FAST_ALL / CI_STAGED_FILES from ci-lib.sh, then prune the README rows. Note: ci_relay_ensure_deps must be KEPT — scripts/ci-local still calls it (ci-local:46). Canonical staged path is `pnpm quality:staged`.

### Delete dead re-export shim scripts/git/quality-helpers.mjs
`dead-code` · severity **low** · effort **small** · confidence high

**Files:** `scripts/git/quality-helpers.mjs`

The file body is exactly `export * from "../quality/helpers.mjs";`. No file in the repo imports it — grep -rn 'quality-helpers' across the repo returns no matches. The git/ entry scripts import directly from ../quality/runner.mjs or ../quality/helpers.mjs.

**Fix:** Delete scripts/git/quality-helpers.mjs.

### Remove unused toolVersion import in runner.mjs
`dead-code` · severity **low** · effort **small** · confidence high

**Files:** `scripts/quality/runner.mjs`

runner.mjs imports toolVersion from helpers.mjs at line 24, but grep -n 'toolVersion' scripts/quality/runner.mjs returns only that import line — there is no call site in the file. toolVersion is legitimately used elsewhere (cache.mjs), just not in runner.mjs.

**Fix:** Drop toolVersion from the import list in runner.mjs.

### exec() in runner silently drops stdin and quiet options that callers pass
`correctness` · severity **low** · effort **small** · confidence high

**Files:** `scripts/quality/runner.mjs`, `scripts/quality/registry.mjs`

The per-gate context.exec wrapper (runner.mjs:242-263) only reads execOptions.cwd and execOptions.env and forwards them to spawnCapture; there is no handling of stdin or quiet. Callers pass options that are silently ignored: runShellScript (registry.mjs:55-61) forwards options.stdin (dropped entirely), and the staged-python-ruff-fix / staged-js-format gates pass `{ quiet: true }` on their `git add` calls (registry.mjs:335, :364) expecting suppressed output, which has no effect. Latent today (no gate relies on stdin) but the API shape is misleading and quiet is a no-op.

**Fix:** Either implement stdin/quiet in exec+spawnCapture, or remove the dead options (drop stdin plumbing from runShellScript and the `{ quiet: true }` args) so the API matches actual behavior.

### macOS README points to legacy and wrong-case CI script paths
`doc` · severity **low** · effort **small** · confidence high

**Files:** `apps/chau7-macos/README.md`

The 'Local CI' section (README.md:36-37) instructs running `../../Scripts/ci-local-fast` and `../../Scripts/ci-local`. The repo dir is lowercase `scripts/`; both `Scripts` and `scripts` resolve on the common case-insensitive macOS volume (verified), but on case-sensitive checkouts/CI the capitalized path breaks. It also steers users to ci-local-fast, which is documented as legacy/orphaned in scripts/README.md:11. Severity lowered from medium because the path resolves on the default macOS filesystem.

**Fix:** Reference `pnpm quality:staged` / `pnpm quality:prepush` from repo root; if a raw script is still wanted, use lowercase `../../scripts/ci-local` and remove the ci-local-fast reference.

### Near-duplicate PTY and CLI wrapper scripts could share a parameterized helper
`duplication` · severity **low** · effort **small** · confidence medium

**Files:** `apps/chau7-macos/Scripts/claude-pty.sh`, `apps/chau7-macos/Scripts/codex-pty.sh`, `apps/chau7-macos/Scripts/claude-wrapper.sh`, `apps/chau7-macos/Scripts/codex-wrapper.sh`

Verified: claude-pty.sh and codex-pty.sh differ only in the log name/env var and the final exec target (`claude` vs `codex`). claude-wrapper.sh and codex-wrapper.sh differ only in the tool name string and invoked binary. Four files encode two templates. Note: the command names claude-pty/claude-wrapper/codex-pty/codex-wrapper are wired into Chau7Core/AIToolRegistry.swift (lines 104, 119) as process-detection command names, so these are NOT vestigial — a parameterization must preserve those exact names (e.g. via symlinks). The wrapper.sh variants carry 'Example wrapper... Adjust to your setup' headers, suggesting they are illustrative.

**Fix:** Optionally collapse each pair into a parameterized script (tool name from $0/symlink), preserving the claude-/codex- command names AIToolRegistry detects. Low value; mostly stylistic.

### Stale script count in scripts/README app-scripts note
`doc` · severity **low** · effort **small** · confidence high

**Files:** `scripts/README.md`

scripts/README.md:81 states the macOS app has '17 additional scripts in apps/chau7-macos/Scripts/', but `git ls-files apps/chau7-macos/Scripts/ | wc -l` returns 21.

**Fix:** Update the count, or drop the hardcoded number and point to the macOS app README so it cannot drift.

### Extensionless shell scripts in scripts/ are never shellchecked; classifier branch is effectively dead
`test-gap` · severity **low** · effort **small** · confidence high

**Files:** `scripts/quality/helpers.mjs`, `scripts/quality/registry.mjs`

directTargetsForFiles().shell (helpers.mjs:232) includes both `.sh`/`.bash` files AND anything under `scripts/` via `/^scripts\//`. Verified the only consumer is the staged-shellcheck gate, which re-narrows to `/\.(sh|bash)$/` in both applies (registry.mjs:423) and run (registry.mjs:426). No other gate consumes `.shell`. As a result the `/^scripts\//` clause produces no effect, and extensionless bash-shebang scripts (scripts/order66, scripts/check-anti-slop, scripts/check-design-system, scripts/ci-local, apps/chau7-macos/Scripts/order66, apps/chau7-macos/Scripts/knit — all confirmed `#!/usr/bin/env bash`) are never shellchecked.

**Fix:** Either shellcheck extensionless scripts by detecting a bash/sh shebang, or remove the unused `/^scripts\//` clause from the shell classifier to avoid implying coverage that does not exist.

## Dropped during verification (false positives)

- **Two action-name catalogs (string-keyed and enum-keyed) maintained in parallel** _(macOS · Settings)_ — The premise that both catalogs are live and 'a name change must be made in two places' is false. KeyboardShortcut.actionDisplayName (string-keyed) is the only user-facing one (used by InputSettingsView and KeyboardShortcutsEditor). KeyAction.displayName (enum-keyed, KeybindingsManager.swift:148-197) has zero production references; its only reference is a test asserting non-emptiness — so it is effectively dead, not a parallel maintained catalog. Worse, the proposed fix (delete actionDisplayName, route the editor through KeyAction.displayName) would regress localization: actionDisplayName returns localized strings via L(...) while KeyAction.displayName returns hardcoded English, so the swap would lose translations. The diverging-string examples cited are between a live localized table and a dead hardcoded one, not two live tables. The genuine observation (KeyAction.displayName is dead) is already covered by the dead-code theme and is not what this finding recommends. Dropping as mis-framed with a behavior-regressing recommendation.
- **Remove unused completedRunFirstResponseSample (singular) helper** _(macOS · Features & Data)_ — Refuted. The singular ProviderLatencyAnalytics.completedRunFirstResponseSample is referenced 4 times in Tests/Chau7Tests/Usage/ProviderLatencyAnalyticsTests.swift (lines 108, 130, 147, 164). The finding's claimed grep of zero call sites is wrong; it is covered by tests and is not dead code.
- **Remove write-only sessionReady field** _(Service · chau7-remote (Go))_ — Refuted. The finding's core claim ('its value is never read') is false. agent_test.go reads a.sessionReady at line 114 (`if a.sessionReady { t.Fatal("expected sessionReady to be cleared for repair handshake") }`) and seeds it at line 92. The field is an asserted-on invariant in the repair-handshake test, so it is not write-only and deleting it would break the test. grep for .sessionReady shows assignments at agent.go:497/843/894 AND read sites at agent_test.go:114-115.
- **Drop unused protocol frame type TypeError** _(Service · chau7-remote (Go))_ — Refuted as dead code. TypeError (0x7F) is part of a live shared wire contract, not dead code. The macOS app mirrors it as `case error = 0x7F` in RemoteFrame.swift:140 and actively PRODUCES an error frame at RemoteControlManager.swift:950 (`sendFrame(type: .error, tabID:, payload:)`). Removing the Go constant would diverge the protocol definition from a value that peers emit. The finding itself hedges ('Verify against the relay/iOS protocol before deleting'), and verification shows the deletion path is wrong; the only safe action (a reserved comment) is trivial/no-benefit. Drop.
