# Contributing to Chau7

Thanks for your interest in contributing to Chau7! Here's how to get involved.

## Reporting Bugs

- Use the in-app bug reporter (Option+Cmd+I) for the fastest path — it captures diagnostic context automatically.
- Or open an issue at [github.com/aeptus/chau7](https://github.com/aeptus/chau7/issues).
- Include: what you did, what you expected, what happened, and your macOS version.

## Development Setup

```bash
# Clone
git clone https://github.com/aeptus/chau7.git
cd chau7

# Install pre-commit hooks
cd apps/chau7-macos && ./Scripts/install-hooks

# Build
swift build

# Test
swift test

# Run
swift run
```

Requirements: macOS 14+, Xcode 26+, Rust toolchain (for terminal backend), Go 1.22+ (for proxy).

## Code Style

- **Swift**: SwiftFormat + SwiftLint enforce style automatically via pre-commit hooks.
- **Rust**: `cargo fmt` + `cargo clippy`.
- **Go**: `gofmt` + `go vet`.

Don't fight the formatter. If a rule feels wrong, open an issue to discuss changing the rule.

## Pull Request Process

1. Fork the repo and create a branch from `main`.
2. Make your changes. Keep commits focused — one logical change per commit.
3. Run the local CI: `./Scripts/ci-local` (runs format, lint, build, and tests for all targets).
4. Open a PR. Describe what you changed and why.
5. A maintainer will review and may request changes.

## Architecture

- **Rule #1**: Document decisions near the code. Each subdirectory has a README explaining its contents.
- **Chau7Core** is the testable library (no UI dependencies). **Chau7** is the macOS app.
- Terminal rendering is handled by a Rust backend via FFI (`rust/chau7_terminal/`).
- The API proxy (`chau7-proxy/`) is a Go binary. The relay (`services/chau7-relay/`) is a Cloudflare Worker.

See `docs/ARCHITECTURE.md` for the full picture.

## What We're Looking For

- Bug fixes with tests.
- Performance improvements with benchmarks.
- New AI tool integrations (see `Sources/Chau7Core/AIToolRegistry.swift`).
- Localization contributions (currently: English, French, Arabic, Hebrew).
- Documentation improvements.

## What We're Not Looking For (Yet)

- Major architectural refactors without prior discussion.
- Features that add significant complexity for niche use cases.
- Changes that break the pre-commit CI.

## License

By contributing, you agree that your contributions will be licensed under the [AGPL 3.0](LICENSE).
