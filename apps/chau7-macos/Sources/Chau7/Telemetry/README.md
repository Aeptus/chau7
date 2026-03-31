# Telemetry

SQLite-backed telemetry for AI coding tool sessions. Records run lifecycle events, terminal output, and provider-specific content (turns, tool calls) for post-hoc analysis via the MCP server.

## Files

| File | Purpose |
|------|---------|
| `TelemetryStore.swift` | SQLite database layer -- tables, migrations, CRUD for runs/turns/tool-calls |
| `TelemetryRecorder.swift` | Singleton that observes terminal session events and writes run records |
| `Providers/ClaudeCodeContentProvider.swift` | Extracts conversation turns from Claude Code JSONL logs |
| `Providers/CodexContentProvider.swift` | Extracts conversation turns from Codex CLI log output |

## Key Types

- `TelemetryStore` -- thread-safe SQLite store (WAL mode, serialized queue) for `TelemetryRun`, turns, and tool calls
- `TelemetryRecorder` -- bridges terminal session lifecycle (`runStarted`/`runEnded`) to the store, resolves provider-specific content via pluggable `RunContentProvider`s
- `ClaudeCodeContentProvider` / `CodexContentProvider` -- parse provider log files into normalized turn/tool-call records

## Dependencies

- **Uses:** Chau7Core (TelemetryRun, RuntimeIsolation, Log), SQLite3, Foundation
- **Used by:** Terminal/Session (run start/end), MCP server (run queries), Debug console (run list)
