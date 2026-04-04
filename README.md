# Chau7

Chau7 started as a personal project and, honestly, an experiment. The repository and codebase still need significant refactoring and cleanup. We're actively working through that.

The AI-native terminal for macOS. Named after a sock. We're not even sorry.

Chau7 detects your AI agents, optimizes their context tokens, tracks what they cost you, and gives you 30+ MCP tools to control everything from another terminal. GPU-accelerated Metal rendering. Not Electron. Not a wrapper.

[![CI](https://github.com/aeptus/chau7/actions/workflows/ci.yml/badge.svg)](https://github.com/aeptus/chau7/actions/workflows/ci.yml)
![License](https://img.shields.io/badge/license-AGPL--3.0-blue)

## What it does

- **AI agent detection**: Claude Code, Codex, Cursor, Windsurf, Copilot, Aider, Cline, Continue, Goose, Devin, Mentat, Amazon Q, Amp. Automatic. Zero config.
- **Context Token Optimization**: Rewrites CLI commands to trim context windows. ~40% token savings on average.
- **36 MCP tools**: Control tabs, query history, manage sessions, read terminal output, launch agents, manage repos. All local, all over a Unix socket.
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
