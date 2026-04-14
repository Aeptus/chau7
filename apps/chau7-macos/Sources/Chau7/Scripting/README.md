# Scripting

External scripting API over a Unix socket for automating Chau7 from scripts.

## Files

| File | Purpose |
|------|---------|
| `ScriptingAPI.swift` | JSON-RPC style API exposing tabs, commands, history, snippets, and settings over a Unix socket |
| `ScriptingClientHandler.swift` | Handles a single connected client, reading newline-delimited JSON and dispatching requests |

## Key Types

- `ScriptingAPI` — singleton ObservableObject managing the scripting socket and request dispatch
- `ScriptingClientHandler` — per-client handler reading JSON-RPC messages and writing responses

## Contract

- Public scripting discovery is tab-first: tabs, input/output, history, snippets, and settings.
- Legacy review/session methods have been removed. Review automation should use the tab-first scripting methods plus repo events/output.

## Dependencies

- **Uses:** Overlay, Settings, Snippets, History, Logging
- **Used by:** App
