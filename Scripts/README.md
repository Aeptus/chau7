# Scripts (Repo Root)

Build orchestration and CI scripts that operate across the entire monorepo. The macOS app has its own scripts in `apps/chau7-macos/Scripts/`.

## Files

| Script | Purpose |
|--------|---------|
| `order66` | Top-level build orchestrator. Delegates to `apps/chau7-macos/Scripts/order66` for macOS and runs `xcodebuild` for iOS. Run `./Scripts/order66 --help` for targets. |
| `ci-local` | Full local CI gate. Runs format + lint + build + test across Swift, Rust, Go, and the relay. Matches what GitHub Actions CI runs. |
| `ci-local-fast` | Fast pre-commit gate. Only checks components affected by staged files. Pass `--all` to check everything. |
| `ci-lib.sh` | Shared CI helper functions sourced by `ci-local` and `ci-local-fast`. Provides `ci_section`, `ci_fail`, `ci_require_cmd`, `ci_run_in`, and `ci_gofmt_check_dir`. |
| `check-docs-staged` | Pre-commit hook. Warns when behavioral source changes are staged without corresponding CHANGELOG/FEATURES updates. Skip with `CHAU7_SKIP_DOC_CHECK=1`. |
| `install-hooks` | Sets up lefthook-based git hooks. Requires `lefthook` (`brew install lefthook`). |

## Environment Requirements

| Tool | Version | Used By |
|------|---------|---------|
| Swift | 6+ (Xcode 26+) | `ci-local`, `ci-local-fast` |
| SwiftFormat | latest | `ci-local`, `ci-local-fast` |
| SwiftLint | latest | `ci-local`, `ci-local-fast` |
| Rust (cargo) | stable | `ci-local`, `ci-local-fast` |
| Go | 1.25+ | `ci-local`, `ci-local-fast` |
| Node.js + npm | 20+ | `ci-local`, `ci-local-fast` |
| lefthook | any | `install-hooks` |
| xcodebuild | Xcode 26+ | `order66 ios` |

## Quick Reference

```bash
# Full CI (matches GitHub Actions)
./Scripts/ci-local

# Fast pre-commit check (staged files only)
./Scripts/ci-local-fast

# Fast check for all components
./Scripts/ci-local-fast --all

# Build macOS app
./Scripts/order66 macos

# Build iOS app
./Scripts/order66 ios

# Build everything
./Scripts/order66 all

# Install git hooks
./Scripts/install-hooks
```

## App-Level Scripts

The macOS app has 17 additional scripts in `apps/chau7-macos/Scripts/` for building the app bundle, creating DMGs, building Rust dylibs, managing PTY wrappers, and more. See the macOS app README for details.
