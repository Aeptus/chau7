//! Selection bookkeeping shared by every way the selected tab changes.

use super::*;
use crate::terminal::view::TerminalView;
use chau7_next_core::{
    data_root::DataRoot,
    tabs_state::{TabColor, TabMeta},
};
use gpui::{AppContext, TestAppContext};
use gpui_kit::test::TestWindowExt;

pub(super) fn init(harness: &mut TestAppContext) {
    let home = std::env::temp_dir().join(format!("chau7-selection-{}", uuid::Uuid::new_v4()));
    harness.update(|cx| {
        gpui_kit::init(cx);
        let mut settings = Settings::default();
        settings.general.full_disk_access_guard_enabled = false;
        cx.set_global(settings);
        cx.set_global(AppData::new(DataRoot::with_home(home, true)));
        crate::terminal::command_guard::init(cx);
        crate::observability::init_for_test(cx);
    });
}

/// A tab whose one pane is a headless terminal (no shell process).
pub(super) fn headless_tab(
    handle: AnyWindowHandle,
    workspace: &Entity<Workspace>,
    cx: &mut App,
) -> (TabId, Entity<TerminalView>) {
    handle
        .update(cx, |_, window, cx| {
            let panes = cx.new(|cx| PaneTree::headless_for_test(1, window, cx));
            let view = panes.read(cx).views()[0].clone();
            workspace.update(cx, |workspace, cx| {
                workspace.adopt_tab(TabMeta::new(0, TabColor::Blue), panes, true, cx);
                (workspace.state.selected().unwrap(), view)
            })
        })
        .unwrap()
}

fn has_focus(handle: AnyWindowHandle, view: &Entity<TerminalView>, cx: &mut App) -> bool {
    handle
        .update(cx, |_, window, cx| {
            view.read(cx).focus_handle(cx).is_focused(window)
        })
        .unwrap()
}

fn close_windows(cx: &mut App) {
    for (handle, _) in AppData::live(cx) {
        let _ = handle.update(cx, |_, window, _| window.remove_window());
    }
}

/// Moving the selected tab out leaves the source window's new selection
/// with the keyboard and its notification style cleared.
#[gpui::test]
fn moving_the_selected_tab_out_focuses_the_next_one(harness: &mut TestAppContext) {
    init(harness);
    harness.update(|cx| {
        let (source_handle, source) = crate::open_window_for_transfer(cx).unwrap();
        let (_, target) = crate::open_window_for_transfer(cx).unwrap();
        let (first, first_view) = headless_tab(source_handle, &source, cx);
        let (second, second_view) = headless_tab(source_handle, &source, cx);
        source.update(cx, |workspace, _| {
            workspace.entries.get_mut(&first).unwrap().notification =
                Some(NotificationStyle::attention());
        });
        source_handle
            .update(cx, |_, window, cx| {
                let handle = second_view.read(cx).focus_handle(cx);
                window.focus(&handle, cx);
            })
            .unwrap();
        assert!(!has_focus(source_handle, &first_view, cx));
        move_drag_target(source.clone(), second, target.entity_id(), cx);
        let workspace = source.read(cx);
        assert_eq!(workspace.state.selected(), Some(first));
        assert_eq!(workspace.entries.get(&first).unwrap().notification, None);
        assert!(has_focus(source_handle, &first_view, cx));
        close_windows(cx);
    });
}

fn move_drag_target(source: Entity<Workspace>, id: TabId, target: gpui::EntityId, cx: &mut App) {
    super::drag::move_tabs_to(source, vec![id], Some(target), cx);
}

/// Closing the selected tab gives the tab selected in its place the same
/// treatment as clicking it.
#[gpui::test]
fn closing_the_selected_tab_runs_the_selection_steps(harness: &mut TestAppContext) {
    init(harness);
    harness.update(|cx| {
        let (handle, workspace) = crate::open_window_for_transfer(cx).unwrap();
        let (first, first_view) = headless_tab(handle, &workspace, cx);
        let (second, _) = headless_tab(handle, &workspace, cx);
        workspace.update(cx, |workspace, _| {
            workspace.entries.get_mut(&first).unwrap().notification =
                Some(NotificationStyle::attention());
            workspace
                .last_bell
                .insert(second, std::time::Instant::now());
            workspace.broadcast_excluded.insert(second);
        });
        handle
            .update(cx, |_, window, cx| {
                workspace.update(cx, |workspace, cx| {
                    workspace.close_tab(second, false, window, cx)
                })
            })
            .unwrap();
        let state = workspace.read(cx);
        assert_eq!(state.state.selected(), Some(first));
        assert_eq!(state.entries.get(&first).unwrap().notification, None);
        assert!(!state.last_bell.contains_key(&second));
        assert!(!state.broadcast_excluded.contains(&second));
        assert!(has_focus(handle, &first_view, cx));
        close_windows(cx);
    });
}

