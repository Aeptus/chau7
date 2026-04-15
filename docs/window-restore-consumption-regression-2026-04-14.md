# Window Restore Consumption Regression

Date: 2026-04-14

## Summary

Chau7 still restores the wrong second window even when the stored multi-window payload is correct.

At this point, the issue is no longer primarily "missing backup data". The current live restore sources contain a reconstructed two-window payload with:

- `Window 1`: 11 tabs
- `Window 2`: 16 tabs

But the running app still restores:

- `Window 1`: 11 tabs
- `Window 2`: 1 tab

This makes the issue an app-side restore-consumption regression.

## User Impact

- Important tabs in `Chau7`, `chau7-website`, `website`, `Mockup`, and `Mediawiki - Control` do not come back on launch.
- The user sees two windows, but the second one is reduced to a single `Chau7` tab instead of the expected multi-repo workspace.
- Repeated relaunches risk re-persisting the wrong `[11, 1]` layout and obscuring recovery attempts.

## Expected Behavior

Given a live restore payload of `[11, 16]`, Chau7 should restore:

1. the surviving 11-tab workspace containing:
   - `Aetower`
   - `aegowlg`
   - `Aethyme`
   - `Aexeo`
   - `safeskills`
2. the reconstructed 16-tab workspace containing:
   - `Chau7`
   - `chau7-website`
   - `website`
   - `Mockup`
   - `Playground/Mediawiki/Mediawiki - Control`

## Actual Behavior

On the latest reproduced launch, Chau7 restored:

- `Restored 11 tab(s) from saved state`
- `Restored 1 tab(s) from saved state`
- `Restored additional window 1 with 1 tab(s) from user defaults`

So the app still consumed or derived a one-tab secondary window even though the prepared restore payload was `[11, 16]`.

## Strong Evidence

### App logs

From `~/Library/Logs/Chau7.log`:

- `2026-04-14T20:19:54.416Z Bundle id=com.chau7.app`
- `2026-04-14T20:19:54.673Z Restored 11 tab(s) from saved state`
- `2026-04-14T20:19:54.953Z Restored 1 tab(s) from saved state`
- `2026-04-14T20:19:54.958Z Restored additional window 1 with 1 tab(s) from user defaults`
- `2026-04-14T20:20:26.952Z Startup restore summary: ... deliveredResumePrefills=11 restoreBootstrapSettled=12 ...`

The key point is that the app explicitly logged restoration of only `1` tab for the additional window.

### Stored restore payloads

At the time of investigation:

- live `com.chau7.app` defaults domain was seeded with a reconstructed `[11, 16]` payload
- `savedTabState` contained the 11-tab primary window
- the reconstructed secondary window contained roots:
  - `/Users/christophehenner/Downloads/Repositories/Chau7`
  - `/Users/christophehenner/Downloads/Repositories/chau7-website`
  - `/Users/christophehenner/Downloads/Repositories/website`
  - `/Users/christophehenner/Downloads/Repositories/Mockup`
  - `/Users/christophehenner/Downloads/Repositories/Playground/Mediawiki/Mediawiki - Control`

So the missing window content existed in the prepared restore source.

### Reconstructed missing window source

The missing tabs were reconstructed from a healthy restore window in the logs around `2026-04-14T16:27` to `2026-04-14T16:28`.

Recovered missing tabs included:

- `Chau7`: 4 tabs
- `chau7-website`: 3 tabs
- `website`: 2 tabs
- `Mockup`: 6 tabs
- `Playground/Mediawiki/Mediawiki - Control`: 1 tab

The `Aethyme` tabs were not actually missing from the surviving 11-tab window; they were already present there.

## What Has Already Been Ruled Out

### 1. "The data is gone"

False.

The important missing repos and sessions were recovered from logs well enough to synthesize a valid multi-window payload.

### 2. "The wrong disk backup was the only issue"

False.

That was an earlier problem, but even after seeding a corrected `[11, 16]` payload, the app still restored `[11, 1]`.

### 3. "The app was reading the wrong bundle ID"

False.

The logs show:

- `Bundle id=com.chau7.app`

which matches the restore domain that was targeted.

### 4. "Autosave raced and overwrote state before restore"

Not supported by the startup order.

`AppDelegate` runs:

1. `setupOverlayWindow()`
2. `restoreAdditionalWindows()`
3. `startMultiWindowAutoSaveTimer()`

So the 30-second autosave timer is not the immediate cause of the bad secondary-window restore.

## Most Likely Current Root Cause

The restore-consumption path is still collapsing the second window before or during `restoreAdditionalWindows()`.

Most likely candidates:

1. `UserDefaults.standard.data(forKey: SavedMultiWindowState.userDefaultsKey)` is not returning the same effective payload that was prepared externally.
2. `restoreAdditionalWindows()` or the pre-decoded `restoringStates` path is mutating or selecting the wrong window before `OverlayTabsModel(appModel:restoringStates:)` consumes it.
3. The additional window payload is reaching `decodeRestorableTabs(fromStates:)` in an already-reduced shape.

At this point the failure should be debugged as an in-app restore path problem, not as a persistence discovery problem.

## Relevant Code Paths

- `apps/chau7-macos/Sources/Chau7/App/AppDelegate.swift`
  - `attemptInitialSetupIfReady()`
  - `restoreAdditionalWindows()`
- `apps/chau7-macos/Sources/Chau7/Overlay/OverlayTabsModel.swift`
  - `init(appModel:restoreState:restoringStates:)`
- `apps/chau7-macos/Sources/Chau7/Overlay/OverlayTabsModel+SessionFinder.swift`
  - `restoreSavedTabs(appModel:)`
  - `decodeRestorableTabs(fromStates:appModel:)`

## Recommended Next Debugging Steps

1. Add explicit logging inside `restoreAdditionalWindows()` for:
   - `SavedMultiWindowState` counts as read by `UserDefaults.standard`
   - the exact `restoredWindows.count`
   - tab counts of each `windowStates` before `OverlayTabsModel(appModel:restoringStates:)`
2. Add logging inside `OverlayTabsModel.init(appModel:restoreState:restoringStates:)` when `restoringStates` is provided:
   - `restoringStates.count`
   - first few `tabID` values
3. Confirm whether `decodeRestorableTabs(fromStates:)` receives 16 states and returns 1 tab, or whether the reduction happens earlier.
4. Do not spend more time searching for alternate backup files until this path is instrumented; the issue is past the persistence-discovery stage.

## Status

Open.

The data needed to reconstruct the missing window exists, but Chau7 still does not faithfully consume that prepared multi-window state on launch.
