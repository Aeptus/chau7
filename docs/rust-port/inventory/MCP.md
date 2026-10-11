# MCP

Swift: `apps/chau7-macos/Sources/Chau7/MCP/` (5 files, 2,394 lines), plus `tools/chau7-mcp-bridge/main.swift` (bridge), `Chau7Core/MCPProfile.swift`, `Chau7Core/MCPPermissionMode.swift`, settings UI in `Settings/Views/MCPSettingsView.swift`
Swift tests: `MCP/MCPCommandFilterTests.swift`, `MCP/MCPProfileTests.swift` (also `MCPApprovalResultTests`, `MCPPermissionModeTests`, `MCPTabContextTests`), `MCP/TerminalControlServiceTests.swift`
Wave: 3 (see README.md)
Depends on: Overlay, Terminal (done); Telemetry (run_* and session_* tools), Repository and History (repo_* tools), TokenOptimization (tab_set_cto), Remote (iOS approval), Profiles (`ProfileSwitchRule` matching), Settings, Runtime (runtime_* tools)

Chau7 runs an MCP server on a Unix socket so AI agents (Claude Code, Codex, Cursor, Windsurf) can list, open, drive and read terminal tabs, query AI run telemetry, keep per-repo notes and orchestrate other agents. A small bridge binary turns the agent's stdio into the socket connection, and Chau7 registers that bridge in each agent's config on launch. Every command an agent runs can be filtered by allow/block lists, profiles and an approval dialog.

## Features