/// Next/Previous Tab and Cmd+N go through `select_tab` with the selection
/// unchanged, so the switch slide starts.
#[gpui::test]
fn keyboard_tab_switches_animate(harness: &mut TestAppContext) {
    init(harness);
    harness.update(|cx| {
        let (handle, workspace) = crate::open_window_for_transfer(cx).unwrap();
        let (first, _) = headless_tab(handle, &workspace, cx);
        let (second, _) = headless_tab(handle, &workspace, cx);
        let animates = !crate::platform::system::reduce_motion();
        workspace.update(cx, |workspace, _| {
            workspace.state.select(first);
        });
        for (step, expected) in [(Some(1), second), (Some(-1), first), (None, second)] {
            handle
                .update(cx, |_, window, cx| {
                    workspace.update(cx, |workspace, cx| {
                        workspace.switch_anim = TabAnimations::default();
                        match step {
                            Some(delta) => workspace.select_relative(delta, window, cx),
                            None => workspace.select_number(2, window, cx),
                        }
                        assert_eq!(workspace.state.selected(), Some(expected));
                        assert_eq!(workspace.switch_anim.offset(0) != 0.0, animates);
                    })
                })
                .unwrap();
        }
        close_windows(cx);
    });
}

/// Tabs that end outside `close_tab` (last tab replaced, window closed)
/// still drop their per-tab window state.
#[gpui::test]
fn forgetting_a_tab_drops_its_window_state(harness: &mut TestAppContext) {
    init(harness);
    harness.update(|cx| {
        let (handle, workspace) = crate::open_window_for_transfer(cx).unwrap();
        let (id, _) = headless_tab(handle, &workspace, cx);
        workspace.update(cx, |workspace, _| {
            workspace.last_bell.insert(id, std::time::Instant::now());
            workspace.broadcast_excluded.insert(id);
            workspace.forget_tab(id);
            assert!(workspace.last_bell.is_empty());
            assert!(workspace.broadcast_excluded.is_empty());
        });
        close_windows(cx);
    });
}

/// The clock must move tabs into the idle group at the threshold, while a
/// static shell with no visible age labels must not continuously repaint.
#[gpui::test]
fn clock_redraw_preserves_idle_transitions_and_visible_ages(harness: &mut TestAppContext) {
    init(harness);
    harness.update(|cx| {
        let (handle, workspace) = crate::open_window_for_transfer(cx).unwrap();
        let (first, _) = headless_tab(handle, &workspace, cx);
        headless_tab(handle, &workspace, cx);
        workspace.update(cx, |workspace, cx| {
            workspace.state.group_idle_tabs = true;
            workspace.state.idle_threshold_secs = 10.0;
            workspace.state.get_mut(first).unwrap().last_activity = 0.0;
            assert!(!workspace.clock_redraw_needed(2.0, 3.0, cx));
            assert!(workspace.clock_redraw_needed(10.0, 11.0, cx));
            assert!(!workspace.clock_redraw_needed(11.0, 12.0, cx));
            workspace.idle_open = true;
            assert!(workspace.clock_redraw_needed(12.0, 13.0, cx));
        });
        close_windows(cx);
    });
}

