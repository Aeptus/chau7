//! Selection bookkeeping shared by every way the selected tab changes.

use super::*;
use crate::terminal::view::TerminalView;
use chau7_next_core::{
    data_root::DataRoot,
    tabs_state::{TabColor, TabMeta},
};
use gpui::{AppContext, TestAppContext};

fn init(harness: &mut TestAppContext) {
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
fn headless_tab(
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
