# Runtime

MCP-managed AI agent sessions: create, monitor, steer.

## Files

| File | Purpose |
|------|---------|
| `RuntimeSession.swift` | Session state machine, approval handling, turn tracking, event journal |
| `RuntimeSessionManager.swift` | Manages active sessions: event routing, permission auto-respond, notifications |
| `RuntimeControlService.swift` | MCP tool dispatch for `runtime_session_*` and `runtime_turn_*` tools |

## Backends (`Backends/`)

| File | Purpose |
|------|---------|
| `ClaudeCodeBackend.swift` | Launch command for Claude Code CLI, hook-based state mapping |
| `CodexBackend.swift` | Launch command for OpenAI Codex CLI, `--full-auto` support |
| `GenericShellBackend.swift` | Plain shell sessions |

## Key Patterns

- Two-layer auto-approve: CLI flags (Layer 1) + runtime auto-respond (Layer 2)
- `SessionConfig.autoApprove` flows to backend launch flags AND runtime permission handling
- Events from Claude Code hooks are parsed by `ClaudeCodeBackend.trigger(from:)`
