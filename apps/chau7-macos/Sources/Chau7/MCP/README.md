# MCP

Model Context Protocol server: exposes terminal control to AI agents.

## Files

| File | Purpose |
|------|---------|
| `MCPSession.swift` | Tool definitions + dispatch: `tab_*`, `repo_*`, `runtime_*` tools |
| `TerminalControlService.swift` | Handler implementations: tab CRUD, output, input, rename, repo metadata |
| `MCPServerManager.swift` | Server lifecycle: start, stop, client connections |
| `MCPCommandFilter.swift` | Command filtering for MCP tool use |
| `TelemetryQueryService.swift` | Telemetry run/turn/tool_call queries for MCP |

## Key Patterns

- MCP tab limit: configurable (default 4, max 50) — `isMCPControlled` flag per tab
- `allModels` and `allTabs` search across all windows for cross-window operations
- `repo_get_metadata` / `repo_set_metadata` / `repo_frequent_commands` for repo memory
