# Contributing to Chau7

So you want to contribute to a terminal named after a sock. Excellent judgment.

## Reporting Bugs

The fastest path: use the in-app bug reporter (Option+Cmd+I). It captures diagnostic context automatically and submits via an encrypted relay to a [private GitHub repository](https://github.com/aeptus/chau7-issue-intake) that only maintainers can access. You choose what data to include — all diagnostic sections are off by default. [Privacy details](PRIVACY.md). The relay is implemented in [`services/chau7-relay/src/worker.ts`](services/chau7-relay/src/worker.ts) and the in-app privacy disclosure is in [`issue_privacy.rs`](apps/chau7-next/crates/chau7_next_core/src/issue_privacy.rs).

Or just open an issue here. Include: what you did, what you expected, what happened, and your macOS version. Screenshots help. Logs help more.

## Setting Up

```bash
git clone https://github.com/aeptus/chau7.git
cd chau7

# Install mise (https://mise.jdx.dev/getting-started.html), then the pinned tools.
mise install
mise exec -- pnpm install       # prepare installs .husky hooks in a clone/worktree
mise exec -- pnpm setup:check   # fails clearly for missing or wrong mandatory tools
mise exec -- python3 -m venv .venv
.venv/bin/pip install -r scripts/requirements-tests.txt # exact Python test dependency lock

# Build and test the macOS app (Rust/GPUI).
cd apps/chau7-next
mise exec -- cargo test --workspace
mise exec -- ./scripts/bundle-macos.sh
# Launch only when desired: open "target/bundle/Chau7 Next.app"

# Shared Rust crates and the iOS app's Swift package.
mise exec -- cargo test --manifest-path ../../crates/Cargo.toml --workspace
mise exec -- swift test --package-path ../chau7-ios/Chau7Core
```

### Environment Requirements

The exact developer tool baseline lives in [mise.toml](mise.toml); both Rust
workspaces (`apps/chau7-next` and `crates/`) additionally enforce their own
`rust-toolchain.toml`. Xcode 26.6 must be installed and selected separately
(`sudo xcode-select --switch /Applications/Xcode_26.6.app/Contents/Developer`).
Rust and Go binaries are generated, ignored artifacts and do not ship in a clean
clone. `bundle-macos.sh` builds the app, the `crates/` helpers (`chau7-optim`,
`chau7-md`) and, when Go is installed, the proxy and remote helpers.

`pnpm setup:check` checks pinned mandatory tools, real author identity and hooks;
it does not build, install, launch or terminate Chau7. `pnpm hooks:check` detects
missing hook configuration. `pnpm install` skips hook preparation in CI and when
this package is copied outside its own Git repository. Hooks share the repository's
relative `.husky` path across worktrees. CI remains the required server-side gate.
The legacy `tools/git-hooks` path includes pre-commit, pre-push and post-commit
maintenance shims. Optional advisory pre-commit AI review is separately documented;
missing security audit tools are blocking, never silently skipped.

Run `pnpm test` for Node quality tests and both Python unittest suites (review
helper and isolated PentAGI logic). These tests use temporary fixtures and do not
contact live Chau7 or require a running container. For the iOS app's shared Swift
code, run `swift test --package-path apps/chau7-ios/Chau7Core`; the iOS app build
itself runs through `xcodebuild` in native CI.

### Bypassing a check

Hooks use deterministic escape hatches so you can unblock yourself without reaching for `--no-verify`. The hook layer is `.husky/`; real policy lives in `scripts/quality/registry.mjs` and runs through `pnpm quality:*`.

| Situation | Escape hatch |
|---|---|
| Whole hook system, git fallback | `git commit --no-verify` |
| Forbidden-file guard only | `CHAU7_SKIP_FORBIDDEN_CHECK=1 git commit ...` |
| Anti-slop regex suite only | `CHAU7_SKIP_ANTISLOP=1 git commit ...` |
| Design-system ratchet only | `CHAU7_SKIP_DS_CHECK=1 git commit ...` |
| Docs-staged rule only | `CHAU7_SKIP_DOC_CHECK=1 git commit ...` |
| AI pre-commit review only | `CHAU7_PRE_COMMIT_REVIEW_ENABLED=0 git commit ...` |
| Silence the "Chau7 not running" banner | `CHAU7_PRE_COMMIT_REVIEW_QUIET=1 git commit ...` |

Any use of a bypass should be explained in the commit message. The whole point of the ratchet is that touched files ratchet up quality — bypassing defeats that.

Quality runner reference:

```bash
pnpm quality:staged
pnpm quality:prepush
pnpm quality:prepush:full
pnpm quality:local
pnpm quality:cloud-parity
pnpm quality:cache:status
```

See [docs/quality-gates.md](docs/quality-gates.md) for scope rules, full-suite triggers, cache behavior, attestation reuse, and failure reproduction.

## Code Style

SwiftFormat and SwiftLint enforce style via pre-commit hooks. Rust uses `cargo fmt` + `cargo clippy`. Go uses `gofmt` + `go vet`. Don't fight the formatters. If a rule feels wrong, open an issue about the rule, not a PR that ignores it.

## Pull Requests

1. Fork and branch from `main`.
2. Make your changes. One logical change per commit.
3. Run `pnpm quality:prepush:full` from repo root before pushing high-impact changes. Normal pushes run `pnpm quality:prepush` automatically and upgrade to full when scoped validation is unsafe.
4. Open a PR. Say what you changed and why.
5. We'll review it. We might ask questions. That's not rejection, that's conversation.

## Architecture

Chau7 follows Rule #1: document decisions near the code. Every subdirectory has a README. The canonical doc entry points are listed in [docs/README.md](docs/README.md).

Quick orientation:
- **apps/chau7-next**: Chau7 for macOS, a Rust/GPUI app. Logic in `chau7_next_core`, UI in `chau7_next`.
- **crates/chau7_terminal**: Rust terminal emulator, linked by the macOS app and, through its C API, by the iOS app.
- **apps/chau7-ios**: iOS companion app; `Chau7Core` is its shared Swift package.
- **services/chau7-proxy**: Go TLS proxy for API analytics.
- **services/chau7-relay**: Cloudflare Worker for the bug report relay and remote control.

The former SwiftUI/AppKit macOS app (`apps/chau7-macos`) has been removed from the tree; it remains in git history and prior release tags. Releases from `v*` tags ship the Rust production build; see [the production release guide](docs/rust-port/PRODUCTION-RELEASE.md) and [parity status](docs/rust-port/PARITY.md).

## What We're Looking For

- Bug fixes. Especially with tests.
- Performance improvements. Especially with measurements.
- New AI tool integrations. Add an entry to `AI_TOOLS` in `apps/chau7-next/crates/chau7_next_core/src/command_detection.rs`.
- Localization. We have English, French, Spanish, Arabic, and Hebrew. More is welcome.
- Documentation fixes. Typos, stale references, unclear explanations.

## What We're Not Looking For (Yet)

- Major refactors without discussion first. Open an issue, talk about it.
- Features that add complexity for edge cases. We'd rather ship less that works well.
- Changes that break the CI. If the hooks fail, fix before pushing.

## License

By contributing, your work is licensed under the [AGPL 3.0](LICENSE). Same terms as the rest of the project.
