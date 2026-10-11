# Spike: Chau7 tab bar in GPUI

Status: superseded. The tab bar was built directly in Chau7 Next
(`apps/chau7-next/crates/chau7_next/src/workspace.rs`); this spec served as its
requirement list. Deviations are listed in `docs/rust-port/PARITY.md`.
Owner: AI agents
Decision this informs: whether the macOS SwiftUI/AppKit UI of Chau7 is ported to GPUI.

## 1. Goal

Rebuild the Chau7 tab bar, standalone, in GPUI, with the behaviour of the current
macOS app. The tab bar is the most demanding UI component in the app. If it works
in GPUI, the rest of the port is lower risk. If a requirement below cannot be met,
the spike must say so clearly so the framework decision can be revisited before
the full port starts.

The spike is throwaway code. Correct behaviour and an honest report matter more
than code quality.

## 2. Out of scope

- Terminal rendering. Each tab hosts a placeholder pane (see 6.1). No PTY, no
  `chau7_terminal`, no Metal or wgpu grid.
- Split panes inside a tab.
- Settings UI, persistence, session restore, MCP, remote, notification delivery.
- AI session detection, token optimisation, real hover card data. Hover cards
  show fake data with the same layout.
- Tab bar auto-recovery (`refreshTabBar`). It exists to work around NSToolbar
  collapsing the hosting view and has no equivalent in GPUI.
- iOS. The iOS app is a remote client and is not affected.

## 3. Pinned dependencies

Pin exact versions. Do not upgrade during the spike. Do not mix the two GPUI
crates: `gpui-component` 0.7.1 depends on `gpui-pre` 0.3.8, not on `gpui`.

```toml
[dependencies]
gpui-component = "=0.7.1"
gpui = { package = "gpui-pre", version = "=0.3.8" }

[dev-dependencies]
gpui = { package = "gpui-pre", version = "=0.3.8", features = ["test-support"] }
```

`gpui-pre` 0.3.8 is a snapshot of Zed at commit `279fe07`. Both crates are
Apache-2.0.

If these versions do not build on the target machine, stop and report rather than
switching versions silently.

## 4. Reference material and licensing

Allowed to read and copy from (Apache-2.0):

- `gpui-pre` 0.3.8 source, including `src/app/test_context.rs` (test harness:
  `TestAppContext`, `VisualTestContext`, `simulate_mouse_move`,
  `simulate_mouse_down`, `simulate_mouse_up`, `simulate_click`,
  `simulate_keystrokes`, `add_window`, `run_until_parked`)
- `gpui-component` 0.7.1 source, especially:
  - `src/tab/tab.rs`, `src/tab/tab_bar.rs`
  - `src/dock/tab_panel.rs` (tab drag and drop with `on_drag`, `drag_over`, `on_drop`)
  - `src/title_bar.rs` (`TitlebarOptions` with `appears_transparent` and
    `traffic_light_position`)
  - `src/native_menu/` (OS-rendered context menus on macOS and Windows,
    GPUI-drawn fallback elsewhere)
  - `src/hover_card.rs`, `src/popover.rs`

Before writing code, copy the files above into `spikes/gpui-tabbar/reference/`
so every agent works from the same API surface instead of guessing.

Not allowed: copying code from Zed's application crates (workspace, terminal_view,
editor, ui, etc.). They are under different, copyleft licenses. Reading them for
ideas is fine; copying is not.

## 5. Source of truth in Chau7

Behaviour must match these files in `apps/chau7-macos`:

