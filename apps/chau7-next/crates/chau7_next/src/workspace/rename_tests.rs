//! Rendered GPUI regressions for rename focus and title selection.

use super::Workspace;
use crate::{pane::PaneTree, settings::Settings, workspace::AppData};
use chau7_next_core::{
    data_root::DataRoot,
    tabs_state::{TabColor, TabMeta},
};
use gpui::{AnyWindowHandle, AppContext, Entity, Focusable, TestAppContext};
use gpui_kit::{component::input::InputState, test::TestWindowExt};

use crate::tab_bar::TabId;

struct RenameFixture {
    window: AnyWindowHandle,
    workspace: Entity<Workspace>,
    tab: TabId,
    input: Entity<InputState>,
    original_title: String,
    original_custom_title: Option<String>,
}

fn init(harness: &mut TestAppContext) -> std::path::PathBuf {
    let home = std::env::temp_dir().join(format!("chau7-rename-{}", uuid::Uuid::new_v4()));
    harness.update(|cx| {
        gpui_kit::init(cx);
        crate::actions::bind_keys(cx);
        let mut settings = Settings::default();
        settings.general.full_disk_access_guard_enabled = false;
        cx.set_global(settings);
        cx.set_global(AppData::new(DataRoot::with_home(home.clone(), true)));
        crate::terminal::command_guard::init(cx);
        crate::observability::init_for_test(cx);
    });
    home
}

fn open_fixture(
    harness: &mut TestAppContext,
    custom_title: Option<&str>,
    open_color_row: bool,
) -> RenameFixture {
    let (window, workspace, tab, original_title, original_custom_title) = harness.update(|cx| {
        let (window, workspace) = crate::open_window_for_transfer(cx).unwrap();
        let panes = cx.new(|_| PaneTree::empty_for_test());
        let mut meta = TabMeta::new(0, TabColor::Blue);
        meta.custom_title = custom_title.map(str::to_owned);
        let tab = workspace.update(cx, |workspace, cx| {
            workspace.adopt_tab(meta, panes, true, cx);
            workspace.state.selected().unwrap()
        });
        let original_title = workspace.read(cx).tab_title(tab, cx);
        let original_custom_title = workspace
            .read(cx)
            .state
            .get(tab)
            .unwrap()
            .custom_title
            .clone();
        (
            window,
            workspace,
            tab,
            original_title,
            original_custom_title,
        )
    });

    // Keep the type-erased handle and render through TestAppContext. Updating a
    // typed view handle while the entity is borrowed can re-enter its render.
    let input = if open_color_row {
        // A menu action is delivered to the active window's focused view. Let
        // activation settle, then focus the rendered Workspace before sending
        // the same action as the application menu.
        harness
            .update_window(window, |_, window, _| window.activate_window())
            .unwrap();
        harness.run_until_parked();
        harness
            .update_window(window, |_, window, cx| {
                window.render_frame(cx);
                let focus = workspace.read(cx).focus_handle(cx);
                window.focus(&focus, cx);
                window.render_frame(cx);
                assert!(
                    focus.is_focused(window),
                    "the rendered Workspace must own focus before menu action dispatch"
                );
                // Window::dispatch_action defers delivery until this update
                // finishes. Inspect the panel only after that effect runs.
                window.dispatch_action(Box::new(crate::actions::ShowTabColorPicker), cx);
            })
            .unwrap();
        harness.run_until_parked();
        harness
            .update_window(window, |_, window, cx| {
                window.render_frame(cx);
                workspace
                    .read(cx)
                    .rename
                    .as_ref()
                    .expect("Show Tab Color opens the rendered rename panel")
                    .input
                    .clone()
            })
            .unwrap()
    } else {
        harness
            .update_window(window, |_, window, cx| {
                window.render_frame(cx);
                workspace.update(cx, |workspace, cx| workspace.begin_rename(tab, window, cx));
                window.render_frame(cx);
                workspace
                    .read(cx)
                    .rename
                    .as_ref()
                    .expect("rendered rename panel is open")
                    .input
                    .clone()
            })
            .unwrap()
    };

    RenameFixture {
        window,
        workspace,
        tab,
        input,
        original_title,
        original_custom_title,
    }
}

fn rendered_input(
    harness: &mut TestAppContext,
    fixture: &RenameFixture,
) -> (Option<bool>, String, std::ops::Range<usize>) {
    harness
        .update_window(fixture.window, |_, window, cx| {
            window.render_frame(cx);
            let id = ("input", fixture.input.entity_id());
            let focused = window.find(id).focused();
            let input = fixture.input.read(cx);
            (focused, input.value().to_string(), input.selected_range())
        })
        .unwrap()
}

fn close_fixture(harness: &mut TestAppContext, fixture: RenameFixture) {
    let _ = harness.update_window(fixture.window, |_, window, _| window.remove_window());
    harness.run_until_parked();
}

