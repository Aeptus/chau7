//! Actual native GPUI window, production restore and owned fake-shell PTYs.
use super::*;
use crate::native_parity_fixture::next_frame;
use crate::terminal::session::TerminalSession;
use chau7_next_core::data_root::DataRoot;
use chau7_next_core::session_restore::models::SavedPane;
use chau7_next_core::session_restore::{SavedAxis, SavedSplitNode};
use chau7_terminal::{CELL_FLAG_BOLD, CELL_FLAG_UNDERLINE, Chau7Terminal};
use gpui::{AppContext, AsyncApp, Focusable, WindowHandle, WindowOptions, size};
use gpui_kit::base::Root;
use objc2::{MainThreadMarker, rc::Retained, runtime::AnyObject};
use objc2_app_kit::{
    NSApplication, NSApplicationActivationPolicy, NSApplicationPresentationOptions, NSColorSpace,
    NSEvent, NSEventModifierFlags, NSEventType, NSMenu, NSView, NSWindow, NSWindowButton,
    NSWindowStyleMask,
};
use objc2_foundation::{NSArray, NSBundle, NSEdgeInsets, NSObject, NSPoint, NSString};
use raw_window_handle::{HasWindowHandle, RawWindowHandle};
use std::io::Write;
use std::os::unix::fs::PermissionsExt;
use std::path::Path;

fn error(error: impl std::fmt::Display) -> String {
    error.to_string()
}
fn ensure(condition: bool, message: &str) -> Result<(), String> {
    if condition {
        Ok(())
    } else {
        Err(message.into())
    }
}

fn verify_grouping_summary(
    summary: &serde_json::Map<String, serde_json::Value>,
    mode: &str,
    group_id: &str,
    primary_root: &str,
    presentation_root: &str,
) -> Result<(), String> {
    let grouping = summary
        .get("repo_grouping")
        .and_then(serde_json::Value::as_object)
        .ok_or("MCP summary omitted repository grouping")?;
    ensure(
        grouping.get("mode").and_then(serde_json::Value::as_str) == Some(mode),
        "MCP repository grouping mode changed",
    )?;
    ensure(
        grouping.get("group_id").and_then(serde_json::Value::as_str) == Some(group_id),
        "MCP repository grouping selected the wrong group",
    )?;
    ensure(
        grouping
            .get("primary_repo_root")
            .and_then(serde_json::Value::as_str)
            == Some(primary_root),
        "MCP primary repository root changed",
    )?;
    ensure(
        grouping
            .get("presentation_repo_root")
            .and_then(serde_json::Value::as_str)
            == Some(presentation_root),
        "MCP presentation repository root changed",
    )
}

fn styled_scrollback_sample(term: &Chau7Terminal) -> Result<serde_json::Value, String> {
    // Sample the first retained row, not the recent screen tail, before
    // persistence and after the production reload. The fixture moves the
    // session to this viewport through its production scroll/refresh path.
    let grid = term.grid_copy();
    ensure(grid.cols > 0, "styled fixture terminal has no columns")?;
    ensure(
        grid.scrollback_rows > 0,
        "styled fixture output did not enter scrollback",
    )?;
    ensure(
        grid.display_offset == grid.scrollback_rows,
        "styled fixture is not viewing the top of retained scrollback",
    )?;

    let marker = "RESTORED_STYLE:é中❤️";
    let row_text = |row: usize| {
        let mut text = String::new();
        for column in 0..grid.cols as usize {
            let index = row * grid.cols as usize + column;
            if !grid.cells[index].continuation {
                text.push_str(&grid.cell_text(index).unwrap_or_default());
            }
        }
        text
    };
    let matching_rows: Vec<_> = (0..grid.rows as usize)
        .filter(|row| row_text(*row).contains(marker))
        .collect();
    ensure(
        matching_rows.len() == 1,
        "styled marker is not unique in the top retained-history viewport",
    )?;
    let row = matching_rows[0];
    ensure(
        row < grid.scrollback_rows as usize,
        "styled marker is outside retained history at the top scroll position",
    )?;
    let row_start = row * grid.cols as usize;
    let row_end = row_start + grid.cols as usize;
    let find_cell = |text: &str| {
        (row_start..row_end)
            .find(|index| grid.cell_text(*index).as_deref() == Some(text))
            .ok_or_else(|| format!("restored grid is missing styled cell {text:?}"))
    };
    let accent = find_cell("é")?;
    let cjk = find_cell("中")?;
    let emoji = find_cell("❤️")?;
    let cjk_continuation = cjk + 1;
    ensure(
        cjk / grid.cols as usize == row && emoji / grid.cols as usize == row,
        "styled graphemes did not remain on one terminal row",
    )?;
    ensure(
        cjk_continuation / grid.cols as usize == row,
        "CJK continuation moved to another terminal row",
    )?;

    for index in [accent, cjk, emoji] {
        let cell = grid.cells[index];
        ensure(
            cell.fg == (12, 34, 56),
            "styled scrollback foreground changed",
        )?;
        ensure(cell.bg == (7, 8, 9), "styled scrollback background changed")?;
        ensure(
            cell.flags & (CELL_FLAG_BOLD | CELL_FLAG_UNDERLINE)
                == (CELL_FLAG_BOLD | CELL_FLAG_UNDERLINE),
            "styled scrollback bold or underline flag changed",
        )?;
        ensure(
            cell.underline == chau7_terminal::UNDERLINE_SINGLE,
            "styled scrollback underline variant changed",
        )?;
    }
    ensure(
        grid.cells[cjk].width == 2 && !grid.cells[cjk].continuation,
        "CJK lead cell lost its wide-cell layout",
    )?;
    ensure(
        grid.cells[cjk_continuation].width == 0 && grid.cells[cjk_continuation].continuation,
        "CJK continuation cell lost its layout",
    )?;

    let row_text = row_text(row);
    ensure(
        row_text.contains(marker),
        "styled scrollback row lost its full grapheme text",
    )?;
    let cell_sample = |index: usize| {
        let cell = grid.cells[index];
        serde_json::json!({
            "index": index,
            "text": grid.cell_text(index),
            "fg": cell.fg,
            "bg": cell.bg,
            "flags": cell.flags,
            "underline": cell.underline,
            "width": cell.width,
            "continuation": cell.continuation,
        })
    };
    Ok(serde_json::json!({
        "scrollback_rows": grid.scrollback_rows,
        "display_offset": grid.display_offset,
        "cells": {
            "row": row,
            "row_text": row_text,
            "combining_accent": cell_sample(accent),
            "cjk": cell_sample(cjk),
            "cjk_continuation": cell_sample(cjk_continuation),
            "emoji": cell_sample(emoji),
        },
    }))
}

fn styled_viewport_diagnostic(session: &TerminalSession) -> serde_json::Value {
    let cached = &session.grid;
    let raw = session.with_terminal(|term| {
        let grid = term.grid_copy();
        serde_json::json!({
            "cols": grid.cols,
            "rows": grid.rows,
            "scrollback_rows": grid.scrollback_rows,
            "display_offset": grid.display_offset,
            "at_top": grid.scrollback_rows > 0 && grid.display_offset == grid.scrollback_rows,
            "styled_background_present": grid.cells.iter().any(|cell| cell.bg == (7, 8, 9)),
        })
    });
    let allocation = session.allocation_snapshot();
    serde_json::json!({
        "cached": {
            "cols": cached.cols,
            "rows": cached.rows,
            "scrollback_rows": cached.scrollback_rows,
            "display_offset": cached.display_offset,
            "at_top": cached.scrollback_rows > 0
                && cached.display_offset == cached.scrollback_rows,
            "styled_background_present": cached.cells.iter().any(|cell| cell.bg == (7, 8, 9)),
        },
        "raw": raw,
        "render_suspended": allocation["render_suspended"],
        "refresh_cap_interval_ms": allocation["refresh_cap_interval_ms"],
        "refresh_interactive": allocation["refresh_interactive"],
    })
}

fn activation_diagnostic(
    app_active: bool,
    activation_policy: isize,
    window_visible: bool,
    window_key: bool,
    window_can_become_key: bool,
) -> serde_json::Value {
    serde_json::json!({
        "stage": "owned_fixture_application_activation",
        "app_active": app_active,
        "activation_policy": activation_policy,
        "window_visible": window_visible,
        "window_key": window_key,
        "window_can_become_key": window_can_become_key,
    })
}

// Native window mutations can synchronously request a GPUI frame. The
// foreground task calls them with no App/window borrow or state lock held.
fn native_mutation(action: impl FnOnce()) -> Result<(), String> {
    let _main = MainThreadMarker::new().ok_or("native fixture is not on main thread")?;
    action();
    Ok(())
}
fn activate_owned_application(application: &NSApplication) -> Result<(), String> {
    native_mutation(|| application.activate())
}

async fn prepare_fullscreen_menu_state(
    stage: &'static str,
    native: &NSWindow,
    application: &NSApplication,
    cx: &mut AsyncApp,
) -> Result<serde_json::Value, String> {
    let was_active = application.isActive();
    let was_key = native.isKeyWindow();
    let reacquisition_requested = !was_active || !was_key;
    if reacquisition_requested {
        native_mutation(|| native.makeKeyAndOrderFront(None))?;
        activate_owned_application(application)?;
    }

    let deadline = Instant::now() + Duration::from_secs(5);
    wait_until_deadline(cx, stage, deadline, |_| {
        application.isActive()
            && native.isVisible()
            && native.isKeyWindow()
            && native.styleMask().contains(NSWindowStyleMask::FullScreen)
    })
    .await?;

    // A focus change during this bounded interval is an assertion failure;
    // this helper does not repeatedly reacquire after the initial attempt.
    for _ in 0..3 {
        ensure(
            application.isActive()
                && native.isVisible()
                && native.isKeyWindow()
                && native.styleMask().contains(NSWindowStyleMask::FullScreen),
            "owned fullscreen fixture lost foreground during its stability window",
        )?;
        pause(cx, Duration::from_millis(25)).await;
    }

    let evidence = serde_json::json!({
        "stage": stage,
        "was_active_before": was_active,
        "was_key_before": was_key,
        "reacquisition_requested": reacquisition_requested,
        "app_active_after": application.isActive(),
        "window_visible_after": native.isVisible(),
        "window_key_after": native.isKeyWindow(),
        "window_fullscreen_after": native.styleMask().contains(NSWindowStyleMask::FullScreen),
        "stability_samples": 3,
        "sample_interval_ms": 25,
        "scope": "only the owned fixture application and its fullscreen window",
    });
    eprintln!("native_fullscreen_menu_foreground={evidence}");
    Ok(evidence)
}

fn emit_activation_handshake(
    prefix: &str,
    stage: &str,
    activation_ack_path: &Path,
) -> Result<(), String> {
    let bundle_identifier = NSBundle::mainBundle()
        .bundleIdentifier()
        .map(|value| value.to_string())
        .ok_or("owned native fixture has no bundle identifier")?;
    let executable = std::env::current_exe().map_err(error)?;
    let bundle = executable
        .parent()
        .and_then(Path::parent)
        .and_then(Path::parent)
        .ok_or("owned native fixture executable is outside an app bundle")?;
    let bundle_path = bundle.to_string_lossy().into_owned();
    let activation_ack_path = activation_ack_path.to_string_lossy().into_owned();
    let handshake = serde_json::json!({
        "stage": stage,
        "pid": std::process::id(),
        "bundle_identifier": bundle_identifier,
        "bundle_path": bundle_path,
        "activation_ack_path": activation_ack_path,
    });
    let mut stderr = std::io::stderr().lock();
    writeln!(stderr, "{prefix}{handshake}").map_err(error)?;
    stderr.flush().map_err(error)
}

