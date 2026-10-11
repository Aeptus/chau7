# Runtime

Swift: `apps/chau7-macos/Sources/Chau7/Runtime/` (7 files, 1,822 lines), plus pure logic in `Chau7Core/Runtime/` (`RuntimeSessionState.swift`, `RuntimeEvent.swift`, `EventJournal.swift`, `ExitClassifier.swift`, `TurnStats.swift`, `AgentBackendProtocol.swift`)
Swift tests: `Runtime/BackendLaunchCommandTests.swift`, `Runtime/EventJournalTests.swift`, `Runtime/ExitClassifierTests.swift`, `Runtime/RuntimeControlServiceTests.swift`, `Runtime/RuntimeSessionManagerTests.swift`, `Runtime/RuntimeSessionStateTests.swift`, `Runtime/TurnStatsTests.swift`
Wave: 3 (see README.md)
Depends on: MCP (it is only reachable through the `runtime_*` MCP tools), AI (Claude Code hook events from `ClaudeCodeMonitor`), Notifications, Overlay, Terminal

The agent runtime lets one AI agent drive others: through MCP an orchestrator starts a Claude Code, Codex or plain shell session in a Chau7 tab, sends it prompts turn by turn, polls a structured event stream, and answers its permission prompts. Chau7 tracks each session with a state machine fed by Claude Code hook events, counts tools, files and tokens per turn, and classifies why each turn ended. Claude Code sessions a user starts by hand are adopted automatically so their events are tracked too.

## Features