| File | What it defines |
|---|---|
| `Sources/Chau7Core/TabBarLayout.swift` | Display items (idle chip, repo group tags, tabs, new-tab button), fallback hit testing, group coalescing order |
| `Sources/Chau7Core/TabDragLayout.swift` | Destination slot during a reorder drag (center-distance threshold) |
| `Sources/Chau7Core/OverlayWindowDropResolver.swift` | Which window a drop at a screen point lands in (tab bar frame first, window frame as fallback, source window excluded) |
| `Sources/Chau7/Overlay/Chau7OverlayView.swift` | Tab bar views, segments, group brackets, `RepoTagChip`, gesture-based drag, context menus, animations, hit-test order (brackets before tabs) |
| `Sources/Chau7/Overlay/OverlayTabsModel.swift` | `OverlayTab`, `TabNotificationStyle`, select, move, close, rename panel state, hover timing (`tabHoverBegan`), prewarm |
| `Sources/Chau7/Overlay/TabHoverCard.swift` | Hover card layout and its optional rows |
| `Sources/Chau7/Overlay/IdleTabsChip.swift` | Idle tabs chip and its popover |
| `Sources/Chau7/Overlay/FullscreenToolbarController.swift` | Fullscreen behaviour (tab bar always visible) |
| `Sources/Chau7/Appearance/TabColor.swift` | Tab colour palette |
| `Sources/Chau7/Settings/FeatureSettings.swift` (`defaultShortcuts`) and `Settings/KeybindingsManager.swift` | Default tab shortcuts and tab actions |
| `Sources/Chau7/App/AppDelegate.swift` (`moveTab`, `handleTabDrop`, `handleGroupDrop`) | Cross-window moves |
| `Tests/Chau7Tests/Overlay/TabBarLayoutTests.swift`, `TabDragLayoutTests.swift`, `OverlayWindowDropResolverTests.swift` | Expected behaviour of the pure logic (13 tests in total) |

When this spec and the Swift code disagree, the Swift code wins. Note the
disagreement in REPORT.md.

## 6. Requirements

Each requirement has acceptance criteria. REPORT.md (section 9) must mark every
one as pass, partial or fail, with the evidence listed in section 10.

### 6.1 Window and model

- One `TabsModel` per window with an ordered list of tabs and a selected tab id.
- Tab fields needed for the spike, mirroring `OverlayTab` and `TabNotificationStyle`:
  - `id`, `title`, `custom_title`
  - `color` (`TabColor`: blue, teal, green, yellow, orange, pink, purple, gray)
  - `repo_group_id: Option<String>` (a repo path; display name is its last component)
  - `is_idle`, `is_suspended`, `is_broadcast_included`
  - notification style: `title_color`, `italic`, `bold`, `pulse`, `icon`,
    `icon_color`, `border_color`, `border_width`, `border_dash`, `badge_text`,
    `badge_color`
- The pane area below the tab bar shows the selected tab's title, colour and id in
  large text. This is the placeholder pane.
- A debug action seeds the model: 12 tabs, 2 repo groups of 3 tabs, 3 idle tabs,
  1 suspended tab, broadcast mode on for 2 tabs, a few notification styles applied.

Accept: app launches on macOS with seeded tabs; selecting a tab updates the pane.

### 6.2 Tab bar in the titlebar

- Tab bar sits in the titlebar row, to the right of the macOS traffic lights,
  using a transparent titlebar (`gpui-component` `title_bar.rs` pattern).
- Keep native titlebar behaviour that Chau7 gets from AppKit today: dragging the
  window from empty tab bar space, and double-click on empty space following the
  macOS "double-click a window's title bar" system setting.
- Fullscreen: tab bar stays visible at all times, as in
  `FullscreenToolbarController`.

Accept: visually aligned with the traffic lights at 1x and 2x scale; window drag
and double-click work; fullscreen keeps the tab bar.

### 6.3 Layout logic port

- Port `TabBarLayout`, `TabDragLayout` and `OverlayWindowDropResolver` to pure Rust
  in a `tabbar_core` module with no GPUI dependency.
- Port all 13 test cases from the three Swift test files to Rust unit tests,
  same inputs, same expected outputs.

Accept: `cargo test tabbar_core` passes with 13 or more tests.

### 6.4 Rendering of items

- Render exactly the items from `TabBarLayout::display_items`: idle chip first when
  any tab is idle, a repo tag chip before each contiguous run of a repo group,
  tabs, then a new-tab button.
- Repo tag chip is non-interactive and visually muted, as `RepoTagChip`.
- Group bracket around each group's tabs. Hit testing checks brackets before tabs,
  as in `Chau7OverlayView.swift`.
- Each tab shows its colour, title, close button, the suspended state visual, the
  broadcast indicator when included, and every notification style field from 6.1
  (including the pulse animation and dashed border).
- Overflow: horizontal scrolling without visible scrollbar, and the selected tab
  is scrolled into view centered when selection changes, as in Chau7.