fn send_owned_key_event(
    application: &NSApplication,
    native: &NSWindow,
    characters: &str,
    modifiers: NSEventModifierFlags,
    key_code: u16,
) -> Result<(), String> {
    let _main = MainThreadMarker::new().ok_or("keyboard event is not on the main thread")?;
    ensure(
        application.isActive() && native.isVisible() && native.isKeyWindow(),
        "keyboard event target is not the active owned window",
    )?;
    let characters = NSString::from_str(characters);
    let event = NSEvent::keyEventWithType_location_modifierFlags_timestamp_windowNumber_context_characters_charactersIgnoringModifiers_isARepeat_keyCode(
        NSEventType::KeyDown,
        NSPoint::new(0., 0.),
        modifiers,
        0.,
        native.windowNumber(),
        None,
        &characters,
        &characters,
        false,
        key_code,
    )
    .ok_or_else(|| "AppKit could not construct the owned keyboard event".to_owned())?;
    // Send through the application's ordinary window/responder route. The call
    // stays outside GPUI's App/window borrow so AppKit may safely re-enter it.
    application.sendEvent(&event);
    Ok(())
}
#[derive(serde::Serialize)]
struct SessionSurfaceDiagnostic {
    index: usize,
    visible: bool,
    suspended: bool,
    live_frame: bool,
}
#[derive(serde::Serialize)]
struct RevealDiagnostic {
    stage: &'static str,
    app_active: bool,
    activation_policy: isize,
    window_miniaturized: bool,
    window_visible: bool,
    window_key: bool,
    window_can_become_key: bool,
    window_occlusion_bits: usize,
    gpui_visible: bool,
    gpui_active: bool,
    selected_session_count: usize,
    session_sample_limit: usize,
    sessions: Vec<SessionSurfaceDiagnostic>,
    renderer_backend: Option<&'static str>,
    submitted_frames: Option<u64>,
    failed_frames: Option<u64>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct RendererFrameCounters {
    submitted: u64,
    failed: u64,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct WindowFrameEvidence {
    frame_number: u64,
    renderer_backend: Option<&'static str>,
    renderer_counters: Option<RendererFrameCounters>,
}

fn window_frame_evidence(
    handle: WindowHandle<Root>,
    cx: &mut AsyncApp,
) -> Result<WindowFrameEvidence, String> {
    handle
        .update(cx, |_, window, _| -> Result<WindowFrameEvidence, String> {
            let raw = window
                .debug_a11y_tree_json()
                .ok_or("owned window has no rendered accessibility tree")?;
            let tree: serde_json::Value = serde_json::from_str(&raw).map_err(error)?;
            let frame_number = tree
                .get("frame")
                .and_then(|frame| frame.get("frame_number"))
                .and_then(serde_json::Value::as_u64)
                .ok_or("rendered accessibility tree lacks frame number")?;
            let renderer = window.renderer_diagnostics();
            let renderer_backend = renderer.as_ref().map(|sample| sample.backend);
            let renderer_counters = renderer.and_then(|sample| {
                Some(RendererFrameCounters {
                    submitted: sample.submitted_frames?,
                    failed: sample.failed_frames?,
                })
            });
            Ok(WindowFrameEvidence {
                frame_number,
                renderer_backend,
                renderer_counters,
            })
        })
        .map_err(error)?
}

fn activate_native_accessibility_adapter(view: &NSView) -> Result<(), String> {
    let _main = MainThreadMarker::new().ok_or("accessibility query is not on the main thread")?;
    // Match the native accessibility fixture: querying the owned content
    // view's AccessKit children activates AppKit's adapter without AX trust.
    let root = unsafe {
        Retained::<NSObject>::retain((view as *const NSView).cast_mut().cast::<NSObject>())
    }
    .ok_or("could not retain owned accessibility content view")?;
    let children: Option<Retained<NSArray<NSObject>>> =
        unsafe { objc2::msg_send![&*root, accessibilityChildren] };
    let _children = children.ok_or("owned content view did not export accessibility children")?;
    Ok(())
}

async fn bootstrap_rendered_accessibility_frame(
    handle: WindowHandle<Root>,
    native: &NSWindow,
    cx: &mut AsyncApp,
) -> Result<(), String> {
    next_frame(handle.into(), cx).await?;
    let content_view = native
        .contentView()
        .ok_or("owned native window lacks accessibility content view")?;
    activate_native_accessibility_adapter(&content_view)?;
    next_frame(handle.into(), cx).await?;
    // Read GPUI's rendered tree after the AppKit query, matching the
    // native accessibility fixture's adapter bootstrap sequence.
    let _ = window_frame_evidence(handle, cx)?;
    Ok(())
}

fn successful_frame_delta(
    before: RendererFrameCounters,
    after: RendererFrameCounters,
) -> Option<u64> {
    if after.failed != before.failed {
        return None;
    }
    after
        .submitted
        .checked_sub(before.submitted)
        .filter(|delta| *delta > 0)
}

fn rendered_frame_delta(before: u64, after: u64) -> Option<u64> {
    after.checked_sub(before).filter(|delta| *delta > 0)
}

fn rendered_reveal_delta(baseline: u64, first_live: u64, after_settle: u64) -> Option<u64> {
    if rendered_frame_delta(baseline, first_live).is_none() || after_settle < first_live {
        return None;
    }
    rendered_frame_delta(baseline, after_settle)
}

fn supplemental_renderer_delta(
    before: WindowFrameEvidence,
    after: WindowFrameEvidence,
) -> Option<Option<u64>> {
    if before.renderer_backend != after.renderer_backend {
        return None;
    }
    match (
        before.renderer_backend,
        before.renderer_counters,
        after.renderer_counters,
    ) {
        (Some("software"), Some(before), Some(after)) => {
            successful_frame_delta(before, after).map(Some)
        }
        (Some("metal"), None, None) => Some(None),
        _ => None,
    }
}

fn restore_surface_frame_ready(visible: bool, live_frame: bool, suspended: bool) -> bool {
    visible && live_frame && !suspended
}

fn final_native_focus_ready(
    app_active: bool,
    window_visible: bool,
    window_key: bool,
    window_miniaturized: bool,
) -> bool {
    app_active && window_visible && window_key && !window_miniaturized
}

fn request_restore_surface_frames(sessions: &[(u64, Entity<TerminalSession>)], cx: &mut App) {
    for (_, session) in sessions {
        session.update(cx, |session, cx| {
            session.request_surface_frame();
            session.refresh(cx);
        });
    }
}

fn reveal_diagnostic(
    stage: &'static str,
    native: &NSWindow,
    application: &NSApplication,
    handle: WindowHandle<Root>,
    sessions: &[(u64, Entity<TerminalSession>)],
    cx: &mut AsyncApp,
) -> Result<RevealDiagnostic, String> {
    let _main = MainThreadMarker::new().ok_or("native fixture is not on main thread")?;
    // Observe native state before entering the read-only GPUI update.
    let mut snapshot = RevealDiagnostic {
        stage,
        app_active: application.isActive(),
        activation_policy: application.activationPolicy().0,
        window_miniaturized: native.isMiniaturized(),
        window_visible: native.isVisible(),
        window_key: native.isKeyWindow(),
        window_can_become_key: native.canBecomeKeyWindow(),
        window_occlusion_bits: native.occlusionState().0,
        gpui_visible: false,
        gpui_active: false,
        selected_session_count: sessions.len(),
        session_sample_limit: 8,
        sessions: Vec::new(),
        renderer_backend: None,
        submitted_frames: None,
        failed_frames: None,
    };
    handle
        .update(cx, |_, window, cx| {
            snapshot.gpui_visible = window.is_visible();
            snapshot.gpui_active = window.is_window_active();
            snapshot.sessions = sessions
                .iter()
                .take(snapshot.session_sample_limit)
                .enumerate()
                .map(|(index, (_, session))| {
                    let session = session.read(cx);
                    SessionSurfaceDiagnostic {
                        index,
                        visible: session.restore_surface_visible(),
                        suspended: session.is_render_suspended(),
                        live_frame: session.surface_has_live_frame(),
                    }
                })
                .collect();
            if let Some(renderer) = window.renderer_diagnostics() {
                snapshot.renderer_backend = Some(renderer.backend);
                snapshot.submitted_frames = renderer.submitted_frames;
                snapshot.failed_frames = renderer.failed_frames;
            }
        })
        .map_err(error)?;
    Ok(snapshot)
}
async fn wait_for_reveal(
    handle: WindowHandle<Root>,
    native: &NSWindow,
    application: &NSApplication,
    sessions: &[(u64, Entity<TerminalSession>)],
    cx: &mut AsyncApp,
    stage: &'static str,
    ready: impl FnMut(&App) -> bool,
) -> Result<(), String> {
    if let Err(error) = wait_until(cx, stage, ready).await {
        // Diagnostic failure must not replace the original failed predicate.
        if let Ok(snapshot) = reveal_diagnostic(stage, native, application, handle, sessions, cx)
            && let Ok(snapshot) = serde_json::to_string(&snapshot)
        {
            eprintln!("native_surface_reveal_failure={snapshot}");
        }
        return Err(error);
    }
    Ok(())
}

async fn wait_for_activation_reveal(
    handle: WindowHandle<Root>,
    native: &NSWindow,
    application: &NSApplication,
    sessions: &[(u64, Entity<TerminalSession>)],
    cx: &mut AsyncApp,
    activation_ack_path: &Path,
) -> Result<(WindowFrameEvidence, WindowFrameEvidence, Instant), String> {
    let stage = "actual deminiaturized surface reveal";
    let deadline = Instant::now() + Duration::from_secs(8);
    let mut frame_at_ack = None;

    loop {
        if activation_ack_path.exists() && frame_at_ack.is_none() {
            let baseline = window_frame_evidence(handle, cx)?;
            // The ACK follows the isolated LaunchServices reopen. Reset each
            // protected terminal here so an older presented-frame bit cannot
            // satisfy the deminiaturized reveal gate.
            cx.update(|cx| request_restore_surface_frames(sessions, cx));
            frame_at_ack = Some(baseline);
        }

        let current_frame = if frame_at_ack.is_some() {
            Some(window_frame_evidence(handle, cx)?)
        } else {
            None
        };
        let surfaces_live = cx.update(|cx| {
            sessions.iter().all(|(_, session)| {
                let session = session.read(cx);
                restore_surface_frame_ready(
                    session.restore_surface_visible(),
                    session.surface_has_live_frame(),
                    session.is_render_suspended(),
                )
            })
        });
        let ready = frame_at_ack
            .zip(current_frame)
            .is_some_and(|(baseline, current)| {
                rendered_frame_delta(baseline.frame_number, current.frame_number).is_some()
                    && supplemental_renderer_delta(baseline, current).is_some()
                    && surfaces_live
                    && final_native_focus_ready(
                        application.isActive(),
                        native.isVisible(),
                        native.isKeyWindow(),
                        native.isMiniaturized(),
                    )
            });
        if Instant::now() < deadline && activation_ack_path.exists() && ready {
            return Ok((
                frame_at_ack.ok_or_else(|| "activation ACK baseline was absent".to_owned())?,
                current_frame.ok_or_else(|| "later rendered frame was absent".to_owned())?,
                deadline,
            ));
        }
        if Instant::now() >= deadline {
            // Diagnostic failure must not replace the original failed predicate.
            if let Ok(snapshot) =
                reveal_diagnostic(stage, native, application, handle, sessions, cx)
                && let Ok(snapshot) = serde_json::to_string(&snapshot)
            {
                eprintln!("native_surface_reveal_failure={snapshot}");
            }
            return Err(format!("owned native fixture deadline: {stage}"));
        }
        let remaining = deadline.saturating_duration_since(Instant::now());
        pause(cx, remaining.min(Duration::from_millis(10))).await;
    }
}

async fn settle_with_deadline(
    handle: WindowHandle<Root>,
    cx: &mut AsyncApp,
    deadline: Instant,
) -> Result<(), String> {
    for _ in 0..2 {
        let remaining = deadline.saturating_duration_since(Instant::now());
        crate::native_parity_fixture::next_frame_with_timeout(handle.into(), cx, remaining).await?;
    }
    Ok(())
}

struct MetadataEventCounter {
    _subscription: gpui::Subscription,
}

impl MetadataEventCounter {
    fn new(
        panes: gpui::Entity<PaneTree>,
        count: std::sync::Arc<std::sync::atomic::AtomicUsize>,
        total_count: std::sync::Arc<std::sync::atomic::AtomicUsize>,
        primary_root: PathBuf,
        presentation_root: PathBuf,
        cx: &mut gpui::Context<Self>,
    ) -> Self {
        let subscription = cx.subscribe(&panes, move |_, panes, event: &PaneEvent, cx| {
            if !matches!(event, PaneEvent::MetadataChanged) {
                return;
            }
            total_count.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
            let tree = panes.read(cx);
            let actual_primary = tree
                .primary_session(cx)
                .and_then(|session| session.read(cx).git_root.clone());
            let actual_presentation = tree
                .presentation_session(cx)
                .and_then(|session| session.read(cx).git_root.clone());
            if actual_primary.as_deref() == Some(primary_root.as_path())
                && actual_presentation.as_deref() == Some(presentation_root.as_path())
            {
                count.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
            }
        });
        Self {
            _subscription: subscription,
        }
    }
}

struct Profile {
    home: PathBuf,
    root: DataRoot,
    shell: PathBuf,
    directories: Vec<PathBuf>,
    ids: Vec<String>,
}
impl Profile {
    fn new(home: PathBuf) -> Result<Self, String> {
        let root = DataRoot::with_home(home.clone(), true);
        root.ensure_dirs().map_err(error)?;
        let shell = home.join("fixture-shell");
        std::fs::write(&shell, b"#!/bin/sh\n/bin/stty -echo -icanon min 1 time 0\nprintf started > started\nwhile [ ! -f ready ]; do /bin/sleep 0.01; done\nif [ -f ordinary-history ]; then /bin/cat ordinary-history; fi\nprintf '\x1b]133;A\x07fixture$ '\n(while [ ! -f hidden-output ]; do /bin/sleep 0.01; done; printf '\nOWNED_HIDDEN_GRID\n'; printf done > output-child-done) &\nexec /bin/cat > received\n").map_err(error)?;
        std::fs::set_permissions(&shell, std::fs::Permissions::from_mode(0o700)).map_err(error)?;
        let directories: Vec<_> = (0..7).map(|i| home.join(format!("pane-{i}"))).collect();
        let ids: Vec<_> = (0..7).map(|_| uuid::Uuid::new_v4().to_string()).collect();
        for (index, (directory, id)) in directories.iter().zip(&ids).enumerate() {
            std::fs::create_dir_all(directory).map_err(error)?;
            if matches!(index, 1 | 2) {
                let git_dir = directory.join(".git");
                std::fs::create_dir_all(git_dir.join("objects")).map_err(error)?;
                std::fs::create_dir_all(git_dir.join("refs/heads")).map_err(error)?;
                let branch = if index == 1 {
                    "fixture-primary"
                } else {
                    "fixture-focused"
                };
                std::fs::write(git_dir.join("HEAD"), format!("ref: refs/heads/{branch}\n"))
                    .map_err(error)?;
                std::fs::write(
                    git_dir.join("config"),
                    b"[core]\n\trepositoryformatversion = 0\n\tbare = false\n",
                )
                .map_err(error)?;
            }
            let project = directory.to_string_lossy();
            let folder = home.join(".claude/projects").join(
                chau7_next_core::session_restore::claude_project_dir_name(&project),
            );
            std::fs::create_dir_all(&folder).map_err(error)?;
            std::fs::write(folder.join(format!("{id}.jsonl")), b"{}\n").map_err(error)?;
        }
        let mut ordinary_history = String::from(concat!(
            "\x1b[1;4;38;2;12;34;56;48;2;7;8;9mRESTORED_STYLE:",
            "e\u{301}中❤️",
            "\x1b[0m\r\n",
        ));
        ordinary_history.push_str(
            &(0..200)
                .map(|i| format!("OWNED_HISTORY_{i:03}\r\n"))
                .collect::<String>(),
        );
        std::fs::write(directories[5].join("ordinary-history"), ordinary_history).map_err(error)?;
        let history = directories
            .iter()
            .zip(&ids)
            .map(|(directory, id)| {
                serde_json::json!({"sessionId":id,"project":directory,"timestamp":1000}).to_string()
            })
            .collect::<Vec<_>>()
            .join("\n");
        std::fs::write(home.join(".claude/history.jsonl"), history).map_err(error)?;
        Ok(Self {
            home,
            root,
            shell,
            directories,
            ids,
        })
    }
    fn resume_command(&self, index: usize) -> String {
        if index == 2 {
            format!("opencode --session {}", self.ids[index])
        } else {
            format!("claude --resume {}", self.ids[index])
        }
    }
    fn pane(&self, index: usize) -> SavedPane {
        SavedPane {
            id: 100 + index as u64,
            directory: Some(self.directories[index].to_string_lossy().into_owned()),
            ai_provider: Some(if index == 2 { "opencode" } else { "claude" }.into()),
            ai_session_id: Some(self.ids[index].clone()),
            ai_resume_command: Some(self.resume_command(index)),
            known_repo_root: matches!(index, 1 | 2)
                .then(|| self.directories[index].to_string_lossy().into_owned()),
            ..Default::default()
        }
    }
    fn tab(&self, indices: &[usize]) -> SavedTab {
        let panes: Vec<_> = indices.iter().map(|i| self.pane(*i)).collect();
        let children: Vec<_> = panes
            .iter()
            .map(|p| SavedSplitNode::Terminal {
                id: p.id,
                directory: p.directory.clone(),
            })
            .collect();
        SavedTab {
            uuid: Some(uuid::Uuid::new_v4()),
            cwd: Some(self.directories[indices[0]].clone()),
            focused_pane: Some(panes[panes.len() - 1].id),
            layout: if children.len() == 1 {
                children.into_iter().next()
            } else {
                Some(SavedSplitNode::Split {
                    id: 900,
                    axis: SavedAxis::Horizontal,
                    ratios: vec![0.35, 0.65],
                    children,
                })
            },
            panes,
            ..Default::default()
        }
    }
    fn received(&self, index: usize) -> Vec<u8> {
        std::fs::read(self.directories[index].join("received")).unwrap_or_default()
    }
    fn release_prompt(&self, index: usize) -> Result<(), String> {
        std::fs::write(self.directories[index].join("ready"), b"ready").map_err(error)
    }
}

async fn settle(handle: WindowHandle<Root>, cx: &mut AsyncApp) -> Result<(), String> {
    next_frame(handle.into(), cx).await?;
    next_frame(handle.into(), cx).await
}
async fn pause(cx: &AsyncApp, duration: Duration) {
    cx.background_executor().timer(duration).await;
}
async fn wait_until(
    cx: &mut AsyncApp,
    stage: &str,
    mut ready: impl FnMut(&App) -> bool,
) -> Result<(), String> {
    let started = Instant::now();
    loop {
        if cx.update(|cx| ready(cx)) {
            return Ok(());
        }
        if started.elapsed() >= Duration::from_secs(5) {
            return Err(format!("owned native fixture deadline: {stage}"));
        }
        pause(cx, Duration::from_millis(10)).await;
    }
}
async fn wait_until_deadline(
    cx: &mut AsyncApp,
    stage: &str,
    deadline: Instant,
    mut ready: impl FnMut(&App) -> bool,
) -> Result<(), String> {
    loop {
        if Instant::now() >= deadline {
            return Err(format!("owned native fixture deadline: {stage}"));
        }
        if cx.update(|cx| ready(cx)) && Instant::now() < deadline {
            return Ok(());
        }
        let now = Instant::now();
        if now >= deadline {
            return Err(format!("owned native fixture deadline: {stage}"));
        }
        let remaining = deadline.saturating_duration_since(now);
        pause(cx, remaining.min(Duration::from_millis(10))).await;
    }
}
fn select(
    handle: WindowHandle<Root>,
    ws: &Entity<Workspace>,
    id: TabId,
    cx: &mut AsyncApp,
) -> Result<(), String> {
    handle
        .update(cx, |_, window, cx| {
            ws.update(cx, |ws, cx| ws.select_tab(id, window, cx))
        })
        .map_err(error)
}

/// Shared cleanup also handles a case cancelled by the common runner deadline.
pub(crate) async fn dispose(cx: &mut AsyncApp) -> Result<usize, String> {
    let sessions = cx.update(|cx| {
        let sessions: Vec<_> = AppData::live(cx)
            .into_iter()
            .flat_map(|(_, ws)| {
                ws.read(cx)
                    .entries
                    .values()
                    .flat_map(|entry| entry.panes.read(cx).pane_sessions(cx))
                    .collect::<Vec<_>>()
            })
            .collect();
        for (_, session) in &sessions {
            session.update(cx, |session, _| session.close());
        }
        sessions
    });
    wait_until(cx, "graceful PTY exit", |cx| {
        sessions
            .iter()
            .all(|(_, session)| session.read(cx).exited.is_some())
    })
    .await?;
    let count = sessions.len();
    cx.update(|cx| {
        for window in cx.windows() {
            let _ = cx.update_window(window, |_, window, _| window.remove_window());
        }
    });
    Ok(count)
}

pub(crate) async fn verify_keyboard(cx: &mut AsyncApp) -> Result<serde_json::Value, String> {
    let home = cx.update(|cx| cx.global::<AppData>().root.home().to_path_buf());
    let profile = Profile::new(home)?;
    std::fs::write(
        &profile.shell,
        b"#!/bin/sh\nset -eu\n/bin/stty -echo -icanon -isig min 1 time 0\nprintf '%s' \"$$\" > \"started.$$\"\nwhile [ ! -f ready ]; do /bin/sleep 0.01; done\nprintf '\\033]133;A\\007fixture$ '\nexec /bin/cat > \"received.$$\"\n",
    )
    .map_err(error)?;
    std::fs::set_permissions(&profile.shell, std::fs::Permissions::from_mode(0o700))
        .map_err(error)?;
    let result = verify_keyboard_workspace(cx, &profile).await;
    let cleanup = dispose(cx).await;
    match (result, cleanup) {
        (Ok(mut details), Ok(closed)) if closed == 3 => {
            if let Some(object) = details.as_object_mut() {
                object.insert("closed_owned_ptys".into(), serde_json::json!(closed));
            }
            Ok(details)
        }
        (Ok(_), Ok(closed)) => Err(format!(
            "keyboard fixture closed {closed} owned PTYs instead of three"
        )),
        (Err(error), Ok(_)) => Err(error),
        (_, Err(error)) => Err(format!("owned keyboard fixture cleanup failed: {error}")),
    }
}

async fn verify_keyboard_workspace(
    cx: &mut AsyncApp,
    profile: &Profile,
) -> Result<serde_json::Value, String> {
    let mut tabs = vec![profile.tab(&[0]), profile.tab(&[1])];
    for tab in &mut tabs {
        for pane in &mut tab.panes {
            pane.ai_provider = None;
            pane.ai_session_id = None;
            pane.ai_resume_command = None;
        }
    }
    cx.update(|cx| {
        let settings = cx.global_mut::<Settings>();
        settings.terminal.shell = Some(profile.shell.to_string_lossy().into_owned());
        settings.terminal.split_panes_enabled = true;
        settings.appearance.rendering.gpu_renderer = false;
        settings.appearance.rendering.suspend_background = false;
    });
    let (handle, ws) = cx
        .update(|cx| {
            gpui_kit::open_window(
                WindowOptions {
                    show: true,
                    focus: false,
                    // Use the same native titlebar and window policy as production.
                    ..super::window::window_options(
                        Some(Bounds::new(
                            gpui::point(px(0.), px(0.)),
                            size(px(1000.), px(600.)),
                        )),
                        cx,
                    )
                },
                cx,
                |window, cx| {
                    cx.new(|cx| {
                        Workspace::new(
                            Some(SavedWindow {
                                tabs,
                                selected: 0,
                                ..Default::default()
                            }),
                            window,
                            cx,
                        )
                    })
                },
            )
        })
        .map_err(error)?;
    let handle = handle
        .downcast::<Root>()
        .ok_or("owned keyboard window lacks Root")?;
    cx.update(|cx| {
        ws.update(cx, |ws, _| ws.window_handle = Some(handle.into()));
        cx.global_mut::<AppData>()
            .workspaces
            .push((handle.into(), ws.downgrade()));
    });
    let ids = cx.update(|cx| {
        ws.read(cx)
            .state
            .tabs()
            .iter()
            .map(|tab| tab.id)
            .collect::<Vec<_>>()
    });
    ensure(
        ids.len() == 2 && ids[0] != ids[1],
        "keyboard fixture did not create two uniquely identified saved tabs",
    )?;

    let native = native_window(handle, cx)?;
    let application = NSApplication::sharedApplication(
        MainThreadMarker::new().ok_or("keyboard fixture is not on main thread")?,
    );
    if application.activationPolicy() != NSApplicationActivationPolicy::Regular {
        application.setActivationPolicy(NSApplicationActivationPolicy::Regular);
    }
    native_mutation(|| native.makeKeyAndOrderFront(None))?;
    activate_owned_application(&application)?;
    wait_until(cx, "active keyboard fixture window", |_| {
        application.isActive() && native.isVisible() && native.isKeyWindow()
    })
    .await?;
    settle(handle, cx).await?;

    wait_until(cx, "first lazy PTY activation", |cx| {
        let ws = ws.read(cx);
        ws.state.selected() == Some(ids[0])
            && ws.entries[&ids[0]].panes.read(cx).pane_sessions(cx).len() == 1
    })
    .await?;
    let (first_session, first_pid) = cx.update(|cx| -> Result<_, String> {
        let workspace = ws.read(cx);
        let tree = workspace.entries[&ids[0]].panes.read(cx);
        ensure(
            tree.focused_pane_id() == Some(100),
            "first tab did not focus its owned terminal",
        )?;
        let session = tree
            .focused_session(cx)
            .ok_or("first tab lacks a focused terminal session")?;
        ensure(
            session.read(cx).selection_text().is_none(),
            "keyboard copy fixture unexpectedly has a terminal selection",
        )?;
        let pid = session.read(cx).shell_pid();
        ensure(pid > 0, "first owned keyboard shell has no PID")?;
        Ok((session, pid))
    })?;
    let first_started = profile.directories[0].join(format!("started.{first_pid}"));
    wait_until(cx, "first owned shell started", |_| first_started.exists()).await?;
    profile.release_prompt(0)?;
    wait_until(cx, "first owned shell prompt", |cx| {
        first_session.read(cx).is_at_prompt()
    })
    .await?;

    // Cmd+C with no selection follows the production terminal path that writes
    // ETX to the PTY. stty -isig keeps the fixture cat alive to record the byte.
    ensure_terminal_focus(handle, &ws, ids[0], cx)?;
    send_owned_key_event(&application, &native, "c", NSEventModifierFlags::Command, 8)?;
    let first_received = profile.directories[0].join(format!("received.{first_pid}"));
    wait_until(cx, "Cmd+C ETX reached owned PTY", |_| {
        std::fs::read(&first_received).is_ok_and(|bytes| bytes == vec![0x03])
    })
    .await?;
    ensure(
        cx.update(|cx| first_session.read(cx).exited.is_none()),
        "Cmd+C terminated the no-selection PTY instead of delivering ETX",
    )?;

    ensure_terminal_focus(handle, &ws, ids[0], cx)?;
    send_owned_key_event(
        &application,
        &native,
        "\t",
        NSEventModifierFlags::Control,
        48,
    )?;
    wait_until(cx, "Ctrl+Tab selected the next saved tab", |cx| {
        let workspace = ws.read(cx);
        workspace.state.selected() == Some(ids[1])
            && workspace.entries[&ids[1]]
                .panes
                .read(cx)
                .pane_sessions(cx)
                .len()
                == 1
    })
    .await?;
    settle(handle, cx).await?;
    let (second_session, second_pid) = cx.update(|cx| -> Result<_, String> {
        let workspace = ws.read(cx);
        let tree = workspace.entries[&ids[1]].panes.read(cx);
        ensure(
            tree.focused_pane_id() == Some(101),
            "next tab did not focus its saved terminal",
        )?;
        let session = tree
            .focused_session(cx)
            .ok_or("next tab lacks a focused terminal session")?;
        let pid = session.read(cx).shell_pid();
        ensure(pid > 0, "second owned keyboard shell has no PID")?;
        Ok((session, pid))
    })?;
    ensure(
        first_pid != second_pid,
        "saved tabs reused an owned shell PID",
    )?;
    let second_started = profile.directories[1].join(format!("started.{second_pid}"));
    wait_until(cx, "second owned shell started", |_| {
        second_started.exists()
    })
    .await?;
    profile.release_prompt(1)?;
    wait_until(cx, "second owned shell prompt", |cx| {
        second_session.read(cx).is_at_prompt()
    })
    .await?;

    ensure_terminal_focus(handle, &ws, ids[1], cx)?;
    send_owned_key_event(&application, &native, "d", NSEventModifierFlags::Command, 2)?;
    wait_until(cx, "Cmd+D created a horizontal terminal split", |cx| {
        let workspace = ws.read(cx);
        if workspace.state.selected() != Some(ids[1]) {
            return false;
        }
        let tree = workspace.entries[&ids[1]].panes.read(cx);
        let layout = tree.export_layout(cx);
        tree.pane_sessions(cx).len() == 2
            && tree.focused_pane_id().is_some_and(|pane| pane != 101)
            && matches!(
                layout,
                Some(SavedSplitNode::Split {
                    axis: SavedAxis::Horizontal,
                    ref children,
                    ..
                }) if children.len() == 2
            )
    })
    .await?;
    settle(handle, cx).await?;
    ensure_terminal_focus(handle, &ws, ids[1], cx)?;
    let (split_pids, focused_pid) = cx.update(|cx| -> Result<_, String> {
        let workspace = ws.read(cx);
        let tree = workspace.entries[&ids[1]].panes.read(cx);
        let layout = tree.export_layout(cx).ok_or("split layout was not saved")?;
        ensure(
            layout.terminal_ids().len() == 2,
            "horizontal split does not contain two terminal leaves",
        )?;
        match layout {
            SavedSplitNode::Split {
                axis: SavedAxis::Horizontal,
                ref children,
                ..
            } => ensure(
                children.len() == 2,
                "horizontal split has the wrong child count",
            )?,
            _ => return Err("Cmd+D did not create a horizontal split".into()),
        }
        let sessions = tree.pane_sessions(cx);
        ensure(sessions.len() == 2, "split tab does not have two live PTYs")?;
        let pids = sessions
            .iter()
            .map(|(_, session)| session.read(cx).shell_pid())
            .collect::<Vec<_>>();
        ensure(
            pids.iter().all(|pid| *pid > 0) && pids[0] != pids[1],
            "split terminals do not have distinct live shell PIDs",
        )?;
        let focused_id = tree
            .focused_pane_id()
            .ok_or("split has no focused terminal leaf")?;
        let focused = tree
            .focused_session(cx)
            .ok_or("split focus does not resolve to a terminal")?;
        let focused_pid = focused.read(cx).shell_pid();
        ensure(
            focused_id != 101 && focused_pid != second_pid,
            "Cmd+D did not focus the newly inserted terminal leaf",
        )?;
        ensure(
            pids.contains(&focused_pid),
            "focused split terminal is not one of the two live PTYs",
        )?;
        Ok((pids, focused_pid))
    })?;
    wait_until(cx, "both split shells at real prompts", |cx| {
        let workspace = ws.read(cx);
        let tree = workspace.entries[&ids[1]].panes.read(cx);
        let sessions = tree.pane_sessions(cx);
        sessions.len() == 2
            && sessions.iter().all(|(_, session)| {
                let session = session.read(cx);
                session.is_at_prompt()
                    && profile.directories[1]
                        .join(format!("started.{}", session.shell_pid()))
                        .exists()
            })
    })
    .await?;
    ensure(
        std::fs::read(&first_received).is_ok_and(|bytes| bytes == vec![0x03]),
        "later shortcuts changed the exact Cmd+C PTY byte",
    )?;
    ensure(
        cx.update(|cx| first_session.read(cx).exited.is_none()),
        "first owned PTY exited before fixture cleanup",
    )?;
    Ok(serde_json::json!({
        "saved_tabs": 2,
        "saved_tab_ids": [ids[0], ids[1]],
        "keyboard_dispatch": "NSApplication.sendEvent",
        "cmd_c_selection": "none",
        "cmd_c_received_bytes": [3],
        "ctrl_tab_changed_selected_id": true,
        "cmd_d_split_axis": "horizontal",
        "cmd_d_split_terminal_count": 2,
        "cmd_d_focused_new_leaf": true,
        "split_shells_started": split_pids.len(),
        "focused_shell_pid_is_split_child": split_pids.contains(&focused_pid) && focused_pid != second_pid,
        "synthetic_frames": false
    }))
}

pub(crate) async fn verify(cx: &mut AsyncApp) -> Result<serde_json::Value, String> {
    let home = cx.update(|cx| cx.global::<AppData>().root.home().to_path_buf());
    let profile = Profile::new(home)?;
    let mut tabs = vec![
        profile.tab(&[0]),
        profile.tab(&[1, 2]),
        profile.tab(&[3]),
        profile.tab(&[4]),
        profile.tab(&[5]),
        profile.tab(&[6]),
    ];
    // This scenario covers shell-free identity hydration in parked tabs. The
    // dedicated restore fixture covers eager background shells for saved input.
    for index in [0, 2, 3, 5] {
        tabs[index].panes[0].ai_resume_command = None;
    }
    // A genuine ordinary shell participates in the worker retention lifecycle.
    tabs[4].panes[0].ai_provider = None;
    tabs[4].panes[0].ai_session_id = None;
    tabs[4].panes[0].ai_resume_command = None;
    let stale = profile.home.clone();
    tabs[0].cwd = Some(stale.clone());
    tabs[0].panes[0].directory = Some(stale.to_string_lossy().into_owned());
    tabs[0].layout = Some(SavedSplitNode::Terminal {
        id: 100,
        directory: Some(stale.to_string_lossy().into_owned()),
    });
    let selected_layout = tabs[1].layout.clone().ok_or("fixture split missing")?;
    let selected_uuid = tabs[1].uuid.ok_or("fixture UUID missing")?;
    let previous_repo_grouping = cx.update(|cx| cx.global::<Settings>().tabs.repo_grouping);
    crate::restore::preparation::register_saved_identity_hints(&profile.root, tabs.iter());
    cx.update(|cx| {
        let settings = cx.global_mut::<Settings>();
        settings.tabs.repo_grouping = crate::settings::RepoGroupingMode::Auto;
        settings.terminal.shell = Some(profile.shell.to_string_lossy().into_owned());
        settings.appearance.rendering.gpu_renderer = false;
        settings.appearance.rendering.suspend_background = true;
        settings.appearance.rendering.suspend_delay_secs = 0.05;
    });
    let opened = cx.update(|cx| {
        let opened = gpui_kit::open_window(
            WindowOptions {
                show: true,
                focus: false,
                // Use the same native titlebar and window policy as production.
                ..super::window::window_options(
                    Some(Bounds::new(
                        gpui::point(px(0.), px(0.)),
                        size(px(1000.), px(600.)),
                    )),
                    cx,
                )
            },
            cx,
            |window, cx| {
                cx.new(|cx| {
                    Workspace::new(
                        Some(SavedWindow {
                            tabs,
                            selected: 1,
                            ..Default::default()
                        }),
                        window,
                        cx,
                    )
                })
            },
        );
        // Keep Auto active while Workspace initializes its grouping state, then
        // restore the process-wide setting before any later fixture can run.
        cx.global_mut::<Settings>().tabs.repo_grouping = previous_repo_grouping;
        opened
    });
    let (handle, ws) = opened.map_err(error)?;
    let handle = handle
        .downcast::<Root>()
        .ok_or("owned restore window lacks Root")?;
    // Use the same ownership registry as the ordinary open_workspace path.
    // Cleanup and memory selection must observe the actual owned Workspace.
    cx.update(|cx| {
        ws.update(cx, |ws, _| ws.window_handle = Some(handle.into()));
        cx.global_mut::<AppData>()
            .workspaces
            .push((handle.into(), ws.downgrade()));
    });
    let ids = cx.update(|cx| {
        ws.read(cx)
            .state
            .tabs()
            .iter()
            .map(|tab| tab.id)
            .collect::<Vec<_>>()
    });
    let metadata_event_count = std::sync::Arc::new(std::sync::atomic::AtomicUsize::new(0));
    let metadata_event_total_count = std::sync::Arc::new(std::sync::atomic::AtomicUsize::new(0));
    let _metadata_event_counter = cx.update(|cx| {
        let panes = ws.read(cx).entries[&ids[1]].panes.clone();
        let count = metadata_event_count.clone();
        let total_count = metadata_event_total_count.clone();
        let primary_root = profile.directories[1].clone();
        let presentation_root = profile.directories[2].clone();
        cx.new(|cx| {
            MetadataEventCounter::new(
                panes,
                count,
                total_count,
                primary_root,
                presentation_root,
                cx,
            )
        })
    });
    // Observe admission before yielding to the native platform. First layout
    // may itself take longer than 450ms, so a later fixed-delay check would
    // incorrectly reject an identity hydrated before that check even starts.
    let selection_at = Instant::now();
    let admitted_after = std::sync::Arc::new(parking_lot::Mutex::new(None));
    let observed_delay = admitted_after.clone();
    let expected_directory = profile.directories[0].clone();
    let parked_id = ids[0];
    let _admission_observer = cx.update(|cx| {
        cx.observe(&ws, move |ws, cx| {
            let repaired = ws.read(cx).entries[&parked_id]
                .panes
                .read(cx)
                .deferred_saved()
                .is_some_and(|saved| saved.cwd == Some(expected_directory.clone()));
            if repaired {
                observed_delay
                    .lock()
                    .get_or_insert_with(|| selection_at.elapsed());
            }
        })
    });
    // All selections occur in one actual window update before the first await.
    // No native paint cost can consume the quiet period before this fence.
    handle
        .update(cx, |_, window, cx| {
            ws.update(cx, |ws, cx| {
                ws.select_tab(ids[2], window, cx);
                ws.select_tab(ids[3], window, cx);
                ws.select_tab(ids[1], window, cx);
            })
        })
        .map_err(error)?;
    settle(handle, cx).await?;
    cx.update(|cx| -> Result<(), String> {
        let ws = ws.read(cx);
        ensure(
            ws.state.selected() == Some(ids[1]),
            "selected-first restore lost selection",
        )?;
        ensure(
            ws.state
                .get(ids[1])
                .is_some_and(|tab| tab.uuid == selected_uuid),
            "stable selected UUID changed",
        )?;
        for i in [0, 2, 3, 4, 5] {
            let tree = ws.entries[&ids[i]].panes.read(cx);
            ensure(
                tree.is_deferred() && tree.pane_sessions(cx).is_empty(),
                "parked restore created an unwanted PTY",
            )?;
        }
        Ok(())
    })?;
    wait_until(cx, "selected split PTY activation", |cx| {
        let ws = ws.read(cx);
        ws.state.selected() == Some(ids[1])
            && ws.entries[&ids[1]].panes.read(cx).pane_sessions(cx).len() == 2
    })
    .await?;
    let selected_panes = cx.update(
        |cx| -> Result<Vec<(u64, Entity<TerminalSession>)>, String> {
            let ws = ws.read(cx);
            ensure(
                ws.state.selected() == Some(ids[1]),
                "selected-first restore lost selection",
            )?;
            ensure(
                ws.state
                    .get(ids[1])
                    .is_some_and(|tab| tab.uuid == selected_uuid),
                "stable selected UUID changed",
            )?;
            for i in [0, 2, 3, 4, 5] {
                let tree = ws.entries[&ids[i]].panes.read(cx);
                ensure(
                    tree.is_deferred() && tree.pane_sessions(cx).is_empty(),
                    "parked restore created an unwanted PTY",
                )?;
            }
            let tree = ws.entries[&ids[1]].panes.read(cx);
            let actual = tree
                .export_layout(cx)
                .ok_or("restored split layout absent")?;
            ensure(
                actual.terminal_ids() == selected_layout.terminal_ids(),
                "split leaf IDs changed",
            )?;
            match (actual, &selected_layout) {
                (
                    SavedSplitNode::Split {
                        axis,
                        ratios,
                        children,
                        ..
                    },
                    SavedSplitNode::Split {
                        axis: expected_axis,
                        ratios: expected_ratios,
                        children: expected_children,
                        ..
                    },
                ) => {
                    ensure(
                        axis == *expected_axis
                            && ratios == *expected_ratios
                            && children == *expected_children,
                        "split geometry or paths changed",
                    )?;
                }
                _ => return Err("restored layout lost its split".into()),
            }
            ensure(
                tree.focused_pane_id() == Some(102),
                "focused split pane changed",
            )?;
            let sessions = tree.pane_sessions(cx);
            ensure(
                sessions.len() == 2,
                "selected split did not launch exactly two PTYs",
            )?;
            for (pane, session) in &sessions {
                let i = (*pane - 100) as usize;
                let session = session.read(cx);
                ensure(session.shell_pid() > 0, "owned shell has no native PID")?;
                ensure(
                    session.shell().ai_session_id() == Some(profile.ids[i].as_str()),
                    "saved provider identity changed",
                )?;
                ensure(
                    session.has_pending_restore_resume(),
                    "resume intent was not retained",
                )?;
            }
            Ok(sessions)
        },
    )?;
    wait_until(cx, "selected shells started", |_| {
        [1, 2]
            .into_iter()
            .all(|i| profile.directories[i].join("started").exists())
    })
    .await?;
    let primary_repo_root = profile.directories[1].to_string_lossy().into_owned();
    let presentation_repo_root = profile.directories[2].to_string_lossy().into_owned();
    // Require an observed production metadata transition after both restored
    // sessions exist. Saved identities may already hydrate roots and branches,
    // so create a real branch change in this isolated fixture's synthetic repos
    // instead of assuming a spontaneous event will occur.
    let expected_primary_branch =
        format!("native-fixture-primary-{}", uuid::Uuid::new_v4().simple());
    let expected_presentation_branch =
        format!("native-fixture-focused-{}", uuid::Uuid::new_v4().simple());
    std::fs::write(
        profile.directories[1].join(".git/HEAD"),
        format!("ref: refs/heads/{expected_primary_branch}\n"),
    )
    .map_err(error)?;
    std::fs::write(
        profile.directories[2].join(".git/HEAD"),
        format!("ref: refs/heads/{expected_presentation_branch}\n"),
    )
    .map_err(error)?;
    let metadata_reconciliation =
        wait_until(cx, "live split repository metadata reconciliation", |cx| {
            let workspace = ws.read(cx);
            let Some(meta) = workspace.state.get(ids[1]) else {
                return false;
            };
            let tree = workspace.entries[&ids[1]].panes.read(cx);
            let sessions = tree.pane_sessions(cx);
            workspace.state.selected() == Some(ids[1])
                && tree.focused_pane_id() == Some(102)
                && sessions.iter().any(|(pane, session)| {
                    *pane == 101
                        && session.read(cx).git_root.as_deref()
                            == Some(Path::new(&primary_repo_root))
                        && session.read(cx).git_branch.as_deref()
                            == Some(expected_primary_branch.as_str())
                })
                && sessions.iter().any(|(pane, session)| {
                    *pane == 102
                        && session.read(cx).git_root.as_deref()
                            == Some(Path::new(&presentation_repo_root))
                        && session.read(cx).git_branch.as_deref()
                            == Some(expected_presentation_branch.as_str())
                })
                && meta.git_root.as_deref() == Some(presentation_repo_root.as_str())
                && meta.primary_git_root.as_deref() == Some(primary_repo_root.as_str())
                && meta.presentation_git_root.as_deref() == Some(presentation_repo_root.as_str())
                && meta.repo_group_id.as_deref() == Some(primary_repo_root.as_str())
                && metadata_event_count.load(std::sync::atomic::Ordering::Relaxed) > 0
        })
        .await;
    if let Err(error) = metadata_reconciliation {
        let snapshot = cx.update(|cx| {
            let workspace = ws.read(cx);
            let tree = workspace.entries[&ids[1]].panes.read(cx);
            let sessions = tree
                .pane_sessions(cx)
                .into_iter()
                .map(|(pane, session)| {
                    let session = session.read(cx);
                    serde_json::json!({
                        "pane_id": pane,
                        "cwd": session.cwd.as_ref().map(|path| path.to_string_lossy().into_owned()),
                        "git_root": session.git_root.as_ref().map(|path| path.to_string_lossy().into_owned()),
                        "git_branch": session.git_branch,
                    })
                })
                .collect::<Vec<_>>();
            let meta = workspace.state.get(ids[1]).map(|meta| serde_json::json!({
                "git_root": meta.git_root,
                "primary_git_root": meta.primary_git_root,
                "presentation_git_root": meta.presentation_git_root,
                "repo_group_id": meta.repo_group_id,
                "has_inherited_repo_group": meta.has_inherited_repo_group,
            }));
            serde_json::json!({
                "error": error,
                "selected_tab": workspace.state.selected(),
                "focused_pane": tree.focused_pane_id(),
                "workspace_auto_repo_grouping": workspace.state.auto_repo_grouping,
                "global_repo_grouping_mode": format!("{:?}", cx.global::<Settings>().tabs.repo_grouping),
                "tab_metadata": meta,
                "sessions": sessions,
                "metadata_events_total": metadata_event_total_count.load(std::sync::atomic::Ordering::Relaxed),
                "metadata_events_with_both_expected_roots": metadata_event_count.load(std::sync::atomic::Ordering::Relaxed),
                "expected": {
                    "primary_root": primary_repo_root,
                    "presentation_root": presentation_repo_root,
                    "primary_branch": expected_primary_branch,
                    "presentation_branch": expected_presentation_branch,
                    "repo_group_id": primary_repo_root,
                }
            })
        });
        if let Ok(snapshot) = serde_json::to_string(&snapshot) {
            eprintln!("native_restore_metadata_reconciliation_failure={snapshot}");
        }
        return Err(error);
    }
    let automatic_grouping_summary = cx.update(|cx| {
        cx.global_mut::<Settings>().tabs.repo_grouping = crate::settings::RepoGroupingMode::Auto;
        let summary = (|| -> Result<serde_json::Value, String> {
            let workspace = ws.read(cx);
            ensure(
                workspace.state.selected() == Some(ids[1]),
                "automatic grouping changed selected tab",
            )?;
            let summary = workspace.mcp_summary(ids[1], cx);
            verify_grouping_summary(
                &summary,
                "auto",
                &primary_repo_root,
                &primary_repo_root,
                &presentation_repo_root,
            )?;
            Ok(serde_json::Value::Object(summary))
        })();
        cx.global_mut::<Settings>().tabs.repo_grouping = previous_repo_grouping;
        summary
    })?;
    let (manual_grouping_summary, restored_automatic_summary) =
        ws.update(cx, |workspace, cx| -> Result<_, String> {
            let transition = (|| -> Result<_, String> {
                cx.global_mut::<Settings>().tabs.repo_grouping =
                    crate::settings::RepoGroupingMode::Manual;
                workspace.state.set_auto_repo_grouping(false);
                workspace.state.add_to_repo_group(ids[1]);
                ensure(
                    workspace.state.selected() == Some(ids[1]),
                    "manual grouping changed selected tab",
                )?;
                ensure(
                    workspace
                        .state
                        .get(ids[1])
                        .and_then(|tab| tab.repo_group_id.as_deref())
                        == Some(presentation_repo_root.as_str()),
                    "manual grouping did not use the focused pane repository",
                )?;
                let manual_summary = workspace.mcp_summary(ids[1], cx);
                verify_grouping_summary(
                    &manual_summary,
                    "manual",
                    &presentation_repo_root,
                    &primary_repo_root,
                    &presentation_repo_root,
                )?;
                cx.global_mut::<Settings>().tabs.repo_grouping =
                    crate::settings::RepoGroupingMode::Auto;
                workspace.state.set_auto_repo_grouping(true);
                ensure(
                    workspace.state.selected() == Some(ids[1]),
                    "restoring automatic grouping changed selected tab",
                )?;
                ensure(
                    workspace
                        .state
                        .get(ids[1])
                        .and_then(|tab| tab.repo_group_id.as_deref())
                        == Some(primary_repo_root.as_str()),
                    "automatic grouping did not restore the primary repository",
                )?;
                let automatic_summary = workspace.mcp_summary(ids[1], cx);
                verify_grouping_summary(
                    &automatic_summary,
                    "auto",
                    &primary_repo_root,
                    &primary_repo_root,
                    &presentation_repo_root,
                )?;
                Ok((
                    serde_json::Value::Object(manual_summary),
                    serde_json::Value::Object(automatic_summary),
                ))
            })();
            cx.global_mut::<Settings>().tabs.repo_grouping = previous_repo_grouping;
            workspace.state.set_auto_repo_grouping(
                previous_repo_grouping == crate::settings::RepoGroupingMode::Auto,
            );
            transition
        })?;
    let split_repository_grouping = serde_json::json!({
        "metadata_event_count": metadata_event_count.load(std::sync::atomic::Ordering::Relaxed),
        "metadata_event_total_count": metadata_event_total_count.load(std::sync::atomic::Ordering::Relaxed),
        "metadata_transition": {
            "origin": "owned synthetic .git/HEAD branch change",
            "primary_branch": expected_primary_branch,
            "presentation_branch": expected_presentation_branch,
        },
        "selected_tab_preserved": true,
        "focused_pane_id": 102,
        "live_session_roots": {
            "primary_pane_101": primary_repo_root,
            "focused_pane_102": presentation_repo_root,
        },
        "automatic": automatic_grouping_summary,
        "manual": manual_grouping_summary,
        "automatic_restored": restored_automatic_summary,
    });
    wait_until(cx, "parked identity-only metadata", |cx| {
        let tree = ws.read(cx).entries[&ids[0]].panes.read(cx);
        tree.pane_sessions(cx).is_empty()
            && tree
                .deferred_saved()
                .is_some_and(|saved| saved.cwd == Some(profile.directories[0].clone()))
    })
    .await?;
    let admission_ms = admitted_after
        .lock()
        .as_ref()
        .map(Duration::as_millis)
        .ok_or("identity admission was not observed")?;
    ensure(
        admission_ms >= 450,
        "identity admitted before selection quiet period",
    )?;
    cx.update(|cx| -> Result<(), String> {
        for i in [0, 2, 3, 4, 5] {
            ensure(
                ws.read(cx).entries[&ids[i]]
                    .panes
                    .read(cx)
                    .pane_sessions(cx)
                    .is_empty(),
                "rapid selection or metadata hydration launched a parked shell",
            )?;
        }
        Ok(())
    })?;
    select(handle, &ws, ids[3], cx)?;
    settle(handle, cx).await?;
    verify_hover(handle, &ws, &ids, &selected_panes, cx).await?;
    let mut loading_clock = verify_loading_clock(handle, cx).await?;
    profile.release_prompt(1)?;
    profile.release_prompt(2)?;
    wait_until(cx, "native OSC133 readiness", |cx| {
        selected_panes
            .iter()
            .all(|(_, session)| session.read(cx).is_at_prompt())
    })
    .await?;
    // The actual one-second production readiness tick prefills both saved
    // commands while their tab remains unselected. No manual timer/PTY driver
    // is used here, and the recorder never executes the command.
    pause(cx, Duration::from_millis(1100)).await;
    wait_until(cx, "background native resume bytes", |_| {
        [1, 2].into_iter().all(|i| !profile.received(i).is_empty())
    })
    .await?;
    for i in [1, 2] {
        ensure(
            profile.received(i) == profile.resume_command(i).as_bytes(),
            "background prefill changed, duplicated or submitted a resume command",
        )?;
        ensure(
            !profile
                .received(i)
                .iter()
                .any(|byte| matches!(byte, b'\r' | b'\n')),
            "background prefill submitted a resume command",
        )?;
    }
    select(handle, &ws, ids[1], cx)?;
    settle(handle, cx).await?;
    pause(cx, Duration::from_millis(1100)).await;
    for i in [1, 2] {
        ensure(
            profile.received(i) == profile.resume_command(i).as_bytes(),
            "resume prefill repeated after next production tick",
        )?;
    }
    wait_until(cx, "loading clock stopped at real prompt", |cx| {
        loading_timers(cx).is_empty()
    })
    .await?;
    loading_clock["ready_active_timers"] = serde_json::json!(0);
    let surface = verify_surfaces(handle, &ws, &ids, &selected_panes, &profile, cx).await?;
    // Let every owned output subprocess finish before normal PTY disposal.
    for directory in &profile.directories {
        if directory.join("ready").exists() {
            std::fs::write(directory.join("hidden-output"), b"done").map_err(error)?;
        }
    }
    wait_until(cx, "owned output subprocess completion", |_| {
        profile.directories.iter().all(|directory| {
            !directory.join("ready").exists() || directory.join("output-child-done").exists()
        })
    })
    .await?;
    let closed = dispose(cx).await?;
    wait_until(cx, "loading clock cleanup", |cx| {
        loading_timers(cx).is_empty()
    })
    .await?;
    loading_clock["cleanup_active_timers"] = serde_json::json!(0);
    ensure(
        closed == 5,
        "cleanup did not close all five actual owned PTYs",
    )?;
    Ok(
        serde_json::json!({"restored_tabs":6,"selected_initial_ptys":2,"preserved_split_leaves":2,"native_identities":2,"quiet_period_ms":450,"observed_identity_admission_ms":admission_ms,"transient_selection_ptys":0,"parked_metadata_ptys":0,"resume_deliveries":2,"resume_providers":["claude","opencode"],"resume_line_terminators":0,"duplicate_deliveries":0,"closed_owned_ptys":closed,"surfaces":surface,"loading_clock":loading_clock,"split_repository_grouping":split_repository_grouping,"manual_polling":false,"simulated_frames":false}),
    )
}

/// Inspect the actual registry; fixture execution never creates a timer here.
fn loading_timers(cx: &App) -> Vec<serde_json::Value> {
    crate::observability::timer_inventory(cx)["timers"]
        .as_array()
        .into_iter()
        .flatten()
        .filter(|timer| {
            timer["active"] == true
                && timer["id"]
                    .as_str()
                    .is_some_and(|id| id.starts_with("shell.loading."))
        })
        .cloned()
        .collect()
}
fn loading_callback_samples() -> u64 {
    chau7_next_core::work_profiler::snapshot()["entries"]
        .as_array()
        .into_iter()
        .flatten()
        .filter(|entry| {
            entry["kind"] == "wakeup" && entry["operation"] == "shell_loading_animation"
        })
        .map(|entry| entry["lifetime"]["sample_count"].as_u64().unwrap_or(0))
        .sum()
}
async fn verify_loading_clock(
    handle: WindowHandle<Root>,
    cx: &mut AsyncApp,
) -> Result<serde_json::Value, String> {
    let native = native_window(handle, cx)?;
    wait_until(cx, "one visible loading clock", |cx| {
        loading_timers(cx).len() == 1
    })
    .await?;
    let initial = cx.update(|cx| loading_timers(cx));
    ensure(initial[0]["interval_ms"] == 80, "loading clock is not 80ms")?;
    let samples_before = loading_callback_samples();
    native_mutation(|| native.orderOut(None))?;
    wait_until(cx, "loading clock cancellation while ordered out", |cx| {
        !native.isVisible() && loading_timers(cx).is_empty()
    })
    .await?;
    let hidden_samples = loading_callback_samples();
    // Allow more than two ordinary intervals, proving the cancelled clock
    // stays dormant instead of repeatedly waking the hidden workspace.
    pause(cx, Duration::from_millis(240)).await;
    ensure(
        loading_callback_samples() == hidden_samples,
        "hidden workspace continued running loading callbacks",
    )?;
    native_mutation(|| native.orderFront(None))?;
    settle(handle, cx).await?;
    wait_until(cx, "one replacement loading clock", |cx| {
        native.isVisible() && loading_timers(cx).len() == 1
    })
    .await?;
    pause(cx, Duration::from_millis(320)).await;
    let shown = cx.update(|cx| loading_timers(cx));
    ensure(
        shown.len() == 1 && shown[0]["interval_ms"] == 80,
        "replacement clock was duplicated or deactivated by its old generation",
    )?;
    let samples_after = loading_callback_samples();
    ensure(
        samples_after > hidden_samples && samples_after > samples_before,
        "real loading callbacks produced no profiler samples",
    )?;
    Ok(
        serde_json::json!({"interval_ms":80,"initial_active_timers":1,
        "hidden_active_timers":0,"shown_active_timers":1,
        "hidden_callback_delta":0,"observed_callback_samples":samples_after-samples_before,
        "callback_cost_unit":"wall_ms","timer_wait_in_callback_cost":false}),
    )
}

async fn verify_hover(
    handle: WindowHandle<Root>,
    ws: &Entity<Workspace>,
    ids: &[TabId],
    sessions: &[(u64, Entity<TerminalSession>)],
    cx: &mut AsyncApp,
) -> Result<(), String> {
    handle
        .update(cx, |_, _, cx| {
            ws.update(cx, |ws, cx| {
                ws.hover_tab(ids[1], true, None, cx);
            })
        })
        .map_err(error)?;
    cx.update(|cx| -> Result<(), String> {
        for (_, session) in sessions {
            ensure(
                session
                    .read(cx)
                    .surface_prewarm_remaining()
                    .is_some_and(|remaining| {
                        remaining <= Duration::from_secs(2)
                            && remaining >= Duration::from_millis(1500)
                    }),
                "existing hidden split did not receive the two-second hover budget",
            )?;
            ensure(
                !session.read(cx).is_render_suspended(),
                "hover did not wake hidden rendering",
            )?;
        }
        Ok(())
    })?;
    pause(cx, Duration::from_millis(2150)).await;
    cx.update(|cx| -> Result<(), String> {
        ensure(
            sessions
                .iter()
                .all(|(_, s)| s.read(cx).surface_prewarm_remaining().is_none()),
            "hover budget exceeded its two-second deadline",
        )
    })?;
    handle
        .update(cx, |_, _, cx| {
            ws.update(cx, |ws, cx| {
                ws.hover_tab(ids[1], true, None, cx);
                ws.hover_tab(ids[1], false, None, cx);
                ws.hover_tab(ids[0], true, None, cx);
            })
        })
        .map_err(error)?;
    cx.update(|cx| -> Result<(), String> {
        ensure(
            sessions.iter().all(|(_, s)| {
                s.read(cx)
                    .surface_prewarm_remaining()
                    .is_some_and(|remaining| remaining <= Duration::from_millis(500))
            }),
            "hover exit did not shorten the budget to 500ms",
        )?;
        ensure(
            ws.read(cx).entries[&ids[0]].panes.read(cx).is_deferred()
                && ws.read(cx).entries[&ids[0]]
                    .panes
                    .read(cx)
                    .pane_sessions(cx)
                    .is_empty(),
            "hovering a parked restore created a PTY",
        )
    })?;
    handle
        .update(cx, |_, _, cx| {
            ws.update(cx, |ws, cx| {
                ws.hover_tab(ids[0], false, None, cx);
            })
        })
        .map_err(error)?;
    pause(cx, Duration::from_millis(650)).await;
    wait_until(cx, "hidden hover deadline suspension", |cx| {
        sessions.iter().all(|(_, s)| {
            s.read(cx).surface_prewarm_remaining().is_none() && s.read(cx).is_render_suspended()
        })
    })
    .await
}

fn ensure_terminal_focus(
    handle: WindowHandle<Root>,
    ws: &Entity<Workspace>,
    tab_id: TabId,
    cx: &mut AsyncApp,
) -> Result<(), String> {
    let focused = handle
        .update(cx, |_, window, cx| {
            ws.update(cx, |ws, cx| {
                ws.entries[&tab_id]
                    .panes
                    .read(cx)
                    .focused_view()
                    .is_some_and(|view| view.read(cx).focus_handle(cx).is_focused(window))
            })
        })
        .map_err(error)?;
    ensure(focused, "owned terminal does not hold GPUI input focus")
}

fn native_window(
    handle: WindowHandle<Root>,
    cx: &mut AsyncApp,
) -> Result<Retained<NSWindow>, String> {
    handle
        .update(cx, |_, window, _| {
            let raw = HasWindowHandle::window_handle(window).map_err(error)?;
            let RawWindowHandle::AppKit(raw) = raw.as_raw() else {
                return Err("owned window lacks AppKit handle".into());
            };
            // SAFETY: GPUI owns this view throughout the real window's lifetime;
            // retaining it is confined to the platform's main-thread fixture.
            let view = unsafe { Retained::retain(raw.ns_view.cast::<NSView>().as_ptr()) }
                .ok_or("owned native view disappeared")?;
            view.window()
                .ok_or("owned native view lacks NSWindow".into())
        })
        .map_err(error)?
}

fn native_gpui_view(
    handle: WindowHandle<Root>,
    cx: &mut AsyncApp,
) -> Result<Retained<NSView>, String> {
    handle
        .update(cx, |_, window, _| -> Result<Retained<NSView>, String> {
            let raw = HasWindowHandle::window_handle(window).map_err(error)?;
            let RawWindowHandle::AppKit(raw) = raw.as_raw() else {
                return Err("owned window lacks AppKit renderer view".into());
            };
            // SAFETY: GPUI owns this renderer view for the lifetime of the
            // fixture window; the retained handle is only used on AppKit's main thread.
            unsafe { Retained::retain(raw.ns_view.cast::<NSView>().as_ptr()) }
                .ok_or_else(|| "owned GPUI renderer view disappeared".to_owned())
        })
        .map_err(error)?
}

fn native_menu_bar_visible() -> Result<bool, String> {
    let mtm = MainThreadMarker::new().ok_or("menu bar query is not on the main thread")?;
    Ok(NSMenu::menuBarVisible(mtm))
}

fn set_native_menu_bar_visible(visible: bool) -> Result<(), String> {
    let mtm = MainThreadMarker::new().ok_or("menu bar mutation is not on the main thread")?;
    native_mutation(|| NSMenu::setMenuBarVisible(visible, mtm))
}

async fn wait_for_menu_bar_visibility(cx: &AsyncApp, expected: bool) -> Result<(), String> {
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        if native_menu_bar_visible()? == expected {
            return Ok(());
        }
        if Instant::now() >= deadline {
            return Err(format!(
                "owned native fixture deadline: menu bar visibility {expected}"
            ));
        }
        pause(cx, Duration::from_millis(10)).await;
    }
}

#[derive(Clone, Copy)]
struct FullscreenScreenGeometry {
    frame: objc2_foundation::NSRect,
    safe_area_insets: NSEdgeInsets,
    menu_bar_height: f64,
    menu_bar_frame: objc2_foundation::NSRect,
}

impl FullscreenScreenGeometry {
    fn capture(native: &NSWindow, application: &NSApplication) -> Result<Self, String> {
        let screen: *mut AnyObject = unsafe { objc2::msg_send![native, screen] };
        ensure(!screen.is_null(), "owned fullscreen window has no NSScreen")?;
        let screen = unsafe { &*screen };
        let frame: objc2_foundation::NSRect = unsafe { objc2::msg_send![screen, frame] };
        let safe_area_insets: NSEdgeInsets = unsafe { objc2::msg_send![screen, safeAreaInsets] };
        let menu_bar_height = application
            .mainMenu()
            .ok_or("owned fullscreen application has no main menu")?
            .menuBarHeight();
        ensure(
            menu_bar_height.is_finite() && menu_bar_height >= 0.0,
            "AppKit returned an invalid main menu bar height",
        )?;
        let menu_bar_frame = objc2_foundation::NSRect::new(
            NSPoint::new(
                frame.origin.x,
                frame.origin.y + frame.size.height - menu_bar_height,
            ),
            objc2_foundation::NSSize::new(frame.size.width, menu_bar_height),
        );
        Ok(Self {
            frame,
            safe_area_insets,
            menu_bar_height,
            menu_bar_frame,
        })
    }
}

#[derive(Clone, Copy)]
struct FullscreenMenuGeometry {
    window_frame: objc2_foundation::NSRect,
    content_layout_rect: objc2_foundation::NSRect,
    content_view_frame: objc2_foundation::NSRect,
    content_view_bounds: objc2_foundation::NSRect,
    renderer_frame: objc2_foundation::NSRect,
    renderer_bounds: objc2_foundation::NSRect,
    screen: FullscreenScreenGeometry,
    renderer_rect_in_screen: objc2_foundation::NSRect,
    menu_bar_overlaps_renderer: bool,
}

impl FullscreenMenuGeometry {
    fn capture(
        native: &NSWindow,
        application: &NSApplication,
        content_view: &NSView,
        renderer: &NSView,
    ) -> Result<Self, String> {
        let screen = FullscreenScreenGeometry::capture(native, application)?;
        let renderer_rect_in_window = renderer.convertRect_toView(renderer.bounds(), None);
        let renderer_rect_in_screen = native.convertRectToScreen(renderer_rect_in_window);
        Ok(Self {
            window_frame: native.frame(),
            content_layout_rect: native.contentLayoutRect(),
            content_view_frame: content_view.frame(),
            content_view_bounds: content_view.bounds(),
            renderer_frame: renderer.frame(),
            renderer_bounds: renderer.bounds(),
            menu_bar_overlaps_renderer: native_rects_intersect(
                screen.menu_bar_frame,
                renderer_rect_in_screen,
            ),
            screen,
            renderer_rect_in_screen,
        })
    }

