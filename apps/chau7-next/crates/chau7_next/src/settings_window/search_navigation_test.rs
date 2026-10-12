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
        let mut settings = Settings::default();
        settings.appearance.font_size = 21.;
        settings.terminal.scrollback_lines = 12345;
        settings.terminal.restored_scrollback_lines = 1234;
        settings.proxy.port = 19090;
        settings.productivity.clipboard_history_enabled = false;
        settings.history.max_records = 8765;
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
        for _ in 0..5 {
            cx.background_executor
                .advance_clock(std::time::Duration::from_millis(250));
            cx.run_until_parked();
            anchors::take_rendered_targets();
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
    // Rapid changes cancel the older120ms retry, including a query cleared
    // before its target ever paints. Exercise actual subscribed input events.
    let retries_before = cx.update(|cx| view.read(cx).search_retry_attempts);
    for query in ["restored", "font"] {
        handle
            .update(cx, |_, window, cx| {
                input.update(cx, |input, cx| {
                    input.set_value(query, window, cx);
                    cx.emit(InputEvent::Change);
                })
            })
            .unwrap();
        cx.run_until_parked();
    }
    for _ in 0..5 {
        cx.background_executor
            .advance_clock(std::time::Duration::from_millis(250));
        cx.run_until_parked();
        anchors::take_rendered_targets();
        cx.update_window(handle, |_, window, cx| {
            window.render_frame(cx);
            window.simulate_next_frame(cx);
        })
        .unwrap();
        cx.run_until_parked();
    }
    cx.update(|cx| {
        let current = view.read(cx);
        assert_eq!(current.navigation.selection, SettingsSection::FontColors);
        assert_eq!(current.navigation.search_query, "font");
        assert_eq!(current.search_retry_attempts, retries_before + 1);
        assert_eq!(
            anchors::highlighted_targets(),
            std::collections::HashSet::from(["fontFamily"])
        );
    });
    let retries_before = cx.update(|cx| view.read(cx).search_retry_attempts);
    for query in ["cursor", ""] {
        handle
            .update(cx, |_, window, cx| {
                input.update(cx, |input, cx| {
                    input.set_value(query, window, cx);
                    cx.emit(InputEvent::Change);
                })
            })
            .unwrap();
        cx.run_until_parked();
    }
    for _ in 0..5 {
        cx.background_executor
            .advance_clock(std::time::Duration::from_millis(250));
        cx.run_until_parked();
        anchors::take_rendered_targets();
        cx.update_window(handle, |_, window, cx| {
            window.render_frame(cx);
            window.simulate_next_frame(cx);
        })
        .unwrap();
        cx.run_until_parked();
    }
    cx.update(|cx| {
        let current = view.read(cx);
        assert_eq!(current.navigation.selection, SettingsSection::Shell);
        assert!(current.navigation.search_query.is_empty());
        assert_eq!(current.search_retry_attempts, retries_before);
        assert!(current.search_animations_finished(cx.background_executor().now()));
        assert!(anchors::highlighted_targets().is_empty());
    });
    let swift = include_str!(concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../../../chau7-macos/Sources/Chau7/Settings/Views/SettingsPageSummaryView.swift"
    ));
    let ids = regex::Regex::new(r#"(?:statusItem|countItem)\(\s*"([^"]+)""#).unwrap();
    let mut card_count = 0;
    for section in SettingsSection::ALL {
        handle
            .update(cx, |_, window, cx| {
                input.update(cx, |input, cx| input.set_value("", window, cx));
                view.update(cx, |view, cx| {
                    view.navigation.search_query.clear();
                    view.select(section, window, cx);
                });
            })
            .unwrap();
        cx.run_until_parked();
        for _ in 0..5 {
            cx.background_executor
                .advance_clock(std::time::Duration::from_millis(250));
            cx.run_until_parked();
            anchors::take_rendered_targets();
            cx.update_window(handle, |_, window, cx| {
                window.render_frame(cx);
                window.simulate_next_frame(cx);
            })
            .unwrap();
            cx.run_until_parked();
        }
        let cards = summary::observed(section);
        let marker = format!("case .{}:", section.id());
        let body = swift
            .split_once(&marker)
            .expect("current Swift section")
            .1
            .split("\n        case .")
            .next()
            .unwrap();
        let mut expected: Vec<_> = ids
            .captures_iter(body)
            .map(|capture| capture[1].to_string())
            .collect();
        if section == SettingsSection::StartHere {
            expected.insert(2, "remote".to_owned());
        }
        assert_eq!(
            cards.iter().map(|(id, _)| *id).collect::<Vec<_>>(),
            expected,
            "current Swift summary card identities for {}",
            section.id()
        );
        assert!(cards.len() >= 4);
        card_count += cards.len();
        let value = |id| {
            cards
                .iter()
                .find(|(card, _)| *card == id)
                .unwrap()
                .1
                .clone()
        };
        match section {
            SettingsSection::FontColors => assert_eq!(value("size"), "21 pt"),
            SettingsSection::ScrollbackPerf => cx.update(|cx| {
                let formats = &view.read(cx).pane_inputs;
                assert_eq!(value("scrollback"), formats.format_summary_count(12345));
                assert_eq!(value("restored"), formats.format_summary_count(1234));
            }),
            SettingsSection::ApiProxy => assert_eq!(value("port"), "19090"),
            SettingsSection::SnippetsTools => assert_eq!(
                value("clipboard"),
                chau7_next_core::l10n::l("status.disabled", "Disabled")
            ),
            SettingsSection::SshProfiles => {
                assert_eq!(
                    value("watch"),
                    chau7_next_core::l10n::l("misc.loading", "Loading...")
                );
                assert_eq!(
                    value("lastSync"),
                    chau7_next_core::l10n::l("status.never", "Never")
                );
            }
            SettingsSection::History => cx.update(|cx| {
                assert_eq!(
                    value("maxRecords"),
                    view.read(cx).pane_inputs.format_summary_count(10000)
                );
            }),
            _ => {}
        }
    }
    assert_eq!(card_count, 114);
    handle
        .update(cx, |_, window, _| window.remove_window())
        .unwrap();
    drop(view);
    cx.update(crate::observability::shutdown);
    std::fs::remove_dir_all(home).unwrap();
}
