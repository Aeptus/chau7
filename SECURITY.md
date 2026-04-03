# Security Policy

## Reporting a Vulnerability

If you discover a security vulnerability in Chau7, please report it responsibly.

**Do NOT open a public issue.** Instead:

1. Email security@chau7.sh with a description of the vulnerability.
2. Or use the in-app bug reporter (Option+Cmd+I) — reports go to a private intake repo.

We will acknowledge your report within 48 hours and aim to provide a fix within 7 days for critical issues.

## Scope

Chau7 handles sensitive data by design — it's a terminal emulator that sees everything you type and every command output. Security-relevant components include:

- **Terminal input/output**: Keystroke handling, clipboard access, scrollback buffer.
- **API Proxy** (`chau7-proxy`): TLS-intercepting proxy for AI API analytics. Handles API keys in transit.
- **Relay** (`services/chau7-relay`): Cloudflare Worker that forwards bug reports. Rate-limited, no auth data stored.
- **Remote Control** (`services/chau7-remote`): Encrypted session relay for iPhone companion app.
- **Shell Integration**: OSC escape sequences, shell history access, git status queries.
- **MCP Server**: Unix socket API exposing tab control, terminal output, and session management.

## Security Model

- The API proxy runs locally and never sends credentials to external servers. API keys pass through to the original provider only.
- The MCP socket is bound to `~/.chau7/mcp.sock` with `0600` permissions (owner-only).
- Bug reports are submitted to a private GitHub repo via Cloudflare Worker relay. No data is sent without explicit user action.
- Session restore uses `stty -echo` to hide restore commands from terminal history.
- Dangerous command detection warns before executing risky commands (configurable).

## Supported Versions

We provide security fixes for the latest release only.
