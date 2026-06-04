# Full Disk Access & TCC stability

Chau7 is a terminal that spawns AI CLIs (codex, claude) and shells. Those child
processes reach the user's project folders (commonly under `~/Downloads`, a
TCC-protected location) via the **responsible-process** attribution — i.e. they
inherit **Chau7's** Full Disk Access (FDA) grant.

If Chau7's FDA grant is lost, every child fails with **"Operation not
permitted" (`EPERM`, Rust "os error 1")** while Chau7 itself looks fine — which
sends people debugging the wrong layer (codex/claude) for hours.

## Why FDA gets "lost"

macOS TCC binds a grant to the app's **code signature**. It does *not*
continuously re-check a running process — it evaluates at launch and caches the
decision. So a signature change creates a *latent* mismatch that only bites on
the next cold re-evaluation (a new child process, app re-activation, a tccd
restart, or memory-pressure evicting the signature cache). That's why it can run
fine for hours, then break on a cliff.

Signature changes that orphan the grant:

- **Re-signing the installed app in place** (e.g. adding `get-task-allow` for
  `MallocStackLogging`/lldb). This is the most reliable way to break it.
- **Running a different identity.** Local dev builds use `com.chau7.app.dev`,
  a *separate* app from production `com.chau7.app`; TCC grants are per-identity,
  so `com.chau7.app.dev` needs its own FDA grant.

## Prevention

1. **Never re-sign or modify the installed production app in place.** Do
   lldb/`MallocStackLogging` debugging on a separate `com.chau7.app.dev` build,
   never `codesign -f` the running app.
2. **Pre-authorize each identity once.** Grant FDA to both `com.chau7.app`
   (production) and `com.chau7.app.dev` (run `scripts/grant-dev-fda.sh`).
3. **Sign every build identically** (same Developer ID, entitlements, hardened
   runtime). `scripts/check-signing.sh` flags drift — it runs automatically
   during `install-launchpad-app.sh` and can be run manually:
   `scripts/check-signing.sh [path-to-app] [--strict]`.

## Detection (in-app)

- **`FullDiskAccessGuard`** probes FDA at launch and on app-activation and, on
  loss, shows one throttled, actionable alert that deep-links to the Full Disk
  Access settings pane.
- When a child command fails with `EPERM` in a protected folder,
  `PermissionDenialClassifier` attributes it to FDA (two-factor gated) and routes
  it to the same alert — so the message is Chau7-level and fixable, not a cryptic
  CLI error.
- Productivity → Permissions shows a **Full Disk Access** status row.

## Recovery

If terminal commands fail with "Operation not permitted":

1. System Settings → Privacy & Security → **Full Disk Access**.
2. Toggle Chau7 off and on (or remove and re-add it). For dev builds, run
   `scripts/grant-dev-fda.sh`.
3. Relaunch Chau7.
