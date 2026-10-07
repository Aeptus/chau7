# Scripts (Repo Root)

Build orchestration and CI scripts that operate across the entire monorepo. The macOS app has its own scripts in `apps/chau7-macos/Scripts/`.

## Files

| Script | Purpose |
|--------|---------|
| `order66` | Top-level build orchestrator. Delegates to `apps/chau7-macos/Scripts/order66` for macOS and runs `xcodebuild` for iOS. Run `./scripts/order66 --help` for targets. |
| `ci-local` | Legacy full local CI implementation invoked by the registered `full-local-ci` quality gate. Runs format + lint + build + test + dead-code + duplication + Rust dep audit across Swift, Rust, Go, and the relay; live JS/Python dependency audits are separate registry gates. |
| `ci-local-relay-ts` | Scoped TS check for `services/chau7-relay`. Runs `tsc --noEmit` + `prettier --check`. |
| `ci-lib.sh` | Shared CI helper functions sourced by `ci-local` and `ci-local-relay-ts`. Provides `ci_section`, `ci_fail`, `ci_require_cmd`, `ci_require_cmd_strict`, `ci_run_in`, `ci_gofmt_check_dir`, `ci_go_vet_dir`, `ci_golangci_lint_dir`, `ci_shellcheck_tracked`, `ci_ruff_check_dir`. |
| `check-docs-staged` | Blocking indexed documentation gate. App behavior changes need a changelog change or a reviewed exact-path exemption; tooling edits do not need artificial feature rows. Validates staged JSON/CSV correspondence and link hygiene; unstaged repairs do not mask failures. |
| `check-features-csv.mjs` | Deterministic structural validator for `apps/chau7-macos/docs/features.csv` (5 columns, valid `Status`/`Differentiator`, no blank/malformed rows). Run via the `staged-features-csv` gate. |
| `generate-features-csv.mjs` | Generates `features.csv` from the authoritative `features.json` manifest. `pnpm features:generate` writes it; `pnpm features:check` (the `staged-features-csv-generated` gate) fails on drift. Edit the manifest, never the CSV. |
| `check-feature-coverage.mjs` | Fails when an MCP tool registered in `MCPSession.swift` has no canonical inventory row in `features.json` (the `staged-feature-coverage` gate). Warns on removed tools. Skip with `CHAU7_SKIP_FEATURE_COVERAGE=1`. |
| `check-forbidden-files` | Registered through `staged-legacy-guardrails`; blocks staged secret/credential paths (`.env*`, `*.pem`, `id_rsa*`, etc.) and blobs at least 5 MiB. Skip with `CHAU7_SKIP_FORBIDDEN_CHECK=1`. |
| `check-anti-slop` | Regex slop check on added diff lines only. Catches new force-unwraps/`print`/`AnyView` in Swift, `console.log`/`as any`/`@ts-ignore` in TS, `fmt.Println`/`panic` in Go, bare `except:` in Python, and AI ghost comments across all. Skip with `CHAU7_SKIP_ANTISLOP=1`. |
| `check-design-system` | Design-system ratchet. For every staged Swift view file outside `Appearance/`, `Tests/`, and `Chau7Core/`, scans the **entire file** and blocks on color literals, `AnyView`, or literal font sizes. Grandfathers untouched files; forces cleanup when a file is touched. Skip with `CHAU7_SKIP_DS_CHECK=1`. |
| `pre-commit-review` | Registered staged advisory review via the running Chau7 app. It skips if the app isn't reachable, and honors `CHAU7_PRE_COMMIT_REVIEW_ENABLED=0`; silence the skip banner with `CHAU7_PRE_COMMIT_REVIEW_QUIET=1`. |
| `pentagi-mcp-local-preflight` | Local PentAGI MCP shakedown helper. Verifies the host HTTPS target, keeps upstream PentAGI off the target port, ensures a `pentagi-sandbox` Kali tool container exists, checks required pentest tools, and can start a sandbox-local SNI proxy for `localhost`-only TLS services. |
| `install-hooks` | Compatibility wrapper for `pnpm hooks:install`, which points Git at `.husky/`. |
| `manual-mcp-codex-smoke.py` | Explicit manual MCP/Codex smoke tool; configured with CHAU7_SMOKE environment variables in its source. It is not a mandatory CI gate and exercises the running app. |
| `git/install-hooks.mjs` | Clone/worktree-safe automatic `.husky` setup and verification; copied packages outside their repository are skipped during prepare. |
| `git/check-prerequisites.mjs` | Read-only setup verification against the pinned development tools; does not install or build Chau7. |
| `git/run-python-tests.mjs` | Runs both Python suites with `CHAU7_TEST_PYTHON`, repository `.venv`, or system Python; missing test dependencies fail with setup guidance. |
| `ruff.toml` | Ruff config for Python helper scripts. Selects `E,F,W,I,B,UP,SIM,PLC/E/W`. Legacy files are grandfathered via `per-file-ignores`. |
| `.jscpd.json` | Duplication detection config. Minimum 60 tokens / 8 lines across Swift/Rust/Go/TS/Python, ignores tests and vendored code. |

## Environment Requirements

The supported source-development tool versions are pinned in
[../mise.toml](../mise.toml). Follow [../CONTRIBUTING.md](../CONTRIBUTING.md) to
install those tools and the isolated Python test requirements, then run
`pnpm setup:check`. Xcode 26.6 is selected separately; native CI runs the full
macOS/iOS build and tests. The developer tool pins and CI runner tool versions
serve different environments and need not be byte-identical.

`pnpm test` runs Node tests and both Python suites. Core-only Swift checks use
`apps/chau7-macos/Scripts/test-core.sh`; they do not replace the full native
`swift test` and `swift build` gates. Security scans and dependency audits fail
when required tools or fixtures are missing; setup never silently skips them.

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

Developer setup uses the pinned [mise.toml](../mise.toml) baseline; see
[CONTRIBUTING](../CONTRIBUTING.md#setting-up). `pnpm install` installs hooks via
`prepare` in repository clones/worktrees. `pnpm setup:check` verifies tools and
hooks without compiling or launching the app. `pnpm test` runs the Node and both
Python suites; `pnpm test:node` is the narrower Node-only command.

PR CI keeps the checked-out snapshot in the index and temporarily moves only
HEAD to the PR base before running the ordinary staged gates. This makes the
changed-file selection and indexed docs checks inspect the actual PR. CI verifies
that gates preserve the original snapshot and restores HEAD even on failure.
This sequence runs only in the disposable GitHub checkout.