    fn delta(self, after: Self) -> serde_json::Value {
        serde_json::json!({
            "window_frame": native_rect_delta(self.window_frame, after.window_frame),
            "content_layout_rect": native_rect_delta(self.content_layout_rect, after.content_layout_rect),
            "content_view_frame": native_rect_delta(self.content_view_frame, after.content_view_frame),
            "content_view_bounds": native_rect_delta(self.content_view_bounds, after.content_view_bounds),
            "renderer_frame": native_rect_delta(self.renderer_frame, after.renderer_frame),
            "renderer_bounds": native_rect_delta(self.renderer_bounds, after.renderer_bounds),
            "screen_frame": native_rect_delta(self.screen.frame, after.screen.frame),
            "safe_area_insets": [
                after.screen.safe_area_insets.top - self.screen.safe_area_insets.top,
                after.screen.safe_area_insets.left - self.screen.safe_area_insets.left,
                after.screen.safe_area_insets.bottom - self.screen.safe_area_insets.bottom,
                after.screen.safe_area_insets.right - self.screen.safe_area_insets.right,
            ],
            "menu_bar_height": after.screen.menu_bar_height - self.screen.menu_bar_height,
            "menu_bar_frame": native_rect_delta(self.screen.menu_bar_frame, after.screen.menu_bar_frame),
            "renderer_rect_in_screen": native_rect_delta(self.renderer_rect_in_screen, after.renderer_rect_in_screen),
            "menu_bar_overlaps_renderer_changed": self.menu_bar_overlaps_renderer != after.menu_bar_overlaps_renderer,
        })
    }
}

fn native_rects_intersect(left: objc2_foundation::NSRect, right: objc2_foundation::NSRect) -> bool {
    left.origin.x < right.origin.x + right.size.width
        && right.origin.x < left.origin.x + left.size.width
        && left.origin.y < right.origin.y + right.size.height
        && right.origin.y < left.origin.y + left.size.height
}

fn native_rect_delta(
    before: objc2_foundation::NSRect,
    after: objc2_foundation::NSRect,
) -> [f64; 4] {
    [
        after.origin.x - before.origin.x,
        after.origin.y - before.origin.y,
        after.size.width - before.size.width,
        after.size.height - before.size.height,
    ]
}

struct FullscreenMenuEvidence {
    geometry: FullscreenMenuGeometry,
    report: serde_json::Value,
    sample_rgb: Vec<[f64; 3]>,
}

fn renderer_image_crop_rect(
    image: &image::RgbaImage,
    renderer_bounds: objc2_foundation::NSRect,
    crop: objc2_foundation::NSRect,
    renderer_is_flipped: bool,
) -> Result<(u32, u32, u32, u32), String> {
    let width = image.width();
    let height = image.height();
    ensure(
        width > 0 && height > 0 && width <= 16_384 && height <= 16_384,
        "owned GPUI scene image has invalid dimensions",
    )?;
    ensure(
        renderer_bounds.size.width.is_finite()
            && renderer_bounds.size.height.is_finite()
            && renderer_bounds.size.width > 0.0
            && renderer_bounds.size.height > 0.0,
        "owned GPUI renderer has invalid dimensions for scene crop",
    )?;

    let scale_x = width as f64 / renderer_bounds.size.width;
    let scale_y = height as f64 / renderer_bounds.size.height;
    let crop_left = crop.origin.x - renderer_bounds.origin.x;
    let crop_top = if renderer_is_flipped {
        crop.origin.y - renderer_bounds.origin.y
    } else {
        renderer_bounds.origin.y + renderer_bounds.size.height - (crop.origin.y + crop.size.height)
    };
    let left = (crop_left * scale_x).floor().clamp(0.0, width as f64) as u32;
    let top = (crop_top * scale_y).floor().clamp(0.0, height as f64) as u32;
    let right = ((crop_left + crop.size.width) * scale_x)
        .ceil()
        .clamp(0.0, width as f64) as u32;
    let bottom = ((crop_top + crop.size.height) * scale_y)
        .ceil()
        .clamp(0.0, height as f64) as u32;
    ensure(
        right > left && bottom > top,
        "owned GPUI tabbar crop does not intersect the rendered scene",
    )?;
    ensure(
        (right - left) as usize * (bottom - top) as usize <= 4 * 1024 * 1024,
        "owned GPUI tabbar scene crop exceeds the fixture capture limit",
    )?;
    Ok((left, top, right - left, bottom - top))
}

fn fullscreen_menu_snapshot(
    stage: &'static str,
    expected_menu_visible: bool,
    application: &NSApplication,
    native: &NSWindow,
    handle: WindowHandle<Root>,
    cx: &mut AsyncApp,
) -> Result<FullscreenMenuEvidence, String> {
    let menu_bar_visible = native_menu_bar_visible()?;
    let app_active = application.isActive();
    let window_visible = native.isVisible();
    let window_key = native.isKeyWindow();
    let window_fullscreen = native.styleMask().contains(NSWindowStyleMask::FullScreen);
    let titlebar_transparent = native.titlebarAppearsTransparent();
    let renderer = native_gpui_view(handle, cx)?;
    let content_view = native
        .contentView()
        .ok_or("owned fullscreen window has no content view")?;
    let geometry = FullscreenMenuGeometry::capture(native, application, &content_view, &renderer)?;
    let renderer_bounds = renderer.bounds();
    let renderer_visible_rect = renderer.visibleRect();
    let renderer_bounds_finite = [
        renderer_bounds.origin.x,
        renderer_bounds.origin.y,
        renderer_bounds.size.width,
        renderer_bounds.size.height,
    ]
    .iter()
    .all(|value| value.is_finite());
    let crop_height = if renderer_bounds.size.height.is_finite() {
        renderer_bounds.size.height.clamp(0.0, 34.0)
    } else {
        0.0
    };
    let crop_x = if renderer_bounds.origin.x.is_finite() {
        renderer_bounds.origin.x + 80.0
    } else {
        0.0
    };
    let crop_width = if renderer_bounds.size.width.is_finite() {
        (renderer_bounds.size.width - 80.0).clamp(0.0, 1000.0)
    } else {
        0.0
    };
    let crop_y = if renderer_bounds_finite && renderer.isFlipped() {
        renderer_bounds.origin.y
    } else if renderer_bounds_finite {
        renderer_bounds.origin.y + renderer_bounds.size.height - crop_height
    } else {
        0.0
    };
    let crop = objc2_foundation::NSRect::new(
        NSPoint::new(crop_x, crop_y),
        objc2_foundation::NSSize::new(crop_width, crop_height),
    );
    let crop_in_bounds = rect_contains_with_tolerance(renderer_bounds, crop);
    let crop_visible = rect_contains_with_tolerance(renderer_visible_rect, crop);
    let renderer_rect_in_content =
        renderer.convertRect_toView(renderer_bounds, Some(&content_view));
    let owned_window_number = native.windowNumber();

    // Emit native numeric geometry before any state, visibility, or occlusion
    // assertion, so a failed reveal still says what AppKit and GPUI reported.
    // The diagnostic is limited to this fixture window and its own views.
    eprintln!(
        "native_fullscreen_menu_geometry={}",
        serde_json::json!({
            "stage": stage,
            "expected_menu_bar_visible": expected_menu_visible,
            "menu_bar_visible": menu_bar_visible,
            "app_active": app_active,
            "window_visible": window_visible,
            "window_key": window_key,
            "window_fullscreen": window_fullscreen,
            "titlebar_appears_transparent": titlebar_transparent,
            "window_number": owned_window_number,
            "window_frame": native_rect_values(geometry.window_frame),
            "content_layout_rect": native_rect_values(geometry.content_layout_rect),
            "content_view_frame": native_rect_values(geometry.content_view_frame),
            "content_view_bounds": native_rect_values(geometry.content_view_bounds),
            "renderer_frame": native_rect_values(geometry.renderer_frame),
            "renderer_bounds": native_rect_values(geometry.renderer_bounds),
            "renderer_rect_in_content_view": native_rect_values(renderer_rect_in_content),
            "renderer_rect_in_screen": native_rect_values(geometry.renderer_rect_in_screen),
            "renderer_visible_rect": native_rect_values(renderer_visible_rect),
            "screen_frame": native_rect_values(geometry.screen.frame),
            "screen_safe_area_insets": {
                "top": geometry.screen.safe_area_insets.top,
                "left": geometry.screen.safe_area_insets.left,
                "bottom": geometry.screen.safe_area_insets.bottom,
                "right": geometry.screen.safe_area_insets.right,
            },
            "main_menu_bar_height": geometry.screen.menu_bar_height,
            "menu_bar_band_frame": native_rect_values(geometry.screen.menu_bar_frame),
            "menu_bar_band_overlaps_renderer": geometry.menu_bar_overlaps_renderer,
            "screen_top_minus_window_top": geometry.screen.frame.origin.y
                + geometry.screen.frame.size.height
                - geometry.window_frame.origin.y
                - geometry.window_frame.size.height,
            "renderer_is_flipped": renderer.isFlipped(),
            "renderer_bounds_finite": renderer_bounds_finite,
            "tabbar_crop_rect": native_rect_values(crop),
            "tabbar_crop_in_renderer_bounds": crop_in_bounds,
            "tabbar_crop_in_renderer_visible_rect": crop_visible,
        })
    );

    ensure(
        renderer_bounds_finite,
        "owned GPUI renderer has non-finite bounds during fullscreen menu reveal",
    )?;

    // Recompute the tabbar hit point from this state's renderer coordinates;
    // menu reveal can change AppKit's content geometry between snapshots.
    let hit_x = if crop.size.width >= 240.0 {
        crop.origin.x + 120.0
    } else {
        crop.origin.x + crop.size.width / 2.0
    };
    let hit_in_renderer = objc2_foundation::NSRect::new(
        NSPoint::new(hit_x, crop.origin.y + crop.size.height / 2.0),
        objc2_foundation::NSSize::new(0.0, 0.0),
    );
    let hit_in_window = renderer.convertRect_toView(hit_in_renderer, None);
    let hit_on_screen = native.convertRectToScreen(hit_in_window);
    let hit_point = NSPoint::new(hit_on_screen.origin.x, hit_on_screen.origin.y);
    let mtm = MainThreadMarker::new().ok_or("fullscreen hit-test is not on the main thread")?;
    let frontmost_window =
        NSWindow::windowNumberAtPoint_belowWindowWithWindowNumber(hit_point, 0, mtm);
    eprintln!(
        "native_fullscreen_menu_hit_test={}",
        serde_json::json!({
            "stage": stage,
            "renderer_point": [hit_x, hit_in_renderer.origin.y],
            "screen_point": [hit_point.x, hit_point.y],
            "topmost_window_number": frontmost_window,
            "owned_window_number": owned_window_number,
            "owned_window_is_frontmost": frontmost_window == owned_window_number,
            "method": "NSWindow.windowNumberAtPoint_belowWindowWithWindowNumber",
            "scope": "compares only the hit result with the owned fixture window; no other window metadata is read",
        })
    );

    ensure(
        app_active && window_visible && window_key && window_fullscreen,
        "menu reveal snapshot requires the owned active fullscreen window",
    )?;
    ensure(
        menu_bar_visible == expected_menu_visible,
        "native menu bar did not reach the requested reveal state",
    )?;
    ensure(
        titlebar_transparent,
        "custom titlebar stopped being transparent during fullscreen menu reveal",
    )?;
    ensure(
        crop_width >= 160.0 && crop_height >= 20.0,
        "owned GPUI renderer is too small to contain the fullscreen tab bar",
    )?;
    ensure(
        crop_in_bounds && crop_visible,
        "owned GPUI tab bar crop is clipped during fullscreen menu reveal",
    )?;
    ensure(
        frontmost_window == owned_window_number,
        &format!(
            "owned fullscreen tab bar is occluded at its hit-test point: topmost window {frontmost_window}, owned window {owned_window_number}"
        ),
    )?;

    const SAMPLE_COLUMNS: usize = 32;
    const SAMPLE_ROWS: usize = 4;
    let renderer_backend = handle
        .update(cx, |_, window, _| {
            window
                .renderer_diagnostics()
                .map(|diagnostics| diagnostics.backend)
        })
        .map_err(error)?
        .ok_or("owned GPUI renderer diagnostics are unavailable")?;

    let (pixel_width, pixel_height, sample_rgb, visible_samples, png_bytes, capture_source) =
        match renderer_backend {
            "software" => {
                let color_space = NSColorSpace::sRGBColorSpace();
                let bitmap = renderer
                    .bitmapImageRepForCachingDisplayInRect(crop)
                    .and_then(|bitmap| bitmap.bitmapImageRepByRetaggingWithColorSpace(&color_space))
                    .ok_or("owned software fullscreen tabbar crop allocation failed")?;
                let pixel_width = u32::try_from(bitmap.pixelsWide()).map_err(error)?;
                let pixel_height = u32::try_from(bitmap.pixelsHigh()).map_err(error)?;
                ensure(
                    pixel_width > 0
                        && pixel_height > 0
                        && pixel_width <= 8192
                        && pixel_height <= 512,
                    "owned software fullscreen tabbar crop has invalid dimensions",
                )?;
                let bytes = usize::try_from(bitmap.bytesPerPlane()).map_err(error)?;
                ensure(
                    bitmap.numberOfPlanes() == 1
                        && !bitmap.bitmapData().is_null()
                        && bytes > 0
                        && bytes <= 64 * 1024 * 1024,
                    "owned software fullscreen tabbar crop has invalid storage",
                )?;
                renderer.cacheDisplayInRect_toBitmapImageRep(crop, &bitmap);

                let mut sample_rgb = Vec::with_capacity(SAMPLE_COLUMNS * SAMPLE_ROWS);
                let mut visible_samples = 0_usize;
                for row in 0..SAMPLE_ROWS {
                    let y = ((((row as f64) + 0.5) / SAMPLE_ROWS as f64) * pixel_height as f64)
                        .floor()
                        .min((pixel_height - 1) as f64) as u32;
                    for column in 0..SAMPLE_COLUMNS {
                        let x = ((((column as f64) + 0.5) / SAMPLE_COLUMNS as f64)
                            * pixel_width as f64)
                            .floor()
                            .min((pixel_width - 1) as f64) as u32;
                        let color = bitmap
                            .colorAtX_y(x as isize, y as isize)
                            .and_then(|color| color.colorUsingColorSpace(&color_space))
                            .ok_or(
                                "owned software fullscreen tabbar crop has an unreadable pixel",
                            )?;
                        let rgb = [
                            color.redComponent(),
                            color.greenComponent(),
                            color.blueComponent(),
                        ];
                        if rgb.iter().copied().fold(0.0_f64, f64::max) > 0.015 {
                            visible_samples += 1;
                        }
                        sample_rgb.push(rgb);
                    }
                }
                let rgba = image::RgbaImage::from_fn(pixel_width, pixel_height, |x, y| {
                    let color = bitmap
                        .colorAtX_y(x as isize, y as isize)
                        .and_then(|color| color.colorUsingColorSpace(&color_space));
                    let byte = |value: f64| (value.clamp(0.0, 1.0) * 255.0).round() as u8;
                    match color {
                        Some(color) => image::Rgba([
                            byte(color.redComponent()),
                            byte(color.greenComponent()),
                            byte(color.blueComponent()),
                            byte(color.alphaComponent()),
                        ]),
                        None => image::Rgba([0, 0, 0, 0]),
                    }
                });
                let mut png = std::io::Cursor::new(Vec::new());
                image::DynamicImage::ImageRgba8(rgba)
                    .write_to(&mut png, image::ImageFormat::Png)
                    .map_err(error)?;
                (
                    pixel_width,
                    pixel_height,
                    sample_rgb,
                    visible_samples,
                    png.into_inner(),
                    "AppKit cacheDisplayInRect on the owned software-backed GPUI view",
                )
            }
            "metal" => {
                let frame_image = handle
                    .update(cx, |_, window, _| -> Result<image::RgbaImage, String> {
                        window.render_to_image().map_err(error)
                    })
                    .map_err(error)??;
                let (left, top, pixel_width, pixel_height) = renderer_image_crop_rect(
                    &frame_image,
                    renderer_bounds,
                    crop,
                    renderer.isFlipped(),
                )?;
                ensure(
                    pixel_width <= 8192 && pixel_height <= 512,
                    "owned Metal fullscreen tabbar crop has invalid dimensions",
                )?;
                let crop_image =
                    image::imageops::crop_imm(&frame_image, left, top, pixel_width, pixel_height)
                        .to_image();
                let mut sample_rgb = Vec::with_capacity(SAMPLE_COLUMNS * SAMPLE_ROWS);
                let mut visible_samples = 0_usize;
                for row in 0..SAMPLE_ROWS {
                    let y = ((((row as f64) + 0.5) / SAMPLE_ROWS as f64) * pixel_height as f64)
                        .floor()
                        .min((pixel_height - 1) as f64) as u32;
                    for column in 0..SAMPLE_COLUMNS {
                        let x = ((((column as f64) + 0.5) / SAMPLE_COLUMNS as f64)
                            * pixel_width as f64)
                            .floor()
                            .min((pixel_width - 1) as f64) as u32;
                        let pixel = crop_image.get_pixel(x, y).0;
                        let rgb = [
                            pixel[0] as f64 / 255.0,
                            pixel[1] as f64 / 255.0,
                            pixel[2] as f64 / 255.0,
                        ];
                        if rgb.iter().copied().fold(0.0_f64, f64::max) > 0.015 {
                            visible_samples += 1;
                        }
                        sample_rgb.push(rgb);
                    }
                }
                let mut png = std::io::Cursor::new(Vec::new());
                image::DynamicImage::ImageRgba8(crop_image)
                    .write_to(&mut png, image::ImageFormat::Png)
                    .map_err(error)?;
                (
                    pixel_width,
                    pixel_height,
                    sample_rgb,
                    visible_samples,
                    png.into_inner(),
                    "Window::render_to_image offscreen rerender of the current GPUI scene; not AppKit composition",
                )
            }
            _ => return Err("owned fullscreen fixture selected an unknown GPUI renderer".into()),
        };
    ensure(
        visible_samples >= sample_rgb.len() / 2,
        "owned fullscreen tabbar renderer crop is black or missing",
    )?;
    let mean_rgb: [f64; 3] = std::array::from_fn(|channel| {
        sample_rgb.iter().map(|pixel| pixel[channel]).sum::<f64>() / sample_rgb.len() as f64
    });
    use base64::Engine as _;

    let renderer_rect_in_content =
        renderer.convertRect_toView(renderer_bounds, Some(&content_view));
    let report = serde_json::json!({
        "stage": stage,
        "menu_bar_visible": menu_bar_visible,
        "app_active": app_active,
        "window_visible": window_visible,
        "window_key": window_key,
        "window_fullscreen": window_fullscreen,
        "titlebar_appears_transparent": titlebar_transparent,
        "window_number": owned_window_number,
        "window_frame": native_rect_values(geometry.window_frame),
        "content_layout_rect": native_rect_values(geometry.content_layout_rect),
        "content_view_frame": native_rect_values(geometry.content_view_frame),
        "content_view_bounds": native_rect_values(geometry.content_view_bounds),
        "renderer_frame": native_rect_values(geometry.renderer_frame),
        "renderer_bounds": native_rect_values(geometry.renderer_bounds),
        "renderer_rect_in_content_view": native_rect_values(renderer_rect_in_content),
        "renderer_rect_in_screen": native_rect_values(geometry.renderer_rect_in_screen),
        "renderer_visible_rect": native_rect_values(renderer.visibleRect()),
        "screen": {
            "frame": native_rect_values(geometry.screen.frame),
            "safe_area_insets": {
                "top": geometry.screen.safe_area_insets.top,
                "left": geometry.screen.safe_area_insets.left,
                "bottom": geometry.screen.safe_area_insets.bottom,
                "right": geometry.screen.safe_area_insets.right,
            },
            "main_menu_bar_height": geometry.screen.menu_bar_height,
            "menu_bar_band_frame": native_rect_values(geometry.screen.menu_bar_frame),
            "menu_bar_band_overlaps_renderer": geometry.menu_bar_overlaps_renderer,
            "screen_top_minus_window_top": geometry.screen.frame.origin.y
                + geometry.screen.frame.size.height
                - geometry.window_frame.origin.y
                - geometry.window_frame.size.height,
        },
        "renderer_is_flipped": renderer.isFlipped(),
        "renderer_backend": renderer_backend,
        "tabbar_crop_in_renderer_bounds": crop_in_bounds,
        "tabbar_crop_in_renderer_visible_rect": crop_visible,
        "tabbar_hit_test": {
            "screen_point": [hit_point.x, hit_point.y],
            "topmost_window_number": frontmost_window,
            "owned_window_number": owned_window_number,
            "owned_window_is_frontmost": frontmost_window == owned_window_number,
            "method": "NSWindow.windowNumberAtPoint_belowWindowWithWindowNumber",
            "scope": "compares only the hit result with the owned fixture window; no other window metadata is read",
        },
        "owned_renderer_crop": {
            "rect": native_rect_values(crop),
            "pixel_size": [pixel_width, pixel_height],
            "sample_grid": [SAMPLE_COLUMNS, SAMPLE_ROWS],
            "visible_samples": visible_samples,
            "sample_count": sample_rgb.len(),
            "mean_rgb": mean_rgb,
            "capture_source": capture_source,
            "capture_scope": "owned GPUI scene/view only; no desktop screenshot or other-app pixels",
            "limitations": "Metal capture rerenders the current GPUI scene offscreen and does not include AppKit composition; separate native occlusion is checked by the window-number hit-test",
            "png_base64": base64::engine::general_purpose::STANDARD.encode(png_bytes),
        },
    });
    Ok(FullscreenMenuEvidence {
        geometry,
        report,
        sample_rgb,
    })
}

fn max_sample_rgb_delta(left: &[[f64; 3]], right: &[[f64; 3]]) -> Option<f64> {
    if left.len() != right.len() || left.is_empty() {
        return None;
    }
    Some(
        left.iter()
            .zip(right)
            .flat_map(|(left, right)| {
                (0..3).map(move |channel| (left[channel] - right[channel]).abs())
            })
            .fold(0.0_f64, f64::max),
    )
}

async fn verify_fullscreen_menu_reveal(
    handle: WindowHandle<Root>,
    native: &NSWindow,
    application: &NSApplication,
    cx: &mut AsyncApp,
) -> Result<serde_json::Value, String> {
    let entry_foreground =
        prepare_fullscreen_menu_state("fullscreen menu entry", native, application, cx).await?;
    let original_menu_bar_visibility = native_menu_bar_visible()?;
    let cycle_result = async {
        set_native_menu_bar_visible(false)?;
        wait_for_menu_bar_visibility(cx, false).await?;
        pause(cx, Duration::from_millis(250)).await;
        settle(handle, cx).await?;
        let hidden_foreground = prepare_fullscreen_menu_state(
            "fullscreen menu hidden-before snapshot",
            native,
            application,
            cx,
        )
        .await?;
        let mut hidden_before = fullscreen_menu_snapshot(
            "fullscreen_menu_hidden_before_reveal",
            false,
            application,
            native,
            handle,
            cx,
        )?;
        hidden_before.report["foreground_reacquisition"] = hidden_foreground;

        set_native_menu_bar_visible(true)?;
        wait_for_menu_bar_visibility(cx, true).await?;
        pause(cx, Duration::from_millis(300)).await;
        settle(handle, cx).await?;
        let revealed_foreground = prepare_fullscreen_menu_state(
            "fullscreen menu revealed snapshot",
            native,
            application,
            cx,
        )
        .await?;
        let mut revealed = fullscreen_menu_snapshot(
            "fullscreen_menu_revealed",
            true,
            application,
            native,
            handle,
            cx,
        )?;
        revealed.report["foreground_reacquisition"] = revealed_foreground;

        set_native_menu_bar_visible(false)?;
        wait_for_menu_bar_visibility(cx, false).await?;
        pause(cx, Duration::from_millis(300)).await;
        settle(handle, cx).await?;
        let hidden_after_foreground = prepare_fullscreen_menu_state(
            "fullscreen menu hidden-after snapshot",
            native,
            application,
            cx,
        )
        .await?;
        let mut hidden_after = fullscreen_menu_snapshot(
            "fullscreen_menu_hidden_after_reveal",
            false,
            application,
            native,
            handle,
            cx,
        )?;
        hidden_after.report["foreground_reacquisition"] = hidden_after_foreground;

        Ok::<_, String>(serde_json::json!({
            "stimulus": {
                "api": "NSMenu.menuBarVisible / setMenuBarVisible",
                "kind": "forced application menu-bar visibility",
                "pointer_hover_exercised": false,
            },
            "states": {
                "hidden_before": hidden_before.report,
                "revealed": revealed.report,
                "hidden_after": hidden_after.report,
            },
            "geometry_deltas": {
                "revealed_from_hidden": hidden_before.geometry.delta(revealed.geometry),
                "hidden_after_from_revealed": revealed.geometry.delta(hidden_after.geometry),
                "hidden_after_from_initial_hidden": hidden_before.geometry.delta(hidden_after.geometry),
            },
            "owned_renderer_crop_max_rgb_delta": {
                "revealed_from_hidden": max_sample_rgb_delta(&hidden_before.sample_rgb, &revealed.sample_rgb),
                "hidden_after_from_initial_hidden": max_sample_rgb_delta(&hidden_before.sample_rgb, &hidden_after.sample_rgb),
            },
            "coverage_limits": {
                "renderer_pixels": "software uses AppKit view capture; Metal uses Window::render_to_image offscreen scene pixels; neither capture includes reliable AppKit fullscreen composition",
                "occlusion_check": "uses AppKit hit-testing at a point in the actual tabbar band and compares only against the owned window number",
                "desktop_capture": false,
            },
        }))
    }
    .await;

    let restoration = async {
        let foreground = prepare_fullscreen_menu_state(
            "fullscreen menu visibility restoration",
            native,
            application,
            cx,
        )
        .await;
        // Always undo the fixture's visibility change, even if foreground was
        // interrupted during cleanup. The call changes this application's menu.
        set_native_menu_bar_visible(original_menu_bar_visibility)?;
        wait_for_menu_bar_visibility(cx, original_menu_bar_visibility).await?;
        let restored = native_menu_bar_visible()?;
        ensure(
            restored == original_menu_bar_visibility,
            "owned fixture did not restore the original menu bar visibility",
        )?;
        Ok::<_, String>((restored, foreground?))
    }
    .await;

    match (cycle_result, restoration) {
        (Ok(mut report), Ok((restored, restoration_foreground))) => {
            report["original_menu_bar_visibility"] =
                serde_json::json!(original_menu_bar_visibility);
            report["restored_menu_bar_visibility"] = serde_json::json!(restored);
            report["entry_foreground"] = entry_foreground;
            report["restoration_foreground"] = restoration_foreground;
            Ok(report)
        }
        (Err(error), Ok(_)) => Err(error),
        (Ok(_), Err(restore_error)) => Err(format!(
            "fullscreen menu reveal succeeded but visibility restoration failed: {restore_error}"
        )),
        (Err(error), Err(restore_error)) => Err(format!(
            "{error}; owned menu bar restoration also failed: {restore_error}"
        )),
    }
}

fn fullscreen_focus_diagnostic(
    application: &NSApplication,
    native: &NSWindow,
    did_resign_key: bool,
    focus_yield_ack_exists: bool,
) -> serde_json::Value {
    serde_json::json!({
        "app_active": application.isActive(),
        "window_key": native.isKeyWindow(),
        "window_visible": native.isVisible(),
        "window_on_active_space": native.isOnActiveSpace(),
        "window_fullscreen": native.styleMask().contains(NSWindowStyleMask::FullScreen),
        "did_resign_key_notification": did_resign_key,
        "focus_yield_ack_exists": focus_yield_ack_exists,
    })
}

fn verify_custom_titlebar_fullscreen_options(
    native: &NSWindow,
) -> Result<serde_json::Value, String> {
    let delegate = native
        .delegate()
        .ok_or("native fixture window has no fullscreen delegate")?;
    let proposed = NSApplicationPresentationOptions::AutoHideToolbar
        | NSApplicationPresentationOptions::AutoHideMenuBar
        | NSApplicationPresentationOptions::AutoHideDock
        | NSApplicationPresentationOptions::FullScreen
        | NSApplicationPresentationOptions::DisableMenuBarTransparency;
    let actual: NSApplicationPresentationOptions = unsafe {
        objc2::msg_send![
            &*delegate,
            window: native,
            willUseFullScreenPresentationOptions: proposed
        ]
    };
    let expected = NSApplicationPresentationOptions(
        proposed.0 & !NSApplicationPresentationOptions::AutoHideToolbar.0,
    );
    ensure(
        actual == expected,
        "custom-titlebar fullscreen policy did not preserve options while keeping toolbar controls visible",
    )?;
    Ok(serde_json::json!({
        "proposed_options": proposed.0,
        "returned_options": actual.0,
        "auto_hide_toolbar_removed": !actual.contains(NSApplicationPresentationOptions::AutoHideToolbar),
        "auto_hide_menu_bar_preserved": actual.contains(NSApplicationPresentationOptions::AutoHideMenuBar),
        "fullscreen_preserved": actual.contains(NSApplicationPresentationOptions::FullScreen),
        "other_options_preserved": actual.0 == expected.0,
    }))
}

fn rect_contains_with_tolerance(
    outer: objc2_foundation::NSRect,
    inner: objc2_foundation::NSRect,
) -> bool {
    const EPSILON: f64 = 0.5;
    inner.origin.x >= outer.origin.x - EPSILON
        && inner.origin.y >= outer.origin.y - EPSILON
        && inner.origin.x + inner.size.width <= outer.origin.x + outer.size.width + EPSILON
        && inner.origin.y + inner.size.height <= outer.origin.y + outer.size.height + EPSILON
}

fn native_rect_values(rect: objc2_foundation::NSRect) -> [f64; 4] {
    [
        rect.origin.x,
        rect.origin.y,
        rect.size.width,
        rect.size.height,
    ]
}

fn native_rects_match(left: objc2_foundation::NSRect, right: objc2_foundation::NSRect) -> bool {
    const EPSILON: f64 = 1.0;
    [
        (left.origin.x, right.origin.x),
        (left.origin.y, right.origin.y),
        (left.size.width, right.size.width),
        (left.size.height, right.size.height),
    ]
    .into_iter()
    .all(|(left, right)| (left - right).abs() <= EPSILON)
}

/// Check the actual AppKit controls and every native ancestor after a window
/// geometry transition. visibleRect accounts for ancestor clipping; explicit
/// conversions identify a container whose bounds would clip a light.
fn traffic_light_geometry(native: &NSWindow, stage: &str) -> Result<serde_json::Value, String> {
    let mut controls = serde_json::Map::new();
    let window_frame = native.frame();
    let content_view = native
        .contentView()
        .ok_or_else(|| format!("{stage}: native window has no content view"))?;
    let content_bounds = content_view.bounds();
    let content_flipped = content_view.isFlipped();
    for (button_kind, name) in [
        (NSWindowButton::CloseButton, "close"),
        (NSWindowButton::MiniaturizeButton, "minimize"),
        (NSWindowButton::ZoomButton, "zoom"),
    ] {
        let button = native
            .standardWindowButton(button_kind)
            .ok_or_else(|| format!("{stage}: native {name} traffic light is missing"))?;
        ensure(
            !button.isHiddenOrHasHiddenAncestor() && button.alphaValue() > 0.01,
            &format!("{stage}: native {name} traffic light or an ancestor is hidden"),
        )?;
        let bounds = button.bounds();
        let visible = button.visibleRect();
        ensure(
            rect_contains_with_tolerance(visible, bounds),
            &format!("{stage}: native {name} traffic light is clipped by an ancestor"),
        )?;

        let button_parent = unsafe { button.superview() };
        let button_parent_bounds = button_parent
            .as_ref()
            .map(|view| native_rect_values(view.bounds()));
        let button_parent_flipped = button_parent.as_ref().map(|view| view.isFlipped());
        let mut ancestor = button_parent;
        let mut ancestor_count = 0;
        while let Some(view) = ancestor {
            let button_in_ancestor = button.convertRect_toView(bounds, Some(&view));
            ensure(
                !view.isHidden() && view.alphaValue() > 0.01,
                &format!("{stage}: native {name} traffic light has an invisible ancestor"),
            )?;
            ensure(
                rect_contains_with_tolerance(view.bounds(), button_in_ancestor),
                &format!(
                    "{stage}: native {name} traffic light extends outside ancestor {} bounds",
                    ancestor_count + 1
                ),
            )?;
            ancestor_count += 1;
            ancestor = unsafe { view.superview() };
        }
        ensure(
            ancestor_count > 0,
            &format!("{stage}: native {name} traffic light has no native ancestors"),
        )?;
        let in_window = button.convertRect_toView(bounds, None);
        let in_screen = native.convertRectToScreen(in_window);
        let window_top = window_frame.origin.y + window_frame.size.height;
        let button_screen_top = in_screen.origin.y + in_screen.size.height;
        let top_inset = window_top - button_screen_top;
        let geometry = serde_json::json!({
            "window_frame": native_rect_values(window_frame),
            "window_rect": native_rect_values(in_window),
            "screen_rect": native_rect_values(in_screen),
            "content_bounds": native_rect_values(content_bounds),
            "content_flipped": content_flipped,
            "button_parent_bounds": button_parent_bounds,
            "button_parent_flipped": button_parent_flipped,
        });
        ensure(
            top_inset.is_finite() && (-1.0..=64.0).contains(&top_inset),
            &format!(
                "{stage}: native {name} traffic light moved away from the top edge: inset={top_inset}; geometry={geometry}"
            ),
        )?;
        controls.insert(
            name.to_owned(),
            serde_json::json!({
                "visible_rect": native_rect_values(visible),
                "window_rect": native_rect_values(in_window),
                "screen_rect": native_rect_values(in_screen),
                "window_frame": native_rect_values(window_frame),
                "content_bounds": native_rect_values(content_bounds),
                "content_flipped": content_flipped,
                "button_parent_bounds": button_parent_bounds,
                "button_parent_flipped": button_parent_flipped,
                "top_inset_points": top_inset,
                "ancestor_count": ancestor_count,
            }),
        );
    }
    Ok(serde_json::Value::Object(controls))
}

/// Capture the owned AppKit frame composition, including the native controls.
/// Geometry alone cannot detect a content layer painted over the titlebar.
/// The crop never reads another application or requires screen capture access.
fn traffic_light_composition(native: &NSWindow, stage: &str) -> Result<serde_json::Value, String> {
    use base64::Engine as _;
    let content = native
        .contentView()
        .ok_or("owned window has no content view")?;
    let frame = unsafe { content.superview() }.ok_or("owned window has no frame view")?;
    let mut rects = Vec::new();
    for (kind, name) in [
        (NSWindowButton::CloseButton, "close"),
        (NSWindowButton::MiniaturizeButton, "minimize"),
        (NSWindowButton::ZoomButton, "zoom"),
    ] {
        let button = native
            .standardWindowButton(kind)
            .ok_or("native control missing")?;
        let rect = button.convertRect_toView(button.bounds(), Some(&frame));
        ensure(
            rect_contains_with_tolerance(frame.bounds(), rect),
            &format!("{stage}: {name} is outside the visible window frame"),
        )?;
        rects.push((name, rect));
    }
    let left = rects
        .iter()
        .map(|(_, r)| r.origin.x)
        .fold(f64::INFINITY, f64::min)
        - 3.0;
    let bottom = rects
        .iter()
        .map(|(_, r)| r.origin.y)
        .fold(f64::INFINITY, f64::min)
        - 3.0;
    let right = rects
        .iter()
        .map(|(_, r)| r.origin.x + r.size.width)
        .fold(f64::NEG_INFINITY, f64::max)
        + 3.0;
    let top = rects
        .iter()
        .map(|(_, r)| r.origin.y + r.size.height)
        .fold(f64::NEG_INFINITY, f64::max)
        + 3.0;
    let crop = objc2_foundation::NSRect::new(
        NSPoint::new(left, bottom),
        objc2_foundation::NSSize::new(right - left, top - bottom),
    );
    let bitmap = frame
        .bitmapImageRepForCachingDisplayInRect(crop)
        .and_then(|b| b.bitmapImageRepByRetaggingWithColorSpace(&NSColorSpace::sRGBColorSpace()))
        .ok_or("owned titlebar bitmap allocation failed")?;
    let width = u32::try_from(bitmap.pixelsWide()).map_err(error)?;
    let height = u32::try_from(bitmap.pixelsHigh()).map_err(error)?;
    ensure(
        width > 0 && height > 0 && width <= 1024 && height <= 256,
        "owned titlebar crop has invalid dimensions",
    )?;
    let length = usize::try_from(bitmap.bytesPerPlane()).map_err(error)?;
    ensure(
        bitmap.numberOfPlanes() == 1
            && !bitmap.bitmapData().is_null()
            && length > 0
            && length <= 4 * 1024 * 1024,
        "owned titlebar bitmap has invalid storage",
    )?;
    unsafe { std::ptr::write_bytes(bitmap.bitmapData(), 0, length) };
    frame.cacheDisplayInRect_toBitmapImageRep(crop, &bitmap);
    let mut rgba = image::RgbaImage::new(width, height);
    for y in 0..height {
        for x in 0..width {
            let color = bitmap
                .colorAtX_y(x as isize, y as isize)
                .and_then(|c| c.colorUsingColorSpace(&NSColorSpace::sRGBColorSpace()))
                .ok_or("owned titlebar pixel missing")?;
            let byte = |v: f64| (v.clamp(0.0, 1.0) * 255.0).round() as u8;
            rgba.put_pixel(
                x,
                y,
                image::Rgba([
                    byte(color.redComponent()),
                    byte(color.greenComponent()),
                    byte(color.blueComponent()),
                    byte(color.alphaComponent()),
                ]),
            );
        }
    }
    let corners = [
        rgba.get_pixel(0, 0),
        rgba.get_pixel(width - 1, 0),
        rgba.get_pixel(0, height - 1),
        rgba.get_pixel(width - 1, height - 1),
    ];
    let background: [f64; 3] =
        std::array::from_fn(|c| corners.iter().map(|p| p[c] as f64).sum::<f64>() / 4.0);
    let mut visible_pixels = serde_json::Map::new();
    for (name, rect) in rects {
        let x0 = ((rect.origin.x - left) / crop.size.width * width as f64)
            .floor()
            .max(0.0) as u32;
        let x1 =
            (((rect.origin.x + rect.size.width - left) / crop.size.width * width as f64).ceil()
                as u32)
                .min(width);
        // All three AppKit controls share a row. Include its entire crop height
        // so the check is independent of NSView/bitmap vertical orientation.
        let contrast = (x0..x1)
            .flat_map(|x| (0..height).map(move |y| (x, y)))
            .filter(|&(x, y)| {
                let p = rgba.get_pixel(x, y);
                p[3] > 200 && (0..3).any(|c| (p[c] as f64 - background[c]).abs() >= 20.0)
            })
            .count();
        ensure(
            contrast >= 8,
            &format!(
                "{stage}: {name} traffic light is absent from the native composition ({contrast} visible pixels)"
            ),
        )?;
        visible_pixels.insert(name.into(), serde_json::json!(contrast));
    }
    let mut png = std::io::Cursor::new(Vec::new());
    image::DynamicImage::ImageRgba8(rgba)
        .write_to(&mut png, image::ImageFormat::Png)
        .map_err(error)?;
    Ok(serde_json::json!({
        "pixel_size": [width, height], "crop_rect": native_rect_values(crop),
        "visible_control_pixels": visible_pixels,
        "png_base64": base64::engine::general_purpose::STANDARD.encode(png.into_inner()),
    }))
}

/// Observe only this fixture window. Completion notifications avoid racing
/// AppKit's Space animation or treating an early style-mask change as settled.
struct FullscreenCompletion {
    observer: Retained<objc2::runtime::ProtocolObject<dyn objc2_foundation::NSObjectProtocol>>,
    completed: std::sync::Arc<std::sync::atomic::AtomicBool>,
}
impl FullscreenCompletion {
    fn new(native: &NSWindow, name: &NSString) -> Self {
        let completed = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
        let flag = completed.clone();
        let block = block2::RcBlock::new(
            move |_: std::ptr::NonNull<objc2_foundation::NSNotification>| {
                flag.store(true, std::sync::atomic::Ordering::Release);
            },
        );
        // The block captures only a sendable atomic; no global observer or
        // application/window outside this owned fixture is inspected.
        let observer = unsafe {
            objc2_foundation::NSNotificationCenter::defaultCenter()
                .addObserverForName_object_queue_usingBlock(Some(name), Some(native), None, &block)
        };
        Self {
            observer,
            completed,
        }
    }
    fn completed(&self) -> bool {
        self.completed.load(std::sync::atomic::Ordering::Acquire)
    }
}
impl Drop for FullscreenCompletion {
    fn drop(&mut self) {
        let observer: &objc2::runtime::AnyObject =
            AsRef::<objc2::runtime::AnyObject>::as_ref(&*self.observer);
        unsafe {
            objc2_foundation::NSNotificationCenter::defaultCenter().removeObserver(observer);
        }
    }
}

async fn verify_traffic_lights_in_real_fullscreen(
    handle: WindowHandle<Root>,
    native: &NSWindow,
    cx: &mut AsyncApp,
    focus_yield_ack_path: &Path,
    activation_ack_path: &Path,
) -> Result<serde_json::Value, String> {
    ensure(
        !native.styleMask().contains(NSWindowStyleMask::FullScreen),
        "owned fullscreen fixture must start windowed",
    )?;
    let entered = FullscreenCompletion::new(native, unsafe {
        objc2_app_kit::NSWindowDidEnterFullScreenNotification
    });
    let exited = FullscreenCompletion::new(native, unsafe {
        objc2_app_kit::NSWindowDidExitFullScreenNotification
    });
    native_mutation(|| native.toggleFullScreen(None))?;
    // Attempt to exit the owned Space even when a visibility assertion fails;
    // retain a failed receipt if AppKit itself cannot complete the transition.
    let fullscreen_result = async {
        wait_until_deadline(
            cx,
            "enter actual fullscreen Space",
            Instant::now() + Duration::from_secs(12),
            |_| entered.completed() && native.styleMask().contains(NSWindowStyleMask::FullScreen),
        )
        .await?;
        wait_for_native_window_geometry(native, cx, "fullscreen controls after animation", |_| {
            true
        })
        .await?;
        settle(handle, cx).await?;
        let initial_geometry = traffic_light_geometry(native, "actual fullscreen")?;
        let initial_composition = traffic_light_composition(native, "actual fullscreen")?;
        let application = NSApplication::sharedApplication(
            MainThreadMarker::new().ok_or("fullscreen focus fixture is not on main thread")?,
        );
        ensure(application.isActive() && native.isKeyWindow(),
            "fullscreen focus fixture must start with an active key window")?;
        let menu_reveal =
            verify_fullscreen_menu_reveal(handle, native, &application, cx).await?;
        ensure(
            application.isActive() && native.isVisible() && native.isKeyWindow(),
            "owned fixture lost foreground after fullscreen menu reveal",
        )?;
        let resigned = FullscreenCompletion::new(native, unsafe {
            objc2_app_kit::NSWindowDidResignKeyNotification
        });
        // A second owned application must take foreground so AppKit performs a
        // real resign-key transition while this window remains in its fullscreen Space.
        let focus_yield_deadline = Instant::now() + Duration::from_secs(12);
        emit_activation_handshake(
            "native_fullscreen_focus_yield=",
            "fullscreen_application_focus_yield",
            focus_yield_ack_path,
        )?;
        let inactive_wait = wait_until_deadline(
            cx,
            "owned fullscreen application actually deactivated",
            focus_yield_deadline,
            |_| {
                focus_yield_ack_path.exists()
                    && !application.isActive()
                    && !native.isKeyWindow()
                    && resigned.completed()
            },
        )
        .await;
        let inactive_result = match inactive_wait {
            Err(error) => {
                let mut diagnostic = fullscreen_focus_diagnostic(
                    &application,
                    native,
                    resigned.completed(),
                    focus_yield_ack_path.exists(),
                );
                diagnostic["wait_error"] = serde_json::json!(error);
                eprintln!("native_fullscreen_focus_yield_failure={diagnostic}");
                Err(error)
            }
            Ok(()) => {
                // Let AppKit deliver its inactive control appearance and layout.
                pause(cx, Duration::from_millis(300)).await;
                let geometry =
                    traffic_light_geometry(native, "fullscreen after app deactivation");
                let composition =
                    traffic_light_composition(native, "fullscreen after app deactivation");
                let mut diagnostic = fullscreen_focus_diagnostic(
                    &application,
                    native,
                    resigned.completed(),
                    focus_yield_ack_path.exists(),
                );
                diagnostic["geometry"] = match &geometry {
                    Ok(value) => value.clone(),
                    Err(error) => serde_json::json!({"error": error}),
                };
                let mut composition_diagnostic = match &composition {
                    Ok(value) => value.clone(),
                    Err(error) => serde_json::json!({"error": error}),
                };
                if let Some(fields) = composition_diagnostic.as_object_mut() {
                    fields.remove("png_base64");
                }
                diagnostic["composition"] = composition_diagnostic;
                eprintln!("native_fullscreen_inactive_diagnostic={diagnostic}");
                match (geometry, composition) {
                    (Ok(geometry), Ok(composition)) => Ok(serde_json::json!({
                        "app_inactive": !application.isActive(),
                        "window_not_key": !native.isKeyWindow(),
                        "window_on_active_space": native.isOnActiveSpace(),
                        "did_resign_key_notification": resigned.completed(),
                        "geometry": geometry,
                        "composition": composition,
                    })),
                    (Err(error), _) => Err(error),
                    (_, Err(error)) => Err(error),
                }
            }
        };
        // Reactivate this exact owned process through LaunchServices after the
        // companion has released foreground and exited.
        let reactivation_deadline = Instant::now() + Duration::from_secs(8);
        let reactivation_result = async {
            emit_activation_handshake(
                "native_fullscreen_reactivation=",
                "fullscreen_application_reactivation",
                activation_ack_path,
            )?;
            wait_until_deadline(
                cx,
                "owned fullscreen LaunchServices reactivation",
                reactivation_deadline,
                |_| activation_ack_path.exists() && application.isActive(),
            )
            .await?;
            native_mutation(|| native.makeKeyAndOrderFront(None))?;
            wait_until_deadline(
                cx,
                "owned fullscreen application reactivated",
                reactivation_deadline,
                |_| application.isActive() && native.isKeyWindow(),
            )
            .await?;
            settle(handle, cx).await?;
            Ok::<_, String>(())
        }
        .await;
        if let Err(reactivation_error) = reactivation_result {
            let mut diagnostic = fullscreen_focus_diagnostic(
                &application,
                native,
                resigned.completed(),
                focus_yield_ack_path.exists(),
            );
            diagnostic["reactivation_ack_exists"] =
                serde_json::json!(activation_ack_path.exists());
            diagnostic["reactivation_error"] = serde_json::json!(reactivation_error.clone());
            let failure = match inactive_result {
                Err(inactive_error) => {
                    diagnostic["inactive_error"] = serde_json::json!(inactive_error.clone());
                    inactive_error
                }
                Ok(_) => reactivation_error,
            };
            eprintln!("native_fullscreen_reactivation_failure={diagnostic}");
            return Err(failure);
        }
        let inactive = inactive_result?;
        Ok::<_, String>(serde_json::json!({
            "actual_fullscreen": true,
            "did_enter_notification": entered.completed(),
            "geometry": initial_geometry,
            "composition": initial_composition,
            "menu_reveal_cycle": menu_reveal,
            "after_deactivation": inactive,
            "after_reactivation": {
                "app_active": application.isActive(),
                "window_key": native.isKeyWindow(),
                "geometry": traffic_light_geometry(native, "fullscreen after app reactivation")?,
                "composition": traffic_light_composition(native, "fullscreen after app reactivation")?,
            },
        }))
    }
    .await;
    let mut exit_via_green_button = false;
    if native.styleMask().contains(NSWindowStyleMask::FullScreen) {
        let green = native
            .standardWindowButton(NSWindowButton::ZoomButton)
            .ok_or("owned fullscreen window has no green button")?;
        // This is the real button from the owned main-thread fixture window.
        native_mutation(|| unsafe { green.performClick(None) })?;
        let exit_result = wait_until_deadline(
            cx,
            "exit owned fullscreen Space through native green button",
            Instant::now() + Duration::from_secs(12),
            |_| exited.completed() && !native.styleMask().contains(NSWindowStyleMask::FullScreen),
        )
        .await;
        exit_via_green_button = exit_result.is_ok();
        if exit_result.is_err() && native.styleMask().contains(NSWindowStyleMask::FullScreen) {
            // Clean up only this fixture's Space if the actual button failed.
            native_mutation(|| native.toggleFullScreen(None))?;
            wait_until_deadline(
                cx,
                "cleanup owned fullscreen Space",
                Instant::now() + Duration::from_secs(12),
                |_| {
                    exited.completed()
                        && !native.styleMask().contains(NSWindowStyleMask::FullScreen)
                },
            )
            .await?;
        }
        exit_result?;
        wait_for_native_window_geometry(native, cx, "controls after fullscreen exit", |_| true)
            .await?;
        settle(handle, cx).await?;
    }
    let fullscreen = fullscreen_result?;
    Ok(serde_json::json!({
        "fullscreen": fullscreen,
        "did_exit_notification": exited.completed(),
        "exit_via_green_button": exit_via_green_button,
        "windowed_after_fullscreen": traffic_light_geometry(native, "after actual fullscreen exit")?,
        "composition_after_fullscreen": traffic_light_composition(native, "after actual fullscreen exit")?,
    }))
}

async fn wait_for_native_window_geometry(
    native: &NSWindow,
    cx: &mut AsyncApp,
    stage: &'static str,
    mut frame_matches: impl FnMut(objc2_foundation::NSRect) -> bool,
) -> Result<(), String> {
    let mut previous = native.frame();
    let mut stable_samples = 0_u8;
    wait_until(cx, stage, |_| {
        let current = native.frame();
        if native_rects_match(previous, current) {
            stable_samples = stable_samples.saturating_add(1);
        } else {
            previous = current;
            stable_samples = 0;
        }
        stable_samples >= 3
            && frame_matches(current)
            && traffic_light_geometry(native, stage).is_ok()
    })
    .await
}

async fn verify_traffic_lights_after_window_zoom(
    handle: WindowHandle<Root>,
    native: &NSWindow,
    cx: &mut AsyncApp,
    fullscreen_focus_yield_ack_path: &Path,
    fullscreen_reactivation_ack_path: &Path,
) -> Result<serde_json::Value, String> {
    let fullscreen_options = verify_custom_titlebar_fullscreen_options(native)?;
    let initial_frame = native.frame();
    let initial_controls = traffic_light_geometry(native, "before ordinary zoom")?;
    let initial_composition = traffic_light_composition(native, "before ordinary zoom")?;
    handle
        .update(cx, |_, window, _| window.zoom_window())
        .map_err(error)?;
    wait_for_native_window_geometry(native, cx, "ordinary window zoom", |frame| {
        !native_rects_match(frame, initial_frame)
    })
    .await?;
    let zoomed_frame = native.frame();
    let zoomed_controls = traffic_light_geometry(native, "after ordinary zoom")?;
    let zoomed_composition = traffic_light_composition(native, "after ordinary zoom")?;

    handle
        .update(cx, |_, window, _| window.zoom_window())
        .map_err(error)?;
    wait_for_native_window_geometry(native, cx, "restore windowed geometry", |frame| {
        native_rects_match(frame, initial_frame)
    })
    .await?;
    let restored_frame = native.frame();
    let restored_controls = traffic_light_geometry(native, "after restoring windowed geometry")?;
    let actual_fullscreen = verify_traffic_lights_in_real_fullscreen(
        handle,
        native,
        cx,
        fullscreen_focus_yield_ack_path,
        fullscreen_reactivation_ack_path,
    )
    .await?;
    Ok(serde_json::json!({
        "windowed_frame_before": native_rect_values(initial_frame),
        "zoomed_frame": native_rect_values(zoomed_frame),
        "windowed_frame_after": native_rect_values(restored_frame),
        "fullscreen_presentation_options": fullscreen_options,
        "controls_before_zoom": initial_controls,
        "composition_before_zoom": initial_composition,
        "composition_after_zoom": zoomed_composition,
        "actual_fullscreen_cycle": actual_fullscreen,
        "controls_after_zoom": zoomed_controls,
        "controls_after_restore": restored_controls,
        "ordinary_zoom_restored_original_frame": native_rects_match(initial_frame, restored_frame),
    }))
}

async fn verify_surfaces(
    handle: WindowHandle<Root>,
    ws: &Entity<Workspace>,
    ids: &[TabId],
    sessions: &[(u64, Entity<TerminalSession>)],
    profile: &Profile,
    cx: &mut AsyncApp,
) -> Result<serde_json::Value, String> {
    let native = native_window(handle, cx)?;
    let selected_views = cx.update(|cx| ws.read(cx).entries[&ids[1]].panes.read(cx).views());
    let initial_cache = cx.update(|cx| {
        selected_views
            .iter()
            .map(|view| view.read(cx).overlays.cache_bytes())
            .sum::<u64>()
    });
    ensure(
        initial_cache > 0,
        "real CPU terminal frames were never cached",
    )?;
    let reclaimed_before = cx.update(|cx| {
        crate::memory_pressure::diagnostics(cx)["regenerable_cache_bytes_released"]
            .as_u64()
            .unwrap_or(0)
    });
    let retention = verify_retention(handle, ws, ids, sessions, profile, cx).await?;
    let reclaimed = cx.update(|cx| {
        crate::memory_pressure::diagnostics(cx)["regenerable_cache_bytes_released"]
            .as_u64()
            .unwrap_or(0)
            .saturating_sub(reclaimed_before)
    });
    ensure(
        reclaimed > 0,
        "injected critical policy reclaimed no actual renderer cache",
    )?;
    eprintln!("native_history_retention={retention}");
    native_mutation(|| native.orderOut(None))?;
    wait_until(cx, "actual ordered-out window suspension", |cx| {
        !native.isVisible()
            && sessions.iter().all(|(_, s)| {
                !s.read(cx).restore_surface_visible() && s.read(cx).is_render_suspended()
            })
    })
    .await?;
    std::fs::write(profile.directories[1].join("hidden-output"), b"release").map_err(error)?;
    wait_until(cx, "hidden authoritative native output", |cx| {
        sessions[0]
            .1
            .read(cx)
            .with_terminal(|term| term.full_buffer_text().contains("OWNED_HIDDEN_GRID"))
            && sessions[0].1.read(cx).is_render_suspended()
    })
    .await?;
    let terminal = cx.update(|cx| sessions[0].1.read(cx).remote_terminal());
    let update = cx
        .background_spawn(async move { crate::remote::snapshot::capture_update(&terminal, 0) })
        .await
        .ok_or("hidden authoritative remote snapshot absent")?;
    let mut cache = chau7_next_core::remote::grid_cache::RemoteGridSnapshotCache::default();
    let encoded = cache
        .encode(&update)
        .ok_or("hidden remote grid encode failed")?;
    let remote =
        chau7_next_core::remote::grid_snapshot::RemoteTerminalGridSnapshot::decode(&encoded)
            .map_err(error)?;
    ensure(
        remote
            .clusters
            .windows(b"OWNED_HIDDEN_GRID".len())
            .any(|bytes| bytes == b"OWNED_HIDDEN_GRID"),
        "remote grid did not reflect output while presentation was suspended",
    )?;
    let application = NSApplication::sharedApplication(
        MainThreadMarker::new().ok_or("native fixture is not on main thread")?,
    );
    // Observe only this fixture application on the platform main thread.
    let policy_before = application.activationPolicy();
    if policy_before != NSApplicationActivationPolicy::Regular {
        application.setActivationPolicy(NSApplicationActivationPolicy::Regular);
    }
    ensure(
        application.activationPolicy() == NSApplicationActivationPolicy::Regular,
        "owned fixture activation policy is not Regular",
    )?;
    native_mutation(|| native.makeKeyAndOrderFront(None))?;
    // The owned acceptance fixture needs an explicit foreground request before
    // testing native restore. Ask LaunchServices to activate this exact bundle,
    // then require both its ACK and AppKit's active state under one deadline.
    let ordered_front_deadline = Instant::now() + Duration::from_secs(8);
    let ordered_front_activation_ack_path = profile
        .home
        .join("native-parity-ordered-front-activation.ack");
    emit_activation_handshake(
        "native_ordered_front_activation=",
        "ordered_front_surface_reveal",
        &ordered_front_activation_ack_path,
    )?;
    cx.update(|cx| cx.activate(true));
    if let Err(error) = wait_until_deadline(
        cx,
        "owned fixture application activation",
        ordered_front_deadline,
        |_| ordered_front_activation_ack_path.exists() && application.isActive(),
    )
    .await
    {
        // Capture this owned application's actual AppKit state at the failed
        // gate, before cleanup changes it. Keep the original failure and timer.
        let mut snapshot = activation_diagnostic(
            application.isActive(),
            application.activationPolicy().0,
            native.isVisible(),
            native.isKeyWindow(),
            native.canBecomeKeyWindow(),
        );
        snapshot["ordered_front_activation_ack_exists"] =
            serde_json::json!(ordered_front_activation_ack_path.exists());
        eprintln!("native_activation_failure={snapshot}");
        return Err(error);
    }
    wait_for_reveal(
        handle,
        &native,
        &application,
        sessions,
        cx,
        "actual ordered-front surface reveal",
        |cx| {
            application.isActive()
                && native.isVisible()
                && native.isKeyWindow()
                && sessions
                    .iter()
                    .all(|(_, s)| s.read(cx).restore_surface_visible())
        },
    )
    .await?;
    settle(handle, cx).await?;
    let resize_markers_before = cx.update(|cx| {
        sessions
            .iter()
            .map(|(id, session)| {
                session.read(cx).with_terminal(|term| {
                    let text = term.full_buffer_text();
                    (
                        *id,
                        text.matches("TIP ").count(),
                        text.matches("fixture$").count(),
                    )
                })
            })
            .collect::<Vec<_>>()
    });
    ensure(
        resize_markers_before
            .iter()
            .all(|(_, _, prompts)| *prompts > 0),
        "native resize fixture has no live shell prompt marker",
    )?;
    let fullscreen_focus_yield_ack_path = profile
        .home
        .join("native-parity-fullscreen-focus-yield.ack");
    let fullscreen_reactivation_ack_path = profile
        .home
        .join("native-parity-fullscreen-reactivation.ack");
    let traffic_light_zoom_geometry = verify_traffic_lights_after_window_zoom(
        handle,
        &native,
        cx,
        &fullscreen_focus_yield_ack_path,
        &fullscreen_reactivation_ack_path,
    )
    .await?;
    let resize_markers_after = cx.update(|cx| {
        sessions
            .iter()
            .map(|(id, session)| {
                session.read(cx).with_terminal(|term| {
                    let text = term.full_buffer_text();
                    (
                        *id,
                        text.matches("TIP ").count(),
                        text.matches("fixture$").count(),
                    )
                })
            })
            .collect::<Vec<_>>()
    });
    ensure(
        resize_markers_before == resize_markers_after,
        "native zoom/fullscreen/focus transition duplicated terminal tips or prompts",
    )?;
    cx.update(|cx| -> Result<(), String> {
        ensure(
            sessions.iter().all(|(_, s)| {
                s.read(cx).surface_has_live_frame() && !s.read(cx).is_render_suspended()
            }),
            "ordered-front reveal did not paint actual terminal surfaces",
        )
    })?;
    bootstrap_rendered_accessibility_frame(handle, &native, cx).await?;
    native_mutation(|| native.miniaturize(None))?;
    wait_for_reveal(
        handle,
        &native,
        &application,
        sessions,
        cx,
        "actual miniaturized window",
        |cx| {
            native.isMiniaturized()
                && sessions
                    .iter()
                    .all(|(_, s)| !s.read(cx).restore_surface_visible())
        },
    )
    .await?;
    native_mutation(|| native.deminiaturize(None))?;
    // Bring the owned window forward and key it once before app activation.
    native_mutation(|| native.makeKeyAndOrderFront(None))?;
    activate_owned_application(&application)?;
    // Keep this owned process alive inside the existing 5-second reveal
    // deadline until the runner has reopened its exact bundle and verified the
    // PID set. The ACK path resets each restored terminal's presentation flag.
    // A later rendered accessibility frame and live terminal surfaces prove
    // repaint; software renderer counters add a backend-specific check.
    let activation_ack_path = profile.home.join("native-parity-activation.ack");
    emit_activation_handshake(
        "native_activation_handshake=",
        "deminiaturized_surface_reveal",
        &activation_ack_path,
    )?;
    let (frame_at_ack, first_live_frame, reveal_deadline) = wait_for_activation_reveal(
        handle,
        &native,
        &application,
        sessions,
        cx,
        &activation_ack_path,
    )
    .await?;
    settle_with_deadline(handle, cx, reveal_deadline).await?;
    let frame_after_settle = window_frame_evidence(handle, cx)?;
    ensure(
        Instant::now() < reveal_deadline,
        "owned native fixture deadline: actual deminiaturized surface reveal",
    )?;
    let (post_demini_surfaces_live, post_demini_surfaces_suspended) = cx.update(|cx| {
        let live = sessions.iter().all(|(_, session)| {
            let session = session.read(cx);
            restore_surface_frame_ready(
                session.restore_surface_visible(),
                session.surface_has_live_frame(),
                session.is_render_suspended(),
            )
        });
        let suspended = sessions
            .iter()
            .any(|(_, session)| session.read(cx).is_render_suspended());
        (live, suspended)
    });
    ensure(
        post_demini_surfaces_live && !post_demini_surfaces_suspended,
        "post-deminiaturization terminal surfaces lost visibility, live frames, or render eligibility after settle",
    )?;
    let rendered_frame_delta_after_ack = rendered_reveal_delta(
        frame_at_ack.frame_number,
        first_live_frame.frame_number,
        frame_after_settle.frame_number,
    )
    .ok_or_else(|| {
        format!(
            "post-deminiaturization rendered accessibility frame did not advance: before={} after={}",
            frame_at_ack.frame_number, frame_after_settle.frame_number
        )
    })?;
    let renderer_counter_delta = supplemental_renderer_delta(frame_at_ack, frame_after_settle)
        .ok_or_else(|| {
            format!(
                "post-deminiaturization renderer evidence failed for backend {:?}: before={:?} after={:?}",
                frame_at_ack.renderer_backend,
                frame_at_ack.renderer_counters,
                frame_after_settle.renderer_counters
            )
        })?;
    ensure(
        Instant::now() < reveal_deadline,
        "owned native fixture deadline: actual deminiaturized surface reveal",
    )?;
    let actual_reveal_frames = post_demini_surfaces_live
        && !post_demini_surfaces_suspended
        && rendered_frame_delta_after_ack > 0
        && final_native_focus_ready(
            application.isActive(),
            native.isVisible(),
            native.isKeyWindow(),
            native.isMiniaturized(),
        );
    ensure(
        actual_reveal_frames,
        "post-deminiaturization reveal lacks a later rendered frame, live terminal surfaces, or native focus",
    )?;
    ensure_terminal_focus(handle, ws, ids[1], cx)?;
    let post_reveal_terminal_input_focus = true;
    let worker = cx.update(crate::memory_pressure::stop_native_fixture);
    cx.background_spawn(async move {
        if let Some(worker) = worker {
            let _ = worker.join();
        }
    })
    .await;
    // Repaint a neighbor and the split, then move more than two tabs away.
    select(handle, ws, ids[3], cx)?;
    settle(handle, cx).await?;
    select(handle, ws, ids[1], cx)?;
    settle(handle, cx).await?;
    let neighbor_views = cx.update(|cx| ws.read(cx).entries[&ids[3]].panes.read(cx).views());
    let neighbor_before = cx.update(|cx| {
        neighbor_views
            .iter()
            .map(|v| v.read(cx).overlays.cache_bytes())
            .sum::<u64>()
    });
    ensure(
        neighbor_before > 0,
        "actual neighbor CPU cache was not painted",
    )?;
    select(handle, ws, ids[5], cx)?;
    wait_until(cx, "far owned deferred PTY activation", |cx| {
        ws.read(cx).entries[&ids[5]]
            .panes
            .read(cx)
            .pane_sessions(cx)
            .len()
            == 1
    })
    .await?;
    settle(handle, cx).await?;
    let retained_cache = cx.update(|cx| -> Result<u64, String> {
        ensure(
            selected_views
                .iter()
                .all(|view| view.read(cx).overlays.cache_bytes() == 0),
            "distant split CPU frames escaped neighbor cache bounds",
        )?;
        ensure(
            neighbor_views
                .iter()
                .map(|v| v.read(cx).overlays.cache_bytes())
                .sum::<u64>()
                == neighbor_before,
            "nearby CPU cache was evicted by the distance policy",
        )?;
        let ws = ws.read(cx);
        let mut total = 0;
        for entry in ws.entries.values() {
            for view in entry.panes.read(cx).views() {
                let bytes = view.read(cx).overlays.cache_bytes();
                ensure(
                    bytes <= 64 * 1024 * 1024,
                    "real CPU frame exceeded its allocation budget",
                )?;
                total += bytes;
            }
        }
        ensure(
            total <= chau7_next_core::memory_pressure::GLOBAL_CACHE_BYTES,
            "fixture's retained real renderer caches exceeded the global budget",
        )?;
        Ok(total)
    })?;
    let final_selected_tab = cx.update(|cx| ws.read(cx).state.selected());
    ensure(
        final_selected_tab == Some(ids[5]),
        &format!(
            "native cache checks ended on an unexpected selected tab: expected={:?} actual={final_selected_tab:?}",
            ids[5]
        ),
    )?;
    ensure_terminal_focus(handle, ws, ids[5], cx)?;
    let final_terminal_input_focus = true;
    let final_native_app_active = application.isActive();
    let final_native_window_visible = native.isVisible();
    let final_native_key_window = native.isKeyWindow();
    let final_native_window_miniaturized = native.isMiniaturized();
    let final_native_focus_passed = final_native_focus_ready(
        final_native_app_active,
        final_native_window_visible,
        final_native_key_window,
        final_native_window_miniaturized,
    );
    if !final_native_focus_passed {
        eprintln!(
            "native_restore_final_focus_failure={}",
            serde_json::json!({
                "app_active": final_native_app_active,
                "window_visible": final_native_window_visible,
                "window_key": final_native_key_window,
                "window_miniaturized": final_native_window_miniaturized,
                "activation_policy": application.activationPolicy().0,
                "stage": "immediately_before_restore_fixture_success",
            })
        );
        return Err(format!(
            "final owned native focus assertion failed before fixture success: app_active={} window_visible={} key_window={} miniaturized={}",
            final_native_app_active,
            final_native_window_visible,
            final_native_key_window,
            final_native_window_miniaturized,
        ));
    }
    Ok(
        serde_json::json!({"traffic_light_zoom_geometry":traffic_light_zoom_geometry,
        "terminal_markers_preserved_through_window_transitions":true,
        "terminal_marker_counts":resize_markers_after,
        "hover_live_budget_ms":2000,"hover_exit_budget_ms":500,
        "hover_parked_ptys":0,"hidden_raw_grid_updated":true,"hidden_remote_grid_updated":true,
        "ordered_out_front":true,"native_mini_demini":true,
        "native_key_window":final_native_key_window,"native_app_active":final_native_app_active,
        "native_window_visible":final_native_window_visible,
        "native_window_miniaturized":final_native_window_miniaturized,
        "final_native_focus_passed":final_native_focus_passed,
        "post_reveal_terminal_input_focus":post_reveal_terminal_input_focus,
        "final_terminal_input_focus":final_terminal_input_focus,
        "native_activation_policy_before":policy_before.0,"native_activation_policy_after":application.activationPolicy().0,
        "restore_surfaces_live_after_demin":post_demini_surfaces_live,
        "restore_surfaces_suspended_after_demin":post_demini_surfaces_suspended,
        "actual_reveal_frames":actual_reveal_frames,
        "reveal_frame_evidence":{"baseline":"after_owned_activation_ack_before_surface_refresh",
        "window_rendered_frame_at_ack":frame_at_ack.frame_number,
        "window_rendered_frame_first_live_after_ack":first_live_frame.frame_number,
        "window_rendered_frame_after_two_native_frames":frame_after_settle.frame_number,
        "window_rendered_frame_delta_after_ack":rendered_frame_delta_after_ack,
        "renderer_backend":frame_at_ack.renderer_backend,
        "renderer_counter_status":if renderer_counter_delta.is_some(){"measured_clean_submission"}else{"unavailable_for_metal"},
        "submitted_frames_at_ack":frame_at_ack.renderer_counters.map(|counters|counters.submitted),
        "failed_frames_at_ack":frame_at_ack.renderer_counters.map(|counters|counters.failed),
        "submitted_frames_first_live_after_ack":first_live_frame.renderer_counters.map(|counters|counters.submitted),
        "failed_frames_first_live_after_ack":first_live_frame.renderer_counters.map(|counters|counters.failed),
        "submitted_frames_after_two_native_frames":frame_after_settle.renderer_counters.map(|counters|counters.submitted),
        "failed_frames_after_two_native_frames":frame_after_settle.renderer_counters.map(|counters|counters.failed),
        "submitted_frame_delta_after_ack":renderer_counter_delta},
        "critical_pressure_source":"fixture_policy_injection","os_pressure_delivery_tested":false,
        "critical_cache_bytes_reclaimed":reclaimed,"native_history_preserved":true,"ordinary_history_retention":retention,
        "distant_split_cache_bytes":0,"neighbor_cpu_cache_bytes":neighbor_before,
        "retained_cpu_cache_bytes":retained_cache}),
    )
}

fn capture_print_snapshot(
    handle: WindowHandle<Root>,
    ws: &Entity<Workspace>,
    tab_id: TabId,
    cx: &mut AsyncApp,
) -> Result<serde_json::Value, String> {
    handle
        .update(cx, |_, window, cx| -> Result<_, String> {
            let view = ws.read(cx).entries[&tab_id]
                .panes
                .read(cx)
                .focused_view()
                .ok_or("styled print fixture has no focused terminal view")?;
            let cache_before = view.read(cx).overlays.cache_bytes();
            let bitmap = view
                .update(cx, |view, cx| view.print_snapshot(window, cx))
                .map_err(error)?;
            let cache_after = view.read(cx).overlays.cache_bytes();
            ensure(
                cache_after == cache_before,
                "print snapshot changed the displayed CPU frame cache",
            )?;

            let decoded = image::load_from_memory(&bitmap.png)
                .map_err(error)?
                .to_rgba8();
            ensure(
                bitmap.pixel_size.0 > 0
                    && bitmap.pixel_size.1 > 0
                    && decoded.dimensions() == bitmap.pixel_size,
                "print snapshot PNG dimensions are empty or inconsistent",
            )?;
            let rgba = decoded.as_raw();
            let nontransparent_pixels = rgba
                .as_chunks::<4>()
                .0
                .iter()
                .filter(|px| px[3] > 0)
                .count();
            let styled_background_pixels = rgba
                .as_chunks::<4>()
                .0
                .iter()
                .filter(|px| px[0] == 7 && px[1] == 8 && px[2] == 9 && px[3] == 255)
                .count();
            let styled_foreground_pixels = rgba
                .as_chunks::<4>()
                .0
                .iter()
                .filter(|px| px[0] == 12 && px[1] == 34 && px[2] == 56 && px[3] == 255)
                .count();
            if nontransparent_pixels == 0 || styled_background_pixels == 0 {
                return Err(format!(
                    "print snapshot lost rendered content or restored ANSI background RGB; \
                     nontransparent_pixels={nontransparent_pixels}, ANSI background [7, 8, 9] pixels={styled_background_pixels}, \
                     ANSI foreground [12, 34, 56] pixels={styled_foreground_pixels}"
                ));
            }
            Ok(serde_json::json!({
                "png_bytes": bitmap.png.len(),
                "point_size": bitmap.point_size,
                "pixel_size": bitmap.pixel_size,
                "decoded_dimensions": decoded.dimensions(),
                "nontransparent_pixels": nontransparent_pixels,
                "expected_ansi_background_rgb": [7, 8, 9],
                "expected_ansi_background_pixel_count": styled_background_pixels,
                "expected_ansi_foreground_rgb": [12, 34, 56],
                "expected_ansi_foreground_pixel_count": styled_foreground_pixels,
                "displayed_cpu_cache_bytes_before": cache_before,
                "displayed_cpu_cache_bytes_after": cache_after,
                "print_panel_opened": false,
            }))
        })
        .map_err(error)?
}

fn memory_sample(id: u64, cx: &App) -> serde_json::Value {
    crate::memory_pressure::diagnostics(cx)["sessions"]
        .as_array()
        .and_then(|samples| {
            samples
                .iter()
                .find(|sample| sample["session_id"].as_u64() == Some(id))
        })
        .cloned()
        .unwrap_or(serde_json::Value::Null)
}
async fn verify_retention(
    handle: WindowHandle<Root>,
    ws: &Entity<Workspace>,
    ids: &[TabId],
    protected: &[(u64, Entity<TerminalSession>)],
    profile: &Profile,
    cx: &mut AsyncApp,
) -> Result<serde_json::Value, String> {
    cx.update(crate::memory_pressure::start);
    select(handle, ws, ids[4], cx)?;
    settle(handle, cx).await?;
    let (ordinary, memory_id) = cx.update(|cx| -> Result<_, String> {
        let panes = ws.read(cx).entries[&ids[4]].panes.read(cx);
        let session = panes
            .pane_sessions(cx)
            .into_iter()
            .next()
            .ok_or("ordinary PTY not activated")?
            .1;
        let view = panes
            .views()
            .into_iter()
            .next()
            .ok_or("ordinary terminal view absent")?;
        Ok((session, view.read(cx).memory_session_id(cx)))
    })?;
    profile.release_prompt(5)?;
    wait_until(cx, "ordinary native PTY history output", |cx| {
        ordinary
            .read(cx)
            .buffer_text()
            .contains("OWNED_HISTORY_199")
            && ordinary.read(cx).is_at_prompt()
    })
    .await?;
    let before = cx.update(|cx| ordinary.read(cx).buffer_text());
    cx.update(|cx| {
        ordinary.update(cx, |session, cx| {
            session.scroll_to_top();
            session.refresh(cx);
        });
    });
    let styled_cells_before =
        cx.update(|cx| ordinary.read(cx).with_terminal(styled_scrollback_sample))?;
    // A raw terminal scroll does not produce PTY output, so drive the same
    // session refresh the production scroll action uses before checking the
    // cached grid that print_snapshot paints.
    let cache_wait = wait_until(cx, "cached styled scrollback viewport for print", |cx| {
        let grid = &ordinary.read(cx).grid;
        grid.scrollback_rows > 0
            && grid.display_offset == grid.scrollback_rows
            && grid.cells.iter().any(|cell| cell.bg == (7, 8, 9))
    })
    .await;
    if let Err(wait_error) = cache_wait {
        let viewport = cx.update(|cx| styled_viewport_diagnostic(ordinary.read(cx)));
        return Err(format!("{wait_error}; viewport_diagnostic={viewport}"));
    }
    // Snapshot this real selected view at the retained styled marker. Decode
    // the production PNG and check its exact ANSI background RGB, without
    // opening or submitting an NSPrintOperation.
    settle(handle, cx).await?;
    let print_snapshot = capture_print_snapshot(handle, ws, ids[4], cx)?;
    let pty_bytes_before = cx.update(|cx| ordinary.read(cx).with_terminal(|term| term.stats().1));
    let cursor_before = cx.update(|cx| {
        ordinary
            .read(cx)
            .with_terminal(|term| term.cursor_position())
    });
    let history_rows_before = cx.update(|cx| {
        ordinary.read(cx).allocation_snapshot()["history_rows"]
            .as_u64()
            .unwrap_or(0)
    });
    ensure(
        history_rows_before > 50,
        "ordinary shell did not produce more than the Hidden ring budget",
    )?;
    select(handle, ws, ids[1], cx)?;
    settle(handle, cx).await?;
    let warm_started = Instant::now();
    let mut last_warm_sample = serde_json::Value::Null;
    let warm_result = wait_until(cx, "ordinary background Warm without pressure", |cx| {
        last_warm_sample = memory_sample(memory_id, cx);
        last_warm_sample["phase"] == "warm"
            && last_warm_sample["retained_on_disk"] == false
            && last_warm_sample["flushes"] == 0
    })
    .await;
    if let Err(wait_error) = warm_result {
        let elapsed_ms = warm_started.elapsed().as_millis();
        let (selected_tab, selected_session_ids, pressure) = cx.update(|cx| {
            let workspace = ws.read(cx);
            let selected_tab = workspace.state.selected();
            let selected_session_ids = workspace
                .selected_panes()
                .map(|panes| {
                    panes
                        .read(cx)
                        .pane_sessions(cx)
                        .into_iter()
                        .map(|(_, session)| session.read(cx).id)
                        .collect::<Vec<_>>()
                })
                .unwrap_or_default();
            let pressure = crate::memory_pressure::diagnostics(cx);
            (selected_tab, selected_session_ids, pressure)
        });
        let gpui_window = handle
            .update(cx, |_, window, _| {
                serde_json::json!({
                    "visible": window.is_visible(),
                    "active": window.is_window_active(),
                })
            })
            .unwrap_or(serde_json::Value::Null);
        let appkit_window = match MainThreadMarker::new() {
            Some(main) => match native_window(handle, cx) {
                Ok(native) => {
                    let application = NSApplication::sharedApplication(main);
                    serde_json::json!({
                        "available": true,
                        "application_active": application.isActive(),
                        "activation_policy": application.activationPolicy().0,
                        "visible": native.isVisible(),
                        "key": native.isKeyWindow(),
                        "miniaturized": native.isMiniaturized(),
                        "can_become_key": native.canBecomeKeyWindow(),
                        "occlusion_bits": native.occlusionState().0,
                    })
                }
                Err(error) => serde_json::json!({"available": false, "error": error}),
            },
            None => serde_json::json!({"available": false, "error": "not on AppKit main thread"}),
        };
        let diagnostic = serde_json::json!({
            "stage": "ordinary background Warm without pressure",
            "elapsed_ms": elapsed_ms,
            "last_memory_sample": last_warm_sample,
            "expected_main_tab_selected": selected_tab == Some(ids[1]),
            "ordinary_tab_selected": selected_tab == Some(ids[4]),
            "selected_session_ids": selected_session_ids,
            "ordinary_session_in_selected_panes": selected_session_ids.contains(&memory_id),
            "under_pressure": pressure["under_pressure"],
            "shed_best_effort": pressure["shed_best_effort"],
            "native_pressure_source": pressure["native_pressure_source"],
            "gpui_window": gpui_window,
            "appkit_window": appkit_window,
        });
        eprintln!("native_memory_warm_failure={diagnostic}");
        return Err(wait_error);
    }
    let protected_before: Vec<_> = cx.update(|cx| {
        protected
            .iter()
            .map(|(_, s)| {
                let s = s.read(cx);
                (
                    s.buffer_text(),
                    s.allocation_snapshot()["history_rows"].clone(),
                )
            })
            .collect()
    });
    cx.update(|cx| -> Result<(), String> {
        crate::memory_pressure::inject_native_fixture_critical(cx);
        ensure(
            ws.read(cx).entries[&ids[1]]
                .panes
                .read(cx)
                .views()
                .iter()
                .all(|view| view.read(cx).overlays.cache_bytes() == 0),
            "critical policy retained regenerable selected CPU caches",
        )
    })?;
    wait_until(
        cx,
        "ordinary Hidden worker persisted native history",
        |cx| {
            let sample = memory_sample(memory_id, cx);
            sample["phase"] == "hidden"
                && sample["retained_on_disk"] == true
                && sample["flushes"].as_u64().is_some_and(|n| n > 0)
        },
    )
    .await?;
    let flushed = cx.update(|cx| memory_sample(memory_id, cx));
    let hidden_rows = cx.update(|cx| {
        ordinary.read(cx).allocation_snapshot()["history_rows"]
            .as_u64()
            .unwrap_or(u64::MAX)
    });
    ensure(
        hidden_rows <= 50,
        "worker persisted history without reducing the real native Hidden ring",
    )?;
    cx.update(|cx| -> Result<(), String> {
        for ((_, session), (text, rows)) in protected.iter().zip(&protected_before) {
            let session = session.read(cx);
            ensure(
                session.allocation_snapshot()["render_phase"] == "active",
                "selected surface entered a Hidden phase under policy pressure",
            )?;
            ensure(
                session.buffer_text() == *text
                    && session.allocation_snapshot()["history_rows"] == *rows,
                "Hidden worker changed selected native history",
            )?;
        }
        Ok(())
    })?;
    select(handle, ws, ids[4], cx)?;
    settle(handle, cx).await?;
    wait_until(
        cx,
        "ordinary selected worker replayed retained native history",
        |cx| {
            let sample = memory_sample(memory_id, cx);
            sample["retained_on_disk"] == false && sample["reloads"].as_u64().is_some_and(|n| n > 0)
        },
    )
    .await?;
    let restored = cx.update(|cx| ordinary.read(cx).buffer_text());
    cx.update(|cx| {
        ordinary.update(cx, |session, cx| {
            session.scroll_to_top();
            session.refresh(cx);
        });
    });
    let styled_cells_after =
        cx.update(|cx| ordinary.read(cx).with_terminal(styled_scrollback_sample))?;
    ensure(
        styled_cells_after.get("cells") == styled_cells_before.get("cells"),
        "retained history reload changed actual terminal cell styles or graphemes",
    )?;
    let content_evidence = serde_json::json!({
        "before_bytes":before.len(),"after_bytes":restored.len(),
        "before_lines":before.lines().count(),"after_lines":restored.lines().count(),
        "before_sha256":chau7_next_core::session_restore::transaction::ContextRef::new(before.as_bytes()).sha256,
        "after_sha256":chau7_next_core::session_restore::transaction::ContextRef::new(restored.as_bytes()).sha256,
        "first_diff_byte":before.bytes().zip(restored.bytes()).position(|(a,b)|a!=b),
        "before_tail_bytes":before.as_bytes().iter().rev().take(16).copied().collect::<Vec<_>>(),
        "after_tail_bytes":restored.as_bytes().iter().rev().take(16).copied().collect::<Vec<_>>(),
        "same_except_final_newlines":before.trim_end_matches('\n')==restored.trim_end_matches('\n'),
        "missing_history_rows":(0..200).filter(|i| !restored.contains(&format!("OWNED_HISTORY_{i:03}"))).collect::<Vec<_>>(),
        "before_cursor":cursor_before,"after_cursor":cx.update(|cx| ordinary.read(cx).with_terminal(|term| term.cursor_position())),
        "styled_cells_before":styled_cells_before,"styled_cells_after":styled_cells_after
    });
    // The shared Swift/Next replay retains the final content row terminator.
    // A prompt at the viewport bottom can therefore add exactly one final LF.
    // Permit only that documented grid-padding case, preserving every byte in
    // its original order; never normalize arbitrary terminal whitespace.
    let raw_exact = restored == before;
    ensure(
        raw_exact || restored == format!("{before}\n"),
        &format!(
            "real retained history reload changed ordinary native contents: {content_evidence}"
        ),
    )?;
    ensure(
        (0..200).all(|i| {
            restored
                .matches(format!("OWNED_HISTORY_{i:03}").as_str())
                .count()
                == 1
        }),
        "retained worker did not preserve all 200 rows exactly once",
    )?;
    let pty_bytes_after = cx.update(|cx| ordinary.read(cx).with_terminal(|term| term.stats().1));
    ensure(
        pty_bytes_after == pty_bytes_before && profile.received(5).is_empty(),
        "ordinary fake PTY output or input changed during retention comparison",
    )?;
    let reloaded = cx.update(|cx| memory_sample(memory_id, cx));
    ensure(
        reloaded["failures"].as_u64() == Some(0),
        "ordinary retention worker reported a failure",
    )?;
    select(handle, ws, ids[1], cx)?;
    settle(handle, cx).await?;
    Ok(
        serde_json::json!({"pressure_source":"fixture_policy_injection","real_tick":true,
        "ordinary_worker_flushes":flushed["flushes"],"ordinary_worker_reloads":reloaded["reloads"],
        "native_history_rows_before":history_rows_before,"native_hidden_ring_rows":hidden_rows,
        "raw_native_history_exact":raw_exact,"native_history_round_trip_with_final_lf_padding":true,
        "content_evidence":content_evidence,"synthetic_rows_preserved_once":200,
        "ordinary_pty_bytes_before":pty_bytes_before,"ordinary_pty_bytes_after":pty_bytes_after,
        "ordinary_input_bytes":0,"ordinary_background_warm":true,"selected_history_preserved":true,
        "worker_failures":reloaded["failures"],"styled_cell_replay_exact":true,
        "print_snapshot":print_snapshot,"os_pressure_delivery_tested":false}),
    )
}

#[cfg(test)]
mod tests {
    use super::{
        RendererFrameCounters, RevealDiagnostic, SessionSurfaceDiagnostic, WindowFrameEvidence,
        activation_diagnostic, final_native_focus_ready, rendered_frame_delta,
        rendered_reveal_delta, restore_surface_frame_ready, successful_frame_delta,
        supplemental_renderer_delta,
    };

