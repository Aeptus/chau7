# Chau7Core

Swift: `apps/chau7-macos/Sources/Chau7Core/` (76 files, 11,295 lines)
Swift tests: `apps/chau7-macos/Tests/Chau7Tests/` (per row below)
Wave: per row, follows its users
Depends on: none

Chau7Core is the pure, UI-free logic shared by the macOS app: parsers, state
machines, catalogs, wire formats and policies. It has no user-visible surface
of its own, so rows here are per Swift file (or main type), not per feature.
Port a row in the same wave as the first app module listed under "Used by".

## Features

| ID | Feature | Swift source | Tests | Rust | Status | macOS API |
|---|---|---|---|---|---|---|
| COR-001 | AI tool detection state machine per session: scanning, detected, cooldown after prompt return (re-detect locked to the same tool), restored from saved tab state. Used by: Terminal. | `AIDetectionState.swift` | `AIDetectionStateTests` (37) | chau7_next_core/src/ai/detection_state.rs | done |  |
| COR-002 | Tool-agnostic `AIEvent` model, `AIEventSource` (extensible raw values), reliability, and `AIEventParser` for event log lines. Used by: Notifications, StatusBar, App, AI, Debug, Events, History, Monitoring, Proxy, Runtime, Settings, Terminal. | `AIEvent.swift` | `AIEventParserTests` (2) | chau7_next_core/src/ai/event.rs | done |  |
| COR-003 | Maps the three primary AI notification toggles (finished, failed, permission) to underlying trigger ids, group trigger state and action lists in settings. Used by: Settings. | `AINotificationSettingsBridge.swift` | `AINotificationSettingsBridgeTests` (9) | chau7_next_core/src/ai/notification_settings.rs | done |  |
| COR-004 | AI session resume: extract provider and session id from `claude --resume <id>` / `codex resume <id>`, detect provider, normalize provider names, validate session ids. Used by: Overlay, Terminal, Debug, Monitoring, Notifications. | `AIResumeParser.swift` | `AIResumeParserTests` (17) | chau7_next_core/src/ai/resume.rs | done |  |
| COR-005 | Registry of AI CLI tools: display name, command names, output patterns, resume format, logo asset, tab color, event source. Rust mirrors only display name, command names and output patterns (`AI_TOOLS`); missing: resume format, logo, tab color map, event source, `tool(named:)`, `resumeProviderKey(for:)`. Used by: Terminal, App, AI, Debug, Notifications, Overlay, Settings, StatusBar (and Core: CommandDetection, AIResumeParser). | `AIToolRegistry.swift` | none | chau7_next_core/src/ai/tool_registry.rs, command_detection.rs | done |  |
| COR-006 | Hex color parsing and simple color math (RGB, 0..1 doubles). Used by: no direct reference in `Sources/Chau7` (Rust uses it for color schemes). | `ColorParsing.swift` | `ColorParsingTests` (30); Rust 31 | `chau7_next_core/src/color_parsing.rs` | done | |
| COR-007 | `CommandBlock` model: command text, line range, timing, exit code, directory, changed files; running/success/failed helpers. Used by: Rendering, Terminal, Analytics, Editor. | `CommandBlock.swift` | `CommandBlockTests` (21); also `CommandBlockOverlayTests` (25, mostly app types) | chau7_next_core/src/command_block.rs | done |  |
| COR-008 | AI CLI and dev server detection from command lines and output, tokenizer, env/sudo skipping, executable check; `EventParsing` for Claude Code hook JSON. Used by: Terminal, Overlay, Monitoring. | `CommandDetection.swift` | `CommandDetectionTests` (66); Rust 78 | `chau7_next_core/src/command_detection.rs` | done | |
| COR-009 | Risky command check: case-insensitive, whitespace-normalized substring match against patterns. Rust also ports the `DangerousCommandGuard` logic and its 28 tests. Used by: Commands, Terminal. | `CommandRiskDetection.swift` | `CommandRiskDetectionTests` (18); Rust 52 incl. guard | `chau7_next_core/src/command_risk.rs` | done | |
| COR-010 | Parser for the TOML-like `config.toml` (sections, key/value, comments, type inference). Used by: Settings. | `ConfigFileParser.swift` | `ConfigFileParserTests` (27); Rust 34 | `chau7_next_core/src/config.rs` | done | |
| COR-011 | Shared ISO 8601 formatter (fractional seconds) and `nowISO8601()`. Used by: Overlay, Runtime, AI, App, Debug, Monitoring, StatusBar, Utilities. | `DateFormatters.swift` | `DateFormattersTests` (9) | chau7_next_core/src/iso8601.rs | done |  |
| COR-012 | Bidirectional directory prefix rank (0 exact, 1 nested, nil unrelated) for matching events to tabs. Used by: Monitoring, Notifications, Overlay. | `DirectoryPathMatcher.swift` | `DirectoryPathMatcherTests` (4) | chau7_next_core/src/path_rank.rs | done |  |
| COR-013 | Strip terminal escape sequences (OSC, CSI, bracketed paste, control chars, collapse spaces) from text for logs and history; length-limited log variant. Used by: App, Monitoring, Telemetry, Terminal. | `EscapeSequenceSanitizer.swift` | `EscapeSequenceSanitizerTests` (39) | chau7_next_core/src/escape_sanitizer.rs | done |  |
| COR-014 | Length-prefixed (4-byte LE) frame stream parser for the remote relay, skips bad lengths, collects decode errors; `packForTransport`. Used by: Remote. | `FrameParser.swift` | `FrameParserTests` (12) | chau7_next_core/src/remote/frame_parser.rs | done |  |
| COR-015 | `HistoryEntryParser`: parse Claude/Codex history JSON lines into session id, timestamp, summary, exit flag, activity kind. Used by: History, App, Monitoring, StatusBar, Terminal. | `HistoryEntry.swift` | `HistoryEntryParserTests` (32) | chau7_next_core/src/history_events.rs | done |  |
| COR-016 | Resolve a working directory hint for history-monitor events from provider session metadata, for tab routing. Used by: App. | `HistoryEventContextResolver.swift` | `HistoryEventContextResolverTests` (4) | chau7_next_core/src/history_events.rs | done |  |
| COR-017 | `HistoryRecord` (persistent command record: command, directory, exit code, shell, tab, session, time, duration) and `FrequentCommand`. Rust has its own simpler `HistoryEntry` in `shell_integration.rs`, not a port. Used by: History, Analytics, DataExplorer, Scripting. | `HistoryRecord.swift` | `HistoryRecordTests` (12) | chau7_next_core/src/history_record.rs | done |  |
| COR-018 | History session lifecycle (active, idle, closed): decides persist, emit finished event, reactivation. Used by: App, Monitoring, Terminal. | `HistorySessionLifecycle.swift` | `HistorySessionLifecycleTests` (5) | chau7_next_core/src/history_events.rs | done |  |
| COR-019 | Drop truncated provider summary fragments (for example `rror`) unless the entry is an exit marker. Used by: App. | `HistorySummarySanitizer.swift` | `HistorySummarySanitizerTests` (4) | chau7_next_core/src/history_events.rs | done |  |
| COR-020 | Detect interactive AI prompts (question plus options) in terminal text for remote approval. Used by: Remote. | `InteractivePromptDetector.swift` | `InteractivePromptDetectorTests` (4) | chau7_next_core/src/interactive_prompt_detector.rs | done |  |
| COR-021 | Pretty-print a JSON string (nil when not JSON). Used by: StatusBar. | `JSONPrettyPrinter.swift` | `JSONPrettyPrinterTests` (15) | chau7_next_core/src/json_pretty.rs | done |  |
| COR-022 | Kitty progressive keyboard protocol: flag stack (push, pop, query, set), key event encoding with modifiers and event types. Used by: Keyboard. | `KittyKeyboardProtocol.swift` | `KittyKeyboardProtocolTests` (28) | chau7_next_core/src/kitty_keyboard.rs | done |  |
| COR-023 | LLM provider types, defaults (endpoint, model, API key need), config (API key excluded from Codable), request/response, error explanation and fix suggestion models for "Explain This Error". Used by: AI, Settings. | `LLMProvider.swift` | `LLMProviderTests` (32) | chau7_next_core/src/llm_provider.rs | done | Keychain (API key, app layer) |
| COR-024 | MCP permission mode enum (how unlisted MCP commands are handled) with display names. Used by: MCP, Settings. | `MCPPermissionMode.swift` | shared with COR-025 in `MCPProfileTests` | chau7_next_core/src/mcp_profile.rs | done |  |
| COR-025 | MCP profiles: scoped permission rules activated by a `ProfileSwitchTrigger` matching the tab context (directory, branch, SSH host, processes, env); approval result. Used by: MCP, Settings. | `MCPProfile.swift` | `MCPProfileTests` (25) | chau7_next_core/src/mcp_profile.rs | done |  |
| COR-026 | Timer math for monitors: next idle check, next history check, poll interval; notification identity, coalescing and rate-limit keys. Used by: Monitoring, Notifications. | `MonitoringSchedule.swift` | `MonitoringScheduleTests` (14) | chau7_next_core/src/notifications/schedule.rs | done |  |
| COR-027 | Catalog of 25 notification action types (notify, sound, focus, dock bounce, tab style, script, shortcut, snippet, webhook, Slack, Discord, Docker, Kubernetes, clipboard, file, URL, git commit, voice, flash, menu bar, timers) with categories, config fields and trigger bindings. Used by: Notifications, Settings. | `NotificationActionCatalog.swift` | `NotificationActionCatalogTests` (41) | chau7_next_core/src/notifications/actions.rs | done |  |
| COR-028 | Which notification actions need a resolved tab target; partition action lists by that. Used by: Notifications. | `NotificationActionRequirements.swift` | `NotificationActionRequirementsTests` (3) | chau7_next_core/src/notifications/action_requirements.rs | done |  |
| COR-029 | Delivery rules: authoritative routing types, drop after routing failure, authority keys and retention (180 s), fallback suppression. Used by: Notifications. | `NotificationDeliverySemantics.swift` | `NotificationDeliverySemanticsTests` (5) | chau7_next_core/src/notifications/delivery.rs | done |  |
| COR-030 | Prepare an `AIEvent` for delivery (tab resolution method, enrichment). Used by: Notifications. | `NotificationEventPreparation.swift` | `NotificationEventPreparationTests` (3) | chau7_next_core/src/notifications/delivery.rs (prepare) | done |  |
| COR-031 | Plan default, style-only and supplemental tab style actions for an event. Used by: Notifications. | `NotificationStylePlanner.swift` | `NotificationStylePlannerTests` (4) | chau7_next_core/src/notifications/delivery.rs (style planner) | done |  |
| COR-032 | Catalog of 40 notification triggers grouped by source, display flags (settings, activity, debug), trigger state and conditions. Used by: Notifications, Settings, StatusBar. | `NotificationTriggerCatalog.swift` | `NotificationTriggerCatalogTests` (61) | chau7_next_core/src/notifications/triggers.rs | done |  |
| COR-033 | Map raw event / notification types to canonical semantic kinds (normalized). Used by: Debug, StatusBar. | `Notifications/CanonicalNotificationMapping.swift` | `CanonicalNotificationMappingTests` (4) | chau7_next_core/src/notifications/canonical.rs (kind, normalize) | done |  |
| COR-034 | Canonical notification model: semantic kinds (attention-seeking flag), provider event, adapter protocol and result. Used by: StatusBar (and Core notification files). | `Notifications/CanonicalNotificationModel.swift` | `CanonicalNotificationModelTests` (4) | chau7_next_core/src/notifications/canonical.rs | done |  |
| COR-035 | Ingest an `AIEvent` into a shared event plus canonical event decision. Used by: App, Notifications. | `Notifications/NotificationIngress.swift` | `NotificationIngressTests` (6) | chau7_next_core/src/notifications/adapters.rs (ingest) | done |  |
| COR-036 | Registry of provider adapters (Claude, Codex, terminal, etc.) that translate events to canonical form or drop/defer them. Used by: Debug (and NotificationIngress). | `Notifications/NotificationProviderAdapterRegistry.swift` | `NotificationProviderAdapterRegistryTests` (10) | chau7_next_core/src/notifications/adapters.rs (adapt) | done |  |
| COR-037 | Decide whether a returning shell prompt means "AI finished" (suppress on resume prefill, restored provider, runtime-owned tab, no AI round trip). Used by: Terminal. | `Notifications/TerminalPromptNotificationAdapter.swift` | `TerminalPromptNotificationAdapterTests` (5) | chau7_next_core/src/terminal_prompt_notification.rs | done |  |
| COR-038 | Treat Option+key as literal text for non-letter base keys (international layouts typing `[` `{`), keep Meta for letters. Rust with `option_as_meta` sends ESC for every Option chord. Used by: RustBackend. | `OptionModifiedTextRouting.swift` | `OptionModifiedTextRoutingTests` (4) | chau7_next_core/src/option_text_routing.rs | done | NSEvent (characters) |
| COR-039 | Resolve which window a dragged tab drops onto. Used by: App. | `OverlayWindowDropResolver.swift` | `OverlayWindowDropResolverTests` (3) | `chau7_next_core/src/tab_bar_layout.rs` | done | |
| COR-040 | Profile auto-switch rules: triggers (directory, git repo, SSH host, running process, env var), priority, matching and summaries. Used by: Profiles, Settings (and Core: MCPProfile). | `ProfileSwitchRule.swift` | `ProfileSwitchRuleTests` (37) | chau7_next_core/src/profile_rules.rs | done |  |
| COR-041 | Project tab activity candidates into the single remote activity state (idle, running, waiting input, completed, failed, pending approval). Used by: Remote. | `RemoteActivityState.swift` | `RemoteActivityStateTests` (4) | chau7_next_core/src/remote/activity_state.rs | done |  |
| COR-042 | Remote relay binary frame: 20-byte header (version, type, flags, tab id, seq), encrypted flag, encode/decode. Used by: Remote. | `RemoteFrame.swift` | `RemoteFrameTests` (10) | chau7_next_core/src/remote/frame.rs | done |  |
| COR-043 | Remote interactive prompt payloads (prompt, options, destructive flag, tab and project context). Used by: Remote. | `RemoteInteractivePrompt.swift` | `RemoteInteractivePromptTests` (1) | chau7_next_core/src/remote/interactive_prompt.rs | done |  |
| COR-044 | Remote output limits (retained text, snapshot and frame caps, 33 ms flush) and per-tab pending output buffer. Used by: Remote. | `RemoteOutputBuffering.swift` | `RemoteOutputBufferingTests` (4) | chau7_next_core/src/remote/output_buffering.rs | done |  |
| COR-045 | Flag remote input that would kill Chau7 itself (kill, killall, pkill, launchctl, osascript). Used by: Remote. | `RemoteProtection.swift` | `RemoteProtectionTests` (5) | chau7_next_core/src/remote/protection.rs | done |  |
| COR-046 | Binary terminal grid snapshot for remote clients (`CHG1`, 29-byte header, 16-byte cells, cursor, scrollback). Used by: RustBackend. | `RemoteTerminalGridSnapshot.swift` | `RemoteTerminalGridSnapshotTests` (2) | chau7_next_core/src/remote/grid_snapshot.rs | done |  |
| COR-047 | `AgentBackend` protocol (launch command, prompt formatting, resume provider) and `SessionConfig`. Used by: Runtime. | `Runtime/AgentBackendProtocol.swift` | none dedicated (`BackendLaunchCommandTests` (4) test app backends) | chau7_next_core/src/runtime/ | done |  |
| COR-048 | Thread-safe ring buffer of runtime events with cursor-based polling. Used by: Runtime. | `Runtime/EventJournal.swift` | `EventJournalTests` (10) | chau7_next_core/src/runtime/ | done |  |
| COR-049 | Classify why an agent turn ended (interrupted, approval denied, failed, context limit, error patterns, success). Used by: Runtime. | `Runtime/ExitClassifier.swift` | `ExitClassifierTests` (11) | chau7_next_core/src/runtime/ | done |  |
| COR-050 | `RuntimeEvent` model (seq, session, turn, type, data) for `runtime_events_poll`. Used by: Runtime. | `Runtime/RuntimeEvent.swift` | none | chau7_next_core/src/runtime/ | done |  |
| COR-051 | Runtime session state machine (launching, ready, busy, waiting permission, waiting input, failed, ...). Used by: Runtime. | `Runtime/RuntimeSessionState.swift` | `RuntimeSessionStateTests` (27) | chau7_next_core/src/runtime/ | done |  |
| COR-052 | Per-turn tool tallies and token usage, flattened into `turn_completed` event data. Used by: Runtime. | `Runtime/TurnStats.swift` | `TurnStatsTests` (7) | chau7_next_core/src/runtime/ | done |  |
| COR-053 | Data paths with `CHAU7_HOME_ROOT` override and isolated test mode. Ported as a redesign (`DataRoot`, own folders, `CHAU7_NEXT_HOME_ROOT`, `CHAU7_NEXT_ISOLATED_TEST_MODE`, `CHAU7_NEXT_KEYCHAIN_SERVICE_PREFIX`). Swift tests ported (4 Rust tests). Used by: nearly every app module. | `RuntimeIsolation.swift` | `RuntimeIsolationTests` (5); Rust 4 | chau7_next_core/src/data_root.rs (expand_tilde, is_isolated_test_mode, keychain_service_name), chau7_next/src/platform/secrets.rs, chau7_next/src/platform/login_item.rs | done | Keychain (service name) |
| COR-054 | FFI wrapper loading `libchau7_parse.dylib` `chau7_risk_*` for command risk; nil when absent (pure fallback in COR-009). Used by: Core only. | `RustCommandRisk.swift` | `RustAnsiParserTests` (`RustCommandRiskTests`, 10) | | n/a | dlopen |
| COR-055 | FFI wrapper for the dylib escape sanitizer; nil when absent (fallback COR-013). Used by: Core only. | `RustEscapeSanitizer.swift` | `RustAnsiParserTests` (`RustEscapeSanitizerTests`, 9) | | n/a | dlopen |
| COR-056 | FFI wrapper for dylib output/wait pattern matching (first match, contains any); nil when absent. Used by: Terminal. | `RustPatternMatcher.swift` | `RustAnsiParserTests` (`RustPatternMatcherTests`, 22) | | n/a | dlopen |
| COR-057 | OpenSSH config parse and serialize (hosts, keys, options). Used by: Profiles, Settings. | `SSHConfigParser.swift` | `SSHConfigParserTests` (19); Rust 20 | `chau7_next_core/src/ssh_config.rs` | done | |
| COR-058 | Redact sensitive input (inline secrets, echo-disabled password input) before logs, history and analytics. Used by: Terminal, AI. | `SensitiveInputGuard.swift` | `SensitiveInputGuardTests` (7) | chau7_next_core/src/sensitive_input.rs | done |  |
| COR-059 | Session recording types: recorded frames (output, input, resize) and recording metadata. Used by: History. | `SessionRecording.swift` | `SessionRecordingTests` (18) | chau7_next_core/src/session_recording.rs | done |  |
| COR-060 | Shell argument escaping, path sanitizing and input validation against injection. Used by: Runtime, Commands, Profiles. | `ShellEscaping.swift` | `ShellEscapingTests` (39); Rust 40 | `chau7_next_core/src/shell_escaping.rs` | done | |
| COR-061 | Preferred `PATH` for launched shells, user home, user `ZDOTDIR`, user `XDG_CONFIG_HOME`. PATH and ZDOTDIR fallback ported (ZDOTDIR in `shell_integration.rs`); missing: `XDG_CONFIG_HOME` fallback to `~/.config` and its test. Used by: Terminal. | `ShellLaunchEnvironment.swift` | `ShellLaunchEnvironmentTests` (4); 3 have Rust equivalents | chau7_next_core/src/shell_env.rs | done |  |
| COR-062 | Snippet placeholder expansion and env token replacement. Used by: no direct reference in `Sources/Chau7` (Rust uses it for snippets). | `SnippetParsing.swift` | `SnippetParsingTests` (21); Rust 26 | `chau7_next_core/src/snippet_parsing.rs` | done | |
| COR-063 | Run a subprocess, return stdout, reap with `waitpid`. Used by: Monitoring. | `SubprocessRunner.swift` | `SubprocessRunnerTests` (2) | chau7_next_core/src/subprocess.rs | done |  |
| COR-064 | Tab bar layout (widths, overflow, items). Used by: Overlay. | `TabBarLayout.swift` | `TabBarLayoutTests` (6) | `chau7_next_core/src/tab_bar_layout.rs` | done | |
| COR-065 | Tab drag reorder geometry. Used by: Overlay. | `TabDragLayout.swift` | `TabDragLayoutTests` (4) | `chau7_next_core/src/tab_bar_layout.rs` | done | |
| COR-066 | `TabTarget` routing key (tool, directory, tab id, AI session id). Used by: Notifications, Overlay, App, StatusBar. | `TabTarget.swift` | none dedicated (`TabResolverTests` (2) test the app resolver) | chau7_next_core/src/tab_target.rs | done |  |
| COR-067 | Parse Claude transcript JSONL into model, turns, tool calls and deduplicated token usage. Used by: Telemetry, Runtime. | `Telemetry/ClaudeTranscriptUsageParser.swift` | `ClaudeTranscriptUsageParserTests` (1) | chau7_next_core/src/telemetry/ | done |  |
| COR-068 | Parse Codex rollout files into model, turns, tool calls and token usage. Used by: Telemetry. | `Telemetry/CodexRolloutParser.swift` | `CodexRolloutParserTests` (1) | chau7_next_core/src/telemetry/ | done |  |
| COR-069 | Telemetry event sent by remote (iOS) clients. Used by: Remote, Telemetry. | `Telemetry/RemoteClientTelemetryEvent.swift` | `RemoteClientTelemetryEventTests` (1) | chau7_next_core/src/telemetry/ | done |  |
| COR-070 | `RunContentProvider` protocol and `ExtractedRunContent` (per-provider transcript extraction). Used by: Telemetry. | `Telemetry/RunContentProvider.swift` | none | chau7_next_core/src/telemetry/ | done |  |
| COR-071 | Drop missing or implausible token totals from extracted run content, with a warning. Used by: Telemetry. | `Telemetry/TelemetryMetricsSanitizer.swift` | `TelemetryMetricsSanitizerTests` (2) | chau7_next_core/src/telemetry/ | done |  |
| COR-072 | `TelemetryRun` (one AI tool invocation: provider, model, cwd, repo, times, tokens, cost) and run filter. Used by: Telemetry, DataExplorer, MCP, Overlay. | `Telemetry/TelemetryRun.swift` | none | chau7_next_core/src/telemetry/ | done |  |
| COR-073 | `TelemetryTurn` and `TelemetryToolCall` (per-turn content, tokens, tool calls, status). Used by: Telemetry. | `Telemetry/TelemetryTurn.swift` | none | chau7_next_core/src/telemetry/ | done |  |
| COR-074 | `TokenUsage` accounting (input, cached, output, reasoning) and metric/cost source enums. Used by: Proxy, Telemetry (and Core: TurnStats, telemetry parsers). | `Telemetry/TokenMetrics.swift` | none | chau7_next_core/src/telemetry/ | done |  |
| COR-075 | Parse key specs (`key` plus `shift`/`ctrl`/`alt` names) and encode them to terminal bytes, rejecting unsupported keys and combos (MCP send keys). Rust `key_encoding.rs` covers the encoding from key events; missing: string spec parsing, rejection errors, Ctrl+Backspace as BS. Used by: Terminal, MCP, RustBackend. | `TerminalKeyPress.swift` | `TerminalKeyPressTests` (8); 5 have Rust equivalents | chau7_next_core/src/terminal_key_press.rs, key_encoding.rs | done |  |
| COR-076 | Token optimization (CTO): global mode, per-tab override, activation decision and reason, gain stats, runtime health assessment, per-tab consumption. Used by: TokenOptimization, Overlay, Settings, Debug, MCP, Telemetry, Terminal. | `TokenOptimization.swift` | `TokenOptimizationTests` (34, mixed with app `CTOManager` / `CTORuntimeMonitor` tests) | chau7_next_core/src/token_optimization.rs | done |  |

