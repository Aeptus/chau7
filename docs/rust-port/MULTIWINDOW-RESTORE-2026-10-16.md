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

The native `multiwindow-restore` case passed at source `43d296ab3b27fe33c61eb0bcc25b54ce601ff795`.
It opened two production workspace windows in an isolated profile, added a late
tab in the second window, requested quit from that window's update callback and
verified the final manifest after the application exited. Both windows, all
three fixture tabs and the newest provider resume identity were preserved. The
profile was removed only after verification; the production app was untouched.
This case verifies final persistence, not a second application launch.

The consolidated Rust run at that source passed 752 app tests, 2,492 core tests,
three CLI tests and six contract tests. The native-harness Python suite passed
61 tests and the production-updater suite passed 41 tests.

All nine full pre-push gates passed, including Swift build/tests, Periphery,
legacy Rust, Go lint/tests, relay build/tests and dependency audits. The Swift
suite executed 4,594 tests with three expected skips and no failures. That gate
run started at `028ec29c`; the later `43d296ab` change only corrected the manual
native fixture's error type and its changelog entry. The installed Go linter
was replaced for this run only by an isolated official golangci-lint 2.14.0,
which understands the repository's Go 1.27.2 export data.

At the earlier `c7f1887e` baseline, fullscreen acceptance remained open. Hidden-state geometry and traffic-light
alignment passed, but the programmatic menu reveal was ignored by this macOS
version. Subsequent isolated AppKit probes on the built-in and external displays did
not record a real reveal either; the pointer stayed stationary during the
external-display run.
Neither result proves that the hover-triggered system overlay clears the tabbar.
The native fixture must record an actual hidden/revealed/hidden pointer cycle
and enforce the geometry and hit-testing assertions before this issue is closed.

## 2026-10-17 recurrence: an update retry accepted reduced state

The installed and running production app was confirmed as build `202610170939`,
source `c7f1887e4d8df582614d5a6c47ad345dd87492d4`. The termination save was
written by the previous build `202610161917`, before the replacement launched.
This distinction matters: the new process loaded an already incomplete source.

The first updater run retained a verified pre-quit transaction with two windows
of 15 and 9 tabs, including all 24 referenced contexts. Its post-quit transaction
contained only the original nine-tab window. A later updater run captured that
same nine-tab state before and after its wait, so the per-invocation comparison
accepted it. The archive sequence independently confirms the loss: a periodic
snapshot at 07:35:35 UTC has both windows; the 07:38:56 termination snapshot and
07:40:36 restore-source snapshot contain only the nine-tab window.

A failed comparison must remain an unresolved recovery incident across updater
invocations. Taking another backup of the reduced state does not resolve the
incident. Prior complete snapshots must remain authoritative until recovery is
verified, including pane layouts, provider identity and context references.
Historical failed runs without an incident marker also need detection.

The updater now checks this history during a read-only dry run and before a new
quit prompt. It records unresolved loss until a complete saved identity set is
verified, including previously populated working directories. A quit wait timeout
is treated as uncertain because the user can quit just after it expires. Snapshot
files and their containing directories are synchronized before the quit prompt.
The synthetic updater suite passes 56 tests; the native harness suite passes 62.
These tests do not establish that a real application relaunch succeeds.

The missing window's full source and contexts were preserved in another private
backup. One of its provider sessions was already open in the surviving window.
Fourteen missing tabs were recreated in the user's new empty window, with their
working directories, custom titles and validated resume commands prefilled
without Enter. The ten existing tabs were unchanged. The resulting autosave has
windows of 10 and 15 tabs, including the user's empty placeholder. Five editor
split leaves remain in the private source snapshot; the current live MCP API
cannot import their layout. This is partial live recovery, not proof that the
original provider identities and notes are durably restored in the running app.

The extended native regression passed at `1147f853`: a second isolated process
loaded the saved session through `session_store::load` and reopened its windows
through `open_workspace_window`. Both windows, all three provider identities,
working directories, and a split editor with saved content were verified in live
workspaces before a second normal quit. Both final manifests matched. This tests
the production load/open/quit paths inside the isolated fixture, not the entire
normal application bootstrap. The fixture removed only its verified owned profile.

## 2026-10-17 physical fullscreen measurement

A 25-second owned AppKit probe recorded real physical pointer reveals and hides,
with no menu setters or synthetic input. On the built-in display, the fullscreen
main content height was 949 points. Its `contentLayoutRect` stayed unchanged
while a separate, owned fullscreen titlebar window moved over its top edge.
That auxiliary window was 32 points high and emitted public
`NSWindowDidMoveNotification` events throughout the animation.

