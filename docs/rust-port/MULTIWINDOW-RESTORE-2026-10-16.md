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
it must never prune the omitted window's contexts or clear the session.

Regression coverage must include two windows, quit initiated inside an update
of window two, and metadata changed in that window immediately before quitting.
The final snapshot must preserve both windows and that newest metadata.

## Live recovery

The ten absent tabs were recreated through the production MCP server in the
empty window opened by the user. Existing first-window tabs were untouched.
The recovery preserved working directories and explicit titles. Six validated
provider resume commands were typed without Enter. One archived provider
identity was already present in the first window, so it was not duplicated.
Three entries were plain shells. The user's initial empty tab was retained.
The subsequent autosave contains two windows with 15 and 11 tabs.

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
layout rect during hidden, revealed and hidden-again states. Offscreen GPUI
pixels alone cannot establish that an AppKit overlay is absent. Forced menu
visibility and physical pointer hover are distinct acceptance conditions.

## Validation

Implementation and regression execution are in progress. Do not interpret this
incident report as a passing native fullscreen or relaunch acceptance receipt.
