# MCP

Model Context Protocol server: exposes Chau7 tab control, output, and telemetry to AI agents.

## Files

| File | Purpose |
|------|---------|
| `MCPSession.swift` | Public tool definitions + dispatch: `tab_*`, telemetry, and `repo_*` tools |
| `TerminalControlService.swift` | Handler implementations: tab CRUD, output, input, rename, repo metadata |
| `MCPServerManager.swift` | Server lifecycle: start, stop, client connections |
| `../Observability/Chau7ObservabilityService.swift` | Build identity, event ring buffer, and timer inventory for external observability |
| `MCPCommandFilter.swift` | Command filtering for MCP tool use |
| `TelemetryQueryService.swift` | Telemetry run/turn/tool_call queries for MCP |

## Key Patterns

- MCP tab limit: configurable (default 4, max 50) — `isMCPControlled` flag per tab
- `allModels` and `allTabs` search across all windows for cross-window operations
- `repo_get_metadata` / `repo_set_metadata` / `repo_frequent_commands` for repo memory
- `tab_list` and `tab_status` are the authoritative live discovery/control path for active AI tabs
- `tab_status.can_accept_exec` / `exec_acceptance_mode` are the canonical launch signals for deterministic `tab_exec` submission
- `tab_status.ready_for_exec` / `readiness_reason` remain the stricter prompt-ready signals for immediate non-queued execution
- `tab_exec` can still be called during shell bootstrap or before the live terminal view attaches; Chau7 queues the command when needed
- `tab_wait_ready` now waits for deterministic exec acceptance rather than stricter prompt-ready state
- `session_list` and `session_current` are telemetry/history views, not the live source of truth for tab control
- `chau7_runtime_info` exposes build/process identity for external observability
- `chau7_runtime_events` exposes app-owned lifecycle markers plus unified non-app AI events with stable sequence numbers
- `chau7_timer_inventory` exposes Chau7-owned timer/display-link state for renderer and MCP server correlation
- `chau7_state_snapshot` is the authoritative aggregated observer read: runtime identity, tabs, approvals, repo event summaries, active telemetry runs/sessions, timers, and latest sequence
- `chau7_subscribe` / `chau7_unsubscribe` open one long-lived state feed per MCP connection using JSON-RPC notifications (`notifications/chau7.event`) with replay from a cursor
- runtime orchestration remains app-internal for now and is no longer part of the public MCP tool surface