The titlebar window's actual overlap is the relevant occlusion. Menu visibility
changed before the auxiliary window finished hiding, so the menu visibility flag
alone is insufficient. Convert the auxiliary screen frame into the content
view's coordinates and account only for its visible intersection at the top
edge. This measurement establishes the mechanism; corrected app acceptance still
requires an actual reveal/hide cycle and hit testing against the final build.


## Corrected native acceptance, 2026-10-17

At `aff3c48f`, the owned native fixture completed a physical-pointer cycle on the
built-in Mac display. No synthetic pointer or menu visibility setters were used.

| State | Toolbar alpha | Visible overlap | Renderer height | Tabbar hit-test |
| --- | --- | --- | --- | --- |
| Hidden before | 0 | 0 pt | 949 pt | Owned window |
| Revealed | 1 | 32 pt | 917 pt | Owned window |
| Hidden after | 0 | 0 pt | 949 pt | Owned window |

The renderer never intersected the visible auxiliary toolbar. Native traffic
lights remained aligned during reveal, application deactivation, reactivation,
and exit from fullscreen. The fixture then completed its remaining restoration,
styled-history, resource cleanup and native surface checks successfully.

The Python wrapper initially reported failure because its evidence extractor
looked for `traffic_light_zoom_geometry` directly under `details`; the native
report correctly nests it under `details.surfaces`. The original manifest is
retained unchanged. The corrected extractor passes the 62-test Python suite.
A separate post-hoc evaluation of a copy of the recorded result passes both
manual-pointer coverage and the complete wrapper acceptance predicate; the
original manifest hash remains unchanged. This is a corrected reading of the
recorded native run, not a newly executed GUI run.

Strict workspace Clippy passes. The consolidated Rust run passes 3,254 tests
(753 app, 2,492 core, three CLI, six contracts), with two existing ignored tests.
The two vendor geometry tests also pass through an exact-source temporary Rust
harness using the already compiled Cocoa geometry types. Cargo cannot run that
vendored package's own test target directly because it is outside the workspace
and needs dev-dependencies; this result is limited to the extracted pure helpers.

An external-display attempt stopped before menu reveal because the traffic-light
pixel-capture helper found no minimize-button pixels, while its native geometry
checks passed. This is unresolved external-display capture evidence, not a
validated rendering failure or a passing external-display test. Reduce Motion
with an alpha-only transition without a geometry/occlusion notification has not
been tested. Production Chau7 was never quit, replaced, or relaunched.


## Offline recovery before installing the prepared update

A blocked updater is not a completed installation procedure. Use
`apps/chau7-next/scripts/recover-macos-production.py` to recover a preserved
RustV1 snapshot without replacing the user's newer session with an older one.
The helper loads the ordinary updater's validators from its sibling
`update-macos-production.command`; distribute both files together.

1. Run `python3 recover-macos-production.py --source <preserved-RustV1> --dry-run`.
   This validates manifests, context hashes and referenced editor files and
   reports counts without changing the profile or asking the app to quit.
2. Run the same command with `--apply` from Terminal.app, outside Chau7. The
   helper saves fresh current and source snapshots, and private copies of the
   editor files, before asking for a normal Cmd+Q. It never sends a quit signal.
3. After the app exits, recovery acquires the existing app lifetime lock, saves
   the final state, and combines it with the pre-quit capture and preserved
   source. Immutable contexts are synchronized before the current bundle, then
   the matching index. A conflicting populated identity stops the operation.
4. Keep Chau7 closed and run the ordinary production updater with `--apply`,
   the verified app, receipt and full source SHA. Its normal history guard
   validates the recovered session and records resolution. Only then reopen
   Chau7. Recovery never writes an updater resolution marker itself.

Recovery transactions live separately under
`~/Library/Application Support/Chau7 Recovery Transactions`. No backup is
removed. Current tab UUIDs, order, histories and content are retained. Missing
original tabs are restored by UUID, with their original layouts and context
references. Recreated tabs with new UUIDs are kept; matching names, directories
or provider sessions are not enough to discard recent work.

For the observed incident, the conservative union is three windows with
10, 15 and 15 tabs. The last window contains the missing originals and five
editor layouts. These layouts reference existing files; their saved file bytes
can be backed up, but these manifests do not contain unsaved editor buffers.
One original tab shares a provider session with a current tab: the loader's
existing first-wins rule retains the current owner and restores the original
with its history and inert archived metadata, without a second active resume.

Do not reopen the app between recovery and the updater: loading legitimately
normalizes duplicate resume metadata and launch-command hints. The updater
needs to verify the complete recovered transaction before that normalization.