| ID | Feature | Swift source | Tests | Rust | Status | macOS API |
|---|---|---|---|---|---|---|
| MCP-001 | MCP server listens on `~/.chau7/mcp.sock` while the app runs (stale socket removed, mode 0600, backlog 5, one session per client, closed on quit) | `MCP/MCPServerManager.swift` |  | `chau7_next/src/mcp/server.rs`, `chau7_next/src/platform/local_socket.rs` | done | Unix sockets |
| MCP-002 | JSON-RPC 2.0 session over the socket: `initialize`, `notifications/initialized`, `tools/list`, `tools/call`, `resources/list`, `resources/read`, `ping`; parse errors and unknown methods return JSON-RPC errors | `MCP/MCPSession.swift` |  | `chau7_next_core/src/mcp/protocol.rs`, `chau7_next/src/mcp/server.rs` | done |  |
| MCP-003 | Bridge binary `chau7-mcp-bridge`: pipes stdin/stdout to the socket; prints a JSON-RPC error "Chau7 is not running. Start the app to enable MCP." and exits 1 when the app is not running | `tools/chau7-mcp-bridge/main.swift` |  | `chau7_next_mcp_bridge/src/main.rs`, `chau7_next_core/src/mcp/mod.rs` | done | Unix sockets |
| MCP-004 | Bridge is copied from the app bundle to `~/.chau7/bin/chau7-mcp-bridge` (mode 755) on every launch; skipped in dev builds without the bundled bridge | `MCP/MCPServerManager.swift` |  | `chau7_next/src/mcp/install.rs`, `apps/chau7-next/scripts/bundle-macos.sh` | done |  |
| MCP-005 | Registers the server in Claude Code `~/.claude.json` (`mcpServers.chau7`), only if `~/.claude.json` or `~/.claude/` exists | `MCP/MCPServerManager.swift` |  | `chau7_next_core/src/mcp/client_config.rs`, `chau7_next/src/mcp/install.rs` | done |  |
| MCP-006 | Registers the server in Codex `~/.codex/config.toml` (`[mcp_servers.chau7]`), only if the file exists; updates `command` when the section is already there | `MCP/MCPServerManager.swift` |  | `chau7_next_core/src/mcp/client_config.rs`, `chau7_next/src/mcp/install.rs` | done |  |
| MCP-007 | Registers the server in Cursor `~/.cursor/mcp.json`, only if `~/.cursor/` exists | `MCP/MCPServerManager.swift` |  | `chau7_next_core/src/mcp/client_config.rs`, `chau7_next/src/mcp/install.rs` | done |  |
| MCP-008 | Registers the server in Windsurf `~/.codeium/windsurf/mcp_config.json`, only if `~/.codeium/windsurf/` exists | `MCP/MCPServerManager.swift` |  | `chau7_next_core/src/mcp/client_config.rs`, `chau7_next/src/mcp/install.rs` | done |  |
| MCP-009 | Tool `run_get`: one telemetry run by `run_id` (active runs checked first) | `MCP/MCPSession.swift`, `MCP/TelemetryQueryService.swift` |  | `chau7_next/src/mcp/tools/telemetry.rs`, `chau7_next/src/mcp/sources.rs`, chau7_next/src/telemetry.rs | done |  |
| MCP-010 | Tool `run_list`: runs filtered by `session_id`, `repo_path`, `provider`, `after`/`before` (ISO 8601), `tags`, `limit` (default 50), `offset`; in-progress runs prepended | `MCP/TelemetryQueryService.swift` |  | `chau7_next/src/mcp/tools/telemetry.rs`, `chau7_next/src/mcp/sources.rs`, chau7_next/src/telemetry.rs | done |  |
| MCP-011 | Tool `run_tool_calls`: all tool calls of a run | `MCP/TelemetryQueryService.swift` |  | `chau7_next/src/mcp/tools/telemetry.rs`, chau7_next/src/telemetry.rs | done |  |
| MCP-012 | Tool `run_transcript`: conversation turns of a run | `MCP/TelemetryQueryService.swift` |  | `chau7_next/src/mcp/tools/telemetry.rs`, chau7_next/src/telemetry.rs | done |  |
| MCP-013 | Tool `run_tag`: replace a run's tags | `MCP/TelemetryQueryService.swift` |  | `chau7_next/src/mcp/tools/telemetry.rs`, chau7_next/src/telemetry.rs | done |  |
| MCP-014 | Tool `run_latest_for_repo`: most recent run for `repo_path`, optional `provider` | `MCP/TelemetryQueryService.swift` |  | `chau7_next/src/mcp/tools/telemetry.rs`, chau7_next/src/telemetry.rs | done |  |
| MCP-015 | Tool `session_list`: AI sessions with run counts, optional `repo_path`, `active_only` | `MCP/TelemetryQueryService.swift` |  | `chau7_next/src/mcp/tools/telemetry.rs`, chau7_next/src/telemetry.rs | done |  |
| MCP-016 | Tool `session_current`: currently active AI runs | `MCP/TelemetryQueryService.swift` |  | `chau7_next/src/mcp/tools/telemetry.rs`, chau7_next/src/telemetry.rs | done |  |
| MCP-017 | Tool `tab_list`: every tab in every window with `window_id`, title, status, cwd, prompt state, MCP flag, CTO state, active app, git branch, repo root/description/labels (`status`/`is_at_prompt` follow the AI CLI's history state, `effectiveStatus`) | `MCP/TerminalControlService.swift` | `TerminalControlServiceTests` | `chau7_next/src/mcp/tools/tabs.rs`, `chau7_next/src/workspace/mcp.rs`, `chau7_next_core/src/history_monitor.rs` | done |  |
| MCP-018 | Tool `tab_create`: opens a background tab (optional `directory`, `window_id`), marks it MCP-controlled, groups it by repo, returns `tab_id` and `shell_loading`; refused when MCP is disabled, the directory does not exist, or the MCP tab limit is reached | `MCP/TerminalControlService.swift` | `TerminalControlServiceTests` | `chau7_next/src/mcp/tools/tabs.rs`, `chau7_next/src/workspace/mcp.rs` | done |  |
| MCP-019 | Tool `tab_exec`: runs a command in a tab at the prompt; queued if the shell is still loading; error if a process is running; passes the command filter first | `MCP/TerminalControlService.swift` |  | `chau7_next/src/mcp/tools/tabs.rs`, `chau7_next/src/mcp/approval.rs` | done |  |
| MCP-020 | Tool `tab_status`: tab summary plus `shell_loading`, child processes (pid, name, cpu, rss) and the active telemetry run, keyed by the focused terminal's `tab_identifier` as in Swift (status as MCP-017) | `MCP/TerminalControlService.swift` | `TerminalControlServiceTests` | chau7_next/src/mcp/tools/tabs.rs (status), chau7_next/src/workspace/mcp.rs, chau7_next/src/telemetry.rs (McpTelemetry) | done |  |
| MCP-021 | Tool `tab_send_input`: raw text to the PTY, no newline added; filtered when it ends with a newline and is longer than 2 characters | `MCP/TerminalControlService.swift` |  | `chau7_next/src/mcp/tools/tabs.rs` | done |  |
| MCP-022 | Tool `tab_press_key`: named key (enter, escape, tab, arrows, backspace, delete, home, end, page_up/down, insert, or one character) with shift/control/alt modifiers | `MCP/TerminalControlService.swift`, `Chau7Core/TerminalKeyPress` |  | `chau7_next/src/mcp/tools/tabs.rs`, `chau7_next_core/src/terminal_key_press.rs` | done |  |
| MCP-023 | Tool `tab_submit_prompt`: presses Enter in a tab | `MCP/TerminalControlService.swift` |  | `chau7_next/src/mcp/tools/tabs.rs` | done |  |
| MCP-024 | Tool `tab_close`: closes a tab without the warning; refuses if a process is running or waiting for input unless `force` | `MCP/TerminalControlService.swift` |  | `chau7_next/src/mcp/tools/tabs.rs`, `chau7_next/src/workspace/mcp.rs` | done |  |
| MCP-025 | Tool `tab_output`: last N lines (default 50, max 10,000, 512 KB cap) from the scrollback, or from the ANSI-stripped AI PTY log with `source=pty_log`; `wait_for_stable_ms` (max 30 s) waits until output stops changing | `MCP/TerminalControlService.swift` |  | `chau7_next/src/mcp/tools/tabs.rs`, `chau7_next_core/src/mcp/output.rs`, `chau7_next/src/ai/session_log.rs` (last_ai_log_path) | done |  |
| MCP-026 | Tool `tab_set_cto`: per-tab token optimization override `default`/`forceOn`/`forceOff`; refused when token optimization is off globally (partial: the global mode is the TokenOptimization stub (off), so it is always refused; flag file recalculation waits for TokenOptimization) | `MCP/TerminalControlService.swift` |  | chau7_next/src/workspace/mcp.rs | done |  |
| MCP-027 | Tool `tab_rename`: sets or clears (empty string) a tab's custom title on every split of the tab | `MCP/TerminalControlService.swift` | `TerminalControlServiceTests` | `chau7_next/src/mcp/tools/tabs.rs`, `chau7_next/src/workspace/mcp.rs` | done |  |
| MCP-028 | Tool `repo_get_metadata`: description, labels, favorite files, top 10 frequent commands and repo stats (commands, success rate, runs, tokens, cost, top tools) | `MCP/TerminalControlService.swift` |  | `chau7_next/src/mcp/tools/repo.rs`, `chau7_next/src/seams.rs` (HistoryDb with the telemetry store), `chau7_next/src/telemetry.rs` (ai_repo_stats) | done |  |
| MCP-029 | Tool `repo_set_metadata`: updates only the given fields (description, labels, favorite files); Rust writes them to its own metadata overlay, never to the repo | `MCP/TerminalControlService.swift` |  | `chau7_next/src/mcp/tools/repo.rs` | done |  |
| MCP-030 | Tool `repo_frequent_commands`: commands for a repo sorted by frecency (`limit` default 20) | `MCP/TerminalControlService.swift` |  | `chau7_next/src/mcp/tools/repo.rs`, `chau7_next/src/seams.rs` (HistoryDb), `chau7_next_core/src/history_store.rs` (frequent_commands_for_repo) | done |  |
| MCP-031 | Tool `runtime_session_create`: starts an agent session (see Runtime.md) | `MCP/MCPSession.swift`, `Runtime/RuntimeControlService.swift` | `RuntimeControlServiceTests` | `chau7_next/src/mcp/tools/runtime.rs`, `chau7_next/src/runtime/control.rs` | done |  |
| MCP-032 | Tool `runtime_session_list`: active sessions, optional `include_stopped` | `Runtime/RuntimeControlService.swift` |  | `chau7_next/src/mcp/tools/runtime.rs`, `chau7_next/src/runtime/control.rs` | done |  |
| MCP-033 | Tool `runtime_session_get`: one session's state | `Runtime/RuntimeControlService.swift` |  | `chau7_next/src/mcp/tools/runtime.rs`, `chau7_next/src/runtime/control.rs` | done |  |
| MCP-034 | Tool `runtime_session_stop`: stops a session, optional `close_tab` and `force` (Ctrl+C) | `Runtime/RuntimeControlService.swift` |  | `chau7_next/src/mcp/tools/runtime.rs`, `chau7_next/src/runtime/control.rs` | done |  |
| MCP-035 | Tool `runtime_turn_send`: sends a prompt (optional `context`) to a ready session | `Runtime/RuntimeControlService.swift` | `RuntimeControlServiceTests` | `chau7_next/src/mcp/tools/runtime.rs`, `chau7_next/src/runtime/control.rs` | done |  |
| MCP-036 | Tool `runtime_turn_status`: state, turn count, current turn, last exit reason, pending approval | `Runtime/RuntimeControlService.swift` |  | `chau7_next/src/mcp/tools/runtime.rs`, `chau7_next/src/runtime/control.rs` | done |  |
| MCP-037 | Tool `runtime_events_poll`: journal events after a cursor (`limit` default 50) | `Runtime/RuntimeControlService.swift` |  | `chau7_next/src/mcp/tools/runtime.rs`, `chau7_next/src/runtime/control.rs` | done |  |
| MCP-038 | Tool `runtime_approval_respond`: approve or deny a pending tool permission | `Runtime/RuntimeControlService.swift` |  | `chau7_next/src/mcp/tools/runtime.rs`, `chau7_next/src/runtime/control.rs` | done |  |
| MCP-039 | Resources `chau7://telemetry/runs` (last 20), `chau7://telemetry/runs/<id>`, `chau7://telemetry/sessions`, `chau7://telemetry/sessions/current` | `MCP/MCPSession.swift` |  | `chau7_next/src/mcp/tools/telemetry.rs`, chau7_next/src/telemetry.rs | done |  |
| MCP-040 | Command filter splits on `;`, `&&`, `\|\|`, `\|`, `&`, newlines and `$(`, respects quotes, skips `VAR=x`, flags and `sudo`/`command`/`env`/`nohup`/`nice`/`time`/`exec`, compares base names lowercased; blocked list always wins | `MCP/MCPCommandFilter.swift` | `MCPCommandFilterTests` | `chau7_next_core/src/mcp/command_filter.rs` | done |  |
| MCP-041 | Permission mode setting: Allow All (default), Allowlist Only, Ask for Unlisted, Audit Only (logs and allows) | `MCP/MCPCommandFilter.swift`, `Chau7Core/MCPPermissionMode.swift` | `MCPPermissionModeTests` | `chau7_next_core/src/mcp/command_filter.rs`, `chau7_next/src/settings/mcp.rs`, `chau7_next/src/settings_window/mcp.rs` | done |  |
| MCP-042 | Allowed and blocked command lists editable in settings | `Settings/Views/MCPSettingsView.swift`, `MCP/MCPCommandFilter.swift` |  | `chau7_next/src/settings/mcp.rs`, `chau7_next/src/settings_window/mcp.rs` | done |  |
| MCP-043 | MCP profiles: per-context rules (trigger on directory, git branch, process, env...), own mode and lists, priority, agent allowlist; highest-priority enabled match overrides global rules | `Chau7Core/MCPProfile.swift`, `MCP/MCPCommandFilter.swift`, `Settings/Views/MCPSettingsView.swift` | `MCPProfileTests`, `MCPTabContextTests` | `chau7_next_core/src/mcp/command_filter.rs`, `chau7_next/src/settings/mcp.rs`, `chau7_next/src/settings_window/mcp.rs` | done |  |
| MCP-044 | Command approval dialog for unlisted commands: Deny (default) / Allow Once / Always Allow; Always Allow adds the command to the matched profile or the global list; shows which rule set applied | `MCP/TerminalControlService.swift` | `MCPApprovalResultTests` | `chau7_next/src/mcp/approval.rs` | done | NSAlert |
| MCP-045 | Same approval request is sent to the paired iOS app; first answer (Mac or iPhone) wins and dismisses the other (the Mac dialog is a GPUI window that an iPhone answer closes) | `MCP/TerminalControlService.swift` |  | chau7_next/src/mcp/approval.rs, chau7_next/src/mcp/approval_window.rs, chau7_next/src/seams.rs (approval_request, set_approval_resolver) | done |  |
| MCP-046 | "Enable MCP" setting (default on): when off, `tab_create` (and new-tab runtime sessions) are refused; the server still runs | `MCP/TerminalControlService.swift`, `Settings/Views/MCPSettingsView.swift` |  | `chau7_next/src/mcp/tools/tabs.rs`, `chau7_next/src/settings/mcp.rs`, `chau7_next/src/settings_window/mcp.rs` | done |  |
| MCP-047 | "Require Approval" setting (default off): Allow/Deny dialog before an agent opens a tab | `MCP/TerminalControlService.swift` |  | `chau7_next/src/mcp/approval.rs`, `chau7_next/src/settings/mcp.rs`, `chau7_next/src/settings_window/mcp.rs` | done | NSAlert |
| MCP-048 | MCP tab limit setting (default 4, hard max 50), counted per window over MCP-created tabs | `MCP/TerminalControlService.swift` |  | `chau7_next/src/mcp/tools/tabs.rs`, `chau7_next/src/settings/mcp.rs`, `chau7_next/src/settings_window/mcp.rs` | done |  |
| MCP-049 | MCP-created tabs stay attached to a live terminal even when far from the selected tab (not render-suspended) so agents can read them | `Overlay/OverlayTabsModel.swift` |  | `chau7_next/src/terminal/session.rs` | done |  |
| MCP-050 | "Show Tab Indicator" setting (default on) | `Settings/Views/MCPSettingsView.swift` |  | `chau7_next/src/settings/mcp.rs`, `chau7_next/src/settings_window/mcp.rs` | n/a |  |
| MCP-051 | Stable `window_id` per window (0, 1, 2...) that does not shift when a window closes; tab lookups search all windows | `MCP/TerminalControlService.swift` | `TerminalControlServiceTests` | `chau7_next/src/mcp/windows.rs` | done |  |
| MCP-052 | MCP actions are logged (tab created, exec, input, key press, close, blocked/allowed commands) | `MCP/TerminalControlService.swift` |  | `chau7_next/src/mcp/tools/tabs.rs`, `chau7_next/src/mcp/approval.rs` | done |  |

## Notes

### Chau7 Next isolation (DUAL-SHIP.md)

- Chau7 Next binds `DataRoot::mcp_socket()` (`~/.chau7-next/mcp.sock`), installs
  its bridge `chau7-next-mcp-bridge` (crate `chau7_next_mcp_bridge`, shipped in
  `Contents/MacOS/` next to the app binary) to `DataRoot::bin_dir()`, and
  registers it under `MCP_SERVER_NAME` (`chau7-next`) with
  `"args": ["--socket", "<socket>"]`, so the bridge never depends on the AI
  CLI's environment (`CHAU7_NEXT_MCP_SOCKET`, then the default socket, are
  fallbacks).
