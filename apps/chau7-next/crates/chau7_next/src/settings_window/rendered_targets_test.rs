use super::*;
use gpui::{AppContext, Bounds, TestAppContext, WindowBounds, WindowOptions, size};
use gpui_kit::test::TestWindowExt;

#[gpui::test]
fn actual_settings_pages_attach_every_current_search_target(cx: &mut TestAppContext) {
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
        crate::observability::init(cx);
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
        let rendered = anchors::take_rendered_targets();
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
    std::fs::remove_dir_all(home).unwrap();
    assert!(
        missing.is_empty(),
        "Current search controls without an actual rendered anchor: {}",
        missing.join(", ")
    );
}