Validation: 26 synthetic recovery tests pass, including loss-free current/source
union, metadata conflicts, content hash failures, symlink rejection, normal-quit
and lifetime-lock gates, a stale plan, and interruption after bundle publication.
The 56 updater and 62 native-harness Python tests also pass. On a private copy
of the observed session, merge, publication, re-read and full-payload comparisons
pass with 40 tabs, 40 contexts and three windows. The ordinary updater's
read-only history validator accepts this recovered copy for the original
incident. The production app/profile were not modified by that verification.


## Remaining empty fullscreen titlebar, 2026-10-17

The user confirmed that the tab row remains visible in the installed
`4c870950` build, but an empty black row still appears below the system menu.
The previous acceptance proved that the tabs were unobscured and clickable;
it allowed the renderer to shrink by the auxiliary titlebar's 32-point overlap.
That leaves a second titlebar row because GPUI draws the tabs and relocated
window controls inside the main content view. The Swift app instead uses an
actual `NSToolbar` for its tabs.

The candidate correction suppresses only the retained, owned auxiliary chrome
of a custom transparent full-size-content window with no native toolbar,
titlebar accessories, visible native title or subtitle, after all three native
controls have moved into their visible main-content host. It saves and restores AppKit appearance, mouse-event
policy and original container visibility. Reconciliation is idempotent and
uses the saved visibility so its own hidden flag cannot alternate suppression
on successive layout notifications. It does not change window alpha, level,
ordering, fullscreen presentation options, or other applications' windows.

The renderer uses the full content layout only while suppression settings read
back successfully. Otherwise it retains the existing occlusion avoidance.
Native evidence keeps the raw auxiliary overlap separate from the applied
renderer inset, checks the top gap independently against `contentLayoutRect`,
and still requires window-server hit testing to select the owned app window.
A successful geometry-only check cannot establish the final composite pixels.

The candidate passes 3,254 workspace Rust tests with the native fixture feature
(two existing ignored tests), strict workspace Clippy including all targets and
the native fixture, and formatting checks. Five pure vendor helpers/tests pass
through an exact-source temporary harness; the vendor package is outside the
workspace, so this is not a claim that its entire test target ran. The 35 vendor
hash chains match the current files.

Physical and composited-pixel acceptance remains pending. A standalone AppKit
probe is prepared for two real pointer reveal/hide cycles and actual tab-row
clicks. Settings readback and renderer-only pixels do not establish that AppKit
has stopped painting the empty row. The PR remains a draft. No current
production app or restoration state has been changed by this investigation.


## Fullscreen crash regression, 2026-10-17

The installed `89a64954` candidate aborted on fullscreen entry. Both native
crash reports show `NSInternalInconsistencyException` in
`-[NSWindow titlebarAccessoryViewControllers]`; the system log states that the
property is unsupported for the window style. The empty-chrome eligibility
check queried it on AppKit's borderless auxiliary window. The selector exists
on that window, so selector availability cannot prevent this exception.

Accessory lookup now runs lazily only on titled windows without a native
toolbar. A toolbar, a nonempty accessory array, or an unknown accessory result
continues to prevent suppression. The auxiliary snapshot reads and changes
titlebar transparency only for a currently titled window, and main-window
title/subtitle checks follow a titled/full-size-content eligibility gate.
Generic window appearance and original-container restoration remain intact.

Three pure regressions cover the lazy borderless path, toolbar refusal, and
empty/nonempty/unknown titled accessory arrays. The native restore fixture now
runs two owned fullscreen enter/exit cycles before its separate geometry and
composited-pixel checks. It records actual AppKit completion notifications,
cycle count, app survival, and bounded cleanup evidence.

A hidden-window Objective-C probe on macOS 27.2 reproduced the original
exception inside `@try/@catch`. The guarded titled read, toolbar refusal,
borderless skip, generic appearance setters, and guarded transparency
round-trip passed. All probe windows remained invisible. This establishes the
AppKit precondition; it does not establish complete GPUI fullscreen or physical
menu-hover acceptance. Validation of the complete candidate is recorded
separately after the exact-revision native run.

The complete Rust workspace passes 3,254 tests with two existing ignored tests;
strict Clippy with all targets and the native fixture passes. Five exact-source
vendor tests pass, and all 35 vendor hash chains match. The first workspace run
also exposed the prior production rebuild helper's four intentional bundle-ID
references in the isolation scan. The scan now permits only those exact file
and metadata lines; all forbidden data paths remain checked.


## Revealed system-menu overlap follow-up, 2026-10-17

