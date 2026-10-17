# Rust production release candidates

The existing `v*` tag workflow continues to build, sign, notarize, and publish the Swift release. The Rust production channel is a separate manual release candidate (RC) path. It does not create or move tags, create a GitHub Release, or update the Homebrew tap.

## Prepare a candidate

Run the **Release** workflow from `main` and select `rust-production-rc`. Enter the full SemVer candidate, such as `0.6.0-rc.1`, then type `RUST_PRODUCTION_MIGRATION_VALIDATED` only after the migration validation has completed. The workflow rejects other branches, missing acknowledgements, and invalid versions.

The build job packages once with `CHANNEL=production`, `RELEASE_VERSION` set to the requested candidate, and the locked Cargo feature `chau7_next_core/production`. It stores that bundle and its build manifest as an unsigned Actions artifact. The signing job downloads those exact bytes and does not run Cargo or rebuild the app.

The bundle reports `CFBundleShortVersionString` as the numeric SemVer core (for example `0.6.0`) and `CFBundleVersion` as the numeric workflow run number. The external build manifest records the full `releaseVersion` (for example `0.6.0-rc.1`) and the `cargoPackageVersion` used by the current Rust workspace, so prerelease labels and internal crate versions remain distinguishable.

The Rust production RC intentionally omits the opt-in Next CLI installer. That installer writes the beta `chau7-next` command and must not redirect a user's stable `chau7` command to the beta. Stable CLI installation remains pending until its production migration is complete.

## Signing and candidate outputs

The signing job requires these GitHub Actions secrets:

- `APPLE_DEVELOPER_ID_APPLICATION`
- `APPLE_CERTIFICATE_P12`
- `APPLE_CERTIFICATE_PASSWORD`
- `APPLE_ID`
- `APPLE_ID_PASSWORD`
- `APPLE_TEAM_ID`

It imports the certificate into the isolated release keychain, signs and verifies the app executable and six helper executables individually, signs and verifies the app bundle, notarizes and staples the app, then creates and notarizes a DMG. The signed ZIP, DMG, refreshed build manifest, and `SHA256SUMS.txt` are uploaded as the `rust-production-rc-*` Actions artifact. The manifest holds SHA-256 hashes for all seven executables after signing and records the production feature, signing team, notarization, RC stage, and artifact-only distribution status. GitHub build provenance is attached to the candidate files.

Missing signing configuration fails the signing job before an artifact is presented as a signed RC. The candidate is available through Actions artifact retention only; publishing Rust as the stable `v*` channel requires a later, deliberate release workflow change after migration validation and RC review.

## Local packaging contract

`apps/chau7-next/scripts/bundle-macos.sh` defaults to the existing `next` channel and keeps its app name and bundle ID. Set `CHANNEL=production` and provide a valid `RELEASE_VERSION` to opt into `Chau7.app`, `com.chau7.app`, and the unified production Cargo feature. Production packaging requires both Go helper binaries and a numeric `BUILD_NUMBER`. The package script only builds and ad-hoc signs; use the CI signing path for a distributable production candidate.
