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
use objc2::{MainThreadMarker, rc::Retained};
use objc2_app_kit::{
    NSApplication, NSApplicationActivationPolicy, NSEvent, NSEventModifierFlags, NSEventType,
    NSView, NSWindow,
};
use objc2_foundation::{NSBundle, NSPoint, NSString};
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

fn styled_scrollback_sample(term: &Chau7Terminal) -> Result<serde_json::Value, String> {
    // Sample the first retained row, not the recent screen tail, before
    // persistence and after the production reload.
    term.scroll_to(1.0);
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

fn emit_activation_handshake(stage: &str, activation_ack_path: &Path) -> Result<(), String> {
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
    writeln!(stderr, "native_activation_handshake={handshake}").map_err(error)?;
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
    let deadline = Instant::now() + Duration::from_secs(5);
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
        for (directory, id) in directories.iter().zip(&ids) {
            std::fs::create_dir_all(directory).map_err(error)?;
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
    fn pane(&self, index: usize) -> SavedPane {
        SavedPane {
            id: 100 + index as u64,
            directory: Some(self.directories[index].to_string_lossy().into_owned()),
            ai_provider: Some("claude".into()),
            ai_session_id: Some(self.ids[index].clone()),
            ai_resume_command: Some(format!("claude --resume {}", self.ids[index])),
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
                    window_bounds: Some(WindowBounds::Windowed(Bounds::new(
                        gpui::point(px(0.), px(0.)),
                        size(px(1000.), px(600.)),
                    ))),
                    ..Default::default()
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
    crate::restore::preparation::register_saved_identity_hints(&profile.root, tabs.iter());
    cx.update(|cx| {
        let settings = cx.global_mut::<Settings>();
        settings.terminal.shell = Some(profile.shell.to_string_lossy().into_owned());
        settings.appearance.rendering.gpu_renderer = false;
        settings.appearance.rendering.suspend_background = true;
        settings.appearance.rendering.suspend_delay_secs = 0.05;
    });
    let (handle, ws) = cx
        .update(|cx| {
            gpui_kit::open_window(
                WindowOptions {
                    show: true,
                    focus: false,
                    window_bounds: Some(WindowBounds::Windowed(Bounds::new(
                        gpui::point(px(0.), px(0.)),
                        size(px(1000.), px(600.)),
                    ))),
                    ..Default::default()
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
            )
        })
        .map_err(error)?;
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
    // Wait through the actual one-second production readiness tick while the
    // target remains unselected. No manual timer/PTY driver is used here.
    pause(cx, Duration::from_millis(1100)).await;
    ensure(
        profile.received(1).is_empty() && profile.received(2).is_empty(),
        "readiness sent input to an unselected tab",
    )?;
    select(handle, &ws, ids[1], cx)?;
    settle(handle, cx).await?;
    wait_until(cx, "readiness-bound native resume bytes", |_| {
        [1, 2].into_iter().all(|i| !profile.received(i).is_empty())
    })
    .await?;
    for i in [1, 2] {
        ensure(
            profile.received(i) == format!("claude --resume {}", profile.ids[i]).as_bytes(),
            "native recorder saw changed, duplicate or submitted resume bytes",
        )?;
    }
    pause(cx, Duration::from_millis(1100)).await;
    for i in [1, 2] {
        ensure(
            profile.received(i) == format!("claude --resume {}", profile.ids[i]).as_bytes(),
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
        serde_json::json!({"restored_tabs":6,"selected_initial_ptys":2,"preserved_split_leaves":2,"native_identities":2,"quiet_period_ms":450,"observed_identity_admission_ms":admission_ms,"transient_selection_ptys":0,"parked_metadata_ptys":0,"resume_deliveries":2,"resume_line_terminators":0,"duplicate_deliveries":0,"closed_owned_ptys":closed,"surfaces":surface,"loading_clock":loading_clock,"manual_polling":false,"simulated_frames":false}),
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
    activate_owned_application(&application)?;
    if let Err(error) = wait_until(cx, "owned fixture application activation", |_| {
        application.isActive()
    })
    .await
    {
        // Capture this owned application's actual AppKit state at the failed
        // gate, before cleanup changes it. Keep the original failure and timer.
        let snapshot = activation_diagnostic(
            application.isActive(),
            application.activationPolicy().0,
            native.isVisible(),
            native.isKeyWindow(),
            native.canBecomeKeyWindow(),
        );
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
    cx.update(|cx| -> Result<(), String> {
        ensure(
            sessions.iter().all(|(_, s)| {
                s.read(cx).surface_has_live_frame() && !s.read(cx).is_render_suspended()
            }),
            "ordered-front reveal did not paint actual terminal surfaces",
        )
    })?;
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
    emit_activation_handshake("deminiaturized_surface_reveal", &activation_ack_path)?;
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
        serde_json::json!({"hover_live_budget_ms":2000,"hover_exit_budget_ms":500,
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
    let styled_cells_before =
        cx.update(|cx| ordinary.read(cx).with_terminal(styled_scrollback_sample))?;
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
        "worker_failures":reloaded["failures"],"styled_cell_replay_exact":true,"os_pressure_delivery_tested":false}),
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
