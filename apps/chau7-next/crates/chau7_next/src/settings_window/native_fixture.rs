//! Acceptance in an owned native window. The opt-in runner validates and
//! initializes a freshly created isolated root before calling this fixture.
use super::*;
use anyhow::{Context as _, Result, ensure};
use gpui::{AppContext, AsyncApp};
use gpui_kit::test::TestWindowExt;
use serde_json::{Value, json};
use std::{
    path::PathBuf,
    time::{Duration, Instant},
};

pub(crate) async fn verify_native_fixture(cx: &mut AsyncApp) -> Result<Value, String> {
    verify(cx).await.map_err(|error| format!("{error:#}"))
}

// Await production easing/retry on real platform frames, then capture one
// final painted layout. No animation is disabled or manually advanced here.
async fn settled_frame(
    handle: gpui::AnyWindowHandle,
    view: &Entity<SettingsView>,
    cx: &mut AsyncApp,
) -> Result<usize> {
    let started = Instant::now();
    let mut frames = 0;
    loop {
        crate::native_parity_fixture::next_frame(handle, cx)
            .await
            .map_err(anyhow::Error::msg)?;
        frames += 1;
        let settled = cx.update(|cx| {
            view.read(cx)
                .search_animations_finished(cx.background_executor().now())
        });
        if settled && frames >= 3 {
            break;
        }
        if started.elapsed() >= Duration::from_millis(500) {
            let state = cx.update(|cx| {
                let view = view.read(cx);
                let now = cx.background_executor().now();
                json!({
                    "anchor": view.navigation.anchor_id,
                    "scroll_motion_pending": view.search_scroll_motion.is_some(),
                    "scroll_motion_finished": view.search_scroll_motion.as_ref().map(|motion| motion.finished(now)),
                    "retry_pending": view.search_retry_pending,
                    "highlight_finished": view.search_highlights.finished(now),
                    "elapsed_microseconds": started.elapsed().as_micros(),
                    "actual_frames": frames,
                })
            });
            let renderer = cx
                .update_window(handle, |_, window, _| {
                    window.renderer_diagnostics().map(|renderer| {
                        json!({
                            "backend": renderer.backend,
                            "submitted_frames": renderer.submitted_frames,
                            "failed_frames": renderer.failed_frames,
                            "last_cpu_submit_microseconds": renderer.last_cpu_submit_microseconds,
                            "last_primitive_counts": renderer.last_primitive_counts,
                            "software_image_pixel_bytes": renderer.software_image_pixel_bytes,
                        })
                    })
                })
                .context("owned settings window disappeared during failure diagnosis")?;
            anyhow::bail!(
                "native settings animation failed to settle within 500ms after {frames} actual frames; state={state}; renderer={renderer:?}"
            );
        }
    }
    anchors::take_rendered_targets();
    cx.update(|cx| view.update(cx, |_, cx| cx.notify()));
    crate::native_parity_fixture::next_frame(handle, cx)
        .await
        .map_err(anyhow::Error::msg)?;
    Ok(frames + 1)
}

