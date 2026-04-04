# Security

Chau7 is a terminal emulator. It sees everything you type and everything your tools output. We take that seriously, even if we don't take our naming conventions seriously.

## Reporting Vulnerabilities

**Do not open a public issue.** Instead:

1. Use the in-app bug reporter (Option+Cmd+I). Reports are submitted via an encrypted Cloudflare Worker relay to a [private GitHub repository](https://github.com/aeptus/chau7-issue-intake) that only maintainers can access. You choose which diagnostic sections to include before anything is sent. See the [in-app privacy page](apps/chau7-macos/Sources/Chau7/Logging/IssueReportingPrivacyView.swift) and [PRIVACY.md](PRIVACY.md) for the full data flow.
2. Or open a [private security advisory](https://github.com/aeptus/chau7/security/advisories/new) on GitHub.

We acknowledge reports within 48 hours. Critical fixes ship within 7 days. We'll credit you in the release notes unless you prefer otherwise.

## What Chau7 Touches

Here's everything security-relevant, with no hand-waving:

**Terminal I/O**: Every keystroke, every command output, every escape sequence. The terminal buffer lives in memory and optionally in scrollback restore files on disk at `~/.chau7/`.

**API Proxy** (`chau7-proxy`): A local Go binary that intercepts AI API calls over TLS for analytics. Your API keys pass through to the original provider (Anthropic, OpenAI, etc.). Keys are never stored, never logged, never transmitted anywhere else. The proxy is opt-in and runs on `localhost:18080`. You can disable it in Settings.

**MCP Server**: 30+ tools exposed over a Unix socket at `~/.chau7/mcp.sock`, permissions `0600` (owner-only). Any process running as your user can connect. The tools can read terminal output, send input, manage tabs, and query history. This is powerful by design.

**Bug Reports**: Submitted via an encrypted Cloudflare Worker relay ([`services/chau7-relay/src/worker.ts`](services/chau7-relay/src/worker.ts)) to a [private GitHub repository](https://github.com/aeptus/chau7-issue-intake) that only maintainers can access. No data leaves your machine until you hit Submit. All diagnostic sections are off by default — you choose what to include. The in-app privacy page ([`IssueReportingPrivacyView.swift`](apps/chau7-macos/Sources/Chau7/Logging/IssueReportingPrivacyView.swift)) lists every third-party involved. See also [PRIVACY.md](PRIVACY.md).

**Shell Integration**: OSC 7/133 escape sequences for working directory and command detection. Shell history access for frecency commands. Git status queries via `git rev-parse`.

**Relay** (`services/chau7-relay`): Cloudflare Worker that relays remote control sessions and bug reports. Rate-limited. Authenticated via HMAC tokens. No persistent storage of user data.

**Telemetry**: Per-run token counts, cost, tool calls. All stored locally in SQLite at `~/.chau7/telemetry/`. Nothing leaves your machine unless you explicitly submit a bug report with diagnostic data attached.

## What Chau7 Does Not Do

- Phone home. No analytics, no crash reporting, no usage tracking. Unless you submit a bug report.
- Store API keys. The proxy forwards them. It does not save them.
- Run in the background after you quit. No daemons, no LaunchAgents (unless you configure start-at-login).
- Send terminal output anywhere. Your scrollback stays on your disk.

## Supported Versions

Security fixes ship for the latest release only. We're a small team (well, a small person). If you're running an old version, update first, then report.
