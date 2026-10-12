use super::*;
use gpui::{AppContext, TestAppContext};
use gpui_kit::test::TestWindowExt;

#[gpui::test]
fn real_search_change_centers_first_match_and_empty_retains_selection(
    harness: &mut TestAppContext,
) {
    let mut fixture = harness.new_app();
    let cx = &mut fixture;
    let home = std::env::temp_dir().join(format!("chau7-settings-query-{}", uuid::Uuid::new_v4()));
    let root = DataRoot::with_home(home.clone(), true);
    root.ensure_dirs().unwrap();
    cx.update(|cx| {
        gpui_kit::init(cx);
        let settings = Settings::default();
        cx.set_global(AppData::new(root.clone()));
        cx.set_global(ConfigFiles::new(root.config_file(), settings.clone()));
        cx.set_global(settings);
        crate::observability::init_for_test(cx);
    });
    let (handle, view) = cx.update(|cx| {
        gpui_kit::open_window(
            WindowOptions {
                window_bounds: Some(WindowBounds::Windowed(Bounds::new(
                    gpui::point(px(0.), px(0.)),
                    size(px(860.), px(640.)),
                ))),
                ..Default::default()
            },
            cx,
            |window, cx| cx.new(|cx| SettingsView::new_inner(window, cx, Some(String::new()))),
        )
        .unwrap()
    });
    let input = cx.update(|cx| view.read(cx).search_input.clone());
    for query in ["restored", "cursor", "no-such-current-setting-12345", ""] {
        anchors::take_rendered_targets();
        let previous = cx.update(|cx| view.read(cx).navigation.selection);
        handle
            .update(cx, |_, window, cx| {
                input.update(cx, |input, cx| {
                    input.set_value(query, window, cx);
                    cx.emit(InputEvent::Change);
                })
            })
            .unwrap();
        cx.run_until_parked();
        for _ in 0..3 {
            cx.update_window(handle, |_, window, cx| {
                window.render_frame(cx);
                window.simulate_next_frame(cx);
            })
            .unwrap();
            cx.run_until_parked();
        }
        cx.update(|cx| {
            let view = view.read(cx);
            assert_eq!(view.navigation.search_query, query);
            assert!(
                view.navigation.anchor_id.is_none(),
                "a derived first match must not become an explicit anchor"
            );
            let first = sections_matching(query)
                .first()
                .map(|(section, _)| *section);
            if query.is_empty() || first.is_none() {
                assert_eq!(view.navigation.selection, previous);
                assert!(view.active_search_anchor_id().is_none());
                assert!(anchors::highlighted_targets().is_empty());
            } else {
                assert_eq!(Some(view.navigation.selection), first);
                let expected = matching_settings(view.navigation.selection, query)[0].anchor_id;
                assert_eq!(view.active_search_anchor_id(), Some(expected));
                assert_eq!(
                    anchors::highlighted_targets(),
                    std::collections::HashSet::from([expected])
                );
                let target = view
                    .target_bounds
                    .get(expected)
                    .expect("actual target layout");
                let bounds = view.scroll_handle.bounds();
                let offset = view.scroll_handle.offset();
                let max = view.scroll_handle.max_offset();
                assert!(target.bottom() > bounds.top() && target.top() < bounds.bottom());
                assert!(offset.y >= -max.y && offset.y <= px(0.));
                if offset.y < px(0.) && offset.y > -max.y {
                    assert!(
                        (f32::from(target.center().y - bounds.center().y)).abs() < 2.,
                        "target is centered after actual callbacks"
                    );
                }
            }
        });
    }
    handle
        .update(cx, |_, window, _| window.remove_window())
        .unwrap();
    drop(view);
    cx.update(crate::observability::shutdown);
    std::fs::remove_dir_all(home).unwrap();
}
