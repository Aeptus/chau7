# Privacy

Chau7 runs entirely on your machine. No analytics, no crash reporting, no usage tracking. The only time data leaves your device is when you explicitly submit a bug report or use the remote control feature.

## What stays local

Everything, by default:

| Data | Location | Leaves your machine? |
|------|----------|---------------------|
| Terminal output and scrollback | Memory + `~/.chau7/` | Never |
| Command history | SQLite at `~/.chau7/` | Never |
| Telemetry (token counts, cost, tool calls) | SQLite at `~/.chau7/telemetry/` | Never |
| AI event logs | `~/.chau7/claude-events.jsonl` | Never |
| Settings and preferences | `UserDefaults` | Never (unless iCloud sync is enabled) |
| API keys | Forwarded by proxy, never stored | Never stored or logged |
| Scrollback restore files | `~/.chau7/` | Never |
| Bug report drafts | `~/.chau7/reports/` | Only when you hit Submit |

## Bug reports

When you use the in-app bug reporter (Option+Cmd+I):

1. **You choose what to include.** All diagnostic sections (logs, terminal state, session data) are off by default. You toggle on only what you want to share.
2. **Your report is sent via HTTPS** through a Cloudflare Worker relay ([`services/chau7-relay/src/worker.ts`](services/chau7-relay/src/worker.ts)) to a [private GitHub repository](https://github.com/aeptus/chau7-issue-intake) that only project maintainers can access.
3. **No data is sent until you hit Submit.** The report is composed locally and you can preview the full markdown content before sending.
4. **Rate limited.** The relay enforces a maximum of 5 reports per hour per IP to prevent abuse.

The in-app privacy page ([`IssueReportingPrivacyView.swift`](apps/chau7-macos/Sources/Chau7/Logging/IssueReportingPrivacyView.swift)) provides a full GDPR-compliant disclosure accessible from the bug report dialog.

### Sub-processors

Only two third-party services are involved in bug report submission:

| Service | Role | Data access |
|---------|------|-------------|
| **Cloudflare** (Workers + Durable Objects) | Relay. Receives the report payload, forwards it to GitHub, discards it. No persistent storage. | Transient: report payload in memory during forwarding |
| **GitHub** (private repo) | Storage. The report becomes a GitHub issue in a private repository. | Persistent: report content stored as a GitHub issue |

Both services process data under their respective DPAs. No other third parties are involved.

### Legal basis

Bug report processing is based on legitimate interest (GDPR Art. 6(1)(f)) — you initiate the report, choose the content, and submit it voluntarily. You can request deletion of any submitted report by opening an issue or contacting the maintainer.

## API proxy

The local Go proxy (`chau7-proxy`) intercepts AI API calls on `localhost:18080` for token counting and cost analytics. Your API keys pass through to the original provider (Anthropic, OpenAI, etc.) and are **never stored, logged, or transmitted elsewhere**. The proxy is opt-in and can be disabled in Settings.

Source: [`apps/chau7-macos/chau7-proxy/`](apps/chau7-macos/chau7-proxy/)

## Remote control

The remote control feature (iOS companion app) relays encrypted frames between your Mac and iPhone through a Cloudflare Worker. The relay does not inspect or store frame payloads — it forwards opaque encrypted data. Encryption uses ChaCha20-Poly1305 with keys derived from a Curve25519 key exchange.

Source: [`services/chau7-relay/`](services/chau7-relay/) and [`services/chau7-remote/`](services/chau7-remote/)

Protocol: [`services/chau7-remote/docs/PROTOCOL.md`](services/chau7-remote/docs/PROTOCOL.md)

## MCP server

The MCP server exposes tools over a Unix socket at `~/.chau7/mcp.sock` with permissions `0600` (owner-only). Any process running as your user can connect. The tools can read terminal output, send input, manage tabs, and query history. All communication is local — nothing crosses the network.

Source: [`apps/chau7-macos/Sources/Chau7/MCP/`](apps/chau7-macos/Sources/Chau7/MCP/)

## What Chau7 does not do

- Phone home. No analytics endpoints, no heartbeats, no "anonymous" usage data.
- Store API keys. The proxy forwards them in-flight. Nothing is persisted.
- Run background daemons after you quit (unless you configure start-at-login).
- Send terminal output anywhere. Your scrollback stays on your disk.
- Use cookies, fingerprinting, or tracking of any kind.