/// Background output keeps timestamps and revives idle tabs, but repeated
/// output must not repaint an otherwise static workspace.
#[gpui::test]
fn hidden_activity_preserves_idle_revival_without_continuous_redraw(harness: &mut TestAppContext) {
    init(harness);
    harness.update(|cx| {
        let (handle, workspace) = crate::open_window_for_transfer(cx).unwrap();
        let (hidden, _) = headless_tab(handle, &workspace, cx);
        let (selected, _) = headless_tab(handle, &workspace, cx);
        workspace.update(cx, |workspace, _| {
            workspace.state.group_idle_tabs = true;
            workspace.state.idle_threshold_secs = 10.0;
            workspace.state.get_mut(hidden).unwrap().last_activity = 0.0;
            assert!(!workspace.record_tab_activity(hidden, 2.0));
            assert_eq!(workspace.state.get(hidden).unwrap().last_activity, 2.0);
            assert!(!workspace.record_tab_activity(hidden, 3.0));
            assert!(workspace.state.idle_ids(14.0).contains(&hidden));
            assert!(workspace.record_tab_activity(hidden, 14.0));
            assert!(!workspace.state.idle_ids(14.0).contains(&hidden));
            assert!(!workspace.record_tab_activity(hidden, 15.0));
            workspace.state.force_idle(hidden);
            assert!(workspace.record_tab_activity(hidden, 16.0));
            assert!(!workspace.state.idle_ids(16.0).contains(&hidden));
            workspace.idle_open = true;
            assert!(workspace.record_tab_activity(hidden, 17.0));
            assert!(!workspace.record_tab_activity(selected, 17.0));
            workspace.idle_open = false;
            workspace.state.group_idle_tabs = false;
            assert!(!workspace.record_tab_activity(hidden, 100.0));
        });
        close_windows(cx);
    });
}

/// Exercise the public frame-demand contract in the app's supported test
/// target; the registry package's full upstream test target needs absent assets.
#[gpui::test]
fn parked_frames_resume_for_presentations_and_nested_callbacks(cx: &mut TestAppContext) {
    use gpui::RequestFrameOptions;
    use std::cell::Cell;

    let window = cx.add_window(|_, _| gpui::Empty);
    let platform = cx.test_window(window.into());
    platform.simulate_frame_request(RequestFrameOptions::default());
    let idle = platform.frame_wake_count();
    platform.simulate_frame_request(RequestFrameOptions::default());
    assert_eq!(platform.frame_wake_count(), idle);

    // High-rate input / compositor presentation must keep a demand-driven
    // platform alive even when the scene itself is already clean.
    platform.simulate_frame_request(RequestFrameOptions {
        require_presentation: true,
        ..Default::default()
    });
    assert!(platform.frame_wake_count() > idle);
    platform.simulate_frame_request(RequestFrameOptions::default());
    let idle = platform.frame_wake_count();
    platform.simulate_frame_request(RequestFrameOptions::default());
    assert_eq!(platform.frame_wake_count(), idle);

    let nested_ran = Rc::new(Cell::new(false));
    window
        .update(cx, {
            let nested_ran = nested_ran.clone();
            move |_, window, _| {
                window.on_next_frame(move |window, _| {
                    window.on_next_frame(move |_, _| nested_ran.set(true));
                })
            }
        })
        .unwrap();
    assert!(platform.frame_wake_count() > idle);
    let pending = platform.frame_wake_count();
    platform.simulate_frame_request(RequestFrameOptions {
        require_presentation: true,
        ..Default::default()
    });
    assert!(!nested_ran.get());
    assert!(platform.frame_wake_count() > pending);
    platform.simulate_frame_request(RequestFrameOptions {
        require_presentation: true,
        ..Default::default()
    });
    assert!(nested_ran.get());
}

