# Chau7

Your coding agents are running. All of them. Across models, across windows, sometimes at 3 AM. Chau7 is the macOS terminal that notices they exist, tracks what they cost, and lets you steer from the outside. Named after a sock. We're not even sorry.

[![CI](https://github.com/aeptus/chau7/actions/workflows/ci.yml/badge.svg)](https://github.com/aeptus/chau7/actions/workflows/ci.yml)
![License](https://img.shields.io/badge/license-AGPL--3.0-blue)

## What it does

- **See every agent.** Detects 13+ AI tools automatically: Claude Code, Codex, Cursor, Windsurf, Copilot, Aider, Cline, Continue, Goose, Devin, Mentat, Amazon Q, Amp. Knows when they finish, fail, or need approval. Zero config.
- **Know what it costs.** Per-run token counts, cost tracking, tool call distribution. Across providers, across models. All in one place.
- **Steer from the outside.** 36 MCP tools over a local Unix socket. Read terminal output, send input, approve tool use, launch agents, stop them. Control from another terminal, a script, or your phone.
- **Trust it.** Everything stays on your machine. No analytics, no heartbeats, no "anonymous" usage data. API keys forwarded by the local proxy, never stored. [Full privacy details](PRIVACY.md).
- **The terminal underneath.** Rust backend via FFI. Metal GPU rendering, triple-buffered, VSync-synced. Context Token Optimization cuts ~40% off agent token usage. Tabs auto-group by git repo. Not Electron. Not a wrapper.

## FAQ

**Why is it named Chau7?** Long story involving a sock, a French RPG audio comedy, and questionable life choices. [The origin story](https://chau7.sh/about) explains everything. Or nothing. Depends on your tolerance for absurdity.

**Why AGPL?** Chau7 is free software. Use it on your machine, modify it, share it. If you offer a modified version as a service, share your changes too. That's the deal.

**Does the proxy send my data anywhere?** No. `chau7-proxy` runs locally. API keys pass through to the original provider. Nothing is stored, nothing is transmitted elsewhere. See [SECURITY.md](SECURITY.md) for the full picture.

**Is it stable?** It's a beta built by one person with a lot of AI agents helping. It works well enough that we use it every day. It crashes occasionally. We fix things fast.

## Layout

```
apps/
  chau7-macos/              # Swift + AppKit + Metal macOS app
    rust/                   # Rust workspace (4 crates)
      chau7_terminal/       #   Terminal emulator FFI bindings
      chau7_parse/          #   Parsing helpers
      chau7_optim/          #   Context Token Optimization engine
      chau7_md/             #   Terminal markdown renderer
    chau7-proxy/            # Go TLS proxy for API analytics
  chau7-ios/                # Native iOS companion app
services/
  chau7-relay/              # Cloudflare Workers relay
  chau7-remote/             # Go relay client for macOS
Scripts/                    # Repo-level CI and build orchestration
```

- [macOS app](apps/chau7-macos/README.md)
- [iOS app](apps/chau7-ios/README.md)
- [Rust terminal crate](apps/chau7-macos/rust/chau7_terminal/README.md)
- [Relay service](services/chau7-relay/README.md)
- [Remote agent](services/chau7-remote/README.md)
- [Remote protocol](services/chau7-remote/docs/PROTOCOL.md)
- [Scripts reference](Scripts/README.md)
- [Feature inventory](apps/chau7-macos/docs/FEATURES.md)
- [Documentation map](docs/README.md)

## Build

The fast way (knit the sock, wear the sock):

```bash
cd apps/chau7-macos
./Scripts/knit           # build release + launch
./Scripts/knit debug     # build debug + launch (for when you want to see what went wrong)
./Scripts/knit --no-run  # build only (commitment issues, we get it)
```

`knit` hot-swaps the binary into your existing app bundle. No full rebuild, no re-signing dance. If no bundle exists yet, it falls back to the full `build-and-run.sh` ceremony.

The slow way (for when you want to feel in control):

```bash
cd apps/chau7-macos
swift build              # compile
swift test               # verify you didn't break anything
./Scripts/build-app.sh   # create a proper .app bundle with notifications and everything
```

Requirements: macOS 14+, Xcode 26+. The Rust terminal backend and Go proxy are pre-built in the repo. If you want to rebuild them: Rust toolchain for `rust/chau7_terminal`, Go 1.25+ for `chau7-proxy`.

## Local CI

```bash
brew install lefthook
./Scripts/install-hooks
```

`pre-commit` runs the fast gate (format + lint + build). `pre-push` runs the full gate (format + lint + build + test across Swift, Rust, Go, and the relay).

## Rule #1

Document decisions near the code. Every subdirectory has a README explaining its contents. When someone reads a file, the *why* should be reachable without leaving the directory. If you're looking for the canonical doc entry points, see the [documentation map](docs/README.md).

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). We read every PR. Yes, actually.

## License

[AGPL 3.0](LICENSE). [Privacy](PRIVACY.md). Third-party notices in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
