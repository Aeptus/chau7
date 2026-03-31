# Monitoring

Terminal and AI session monitoring: event detection, conflict tracking, resource usage.

## Files

| File | Purpose |
|------|---------|
| `ShellEventDetector.swift` | Command lifecycle, directory/branch changes, output pattern matching |
| `ClaudeCodeMonitor.swift` | Claude Code hook events from `~/.chau7/claude-events.jsonl` |
| `ConflictDetector.swift` | Cross-tab file change detection (fires `app.file_conflict` notification) |
| `DevServerMonitor.swift` | Dev server detection: Vite, Next.js, Astro + port discovery via lsof |
| `HistoryIdleMonitor.swift` | AI session idle detection from history file tailing |
| `ProcessResourceMonitor.swift` | Per-tab CPU/memory via `ps` polling |
| `FileMonitor.swift` | FSEvents-based file change watcher |

## Key Patterns

- `ConflictDetector.checkForConflicts()` called after each command finish (OSC 133 D)
- Dev server port detection defers initial callback when port is nil
- Shell events emit to `AppModel.recordEvent()` which feeds the notification pipeline
