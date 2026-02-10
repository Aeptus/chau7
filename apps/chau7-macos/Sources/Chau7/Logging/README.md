# Logging

Structured logging with file output, categories, correlation IDs, and os.log integration.

## Files

| File | Purpose |
|------|---------|
| `DebugContext.swift` | Provides correlated debug context with unique IDs for tracing operations across the app |
| `Log.swift` | Core logging enum with file-based output, rotation, and configurable max size |
| `LogEnhanced.swift` | Category-based logging with os.log integration and per-category filtering |

## Key Types

- `Log` — static logging API with info/warn/error levels and file output
- `LogCategory` — enum of subsystem categories (App, Tabs, Terminal, Render, etc.) for filtering
- `DebugContext` — correlates related log entries with a unique ID for operation tracing

## Dependencies

- **Uses:** (none -- foundation-level module)
- **Used by:** Nearly all modules in the app
