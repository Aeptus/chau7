# Contributing to Chau7

So you want to contribute to a terminal named after a sock. Excellent judgment.

## Reporting Bugs

The fastest path: use the in-app bug reporter (Option+Cmd+I). It captures diagnostic context automatically and submits via an encrypted relay to a [private GitHub repository](https://github.com/aeptus/chau7-issue-intake) that only maintainers can access. You choose what data to include — all diagnostic sections are off by default. [Privacy details](PRIVACY.md). The relay is implemented in [`services/chau7-relay/src/worker.ts`](services/chau7-relay/src/worker.ts) and the in-app privacy disclosure is in [`IssueReportingPrivacyView.swift`](apps/chau7-macos/Sources/Chau7/Logging/IssueReportingPrivacyView.swift).

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

### Environment Requirements

| Tool | Version | Required For | Install |
|------|---------|-------------|---------|
| macOS | 14+ | Everything | — |
| Xcode | 26+ (Swift 6+) | Swift build + test | Mac App Store |
| SwiftFormat | latest | Pre-commit hook | `brew install swiftformat` |
| SwiftLint | latest | Pre-commit hook | `brew install swiftlint` |
| lefthook | any | Git hooks | `brew install lefthook` |
| gitleaks | any | Pre-commit secret scan | `brew install gitleaks` |
| shellcheck | any | Pre-commit shell lint | `brew install shellcheck` |
| ruff | any | Pre-commit Python lint | `brew install ruff` |
| golangci-lint | any | Go lint | `brew install golangci-lint` |
| periphery | any | Local CI dead-code scan | `brew install periphery` |
| cargo-deny | any | Local CI Rust dep audit | `cargo install cargo-deny` |
| jscpd | any | Local CI duplication scan | `npm install -g jscpd` |
| Rust | stable | Terminal backend rebuild | [rustup.rs](https://rustup.rs) |
| Go | 1.25+ | Proxy and remote agent | `brew install go` |
| Node.js | 22+ | Relay service | `brew install node` |

The Rust terminal backend and Go proxy ship pre-built in the repo. You only need the Rust and Go toolchains if you're modifying those components. Swift, SwiftFormat, SwiftLint, lefthook, gitleaks, shellcheck, ruff, and golangci-lint are required for all contributors; periphery, cargo-deny, and jscpd are only required when running the full local CI (`./Scripts/ci-local`).

### Bypassing a check

Hooks use deterministic escape hatches so you can unblock yourself without reaching for `--no-verify`:

| Situation | Escape hatch |
|---|---|
| Whole hook system, one commit | `LEFTHOOK=0 git commit ...` |
| Whole hook system, git fallback | `git commit --no-verify` |
| Forbidden-file guard only | `CHAU7_SKIP_FORBIDDEN_CHECK=1 git commit ...` |
| Anti-slop regex suite only | `CHAU7_SKIP_ANTISLOP=1 git commit ...` |
| Design-system ratchet only | `CHAU7_SKIP_DS_CHECK=1 git commit ...` |
| Docs-staged rule only | `CHAU7_SKIP_DOC_CHECK=1 git commit ...` |
| AI pre-commit review only | `CHAU7_PRE_COMMIT_REVIEW_ENABLED=0 git commit ...` |
| Silence the "Chau7 not running" banner | `CHAU7_PRE_COMMIT_REVIEW_QUIET=1 git commit ...` |

Any use of a bypass should be explained in the commit message. The whole point of the ratchet is that touched files ratchet up quality — bypassing defeats that.

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
