# DataExplorer

Swift: `apps/chau7-macos/Sources/Chau7/DataExplorer/` (5 files, 594 lines)
Swift tests: none
Wave: 4
Depends on: Telemetry (`TelemetryStore`: AI runs, tokens, cost, tool calls), History (`PersistentHistoryStore`: command records)

A window for browsing recorded activity: AI runs grouped by repository, a list of all AI runs with a tool-call breakdown, and a searchable table of every command run in Chau7.

## Features

| ID | Feature | Swift source | Tests | Rust | Status | macOS API |
|---|---|---|---|---|---|---|
| DEX-001 | Data Explorer window from the View menu (Shift+Cmd+D), 900x600 (minimum 600x400), single instance brought to front and refreshed when reopened; segmented tabs By Repo / All Runs / Commands | `DataExplorer/DataExplorerWindow.swift`, `DataExplorer/DataExplorerView.swift`, `App/Chau7App.swift` |  | chau7_next/src/data_explorer.rs | done |  |
| DEX-002 | By Repo: the last 500 AI runs grouped by repository (or working directory), most recently active first; each row shows repo name, relative last-active time, colored provider badges (Claude, Codex, Cline, ChatGPT), command count with success rate (green over 90%, yellow over 70%, else red), run count, billable tokens (K/M) and cost | `DataExplorer/SessionsExplorerView.swift` |  | chau7_next_core/src/data_explorer.rs,chau7_next/src/data_explorer.rs, chau7_next/src/telemetry.rs | done |  |
| DEX-003 | All Runs: the 200 most recent AI runs with provider badge, repo name, relative start time, short session id, turn count, billable tokens and model; header shows run count and how many have token data | `DataExplorer/RunsExplorerView.swift` (`RunRow`) |  | chau7_next_core/src/data_explorer.rs,chau7_next/src/data_explorer.rs, chau7_next/src/telemetry.rs | done |  |
| DEX-004 | Selecting a run shows its tool calls as a bar chart (tool name, bar scaled to the most used tool, count), or "No tool calls recorded" | `DataExplorer/RunsExplorerView.swift` (`RunDetailView`) |  | chau7_next/src/data_explorer.rs, chau7_next/src/telemetry.rs | done |  |
| DEX-005 | Commands: the 200 most recent persisted commands, search on Return over all history, total record count; each row shows exit status (green check, red cross, or empty circle), command, directory shortened with `~`, duration (ms, s, or m s) and time | `DataExplorer/HistoryExplorerView.swift` |  | chau7_next_core/src/data_explorer.rs,chau7_next/src/data_explorer.rs, chau7_next/src/telemetry.rs (ExplorerData) | done |  |
| DEX-006 | Empty states: "No AI sessions recorded yet", "No AI runs recorded yet", "No command history yet" / "No matching commands" | `DataExplorer/*.swift` |  | chau7_next/src/data_explorer.rs | done |  |

## Notes

- Everything here reads stores owned by other modules; port Telemetry and
  History storage first. Rust history (`history.tsv`, written by the shell
  integration) has command and directory but no exit code, duration or
  timestamp in the picker.
- `chau7_next/src/data_explorer.rs` reads through the `ExplorerSource`
  trait (runs, tool calls, repo cost, command totals, recent and searched
  commands, record count). `chau7_next/src/telemetry.rs` (`connect`)
  registers the telemetry store and the SQLite history with
  `data_explorer::set_source`; before that (and without a history
  database) commands come from the shell integration's `history.tsv`.
- Shift+Cmd+D opens the Data Explorer (Ctrl+Shift+Alt+X off macOS).
- Data is loaded once when each tab appears; there is no live refresh.