Accept: seeded data renders every item kind and state; with 30 tabs the bar
scrolls and selecting tab 30 brings it into view.

### 6.5 Selection and keyboard

- Click selects. Close button closes.
- Default shortcuts from `FeatureSettings.defaultShortcuts`: new tab (Cmd+T),
  close tab (Cmd+W), next tab (Cmd+Shift+]), previous tab (Cmd+Shift+[),
  rename tab (Cmd+Opt+R).
- Also implement select tab 1 to 9 and reopen closed tab, with the same behaviour
  and bindings as Chau7 (see `KeybindingsManager.swift`).

Accept: all actions work; closing the selected tab selects the same neighbour
Chau7 selects.

### 6.6 Drag to reorder

- Drag a tab horizontally: other tabs slide to show the destination slot,
  computed with the ported `TabDragLayout::destination_index`.
- Animated slide with a spring feel comparable to Chau7's
  `spring(response: 0.25, dampingFraction: 0.85)`. GPUI has no built-in spring;
  implement a small damped-spring helper in the spike. The dragged tab itself
  follows the cursor without animation, as in Chau7.
- Hover card is dismissed when a drag starts.
- Drop commits the move.
- A tab closed or added in the background during a drag is handled cleanly
  (Chau7 handles both explicitly near its drag end handler).

Accept: reorder works across groups and ungrouped tabs; no visual jump at drop;
background close or add during drag does not crash or corrupt order.

### 6.7 Repo groups

- Dragging a group bracket moves the whole group.
- Context menu on the group bracket, with the same items as Chau7:
  - Move "<repo name>" to Window (New Window, then each other open window by title)
  - Remove from Repo Group (ungroups every tab of the group)
  - Close Group (N tabs)

Accept: all menu actions work; group drag moves the group as a block.

### 6.8 Tab context menu and rename

- Use `gpui-component` `NativeMenu` so menus are OS-rendered on macOS.
- Tab menu items, same as Chau7:
  - Rename Tab...
  - Remove from Repo Group, and Move Group to Window submenu (only when the tab's
    group has 2 or more tabs)
  - Add to Repo Group, Group All Same Repo (when the tab is not grouped)
  - Move to Idle Tabs
  - Move to Window submenu (New Window, then each other open window)
  - Close Tab
- Rename opens Chau7's rename panel equivalent: edit title and colour together,
  with cancel restoring the original title and colour.

Accept: menus appear natively on macOS; every item acts on the right tab; rename
cancel restores both fields.

### 6.9 Hover card and prewarm

- Hover start calls `prewarm(tab_id)`; hover end calls `cancel_prewarm(tab_id)`
  (log only in the spike).
- Hover card appears after 0.4 s of hover, anchored to the tab's horizontal
  center, with the layout of `TabHoverCard.swift` filled with fake data.
- Card is dismissed on drag start, on click, and on hover end, as in Chau7.

Accept: one prewarm and one cancel per hover; card timing and dismissal correct.

### 6.10 Idle tabs chip

- Tabs become idle through "Move to Idle Tabs" (seeded idle tabs also count).
- Chip shows the idle tab count. Click opens a popover listing idle tabs with
  hover card support; clicking an entry selects that tab.

Accept: behaves as described with seeded and manually idled tabs.

### 6.11 Cross-window drag (highest risk)

Two windows open, each with its own `TabsModel`. Chau7 behaviour to reproduce:

- At drag end, the drop point in screen coordinates is resolved with
  `OverlayWindowDropResolver` against every visible, non-minimised window except
  the source: the target's tab bar frame first, its whole window frame as fallback.
- If a target is found, the tab is appended at the end of the target window's tabs
  and selected there. It is not inserted at the drop slot.
- If the target window closed during the drag, the tab goes back to the end of the
  source window and is selected.
- If no target is found, nothing moves across windows.
- Same for a whole repo group via the group bracket (`handleGroupDrop`).

Notes for the implementer:

- In `gpui-pre`, the active drag is stored on the app, not the window
  (`App.active_drag`), so it may be visible to other windows. Test this first.
- If the target window does not receive events while the mouse button is held in
  the source window, use Chau7's approach: at drag end, compute the screen point
  from the source window's bounds plus the mouse position, then resolve against
  all windows' bounds (`cx.windows()`, `window.window_bounds()`).
- Record which approach worked and any platform limitation.

Accept: tab and group move between windows on macOS following the rules above.
Either approach is a pass. If neither works, mark fail and describe exactly why.

### 6.12 Portability check (CI only)

No human tests on Linux or Windows; the only test machine is a Mac. Portability
is proven by CI:

- Add `.github/workflows/spike-gpui-tabbar.yml` running on `macos-latest`,
  `ubuntu-latest` and `windows-latest`, triggered only by changes under
  `spikes/gpui-tabbar/`.
- Each job runs `verify.sh` (or its PowerShell equivalent on Windows): build plus
  all unit and interaction tests. The GPUI test harness uses an in-memory test
  platform, so interaction tests run headless on every OS.
- Ubuntu needs GPUI's system libraries (X11/XCB, Wayland, xkbcommon, fontconfig,
  Vulkan). Find the exact list from the `gpui-pre` 0.3.8 dependencies and install
  them in the job; record the list in README.md.