async fn verify(cx: &mut AsyncApp) -> Result<Value> {
    let (handle, view, locale) = cx.update(|cx| {
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

        let requested = std::env::var(native_locale::LANGUAGE_ENV).unwrap_or_else(|_| "en".into());
        let locale = native_locale::LocaleCase::new(
            &requested,
            crate::platform::system::preferred_languages(),
        )
        .map_err(anyhow::Error::msg)?;
        // Only this guarded fixture's in-memory settings change. System Default
        // uses the actual read-only OS preferences, never an OS locale override.
        cx.global_mut::<Settings>().general.app_language = locale.setting;
        cx.global_mut::<ConfigFiles>().base.general.app_language = locale.setting;
        crate::l10n::apply_setting(locale.setting);
        ensure!(
            chau7_next_core::l10n::current() == locale.resolved,
            "actual language resolution differs from fixture expectation"
        );
        ensure!(
            crate::l10n::is_rtl() == locale.resolved.is_rtl(),
            "actual layout direction differs from resolved language"
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
        Ok::<_, anyhow::Error>((window, view, locale))
    })?;

    let outcome = async {
        let mut evidence = Vec::new();
        for setting in SEARCHABLE_SETTINGS {
            anchors::take_rendered_targets();
            let retries_before = cx.update(|cx|view.read(cx).search_retry_attempts);
            cx.update_window(handle, |_, window, cx| {
                view.update(cx, |view, cx| {
                    view.navigation.search_query.clear();
                    view.focus_search_result(setting, window, cx);
                });
            }).context("owned settings window disappeared during navigation")?;
            let animation_frames = settled_frame(handle,&view,cx).await?;
            let retries = cx.update(|cx|view.read(cx).search_retry_attempts - retries_before);
            ensure!(retries == 1, "native target must execute exactly one current120ms retry: {}",setting.anchor_id);
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
            let sidebar = cx.update_window(handle, |_, window, _| window.try_find("settings-sidebar")
                .filter(|element| element.visible()).map(|element|element.bounds()))
                .context("owned window disappeared during direction check")?
                .context("native Settings sidebar is not visible")?;
            let actual_rtl = locale.resolved.is_rtl();
            ensure!(if actual_rtl { sidebar.left() >= bounds.right() - px(1.) }
                else { sidebar.right() <= bounds.left() + px(1.) },
                "native Settings sidebar is on the wrong side for {}: sidebar {sidebar:?}, viewport {bounds:?}",locale.resolved.code());
            let target = target_bounds.with_context(|| format!("native settings target not visible: {} (offset {offset:?}, maximum {maximum:?}, viewport {bounds:?})", setting.anchor_id))?;
            evidence.push(json!({"animation_frames":animation_frames,"retry_attempts":retries,"sidebar_on_expected_side":true,"rtl":actual_rtl,"sidebar_x":f32::from(sidebar.origin.x),"sidebar_width":f32::from(sidebar.size.width),"id":setting.id,"anchor":setting.anchor_id,"section":setting.section.id(),
                "offset_y":f32::from(offset.y),"max_offset_y":f32::from(maximum.y),
                "viewport":{"x":f32::from(bounds.origin.x),"y":f32::from(bounds.origin.y),"width":f32::from(bounds.size.width),"height":f32::from(bounds.size.height)},
                "target":{"x":f32::from(target.origin.x),"y":f32::from(target.origin.y),"width":f32::from(target.size.width),"height":f32::from(target.size.height)}}));
        }
        let mut summary_evidence = Vec::new();
        for section in SettingsSection::ALL {
            cx.update_window(handle, |_, window, cx| view.update(cx, |view, cx| {
                view.navigation.search_query.clear();
                view.select(section,window,cx);
            })).context("owned summary window disappeared")?;
            for _ in 0..3 {
                crate::native_parity_fixture::next_frame(handle,cx).await.map_err(anyhow::Error::msg)?;
            }
            let cards = summary::observed(section);
            ensure!(cards.len() >= 4, "summary lacks current minimum4 cards: {}",section.id());
            let viewport=cx.update(|cx|view.read(cx).scroll_handle.bounds());
            let visible=cx.update_window(handle,|_,window,_|cards.iter().all(|(id,_)| {
                window.try_find(SharedString::from(format!("settings-summary-{}-{id}",section.id())))
                    .is_some_and(|element|element.visible() && element.bounds().bottom()>viewport.top() && element.bounds().top()<viewport.bottom())
            })).context("owned summary window disappeared during actual visibility check")?;
            ensure!(visible,"summary cards are outside native viewport: {}",section.id());
            if section == SettingsSection::General {
                let displayed=cards.iter().find(|(id,_)|*id=="language").map(|(_,v)|v);
                ensure!(displayed == Some(&crate::l10n::language_name(locale.setting)), "native summary did not display the actual chosen language");
            }
            summary_evidence.push(json!({"section":section.id(),"cards":cards.iter().map(|(id,value)|json!({"id":id,"value":value})).collect::<Vec<_>>(),"visible":visible}));
        }
        let input = cx.update(|cx| view.read(cx).search_input.clone());
        let mut queries = Vec::new();
        // Exercise the actual InputState subscription. These are owned app
        // events, without OS keyboard input or a direct navigation shortcut.
        for spec in locale.queries() {
            let query = spec.query.as_str();
            anchors::take_rendered_targets();
            let previous = cx.update(|cx| view.read(cx).navigation.selection);
            cx.update_window(handle, |_, window, cx| input.update(cx, |input, cx| {
                input.set_value(query, window, cx);
                cx.emit(InputEvent::Change);
            })).context("owned settings query window disappeared")?;
            let animation_frames = settled_frame(handle,&view,cx).await?;
            let (selection, explicit, active, target, viewport, offset, maximum) = cx.update(|cx| {
                let settings = view.read(cx);
                let active = settings.active_search_anchor_id();
                (settings.navigation.selection, settings.navigation.anchor_id.clone(), active,
                 active.and_then(|id| settings.target_bounds.get(id)), settings.scroll_handle.bounds(),
                 settings.scroll_handle.offset(), settings.scroll_handle.max_offset())
            });
            ensure!(explicit.is_none(), "automatic query created an explicit anchor: {query}");
            let first = sections_matching(query).first().map(|(section, _)| *section);
            ensure!(first == spec.expected.map(|(section,_)|section), "localized query did not match its source-exact expected section: {query}");
            if query.is_empty() || first.is_none() {
                ensure!(selection == previous && active.is_none(), "empty/unmatched query changed selection: {query}");
                ensure!(anchors::highlighted_targets().is_empty(), "empty/unmatched query retained highlight: {query}");
                queries.push(json!({"animation_frames":animation_frames,"query":query,"section":selection.id(),"retained_selection":true,"active_anchor":null,"highlighted_targets":0}));
            } else {
                ensure!(Some(selection) == first, "automatic query did not select first matching section: {query}");
                let expected = matching_settings(selection, query)[0].anchor_id;
                ensure!(active == Some(expected), "automatic query did not derive first matching anchor: {query}");
                ensure!(spec.expected.map(|(_,anchor)|anchor) == Some(expected), "localized query did not match its source-exact expected anchor: {query}");
                ensure!(anchors::highlighted_targets() == std::collections::HashSet::from([expected]), "actual first-match highlight did not prepaint: {query}");
                let target = target.context("first-match query has no actual layout")?;
                ensure!(target.bottom() > viewport.top() && target.top() < viewport.bottom(), "automatic query target is outside viewport: {query}");
                ensure!(offset.y >= -maximum.y && offset.y <= px(0.0), "automatic query offset is out of bounds: {query}");
                let center_error = f32::from(target.center().y - viewport.center().y).abs();
                let clamped = offset.y == px(0.0) || offset.y == -maximum.y;
                ensure!(clamped || center_error < 2.0, "automatic query was not centered: {query}: {center_error}");
                queries.push(json!({"animation_frames":animation_frames,"query":query,"source_title_key":spec.title_key,"catalog_uses_english_fallback":spec.fallback,"section":selection.id(),"active_anchor":expected,"derived_anchor":true,
                    "highlight_prepaint":true,"visible":true,"center_error_px":center_error,"clamped_to_content":clamped,
                    "offset_y":f32::from(offset.y),"max_offset_y":f32::from(maximum.y)}));
            }
        }
        Ok(json!({"case":"settings-search", "targets":SEARCHABLE_SETTINGS.len(), "visible_targets":evidence.len(), "target_evidence":evidence,
            "summary_evidence":summary_evidence,"summary_sections":28,"automatic_query_evidence":queries,"query_event_delivery":"production_InputState_Change","query_frames":"actual_until_production_animations_settle","scroll_duration_ms":220,"scroll_retry_ms":120,"highlight_duration_ms":180,"animation_settle_deadline_ms":500,"settings_case_deadline_seconds":70,"highlight_pixel_acceptance":false,
            "frame_delivery":"real_native_platform", "frames_per_target":"actual_until_production_animations_settle", "synthetic_frame_delivery":false,
            "keyboard_or_pointer_acceptance":false,"requested_language":locale.setting.id(),"os_preferred_languages":locale.preferred,"system_default_resolution":if locale.setting==crate::settings::AppLanguage::System {Some(locale.resolved.code())}else{None},"rtl":locale.resolved.is_rtl(),"direction_check":"real_sidebar_and_detail_prepaint_bounds","interface_language":chau7_next_core::l10n::current().code()}))
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
