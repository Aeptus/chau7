# Chau7 Relay (Cloudflare Workers + Durable Objects)

This service forwards encrypted frames between macOS and iOS clients. It does
not inspect payloads.

The relay fails closed unless `RELAY_SECRET` is set to a real shared secret.
The shipped placeholder in `wrangler.toml` is intentionally rejected at runtime.

## Build/Deploy
From this directory:

```bash
npm install
npm run build
npm run deploy
```

## Cloudflare
Set the Cloudflare build root to `services/chau7-relay`.

See `../chau7-remote/docs/PROTOCOL.md` for protocol details.
