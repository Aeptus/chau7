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

## Phase 2 — Wire up the four advertised-but-dead features  ⬆ *(decision: implement, not remove)*
These now become real feature work, not deletions — each promises something the UI exposes, so we make it deliver. This is the largest scope-expansion vs. the audit's "remove" default; **17 in particular is a large, design-bearing piece** and likely wants its own mini-design pass.
- **17** Sixel/Kitty graphics: implement intercepted-image decode → RGBA → `InlineImageView`, replacing the two "Phase 4 future" TODO log stubs in `RustTerminalView+Rendering.swift:184-193`. Likely Rust-side decode (or a Swift decoder) + Kitty protocol state management. *Largest item in the whole plan; flag for a design sub-step (decoder choice, memory/anchor handling, placement in the Metal render path).*
- **33** Inactivity detection: call `recordActivity` from real input (keyDown/mouse/PTY activity) so `lastActivityTime` tracks actual use and `checkInactivity` stops firing spurious `inactivity_timeout` notifications after launch. Add a test driving the activity clock.
- **44** MinimalMode: implement the actual chrome-hiding behavior the settings UI promises **and** the `Cmd+Shift+M` shortcut its header claims (currently unimplemented). Decide exactly what "minimal" hides (tab bar / status bar / toolbar) — small design call.
- **3** Keybindings: wire the ~21 unreachable `KeyAction` cases (`selectTab1-9`, `selectAll`, `toggleFullscreen`, `interrupt`, `eof`, `suspend`, `clearLine`, `clearWord`, `toggleBroadcast`, `showClipboardHistory`, `showBookmarks`, `addBookmark`, `closeWindow`) into `fromShortcutAction` + `defaultShortcuts` so they're user-bindable — routing to the existing AppDelegate/menu actions that already implement them. Add a test asserting every `executeAction` branch is reachable.

> **Scope note:** wiring (vs. removing) turns Phase 2 from ~hours into a meaningful feature block. 17 should probably be staged after the low-risk phases so a broken decoder can't block everything else.

## Phase 3 — Correctness fixes (bugs)
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

## Phase 4 — Performance fixes
- **29** O(columns²) per-row column-map rebuild in telemetry parse — reuse the map-taking variant (`parseRun` precedent)
- **85** Rust tracker reopens SQLite + runs CREATE/ALTER/DELETE every command (×38 sites) — guard schema with `PRAGMA user_version`, gate cleanup to once/day
- **57** LocalizedFormatters rebuilt per access (per terminal line) — memoize
- **56** ISO8601DateFormatter minted per API-call message — hoist one instance
- **61** `appendSnapshotIfNeeded` re-reads entire JSONL on first write per provider — track offset/state
- **2** KeybindingsManager rebuilds a signature string per key event — invalidate via `didSet`, not recompute-and-compare
- **37** leak-investigation RSS instrumentation left in `moveTab` hot path — remove
- **69** relay mints APNs JWT per notification — cache (~50 min TTL)
- **95** Rust `ansi_sgr_sequence` allocates a `Vec<String>` per style transition — write into reusable buffer

## Phase 5 — Cross-cutting consolidations (build the shared helper once)
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

## Phase 6 — Hand-mirrored list sync + guard tests
Stops the "lists drift" theme from recurring.
- **21** route NotificationActionExecutor through `makeDefault` (one list) **+ a test** asserting prod list == tested list
- **5** backfill the 4 uncovered `SettingsSection`s in `searchableSettings` **+ a coverage test** (every section searchable)
- **1 (partial)** make `exportSettings`/`importSettings`/`resetAllToDefaults` iterate canonical declarations instead of re-listing defaults (start with one cluster as `MCPRemoteSettings`-style nested Codable; full god-object split is Phase 8)

## Phase 7 — Test gaps (highest risk-reduction per effort)
- **67** first iOS test target: ChaChaPoly seal/open round-trip + tamper rejection, nonce/AAD framing, ANSI scanner, output store
- **81** Go `state.go`: atomic save/load round-trip, AES-GCM wrap/unwrap, legacy migration, unwrap-failure fallback (the silent identity-reset)
- **76** chau7-issues: rate-limit window edges, 429/503 mapping, input validation
- **5** searchableSettings coverage test (also in Phase 6)
- **103** shellcheck the extensionless `scripts/` files (CI), fix the dead classifier branch

## Phase 8 — God-object decomposition  ✅ *(decision: include, incremental)*
In scope. Behavior-preserving, **one cohesive cluster per commit**, build/hot-swap/test after each — **last** because it's the riskiest and the app can't be killed. Each god-object is a multi-commit sub-effort, not a single pass.
- **39** AppDelegate (2974) → extract in order of increasing coupling: (a) autosave/persist, (b) multi-window create/restore, (c) tab/group move-between-windows, (d) URL-scheme handling, (e) the ~60 menu forwarders into a dedicated router. Lifecycle/App-Nap policy stays last.
- **1** FeatureSettings (4255) → continue Phase 6's nested-Codable extraction cluster-by-cluster (appearance, terminal, MCP, notifications, …) until export/import/reset/property are one declaration each. Highest payoff for stopping list drift.
- **19** RustTerminalView (~10k) → promote the existing `+Input`/`+Mouse`/`+Rendering`/`+UI`/`+Transcript` extensions into real collaborator types (input handler, renderer bridge, transcript store) behind the `TerminalViewLike` protocol, rather than one class with extensions.
- **11** Chau7OverlayView overlay extraction — the bounded, pure cut/paste split (also listed in Phase 5; do it early as the warm-up for this phase).

> **Sequencing:** start with **11** (pure move) and **1** (continues Phase 6, mechanical), then **39** (cluster by cluster), then **19** (touches the hottest render path — most regression-sensitive, do last with heavy manual verification via `/run`).

## Phase 9 — Documentation sweep (last, reflects post-refactor reality)
All small, low-risk. Do after refactors so READMEs match final disk.
- READMEs: **18** RustBackend, **20** Notifications, **27** Performance, **28** Monitoring, **34** Runtime, **71** relay routes, **94** chau7_terminal, **100** macOS CI paths, **102** scripts count
- Comments: **80** Go Curve25519 "identity" mislabel, **87** Rust `cc_economics.rs` stale ref
- Drop hardcoded counts/line numbers that rot; **optional CI check** flagging README file-tables that list nonexistent files (prevents recurrence).

---

## Coverage check
Findings 1–103 each appear in exactly one primary phase (a few cross-referenced where a helper and a guard test both apply).

## Decisions on record (2026-06-20)
- **Phase 2:** wire the four dead features up rather than remove them → Phase 2 is now real feature work; **finding 17 (Sixel/Kitty) is the largest single item in the plan** and wants its own design sub-step.
- **Phase 8:** god-object decompositions are **in scope**, done incrementally (one cluster per commit), sequenced last.
- **Execution:** plan only for now — no code changes made. Resume by picking a phase.

## Suggested execution order when resumed
0 (baseline) → 1 (deletions) → 3 (bugs) → 4 (perf) → 5 (consolidations) → 6 (list-sync) → 7 (tests) → 2 (wire features; 17 last/own design) → 8 (god-objects; 11 → 1 → 39 → 19) → 9 (doc sweep).
Rationale: clear the cheap/low-risk wins and shrink surface area *before* the two large blocks (feature-wiring and decomposition), and do the doc sweep last so READMEs match final disk.
