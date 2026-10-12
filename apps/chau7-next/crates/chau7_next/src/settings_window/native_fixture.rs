//! Acceptance in an owned native window. The opt-in runner validates and
//! initializes a freshly created isolated root before calling this fixture.
use super::*;
use anyhow::{Context as _, Result, ensure};
use gpui::{AppContext, AsyncApp};
use gpui_kit::test::TestWindowExt;
use serde_json::{Value, json};
use std::path::PathBuf;

pub(crate) async fn verify_native_fixture(cx: &mut AsyncApp) -> Result<Value, String> {
    verify(cx).await.map_err(|error| format!("{error:#}"))
}

async fn verify(cx: &mut AsyncApp) -> Result<Value> {
    let (handle, view) = cx.update(|cx| {
        let root = &cx.global::<AppData>().root;
        ensure!(
            chau7_next_core::data_root::is_isolated_test_mode(),
            "native settings fixture requires isolated test mode"
        );
        ensure!(
            std::env::var("CHAU7_NEXT_NATIVE_PARITY_FIXTURE").as_deref() == Ok("1"),
            "native settings fixture requires explicit opt-in"
        );
        ensure!(
            root.state_dir() == root.home().join(".chau7-next-state"),
            "native settings fixture requires an isolated state root"
        );
        ensure!(
            std::env::var_os(chau7_next_core::data_root::HOME_ROOT_ENV)
                .map(PathBuf::from)
                .as_deref()
                == Some(root.home()),
            "native settings root differs from the runner-owned home"
        );
        ensure!(
            root.home()
                .file_name()
                .and_then(|name| name.to_str())
                .is_some_and(|name| name.starts_with("chau7-native-fixture-")),
            "native settings fixture requires its owned temporary home"
        );
        let temporary = std::env::temp_dir()
            .canonicalize()
            .context("native fixture temporary parent missing")?;
        ensure!(
            root.home().parent() == Some(temporary.as_path()),
            "native settings fixture home is outside the process temporary directory"
        );
        ensure!(
            cx.windows().is_empty(),
            "native settings fixture must run before ordinary windows"
        );
        ensure!(
            cx.global::<ConfigFiles>().global_path() == root.config_file(),
            "native settings fixture config path differs from its owned root"
        );

        // These controls are conditional on CTO. Change only this fresh
        // fixture's in-memory values; no optimizer helper is initialized.
        cx.global_mut::<Settings>().cto.mode =
            chau7_next_core::token_optimization::TokenOptimizationMode::AiOnly;
        cx.global_mut::<ConfigFiles>().base.cto.mode =
            chau7_next_core::token_optimization::TokenOptimizationMode::AiOnly;
        let (window, view) = gpui_kit::open_window(
            WindowOptions {
                focus: false,
                window_bounds: Some(WindowBounds::Windowed(Bounds::new(
                    gpui::point(px(0.0), px(0.0)),
                    size(px(860.0), px(640.0)),
                ))),
                ..Default::default()
            },
            cx,
            // Use the actual SettingsView. The empty, explicit fixture key
            // avoids reading a saved provider secret from this constructor.
            |window, cx| cx.new(|cx| SettingsView::new_inner(window, cx, Some(String::new()))),
        )?;
        Ok::<_, anyhow::Error>((window, view))
    })?;

    let outcome = async {
        let mut evidence = Vec::new();
        for setting in SEARCHABLE_SETTINGS {
            anchors::take_rendered_targets();
            cx.update_window(handle, |_, window, cx| {
                view.update(cx, |view, cx| {
                    view.navigation.search_query.clear();
                    view.focus_search_result(setting, window, cx);
                });
            }).context("owned settings window disappeared during navigation")?;
            // Platform-delivered frames cover the layout barrier and the
            // ScrollAnchor callback. Never simulate or manually render frames.
            for _ in 0..3 {
                crate::native_parity_fixture::next_frame(handle, cx).await.map_err(anyhow::Error::msg)?;
            }
            let ids = anchors::observed_target_ids(setting.anchor_id);
            let rendered = anchors::take_rendered_targets();
            let (offset, maximum, bounds, section, anchor) = cx.update(|cx| {
                let settings = view.read(cx);
                (settings.scroll_handle.offset(), settings.scroll_handle.max_offset(),
                 settings.scroll_handle.bounds(), settings.navigation.selection,
                 settings.navigation.anchor_id.clone())
            });
            ensure!(section == setting.section && anchor.as_deref() == Some(setting.anchor_id), "native settings navigation mismatch: {}", setting.anchor_id);
            ensure!(rendered.contains(setting.anchor_id), "native settings target did not render: {}", setting.anchor_id);
            ensure!(bounds.size.height > px(0.0) && bounds.size.width > px(0.0) && offset.y <= px(0.0) && offset.y >= -maximum.y, "native settings viewport mismatch: {}", setting.anchor_id);
            let target_bounds = cx.update_window(handle, |_, window, _| ids.iter()
                .filter_map(|id| window.try_find(SharedString::from(id.clone())))
                .find_map(|element| {
                    let target = element.bounds();
                    (element.visible() && target.bottom() > bounds.top() && target.top() < bounds.bottom()
                        && target.right() > bounds.left() && target.left() < bounds.right()).then_some(target)
                })).context("owned settings window disappeared during visibility check")?;
            let target = target_bounds.with_context(|| format!("native settings target not visible: {} (offset {offset:?}, maximum {maximum:?}, viewport {bounds:?})", setting.anchor_id))?;
            evidence.push(json!({"id":setting.id,"anchor":setting.anchor_id,"section":setting.section.id(),
                "offset_y":f32::from(offset.y),"max_offset_y":f32::from(maximum.y),
                "viewport":{"x":f32::from(bounds.origin.x),"y":f32::from(bounds.origin.y),"width":f32::from(bounds.size.width),"height":f32::from(bounds.size.height)},
                "target":{"x":f32::from(target.origin.x),"y":f32::from(target.origin.y),"width":f32::from(target.size.width),"height":f32::from(target.size.height)}}));
        }
        let input = cx.update(|cx| view.read(cx).search_input.clone());
        let mut queries = Vec::new();
        // Exercise the actual InputState subscription. These are owned app
        // events, without OS keyboard input or a direct navigation shortcut.
        for query in ["restored", "cursor", "no-such-current-setting-12345", ""] {
            anchors::take_rendered_targets();
            let previous = cx.update(|cx| view.read(cx).navigation.selection);
            cx.update_window(handle, |_, window, cx| input.update(cx, |input, cx| {
                input.set_value(query, window, cx);
                cx.emit(InputEvent::Change);
            })).context("owned settings query window disappeared")?;
            for _ in 0..4 {
                crate::native_parity_fixture::next_frame(handle, cx).await.map_err(anyhow::Error::msg)?;
            }
            let (selection, explicit, active, target, viewport, offset, maximum) = cx.update(|cx| {
                let settings = view.read(cx);
                let active = settings.active_search_anchor_id();
                (settings.navigation.selection, settings.navigation.anchor_id.clone(), active,
                 active.and_then(|id| settings.target_bounds.get(id)), settings.scroll_handle.bounds(),
                 settings.scroll_handle.offset(), settings.scroll_handle.max_offset())
            });
            ensure!(explicit.is_none(), "automatic query created an explicit anchor: {query}");
            let first = sections_matching(query).first().map(|(section, _)| *section);
            if query.is_empty() || first.is_none() {
                ensure!(selection == previous && active.is_none(), "empty/unmatched query changed selection: {query}");
                ensure!(anchors::highlighted_targets().is_empty(), "empty/unmatched query retained highlight: {query}");
                queries.push(json!({"query":query,"section":selection.id(),"retained_selection":true,"active_anchor":null,"highlighted_targets":0}));
            } else {
                ensure!(Some(selection) == first, "automatic query did not select first matching section: {query}");
                let expected = matching_settings(selection, query)[0].anchor_id;
                ensure!(active == Some(expected), "automatic query did not derive first matching anchor: {query}");
                ensure!(anchors::highlighted_targets() == std::collections::HashSet::from([expected]), "actual first-match highlight did not prepaint: {query}");
                let target = target.context("first-match query has no actual layout")?;
                ensure!(target.bottom() > viewport.top() && target.top() < viewport.bottom(), "automatic query target is outside viewport: {query}");
                ensure!(offset.y >= -maximum.y && offset.y <= px(0.0), "automatic query offset is out of bounds: {query}");
                let center_error = f32::from(target.center().y - viewport.center().y).abs();
                let clamped = offset.y == px(0.0) || offset.y == -maximum.y;
                ensure!(clamped || center_error < 2.0, "automatic query was not centered: {query}: {center_error}");
                queries.push(json!({"query":query,"section":selection.id(),"active_anchor":expected,"derived_anchor":true,
                    "highlight_prepaint":true,"visible":true,"center_error_px":center_error,"clamped_to_content":clamped,
                    "offset_y":f32::from(offset.y),"max_offset_y":f32::from(maximum.y)}));
            }
        }
        Ok(json!({"case":"settings-search", "targets":SEARCHABLE_SETTINGS.len(), "visible_targets":evidence.len(), "target_evidence":evidence,
            "automatic_query_evidence":queries,"query_event_delivery":"production_InputState_Change","query_frames":4,"highlight_pixel_acceptance":false,
            "frame_delivery":"real_native_platform", "frames_per_target":3, "synthetic_frame_delivery":false,
            "keyboard_or_pointer_acceptance":false, "interface_language":chau7_next_core::l10n::current().code()}))
    }.await;

    // Close only the fixture's window, including on navigation/frame failure.
    let closed = cx.update_window(handle, |_, window, _| window.remove_window());
    drop(view);
    if let Err(error) = closed {
        return Err(anyhow::anyhow!(
            "owned settings window cleanup failed: {error}; verification: {outcome:?}"
        ));
    }
    outcome
}
