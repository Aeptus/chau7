# Chau7 Relay (Cloudflare Workers + Durable Objects)

Forwards encrypted frames between macOS and iOS clients and handles APNs push
notifications for offline devices. The relay does not inspect or store payloads.

If `RELAY_SECRET` is set to a real shared secret, the Worker requires HMAC
authentication for relay and push requests. If it is left unset or left at the
shipped placeholder value, the Worker accepts unauthenticated requests so older
clients continue to work during rollout.

## Routes

| Method | Path | Purpose |
|--------|------|---------|
| GET | `/` | Landing page (HTML) |
| WS | `/connect/:deviceId?role=mac\|ios` | WebSocket relay between paired devices |
| POST | `/push/register/:deviceId` | Register an iOS device for APNs push |
| POST | `/push/notify/:deviceId` | Send a push notification to a paired iOS device |

## Source Files

| File | Purpose |
|------|---------|
| `src/worker.ts` | Cloudflare Worker entry point — routing and auth |
| `src/session.ts` | `SessionDO` Durable Object — WebSocket relay, push registration, APNs |
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
| `APNS_TEAM_ID` | Apple Developer Team ID for push notifications |
| `APNS_KEY_ID` | APNs signing key ID |
| `APNS_PRIVATE_KEY` | APNs P8 private key (PEM format) |

Do not configure `GITHUB_ISSUE_PAT` or `GITHUB_ISSUE_REPO` here. Issue
reporting is owned exclusively by `services/chau7-issues` and
`issues.chau7.sh`.

## Custom Domain

The relay should be exposed at `relay.chau7.sh`. Configure via Cloudflare dashboard:
Workers > chau7-ios-relay > Settings > Domains & Routes > Custom Domain.

## Protocol

See [`../chau7-remote/docs/PROTOCOL.md`](../chau7-remote/docs/PROTOCOL.md) for the frame format,
encryption scheme, and pairing flow.