- Never write or remove the `chau7` entry in any client config. Use
  `mcpServers["chau7-next"]` in the JSON files and `[mcp_servers.chau7-next]`
  in Codex TOML (a bare key with `-` is valid TOML).
- The Swift bridge hardcodes `NSHomeDirectory() + "/.chau7/mcp.sock"`, so Chau7 Next
  needs its own bridge (a Rust binary, or the same code taking the socket path
  from an argument or env var). If it takes an argument, put it in `args`.
- `serverInfo.name` is `chau7-next`. Decision: resource URIs stay `chau7://...`
  (same URIs for agents with both apps).
- The repo's own `.mcp.json` registers `chau7` via `sh -c $HOME/.chau7/bin/chau7-mcp-bridge`;
  leave it alone.

### Wire format

- Transport: newline-delimited JSON, one JSON-RPC message per line, both ways.
  The server reads with `getline`, trims whitespace, skips empty lines, writes
  one line per response and flushes.
- `initialize` result: `protocolVersion "2024-11-05"`, capabilities
  `tools.listChanged=false`, `resources.subscribe=false, listChanged=false`,
  `serverInfo {name: "chau7", version: "1.1.0"}`.
- `notifications/initialized` produces no output. Any other notification gets a
  `-32601 Method not found` error with `id: null` (Swift quirk; harmless to keep or fix).
