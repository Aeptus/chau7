# Chau7 Issues (Cloudflare Worker + Durable Objects)

Receives bug reports from Chau7, rate-limits submissions per IP, and forwards
validated payloads to a private GitHub issue intake repository.

This is the only Worker that should own `issues.chau7.sh`. Do not add issue
reporting routes or `GITHUB_ISSUE_*` secrets to the remote relay Worker.

## Routes

| Method | Path | Purpose |
|--------|------|---------|
| GET | `/` | Landing page (HTML) |
| POST | `/` or `/issue` | Create an authenticated GitHub issue via the private intake repo |

Issue creation is a native-app endpoint and does not enable CORS. Each POST
must include an `Authorization: Bearer` token in the relay's v2 HMAC format,
plus `X-Chau7-Device-ID` and `X-Chau7-Role` (`mac` or `ios`). Tokens must use
the `issues` scope and are single-use. Browser preflights are rejected.

## Source Files

| File | Purpose |
|------|---------|
| `src/worker.js` | Cloudflare Worker entry point and rate-limit Durable Object |

## Build / Deploy

```bash
npm install
npm run build
npm run deploy
```

## Production Cutover

`issues.chau7.sh` used to be served by a legacy combined Worker named
`chau7-relay`. To avoid a dual setup, cut traffic over to this dedicated Worker
and retire the legacy Worker in one operation:

```bash
GITHUB_ISSUE_PAT="github_pat_..." \
GITHUB_ISSUE_REPO="owner/private-intake-repo" \
npm run cutover
```

Before cutover, provision `RELAY_SECRET` on `chau7-issues` through the
Cloudflare dashboard or Wrangler. It must exactly match the secret configured
on `chau7-relay`; the cutover script does not accept or upload this secret.

The cutover script:

1. deploys `chau7-issues` without moving domain traffic;
2. installs `GITHUB_ISSUE_PAT` and `GITHUB_ISSUE_REPO` on `chau7-issues`;
3. attaches `issues.chau7.sh` to `chau7-issues`;
4. verifies the landing page and confirms that an unauthenticated POST is
   rejected;
5. deletes the legacy `chau7-relay` Worker by default.

Set `RUN_SMOKE=0` to skip the authentication check, or `DELETE_LEGACY_WORKER=0` to keep
the legacy Worker while deleting only its stale issue secrets.

## Secrets (set via Wrangler, not in `wrangler.toml`)

| Secret | Purpose |
|--------|---------|
| `GITHUB_ISSUE_PAT` | Fine-grained GitHub PAT (Issues: Read & Write) |
| `GITHUB_ISSUE_REPO` | Target repo in `owner/repo` format |
| `RELAY_SECRET` | Shared HMAC key used by paired clients to mint scoped issue tokens; must match `chau7-relay` |

Optionally set `GITHUB_ISSUE_ALLOWED_LABELS` to a comma-separated allowlist.
Labels outside that list, malformed labels, and requests with more than five
labels are rejected. If unset, the endpoint accepts no caller-supplied labels.

Paired clients need a pairing payload that contains `relay_secret`. Older
pairing payloads without it cannot submit directly; the macOS reporter can
still save the report locally, and the iOS reporter offers file export.

## Custom Domain

The issue intake worker should be exposed at `issues.chau7.sh`. Configure via
Cloudflare dashboard: Workers > chau7-issues > Settings > Domains & Routes >
Custom Domain.
