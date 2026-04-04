# Chau7 Relay (Cloudflare Workers + Durable Objects)

Forwards encrypted frames between macOS and iOS clients, handles APNs push
notifications for offline devices, and relays bug reports to a private GitHub
intake repo. The relay does not inspect or store payloads.

The relay fails closed unless `RELAY_SECRET` is set to a real shared secret.
The shipped placeholder in `wrangler.toml` is intentionally rejected at runtime.

## Routes

| Method | Path | Purpose |
|--------|------|---------|
| GET | `/` | Landing page (HTML) |
| POST | `/` or `/issue` | Create a GitHub issue via the private intake repo |
| WS | `/connect/:deviceId?role=mac\|ios` | WebSocket relay between paired devices |
| POST | `/push/register/:deviceId` | Register an iOS device for APNs push |
| POST | `/push/notify/:deviceId` | Send a push notification to a paired iOS device |

## Source Files

| File | Purpose |
|------|---------|
| `src/worker.ts` | Cloudflare Worker entry point — routing, auth, issue creation |
| `src/session.ts` | `SessionDO` Durable Object — WebSocket relay, push registration, APNs, rate limiting |
| `src/auth.js` | Relay secret validation (rejects placeholder values) |

## Build / Deploy

```bash
npm install
npm run build      # dry-run deploy (validates config)
npm run deploy     # deploy to Cloudflare
npm test           # run tests
```

## Secrets (set via Wrangler, not in `wrangler.toml`)

| Secret | Purpose |
|--------|---------|
| `RELAY_SECRET` | Shared HMAC secret for device authentication |
| `GITHUB_ISSUE_PAT` | Fine-grained GitHub PAT (Issues: Read & Write) |
| `GITHUB_ISSUE_REPO` | Target repo in `owner/repo` format |
| `APNS_TEAM_ID` | Apple Developer Team ID for push notifications |
| `APNS_KEY_ID` | APNs signing key ID |
| `APNS_PRIVATE_KEY` | APNs P8 private key (PEM format) |

## Custom Domain

The relay is accessible at `issues.chau7.sh`. Configure via Cloudflare dashboard:
Workers > chau7-relay > Settings > Domains & Routes > Custom Domain.

## Protocol

See [`../chau7-remote/docs/PROTOCOL.md`](../chau7-remote/docs/PROTOCOL.md) for the frame format,
encryption scheme, and pairing flow.
