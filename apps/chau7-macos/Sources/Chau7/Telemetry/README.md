# Telemetry

SQLite-backed telemetry for AI coding tool sessions. Records run lifecycle events, terminal output, and provider-specific content (turns, tool calls) for post-hoc analysis via the MCP server. A separate in-memory token-rate feed combines proxy stream estimates, proxy usage timing, and Claude/Codex transcript events for the selected tab badge.

## Files

| File | Purpose |
|------|---------|
| `TelemetryStore.swift` | SQLite database layer -- tables, migrations, CRUD for runs/turns/tool-calls |
| `TelemetryRecorder.swift` | Singleton that observes terminal session events and writes run records |
| `TokenRateStore.swift` | In-memory per-tab rate snapshots with source/confidence labels |
| `LiveTokenRateMonitor.swift` | Tails Claude and Codex JSONL usage events while a run is active |
| `TokenRateBadge.swift` | Selected-tab token-rate indicator |
| `Providers/ClaudeCodeContentProvider.swift` | Extracts conversation turns from Claude Code JSONL logs |
| `Providers/CodexContentProvider.swift` | Extracts conversation turns from Codex CLI log output |

## Key Types

- `TelemetryStore` -- thread-safe SQLite store (WAL mode, serialized queue) for `TelemetryRun`, turns, and tool calls
- `TelemetryRecorder` -- bridges terminal session lifecycle (`runStarted`/`runEnded`) to the store, resolves provider-specific content via pluggable `RunContentProvider`s
- `ClaudeCodeContentProvider` / `CodexContentProvider` -- parse provider log files into normalized turn/tool-call records
- `TokenRateStore` -- keeps the latest per-tab rate; transcript rates are approximate because their timestamps include tool and response delays

The proxy reports a rolling text-based estimate while an SSE response is active, then replaces it with a usage-based rate when provider counts arrive. Streamed calls use time from first response byte to completion; non-streamed calls use total request duration and are marked approximate because setup and prefill are included. The observer emits character counts only and does not persist or log generated text. Claude and Codex transcript adapters use provider-reported output-token counts with transcript timing, and therefore remain approximate. The badge tooltip identifies the source and timing basis.

## Dependencies

- **Uses:** Chau7Core (TelemetryRun, RuntimeIsolation, Log), SQLite3, Foundation
- **Used by:** Terminal/Session (run start/end), MCP server (run queries), Debug console (run list)