/// Hidden output keeps the model current without invalidating an invisible
/// terminal view. Selection and hover prewarming still deliver visual changes.
#[gpui::test]
fn hidden_terminal_updates_do_not_notify_the_view_until_revealed(harness: &mut TestAppContext) {
    use std::cell::Cell;

    init(harness);
    let (handle, workspace, hidden, selected, view, session) = harness.update(|cx| {
        cx.global_mut::<Settings>().tabs.close_on_exit = false;
        let (handle, workspace) = crate::open_window_for_transfer(cx).unwrap();
        let (hidden, view) = headless_tab(handle, &workspace, cx);
        let (selected, selected_view) = headless_tab(handle, &workspace, cx);
        // Headless terminals have no PTY: their first refresh emits Exited.
        // Drain that real metadata transition before testing output-only work.
        for view in [&view, &selected_view] {
            let session = view.read(cx).session.clone();
            session.update(cx, |session, cx| session.refresh(cx));
        }
        handle
            .update(cx, |_, window, cx| {
                workspace.update(cx, |workspace, cx| {
                    workspace.select_tab(selected, window, cx);
                    workspace.sync_restore_surfaces(window, cx);
                    workspace.record_tab_activity(hidden, AppData::now(cx));
                });
            })
            .unwrap();
        let session = view.read(cx).session.clone();
        assert!(!session.read(cx).restore_surface_visible());
        (handle, workspace, hidden, selected, view, session)
    });
    harness.run_until_parked();
    let platform = harness.test_window(handle);
    platform.simulate_frame_request(gpui::RequestFrameOptions::default());
    harness.run_until_parked();
    // Initial layout/focus notifications belong to fixture setup, not output.
    let notifications = Rc::new(Cell::new(0));
    let _observer = harness.update(|cx| {
        let notifications = notifications.clone();
        cx.observe(&view, move |_, _| {
            notifications.set(notifications.get() + 1)
        })
    });
    harness.update(|cx| {
        assert_eq!(workspace.read(cx).state.selected(), Some(selected));
        assert!(!session.read(cx).restore_surface_visible());
        assert!(session.read(cx).surface_prewarm_remaining().is_none());
        assert!(session.read(cx).exited.is_some());
    });
    let wakes = platform.frame_wake_count();
    // Drive the same session refresh and Output event as the real PTY worker.
    harness.update(|cx| {
        session.update(cx, |session, cx| {
            session.with_terminal(|terminal| terminal.inject_output(b"fresh hidden output"));
            session.refresh(cx);
        })
    });
    harness.run_until_parked();
    assert_eq!(
        notifications.get(),
        0,
        "hidden output must not invalidate its view"
    );
    assert_eq!(
        platform.frame_wake_count(),
        wakes,
        "implicit session reads in the tab bar must not wake the window either"
    );
    harness.update(|cx| {
        assert!(
            session
                .read(cx)
                .with_terminal(|terminal| terminal.full_buffer_ansi_text())
                .contains("fresh hidden output")
        );
        handle
            .update(cx, |_, window, cx| {
                workspace.update(cx, |workspace, cx| workspace.select_tab(hidden, window, cx));
            })
            .unwrap();
        assert!(session.read(cx).restore_surface_visible());
        assert!(
            session
                .read(cx)
                .grid
                .cells
                .iter()
                .map(|cell| cell.character)
                .collect::<String>()
                .contains("fresh hidden output")
        );
        handle
            .update(cx, |_, window, cx| window.render_frame(cx))
            .unwrap();
    });
    harness.run_until_parked();
    assert!(
        notifications.get() > 0,
        "selection must explicitly reveal the fresh surface"
    );
    let before = notifications.get();
    harness.update(|cx| {
        session.update(cx, |session, cx| {
            session.with_terminal(|terminal| terminal.inject_output(b" visible"));
            session.refresh(cx);
        })
    });
    harness.run_until_parked();
    assert!(
        notifications.get() > before,
        "visible output must invalidate the view"
    );

    // A hidden hover preview is an intentional, temporary presentation surface.
    harness.update(|cx| {
        handle
            .update(cx, |_, window, cx| {
                workspace.update(cx, |workspace, cx| {
                    workspace.select_tab(selected, window, cx)
                });
            })
            .unwrap();
        assert!(!session.read(cx).restore_surface_visible());
        session.update(cx, |session, cx| session.prewarm_surface(true, cx));
    });
    harness.run_until_parked();
    let before = notifications.get();
    harness.update(|cx| session.update(cx, |_, cx| cx.notify()));
    harness.run_until_parked();
    assert!(
        notifications.get() > before,
        "hover prewarming must still notify"
    );
    // Metadata must still reach a hidden tab's chrome immediately.
    harness.update(|cx| {
        session.update(cx, |session, cx| {
            session.prewarm_surface(false, cx);
            session.with_terminal(|terminal| {
                terminal.inject_output(b"\x1b]2;hidden title\x07");
                // The production PTY worker drains parser events before refresh.
                let _ = terminal.poll(0);
            });
            session.refresh(cx);
        })
    });
    harness.run_until_parked();
    harness.update(|cx| {
        assert_eq!(session.read(cx).title.as_deref(), Some("hidden title"));
        close_windows(cx);
    });
}
