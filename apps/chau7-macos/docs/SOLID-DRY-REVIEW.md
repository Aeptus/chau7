# macOS App — Deep SOLID/DRY Review

*2026-07-03. Seven parallel subsystem reviews covering all of `Sources/Chau7`,
`Sources/Chau7Core`, and `Sources/MagiCLI`. Companion to the iOS review that
drove the RemoteClient decomposition; the house remediation style is the same:
extract collaborator/store behind a thin facade, isolated tests per
collaborator, granular gate-green commits.*

## The macro picture

| Metric | Value |
|---|---|
| Singletons (`static let shared`) | 79 |
| `.shared` reach-in call sites | 773 (FeatureSettings 267, TerminalControlService 54, FeatureProfiler 46) |
| Files > 2,400 lines | 8 (RustTerminalView 3,996; TerminalSessionModel 3,976; FeatureSettings 3,679; DebugConsoleView 3,070; AppDelegate 3,020; Chau7OverlayView 2,753; TerminalControlService 2,607; TelemetryStore 2,450) |

Three themes repeat in every subsystem:

1. **Per-item knowledge spread across N hand-maintained tables.** Settings
   exist in 4–6 definition sites; a new AI tool needs 4 table edits despite a
   registry claiming one; trigger-type strings are switched on in 5+ places;
   idle-tab logic is derived 3 divergent ways. This class of duplication has
   already produced live bugs (see below) — it is the highest-leverage target.
2. **God objects with visible seams.** Every big file decomposes along the
   same lines the events program proved out; several extractions are pure
   file moves or pure-logic lifts into Chau7Core with tests.
3. **Singleton reach-ins defeating existing injection.** Multiple types
   inject one dependency beautifully and then dereference 10–24 singletons
   internally (RepositoryPaneModel, RuntimeSessionManager, OverlayTabsModel
   at 115 sites).

## Bugs found by the review (fix first — each is S effort)

1. **Divergent setting defaults** — `isCopyOnSelectEnabled`: init default
   `true` (FeatureSettings.swift:2326) vs reset `false` (:3187);
   `showTabGitIndicator`: load `?? false` (:2335) vs reset `true` (:3166).
   Resetting settings silently changes behavior vs a fresh install.
2. **Data race in RuntimeSession** — `approvalTimeoutWork` /
   `consecutiveApprovalTimeouts` mutated outside the lock
   (RuntimeSession.swift:611–623, 675–676) contradicting the type's own
   `@unchecked Sendable` contract; event thread races MCP thread.
3. **Idle-tab logic divergence** — `fallbackIdleTabIDs`
   (Chau7OverlayView.swift:639) omits the `suspendedTabIDs` check present in
   `idleTabs` (:768); right-click hit-testing can disagree with rendering.
4. **Unbounded growth** — `AgentDashboardModel.sessionCosts` (:51) is never
   pruned while sibling maps are (:214).
5. **Dead startup-reveal path** — `prepareStartupOverlayWindow`
   (AppDelegate.swift:2550–2627) has zero callers, so
   `revealPreparedStartupOverlayWindows("startup_ready")` at :403 is a silent
   no-op. Delete or re-wire deliberately.
6. **Latent deadlocks** — `SpineJournalStore.deinit { queue.sync }`;
   RepositoryPaneModel `DispatchQueue.main.sync` from background (:307) plus
   main-thread git subprocesses (:614, :628); TerminalSessionModel
   `outputProcessingQueue.sync { aiLogQueue.sync }` lock-ordering hazard
   (+ShellIntegration:520 vs :208).

## Per-subsystem highlights

### App core (AppModel 1,704 · AppDelegate 3,020)
- AppDelegate ≈ 9 responsibilities → extract `WindowStatePersistenceController`,
  `OverlayWindowTransferController`, `StartupSequencer`, `AppKeyEventRouter`.
- AppModel ≈ 7 → extract `NotificationPermissionCoordinator`,
  `ToolMonitorCoordinator` (kills the hardcoded codex/claude twin sites ×6),
  `ClaudeCodeEventBridge`.
- `bootstrap()` is a second composition root wiring 8 singletons; move wiring
  to Chau7App, inject `SpineJournalStore` (injectable init already exists).
- Neither AppModel nor TerminalSessionModel is `@MainActor` despite doc
  comments claiming it; ~35 manual main-queue hops would delete.

### Terminal + RustBackend (3,976 + 3,996 and extensions)
- TerminalSessionModel ≈ 15 responsibilities → the four best extractions:
  `ShellLaunchConfigurator` (~650 lines, PURE → Chau7Core+tests),
  `LatencyTracker` (pure), `ShellProcessTerminator`, `AgentIdentityResolver`.
- RustTerminalView contains three types; `RustTerminalFFI` repeats the
  symbol-load pattern **39×** (~570 lines) → table-driven `RustTerminalSymbolTable`
  + a `TerminalBackend` protocol so the view can be tested against a fake.
- Pure encoders stranded in AppKit files: `MouseReportEncoder` (SGR/X10
  triplicated), `TerminalKeyEncoder` (+Input.swift:269–466) → Chau7Core.
- `terminalPollAccessLock` locked externally by BackgroundTerminalDrainService
  and doesn't cover everything it should; `VisibleTerminalPollingContext`'s
  `isWindowOccluded`/`isInteractive` fields are now dead (post occlusion fix).

### Overlay / StatusBar / Debug / Dashboard
- OverlayTabsModel: 115 `.shared` sites across 19 extensions → extract
  `TabStateBackupStore` (pure statics), `TabRestoreCoordinator`,
  `AIResumeIdentityResolver`, `TabRenderCoordinator`, `TabBarWatchdog`.