| ID | Feature | Swift source | Tests | Rust | Status | macOS API |
|---|---|---|---|---|---|---|
| RUN-001 | Claude backend launches `claude [--resume ID] [--dangerously-skip-permissions] [--model M] <args>` with shell escaping and an `ENV=value` prefix | `Runtime/Backends/ClaudeCodeBackend.swift` | `BackendLaunchCommandTests` | `chau7_next_core/src/runtime/backends.rs` | done |  |
| RUN-002 | Codex backend launches `codex [resume ID] [--full-auto] [--model M] <args>` | `Runtime/Backends/CodexBackend.swift` | `BackendLaunchCommandTests` | `chau7_next_core/src/runtime/backends.rs` | done |  |
| RUN-003 | Shell backend runs `backend_args` as the command, with no turn semantics (orchestrator drives it with `tab_send_input`) | `Runtime/Backends/GenericShellBackend.swift` | `BackendLaunchCommandTests` | `chau7_next_core/src/runtime/backends.rs` | done |  |
| RUN-004 | Backend registry (`claude` default, `codex`, `shell`); unknown backend error lists the valid names | `Runtime/RuntimeControlService.swift` |  | `chau7_next_core/src/runtime/backends.rs`, `chau7_next/src/runtime/control.rs` | done |  |
| RUN-005 | Model check rejects cross-backend models (Claude names on Codex, OpenAI names on Claude) and empty names | `Runtime/RuntimeControlService.swift` |  | `chau7_next_core/src/runtime/backends.rs`, `chau7_next/src/runtime/control.rs` | done |  |
| RUN-006 | Refuses to start when `claude` or `codex` is not on PATH (checked with `/usr/bin/which`), except when attaching to a tab | `Runtime/RuntimeControlService.swift` |  | `chau7_next/src/runtime/control.rs` | done |  |
| RUN-007 | New session opens a background MCP tab in `directory`, runs the launch command there through `tab_exec`, and marks the session ready | `Runtime/RuntimeControlService.swift`, `Runtime/RuntimeSessionManager.swift` | `RuntimeControlServiceTests` | `chau7_next/src/runtime/control.rs`, `chau7_next_core/src/runtime/manager.rs` | done |  |
| RUN-008 | `attach_tab_id` adopts an existing tab as a passive session (no launch, starts ready) | `Runtime/RuntimeControlService.swift` | `RuntimeControlServiceTests` | `chau7_next/src/runtime/control.rs`, `chau7_next_core/src/runtime/manager.rs` | done |  |
| RUN-009 | `initial_prompt` delivered once the session is ready: up to 8 tries, 0.3 s then 0.5 s apart (about 4 s); journals `initial_prompt_failed` on timeout or early stop | `Runtime/RuntimeControlService.swift` |  | `chau7_next/src/runtime/control.rs` | done |  |
| RUN-010 | Session state machine: starting, ready, busy, awaitingApproval, waitingInput, interrupted, failed, stopped, with a fixed transition table; failed and stopped are final | `Chau7Core/Runtime/RuntimeSessionState.swift`, `Runtime/RuntimeSession.swift` | `RuntimeSessionStateTests` | `chau7_next_core/src/runtime/session.rs`, `chau7_next_core/src/runtime/session_state.rs` | done |  |
| RUN-011 | Turns: only accepted in `ready`; ids `t_1`, `t_2`...; prompt sent as `<context>\n\n<prompt>\n` (or `<prompt>\n`) to the PTY; reply has `turn_id`, `status:"accepted"`, `session_state`, `cursor` | `Runtime/RuntimeSession.swift`, `Runtime/RuntimeControlService.swift` | `RuntimeControlServiceTests` | `chau7_next_core/src/runtime/session.rs`, `chau7_next/src/runtime/control.rs` | done |  |
| RUN-012 | Per-session event journal: ring buffer of 1,000 events, increasing `seq`, cursor polling with `has_more` | `Chau7Core/Runtime/EventJournal.swift` | `EventJournalTests` | `chau7_next_core/src/runtime/event_journal.rs` | done |  |
| RUN-013 | Claude Code hook events drive sessions: tool start opens a turn and journals `tool_use`; tool complete journals `tool_result`; user prompt opens a turn (`agent_responding`); notification journals `notification`; response complete closes the turn with an `output_chunk` (first 4,096 chars of the last 50 lines); session end stops it | `Runtime/RuntimeSessionManager.swift` | `RuntimeSessionManagerTests` | `chau7_next_core/src/runtime/manager.rs`, `chau7_next/src/runtime/mod.rs`, `chau7_next/src/ai/hub.rs` | done |  |
| RUN-014 | Unknown Claude Code sessions are adopted automatically by matching the event's cwd to a tab; each Claude session id is bound to one runtime session, preferring the one with an active or most recent turn when several share a directory | `Runtime/RuntimeSessionManager.swift` | `RuntimeSessionManagerTests` | `chau7_next_core/src/runtime/manager.rs`, `chau7_next/src/runtime/mod.rs` | done |  |
| RUN-015 | Permission requests become a pending approval (`approval_needed`, state awaitingApproval); `runtime_approval_respond` types `y\n` or `n\n`, journals `approval_resolved` and clears the tab's persistent notification style | `Runtime/RuntimeSession.swift`, `Runtime/RuntimeControlService.swift` |  | `chau7_next_core/src/runtime/session.rs`, `chau7_next/src/runtime/control.rs` | done |  |
| RUN-016 | Two-layer auto-approve: CLI flag (`--dangerously-skip-permissions` / `--full-auto`) plus automatic `y\n` answer to any permission request that still shows up | `Runtime/RuntimeSessionManager.swift`, `Runtime/Backends/*` |  | `chau7_next_core/src/runtime/manager.rs`, `chau7_next_core/src/runtime/backends.rs` | done |  |
| RUN-017 | Turn stats: tool calls, tool names, unique files touched, input/output/cache tokens, total tokens, reported in `turn_completed` | `Chau7Core/Runtime/TurnStats.swift`, `Runtime/RuntimeSession.swift` | `TurnStatsTests` | `chau7_next_core/src/runtime/turn_stats.rs`, `chau7_next_core/src/runtime/session.rs` | done |  |
| RUN-018 | Token usage read incrementally from Claude Code transcripts under `~/.claude/projects/`, deduplicated per request | `Runtime/IncrementalTranscriptReader.swift` |  | `chau7_next_core/src/runtime/transcript_reader.rs`, `chau7_next_core/src/runtime/manager.rs` | done |  |
| RUN-019 | Turn exit reason: interrupted, approval_denied, error (failed state or `error:`/`fatal:`/`panic:`/`unhandled exception` in output), context_limit (`context window`, `token limit`, `context limit`, `max context`), success | `Chau7Core/Runtime/ExitClassifier.swift` | `ExitClassifierTests` | `chau7_next_core/src/runtime/exit_classifier.rs`, `chau7_next_core/src/runtime/session.rs` | done |  |
| RUN-020 | Runtime posts notifications: `tool_called`, `file_edited` (Write, Edit, NotebookEdit, Bash), `permission` / `permission_auto_approved` and `waiting_input` (non-Claude backends only), `token_threshold` (turn over 100,000 tokens), `context_limit` / `failed` | `Runtime/RuntimeSessionManager.swift` |  | `chau7_next_core/src/runtime/manager.rs`, `chau7_next/src/runtime/mod.rs` | done |  |
| RUN-021 | Stop session: Ctrl+C when forced or busy/awaiting approval, journals `session_stopped`, optional tab close; stopped sessions stay queryable for 10 minutes | `Runtime/RuntimeControlService.swift`, `Runtime/RuntimeSessionManager.swift` | `RuntimeSessionManagerTests` | `chau7_next/src/runtime/control.rs`, `chau7_next_core/src/runtime/manager.rs` | done |  |
| RUN-022 | Every 30 s: sessions whose tab was closed become stopped (`reason: tab_closed`) and old stopped sessions are dropped | `Runtime/RuntimeSessionManager.swift` |  | `chau7_next_core/src/runtime/manager.rs`, `chau7_next/src/runtime/mod.rs` | done |  |
| RUN-023 | Runtime-owned tabs: Claude notifications route to the runtime session's tab, and the terminal-prompt `waiting_input` fallback knows the tab is runtime owned | `App/AppModel.swift`, `Terminal/Session/TerminalSessionModel+ShellIntegration.swift` |  | `chau7_next/src/runtime/mod.rs`, `chau7_next/src/ai/hub.rs`, `chau7_next_core/src/shell_session.rs` | done |  |
| RUN-024 | Session summary returned by create/list/get: `session_id` (`rs_` + 8 hex), `tab_id`, `backend`, `state`, `directory`, `turn_count`, `adopted`, `auto_approve`, `created_at`, `cursor`, `current_turn_id`, `pending_approval` | `Runtime/RuntimeSession.swift` |  | `chau7_next_core/src/runtime/session.rs` | done |  |