- Bad JSON: `{"jsonrpc":"2.0","id":null,"error":{"code":-32700,"message":"Parse error"}}`.
- `tools/call` always succeeds at the JSON-RPC level:
  `{"content":[{"type":"text","text":"<JSON string>"}]}`. Tool errors are a
  JSON text `{"error":"..."}` inside `text`, never `isError` and never a
  JSON-RPC error. Successful payloads are JSON with sorted keys.
- `resources/read` returns `{"contents":[{"uri":..., "mimeType":"application/json","text":"<JSON>"}]}`.
- Bridge connect failure line: `{"jsonrpc":"2.0","id":null,"error":{"code":-32000,"message":"Chau7 is not running. Start the app to enable MCP."}}`, exit 1.
  The bridge ignores SIGPIPE, sends `SHUT_WR` on stdin EOF, and exits when the socket closes.

### Tool response shapes (agents parse these)

- Tab summary keys: `tab_id`, `title`, `status`, `cwd`, `is_at_prompt`,
  `is_mcp_controlled`, `cto_active`, `cto_override`, optional `raw_status`,
  `raw_is_at_prompt`, `active_app`, `raw_active_app`, `git_branch`, `repo_root`,
  `repo_description`, `repo_labels`; `tab_list` adds `window_id`.
- `tab_create`: `{tab_id, window_id, status:"created", shell_loading}`.
- `tab_exec`: `{ok:true, queued:bool}`; `tab_send_input`, `tab_press_key`, `tab_close`: `{ok:true}`.
- `tab_output`: `{tab_id, output, lines, source:"buffer"|"pty_log"}`. Buffer mode
  strips trailing blank lines; if the result exceeds 512 KB it keeps half the
  requested lines. Stability wait polls every 250 ms and returns once output is
  unchanged for `min(wait, 500)` ms; the fingerprint is (byte count, SHA-256 of
  the last 4 KB). `pty_log` reads the tail (1,024,000 bytes) of the tab's last AI PTY log.
