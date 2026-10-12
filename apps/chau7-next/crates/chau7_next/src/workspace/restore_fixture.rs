//! Production restore acceptance with deterministic GPUI and owned native PTYs.
//! The fake shell only records bytes; it never interprets provider commands.
use super::*;
use crate::settings::config_files::ConfigFiles;
use crate::terminal::session::{ManuallyDrivenRestoreFixture, TerminalSession};
use chau7_next_core::data_root::DataRoot;
use chau7_next_core::session_restore::models::SavedPane;
use chau7_next_core::session_restore::{SavedAxis, SavedSplitNode};
use gpui::{AppContext, TestAppContext, WindowHandle, WindowOptions, size};
use gpui_kit::{base::Root, test::TestWindowExt};
use std::os::unix::fs::PermissionsExt;

struct Profile {
    home: PathBuf,
    root: DataRoot,
    shell: PathBuf,
    directories: Vec<PathBuf>,
    ids: Vec<String>,
}
impl Profile {
    fn new() -> Self {
        let home = std::env::temp_dir().join(format!("chau7-restore-pty-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&home).unwrap();
        let home = home.canonicalize().unwrap();
        let root = DataRoot::with_home(home.clone(), true);
        root.ensure_dirs().unwrap();
        let shell = home.join("fixture-shell");
        std::fs::write(&shell, b"#!/bin/sh\n/bin/stty -echo -icanon min 1 time 0\nprintf started > started\nwhile [ ! -f ready ]; do /bin/sleep 0.01; done\nprintf '\x1b]133;A\x07fixture$ '\nexec /bin/cat > received\n").unwrap();
        std::fs::set_permissions(&shell, std::fs::Permissions::from_mode(0o700)).unwrap();
        let directories: Vec<_> = (0..5).map(|i| home.join(format!("pane-{i}"))).collect();
        let ids: Vec<_> = (0..5).map(|_| uuid::Uuid::new_v4().to_string()).collect();
        for (directory, id) in directories.iter().zip(&ids) {
            std::fs::create_dir_all(directory).unwrap();
            let project = directory.to_string_lossy();
            let folder = home.join(".claude/projects").join(
                chau7_next_core::session_restore::claude_project_dir_name(&project),
            );
            std::fs::create_dir_all(&folder).unwrap();
            std::fs::write(folder.join(format!("{id}.jsonl")), b"{}\n").unwrap();
        }
        let history = directories
            .iter()
            .zip(&ids)
            .map(|(directory, id)| {
                serde_json::json!({"sessionId":id,"project":directory,"timestamp":1000}).to_string()
            })
            .collect::<Vec<_>>()
            .join("\n");
        std::fs::write(home.join(".claude/history.jsonl"), history).unwrap();
        Self {
            home,
            root,
            shell,
            directories,
            ids,
        }
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
    fn release_prompt(&self, index: usize) {
        std::fs::write(self.directories[index].join("ready"), b"ready").unwrap();
    }
}
impl Drop for Profile {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.home);
    }
}

fn render(cx: &mut TestAppContext, handle: WindowHandle<Root>) {
    cx.update_window(handle.into(), |_, window, cx| window.render_frame(cx))
        .unwrap();
    cx.run_until_parked();
}
fn settle(cx: &mut TestAppContext, handle: WindowHandle<Root>) {
    cx.run_until_parked();
    render(cx, handle);
    render(cx, handle);
}
fn select(cx: &mut TestAppContext, handle: WindowHandle<Root>, ws: &Entity<Workspace>, id: TabId) {
    cx.update_window(handle.into(), |_, window, cx| {
        ws.update(cx, |ws, cx| ws.select_tab(id, window, cx));
    })
    .unwrap();
}
fn poll(cx: &mut TestAppContext, sessions: &[(u64, Entity<TerminalSession>)]) {
    for (_, session) in sessions {
        cx.update(|cx| session.update(cx, |s, cx| s.poll_restore_fixture(cx)));
    }
    cx.run_until_parked();
}
fn wait_for(stage: &str, mut ready: impl FnMut() -> bool) {
    let started = Instant::now();
    while !ready() {
        assert!(
            started.elapsed() < Duration::from_secs(5),
            "owned fixture did not become ready: {stage}"
        );
        std::thread::sleep(Duration::from_millis(5));
    }
}
fn advance(cx: &mut TestAppContext, duration: Duration) {
    // The production selection deadline shares this monotonic timer clock.
    cx.executor().advance_clock(duration);
    cx.run_until_parked();
}

#[gpui::test]
fn production_selected_restore_fences_rapid_selection_and_real_resume_bytes(
    harness: &mut TestAppContext,
) {
    let profile = Profile::new();
    let mut fixture = harness.new_app();
    let cx = &mut fixture;
    let mut tabs = vec![
        profile.tab(&[0]),
        profile.tab(&[1, 2]),
        profile.tab(&[3]),
        profile.tab(&[4]),
    ];
    // A parked identity's real artifact repairs a stale saved directory only
    // after the production 450ms identity scheduler admits its result.
    let stale = profile.home.clone();
    tabs[0].cwd = Some(stale.clone());
    tabs[0].panes[0].directory = Some(stale.to_string_lossy().into_owned());
    tabs[0].layout = Some(SavedSplitNode::Terminal {
        id: 100,
        directory: Some(stale.to_string_lossy().into_owned()),
    });
    let selected_layout = tabs[1].layout.clone();
    let selected_uuid = tabs[1].uuid.unwrap();
    crate::restore::preparation::register_saved_identity_hints(&profile.root, tabs.iter());
    cx.update(|cx| {
        gpui_kit::init(cx);
        let mut settings = Settings::default();
        settings.terminal.shell = Some(profile.shell.to_string_lossy().into_owned());
        settings.cto.mode = chau7_next_core::token_optimization::TokenOptimizationMode::Off;
        settings.proxy.enabled = false;
        cx.set_global(AppData::new(profile.root.clone()));
        cx.set_global(ConfigFiles::new(
            profile.root.config_file(),
            settings.clone(),
        ));
        cx.set_global(settings);
        cx.set_global(ManuallyDrivenRestoreFixture);
        crate::observability::init_for_test(cx);
    });
    let (handle, ws) = cx.update(|cx| {
        gpui_kit::open_window(
            WindowOptions {
                window_bounds: Some(WindowBounds::Windowed(Bounds::new(
                    gpui::point(px(0.0), px(0.0)),
                    size(px(1000.0), px(600.0)),
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
        .unwrap()
    });
    let handle = handle.downcast::<Root>().unwrap();
    let outcome = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        let ids = cx.update(|cx| {
            ws.read(cx)
                .state
                .tabs()
                .iter()
                .map(|t| t.id)
                .collect::<Vec<_>>()
        });
        settle(cx, handle);
        let selected_panes = cx.update(|cx| {
            let ws = ws.read(cx);
            assert_eq!(ws.state.selected(), Some(ids[1]));
            assert_eq!(ws.state.get(ids[1]).unwrap().uuid, selected_uuid);
            for index in [0, 2, 3] {
                let tree = ws.entries[&ids[index]].panes.read(cx);
                assert!(tree.is_deferred());
                assert!(tree.pane_sessions(cx).is_empty());
            }
            let tree = ws.entries[&ids[1]].panes.read(cx);
            let actual_layout = tree.export_layout(cx).unwrap();
            let expected_layout = selected_layout.clone().unwrap();
            assert_eq!(actual_layout.terminal_ids(), expected_layout.terminal_ids());
            let SavedSplitNode::Split {
                axis,
                ratios,
                children,
                ..
            } = actual_layout
            else {
                panic!("restored two-terminal layout lost its split");
            };
            let SavedSplitNode::Split {
                axis: expected_axis,
                ratios: expected_ratios,
                children: expected_children,
                ..
            } = expected_layout
            else {
                unreachable!()
            };
            assert_eq!(axis, expected_axis);
            assert_eq!(ratios, expected_ratios);
            assert_eq!(children, expected_children);
            assert_eq!(tree.focused_pane_id(), Some(102));
            tree.pane_sessions(cx)
        });
        assert_eq!(selected_panes.len(), 2);
        for (pane, session) in &selected_panes {
            let index = (*pane - 100) as usize;
            cx.update(|cx| {
                let session = session.read(cx);
                assert!(session.shell_pid() > 0);
                assert_eq!(
                    session.shell().ai_session_id(),
                    Some(profile.ids[index].as_str())
                );
                assert!(session.has_pending_restore_resume());
            });
            wait_for("shell startup", || {
                profile.directories[index].join("started").exists()
            });
            assert!(profile.received(index).is_empty());
        }
        cx.update(|cx| {
            let (elapsed, slow) = ws
                .read(cx)
                .shell_loading_state(cx)
                .expect("actual unready PTY");
            assert!(elapsed > Duration::ZERO);
            assert!(!slow);
        });
        // Exercise actual select_tab and weak preparation callbacks. The two
        // briefly selected tabs may prepare metadata, but never acquire a PTY.
        advance(cx, Duration::from_millis(180));
        select(cx, handle, &ws, ids[2]);
        select(cx, handle, &ws, ids[3]);
        select(cx, handle, &ws, ids[1]);
        settle(cx, handle);
        advance(cx, Duration::from_millis(200));
        cx.update(|cx| {
            let ws = ws.read(cx);
            assert_eq!(
                ws.entries[&ids[0]]
                    .panes
                    .read(cx)
                    .deferred_saved()
                    .unwrap()
                    .cwd,
                Some(stale.clone())
            );
            for index in [0, 2, 3] {
                assert!(
                    ws.entries[&ids[index]]
                        .panes
                        .read(cx)
                        .pane_sessions(cx)
                        .is_empty()
                );
            }
        });
        // Delay dispatch independently of the clock: queued UI and worker work
        // must not admit parked identity before the selection quiet deadline.
        cx.executor()
            .dispatcher()
            .as_test()
            .unwrap()
            .scheduler()
            .clock()
            .advance(Duration::from_millis(249));
        cx.update(|cx| {
            let ws = ws.read(cx);
            assert_eq!(
                cx.background_executor()
                    .now()
                    .saturating_duration_since(ws.restore_lifecycle.last_selection.unwrap()),
                Duration::from_millis(449)
            );
            assert_eq!(
                ws.entries[&ids[0]]
                    .panes
                    .read(cx)
                    .deferred_saved()
                    .unwrap()
                    .cwd,
                Some(stale.clone())
            );
        });
        cx.run_until_parked();
        cx.update(|cx| {
            let ws = ws.read(cx);
            let tree = ws.entries[&ids[0]].panes.read(cx);
            assert_eq!(tree.deferred_saved().unwrap().cwd, Some(stale.clone()));
            assert!(tree.pane_sessions(cx).is_empty());
        });
        advance(cx, Duration::from_millis(1));
        settle(cx, handle);
        cx.update(|cx| {
            let ws = ws.read(cx);
            assert_eq!(
                cx.background_executor()
                    .now()
                    .saturating_duration_since(ws.restore_lifecycle.last_selection.unwrap()),
                Duration::from_millis(450)
            );
            let tree = ws.entries[&ids[0]].panes.read(cx);
            assert_eq!(
                tree.deferred_saved().unwrap().cwd,
                Some(profile.directories[0].clone())
            );
            assert!(tree.pane_sessions(cx).is_empty());
        });
        advance(cx, Duration::from_millis(50));
        settle(cx, handle);
        cx.update(|cx| {
            let tree = ws.read(cx).entries[&ids[0]].panes.read(cx);
            assert_eq!(
                tree.deferred_saved().unwrap().cwd,
                Some(profile.directories[0].clone())
            );
            assert!(
                tree.pane_sessions(cx).is_empty(),
                "metadata hydration must not launch a shell"
            );
        });
        // Native prompt readiness alone cannot send bytes to an unselected tab.
        select(cx, handle, &ws, ids[3]);
        settle(cx, handle);
        for index in [1, 2] {
            profile.release_prompt(index);
        }
        wait_for("native prompt", || {
            poll(cx, &selected_panes);
            cx.update(|cx| {
                selected_panes
                    .iter()
                    .all(|(_, s)| s.read(cx).is_at_prompt())
            })
        });
        for index in [1, 2] {
            assert!(profile.received(index).is_empty());
        }
        select(cx, handle, &ws, ids[1]);
        settle(cx, handle);
        wait_for("resume bytes", || {
            poll(cx, &selected_panes);
            (1..=2).all(|i| !profile.received(i).is_empty())
        });
        for index in [1, 2] {
            assert_eq!(
                profile.received(index),
                format!("claude --resume {}", profile.ids[index]).as_bytes()
            );
            assert!(
                !profile
                    .received(index)
                    .iter()
                    .any(|b| matches!(b, b'\r' | b'\n'))
            );
        }
        poll(cx, &selected_panes);
        for index in [1, 2] {
            assert_eq!(
                profile.received(index),
                format!("claude --resume {}", profile.ids[index]).as_bytes(),
                "prefill delivered exactly once"
            );
        }
        // Readiness comes from the real session, not its currently painted
        // grid. A clear-screen escape leaves (0,0) and a blank first row but
        // must not restart startup UI or its animation clock.
        let focused = &selected_panes[1].1;
        cx.update(|cx| {
            assert!(ws.read(cx).shell_loading_state(cx).is_none());
            focused.update(cx, |session, cx| {
                session.with_terminal(|term| term.inject_output(b"\x1b[2J\x1b[H"));
                session.refresh(cx);
                assert_eq!(session.cursor, (0, 0));
                assert!(
                    session
                        .line_text(0)
                        .is_none_or(|line| line.trim().is_empty())
                );
                assert!(!session.is_loading());
            });
            assert!(ws.read(cx).shell_loading_state(cx).is_none());
        });
        settle(cx, handle);
        cx.update(|cx| assert!(ws.read(cx).shell_loading_tick.is_none()));
    }));
    // All subprocesses belong to this fixture and close through the normal
    // production close path before the owned app/profile are disposed.
    let sessions = cx.update(|cx| {
        let sessions: Vec<_> = ws
            .read(cx)
            .entries
            .values()
            .flat_map(|e| e.panes.read(cx).pane_sessions(cx))
            .collect();
        for (_, session) in &sessions {
            session.update(cx, |s, _| s.close());
        }
        sessions
    });
    wait_for("graceful PTY exit", || {
        poll(cx, &sessions);
        cx.update(|cx| sessions.iter().all(|(_, s)| s.read(cx).exited.is_some()))
    });
    cx.update_window(handle.into(), |_, window, _| window.remove_window())
        .unwrap();
    if let Some(worker) = cx.update(crate::observability::shutdown) {
        worker.join().unwrap();
    }
    cx.run_until_parked();
    cx.quit();
    drop(sessions);
    drop(ws);
    cx.run_until_parked();
    drop(fixture);
    if let Err(error) = outcome {
        std::panic::resume_unwind(error);
    }
}