| RUN-025 | Delegated session purpose, parent session/run, metadata, schema and hierarchy validation; default allow_child_delegation=true and max_depth=4 | `Chau7Core/Runtime/DelegatedTask.swift`; `Runtime/RuntimeControlService.swift` | RuntimeDelegationPolicyTests | chau7_next/src/runtime/; chau7_next_core/src/runtime/ | missing |  |
| RUN-026 | Enforce max turns/duration/delegation depth and tool allow/block rules; network/file-write flags remain advisory exactly as Swift documents | `Chau7Core/Runtime/DelegatedTask.swift`; `Runtime/RuntimeSession.swift` | RuntimeDelegationPolicyTests | chau7_next/src/runtime/; chau7_next_core/src/runtime/ | missing |  |
| RUN-027 | Query/cancel child sessions and retry completed/failed task without losing parent attribution | `Runtime/RuntimeControlService.swift`; `Runtime/RuntimeSessionManager.swift` | RuntimeControlServiceTests | chau7_next/src/runtime/; chau7_next_core/src/runtime/ | missing |  |
| RUN-028 | Capture structured JSON result from backend final output/fenced content; validate supplied schema and expose available/invalid/missing status and validation errors | `Chau7Core/Runtime/StructuredResultExtractor.swift`; `Runtime/RuntimeSession.swift` | StructuredResultExtractorTests | chau7_next/src/runtime/; chau7_next_core/src/runtime/ | missing |  |
| RUN-029 | runtime_turn_wait waits for settled result/state with timeout, journals completion and preserves current/latest result | `Runtime/RuntimeControlService.swift` | RuntimeControlServiceTests | chau7_next/src/runtime/; chau7_next_core/src/runtime/ | missing |  |
| RUN-030 | Code review template for base/head commits or staged diff emits documented finding schema and restrictive default delegation policy | `Chau7Core/Runtime/CodeReviewTaskTemplate.swift` | CodeReviewTaskTemplateTests | chau7_next/src/runtime/; chau7_next_core/src/runtime/ | missing |  |
| RUN-031 | Launch readiness waits for matching provider process/active run and shell completion before initial prompt; code_review has explicit startup exception | `Chau7Core/Runtime/RuntimeLaunchReadiness.swift`; `Runtime/RuntimeControlService.swift` | RuntimeLaunchReadinessTests | chau7_next/src/runtime/; chau7_next_core/src/runtime/ | partial |  |
| RUN-032 | Codex backend structured feedback/approval/usage lifecycle reaches same runtime states as Claude; adoption cooldown prevents repeated false sessions | `Runtime/Backends/CodexBackend.swift`; `Runtime/RuntimeSessionManager.swift` | RuntimeSessionManagerAdoptionCooldownTests; AISessionBindingPolicyTests | chau7_next/src/runtime/; chau7_next_core/src/runtime/ | partial |  |

