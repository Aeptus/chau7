# Monitoring

Real-time monitoring of Claude Code hooks, dev servers, file changes, and shell events.

## Files

| File | Purpose |
|------|---------|
| `ClaudeCodeEvent.swift` | Event types and model for Claude Code hook events (prompts, tools, permissions) |
| `ClaudeCodeMonitor.swift` | Monitors Claude Code events via hooks and tracks active sessions |
| `DevServerMonitor.swift` | Detects running dev servers by port scanning and command pattern matching |
| `FileMonitor.swift` | Low-level file system watcher using GCD dispatch sources (O_EVTONLY) |
| `HistoryIdleMonitor.swift` | Tracks session idle/active/closed states from history file entries |
| `ShellEventDetector.swift` | Detects shell events (exit codes, patterns, long-running commands, git changes) |

## Key Types

- `ClaudeCodeMonitor` — singleton tracking Claude Code sessions and events in real time
- `ShellEventDetector` — emits notification events for exit codes, output patterns, and long commands
- `HistoryIdleMonitor` — monitors session activity and fires idle/stale callbacks
- `FileMonitor` — GCD-based file watcher wrapping dispatch_source for filesystem events

## Dependencies

- **Uses:** History (FileTailer), Logging, Settings, Utilities (BoundedArray), App
- **Used by:** App, Notifications, Overlay
