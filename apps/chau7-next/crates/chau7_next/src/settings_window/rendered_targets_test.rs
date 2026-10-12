use super::*;
use gpui::{AppContext, Bounds, TestAppContext, WindowBounds, WindowOptions, size};
use gpui_kit::test::TestWindowExt;

#[gpui::test]
fn actual_settings_pages_attach_every_current_search_target(harness: &mut TestAppContext) {
    let mut fixture = harness.new_app();
    let cx = &mut fixture;
    let home =
        std::env::temp_dir().join(format!("chau7-settings-targets-{}", uuid::Uuid::new_v4()));
    let root = DataRoot::with_home(home.clone(), true);
    root.ensure_dirs().unwrap();
    cx.update(|cx| {
        gpui_kit::init(cx);
        let mut settings = Settings::default();
        // Prefix and per-tab controls are intentionally conditional on CTO.
        // Enable only the in-memory fixture preference, without starting helpers.
        settings.cto.mode = chau7_next_core::token_optimization::TokenOptimizationMode::AiOnly;
        cx.set_global(AppData::new(root.clone()));
        cx.set_global(ConfigFiles::new(root.config_file(), settings.clone()));
        cx.set_global(settings);
        crate::observability::init_for_test(cx);
    });
    let (window, view) = cx.update(|cx| {
        gpui_kit::open_window(
            WindowOptions {
                window_bounds: Some(WindowBounds::Windowed(Bounds::new(
                    gpui::point(px(0.0), px(0.0)),
                    size(px(860.0), px(640.0)),
                ))),
                ..Default::default()
            },
            cx,
            |window, cx| cx.new(|cx| SettingsView::new_inner(window, cx, Some(String::new()))),
        )
        .unwrap()
    });
    let window = window.downcast::<gpui_kit::base::Root>().unwrap();
    let mut missing = Vec::new();
    for setting in SEARCHABLE_SETTINGS {
        anchors::take_rendered_targets();
        window
            .update(cx, |_, window, cx| {
                view.update(cx, |view, cx| {
                    view.navigation.search_query.clear();
                    view.focus_search_result(setting, window, cx);
                });
            })
            .unwrap();
        cx.update_window(window.into(), |_, window, cx| window.render_frame(cx))
            .unwrap();
        let observation_ids = anchors::observed_target_ids(setting.anchor_id);
        let rendered = anchors::take_rendered_targets();
        // GPUI's test platform has no OS frame loop. Deliver the two actual
        // next-frame callbacks: our section/layout barrier and ScrollAnchor.
        for _ in 0..2 {
            cx.update_window(window.into(), |_, window, cx| {
                window.simulate_next_frame(cx);
                window.render_frame(cx);
            })
            .unwrap();
        }
        let (offset, maximum, bounds, selection, target) = cx.update(|cx| {
            let settings = view.read(cx);
            (
                settings.scroll_handle.offset(),
                settings.scroll_handle.max_offset(),
                settings.scroll_handle.bounds(),
                settings.navigation.selection,
                settings.navigation.anchor_id.clone(),
            )
        });
        assert_eq!(selection, setting.section, "{}", setting.anchor_id);
        assert_eq!(target.as_deref(), Some(setting.anchor_id));
        assert!(
            bounds.size.height > px(0.0),
            "{}: missing viewport",
            setting.anchor_id
        );
        assert!(
            offset.y <= px(0.0),
            "{}: positive scroll offset",
            setting.anchor_id
        );
        assert!(
            offset.y >= -maximum.y,
            "{}: offset beyond content",
            setting.anchor_id
        );
        let visible = cx
            .update_window(window.into(), |_, window, _| {
                observation_ids
                    .iter()
                    .filter_map(|id| window.try_find(SharedString::from(id.clone())))
                    .any(|element| {
                        element.visible()
                            && element.bounds().bottom() > bounds.top()
                            && element.bounds().top() < bounds.bottom()
                    })
            })
            .unwrap();
        if !visible {
            missing.push(format!("{}:{} (target not visible after actual scroll callbacks; offset {:?}, maximum {:?})", setting.section.id(), setting.anchor_id, offset, maximum));
        }
        if !rendered.contains(setting.anchor_id) {
            missing.push(format!(
                "{}:{} ({})",
                setting.section.id(),
                setting.anchor_id,
                setting.title
            ));
        }
    }
    if let Some(worker) = cx.update(crate::observability::shutdown) {
        worker.join().unwrap();
    }
    // Finish queued projections while their globals are alive, then drop the
    // complete owned app to release SQLite handles before Windows cleanup.
    cx.run_until_parked();
    cx.quit();
    drop(view);
    cx.run_until_parked();
    drop(fixture);
    std::fs::remove_dir_all(home).unwrap();
    assert!(
        missing.is_empty(),
        "Current search controls without an actual rendered anchor: {}",
        missing.join(", ")
    );
}