- On Linux the titlebar may fall back to a client-side title bar. Note in
  REPORT.md what the code does differently there.

Accept: all three CI jobs green; REPORT.md links to the passing run.

### 6.13 Coexistence with the installed Chau7

The spike must be safe to run next to the real Chau7:

- Distinct executable name and, if bundled, bundle id `com.chau7.spike.tabbar`.
- Never read or write `~/.chau7`, `~/Library/Application Support/Chau7`,
  Chau7 UserDefaults keys, Chau7 keychain entries (`com.chau7.*`), or the
  `com.chau7` LaunchAgent. Never open `mcp.sock`, `remote.sock` or `proxy.sock`.

Accept: `verify.sh` (section 10) finds none of these strings in the spike source.

## 7. Layout of the spike

```
spikes/gpui-tabbar/
  SPEC.md            this file
  README.md          how to run, decisions taken (repo rule #1: document near the code)
  REPORT.md          final report (section 9)
  verify.sh          verification gate (section 10)
  Cargo.toml
  reference/         copied gpui-component files (section 4)
  evidence/          logs and screenshots referenced by REPORT.md
  src/
    main.rs          app, windows, seeding, keybindings
    model.rs         TabsModel, Tab, TabColor, TabNotificationStyle
    tabbar_core.rs   pure ports of TabBarLayout, TabDragLayout, OverlayWindowDropResolver
    tab_bar.rs       tab bar view, drag, groups, menus
    rename.rs        rename panel
    hover_card.rs
    idle_chip.rs
    spring.rs        damped spring helper
  tests/
    interactions.rs  GPUI TestAppContext scenarios (section 10.2)
```

The spike is not added to the Chau7 Cargo workspace in `apps/chau7-macos/rust`.

## 8. Working rules for agents

1. Read `AGENTS.md` and this spec before starting. Number questions when asking.
2. Build order: 6.3, 6.1, 6.2, 6.4, 6.5, 6.6, 6.9, 6.10, 6.7, 6.8, 6.11, 6.12,
   6.13. Start a minimal two-window prototype of 6.11 early, since it is the
   requirement most likely to fail.
3. Only use APIs that exist in the copied reference files or the pinned crate
   sources. When unsure, grep the crate source; never invent an API.
4. Every non-obvious decision gets a comment in the code or a line in README.md.
5. Log user-visible events to stdout with a stable prefix, one line each:
   `TABBAR select`, `TABBAR reorder`, `TABBAR drop_target`, `TABBAR move_window`,
   `TABBAR prewarm`, `TABBAR cancel_prewarm`, `TABBAR hover_card`, `TABBAR menu`.
   Section 10 relies on these lines.
6. Run `./verify.sh` before each commit.

## 9. Deliverable

`spikes/gpui-tabbar/REPORT.md` containing:

- A table of requirements 6.1 to 6.13 with pass / partial / fail, one line each,
  and a link to the evidence in `evidence/`.
