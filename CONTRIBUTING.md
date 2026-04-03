# Contributing to Chau7

So you want to contribute to a terminal named after a sock. Excellent judgment.

## Reporting Bugs

The fastest path: use the in-app bug reporter (Option+Cmd+I). It captures diagnostic context automatically and submits to our private intake. You choose what data to include. [Privacy details](SECURITY.md).

Or just open an issue here. Include: what you did, what you expected, what happened, and your macOS version. Screenshots help. Logs help more.

## Setting Up

```bash
git clone https://github.com/aeptus/chau7.git
cd chau7

# Install pre-commit hooks (format + lint + build gate)
./Scripts/install-hooks

# Enter the macOS app directory
cd apps/chau7-macos

# Build
swift build

# Test
swift test

# Run (for proper notifications, build the app bundle)
./Scripts/build-app.sh
```

You'll need macOS 14+, Xcode 26+. The Rust terminal backend and Go proxy ship pre-built. If you want to rebuild them: Rust toolchain for `rust/chau7_terminal`, Go 1.22+ for `chau7-proxy`.

## Code Style

SwiftFormat and SwiftLint enforce style via pre-commit hooks. Rust uses `cargo fmt` + `cargo clippy`. Go uses `gofmt` + `go vet`. Don't fight the formatters. If a rule feels wrong, open an issue about the rule, not a PR that ignores it.

## Pull Requests

1. Fork and branch from `main`.
2. Make your changes. One logical change per commit.
3. Run `./Scripts/ci-local` from repo root before pushing. It runs everything the CI will run.
4. Open a PR. Say what you changed and why.
5. We'll review it. We might ask questions. That's not rejection, that's conversation.

## Architecture

Chau7 follows Rule #1: document decisions near the code. Every subdirectory has a README. The canonical doc entry points are listed in [docs/README.md](docs/README.md).

Quick orientation:
- **Chau7Core**: Pure Swift library, no UI. All testable logic lives here.
- **Chau7**: The macOS app. SwiftUI views, AppKit integration, Metal rendering.
- **rust/chau7_terminal**: Rust terminal emulator, accessed via FFI.
- **chau7-proxy**: Go TLS proxy for API analytics.
- **services/chau7-relay**: Cloudflare Worker for the bug report relay and remote control.

## What We're Looking For

- Bug fixes. Especially with tests.
- Performance improvements. Especially with measurements.
- New AI tool integrations. Add a definition to `AIToolRegistry.swift` and you're done.
- Localization. We have English, French, Arabic, and Hebrew. More is welcome.
- Documentation fixes. Typos, stale references, unclear explanations.

## What We're Not Looking For (Yet)

- Major refactors without discussion first. Open an issue, talk about it.
- Features that add complexity for edge cases. We'd rather ship less that works well.
- Changes that break the CI. If the hooks fail, fix before pushing.

## License

By contributing, your work is licensed under the [AGPL 3.0](LICENSE). Same terms as the rest of the project.
