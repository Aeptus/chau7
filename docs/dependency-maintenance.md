# Dependency and repository maintenance

The macOS Swift manifest/lock and iOS Xcode Package.resolved share swift-atomics
1.3.1 at the same revision. Update both in dependency PRs and run native macOS/iOS
CI; platform-specific divergence requires a separately reviewed policy change.
Dependabot's Swift fetcher supports Xcode project lockfiles, so the iOS update
surface is `apps/chau7-ios/Chau7RemoteApp`, not a synthetic second Package.swift.
The [upstream fetcher](https://github.com/dependabot/dependabot-core/blob/main/swift/lib/dependabot/swift/file_fetcher.rb)
defines this support.

Dependabot covers macOS/iOS Swift, both npm services, both Go modules, the Rust
workspace, Python project/test requirements and Actions. Compatible minor/patch
updates are grouped; majors and security updates are not globally ignored or
silently merged. Root pnpm is the dependency-free quality runner, pinned by
packageManager; service npm packages own package-lock.json and use npm ci. A root
pnpm lock is unnecessary while the root has no dependency declarations. Rust
members resolve through their parent workspace; only its Cargo.lock is tracked.

Repository text follows LF through .gitattributes; no history normalization was
performed. Root CHANGELOG.md is already a symlink to the app's canonical changelog; it is preserved. Local
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

SwiftPM has **no automated vulnerability-advisory scanner in this repository**.
Shared-pin validation and native builds/tests establish consistency and
compatibility, not advisory coverage. Swift dependency updates must include a
manual review of upstream security advisories and release notes for the exact
macOS/iOS revisions in the PR. Track any unreviewed revision or new dependency
explicitly; do not describe the Rust/npm/Python/Go audits as Swift coverage.
