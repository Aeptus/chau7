# Chau7 Issues (Cloudflare Worker + Durable Objects)

Receives bug reports from Chau7, rate-limits submissions per IP, and forwards
validated payloads to a private GitHub issue intake repository.

This is the only Worker that should own `issues.chau7.sh`. Do not add issue
reporting routes or `GITHUB_ISSUE_*` secrets to the remote relay Worker.

## Routes

| Method | Path | Purpose |
|--------|------|---------|
| GET | `/` | Landing page (HTML) |
| POST | `/` or `/issue` | Create a GitHub issue via the private intake repo |
| OPTIONS | `/` or `/issue` | CORS preflight for issue creation |

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

The cutover script:

1. deploys `chau7-issues` without moving domain traffic;
2. installs `GITHUB_ISSUE_PAT` and `GITHUB_ISSUE_REPO` on `chau7-issues`;
3. attaches `issues.chau7.sh` to `chau7-issues`;
4. verifies the landing page and creates one smoke-test GitHub issue;
5. deletes the legacy `chau7-relay` Worker by default.

Set `RUN_SMOKE=0` to skip issue creation, or `DELETE_LEGACY_WORKER=0` to keep
the legacy Worker while deleting only its stale issue secrets.

## Secrets (set via Wrangler, not in `wrangler.toml`)

| Secret | Purpose |
|--------|---------|
| `GITHUB_ISSUE_PAT` | Fine-grained GitHub PAT (Issues: Read & Write) |
| `GITHUB_ISSUE_REPO` | Target repo in `owner/repo` format |

## Custom Domain

The issue intake worker should be exposed at `issues.chau7.sh`. Configure via
Cloudflare dashboard: Workers > chau7-issues > Settings > Domains & Routes >
Custom Domain.
