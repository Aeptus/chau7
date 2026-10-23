# Release validation

`Release` ships the Rust/GPUI app from `apps/chau7-next`. A `preflight` job resolves
the stage and version, then the `build` job runs `apps/chau7-next/scripts/bundle-macos.sh`
once with `CHANNEL=production` and stores the unsigned `Chau7.app` and its build
manifest as a tar artifact. The signing jobs restore that artifact and only sign,
notarize and repackage it through `scripts/release/sign-rust-production.sh`; they
never run Cargo. Build jobs have read permissions; only `publish` can write a release.
All action revisions are commit-pinned, and the release/tap sequence is serialized.

| Trigger | Stage | Signing | Output |
| --- | --- | --- | --- |
| push of a `v*` tag | `stable` | required | GitHub Release with `Chau7-AppleSilicon.dmg`, `.zip`, build manifest and `SHA256SUMS.txt`, then the optional Homebrew tap |
| manual, `production-dry-run` (default) | `dry-run` | none | unsigned bundle artifact only |
| manual, `rust-production-rc` from `main` with the migration acknowledgement | `rc` | required | signed RC Actions artifact only |

A manual dry run cannot access Apple signing secrets, create releases or write the
tap. Artifacts are retained seven days. Do not push a tag to validate these changes.
The Swift app's release path was removed with the Swift app; it remains in git
history and prior release tags.

Run `node --test scripts/quality/tests/release-lifecycle.test.mjs` for a completely
synthetic signing lifecycle fixture. It stubs security/notary commands and tests
failure and cancellation cleanup without real credentials or user keychains.
GitHub PR CI runs this suite; `actionlint .github/workflows/release.yml` validates
workflow syntax locally without building the app.

Signing uses a random-password runner-only keychain, trusted signing executables
rather than unrestricted import, and a stored notarization profile. Setup failures
clean immediately; `always()` cleanup restores the previous keychain search list
and removes the keychain, certificate, password and temporary submission artifacts
after success/failure/cancellation. GitHub's hard runner termination cannot execute
cleanup; the ephemeral runner is the remaining boundary in that case. The optional
Homebrew token controls only the tap job; missing it produces an explicit summary
while release downloads remain available. Jobs are bounded to 10/60/60/10/60 minutes.
