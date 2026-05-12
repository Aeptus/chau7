# Chau7 Issues (Cloudflare Worker + Durable Objects)

Receives bug reports from Chau7, rate-limits submissions per IP, and forwards
validated payloads to a private GitHub issue intake repository.

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

## Secrets (set via Wrangler, not in `wrangler.toml`)

| Secret | Purpose |
|--------|---------|
| `GITHUB_ISSUE_PAT` | Fine-grained GitHub PAT (Issues: Read & Write) |
| `GITHUB_ISSUE_REPO` | Target repo in `owner/repo` format |

## Custom Domain

The issue intake worker should be exposed at `issues.chau7.sh`. Configure via
Cloudflare dashboard: Workers > chau7-issues > Settings > Domains & Routes >
Custom Domain.