#[gpui::test]
fn rendered_rename_selects_default_and_unicode_titles_once(harness: &mut TestAppContext) {
    let home = init(harness);
    for custom_title in [None, Some("文档 🦀 · résumé")] {
        let fixture = open_fixture(harness, custom_title, false);
        harness.run_until_parked();
        let color_row_context = harness
            .update_window(fixture.window, |_, window, cx| {
                window.render_frame(cx);
                window
                    .context_stack()
                    .iter()
                    .any(|context| context.contains("rename_color_focus"))
            })
            .unwrap();
        assert!(
            !color_row_context,
            "the title field keeps normal Root Tab routing"
        );

        let (focused, value, selected) = rendered_input(harness, &fixture);
        assert_eq!(focused, Some(true));
        assert_eq!(value, fixture.original_title);
        assert_eq!(selected, 0..fixture.original_title.len());

        harness
            .update_window(fixture.window, |_, window, cx| window.input("R", cx))
            .unwrap();
        let (focused, value, selected) = rendered_input(harness, &fixture);
        assert_eq!(focused, Some(true));
        assert_eq!(value, "R", "first key replaces the selected title");
        assert_eq!(selected, 1..1, "typing collapses selection to the caret");

        harness
            .update_window(fixture.window, |_, window, cx| window.input("!", cx))
            .unwrap();
        let (focused, value, selected) = rendered_input(harness, &fixture);
        assert_eq!(focused, Some(true));
        assert_eq!(
            value, "R!",
            "a later render must not select the title again"
        );
        assert_eq!(selected, 2..2);

        close_fixture(harness, fixture);
    }
    let _ = std::fs::remove_dir_all(home);
}

#[gpui::test]
fn cancelling_rendered_rename_keeps_the_original_unicode_title(harness: &mut TestAppContext) {
    let home = init(harness);
    let fixture = open_fixture(harness, Some("原文 🧭 notes"), false);
    harness.run_until_parked();

    harness
        .update_window(fixture.window, |_, window, cx| {
            window.input("temporary", cx);
            window.press("escape", cx);
        })
        .unwrap();

    let (is_open, custom_title) = harness.update(|cx| {
        let workspace = fixture.workspace.read(cx);
        (
            workspace.rename.is_some(),
            workspace
                .state
                .get(fixture.tab)
                .unwrap()
                .custom_title
                .clone(),
        )
    });
    assert!(!is_open, "Escape closes the rename panel");
    assert_eq!(custom_title, fixture.original_custom_title);
    close_fixture(harness, fixture);
    let _ = std::fs::remove_dir_all(home);
}

#[gpui::test]
fn tab_color_action_tab_focus_selects_the_entire_title(harness: &mut TestAppContext) {
    let home = init(harness);
    let fixture = open_fixture(harness, Some("色 🎨 / Project"), true);
    harness.run_until_parked();
    let color_row_context = harness
        .update_window(fixture.window, |_, window, cx| {
            window.render_frame(cx);
            window
                .context_stack()
                .iter()
                .any(|context| context.contains("rename_color_focus"))
        })
        .unwrap();
    assert!(
        color_row_context,
        "the scoped Tab override is active while the color row owns focus"
    );

    harness
        .update_window(fixture.window, |_, window, cx| window.press("tab", cx))
        .unwrap();

    let (focused, value, selected) = rendered_input(harness, &fixture);
    assert_eq!(focused, Some(true));
    assert_eq!(value, fixture.original_title);
    assert_eq!(selected, 0..fixture.original_title.len());
    assert!(!harness.update(|cx| {
        fixture
            .workspace
            .read(cx)
            .rename
            .as_ref()
            .unwrap()
            .color_focus
    }));

    close_fixture(harness, fixture);
    let _ = std::fs::remove_dir_all(home);
}

#[gpui::test]
fn clicking_title_from_tab_color_returns_arrow_keys_to_text_input(harness: &mut TestAppContext) {
    let home = init(harness);
    let fixture = open_fixture(harness, Some("色 🎨 / Project"), true);
    let input_id = ("input", fixture.input.entity_id());

    harness
        .update_window(fixture.window, |_, window, cx| {
            window.render_frame(cx);
            window.click(input_id, cx);
        })
        .unwrap();
    harness.run_until_parked();

    let color_before = harness
        .update_window(fixture.window, |_, window, cx| {
            window.render_frame(cx);
            assert_eq!(window.find(input_id).focused(), Some(true));
            let input = fixture.input.read(cx);
            let selected = input.selected_range();
            assert_eq!(selected.start, selected.end, "a click places a caret");

            let workspace = fixture.workspace.read(cx);
            let rename = workspace.rename.as_ref().unwrap();
            assert!(
                !rename.color_focus,
                "input focus leaves color keyboard mode"
            );
            rename.color
        })
        .unwrap();

    let (color_after, selected_after) = harness
        .update_window(fixture.window, |_, window, cx| {
            // Recreate a stale mode bit to exercise the Workspace focus guard
            // on a real key event that the Input deliberately propagates at
            // the start of its text.
            fixture.workspace.update(cx, |workspace, _| {
                workspace.rename.as_mut().unwrap().color_focus = true;
            });
            window.render_frame(cx);

            assert!(
                window
                    .context_stack()
                    .iter()
                    .all(|context| !context.contains("rename_color_focus")),
                "the focused title input does not activate the color-row key context"
            );
            fixture
                .input
                .update(cx, |input, cx| input.select_all(window, cx));
            window.press("left", cx);
            assert_eq!(fixture.input.read(cx).selected_range(), 0..0);
            window.press("left", cx);

            let workspace = fixture.workspace.read(cx);
            (
                workspace.rename.as_ref().unwrap().color,
                fixture.input.read(cx).selected_range(),
            )
        })
        .unwrap();

    let (focused, value, selected) = rendered_input(harness, &fixture);
    assert_eq!(focused, Some(true));
    assert_eq!(value, fixture.original_title);
    assert_eq!(
        selected,
        0..0,
        "Left collapses the title selection to its start"
    );
    assert_eq!(
        selected_after,
        0..0,
        "the second Left stays at the title boundary"
    );
    assert_eq!(
        color_after, color_before,
        "the title boundary does not change tab color"
    );

    close_fixture(harness, fixture);
    let _ = std::fs::remove_dir_all(home);
}
