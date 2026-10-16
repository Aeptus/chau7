# Multi-window restoration incident, 2026-10-16

## Observed failure

The production Rust build `202610161917` restored only the first window after
normal quit and an app update. The updater's post-quit backup already contained
the incomplete session, so replacing the app bundle did not cause the loss.

The local archive sequence establishes the boundary (times in Europe/Paris):

| Snapshot | Windows and tab counts |
| --- | --- |
| 19:48 periodic | 2 windows: 15, 10 |
| 19:53 periodic | 2 windows: 15, 10 |
| 19:58 termination | 1 window: 15 |
| 19:58 restored source | 1 window: 15 |

The writer reported a successful final drain. That result measured successful
persistence of the supplied snapshot, without proving that the snapshot included
every live window.

## Cause and required behavior

A quit action can run with its originating GPUI window temporarily borrowed.
The old capture loop silently skipped failed `WindowHandle::update` calls and
submitted the remaining windows as a complete session. Quitting from the second
window could therefore replace the complete snapshot with only the first one.

Quit capture must run after the initiating window has returned to GPUI. Snapshot
capture must also fail as a whole if any registered workspace or window cannot
be captured. A failed capture must preserve the last complete durable state;
it must never prune the omitted window's contexts or clear the session. A user
quit must leave the app running if the full capture cannot be admitted to the
writer.
This admission guard does not turn an asynchronous disk write into a synchronous
durability acknowledgement.

Regression coverage must include two windows, quit initiated inside an update
of window two, and metadata changed in that window immediately before quitting.
The final snapshot must preserve both windows and that newest metadata.

## Additional loss path found during review

Rust keeps the tabs and processes of a closed window in `AppData.hidden` so the
Dock or a shortcut can reopen them. The capture loop previously serialized only
live workspace windows. A later autosave therefore omitted those parked tabs;
quitting with every window parked could submit an empty final session. This is a
separate source-level defect, not evidence that it caused the observed 19:58
incident.

Persistence must include these parked windows with the same tab, split, provider
identity and terminal-context capture used for visible windows. Their contexts
must also remain in the writer's retention set. Regression coverage must include
one visible plus one parked window and an app with only parked windows. If
native window creation fails when reopening a parked window, its tabs must be
returned to the parked collection rather than dropped.

## Update protection

The updater must preserve a verified current restore transaction before asking
for a normal quit. Its existing full post-quit backup is still necessary, but
cannot recover a window that the old app already omitted during shutdown.

Before replacing the installed app, compare the old window/tab/pane identities
with the final saved state. Added windows and tabs, new metadata and changes to
selection are normal; losing an old window, tab, pane, provider resume identity
or required context must stop installation and retain both snapshots. Restore
files must never be copied into a running app's profile.

## Live recovery

The ten absent tabs were recreated through the production MCP server in the
empty window opened by the user. Existing first-window tabs were untouched.
The recovery preserved working directories and explicit titles. Six validated
provider resume commands were typed without Enter. One archived provider
identity was already present in the first window, so it was not duplicated.
Three entries were plain shells. The user's initial empty tab was retained.
The first recovery autosave contained two windows with 15 and 11 tabs.
A later autosave contained 15 and 10 tabs.

A private backup of the source manifest, relevant contexts and the old/new tab
ID mapping was retained locally. No user paths, session IDs, terminal text or
resume commands belong in repository evidence.

Raw MCP input is not equivalent to the native restoration prefill API: unsubmitted
input in a freshly created shell does not establish durable provider identity.
The original recovery manifest remains the authority for those six resume
identities until they are resumed or explicitly imported through the restore
path. This limitation must be accounted for before the next local update.

## Fullscreen follow-up

The previous titlebar-transparency change did not resolve the native system-bar
occlusion. AppKit's `contentLayoutRect` describes the content not obscured by
its toolbar and is observable through KVO:
[Apple documentation](https://developer.apple.com/documentation/appkit/nswindow/contentlayoutrect).

The native regression must compare the actual renderer view frame with that
layout rect during hidden, revealed and hidden-again states, with no hidden-menu
gutter and with the traffic-light host on the same top edge. Mouse, drag, text
input and VoiceOver frames must use the actual renderer view. Offscreen GPUI
pixels alone cannot establish that an AppKit overlay is absent. Forced menu
visibility and physical pointer hover are distinct acceptance conditions.

## Validation

The native `multiwindow-restore` case passed at source `918cad58ef73af7d027651ec2a6dbf3c9269cd7d`.
It opened two production workspace windows in an isolated profile, added a late
tab in the second window, requested quit from that window's update callback and
verified the final manifest after the application exited. Both windows, all
three fixture tabs and the newest provider resume identity were preserved. The
profile was removed only after verification; the production app was untouched.
This case verifies final persistence, not a second application launch.

The preceding regression run passed 749 app tests, 2,492 core tests and six
contract tests. The Swift suite passed 4,594 tests with three expected skips.
The full local quality gate passed Swift, Periphery and legacy Rust checks, then
stopped at an installed Go linter that could not read Go 1.27.2 export data.
An isolated official golangci-lint 2.14.0 passed both Go modules; the remaining
full-gate stages still require execution.

Fullscreen acceptance remains open. Hidden-state geometry and traffic-light
alignment passed, but the programmatic menu reveal was ignored by this macOS
version. Subsequent isolated AppKit probes on the built-in and external displays did
not record a real reveal either; the pointer stayed stationary during the
external-display run.
Neither result proves that the hover-triggered system overlay clears the tabbar.
The native fixture must record an actual hidden/revealed/hidden pointer cycle
and enforce the geometry and hit-testing assertions before this issue is closed.
