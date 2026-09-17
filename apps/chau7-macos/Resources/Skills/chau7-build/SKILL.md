---
name: chau7-build
description: Build, install, and relaunch the Chau7 macOS app through its guarded local workflow while preserving session restoration data.
---

# Chau7 Build

Use this skill for an explicit request to build, rebuild, install, relaunch, or safely quit the local Chau7 macOS app. It is not an iOS/Xcode build workflow and it does not publish a release unless the user separately requests publication.

## Canonical workflow

The single entry point is:

```bash
cd /Users/christophehenner/Repositories/Chau7/apps/chau7-macos
./Scripts/rebuild-and-relaunch.sh
```

The script builds and verifies a complete bundle before asking the running app to quit, stages and atomically installs the bundle, retains a rollback copy, and then relaunches it. Intermediate compilation uses `com.chau7.app.dev` with launching disabled; only the verified package is `com.chau7.app`.

Choose the smallest mode that matches the request:

- Full local cycle: no extra flags (release build, install, relaunch).
- Compile and verify only: `--no-install --no-launch` (the running app is not touched).
- Quit only: `--quit-only`.
- Install without opening: `--no-launch`.
- Inspect without mutation: `--dry-run`.
- Debug iteration: `--debug` (still keep the same quit/install safety rules).

Do not add `--allow-dirty`, `--allow-stale-source`, or `--force` unless the user explicitly authorizes that exception. If the request is only for an explanation or a plan, use `--dry-run` and report the command instead of changing processes.

## Safety checks before execution

1. Run a read-only source preflight: inspect `git status`, the current branch/commit, and `origin/main`/`aethyme/integration`. Do not discard or stash user changes. When source edits are needed, use the Aethyme broker and its managed worktree; building alone does not authorize source edits.
2. Confirm that restoration data exists before a mutating run. Read metadata only (never dump transcript contents) from:
   - `~/Library/Application Support/Chau7/TabRestoreBundles/current/manifest.json`
   - `~/Library/Application Support/Chau7/TabStateBackups/latest.json`
   - `~/Library/Preferences/com.chau7.app.plist`
   For a non-empty manifest, record `savedAt`, window count, and tab counts so the result can be compared afterward.
3. Run the canonical script from `apps/chau7-macos`; do not call `build-and-run.sh` with the production bundle identifier while a production Chau7 process is running.

## Restoration invariants

- Build and packaging output lives under `apps/chau7-macos/build`; session state is outside the app bundle and must never be removed, rewritten, or used as a build cache.
- The restore bundle is swapped atomically; the lightweight UserDefaults index is published only after the full bundle is durable. Termination drains the ordered persistence queue before app-owned shells close.
- A graceful AppleScript quit is the default. If it times out, the script must fail without sending a POSIX signal. `--force` is an explicit last resort: it may bypass `applicationWillTerminate` and lose the newest in-memory snapshot. Never add it automatically and never replace it with `kill`, `pkill`, or `kill -9`.
- A failed build or failed preflight must leave the running app and restoration files untouched. An installation failure should leave the rollback copy and be reported; do not delete `ReleaseBackups` or restore directories to “clean up.”

## Verification after execution

Read the latest workflow log under `apps/chau7-macos/build/logs/` and require a successful final status. Verify the installed bundle has the expected production identifier and build SHA. Re-read restore metadata and ensure the manifest and backup are still parseable; if a previously non-empty state becomes missing or unexpectedly empty, treat the run as failed and stop rather than claiming restoration succeeded. A relaunch may legitimately advance `savedAt`, so compare structural counts and file presence rather than raw timestamps alone.

For source changes related to this workflow, run at least:

```bash
swift test --package-path apps/chau7-macos
swift build --package-path apps/chau7-macos
bash -n apps/chau7-macos/Scripts/rebuild-and-relaunch.sh
shellcheck -x apps/chau7-macos/Scripts/rebuild-and-relaunch.sh
```

Report the selected mode, source SHA, whether the app was quit/installed/launched, restoration metadata before/after, and any explicit exception used. Keep commands and logs free of terminal transcript contents or literal keystrokes.
