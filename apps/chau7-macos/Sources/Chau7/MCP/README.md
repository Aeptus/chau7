# MCP

Model Context Protocol server: exposes Chau7 tab control, output, and telemetry to AI agents.

## Files

| File | Purpose |
|------|---------|
| `MCPSession.swift` | Tool definitions + dispatch: `tab_*`, telemetry, `repo_*`, and `runtime_*` tools |
| `TerminalControlService.swift` | Handler implementations: tab CRUD, output, input, rename, repo metadata |
| `MCPServerManager.swift` | Server lifecycle: start, stop, client connections |
| `MCPCommandFilter.swift` | Command filtering for MCP tool use |
| `TelemetryQueryService.swift` | Telemetry run/turn/tool_call queries for MCP |

## Key Patterns

- MCP tab limit: configurable (default 4, max 50) — `isMCPControlled` flag per tab
- `allModels` and `allTabs` search across all windows for cross-window operations
- `repo_get_metadata` / `repo_set_metadata` / `repo_frequent_commands` for repo memory
- `tab_list` and `tab_status` are the authoritative live discovery/control path for active AI tabs
- `session_list` and `session_current` are telemetry/history views, not the live source of truth for tab control
