//! Actual native GPUI window, production restore and owned fake-shell PTYs.
use super::*;
use crate::native_parity_fixture::next_frame;
use crate::terminal::session::TerminalSession;
use chau7_next_core::data_root::DataRoot;
use chau7_next_core::session_restore::models::SavedPane;
use chau7_next_core::session_restore::{SavedAxis, SavedSplitNode};
use gpui::{AppContext, AsyncApp, WindowHandle, WindowOptions, size};
use gpui_kit::base::Root;
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
        std::fs::write(&shell, b"#!/bin/sh\n/bin/stty -echo -icanon min 1 time 0\nprintf started > started\nwhile [ ! -f ready ]; do /bin/sleep 0.01; done\nprintf '\x1b]133;A\x07fixture$ '\nexec /bin/cat > received\n").map_err(error)?;
        std::fs::set_permissions(&shell, std::fs::Permissions::from_mode(0o700)).map_err(error)?;
        let directories: Vec<_> = (0..5).map(|i| home.join(format!("pane-{i}"))).collect();
        let ids: Vec<_> = (0..5).map(|_| uuid::Uuid::new_v4().to_string()).collect();
        for (directory, id) in directories.iter().zip(&ids) {
            std::fs::create_dir_all(directory).map_err(error)?;
            let project = directory.to_string_lossy();
            let folder = home.join(".claude/projects").join(
                chau7_next_core::session_restore::claude_project_dir_name(&project),
            );
            std::fs::create_dir_all(&folder).map_err(error)?;
            std::fs::write(folder.join(format!("{id}.jsonl")), b"{}\n").map_err(error)?;
        }
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
    ];
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
        cx.global_mut::<Settings>().terminal.shell =
            Some(profile.shell.to_string_lossy().into_owned())
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
            for i in [0, 2, 3] {
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
        for i in [0, 2, 3] {
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
    let closed = dispose(cx).await?;
    Ok(
        serde_json::json!({"restored_tabs":4,"selected_initial_ptys":2,"preserved_split_leaves":2,"native_identities":2,"quiet_period_ms":450,"observed_identity_admission_ms":admission_ms,"transient_selection_ptys":0,"parked_metadata_ptys":0,"resume_deliveries":2,"resume_line_terminators":0,"duplicate_deliveries":0,"closed_owned_ptys":closed,"manual_polling":false,"simulated_frames":false}),
    )
}