- `tab_set_cto`: `{ok, cto_active, cto_override}`; `tab_rename`: `{ok, title}`.
- `tab_status` extras: `processes[{pid,name,cpu_percent,rss_bytes}]`,
  `active_run{run_id, provider, started_at, session_id, duration_so_far_ms}`.
- Telemetry tools return the `TelemetryRun`/turn/tool-call Codable structs
  (ISO 8601 dates, sorted keys); Telemetry is not ported, so match its inventory.

### Client config registration

- JSON files: read, set `root["mcpServers"]["chau7"] = {"command": <bridge>, "args": []}`,
  write back pretty-printed with **sorted keys** (Swift reorders the user's whole
  file). Skip the file if it exists but is not valid JSON. Creates the file if
  the parent tool folder exists.
- Codex: if `[mcp_servers.chau7]` exists, rewrite its `command = "..."` line
  (insert one if missing); else insert
  `\n[mcp_servers.chau7]\ncommand = "<bridge>"\nargs = []` before `\n[features]`,
  or append at the end.
- Runs on every app launch, after copying the bridge.

### Settings keys (UserDefaults, Swift)

`mcp.enabled` (true), `mcp.maxTabs` (4), `mcp.requiresApproval` (false),
`mcp.showTabIndicator` (true), `mcp.permissionMode` (`allow_all` | `allowlist` |
`ask_unlisted` | `audit_only`, default `allow_all`), `mcp.allowedCommands`,
`mcp.blockedCommands` (string arrays, compared lowercased), `mcp.profiles`
(JSON array of `MCPProfile`: `id`, `name`, `isEnabled`, `trigger`,
`permissionMode`, `allowedCommands`, `blockedCommands`, `priority`,
`agentAllowlist`). Ties in profile priority break by name.

