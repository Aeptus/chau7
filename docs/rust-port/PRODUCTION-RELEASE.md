# Rust production release and rollback

Status (2026-10-23): The legacy SwiftUI/AppKit macOS app (`apps/chau7-macos`) has been removed from
the tree. It remains available in git history and in prior release tags.
`apps/chau7-next` is the macOS app, and the `Release` workflow publishes its
production build (`CHANNEL=production`) from `v*` tags. The shared Rust crates
moved to `crates/`, the Go proxy to `services/chau7-proxy`, and `Chau7Core` to
`apps/chau7-ios/Chau7Core`. Paths to `apps/chau7-macos` below are historical.
A `v*` tag signs, notarizes and publishes `Chau7-AppleSilicon.dmg`/`.zip` from the
Rust production bundle; see [`scripts/release/RUST-RC.md`](../../scripts/release/RUST-RC.md)
and [`docs/release-validation.md`](../release-validation.md). Migration and release
acceptance below still apply before pushing a tag; a manual candidate artifact is
not a published release.

## Identities and data ownership

| Channel | Bundle | Writable configuration | macOS session state |
| --- | --- | --- | --- |
| Former Swift app (removed from the tree) | `com.chau7.app` | `~/.chau7/` | `Application Support/Chau7/` and Swift UserDefaults |
| Next beta | `com.chau7.next` | `~/.chau7-next/` | `Application Support/Chau7 Next/` |
| Rust production | `com.chau7.app` | `~/.chau7/rust-v1/` | `Application Support/Chau7/RustV1/` |

Application Support is under `~/Library/` on macOS. Production is an explicit
compile-time `chau7_next_core/production` feature. The normal developer build
remains Next. The production binary uses the stable identity and the `chau7` MCP
registration; internal helper executable names can retain the Next prefix.
Production refuses to start when another stable macOS app is running. It never
stops that app itself. Keep the Swift bundle until the replacement is validated.

The versioned Rust directories deliberately preserve the original Swift bundle,
UserDefaults index, Next sessions, and backups. Migration must copy saved data;
it cannot transfer running shell processes. Resume-capable AI sessions retain
supported persisted session identities. Unfinished in-memory output is outside
a saved snapshot and requires the user to close the old app normally before the
final migration. No script should force a quit to obtain that snapshot.

## Migration procedure

1. Keep the current app running during source preparation, tests and packaging.
   Do not install over its bundle or modify either live profile.
2. Build and verify the exact production candidate, without launching it.
3. When ready to switch, the user closes the old app normally. Preserve a dated
   backup of the original app and both saved profiles outside build-cache folders.
4. Select the restore source explicitly: Swift or Next. If both contain data,
   do not combine their windows implicitly. Run the import in dry-run mode first,
   inspect structural counts and warnings, then apply to an empty Rust target.
5. The converter must validate schema versions, checksums, relative context
   references, source consistency and destination ownership before publication.
   Invalid input or existing destination state is an error, never permission to
   overwrite or silently start empty.
6. Open the candidate only when the user permits it. Verify window/tab/split
   counts, selected panes, working directories, scrollback and AI resume prefill.
   Confirm the source profiles remain usable for rollback.

The production executable supports an explicit import before it starts any GUI:

```sh
"/path/to/Chau7.app/Contents/MacOS/Chau7" \
  --import-chau7-restoration swift --source-home "$HOME" --dry-run
```

Use `next` to select the Next source. Review the numeric summary, then omit
`--dry-run` to apply. An existing Rust destination is refused. A second import
never replaces it. The complete restore bundle is published atomically before
its lightweight index, so interruption after bundle publication is recoverable
by the normal loader. The original source is kept intact. A production first
launch with saved source data refuses to start empty and prints these import
instructions. A graphical source chooser remains a release acceptance item.

Use only synthetic data or private copies for headless converter validation.
Never commit restore files, terminal transcripts, history, credentials or private
paths as test fixtures or public release assets. Importing a session is not a
claim that Keychain credentials, permissions or every Swift preference migrated;
record these separately in acceptance results.

## Guarded local upgrade

