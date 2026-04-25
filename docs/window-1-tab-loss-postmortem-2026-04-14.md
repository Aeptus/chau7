# Window 1 Tab Loss Postmortem

Date: 2026-04-14

## Summary

`Window 1` tabs were repeatedly lost after a rebuild or relaunch because the app running from `/Applications/Chau7.app` still skipped primary-window restoration. The persisted multi-window state contained both windows, but only the secondary window was being hydrated. Each bad relaunch then autosaved the damaged state back to disk, replacing the previously good recovery payload.

## User Impact

- `Window 1` came back as a fresh shell or a single-tab window.
- `Window 2` continued to restore normally.
- Subsequent rebuilds and relaunches made recovery harder by overwriting `latest.json` and the `UserDefaults` restore blob with the already-damaged layout.

## What Happened

1. A good archived multi-window backup still existed, with `Window 1 = 23 tabs` and `Window 2 = 11 tabs`.
2. The active `/Applications/Chau7.app` build was still running a stale implementation of `OverlayTabsModel.restoreSavedTabs(appModel:)`.
3. That implementation explicitly removed the legacy single-window key and returned `nil`, which meant the primary overlay model never restored the first saved window.
4. `AppDelegate.restoreAdditionalWindows()` still restored `dropFirst()` from the multi-window state, so secondary windows continued to appear.
5. After launch, Chau7 persisted the now-damaged runtime state back to:
   - `~/Library/Preferences/com.chau7.app.plist` under `com.chau7.savedMultiWindowState`
   - `~/Library/Application Support/Chau7/TabStateBackups/latest.json`
6. That converted a recoverable `[23, 11]` layout into `[1, 11]`, then kept replaying the broken state on later launches.

## Root Cause

The root cause was stale restore logic in the shipped app bundle. The code path that should restore the first saved window had regressed to a hardcoded `return nil`.

Affected implementation:

- `apps/chau7-macos/Sources/Chau7/Overlay/OverlayTabsModel+RestorePipeline.swift` (renamed from `OverlayTabsModel+SessionFinder.swift` on 2026-04-25)

Broken behavior:

- primary window restore skipped entirely
- only additional windows restored from the multi-window payload

## Contributing Factors

- The bad launch path immediately rewrote persisted state, so the recovery source degraded after each restart.
- `/Applications/Chau7.app` matched the local build output, so rebuilding without the actual source fix simply reproduced the bug.
- Live tab recreation through UI automation was not a viable fallback because macOS accessibility restrictions blocked synthetic keystrokes.
- Restarting Chau7 from a Codex session hosted inside Chau7 is self-disruptive and complicated recovery attempts.

## Detection

The issue was confirmed from three independent signals:

- source inspection showed `restoreSavedTabs(appModel:)` returning `nil`
- app logs showed repeated lines like `Restored additional window 1 with 11 tab(s) from user defaults` without corresponding primary-window restoration
- persisted state after relaunch collapsed to `[1, 11]`

## Fix

`restoreSavedTabs(appModel:)` was corrected to:

1. restore the first window from `SavedMultiWindowState.userDefaultsKey` when present
2. fall back to the legacy single-window key
3. fall back to disk backups if `UserDefaults` has no usable state

Regression coverage already existed and now matches the implementation again:

- `apps/chau7-macos/Tests/Chau7Tests/Overlay/OverlayTabsModelTests.swift`
  `testRestoreSavedTabsUsesPrimaryWindowFromMultiWindowState`

## Validation

From `apps/chau7-macos`:

- `swift build` passed
- `swift test` passed with 1369 tests and 0 failures

## Recovery Source

Best current known-good archive:

- `~/Library/Application Support/Chau7/TabStateBackups/archive/1776174632313-termination.json`

Recovered layout in that archive:

- `Window 1`: 23 tabs
- `Window 2`: 11 tabs

## Follow-Up Actions

- Install the fixed build into `/Applications/Chau7.app`.
- Seed both restore sources from the good archive before the next relaunch:
  - `com.chau7.savedMultiWindowState`
  - `latest.json`
- Consider making backup recovery more defensive when the live persisted state regresses sharply, for example preferring a recent archive when the primary window collapses unexpectedly.
