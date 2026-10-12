use super::*;
use crate::settings_window::{SettingsSection, SettingsView};
use crate::workspace::AppData;
use chau7_next_core::data_root::DataRoot;
use gpui::{AppContext, Bounds, TestAppContext, WindowBounds, WindowOptions, size};
use gpui_kit::test::TestWindowExt;

#[gpui::test]
fn actual_scrollback_input_preserves_drafts_and_commits_owned_settings(
    harness: &mut TestAppContext,
) {
    let mut fixture = harness.new_app();
    let cx = &mut fixture;
    let home =
        std::env::temp_dir().join(format!("chau7-scrollback-entry-{}", uuid::Uuid::new_v4()));
    let root = DataRoot::with_home(home.clone(), true);
    root.ensure_dirs().unwrap();
    cx.update(|cx| {
        gpui_kit::init(cx);
        let mut settings = Settings::default();
        settings.input.copy_on_select = false;
        settings.terminal.restored_scrollback_lines = 333;
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
    let input = cx.update(|cx| view.read(cx).pane_inputs.scrollback.clone());
    window
        .update(cx, |_, _, cx| {
            view.update(cx, |view, _| {
                view.navigation.selection = SettingsSection::ScrollbackPerf
            })
        })
        .unwrap();
    cx.update_window(window.into(), |_, window, cx| window.render_frame(cx))
        .unwrap();

    // Exercise the real InputState event subscription in an owned GPUI window.
    window
        .update(cx, |_, window, cx| {
            input.update(cx, |state, cx| {
                state.focus(window, cx);
                cx.emit(InputEvent::Focus);
            })
        })
        .unwrap();
    cx.run_until_parked();
    for text in ["3", "33", "333"] {
        window
            .update(cx, |_, window, cx| {
                input.update(cx, |state, cx| {
                    state.set_value(text, window, cx);
                    cx.emit(InputEvent::Change);
                })
            })
            .unwrap();
        cx.run_until_parked();
        cx.update_window(window.into(), |_, window, cx| window.render_frame(cx))
            .unwrap();
        cx.update(|cx| {
            assert_eq!(input.read(cx).value().as_str(), text);
            assert_eq!(Settings::get(cx).terminal.scrollback_lines, 10_000);
        });
    }
    window
        .update(cx, |_, _, cx| {
            input.update(cx, |_, cx| {
                cx.emit(InputEvent::PressEnter {
                    secondary: false,
                    shift: false,
                })
            })
        })
        .unwrap();
    cx.run_until_parked();
    cx.update(|cx| {
        assert_eq!(Settings::get(cx).terminal.scrollback_lines, 333);
        assert_eq!(Settings::load(&root).terminal.scrollback_lines, 333);
        assert!(!Settings::get(cx).input.copy_on_select);
        assert_eq!(Settings::get(cx).terminal.restored_scrollback_lines, 333);
    });

    for (text, expected) in [
        ("99", 100),
        ("100001", 100_000),
        ("+", 100_000),
        ("13.5", 100_000),
        ("99999999999999999999999999999999999999999999", 100_000),
    ] {
        window
            .update(cx, |_, window, cx| {
                input.update(cx, |state, cx| {
                    state.set_value(text, window, cx);
                    cx.emit(InputEvent::Change);
                    cx.emit(InputEvent::Blur);
                })
            })
            .unwrap();
        cx.run_until_parked();
        cx.update(|cx| {
            assert_eq!(
                Settings::get(cx).terminal.scrollback_lines,
                expected,
                "{text}"
            );
            assert_eq!(input.read(cx).value().as_str(), expected.to_string());
        });
    }

    window
        .update(cx, |_, window, cx| {
            input.update(cx, |state, cx| {
                cx.emit(InputEvent::Focus);
                state.set_value("777", window, cx);
                cx.emit(InputEvent::Change);
            })
        })
        .unwrap();
    cx.run_until_parked();
    cx.update(|cx| {
        super::super::update(cx, |settings| settings.terminal.set_scrollback_lines(2500));
    });
    cx.update_window(window.into(), |_, window, cx| window.render_frame(cx))
        .unwrap();
    cx.update(|cx| assert_eq!(input.read(cx).value().as_str(), "777"));
    window
        .update(cx, |_, _, cx| {
            input.update(cx, |_, cx| cx.emit(InputEvent::Blur))
        })
        .unwrap();
    cx.run_until_parked();
    cx.update(|cx| {
        assert_eq!(Settings::get(cx).terminal.scrollback_lines, 2500);
        assert_eq!(input.read(cx).value().as_str(), "2500");
        assert!(!Settings::get(cx).input.copy_on_select);
        assert_eq!(Settings::get(cx).terminal.restored_scrollback_lines, 333);
    });

    // An unedited, unfocused field refreshes to the latest setting on focus.
    cx.update(|cx| {
        super::super::update(cx, |settings| settings.terminal.set_scrollback_lines(3000))
    });
    window
        .update(cx, |_, _, cx| {
            input.update(cx, |_, cx| cx.emit(InputEvent::Focus))
        })
        .unwrap();
    cx.run_until_parked();
    cx.update(|cx| assert_eq!(input.read(cx).value().as_str(), "3000"));

    assert!(cx.update(crate::observability::shutdown).is_none());
    cx.run_until_parked();
    cx.quit();
    drop(view);
    drop(input);
    cx.run_until_parked();
    drop(fixture);
    std::fs::remove_dir_all(home).unwrap();
}
