# Scripts (Repo Root)

Build orchestration and CI scripts that operate across the entire monorepo. The macOS app has its own scripts in `apps/chau7-macos/Scripts/`.

## Files

| Script | Purpose |
|--------|---------|
| `order66` | Top-level build orchestrator. Delegates to `apps/chau7-macos/Scripts/order66` for macOS and runs `xcodebuild` for iOS. Run `./scripts/order66 --help` for targets. |
| `ci-local` | Legacy full local CI implementation invoked by the registered `full-local-ci` quality gate. Runs format + lint + build + test + dead-code + duplication + Rust dep audit across Swift, Rust, Go, and the relay; live JS/Python dependency audits are separate registry gates. |
| `ci-local-relay-ts` | Scoped TS check for `services/chau7-relay`. Runs `tsc --noEmit` + `prettier --check`. |
| `ci-lib.sh` | Shared CI helper functions sourced by `ci-local`, `ci-local-relay-ts`, and `check-release-tag-push`. Provides `ci_section`, `ci_fail`, `ci_require_cmd`, `ci_require_cmd_strict`, `ci_run_in`, `ci_gofmt_check_dir`, `ci_go_vet_dir`, `ci_golangci_lint_dir`, `ci_shellcheck_tracked`, `ci_ruff_check_dir`. |
| `check-docs-staged` | Pre-commit hook. Warns when behavioral source changes are staged without corresponding CHANGELOG/FEATURES updates. Skip with `CHAU7_SKIP_DOC_CHECK=1`. |
| `check-features-csv.mjs` | Deterministic structural validator for `apps/chau7-macos/docs/features.csv` (5 columns, valid `Status`/`Differentiator`, no blank/malformed rows). Run via the `staged-features-csv` gate. |
| `generate-features-csv.mjs` | Generates `features.csv` from the authoritative `features.json` manifest. `pnpm features:generate` writes it; `pnpm features:check` (the `staged-features-csv-generated` gate) fails on drift. Edit the manifest, never the CSV. |
| `check-feature-coverage.mjs` | Fails when an MCP tool registered in `MCPSession.swift` has no canonical inventory row in `features.json` (the `staged-feature-coverage` gate). Warns on removed tools. Skip with `CHAU7_SKIP_FEATURE_COVERAGE=1`. |
| `check-forbidden-files` | Blocks committing secrets/credential files (`.env*`, `*.pem`, `id_rsa*`, etc.) and files > 5 MB. Skip with `CHAU7_SKIP_FORBIDDEN_CHECK=1`. |
| `check-anti-slop` | Regex slop check on added diff lines only. Catches new force-unwraps/`print`/`AnyView` in Swift, `console.log`/`as any`/`@ts-ignore` in TS, `fmt.Println`/`panic` in Go, bare `except:` in Python, and AI ghost comments across all. Skip with `CHAU7_SKIP_ANTISLOP=1`. |
| `check-design-system` | Design-system ratchet. For every staged Swift view file outside `Appearance/`, `Tests/`, and `Chau7Core/`, scans the **entire file** and blocks on color literals, `AnyView`, or literal font sizes. Grandfathers untouched files; forces cleanup when a file is touched. Skip with `CHAU7_SKIP_DS_CHECK=1`. |
| `pre-commit-review` | AI-delegated code review via the running Chau7 app. Advisory by default; prints a loud skip banner if the app isn't reachable. Silence with `CHAU7_PRE_COMMIT_REVIEW_QUIET=1`. |
| `pentagi-mcp-local-preflight` | Local PentAGI MCP shakedown helper. Verifies the host HTTPS target, keeps upstream PentAGI off the target port, ensures a `pentagi-sandbox` Kali tool container exists, checks required pentest tools, and can start a sandbox-local SNI proxy for `localhost`-only TLS services. |
| `install-hooks` | Compatibility wrapper for `pnpm hooks:install`, which points Git at `.husky/`. |
| `ruff.toml` | Ruff config for Python helper scripts. Selects `E,F,W,I,B,UP,SIM,PLC/E/W`. Legacy files are grandfathered via `per-file-ignores`. |
| `.jscpd.json` | Duplication detection config. Minimum 60 tokens / 8 lines across Swift/Rust/Go/TS/Python, ignores tests and vendored code. |

## Environment Requirements

| Tool | Version | Used By |
|------|---------|---------|
| Swift | 6+ (Xcode 26+) | `ci-local` |
| SwiftFormat | latest | `ci-local` |
| SwiftLint | latest | `ci-local` |
| Rust (cargo) | stable | `ci-local` |
| Go | 1.25+ | `ci-local` |
| Node.js + npm | 22+ | `ci-local`, `ci-local-relay-ts` |
| pnpm | 10.11+ | `hooks:install`, `quality:*` |
| gitleaks | any | pre-commit (secret scan) |
| shellcheck | any | pre-commit (staged `.sh`), `ci-local` (full) |
| ruff | any | pre-commit (staged `.py`), `ci-local` (full) |
| golangci-lint | any | `ci-local` |
| periphery | any | `ci-local` (Swift dead-code) |
| cargo-deny | any | `ci-local` (Rust dep audit) |
| jscpd | any | `ci-local` (duplication) |
| xcodebuild | Xcode 26+ | `order66 ios` |

### Follow-ups (future work)

- **ESLint for relay worker**: deferred. 6 TS files don't justify another lint config tree; `tsc --noEmit` + prettier cover the realistic failure modes. Re-evaluate when the worker grows.

## Quick Reference

```bash
# Full local CI via the quality registry
pnpm quality:prepush:full

# Full CI implementation directly
./scripts/ci-local

# Staged pre-commit firewall
pnpm quality:staged

# Affected-surface pre-push firewall
pnpm quality:prepush

# Build macOS app
./scripts/order66 macos

# Build iOS app
./scripts/order66 ios

# Build everything
./scripts/order66 all

# Install git hooks
pnpm hooks:install
```

See [../docs/quality-gates.md](../docs/quality-gates.md) for the quality
runner architecture, registry contract, cache policy, and reproduction flow.

## App-Level Scripts

The macOS app has 17 additional scripts in `apps/chau7-macos/Scripts/` for building the app bundle, creating DMGs, building Rust dylibs, managing PTY wrappers, and more. See the macOS app README for details.