    #[test]
    fn post_demini_surface_gate_requires_visible_live_unsuspended_surface() {
        assert!(restore_surface_frame_ready(true, true, false));
        assert!(!restore_surface_frame_ready(false, true, false));
        assert!(!restore_surface_frame_ready(true, false, false));
        assert!(!restore_surface_frame_ready(true, true, true));
    }

    #[test]
    fn final_native_focus_gate_rejects_stolen_or_miniaturized_focus() {
        assert!(final_native_focus_ready(true, true, true, false));
        assert!(!final_native_focus_ready(false, true, true, false));
        assert!(!final_native_focus_ready(true, false, true, false));
        assert!(!final_native_focus_ready(true, true, false, false));
        assert!(!final_native_focus_ready(true, true, true, true));
    }

    #[test]
    fn reveal_frame_evidence_requires_a_later_clean_renderer_submission() {
        let before = RendererFrameCounters {
            submitted: 7,
            failed: 2,
        };
        assert_eq!(
            successful_frame_delta(
                before,
                RendererFrameCounters {
                    submitted: 8,
                    failed: 2,
                }
            ),
            Some(1)
        );
        assert_eq!(
            successful_frame_delta(
                before,
                RendererFrameCounters {
                    submitted: 7,
                    failed: 2,
                }
            ),
            None
        );
        assert_eq!(
            successful_frame_delta(
                before,
                RendererFrameCounters {
                    submitted: 8,
                    failed: 3,
                }
            ),
            None
        );
        assert_eq!(
            successful_frame_delta(
                before,
                RendererFrameCounters {
                    submitted: 6,
                    failed: 2,
                }
            ),
            None
        );
    }

