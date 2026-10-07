# Chau7 Relay (Cloudflare Workers + Durable Objects)

Forwards encrypted frames between macOS and iOS clients and handles APNs push
notifications for offline devices. WebSocket frames stay opaque and are not persistently stored. The separate pending-state REST and APNs paths carry server-readable metadata with bounded retention (below).

## Authentication

The Worker fails **closed**. Provide the shared secret as a Worker secret
(`wrangler secret put RELAY_SECRET`); requests then require a valid token. If
`RELAY_SECRET` is absent, authenticated routes return **503** — unless you
explicitly opt into unauthenticated rollout mode by setting the
`RELAY_ALLOW_UNAUTHENTICATED = "true"` var (logged as a warning on use).

Tokens are **scoped, single-use HMAC-SHA256 bearer tokens** carried only in the
`Authorization: Bearer` header (never the URL query string):

```
wire:    v2.{ts}.{nonce}.{scope}.{base64url_sig}
signed:  v2:{deviceId}:{role}:{scope}:{ts}:{nonce}
```

- bound to a single `deviceId`, `role` (`mac`/`ios`), and `scope`
  (`connect`/`push`/`pending`), so a token cannot be replayed across endpoints;
- valid for 120s (with 30s future skew tolerance);
- the `nonce` is enforced single-use by the Durable Object, defeating
  capture-and-replay within the validity window;
- verified in constant time via `crypto.subtle.verify`.

The relay additionally enforces per-device, per-route rate limits, caps request
bodies (64 KB) and relayed frames (1 MB), bounds persisted pending-state, and
applies WebSocket backpressure (dropping/closing slow receivers).

## Routes

| Method | Path | Role | Scope |
|--------|------|------|-------|
| GET | `/` | — | — (landing page) |
| GET | `/runtime` | — | — (deployment identity) |
| WS | `/connect/:deviceId?role=mac\|ios` | mac/ios | connect |
| POST | `/push/register/:deviceId` | mac | push |
| POST | `/push/notify/:deviceId` | mac | push |
| GET | `/pending/:deviceId` | ios | pending |
| POST | `/pending/:deviceId` | mac | pending |
| DELETE | `/pending/:deviceId` | mac | pending |

## Source Files

| File | Purpose |
|------|---------|
| `src/worker.ts` | Cloudflare Worker entry point — routing and scoped auth |
| `src/session.ts` | `SessionDO` Durable Object — hibernatable WebSocket relay, replay defense, rate limiting, push, APNs |
| `src/apns-token-broker.ts` | One globally addressed provider-token owner per Apple signing key |
| `src/auth.js` | Relay secret validation + fail-closed auth-mode resolver |
| `src/token.js` | Scoped single-use token mint/parse/verify |
| `src/validation.js` | Body size limits, safe JSON parsing, payload sanitizers |
| `src/apns.js` | APNs payload + reason-based registration removal |
| `src/ratelimit.js` | Per-route token-bucket rate limiter |

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

## Remote data and retention

WebSocket terminal/control frames are end-to-end encrypted between the paired
Mac and iPhone. The relay forwards their ciphertext and does not persist frames.
The separate `/pending` REST snapshot is **server-readable**, protected in transit
by HTTPS and device/role-scoped authentication. It can contain approval commands,
prompt text, directory paths, and project/tab metadata. APNs registration tokens
and notification titles/bodies are also visible to the relay and Apple for delivery.

| Stored record | Lifetime and deletion |
|---|---|
| Pending snapshot | Four hours after the latest accepted POST. GET deletes expired state and returns empty arrays with the epoch timestamp; it never returns an expired snapshot. Authenticated mac-role DELETE removes it immediately. |
| Push registration | Thirty days after the latest registration. Re-registering refreshes that lifetime; an explicit `notifications_authorized: false` registration revokes it immediately, as does an APNs invalid-token response. Expired registrations are not notified. |
| Replay nonce | Through the end of the token's final accepted second (120-second TTL, plus up to 30 seconds of future clock skew). Cleanup never drops a nonce while that token can still authenticate. A full live nonce budget rejects new admission. |

One Durable Object alarm tracks the earliest retained deadline. Alarm cleanup,
expiry reads, and writes use storage transactions and survive eviction; idle
objects with newly stored records have a scheduled cleanup. Legacy records are
adopted on their next activation: invalid or expired timestamps are deleted then.
Existing dormant legacy objects without an alarm are not retroactively awakened
by a code change; a deployment must arrange their activation/removal if immediate
legacy cleanup is required. No production rollout is implied by these source tests.
An alarm can execute late during a platform outage, so expiry is also enforced
on reads and before push delivery. Empty keys and unused alarms are removed.