Run `apps/chau7-next/scripts/upgrade-macos-production.command` in Terminal.app,
outside Chau7. It builds and verifies a local production candidate first, then
asks the user to quit Chau7 normally. It never closes the app or its tabs itself.
The source for this workflow is explicitly **Swift Chau7**, not the Next profile.

The workflow makes a dated, checksum-verified copy of the source profiles and
keeps the previous application bundle. It imports from that frozen backup home,
checks the dry-run summary, applies only to an empty Rust destination, compares
the resulting receipt, and then installs the verified bundle. It does not open
the new app. Follow the launch command printed only after installation succeeds.
Do not reopen either app while the backup/import/replacement is in progress.

A final status identifies the completed stage, whether restoration was imported,
and whether the app was replaced. The log stays with the backup, and the machine-readable status is saved under
`~/Library/Logs/Chau7/`; both paths are printed at exit. A warning or failure before import leaves Swift installed; successful
compilation alone does not mean the upgrade happened. If import succeeded but
installation failed, retain the Rust destination and receipt for recovery. Do not
delete them or rerun an import over them.

Swift's synthetic AI tracking identities are not CLI session IDs. They are kept
as inert metadata and never turned into shell input. Legacy command blocks and
PNG previews are also retained in the restore schema through activation, later
saves, and tab moves. They are distinct from active runtime command-block UI.
The import report separates these `preserved` counts from actual loss warnings;
nonzero loss warnings still stop the script before import. Valid CLI session IDs
continue to generate the same validated resume prefill as before.

For an already prepared candidate, supply `CHAU7_UPGRADE_APP`,
`CHAU7_UPGRADE_RECEIPT`, and `CHAU7_UPGRADE_EXPECTED_SHA` together, with
`CHAU7_UPGRADE_REPO` pointing to the reviewed checkout. The candidate is reverified
against its receipt before the user is asked to quit. This avoids recompilation
while retaining source, identity, signature, and executable-hash checks.

## Updating an existing Rust installation

Use `apps/chau7-next/scripts/update-macos-production.command` for a Mac already
running production Rust Chau7. The migration script above is only for the first
Swift import and refuses an existing Rust destination.

Prepare the exact clean production bundle and its receipt first. From
Terminal.app, outside Chau7, inspect the candidate with:

```sh
./apps/chau7-next/scripts/update-macos-production.command \
  --app "/path/to/Chau7.app" \
  --receipt "/path/to/Chau7-Production-aarch64-apple-darwin-fast.json" \
  --expected-sha "FULL_REVIEWED_COMMIT_SHA" \
  --dry-run
```

After reviewing the successful preflight, replace `--dry-run` with
`--apply --wait-seconds 600`. The updater verifies the production identity,
source revision, receipt, executable hashes and signatures before waiting for
you to quit Chau7 normally. It does not quit or launch Chau7 itself. Keep the
app closed until the updater reports completion.

The updater requires existing Rust state, preserves both Rust profile directories,
backs up the current application and saved data, and stages the complete candidate
on the destination volume before replacing the app. It retains a rollback bundle
and verifies the installed candidate. It never reruns the Swift importer. A
failed preflight leaves the installed app untouched. Use the exact backup and rollback paths reported by the updater for recovery; do not delete
saved profiles to make an update pass.

## Build, sign and release

`CHANNEL=production RELEASE_VERSION=0.6.0-rc.1 BUILD_MODE=fast ./scripts/bundle-macos.sh` from
`apps/chau7-next` prepares a production bundle without installing or opening it.
The default `CHANNEL=next` path retains the isolated beta identity. Packaging
refuses Applications directories, bundle symlinks and existing bundles outside
the generated build cache. Choose a fresh artifact directory for local candidates.
A generated bundle with open files is also refused. Installation is a separate step.

Integrate all code before the final build. Use the fast profile normally and
restart with `BUILD_MODE=diagnostic` only when symbols are needed. Keep one warm
fast cache. Build once from the exact clean source commit; signing and notarizing
must consume those artifacts rather than recompiling another source tree.

The candidate includes its CLI executable, but deliberately omits the beta
`chau7-next` installer. Stable public-command installation must be accepted
separately before public distribution; production must not repoint a beta CLI.

