# Release validation

`Release` builds the native backends and release app through `build-dist.sh` once,
then stores the complete unsigned distribution as a tar artifact. The publish job
restores that artifact and only signs/repackages it; it never compiles Swift again.
Build jobs have read permissions; publish alone has release/provenance permissions.
All action revisions are commit-pinned, and the release/tap sequence is serialized.

A manual `workflow_dispatch` is a nonpublishing build/test run: only the read-only
build job can execute. The signing/publish job requires a `push` of a `v*` tag, so
manual validation cannot access Apple signing secrets, create releases or write the
tap. Artifacts are retained seven days. Do not push a tag to validate these changes.

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
while release downloads remain available. Jobs are bounded to 60/40/10 minutes.