## Notes

- Rust layout: pure logic in `chau7_next_core::runtime` (`backends`, `session`,
  `manager` with a `RuntimeHost` trait for what it asks of the app,
  `transcript_reader`); the app side in `chau7_next/src/runtime/` (the shared
  registry, the main-thread host, the 30 s cleanup, the MCP tools in
  `control.rs`). The AI hub feeds every Claude Code hook event to
  `runtime::handle_claude_event` before routing it, and sets the event's tab to the
  runtime session's tab (`notification_tab_for_claude_session`).
- `RuntimeSessionManagerTests.testUserPromptStartsTurnForAdoptedClaudeSession`
  creates a `starting` session, which cannot take a turn; the Rust port of the
  test adopts the session (ready), which is what its name says.
- RUN-006: Swift runs `/usr/bin/which <cli>`; Rust searches the app's `PATH`
  for an executable file of that name (same answer, works on every OS).
- Runtime is only reachable through MCP; there is no UI. Port it with or after MCP.
- State values on the wire (`state`, `session_state`, `from`/`to` in
  `state_changed`): `starting`, `ready`, `busy`, `awaitingApproval`,
  `waitingInput`, `interrupted`, `failed`, `stopped` (camelCase, Swift raw values).
- Transition table (anything else is rejected and logged at debug):
  starting: backendReady→ready, launchTimeout→failed, processCrashed→failed, tabClosed→stopped.
  ready: turnSubmitted→busy, tabClosed→stopped.
  busy: turnCompleted→ready, approvalNeeded→awaitingApproval, inputRequested→waitingInput, interrupted→interrupted, processCrashed→failed, tabClosed→stopped.
  awaitingApproval: approvalResolved→busy, interrupted→interrupted, tabClosed→stopped.
  waitingInput: inputProvided→busy, tabClosed→stopped.
  interrupted: backendReady→ready, processCrashed→failed, tabClosed→stopped.
- Event wire format (`runtime_events_poll`): `{events:[{seq, session_id, timestamp (ISO 8601), type, turn_id?, data?}], cursor, has_more, session_state}`.
  `data` is a string to string map (numbers are strings). Event types:
  `session_starting`, `session_ready`, `session_stopped`, `session_error`,
  `state_changed`, `turn_started` (`prompt_length`), `turn_completed`
  (`tool_count`, `tools_used` comma-joined, `input_tokens`, `output_tokens`,
  `cache_creation_tokens`, `cache_read_tokens`, `total_tokens`,
  `files_touched`, `exit_reason`, `summary`), `turn_failed`, `agent_responding`,
  `notification`, `tool_use`, `tool_result`, `output_chunk`, `approval_needed`
  (`approval_id`, `tool`, `description`), `approval_resolved` (`approval_id`,
  `approved` "true"/"false", `resolved_by`), `initial_prompt_failed`. Also
  defined but never emitted: `stall_detected`, `token_threshold`,
  `cost_threshold`, `exit_classified`.
- Journal cursor: `seq` starts at 1; poll returns events with `seq > cursor`; if
  the ring buffer wrapped past the cursor, polling resumes at the oldest kept event.
- `turn_send` error when not ready: `{"error":"Session <id> is not ready (state: <state>). Wait for ready state."}`.
- `runtime_session_stop` reply: `{ok, session_id, final_state}`; `runtime_approval_respond`: `{ok:true, approved}`.
- Transcript reader: project dir is found by turning the cwd's `/` into `-` and
  matching entries of `~/.claude/projects/` (exact, suffix, or last two path
  parts); session dir is `<project>/<sessionID>` or the entry starting with the
  first 8 chars of the id. It only reads `*.jsonl` under `<session>/subagents/`,
  keeps a byte offset per file, consumes only complete lines, counts assistant
  messages' `usage.input_tokens`, `output_tokens`, `cache_creation_input_tokens`,
  `cache_read_input_tokens`, and dedupes by `ClaudeTranscriptUsageParser.requestUsageKey`.
  Read-only on `~/.claude`, safe for side-by-side use.
- `directory` defaults to the app's current directory when omitted (Swift
  `FileManager.currentDirectoryPath`), which is usually `/`.
- Sessions live in memory only; nothing is persisted across restarts.
- `markReady` is called right after the launch command is sent, not when the
  CLI is actually up; the initial prompt retry hides that.