A candidate must include every helper and license notice. Verify its receipt,
source revision, channel, bundle identity, minimum macOS version and executable
hashes. Distribution then requires Developer ID signing, hardened runtime,
notarization, stapling, package checksums and provenance. Ad-hoc local signing is
insufficient for a public stable release.

Prepare `0.6.0-rc.1` as a candidate once these checks pass. Keep existing stable
tag behavior until migration and the candidate have release acceptance. The
current `v*` tag workflow still builds Swift. Before creating the Rust stable
tag, land and verify the explicit stable-pipeline switch; creating a new tag
alone does not select the Rust app. Publish the stable tag and update the
website's download availability together only after the candidate is accepted. Never advertise an unreleased artifact as the
stable download. Keep Linux and Windows support claims tied to actual platform
acceptance rather than compilation alone.

## Cleanup and rollback

Keep the current and one known rollback app, the original Swift and Next stores,
all migration backups, compact test reports and one fast build cache. Remove
only named generated artifacts after checking that no process uses them. Do not
remove source checkouts with unpublished commits or unknown untracked files.
Allocated sizes can overstate disk recovered on APFS shared extents.

Rollback closes the Rust app normally, restores the previous app bundle and
opens it against its untouched original store. Never point Swift at the Rust
session format. Keep the Rust profile for diagnosis; do not merge it into the
Swift store. Rollback does not reverse external AI-provider activity performed
after migration.

## Local preparation checkpoint (2026-10-14)

Application/package source: `350d851b457e31a021474a8c174fc9b923449838`. The
candidate receipt records this exact clean source, not later documentation-only
commits. Both Next and production workspace configurations pass 3,157 tests with
two ignored each, strict Clippy and the static/release packaging contracts.

One fast optimized `0.6.0-rc.1` production package completed in 138 seconds.
All seven executable hashes/signatures, arm64 architecture, bundle metadata,
notices and the deep app signature verify. Signing is ad-hoc only; Developer ID
signing, notarization, installation and public release have not occurred.

The read-only Swift inspection found two windows, 25 tabs and 25 panes with no
terminal context truncation. One invalid AI resume identity and five tab preview
contexts are explicitly reported as omitted. No real import was applied. Swift
and Next profiles remain readable, and the original Swift process remained open.
All Swift application build inputs are byte-identical to previously validated
source `778010757101fe75c5bb23e080e08e4be92a969d`; only its docs changed. The
broad local Python quality gate has an unrelated missing `mcp` dependency and is
not claimed as passing. New-head GitHub CI is tracked separately in
[PR #229](https://github.com/Aeptus/chau7/pull/229/checks).

Cleanup removed 28 named unused generated directories, totaling 22.68 GiB of
allocated blocks. The original profiles, current and rollback apps, private
receipts, unknown files and warm fast cache were preserved. The official website
updates were merged in [website PR #2](https://github.com/Aeptus/chau7-website/pull/2)
and deployed to [chau7.sh](https://chau7.sh/) on October 14, 2026, from website
commit `6dc6540b4ba0e3dc8e20a8fd710b67a194df942b`. The new
[Rust transition guide](https://chau7.sh/rust-transition), nine feature guides,
home/catalog links, knowledge pages and sitemaps distinguish stable v0.5.1 from
the unreleased candidate. Production verification checked 14 routes/assets
against the reviewed public files; internal repository files were excluded.
The stable download remains unchanged. Runtime restoration, graphical source
selection, stable CLI installation, preference/Keychain acceptance and the
stable-pipeline switch remain release gates. No local app was launched or stopped
for the website deployment.

## Required release evidence

- Exact source SHA and clean-tree receipt for all artifacts.
- Headless Swift and Next import tests, refusal tests and transaction recovery.
- Production and beta identity/path isolation checks.
- Signed/notarized candidate verification without a second compilation.
- User-approved runtime restoration and macOS integration acceptance.
- Documentation and website PRs with no premature availability claims.
- Exact cleanup manifest, retained rollback paths and retained private evidence.

The October 14 local transition preparation explicitly forbids launching or
relaunching Next and forbids stopping Chau7. Therefore a build-only check cannot
satisfy the runtime acceptance item. Keep that item visibly pending.
