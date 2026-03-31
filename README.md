# Chau7 Monorepo

This repository hosts the macOS app, iOS app, relay service, and remote agent.

## Rule #1: Document Decisions Near the Code

All code-related decisions must be documented as close as possible to the related code. Prefer inline comments, per-folder `README.md` files, or doc-comments over distant wiki pages or top-level docs. When someone reads a file, the *why* behind its design should be reachable without leaving the directory.

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

## Local CI

Repo-wide local CI is now split into:

- `./Scripts/ci-local-fast`: fast pre-commit gate
- `./Scripts/ci-local`: full pre-push gate
- `./Scripts/install-hooks`: installs Lefthook hooks for this repo

The full gate covers:

- Swift format, lint, build, and tests for `apps/chau7-macos`
- Rust format, clippy, and tests for `apps/chau7-macos/rust`
- Go format, vet, and tests for `apps/chau7-macos/chau7-proxy`
- Go format, vet, and tests for `services/chau7-remote`
- Relay install, test, and dry-run build for `services/chau7-relay`

Recommended setup on macOS:

```bash
brew install lefthook
./Scripts/install-hooks
```

`pre-commit` runs the fast gate. `pre-push` runs the full gate.

Packaging and app launch are intentionally not part of CI.

## Build and Test (macOS app)

From `apps/chau7-macos`:

```bash
swift test
swift build
```