### Behavior notes

- The filter applies to `tab_exec` and `tab_send_input` only, not
  `tab_press_key`. `runtime_turn_send` goes through `tab_send_input`, so in
  Allowlist or Ask mode the first word of a prompt is checked as if it were a
  command. Keep or fix deliberately.
- Input is validated on the main thread and sent asynchronously to avoid a
  deadlock with the Rust PTY lock; Chau7 Next has a different threading model.
- MCP-050 is `n/a`: the setting is stored and shown in settings but nothing in
  the Swift app reads it.
- `chau7_next_core/src/key_encoding.rs` already encodes xterm keys and
  modifiers; reuse it for `tab_press_key`.

### Chau7 Next implementation

- Layout: `chau7_next_core::mcp` (pure: `protocol` JSON-RPC session,
  `command_filter`, `output` formatting, `client_config` registration) and
  `chau7_next::mcp` (`server` socket threads, `tools/` one file per tool
  family, `approval` dialogs, `install`, `windows` ids, `sources` hooks).
  Window side: `chau7_next/src/workspace/mcp.rs`. Socket: `platform/local_socket.rs`
  (Unix; Windows stub). Settings: `settings/mcp.rs`, `settings_window/mcp.rs`.
- Threading: one listener thread, one thread per client. Anything touching
  tabs or settings runs on the GPUI main thread through `mcp::MainThread`
  (a job channel drained by a foreground task); the client thread blocks on
  the answer. Waits (stable output polling, CPU sampling for `tab_status`)
  happen on the client thread. PTY writes go to the session's writer thread,
  so the Swift deadlock workaround is not needed.