- For 6.11: which approach worked, with log excerpts.
- Workarounds needed, with rough size in lines.
- APIs that were missing or awkward in `gpui-pre` 0.3.8 / `gpui-component` 0.7.1.
- Every place where the spike deviates from Chau7 behaviour, and why.
- Recommendation: proceed with GPUI, proceed with listed caveats, or revisit egui.

## 10. Verification: is the spike good to go

The spike is "good to go" only when all three layers below pass. Agents must not
mark a requirement as pass without the evidence listed for it.

### 10.1 Automated gate (`verify.sh`)

A script in the spike folder, exiting non-zero on any failure:

1. `cargo fmt --check`
2. `cargo clippy --all-targets -- -D warnings`
3. `cargo test` (unit tests and `tests/interactions.rs`)
4. Count check: at least 13 tests in `tabbar_core`, and one or more interaction
   tests per requirement listed in 10.2.
5. `cargo build --release` on the host.
6. Linux and Windows are not checked locally; they are covered by the CI jobs in
   6.12, which run this same script.
7. Coexistence grep for 6.13: fail if `src/` contains `.chau7`, `Application
   Support/Chau7`, `com.chau7.` (other than `com.chau7.spike.`), `mcp.sock`,
   `remote.sock` or `proxy.sock`.
8. Pin check: fail if `Cargo.lock` resolves `gpui-pre` to anything other than
   0.3.8 or `gpui-component` to anything other than 0.7.1, or if the plain `gpui`
   crate appears in the lock file.

### 10.2 Interaction tests (GPUI test harness)

Written with `TestAppContext` / `VisualTestContext` and the `simulate_*` methods.
The tab bar view must expose each item's last laid-out bounds (recorded during
layout) so tests can click and drag at real positions.

| Requirement | Scenario | Assert |
|---|---|---|
| 6.4 | Seed data | Rendered item sequence equals `display_items` |
| 6.5 | Keystrokes for each shortcut | Selection and tab count change as Chau7 does |
| 6.6 | Mouse down on tab 2, move past two tab centers, mouse up | Order matches `destination_index`; no lost or duplicated tab |
| 6.6 | Same drag, close a background tab mid-drag | Order consistent, no panic |
| 6.7 | Drag group bracket | Group tabs stay contiguous and move together |
| 6.8 | Dispatch each menu action | Model changes as expected; rename cancel restores title and colour |
| 6.9 | Hover a tab, advance 0.4 s | One prewarm, card shown; mouse out: one cancel, card hidden |
| 6.10 | Click chip, click entry | Entry's tab selected |
| 6.11 | Two windows, call the drop handler with a screen point inside window B's tab bar, then inside B's window but outside its tab bar, then outside all windows | Tab appended and selected in B for the first two; nothing moves for the third |

The 6.11 test checks the resolution logic only. The real cross-window mouse
behaviour is checked manually in 10.3.

### 10.3 Manual checklist on macOS (human, about 15 minutes)

Run the release build next to the installed Chau7 and tick each line. Agents
prepare this as a checklist in REPORT.md; a human fills it in.

- [ ] Installed Chau7 still works normally while the spike runs (6.13).
- [ ] Tab bar aligned with traffic lights on a Retina and a non-Retina display.
- [ ] Window drags from empty tab bar space; double-click on it follows the macOS setting.
- [ ] Fullscreen keeps the tab bar visible.
- [ ] Reorder feels at least as smooth as Chau7 (compare side by side).
- [ ] Pulse animation, dashed border, badge, suspended and broadcast states look right.
- [ ] Context menus are native (system look, can extend past the window edge).
- [ ] Hover card timing feels the same as Chau7.
- [ ] Drag a tab from window A onto window B's tab bar: it moves and is selected.
- [ ] Drag a group from window A onto window B: the whole group moves.
- [ ] Drag a tab and release outside both windows: nothing moves across windows.
- [ ] 30 tabs: scrolling and select-into-view work.

### 10.4 Go / no-go rule

- **Go**: 10.1 and 10.2 fully green locally and in all three CI jobs, 10.3 fully
  ticked on macOS, and 6.11 passes with either approach.
- **Go with caveats**: everything green except at most two partials outside 6.2,
  6.6 and 6.11, each with a written workaround estimate.
- **No-go**: 6.2, 6.6 or 6.11 fails, or more than two partials. Revisit egui using
  the same spec.
