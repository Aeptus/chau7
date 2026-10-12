//! Actual native GPUI window, production restore and owned fake-shell PTYs.
use super::*;
use crate::native_parity_fixture::next_frame;
use crate::terminal::session::TerminalSession;
use chau7_next_core::data_root::DataRoot;
use chau7_next_core::session_restore::models::SavedPane;
use chau7_next_core::session_restore::{SavedAxis, SavedSplitNode};
use gpui::{AppContext, AsyncApp, WindowHandle, WindowOptions, size};
use gpui_kit::base::Root;
use objc2::{MainThreadMarker, rc::Retained};
use objc2_app_kit::{NSApplication, NSApplicationActivationPolicy, NSView, NSWindow};
use raw_window_handle::{HasWindowHandle, RawWindowHandle};
use std::os::unix::fs::PermissionsExt;

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
    native_mutation(|| {
        // SAFETY: this actual retained AppKit application is on the verified
        // main thread. Preserve GPUI's existing ignoring-other-apps selector.
        unsafe { objc2::msg_send![application, activateIgnoringOtherApps: true] }
    })
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
        let ordinary_history = (0..200)
            .map(|i| format!("OWNED_HISTORY_{i:03}\r\n"))
            .collect::<String>();
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
    native_mutation(|| native.orderFront(None))?;
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
    native_mutation(|| {
        native.orderFront(None);
        native.makeKeyWindow();
    })?;
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
    // One explicit activation/key sequence; polling observes without refocusing.
    native_mutation(|| native.orderFront(None))?;
    activate_owned_application(&application)?;
    native_mutation(|| native.makeKeyWindow())?;
    wait_for_reveal(
        handle,
        &native,
        &application,
        sessions,
        cx,
        "actual deminiaturized surface reveal",
        |cx| {
            !native.isMiniaturized()
                && application.isActive()
                && native.isVisible()
                && native.isKeyWindow()
                && sessions
                    .iter()
                    .all(|(_, s)| s.read(cx).restore_surface_visible())
        },
    )
    .await?;
    settle(handle, cx).await?;
    let key_window_observed = native.isKeyWindow();
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
    Ok(
        serde_json::json!({"hover_live_budget_ms":2000,"hover_exit_budget_ms":500,
        "hover_parked_ptys":0,"hidden_raw_grid_updated":true,"hidden_remote_grid_updated":true,
        "ordered_out_front":true,"native_mini_demini":true,"native_key_window":key_window_observed,"native_app_active":application.isActive(),"native_activation_policy_before":policy_before.0,"native_activation_policy_after":application.activationPolicy().0,"actual_reveal_frames":true,
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
    wait_until(cx, "ordinary background Warm without pressure", |cx| {
        let sample = memory_sample(memory_id, cx);
        sample["phase"] == "warm" && sample["retained_on_disk"] == false && sample["flushes"] == 0
    })
    .await?;
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
        "before_cursor":cursor_before,"after_cursor":cx.update(|cx| ordinary.read(cx).with_terminal(|term| term.cursor_position()))
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
        "worker_failures":reloaded["failures"],"os_pressure_delivery_tested":false}),
    )
}

#[cfg(test)]
mod activation_diagnostic_tests {
    use super::{RevealDiagnostic, SessionSurfaceDiagnostic, activation_diagnostic};

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