    #[test]
    fn reveal_frame_evidence_requires_a_later_rendered_accessibility_frame() {
        assert_eq!(rendered_frame_delta(12, 13), Some(1));
        assert_eq!(rendered_frame_delta(12, 12), None);
        assert_eq!(rendered_frame_delta(12, 11), None);
        assert_eq!(rendered_reveal_delta(12, 13, 15), Some(3));
        assert_eq!(rendered_reveal_delta(12, 11, 15), None);
        assert_eq!(rendered_reveal_delta(12, 13, 12), None);
    }

    #[test]
    fn renderer_counters_are_supplemental_for_metal_and_strict_for_software() {
        let metal_before = WindowFrameEvidence {
            frame_number: 12,
            renderer_backend: Some("metal"),
            renderer_counters: None,
        };
        let metal_after = WindowFrameEvidence {
            frame_number: 13,
            renderer_backend: Some("metal"),
            renderer_counters: None,
        };
        assert_eq!(
            supplemental_renderer_delta(metal_before, metal_after),
            Some(None)
        );
        let metal_with_counters = WindowFrameEvidence {
            renderer_counters: Some(RendererFrameCounters {
                submitted: 7,
                failed: 2,
            }),
            ..metal_before
        };
        assert_eq!(
            supplemental_renderer_delta(metal_with_counters, metal_with_counters),
            None
        );

        let software_before = WindowFrameEvidence {
            renderer_backend: Some("software"),
            renderer_counters: Some(RendererFrameCounters {
                submitted: 7,
                failed: 2,
            }),
            ..metal_before
        };
        let software_after = WindowFrameEvidence {
            frame_number: 13,
            renderer_counters: Some(RendererFrameCounters {
                submitted: 8,
                failed: 2,
            }),
            ..software_before
        };
        assert_eq!(
            supplemental_renderer_delta(software_before, software_after),
            Some(Some(1))
        );

        let failed_after = WindowFrameEvidence {
            renderer_counters: Some(RendererFrameCounters {
                submitted: 8,
                failed: 3,
            }),
            ..software_after
        };
        assert_eq!(
            supplemental_renderer_delta(software_before, failed_after),
            None
        );

        let missing_software = WindowFrameEvidence {
            renderer_counters: None,
            ..software_before
        };
        assert_eq!(
            supplemental_renderer_delta(software_before, missing_software),
            None
        );
        let unsupported_backend = WindowFrameEvidence {
            renderer_backend: Some("unsupported"),
            ..metal_before
        };
        assert_eq!(
            supplemental_renderer_delta(unsupported_backend, unsupported_backend),
            None
        );
    }

