# Dependency and repository maintenance

The iOS app's Swift code has no remote Swift packages: the Xcode project links only
the local `apps/chau7-ios/Chau7Core` package, which has no dependencies, so there is
no Swift lockfile or Swift Dependabot entry. Adding a remote Swift package requires
adding its lockfile and a Dependabot entry in the same change.

Dependabot covers both npm services, both Go modules (services/chau7-remote and
services/chau7-proxy), both Rust workspaces (crates and apps/chau7-next), Python project/test
requirements and Actions. Compatible minor/patch updates are grouped; major and
security updates are surfaced for review and are not silently merged. The two
Rust workspaces have separate tracked app-level Cargo.lock files; the vendored
GPUI package lockfiles are provenance snapshots, not workspace locks.

In Chau7 Next, the gpui* family is grouped for version and security updates.
gpui-kit and the three local GPUI path patches form one pinned compatible
snapshot. Dependabot can surface candidate updates, but a GPUI update must
coordinate the exact manifest pins, affected vendor sources, provenance and
modification ledgers, and Cargo.lock in one reviewed change. Do not merge a
partial GPUI update.

The Go proxy's modernc SQLite/libc versions are also a matched pair. The
[driver guidance](https://pkg.go.dev/modernc.org/sqlite#section-readme) requires
the exact libc version in the driver's go.mod because that dependency is
fragile. SQLite 1.60.1 declares libc 1.77.1; an independently newer libc release
is not a supported standalone upgrade of that pair.

Root pnpm is the dependency-free quality runner, pinned by packageManager;
service npm packages own package-lock.json and use npm ci. A root pnpm lock is
unnecessary while the root has no dependency declarations. A scheduled update
entry describes coverage, not an applied upgrade. A specific update is evidenced
by its manifest/lockfile diff and reviewed CI result; those establish the version
change and tested compatibility, not that every newer release was adopted.
GPUI's source rebase additionally has upstream checksum, provenance and
modification-ledger records.

CI installs SwiftFormat 0.63.1 from the upstream release archive and verifies
its SHA-256 and executable version, matching `mise.toml`. Update those pins
together. Homebrew's latest formatter can enable new rules before this
repository intentionally adopts them.

Both Worker services override Miniflare's Undici dependency to 7.30.1. The
Wrangler 4.151.3 / Miniflare 5.20261019.1-beta toolchain still pins an affected
Undici 7.x release. The scoped override keeps the same major version while
fixing [excessive content-encoding crashes](https://github.com/advisories/GHSA-xjj6-f33q-929c),
[EventSource memory exhaustion](https://github.com/advisories/GHSA-4qv8-2p9j-2685)
and [integrity-token parsing](https://github.com/advisories/GHSA-f72v-6w45-q472).
Keep both npm lockfiles in sync with their manifests. Remove this override
when the selected Miniflare release requires a patched version itself, after
both services pass their tests, Wrangler dry-run builds and live npm audits.
The relay similarly overrides `@cloudflare/vitest-plugin`'s Zod to 4.6.6 for
[bounded collection validation](https://github.com/advisories/GHSA-mrhx-c7xc-m3w5).
Remove that scoped override once the plugin selects a patched Zod release,
with the same integration and audit checks.

Repository text follows LF through .gitattributes; no history normalization was
performed. The root CHANGELOG.md is the canonical changelog. Local
`.chau7/pre-commit-review.conf` is ignored; the tracked `.example` documents the
optional advisory override. The existing script has matching defaults when the
local file is absent. Do not author product commits with a fixture identity:
`git var GIT_AUTHOR_IDENT` must show the real configured author. If local settings
mask a correct global identity, remove only those local user.name/user.email
overrides. Developer prerequisite checks reject known test identities.

## Safe retirement policy

Active broker sessions and their worktrees are valid work. Branch/worktree/stash
counts alone are not evidence that anything is disposable. Before retiring an
exact ref, record its full SHA, broker owner/status, clean/dirty state, unique
commits against main and remote backup coverage. Preserve unrepresented commits,
staged/unstaged changes and stashes before proposing deletion. An active owner or
unbacked work prevents retirement. Use the broker representation scan/record and
cleanup plan for finished broker-owned worktrees; never force cleanup or rewrite
public history. No pre-existing refs, worktrees or stashes are retired by this
source cleanup. The local review config is not deleted from the developer checkout.

## Live security checks and coverage

Both Go modules run `go test -race ./...` in affected pre-push/PR gates and full
local CI. `.golangci.yml` enables bodyclose, contextcheck and gosec alongside the
standard linters. Narrow inline exclusions explain reviewed ownership or trust
boundaries; whole linters and security classes are not disabled.

Every pre-push/PR validation also runs uncached, call-graph-aware
`go run golang.org/x/vuln/cmd/govulncheck@v1.8.0 ./...` in both modules. This uses
the selected Go toolchain and current vulnerability database. Missing tooling,
download/database failures, and reachable advisories fail the gate. A clean scan
is evidence for the checked source/toolchain and current database; it is not a
claim that every required but unreachable module is advisory-free. Run with
`-show verbose` when reviewing an upstream module advisory.

Both Go modules require Go 1.27.1 or newer. CI and release setup read this patched minimum from the remote module manifest; they must not select the unpatched Go 1.26.0 compiler. The live audit covers the standard library of the compiler actually used.

SwiftPM has **no automated vulnerability-advisory scanner in this repository**.
Native builds/tests establish compatibility, not advisory coverage. Any future
Swift dependency must include a manual review of upstream security advisories and
release notes for the exact revisions in the PR. Track any unreviewed revision or new dependency
explicitly; do not describe the Rust/npm/Python/Go audits as Swift coverage.
