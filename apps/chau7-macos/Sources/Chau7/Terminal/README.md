# Terminal

Top-level terminal module containing session management, rendering, and view submodules.

## Subdirectories

| Directory | Purpose |
|-----------|---------|
| `Session/` | Terminal session lifecycle, command tracking, input detection, and history |
| `Rendering/` | ANSI parsing, terminal view subclass, output normalization, and PTY capture |
| `Views/` | SwiftUI/AppKit terminal view wrappers, protocols, and log display |

## Session Key Files

`TerminalSessionModel` is the core session model (~1,800 lines) with four extension files that hold extracted MARK sections:

| File | Lines | Purpose |
|------|------:|---------|
| `TerminalSessionModel.swift` | ~1,800 | Core model: stored properties, init, shell config, idle timer, session control, zoom, paste, broadcast, CTO |
| `+ShellIntegration.swift` | ~1,400 | OSC 133 handling, command/AI detection, dev server monitoring, dangerous output highlighting, input/output processing |
| `+Search.swift` | ~340 | Find-in-terminal, regex search, semantic search, match navigation, buffer caching |
| `+Telemetry.swift` | ~150 | Latency summaries, percentile calculations, lag spike logging, lag event timeline |
| `+ProcessMonitor.swift` | ~30 | Hover-card CPU/memory polling via `ProcessResourceMonitor` |
| `CommandBlockManager.swift` | -- | Tracks command blocks (start/end lines, timing, exit codes) per tab |

## Dependencies

- **Uses:** Settings, Logging, Utilities, Performance, RustBackend, Rendering
- **Used by:** App, Overlay, SplitPanes, StatusBar, Analytics, Scripting
