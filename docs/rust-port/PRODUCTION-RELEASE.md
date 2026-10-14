# Rust production release and rollback

Status: release preparation. The stable download remains the Swift release until
migration, signing, and release acceptance have passed. Do not interpret a
successful beta build or a manual candidate artifact as a published stable release.

## Identities and data ownership

| Channel | Bundle | Writable configuration | macOS session state |
| --- | --- | --- | --- |
| Existing Swift | `com.chau7.app` | `~/.chau7/` | `Application Support/Chau7/` and Swift UserDefaults |
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
