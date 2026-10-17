use super::*;
use crate::{pane::PaneTree, settings::Settings};
use chau7_next_core::{
    data_root::DataRoot,
    tabs_state::{TabColor, TabMeta},
};
use gpui::{AppContext, EntityId, TestAppContext, point, px};

fn init(harness: &mut TestAppContext) {
    let home = std::env::temp_dir().join(format!("chau7-tab-transfer-{}", uuid::Uuid::new_v4()));
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

fn seed_tab(workspace: &Entity<Workspace>, cx: &mut App) -> (TabId, EntityId, uuid::Uuid) {
    // Pure pane state: no PTY, providers, or user restoration files.
    let panes = cx.new(|_| PaneTree::empty_for_test());
    let pane_id = panes.entity_id();
    workspace.update(cx, |workspace, cx| {
        workspace.adopt_tab(TabMeta::new(0, TabColor::Blue), panes, true, cx);
        let id = workspace.state.selected().unwrap();
        (id, pane_id, workspace.state.get(id).unwrap().uuid)
    })
}

fn close_windows(cx: &mut App) {
    for (handle, _) in AppData::live(cx) {
        let _ = handle.update(cx, |_, window, _| window.remove_window());
    }
}

#[gpui::test]
fn horizontal_and_vertical_motion_cross_drag_threshold(harness: &mut TestAppContext) {
    init(harness);
    let workspace = harness.update(|cx| {
        let (_, workspace) = crate::open_window_for_transfer(cx).unwrap();
        let _ = seed_tab(&workspace, cx);
        workspace
    });
    let start = point(px(100.0), px(100.0));
    let threshold = f32::from(DRAG_THRESHOLD);
    let cases = [
        ("horizontal under", threshold - 1.0, 0.0, false),
        ("horizontal equal", threshold, 0.0, false),
        ("horizontal over", threshold + 1.0, 0.0, true),
        ("vertical under", 0.0, threshold - 1.0, false),
        ("vertical equal", 0.0, threshold, false),
        ("vertical over", 0.0, threshold + 1.0, true),
    ];

    harness.update(|cx| {
        let tab = workspace.read(cx).state.selected().unwrap();
        for (label, dx, dy, expected_active) in cases {
            workspace.update(cx, |workspace, cx| {
                workspace.begin_press(DragSubject::Tab(tab), start, cx);
                workspace.drag_move(point(px(100.0 + dx), px(100.0 + dy)), cx);
                assert_eq!(
                    workspace.drag.as_ref().unwrap().active,
                    expected_active,
                    "{label} displacement"
                );
            });
        }
        close_windows(cx);
    });
}

#[gpui::test]
fn invalid_or_source_destination_preserves_tabs(harness: &mut TestAppContext) {
    init(harness);
    harness.update(|cx| {
        let (_, source) = crate::open_window_for_transfer(cx).unwrap();
        let (id, pane_id, uuid) = seed_tab(&source, cx);
        for target in [Some(EntityId::from(u64::MAX)), Some(source.entity_id())] {
            move_tabs_to(source.clone(), vec![id], target, cx);
            let workspace = source.read(cx);
            assert_eq!(workspace.state.len(), 1);
            assert_eq!(workspace.state.get(id).unwrap().uuid, uuid);
            assert_eq!(
                workspace.entries.get(&id).unwrap().panes.entity_id(),
                pane_id
            );
            assert_eq!(
                cx.windows().len(),
                1,
                "invalid destinations must not create a window"
            );
        }
        close_windows(cx);
    });
}

#[gpui::test]
fn closed_destination_preserves_source_and_its_panes(harness: &mut TestAppContext) {
    init(harness);
    harness.update(|cx| {
        let (_, source) = crate::open_window_for_transfer(cx).unwrap();
        let (target_handle, target) = crate::open_window_for_transfer(cx).unwrap();
        let (id, pane_id, uuid) = seed_tab(&source, cx);
        target_handle
            .update(cx, |_, window, _| window.remove_window())
            .unwrap();
        // Keep the registered entity alive after its native window closes.
        // A retained entity must neither count as live nor accept a transfer.
        assert!(
            cx.global::<AppData>()
                .workspaces
                .iter()
                .any(|(_, workspace)| {
                    workspace
                        .upgrade()
                        .is_some_and(|workspace| workspace.entity_id() == target.entity_id())
                })
        );
        let live_ids: Vec<_> = AppData::live(cx)
            .into_iter()
            .map(|(_, workspace)| workspace.entity_id())
            .collect();
        assert_eq!(live_ids, [source.entity_id()]);
        assert!(target_handle.update(cx, |_, _, _| ()).is_err());
        move_tabs_to(source.clone(), vec![id], Some(target.entity_id()), cx);
        assert_eq!(source.read(cx).state.get(id).unwrap().uuid, uuid);
        assert_eq!(
            source.read(cx).entries.get(&id).unwrap().panes.entity_id(),
            pane_id
        );
        assert!(target.read(cx).state.is_empty());
        close_windows(cx);
    });
}

#[gpui::test]
fn successful_transfer_preserves_identity_and_closes_only_empty_source(
    harness: &mut TestAppContext,
) {
    init(harness);
    harness.update(|cx| {
        let (source_handle, source) = crate::open_window_for_transfer(cx).unwrap();
        let (_, target) = crate::open_window_for_transfer(cx).unwrap();
        let (id, pane_id, uuid) = seed_tab(&source, cx);
        move_tabs_to(source.clone(), vec![id], Some(target.entity_id()), cx);
        assert!(source.read(cx).state.is_empty());
        assert!(source_handle.update(cx, |_, _, _| ()).is_err());
        let workspace = target.read(cx);
        assert_eq!(workspace.state.len(), 1);
        let moved = &workspace.state.tabs()[0];
        assert_eq!(moved.uuid, uuid);
        assert_ne!(moved.id, id, "window-local numeric IDs are renewed");
        assert_eq!(
            workspace.entries.get(&moved.id).unwrap().panes.entity_id(),
            pane_id
        );
        close_windows(cx);
    });
}

#[gpui::test]
fn closing_an_earlier_window_does_not_redirect_a_stable_destination(harness: &mut TestAppContext) {
    init(harness);
    let (preceding_handle, preceding, source, target, following, id, pane_id, uuid, target_id) =
        harness.update(|cx| {
            let (preceding_handle, preceding) = crate::open_window_for_transfer(cx).unwrap();
            let (_, source) = crate::open_window_for_transfer(cx).unwrap();
            let (_, target) = crate::open_window_for_transfer(cx).unwrap();
            let (_, following) = crate::open_window_for_transfer(cx).unwrap();
            let (id, pane_id, uuid) = seed_tab(&source, cx);
            (
                preceding_handle,
                preceding,
                source,
                target.clone(),
                following,
                id,
                pane_id,
                uuid,
                target.entity_id(),
            )
        });

    harness.update(|cx| {
        preceding_handle
            .update(cx, |_, window, _| window.remove_window())
            .unwrap();
    });
    drop(preceding);
    harness.run_until_parked();

    harness.update(|cx| {
        let live_ids: Vec<_> = AppData::live(cx)
            .into_iter()
            .map(|(_, workspace)| workspace.entity_id())
            .collect();
        assert_eq!(
            live_ids,
            [source.entity_id(), target_id, following.entity_id()]
        );

        move_tabs_to(source.clone(), vec![id], Some(target_id), cx);

        assert!(source.read(cx).state.is_empty());
        let target_workspace = target.read(cx);
        assert_eq!(target_workspace.state.len(), 1);
        let moved = &target_workspace.state.tabs()[0];
        assert_eq!(moved.uuid, uuid);
        assert_eq!(
            target_workspace
                .entries
                .get(&moved.id)
                .unwrap()
                .panes
                .entity_id(),
            pane_id
        );
        assert!(following.read(cx).state.is_empty());
        close_windows(cx);
    });
}

#[gpui::test]
fn disappeared_stable_destination_cancels_instead_of_redirecting(harness: &mut TestAppContext) {
    init(harness);
    let (target_handle, target, source, following, id, pane_id, uuid, target_id) =
        harness.update(|cx| {
            let (target_handle, target) = crate::open_window_for_transfer(cx).unwrap();
            let (_, source) = crate::open_window_for_transfer(cx).unwrap();
            let (_, following) = crate::open_window_for_transfer(cx).unwrap();
            let (id, pane_id, uuid) = seed_tab(&source, cx);
            (
                target_handle,
                target.clone(),
                source,
                following,
                id,
                pane_id,
                uuid,
                target.entity_id(),
            )
        });

    harness.update(|cx| {
        target_handle
            .update(cx, |_, window, _| window.remove_window())
            .unwrap();
    });
    drop(target);
    harness.run_until_parked();

    harness.update(|cx| {
        assert!(
            AppData::live(cx)
                .into_iter()
                .all(|(_, workspace)| workspace.entity_id() != target_id)
        );
        move_tabs_to(source.clone(), vec![id], Some(target_id), cx);

        let source_workspace = source.read(cx);
        assert_eq!(source_workspace.state.get(id).unwrap().uuid, uuid);
        assert_eq!(
            source_workspace.entries.get(&id).unwrap().panes.entity_id(),
            pane_id
        );
        assert!(following.read(cx).state.is_empty());
        close_windows(cx);
    });
}

#[gpui::test]
fn new_window_transfer_prepares_destination_and_keeps_panes(harness: &mut TestAppContext) {
    init(harness);
    harness.update(|cx| {
        let (_, source) = crate::open_window_for_transfer(cx).unwrap();
        let (id, pane_id, uuid) = seed_tab(&source, cx);
        move_tabs_to(source.clone(), vec![id], None, cx);
        let (_, target) = AppData::live(cx)
            .into_iter()
            .find(|(_, workspace)| workspace.entity_id() != source.entity_id())
            .unwrap();
        let workspace = target.read(cx);
        assert_eq!(workspace.state.len(), 1);
        let moved = &workspace.state.tabs()[0];
        assert_eq!(moved.uuid, uuid);
        assert_eq!(
            workspace.entries.get(&moved.id).unwrap().panes.entity_id(),
            pane_id
        );
        close_windows(cx);
    });
}

#[gpui::test]
fn closing_windows_commits_remaining_tabs_and_clears_the_last_saved_window(
    harness: &mut TestAppContext,
) {
    init(harness);
    let (source_handle, source, target_handle, target, source_uuid) = harness.update(|cx| {
        crate::restore::writer::init(cx);
        let (source_handle, source) = crate::open_window_for_transfer(cx).unwrap();
        let (target_handle, target) = crate::open_window_for_transfer(cx).unwrap();
        let (_, _, source_uuid) = seed_tab(&source, cx);
        seed_tab(&target, cx);
        crate::save_session(cx, false);
        (source_handle, source, target_handle, target, source_uuid)
    });
    harness.update(|cx| {
        target_handle
            .update(cx, |_, window, _| window.remove_window())
            .unwrap();
        crate::save_after_terminal_window_close(cx);
        assert!(target.downgrade().upgrade().is_some());
    });
    let worker = harness.update(crate::restore::writer::shutdown).unwrap();
    assert_eq!(worker.join().unwrap().failed, 0);
    harness.update(|cx| {
        let root = &cx.global::<AppData>().root;
        let restored = crate::session_store::load(root).unwrap();
        assert_eq!(restored.windows.len(), 1);
        assert_eq!(restored.windows[0].tabs[0].uuid, Some(source_uuid));
        crate::restore::writer::init(cx);
        source_handle
            .update(cx, |_, window, _| window.remove_window())
            .unwrap();
        crate::save_after_terminal_window_close(cx);
        assert!(source.downgrade().upgrade().is_some());
    });
    let worker = harness.update(crate::restore::writer::shutdown).unwrap();
    assert_eq!(worker.join().unwrap().failed, 0);
    harness.update(|cx| {
        assert!(crate::session_store::load(&cx.global::<AppData>().root).is_none());
    });
}
