# Debug

Hidden debug console and last-command tracking for development diagnostics.

## Files

| File | Purpose |
|------|---------|
| `DebugConsoleView.swift` | Hidden debug console (Cmd+Shift+L) showing logs, state, perf data, and bug reports |
| `LastCommandInfo.swift` | Tracks the last executed command with timing and exit code for badge display |

## Key Types

- `DebugConsoleView` — SwiftUI view with tabs for logs, state inspection, and bug report generation
- `LastCommandInfo` — value type holding command text, start/end time, exit code, and duration

## Dependencies

- **Uses:** App, Overlay, Settings, Logging, Performance
- **Used by:** Overlay, StatusBar
