# DataExplorer

SQLite data browser for command history and AI telemetry.

## Files

| File | Purpose |
|------|---------|
| `DataExplorerWindow.swift` | Singleton NSWindow manager (Cmd+Shift+D) |
| `DataExplorerView.swift` | Root view with tab picker: By Repo / All Runs / Commands |
| `HistoryExplorerView.swift` | Searchable command history from `history.db` |
| `RunsExplorerView.swift` | AI telemetry runs with tool call breakdown |
| `SessionsExplorerView.swift` | Runs grouped by repository |

## Data Sources

- `~/Library/Application Support/Chau7/history.db` — command history (SQLite)
- `~/.chau7/telemetry/runs.db` — AI session telemetry (SQLite)