## Notes

- Counts: 76 rows. done 10, partial 4, missing 59, n/a 3. Swift test
  methods counted in the Tests column: 950; with a Rust port: 242 (233 in
  done rows, about 9 equivalents in partial rows).
- Cross-cutting test files also exercise Core types and are not counted
  above: `IntegrationTests` (14), `PerformanceTests` (14),
  `PropertyBasedTests` (7), `SendableTests` (10). Port the relevant cases with
  the row they touch.
- "Used by" comes from a grep of the type names in
  `apps/chau7-macos/Sources/Chau7/`, ordered by number of files where it
  matters. Core-internal dependencies: `AIEvent` and `AIToolRegistry` feed
  most notification, history and resume rows; `TokenMetrics` feeds
  `TurnStats` and the telemetry rows; `ProfileSwitchRule` feeds `MCPProfile`;
  `RemoteInteractivePrompt` feeds `InteractivePromptDetector`; port those
  first within their wave.
- COR-054 to COR-056 are `n/a`: they `dlopen` `libchau7_parse.dylib`, whose
  symbols have no implementation in the repo; Swift falls back to pure code
  (COR-009, COR-013). Chau7 Next links Rust crates directly. The pattern
  matching behavior itself belongs to the Terminal rows that use it.
- COR-053 and COR-061 are listed as done in `PARITY.md`; here they are
  `partial` because not all Swift functions and tests have counterparts.
  `DataRoot` is a deliberate redesign (see `DUAL-SHIP.md`): do not make it
  share Swift paths.
- COR-005: when porting resume, logos or tab colors, extend `AI_TOOLS` in
  `command_detection.rs` rather than adding a second table.
- COR-075: Swift `TerminalKeyPress` always ESC-prefixes Alt; Rust composes
  with Option unless `option_as_meta` is on. MCP send keys should keep the
  Swift behavior.
