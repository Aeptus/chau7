# Chau7

The AI-native terminal for macOS. Named after a sock. We're not even sorry.

Chau7 detects your AI agents, optimizes their context tokens, tracks what they cost you, and gives you 20 MCP tools to control everything from another terminal. GPU-accelerated Metal rendering. Not Electron. Not a wrapper.

[![CI](https://github.com/aeptus/chau7/actions/workflows/ci.yml/badge.svg)](https://github.com/aeptus/chau7/actions/workflows/ci.yml)
![License](https://img.shields.io/badge/license-AGPL--3.0-blue)

> TODO: Screenshots. A terminal emulator without screenshots is like a sock without a foot.

## What it does

- **AI agent detection**: Claude Code, Codex, Cursor, Windsurf, Copilot, Aider, Cline, Continue, Goose, Devin, Mentat, Amazon Q, Amp. Automatic. Zero config.
- **Context Token Optimization**: Rewrites CLI commands to trim context windows. ~40% token savings on average.
- **20 MCP tools**: Control tabs, query history, manage sessions, read terminal output. All local, all over a Unix socket.
- **Notifications that actually work**: Know when your agent finishes, needs permission, or gets stuck. Per-tab, per-tool, cross-window.
- **Tab grouping by repository**: Tabs auto-group by git root. Move groups between windows. Color-coded by provider.
- **Telemetry**: Per-run token counts, cost tracking, tool call distribution. All local, nothing phones home.
- **Metal GPU rendering**: Rust terminal backend via FFI, triple-buffered, VSync-synced. Your scrollback is fast.

## FAQ

**Why is it named Chau7?** Long story involving a sock, a French RPG audio comedy, and questionable life choices. [The origin story](https://chau7.sh/about) explains everything. Or nothing. Depends on your tolerance for absurdity.

**Why AGPL?** Chau7 is free software. Use it on your machine, modify it, share it. If you offer a modified version as a service, share your changes too. That's the deal.

**Does the proxy send my data anywhere?** No. `chau7-proxy` runs locally. API keys pass through to the original provider. Nothing is stored, nothing is transmitted elsewhere. See [SECURITY.md](SECURITY.md) for the full picture.

**Is it stable?** It's a beta built by one person with a lot of AI agents helping. It works well enough that we use it every day. It crashes occasionally. We fix things fast.

## Layout

```
apps/
  chau7-macos/      # Swift + AppKit + Metal macOS app
  chau7-ios/        # Native iOS companion app
services/
  chau7-relay/      # Cloudflare Workers relay
  chau7-remote/     # Go relay client for macOS
```

- [macOS app](apps/chau7-macos/README.md)
- [iOS app](apps/chau7-ios/README.md)
- [Relay service](services/chau7-relay/README.md)
- [Remote agent](services/chau7-remote/README.md)
- [Remote control spec](docs/remote-control/SPEC-Remote-Control.md)

## Build

```bash
cd apps/chau7-macos
swift build
swift test
```

Requirements: macOS 14+, Xcode 26+. The Rust terminal backend and Go proxy are pre-built in the repo. If you want to rebuild them: Rust toolchain for `rust/chau7_terminal`, Go 1.22+ for `chau7-proxy`.

## Local CI

```bash
brew install lefthook
./Scripts/install-hooks
```

`pre-commit` runs the fast gate (format + lint + build). `pre-push` runs the full gate (format + lint + build + test across Swift, Rust, Go, and the relay).

## Rule #1

Document decisions near the code. Every subdirectory has a README explaining its contents. When someone reads a file, the *why* should be reachable without leaving the directory. If you're looking for architecture docs, see [`docs/ARCHITECTURE.md`](apps/chau7-macos/docs/ARCHITECTURE.md).

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). We read every PR. Yes, actually.

## License

[AGPL 3.0](LICENSE). Third-party notices in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
