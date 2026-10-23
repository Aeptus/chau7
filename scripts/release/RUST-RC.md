# Rust production releases and release candidates

The `v*` tag workflow builds, signs, notarizes and publishes the Rust production app as the stable release (`Chau7-AppleSilicon.dmg` and `.zip`, the build manifest and `SHA256SUMS.txt`), then updates the optional Homebrew tap. The Swift app and its release path have been removed from the tree; they remain in git history and prior release tags. The manual release candidate (RC) path below does not create or move tags, create a GitHub Release, or update the Homebrew tap.

## Prepare a candidate

Run the **Release** workflow from `main` and select `rust-production-rc`. Enter the full SemVer candidate, such as `0.6.0-rc.1`, then type `RUST_PRODUCTION_MIGRATION_VALIDATED` only after the migration validation has completed. The workflow rejects other branches, missing acknowledgements, and invalid versions.

The shared build job packages once with `CHANNEL=production`, `RELEASE_VERSION` set to the requested candidate, and the locked Cargo feature `chau7_next_core/production`. It stores that bundle and its build manifest as an unsigned Actions artifact. The signing job downloads those exact bytes and does not run Cargo or rebuild the app.

The bundle reports `CFBundleShortVersionString` as the numeric SemVer core (for example `0.6.0`) and `CFBundleVersion` as the numeric workflow run number. The external build manifest records the full `releaseVersion` (for example `0.6.0-rc.1`) and the `cargoPackageVersion` used by the current Rust workspace, so prerelease labels and internal crate versions remain distinguishable.

The Rust production RC intentionally omits the opt-in Next CLI installer. That installer writes the beta `chau7-next` command and must not redirect a user's stable `chau7` command to the beta. Stable CLI installation remains pending until its production migration is complete.

## Signing and candidate outputs

The RC signing job and the tag publish job require these GitHub Actions secrets, checked by `scripts/release/require-signing-secrets.sh`:

- `APPLE_DEVELOPER_ID_APPLICATION`
- `APPLE_CERTIFICATE_P12`
- `APPLE_CERTIFICATE_PASSWORD`
- `APPLE_ID`
- `APPLE_ID_PASSWORD`
- `APPLE_TEAM_ID`

It imports the certificate into the isolated release keychain, signs and verifies the app executable and six helper executables individually, signs and verifies the app bundle, notarizes and staples the app, then creates and notarizes a DMG. The signed ZIP, DMG, refreshed build manifest, and `SHA256SUMS.txt` are uploaded as the `rust-production-rc-*` Actions artifact. The manifest holds SHA-256 hashes for all seven executables after signing and records the production feature, signing team, notarization, RC stage, and artifact-only distribution status. GitHub build provenance is attached to the candidate files.

Missing signing configuration fails the signing job before an artifact is presented as signed. The RC is available through Actions artifact retention only. A stable `v*` tag runs the same signer with `RELEASE_STAGE=stable`, which names the assets `Chau7-AppleSilicon.*` and records the `stable` stage and `github-release` distribution in the manifest.

## Local packaging contract

`apps/chau7-next/scripts/bundle-macos.sh` defaults to the existing `next` channel and keeps its app name and bundle ID. Set `CHANNEL=production` and provide a valid `RELEASE_VERSION` to opt into `Chau7.app`, `com.chau7.app`, and the unified production Cargo feature. Production packaging requires both Go helper binaries and a numeric `BUILD_NUMBER`. The package script only builds and ad-hoc signs; use the CI signing path for a distributable production candidate.