    #[test]
    fn reveal_snapshot_preserves_each_conjunct_and_unknown_renderer_counts() {
        let snapshot = serde_json::to_value(RevealDiagnostic {
            stage: "actual deminiaturized surface reveal",
            app_active: true,
            activation_policy: 0,
            window_miniaturized: false,
            window_visible: true,
            window_key: false,
            window_can_become_key: true,
            window_occlusion_bits: 2,
            gpui_visible: false,
            gpui_active: false,
            selected_session_count: 2,
            session_sample_limit: 8,
            sessions: vec![SessionSurfaceDiagnostic {
                index: 0,
                visible: false,
                suspended: true,
                live_frame: false,
            }],
            renderer_backend: None,
            submitted_frames: None,
            failed_frames: Some(0),
        })
        .unwrap();
        assert_eq!(snapshot["window_visible"], true);
        assert_eq!(snapshot["gpui_visible"], false);
        assert_eq!(snapshot["window_key"], false);
        assert_eq!(snapshot["window_occlusion_bits"], 2);
        assert_eq!(
            snapshot["sessions"][0],
            serde_json::json!({
                "index": 0, "visible": false, "suspended": true, "live_frame": false,
            })
        );
        assert_eq!(snapshot["selected_session_count"], 2);
        assert_eq!(snapshot["session_sample_limit"], 8);
        assert!(snapshot["renderer_backend"].is_null());
        assert!(snapshot["submitted_frames"].is_null());
        assert_eq!(snapshot["failed_frames"], 0);
        assert_eq!(snapshot.as_object().unwrap().len(), 16);
    }

