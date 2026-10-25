# Chau7

Your coding agents are running. All of them. Across models, across windows, sometimes at 3 AM. Chau7 is the macOS terminal that notices they exist, tracks what they cost, and lets you steer from the outside. Named after a sock. We're not even sorry.

> **Release status:** Chau7 for macOS is the Rust/GPUI app in [`apps/chau7-next`](apps/chau7-next/README.md). The former SwiftUI/AppKit app has been removed from this repository; it remains in git history and in prior release tags. Releases from `v*` tags publish the Rust production build. See the [production release guide](docs/rust-port/PRODUCTION-RELEASE.md) and [parity status](docs/rust-port/PARITY.md).

[![Release](https://github.com/aeptus/chau7/actions/workflows/release.yml/badge.svg)](https://github.com/aeptus/chau7/actions/workflows/release.yml)
![License](https://img.shields.io/badge/license-AGPL--3.0-blue)

## What it does

- **See every agent.** Detects 13+ AI tools automatically: Claude Code, Codex, Cursor, Windsurf, Copilot, Aider, Cline, Continue, Goose, Devin, Mentat, Amazon Q, Amp. Knows when they finish, fail, or need approval. Zero config.
- **Know what it costs.** Per-run token counts, cost tracking, tool call distribution. Across providers, across models. All in one place.
- **Steer from the outside.** MCP tools over an owner-only local Unix socket. Read terminal output, send input, approve tool use, launch agents, stop them. Control from another terminal, a script, or your phone.
- **Trust it.** Everything stays on your machine. No analytics, no heartbeats, no "anonymous" usage data. API keys forwarded by the local proxy, never stored. [Full privacy details](PRIVACY.md).
- **The terminal underneath.** Rust from the terminal emulator to the GPUI interface, with GPU rendering through Metal. Context Token Optimization cuts ~40% off agent token usage. Tabs auto-group by git repo. Not Electron. Not a wrapper.

## FAQ

**Why is it named Chau7?** Long story involving a sock, a French RPG audio comedy, and questionable life choices. [The origin story](https://chau7.sh/about) explains everything. Or nothing. Depends on your tolerance for absurdity.

**Why AGPL?** Chau7 is free software. Use it on your machine, modify it, share it. If you offer a modified version as a service, share your changes too. That's the deal.

**Does the proxy send my data anywhere?** No. `chau7-proxy` runs locally. API keys pass through to the original provider. Nothing is stored, nothing is transmitted elsewhere. See [SECURITY.md](SECURITY.md) for the full picture.

**Is it stable?** It's a beta built by one person with a lot of AI agents helping. It works well enough that we use it every day. It crashes occasionally. We fix things fast.

## Layout

```
apps/
  chau7-next/               # Chau7 for macOS: Rust/GPUI app (Cargo workspace)
  chau7-ios/                # Native iOS companion app
    Chau7Core/              #   Shared Swift package used by the iOS app and widget
crates/                     # Shared Rust workspace (own toolchain and lockfile)
  chau7_terminal/           #   Terminal emulator, used by the macOS and iOS apps
  chau7_optim/              #   Context Token Optimization engine
  chau7_md/                 #   Terminal markdown renderer
services/
  chau7-proxy/              # Go TLS proxy for API analytics
  chau7-relay/              # Cloudflare Workers relay
  chau7-remote/             # Go relay client for macOS
  chau7-issues/             # Bug-report intake worker
scripts/                    # Repo-level CI and build orchestration
```

- [macOS app (Rust/GPUI)](apps/chau7-next/README.md), port history in [docs/rust-port](docs/rust-port/)
- [iOS app](apps/chau7-ios/README.md)
- [Rust terminal crate](crates/chau7_terminal/README.md)
- [Analytics proxy](services/chau7-proxy/README.md)
- [Relay service](services/chau7-relay/README.md)
- [Remote agent](services/chau7-remote/README.md)
- [Remote protocol](services/chau7-remote/docs/PROTOCOL.md)
- [Scripts reference](scripts/README.md)
- [Documentation map](docs/README.md)

## Install

```bash
brew tap aeptus/chau7
brew install --cask chau7
```

Or grab the DMG from the [latest release](https://github.com/aeptus/chau7/releases/latest). Release builds are Developer ID signed and notarized; a release published before the Rust switch contains the former Swift app.

## Build

```bash
cd apps/chau7-next
cargo run                         # development build, runs as "Chau7 Next"
cargo test --workspace            # verify you didn't break anything
./scripts/bundle-macos.sh         # optimized "Chau7 Next.app" bundle in target/bundle
```

Local builds default to the side-by-side `next` channel (`com.chau7.next`, its own
data folders). `CHANNEL=production RELEASE_VERSION=<semver> BUILD_NUMBER=<n>
./scripts/bundle-macos.sh` builds the production `Chau7.app` that releases ship.
See the [Chau7 Next README](apps/chau7-next/README.md) for build modes and data
locations.

Requirements: macOS 13+, Xcode 26.6 and the tool baseline in [mise.toml](mise.toml). The bundle script also builds the Go helpers (`services/chau7-proxy`, `services/chau7-remote`) and the shared `crates/` tools when Go is installed. See [contributor setup](CONTRIBUTING.md#setting-up).

## Local CI

```bash
mise install
mise exec -- pnpm install
mise exec -- pnpm setup:check
```

`pre-commit` runs `pnpm quality:staged`. `pre-push` runs `pnpm quality:prepush`, which scopes to the affected integration surface and upgrades to full validation for high-impact changes.

## Rule #1

Document decisions near the code. Every subdirectory has a README explaining its contents. When someone reads a file, the *why* should be reachable without leaving the directory. If you're looking for the canonical doc entry points, see the [documentation map](docs/README.md).

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). We read every PR. Yes, actually.

## License

[AGPL 3.0](LICENSE). [Privacy](PRIVACY.md). Third-party notices in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
