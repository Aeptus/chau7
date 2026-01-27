# Chau7 Monorepo

This repository hosts the macOS app, iOS app, relay service, and remote agent.

## Layout

```
apps/
  chau7-macos/      # SwiftUI + AppKit macOS app (SwiftPM)
  chau7-ios/        # Native iOS app
services/
  chau7-relay/      # Cloudflare relay (Workers + Durable Objects)
  chau7-remote/     # Go relay client for macOS

docs/
  remote-control/   # Remote control specifications
```

## Quick Links

- macOS app: `apps/chau7-macos/README.md`
- Remote control spec: `docs/remote-control/SPEC-Remote-Control.md`
- Relay service: `services/chau7-relay/README.md`
- Remote agent: `services/chau7-remote/README.md`
- iOS app: `apps/chau7-ios/README.md`

## Build and Test (macOS app)

From `apps/chau7-macos`:

```bash
swift test
swift build
```
