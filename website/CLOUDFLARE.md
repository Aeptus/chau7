# Cloudflare Deployment

This site is ready to deploy as a static Cloudflare Pages project. There is no build step.

## One-time auth

Use either of these:

- `wrangler login`
- `export CLOUDFLARE_API_TOKEN=...`

I checked local Wrangler on March 11, 2026 and this machine is currently not logged in.

## Direct deploy from this folder

```bash
cd /Users/christophehenner/Downloads/Repositories/Chau7/website
wrangler pages deploy . --project-name chau7-website
```

Preview deploy:

```bash
cd /Users/christophehenner/Downloads/Repositories/Chau7/website
wrangler pages deploy . --project-name chau7-website --branch preview
```

## Local Cloudflare preview

```bash
cd /Users/christophehenner/Downloads/Repositories/Chau7/website
wrangler pages dev .
```

## Dashboard setup

If you prefer Git-based deploys in the Cloudflare dashboard:

1. Create a new Pages project.
2. Connect the repository.
3. Set the build command to blank.
4. Set the build output directory to `.`.
5. Deploy.

## Files added for Pages

- `wrangler.jsonc`: tells Cloudflare this is a Pages project with the current directory as output.
- `_headers`: basic security headers and conservative caching rules.
- `_redirects`: optional extensionless routes like `/mcp` and `/features/<slug>`.