    #[test]
    fn activation_timeout_snapshot_preserves_observed_states_and_numeric_policy() {
        let inactive = activation_diagnostic(false, 0, true, false, true);
        assert_eq!(
            inactive,
            serde_json::json!({
                "stage": "owned_fixture_application_activation",
                "app_active": false,
                "activation_policy": 0,
                "window_visible": true,
                "window_key": false,
                "window_can_become_key": true,
            })
        );
        let alternate = activation_diagnostic(true, 2, false, true, false);
        assert_eq!(alternate["app_active"], true);
        assert_eq!(alternate["activation_policy"], 2);
        assert_eq!(alternate["window_visible"], false);
        assert_eq!(alternate["window_key"], true);
        assert_eq!(alternate["window_can_become_key"], false);
    }
}

#[cfg(test)]
mod fullscreen_menu_geometry_tests {
    use super::*;

    #[test]
    fn reserved_menu_band_does_not_overlap_touching_content() {
        let rect = |x, y, width, height| {
            objc2_foundation::NSRect::new(
                NSPoint::new(x, y),
                objc2_foundation::NSSize::new(width, height),
            )
        };
        let menu = rect(0.0, 949.0, 1512.0, 33.0);
        assert!(!native_rects_intersect(menu, rect(0.0, 0.0, 1512.0, 949.0)));
        assert!(native_rects_intersect(menu, rect(0.0, 0.0, 1512.0, 982.0)));
        assert!(!native_rects_intersect(
            menu,
            rect(1512.0, 0.0, 1920.0, 1080.0)
        ));
    }
}
