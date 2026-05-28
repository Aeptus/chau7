# Quality Gates

Chau7 quality checks are organized around one rule: hooks select a mode, the
registry selects policy, and the runner executes gates.

## Architecture

```text
.husky/pre-commit
  -> pnpm quality:staged
  -> scripts/git/run-staged-checks.mjs
  -> scripts/quality/runner.mjs
  -> scripts/quality/registry.mjs

.husky/pre-push
  -> pnpm quality:prepush
  -> scripts/git/run-prepush-checks.mjs
  -> scripts/quality/runner.mjs
  -> scripts/quality/registry.mjs
```

`scripts/git/` files are compatibility shims. Real quality policy belongs in
`scripts/quality/registry.mjs`; execution, caching, logging, and filtering
belong in `scripts/quality/runner.mjs`.

## Installation

```bash
pnpm hooks:install
```

This sets `core.hooksPath` to `.husky`. The legacy `scripts/install-hooks` and
`tools/git-hooks/install.sh` entry points delegate to the same command.

## Entry Points

| Command | Purpose |
|---|---|
| `pnpm quality:staged` | Staged-file pre-commit firewall. |
| `pnpm quality:prepush` | Affected-surface pre-push firewall. |
| `pnpm quality:prepush:full` | Conservative full-suite pre-push. |
| `pnpm quality:local` | Local broad validation using registry gates. |
| `pnpm quality:cloud-parity` | Checks local/release workflow parity policy. |
| `pnpm quality:cache:status` | Inspect content-hash cache state. |
| `pnpm quality:cache:clear` | Remove quality cache entries and outputs. |
| `pnpm test` | Fast unit tests for the quality runner and registry. |

## Staged Scope

Pre-commit discovers files with:

```bash
git diff --cached --name-only --diff-filter=ACMR
```

Local artifacts are filtered centrally: `.aeptus-cache/`, `.cache/`,
`.jscpd-report/`, `.ruff_cache/`, `node_modules/`, `.build/`, `target/`,
`dist/`, `coverage/`, virtualenvs, and Python `__pycache__/`.

Staged gates include:

- high-signal secret and credential scanning;
- dependency-manifest policy and lockfile drift checks;
- Ruff fix/format/verify for staged Python files, with deliberate re-stage;
- Python guardrails for bare/silent exceptions, placeholders, and debuggers;
- Prettier write/check for staged JS/TS files where package-local Prettier is installed;
- JS/TS security and naming guardrails;
- registered legacy source-policy checks for anti-slop, design-system ratchet, and docs hygiene;
- staged ShellCheck.
- quality-runner unit tests when staged files touch `scripts/quality/`,
  `scripts/git/`, or the root quality package.

## Pre-push Scope

Pre-push first reads Git hook stdin update lines. Each pushed local SHA is
diffed against its remote SHA. For new branches, the runner falls back to a
merge base with `origin/main`.

When stdin is unavailable, the diff base is resolved in this order:

1. current upstream branch
2. `origin/main`
3. `origin/production`
4. `main`
5. `production`
6. `HEAD^`

Before running pre-push gates, the runner checks the dirty worktree state. In
non-interactive contexts it fails closed unless
`AEPTUS_SKIP_DIRTY_WORKTREE_CONFIRM=1` is set.

## Full-Suite Triggers

`pnpm quality:prepush` upgrades to `prepush-full` when scoped validation is
unsafe:

- `--full` is passed;
- no changed files can be resolved;
- hook infrastructure changes;
- runner, registry, cache, or quality helper files change;
- `package.json`, `pnpm-lock.yaml`, or workspace graph files change;
- package manifests or lockfiles change;
- `tsconfig*.json`, Vitest, Playwright, Tailwind, or ESLint config changes;
- Python dependency config changes;
- Swift package/config files change;
- Rust workspace, Cargo lockfile, or `deny.toml` changes;
- Go module files change;
- CI/release workflow files change;
- OpenAPI/spec/generator paths change;
- test setup, build tooling, or environment validation code changes.

Generated contract gates fail closed when a generated artifact or OpenAPI input
changes without a registered freshness check. Add the generator gate before
committing that kind of drift.

## Registry Contract

Every gate declares:

```js
{
  id,
  modes,
  scope,
  wave,
  tags,
  cacheable,
  inputs,
  applies,
  run,
  rerun
}
```

The registry validation gate fails if a gate lacks a stable id, valid mode,
wave, scope, rerun command, cache declaration, cache inputs, or an applies
predicate for non-repo gates.

## Cache Behavior

Successful cacheable gates are stored under:

```text
.aeptus-cache/quality/
```

The cache key includes the cache schema, gate id, mode, Node/pnpm/Python
versions, lockfiles, runner/registry/cache/helper code, gate inputs, scoped
changed file contents, relevant env vars, and untracked files inside declared
input directories. Failed gates are never cached.

Disable cache with:

```bash
AEPTUS_QUALITY_DISABLE_CACHE=1 pnpm quality:prepush
```

`AEPTUS_PREPUSH_DISABLE_CACHE=1` remains supported for compatibility.

## Attestations

Heavy trusted commands may write attestations under:

```text
.aeptus-cache/quality/attestations/
```

The runner accepts an attestation only when HEAD, repository fingerprint,
lockfile fingerprint, registry fingerprint, runner fingerprint, gate id, and
freshness window match. The default freshness window is 30 minutes via
`AEPTUS_ORDER66_ATTESTATION_MAX_AGE_MINUTES`.

Security-sensitive gates and audit gates continue to run live. Full-suite mode
runs `npm audit --audit-level=high` for tracked Node package-lock projects. A
Python dependency audit gate is registered and activates when tracked
`pyproject.toml` or `requirements*.txt` files exist.

Quality runner tests are also registry-backed through `quality-runner-tests`, so
runner/registry behavior changes are exercised by hooks and full-suite modes.

## Runtime Filters

Runtime filters are for diagnosis, not normal weakening of hooks:

```bash
pnpm quality:prepush --include=rust-terminal-static
pnpm quality:prepush --skip=swift-macos-tests
pnpm quality:local --tags=backend
pnpm quality:local --skip-tags=slow
pnpm quality:prepush --wave=static
pnpm quality:prepush --json
pnpm quality:prepush --debug-cache
pnpm quality:prepush --concurrency=3
```

## Failure Reproduction

Every failed gate prints its id, scope, wave, rerun command, cache/attestation
status, and per-gate log path when available. Detailed command output is kept
under:

```text
.aeptus-cache/quality/outputs/
```

Pre-push/local/cloud-parity runs also tee a run log to:

```text
logs/quality-<mode>-<timestamp>.log
```

Logs older than 7 days are pruned by the runner/post-commit hook.

## Adding a Gate

1. Add the gate to `scripts/quality/registry.mjs`.
2. Give it a stable kebab-case id and explicit `rerun` command.
3. Declare mode, scope, wave, tags, cacheability, and inputs.
4. Use `applies(context)` for scoped gates.
5. Keep tool invocation inside `run(context)`.
6. Add or update `scripts/quality/tests/*`.
7. Run `pnpm test` and the relevant `pnpm quality:*` command.

## `--no-verify`

`--no-verify` is an emergency escape hatch only. Prefer named, narrow, logged
environment overrides when a gate has an intentional escape hatch. Any bypass
should be justified in the commit message.
