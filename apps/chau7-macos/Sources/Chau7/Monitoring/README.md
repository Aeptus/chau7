# Monitoring

Real-time monitoring of AI tool events, dev servers, file changes, and shell events.

> **Design principle — backend-agnostic AI support.** Chau7 strives to treat every AI coding tool identically. Tool-specific monitors (Claude hooks, Codex session files) exist only because each tool stores session data differently. They self-register with the generic routing layer (`TabResolver`) at startup so that no downstream subsystem — notifications, tab switching, UI — ever references a specific tool by name. Adding a new AI backend should never require changes outside the monitor itself and `AIToolRegistry`.

## Files

| File | Purpose |
|------|---------|
| `ClaudeCodeEvent.swift` | Event types and model for Claude Code hook events (prompts, tools, permissions). Scoped to Claude — use `AIEvent` for cross-tool logic. |
| `ClaudeCodeMonitor.swift` | Monitors Claude Code events and tracks active sessions. Registers its CWD resolver with `TabResolver` on `start()`. |
| `CodexSessionResolver.swift` | Resolves Codex session metadata from `~/.codex/sessions/`. Registers its CWD resolver with `TabResolver` via `registerWithTabResolver()`. |
| `DevServerMonitor.swift` | Detects running dev servers by port scanning and command pattern matching |
| `FileMonitor.swift` | Low-level file system watcher using GCD dispatch sources (O_EVTONLY) |
| `HistoryIdleMonitor.swift` | Tracks session idle/active/closed states from history file entries |
| `ShellEventDetector.swift` | Detects shell events (exit codes, patterns, long-running commands, git changes) |

## Key Types

- `ClaudeCodeMonitor` — singleton tracking Claude Code sessions and events in real time
- `CodexSessionResolver` — caseless enum resolving Codex session metadata by session ID or directory
- `ShellEventDetector` — emits notification events for exit codes, output patterns, and long commands
- `HistoryIdleMonitor` — monitors session activity and fires idle/stale callbacks
- `FileMonitor` — GCD-based file watcher wrapping dispatch_source for filesystem events

## Registration Pattern

Each tool-specific monitor registers a CWD session resolver with `TabResolver` during setup. This lets `TabResolver` route events for any tool without knowing which monitors exist:

```
ClaudeCodeMonitor.start()          → TabResolver.registerCWDResolver(forProviderKey: "claude", ...)
CodexSessionResolver.registerWithTabResolver() → TabResolver.registerCWDResolver(forProviderKey: "codex", ...)
```

To add a new AI backend: create its monitor, implement a `sessionCandidates(forDirectory:)` method, register with `TabResolver`, and add its definition to `AIToolRegistry`.

## Dependencies

- **Uses:** History (FileTailer), Logging, Settings, Utilities (BoundedArray), App, Notifications (TabResolver)
- **Used by:** App, Notifications, Overlay
