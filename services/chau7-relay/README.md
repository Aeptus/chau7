# Chau7 Relay (Cloudflare Workers + Durable Objects)

Forwards encrypted frames between macOS and iOS clients and handles APNs push
notifications for offline devices. The relay does not inspect or store payloads.

## Authentication

The Worker fails **closed** unless a valid `RELAY_AUTH_KEYS` keyring is
configured. The server/operator retains its canonical 256-bit root keys;
each derived credential covers only one Mac device ID and one role. Macs hold
both local role keys for pairing; phones receive only the iOS role key.
A credential for device A cannot mint access to B or switch from iOS to Mac.
The old global `RELAY_SECRET` and v2 admission tokens are rejected.

Tokens travel only in `Authorization: Bearer`, never the query string:

```
credential = base64url(HMAC-SHA256(raw_root, "chau7-v3:{key_id}:{device_id}:{role}"))
wire:   v3.{key_id}.{ts}.{nonce}.{scope}.{base64url_signature}
signed: v3:{key_id}:{device_id}:{role}:{scope}:{ts}:{nonce}
```

The signature uses the UTF-8 derived credential as its HMAC key. Tokens last
120 seconds (+30 seconds future clock skew); Durable Object nonce admission
prevents reuse. Metadata binds device, role, scope and key ID. Only
`ENVIRONMENT=development` plus `RELAY_ALLOW_UNAUTHENTICATED=true`, with no
keyring supplied, enables explicit local open mode. A malformed keyring
never falls back to open mode; issue intake always requires authentication.

### Provisioning, rotation and revocation

See the [remote credential workflow](../chau7-remote/docs/CREDENTIALS.md).
`RELAY_AUTH_KEYS` is a JSON Worker secret with `current: {id, secret}` and
an optional `previous: {id, secret, grace_started_at, accept_until}`. Roots
are unpadded canonical base64url encodings of 32 random bytes; IDs are ASCII
letters, digits, `_` or `-` (1–32 characters). Both Workers must receive the
same keyring through a separately authorized operator deployment.

Rotation accepts one previous root for an explicit overlap of at most 24
hours. Clients must be reprovisioned and phones scan a new secure QR; private
identity and paired-device trust are preserved. `RELAY_REVOKED_DEVICES` is an
optional JSON array of at most 256 Mac device IDs, denying both current and
previous keys for those namespaces. Individual phone trust is managed by the
Mac's paired-device revocation, not this namespace-level list.

Existing hibernatable sockets retain their admitted device, role and key ID.
Every forwarded message checks current policy for sender and recipient and
closes expired/revoked/legacy admissions. Quiet sockets are checked when they
next send or receive; this does not promise an immediate idle disconnect or
prove live deployment configuration.

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

## Source Files

| File | Purpose |
|------|---------|
| `src/worker.ts` | Cloudflare Worker entry point — routing and scoped auth |
| `src/session.ts` | `SessionDO` Durable Object — hibernatable WebSocket relay, replay defense, rate limiting, push, APNs |
| `src/apns-token-broker.ts` | One globally addressed provider-token owner per Apple signing key |
| `src/auth.js` | Device/role credential derivation, rotation and fail-closed policy |
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
| `RELAY_AUTH_KEYS` | Server-only JSON root keyring for device/role-derived credentials |
| `RELAY_REVOKED_DEVICES` | Optional JSON array of revoked Mac device IDs |
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
