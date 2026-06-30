# Logging

Structured logging with file output, categories, correlation IDs, and os.log integration.

## Files

| File | Purpose |
|------|---------|
| `DebugContext.swift` | `StateSnapshot` (captures app/tab/session state) and `BugReporter` (generates prefilled GitHub issue reports) |
| `Log.swift` | Core logging enum with file-based output, rotation, and configurable max size |
| `LogEnhanced.swift` | Category-based logging with os.log integration and per-category filtering |

## Key Types

- `Log` — static logging API with info/warn/error levels and file output
- `LogCategory` — enum of subsystem categories (App, Tabs, Terminal, Render, etc.) for filtering
- `StateSnapshot` / `BugReporter` — capture app state and generate bug reports (in `DebugContext.swift`)

## Dependencies

- **Uses:** (none -- foundation-level module)
- **Used by:** Nearly all modules in the app