- DebugConsoleView: 3,070-line struct, ~360 dead lines, four token formatters
  despite `CountFormat` claiming single-source → `DebugConsoleModel` +
  per-tab files; delete dead views.
- CommandStatus→display mapping triplicated; `displayTitle` duplicated with
  divergent fallbacks; ~58 hand-rolled `tabs.first(where:)` → `subscript(tabID:)`.
- Model/view inversions both directions (NSAlert in model; git spawns in view
  `onAppear`; repo-group mutations inside menu closures).

### Remote / MCP / Proxy / Monitoring
- TerminalControlService ≈ 4 domains → `AgentLaunchOrchestrator` (~470 lines,
  clean seam via a `TabToolInvoking` protocol), `MCPApprovalPresenter`,
  `WindowModelRegistry` (breaks the Remote→MCP layering violation).
- RemoteControlManager deserves the iOS split: `RemoteAgentProcessController`
  (+`RemoteAgentBinaryProvider` — ~330 lines of embedded go-build),
  `RemoteApprovalCoordinator`, `RemoteActivityProjector` (nearly pure).
- Remote↔MCP bidirectional singleton cycle; approval context composition
  duplicated 3×; Unix-socket boilerplate triplicated → `UnixSocketListener`;
  Go-sidecar lifecycle duplicated with ProxyManager → `ManagedGoSidecar`.
- 11 `Thread.sleep` poll loops hammering `DispatchQueue.main.sync` from MCP
  threads; one MCP thread blocks inside nested `runModal`.

### Settings / Telemetry / Performance
- Every remaining FeatureSettings setting has 4–6 definition sites
  (didSet/Keys/init/reset/export/SettingsSearch) — source of the divergence
  bugs. Fix: `SettingDescriptor` (key, default, codec) that init/reset/export
  derive from; stores own their `reset()` + export fragment (do this BEFORE
  further domain extractions so they follow the corrected pattern).
- Remaining domains ranked: General Terminal (dangerous-command config),
  Tab behavior/display/hover, Productivity (F13–F21), MCP+Remote, App-level.
- TelemetryStore → `TelemetrySchemaMigrator` + `TelemetryMaintenance`;
  sqlite3 boilerplate quintuplicated across stores → shared `SQLiteStatement`
  helper in Chau7Core (~300 lines removed); aggregation queries scan full
  tables and filter provider in Swift → normalized `provider_key` column.
- SettingsSearch (911 lines) is a third hand-written catalog; generate it.

### Chau7Core + MagiCLI
- Tool identity in 4 tables (registry claims 1) → derive catalog tables and
  generic-adapter set from `AIToolDefinition`.
- Trigger-type vocabulary switched on in 5+ places; StylePlanner/formatter
  still match pre-unification raw strings → one kind→(title, body, style,
  trigger) table keyed on `SemanticTriggerType`; unify the three divergent
  type normalizers.
- Magi subtree (~3,900 lines) is app-agnostic CLI code inside the
  cross-platform core the iOS app links → move to `MagiKit`/MagiCLI.
- `MagiMCPOrchestrator.run()` (432 lines): 8 phases, 4 of which share one
  round template → `RunContext` + `runCouncilRound(kind:...)`; also split
  `waitForParsed` (246 lines). Removes the lint waiver.
- Delete `EventParsing` (dead pre-unification), `NotificationIngress` shim;
  downgrade over-public Core internals; derive ~350 lines of catalog literals.

## Staged remediation plan

Ordered for value ÷ risk; every stage keeps the full gate suite green and
lands as granular commits, exactly like the events program.

- **Stage 0 — bug sweep (S, do immediately):** the six findings in "Bugs
  found by the review". Behavior fixes with tests; no structure changes.
- **Stage 1 — dead code + micro-DRY (S):** dead startup path, DebugConsole
  dead views, `EventParsing`, `NotificationIngress`, dead polling-context
  fields, `tabs[tabID:]` subscript, shared normalizer, output-shaping dedup,
  approval-context factory, JSON-decode twins.
- **Stage 2 — SettingDescriptor + store-owned reset/export (M):** kills the
  4–6-sites-per-setting class permanently; then extract remaining settings
  domains in ranked order (each now one-table).
- **Stage 3 — pure-logic lifts to Chau7Core (M, low risk, high test value):**
  ShellLaunchConfigurator, MouseReportEncoder, TerminalKeyEncoder,
  GitPorcelainParser + UnifiedDiffParser, AIEventTimelineFormatter,
  SQLiteStatement helper, LatencyTracker.
- **Stage 4 — Remote/MCP decoupling (M–L):** WindowModelRegistry +
  protocol seams to break the singleton cycle; AgentLaunchOrchestrator;
  ManagedGoSidecar; UnixSocketListener; async-ify the Thread.sleep loops.
- **Stage 5 — the two flagship splits (L, one at a time):**
  TerminalSessionModel collaborators, then RustTerminalFFI symbol table +
  TerminalBackend protocol. Gate each on the full suite + a manual smoke.
- **Stage 6 — OverlayTabsModel + AppDelegate + TelemetryStore splits (L).**
- **Stage 7 — @MainActor adoption for AppModel/TerminalSessionModel (L,
  riskiest, last):** delete the ~35 manual hops once collaborators shrank
  the surfaces.
- **Parallel track — Chau7Core consolidation (M):** tool-identity single
  table, trigger-vocabulary single table, catalog literal derivation,
  MagiKit move, orchestrator round template.

## What's already right (templates for the rest)

EventSpine + host pump, the notification decision layer, the four extracted
settings stores, TerminalEventDrain's generation-counter design,
VisibleTerminalPollingPolicy (pure + tested), AgentDashboard's view/model
split, RemoteIPCServer's queue discipline, ProxyManager's request helpers,
DateFormatters/JSONPrettyPrinter centralization.