The installed `a5534870` survives fullscreen entry, but the user reports tabs
covered again when the system menu appears. Two distinct areas need separate
handling. The prior physical built-in-display measurement has a 982-point screen
and a 949-point fullscreen app: the system menu lies above the app, while an
additional 32-point AppKit auxiliary titlebar overlaps its top. The isolated
external-display probe has a full-height 1080-point app/content layout, zero
safe-area top, and a measured 30-point main menu. Clearing the auxiliary alone
cannot exclude the external screen's system-menu band.

The backend now converts the current screen's actual menu band into content-view
coordinates and removes only its intersection while the fullscreen app/window
is active/key and AppKit reports the menu visible. It clips any remaining
nonempty native toolbar afterward, avoiding double counting. Existing
contentLayoutRect reservations therefore add no extra menu inset. Move, screen,
key and app activation changes coalesce onto the same deferred main-queue sync
as native auxiliary notifications, avoiding new reentrant renderer updates.

The auxiliary snapshot also retains the exact contentView and its original
hidden state. Clear-window flags plus hiding only the titlebar container do not
remove every native drawing view. Reconciliation verifies the current root,
restores the previous root before accepting a replacement, and restores the
original root visibility on exit. AppKit's frame, alpha, ordering and
presentation options remain untouched in production. The borderless accessory
query guard from the crash correction remains in place.

An isolated AppKit comparison captured only its own 32-point blue tab row while
forcing its owned auxiliary over that row. The initial image-preview reading
suggested a difference, but direct RGBA analysis disproved it: all seven label
regions have identical pixels, including 1,250 near-white pixels in each crop.
The sampled top window remained the main window in every variant, and the
system menu was hidden. The forced probe therefore did not establish actual
auxiliary paint or verify the content-root correction. Earlier captures with
the auxiliary above the row are also inconclusive. These diagnostics cannot
replace physical menu-hover acceptance. The content-root change remains a
reviewed candidate whose final visible result needs that acceptance.

The native fixture now keeps raw menu-band intersection separate from active
menu inset and auxiliary inset. It rejects a revealed menu overlapping the
renderer or tab-row crop, requires the app to remain frontmost at the tab hit
point, and permits only the actual menu-derived gap when the empty auxiliary
is suppressed. Manual pointer phases retain renderer stability checks without
requiring an auxiliary overlap as proof of menu visibility. Renderer captures
remain explicitly non-composited. Full physical reveal/hide and final
composited acceptance on both display types are still required; they are not
inferred from the forced probe.

Validation after the combined change: 3,254 workspace Rust tests pass with two
existing ignored tests; formatting and strict workspace Clippy with all targets
and the native fixture feature pass. Twelve actual vendor helper/test bodies
pass through a temporary exact-source rustc harness using Cocoa's real geometry
types, including the previous borderless-accessory crash guards. This does not
claim execution of the entire vendor test target. All 35 vendor hash chains
match. The fixture's expanded JSON evidence is assembled from smaller values
rather than raising the crate's macro recursion limit.

The exact code candidate also completed two native fullscreen enter/exit cycles
with the default renderer and two with the software renderer. Both report all
entry/exit notifications, app survival, successful cleanup and no transition
error. The complete restore cases remain failed: the later programmatic menu
reveal reaches its deadline waiting for `menu bar visibility true` (the default
run additionally lost foreground during menu-visibility cleanup). These are
partial transition-survival results, not passing restore/visual cases. Both
owned test processes were subsequently checked separately for normal exit;
the production process was left running.


The first manual-pointer attempt on `104c712e` selected the external display
from the pointer's position before fullscreen entry. Two transition cycles
passed, but the subsequent initial fullscreen check stopped before any hover
instruction: the minimize control had zero qualifying contrast pixels in the
owned frame-view cache. All three controls passed the preceding native geometry
and visibility checks. This does not distinguish an actual paint regression
from a view-cache or disabled-control contrast false negative. The assertion
ran before crop serialization, so that failed crop was not retained. No physical
menu reveal was exercised in this attempt. Evidence is retained in
`/private/tmp/chau7-s18-menu-overlay-review/native-candidate-104c712e/manifest.json`;
the isolated process exited and production Chau7 stayed open.

The diagnostic follow-up retains all three pixel counts and a bounded owned
NSView-cache crop before enforcing the same visibility thresholds. It records
scale, geometry and enabled state rather than inferring screen composition from
the view cache. The initial control-paint result is retained while the independent
menu reveal check runs; either failure still fails the complete case. This lets
the operator exercise the menu without silently accepting a control-paint failure.