- Differences on purpose: no answer to any notification (Swift answered
  "Method not found" with `id: null`); tool errors are always valid JSON
  (Swift only escaped quotes); `run_list` `after`/`before` accept ISO 8601
  with or without fractional seconds (Swift required them); the command
  filter returns normalized names (`/bin/rm` gives `rm`, as the Swift tests
  expect, so "Always Allow" stores a name that matches again); the profile
  editor keeps `agentAllowlist` when editing (Swift reset it); the listen
  backlog is the OS default, not 5.
- Tab ids: `TabMeta::uuid` (upper-case UUID like `uuidString`), kept when a
  tab moves to another window; lookups accept any case. Window ids: given in
  opening order (`mcp::windows`, swept every second and on each request),
  never reused. Tabs of windows closed with Close Window (parked, APP-004)
  are not listed until the window comes back.
- Runtime tools (MCP-031 to MCP-038): `chau7_next/src/mcp/tools/runtime.rs` (schemas), handled by `chau7_next/src/runtime/control.rs`
- `tab_status` looks up `active_run` with the tab's MCP `tab_id` (upper-case UUID). Swift keys it by the terminal session's `tabIdentifier`; the Telemetry port must use the same key it records runs under
  lists the Swift schemas and answers an error; the Runtime port replaces
  its `call` (it gets `ToolContext::main` for main-thread work).
- Telemetry and History: `mcp::sources::set_telemetry` / `set_history` plug
  in the stores (TelemetryStore, TelemetryRecorder, PersistentHistoryStore,
  RepoStatsProvider); `chau7_next/src/telemetry.rs` (`connect`) and
  `seams.rs` register them at launch. Runs are keyed by the terminal's
  `tab_identifier` (Swift `tabIdentifier`), so `tab_get` looks up the active
  run of the tab's focused terminal.
- MCP-049: sessions run without a view in Chau7 Next (PTY and emulator live
  in `TerminalSession`), Suspend Background Rendering only slows the grid
  copy, and MCP reads the emulator, so background MCP tabs always work.
- Settings live in config.toml `[next]`: `mcp_enabled`, `mcp_max_tabs`,
  `mcp_requires_approval`, `mcp_show_tab_indicator`, `mcp_permission_mode`
  (Swift raw values), and `mcp_allowed_commands`, `mcp_blocked_commands`,
  `mcp_profiles` as escaped JSON text (Swift `MCPProfile` JSON). Settings
  export and import use the Swift `mcp*` keys.
- Dialogs are GPUI prompts on the tab's window (NSAlert on macOS), one at a
  time; the window is brought to the front. Linux draws GPUI's fallback
  prompt, which cuts long details.
- A socket path longer than the OS limit (104 bytes on macOS, 108 on Linux)
  cannot be bound; the error is logged.
