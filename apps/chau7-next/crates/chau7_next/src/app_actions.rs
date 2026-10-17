//! App-wide actions and lifecycle: quit (with the running-process
//! confirmation), hide and show, the windows that survive Close Window, shortcuts
//! with no window open, URL scheme links, the hidden preferences (menu bar
//! only mode, floating windows).
//!
//! `AppDelegate.swift` (`applicationShouldTerminate`,
//! `applicationShouldHandleReopen`, `ensureActiveOverlayModel`,
//! `handleChau7URL`) and the standard app menu items.

use std::cell::Cell;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::time::Duration;

use chau7_next_core::app_shell::{self, AppUrl};
use gpui::{Action, AnyWindowHandle, App, Entity, PromptLevel};

use crate::actions::*;
use crate::platform::{self, EventQueue};
use crate::workspace::{AppData, ParkedWindow, Workspace};

/// A quit confirmation is on screen; a second Cmd+Q does not stack another.
/// Calls of [`poll`], to run slower jobs every few of them.
static POLL_TICKS: AtomicUsize = AtomicUsize::new(0);
static QUIT_PROMPT_OPEN: AtomicBool = AtomicBool::new(false);

/// Links opened with the URL scheme, queued by the OS callback (which has no
/// access to the app) and handled on the main thread by [`poll`].
static OPEN_URLS: EventQueue<String> = EventQueue::new();

/// Queue links the OS asked us to open.
pub fn queue_open_urls(urls: Vec<String>) {
    for url in urls {
        OPEN_URLS.push(url);
    }
}

pub fn register(cx: &mut App) {
    cx.on_action(|_: &Quit, cx| request_quit(cx));
    cx.on_action(|_: &HideApp, cx| cx.hide());
    cx.on_action(|_: &HideOtherApps, cx| cx.hide_other_apps());
    cx.on_action(|_: &ShowAllApps, cx| cx.unhide_other_apps());
    register_window_fallbacks(cx);
    crate::views::register(cx);
    crate::migration::register(cx);
    cx.on_action(|_: &DataExplorer, cx| crate::data_explorer::open(cx));
    cx.on_action(|_: &BringAllToFront, cx| bring_all_to_front(cx));
    cx.on_action(|_: &ShowTerminalAnalytics, cx| crate::analytics::open(cx));
}

/// Window > Bring All to Front (`arrangeInFront:`): every window of the app
/// comes above other apps' windows, the key window last so it stays on top.
fn bring_all_to_front(cx: &mut App) {
    cx.activate(true);
    let key = cx.active_window();
    for handle in cx.windows() {
        if Some(handle) != key {
            let _ = handle.update(cx, |_, window, _| window.activate_window());
        }
    }
    if let Some(key) = key {
        let _ = key.update(cx, |_, window, _| window.activate_window());
    }
}

/// Menu bar only mode: no Dock icon, the app lives in its menu bar item (the
/// command center, `status_bar`).
pub fn apply_menu_bar_only_mode(cx: &mut App) {
    if !crate::settings::Settings::get(cx).appearance.menu_bar_only {
        return;
    }
    if let Err(err) = platform::attention::set_dock_icon_visible(false) {
        log::warn!("menu bar only mode: {err}");
    }
}

/// Handle what the OS queued since the last call: links and menu bar item
/// choices. Called from a timer on the main thread.
pub fn poll(cx: &mut App) {
    let _callback = chau7_next_core::work_profiler::timer_callback(
        "app.poll",
        "callback",
        chau7_next_core::work_profiler::Queue::Main,
    );
    // About once a second: the config file and the active directory's repo
    // config (`ConfigFileWatcher`).
    crate::settings::sync::tick(cx);
    let tick = POLL_TICKS.fetch_add(1, Ordering::Relaxed);
    if tick.is_multiple_of(7) {
        let directory = active_workspace(cx).and_then(|(_, ws)| ws.read(cx).active_directory(cx));
        crate::settings::config_files::tick(cx, directory);
    }
    for url in OPEN_URLS.drain() {
        handle_url(&url, cx);
    }
    deliver_platform_input(cx);
    for event in platform::status_item::drain_events() {
        crate::status_bar::handle_event(event, cx);
    }
    crate::status_bar::poll(cx);
    crate::views::poll(cx);
}

/// Image data dropped on a terminal window (RBK-051) and text returned by
/// a macOS service (RBK-042): pasted into the focused terminal of that window.
fn deliver_platform_input(cx: &mut App) {
    let drops = platform::drop_image::drain_events();
    let returned = platform::services::drain_returned_text();
    if drops.is_empty() && returned.is_empty() {
        return;
    }
    for (handle, ws) in AppData::live(cx) {
        let Some(key) = handle
            .update(cx, |_, window, _| platform::drop_image::window_key(window))
            .ok()
            .flatten()
        else {
            continue;
        };
        let view = ws
            .read(cx)
            .selected_panes()
            .and_then(|p| p.read(cx).focused_view());
        let Some(view) = view else {
            continue;
        };
        for drop in drops.iter().filter(|d| d.window == key) {
            view.update(cx, |v, cx| v.paste_image_data(&drop.data, cx));
        }
        for returned in returned.iter().filter(|t| t.window == key) {
            view.update(cx, |v, cx| v.paste_text(&returned.text, cx));
        }
    }
}

// ----- windows -------------------------------------------------------------

/// The window of the app that was used last, else any, among the terminal
/// windows (the settings window and others do not count).
pub(crate) fn active_workspace(cx: &App) -> Option<(AnyWindowHandle, Entity<Workspace>)> {
    let windows = AppData::live(cx);
    let active = cx.active_window();
    windows
        .iter()
        .find(|(handle, _)| Some(*handle) == active)
        .or_else(|| windows.first())
        .cloned()
}

/// Bring a terminal window to the front: the one that was hidden last, or a
/// new one (`showOverlay`).
pub fn show_overlay(cx: &mut App) {
    if let Some(parked) = cx.global_mut::<AppData>().hidden.pop() {
        open_parked_window_or_requeue(parked, cx, crate::open_parked_window);
    } else if let Some((handle, _)) = active_workspace(cx) {
        let _ = handle.update(cx, |_, window, _| window.activate_window());
    } else {
        crate::open_workspace_window(None, cx);
    }
    cx.activate(true);
}

fn open_parked_window_or_requeue(
    parked: ParkedWindow,
    cx: &mut App,
    open: impl FnOnce(ParkedWindow, &mut App) -> Result<(), ParkedWindow>,
) {
    if let Err(parked) = open(parked, cx) {
        cx.global_mut::<AppData>().hidden.push(parked);
    }
}

/// A terminal window to act on, created when none is open
/// (`ensureActiveOverlayModel`). The flag says it was just created.
fn ensure_workspace(cx: &mut App) -> Option<(AnyWindowHandle, Entity<Workspace>, bool)> {
    if let Some((handle, workspace)) = active_workspace(cx) {
        return Some((handle, workspace, false));
    }
    show_overlay(cx);
    let (handle, workspace) = active_workspace(cx)?;
    Some((handle, workspace, true))
}

/// Parked windows (Close Window) hold shells too.
pub fn hidden_windows(cx: &App) -> &[ParkedWindow] {
    &cx.global::<AppData>().hidden
}

thread_local! {
    /// An action is being forwarded to a terminal window; do not forward it
    /// again if that window does not handle it either.
    static FORWARDING: Cell<bool> = const { Cell::new(false) };
}

/// Shortcuts and menu items act on a terminal window even when no window is
/// open or another window (settings) has the focus: a window is created or
/// brought forward and the action is delivered to it. The workspace handles
/// these actions itself first, so this only runs when it was not reached.
fn register_window_fallbacks(cx: &mut App) {
    fn forward<A: Action + Clone>(cx: &mut App) {
        cx.on_action(move |action: &A, cx| {
            if FORWARDING.with(Cell::get) {
                return;
            }
            let Some((handle, _, created)) = ensure_workspace(cx) else {
                return;
            };
            let boxed = action.boxed_clone();
            FORWARDING.with(|f| f.set(true));
            let deliver = move |cx: &mut App| {
                let _ = handle.update(cx, |_, window, cx| {
                    window.activate_window();
                    window.dispatch_action(boxed, cx);
                });
                FORWARDING.with(|f| f.set(false));
            };
            if created {
                // Let the new window draw once, so its handlers exist.
                cx.spawn(async move |cx| {
                    cx.background_executor()
                        .timer(Duration::from_millis(150))
                        .await;
                    cx.update(deliver);
                })
                .detach();
            } else {
                cx.defer(deliver);
            }
        });
    }
    // A new window already starts with one tab: creating it is the action.
    cx.on_action(|_: &NewTab, cx| {
        if FORWARDING.with(Cell::get) {
            return;
        }
        match active_workspace(cx) {
            Some((handle, _)) => {
                FORWARDING.with(|f| f.set(true));
                cx.defer(move |cx| {
                    let _ = handle.update(cx, |_, window, cx| {
                        window.activate_window();
                        window.dispatch_action(Box::new(NewTab), cx);
                    });
                    FORWARDING.with(|f| f.set(false));
                });
            }
            None => show_overlay(cx),
        }
    });
    forward::<CloseTab>(cx);
    forward::<CloseOtherTabs>(cx);
    forward::<ReopenClosedTab>(cx);
    forward::<NextTab>(cx);
    forward::<PreviousTab>(cx);
    forward::<MoveTabLeft>(cx);
    forward::<MoveTabRight>(cx);
    forward::<RenameTab>(cx);
    forward::<SelectTabNumber>(cx);
    forward::<SplitRight>(cx);
    forward::<OpenTextEditor>(cx);
    forward::<OpenFilePreview>(cx);
    forward::<OpenDiffViewer>(cx);
    forward::<OpenRepositoryPane>(cx);
    forward::<AppendSelectionToEditor>(cx);
    forward::<ShowChangedFiles>(cx);
    forward::<SplitDown>(cx);
    forward::<ClosePane>(cx);
    forward::<FocusNextPane>(cx);
    forward::<FocusPreviousPane>(cx);
    forward::<ToggleSearch>(cx);
    forward::<FindNext>(cx);
    forward::<FindPrevious>(cx);
    forward::<ToggleSnippets>(cx);
    forward::<ToggleCommandPalette>(cx);
    forward::<ShowClipboardHistory>(cx);
    forward::<ShowCommandHistory>(cx);
    forward::<ShowSshHosts>(cx);
    forward::<ToggleBroadcast>(cx);
    forward::<IncreaseFontSize>(cx);
    forward::<DecreaseFontSize>(cx);
    forward::<ResetFontSize>(cx);
    forward::<ExportText>(cx);
    forward::<ClearScreen>(cx);
    forward::<ClearScrollback>(cx);
}

// ----- quit ----------------------------------------------------------------

/// Names of every process running under any tab's shell, in every window,
/// hidden ones included.
pub fn running_process_names(cx: &App) -> Vec<String> {
    let mut names = Vec::new();
    for (_, workspace) in AppData::live(cx) {
        names.extend(workspace.read(cx).running_process_names(cx));
    }
    for parked in hidden_windows(cx) {
        for (_, panes) in &parked.tabs {
            names.extend(panes.read(cx).running_process_names(cx));
        }
    }
    names
}

/// Cmd+Q: ask first when processes run in any tab, then save and quit.
pub fn request_quit(cx: &mut App) {
    // Resolve prompt targets only after the current action/window update has
    // returned its active window to GPUI's handle map.
    cx.defer(request_quit_after_window_update);
}

fn request_quit_after_window_update(cx: &mut App) {
    let Some((title, detail)) = app_shell::quit_confirmation_localized(
        &running_process_names(cx),
        chau7_next_core::l10n::current(),
    ) else {
        quit_now(cx);
        return;
    };
    if QUIT_PROMPT_OPEN.swap(true, Ordering::SeqCst) {
        return;
    }
    // Any open window can show the alert; a parked-only app gets a new window.
    if active_workspace(cx).is_none() && cx.windows().is_empty() {
        show_overlay(cx);
    }
    let target = active_workspace(cx)
        .map(|(handle, _)| handle)
        .or_else(|| cx.windows().first().copied());
    let answer = target.and_then(|handle| {
        handle
            .update(cx, |_, window, cx| {
                window.activate_window();
                crate::l10n::prompt(
                    window,
                    PromptLevel::Warning,
                    &title,
                    Some(&detail),
                    &["Quit", "Cancel"],
                    cx,
                )
            })
            .ok()
    });
    let Some(answer) = answer else {
        QUIT_PROMPT_OPEN.store(false, Ordering::SeqCst);
        log::warn!("Cannot show quit confirmation; leaving the app running");
        return;
    };
    cx.spawn(async move |cx| {
        let confirmed = answer.await.ok() == Some(0);
        QUIT_PROMPT_OPEN.store(false, Ordering::SeqCst);
        if confirmed {
            cx.update(quit_now);
        }
    })
    .detach();
}

fn quit_now(cx: &mut App) {
    // Quit can be dispatched while GPUI has temporarily taken the active
    // window out of its handle map for a nested update. Run the final capture
    // at the end of this effect cycle, after all stacked windows are restored.
    cx.defer(|cx| {
        if !crate::save_session(cx, true) {
            log::warn!("Quit canceled because a complete restore snapshot could not be queued");
            return;
        }
        crate::settings::sync::push_now(cx);
        platform::power::end_latency_critical();
        cx.quit();
    });
}

// ----- URL scheme ----------------------------------------------------------

/// `chau7-next://run|ssh|cd|open/...` (`handleChau7URL`).
pub fn handle_url(url: &str, cx: &mut App) {
    log::info!("URL handler: {url}");
    match app_shell::parse_url(url) {
        Ok(AppUrl::Run { command, source }) => {
            let detail = app_shell::run_confirmation_detail(&command, &source);
            confirm_and_run("Run command from URL?", "Run", detail, command, cx);
        }
        Ok(parsed @ AppUrl::Ssh { .. }) => {
            let AppUrl::Ssh { target } = &parsed else {
                return;
            };
            let detail = app_shell::ssh_confirmation_detail(target, url);
            if let Some(command) = parsed.tab_command() {
                confirm_and_run("Connect with SSH?", "Connect", detail, command, cx);
            }
        }
        Ok(parsed @ AppUrl::Cd { .. }) => {
            if let Some(command) = parsed.tab_command() {
                open_tab_with_command(command, cx);
            }
        }
        Ok(AppUrl::Open { path }) => open_in_editor(path, cx),
        Err(err) => log::warn!("URL {url}: {err:?}"),
    }
}

/// `chau7-next://open/<path>`: a new editor pane in the current tab
/// (`openTextEditorInCurrentTab(filePath:)`).
fn open_in_editor(path: String, cx: &mut App) {
    let Some((handle, workspace, _)) = ensure_workspace(cx) else {
        return;
    };
    cx.activate(true);
    let _ = handle.update(cx, |_, window, cx| {
        window.activate_window();
        workspace.update(cx, |ws, cx| ws.open_text_editor(path.into(), window, cx));
    });
}

fn confirm_and_run(
    title: &'static str,
    confirm: &'static str,
    detail: String,
    command: String,
    cx: &mut App,
) {
    let Some((handle, _, _)) = ensure_workspace(cx) else {
        return;
    };
    let answer = handle.update(cx, |_, window, cx| {
        window.activate_window();
        crate::l10n::prompt(
            window,
            PromptLevel::Warning,
            title,
            Some(&detail),
            &[confirm, "Cancel"],
            cx,
        )
    });
    let Ok(answer) = answer else {
        return;
    };
    cx.spawn(async move |cx| {
        if answer.await.ok() == Some(0) {
            cx.update(|cx| open_tab_with_command(command, cx));
        }
    })
    .detach();
}

fn open_tab_with_command(command: String, cx: &mut App) {
    let Some((handle, workspace, _)) = ensure_workspace(cx) else {
        return;
    };
    cx.activate(true);
    let _ = handle.update(cx, |_, window, cx| {
        window.activate_window();
        workspace.update(cx, |ws, cx| ws.new_tab_with_command(command, window, cx));
    });
}

#[cfg(all(test, unix))]
mod quit_tests {
    use super::*;
    use crate::{
        pane::PaneTree,
        session_store::{SavedPane, SavedSession, SavedTab, SavedWindow},
        settings::Settings,
        workspace::AppData,
    };
    use chau7_next_core::{
        data_root::DataRoot,
        session_restore::{SavedAxis, SavedSplitNode, models::ArchivedTabContext},
        tabs_state::{TabColor, TabMeta},
    };
    use gpui::{App, AppContext, TestAppContext};

    fn init(harness: &mut TestAppContext) -> DataRoot {
        let root = DataRoot::with_home(
            std::env::temp_dir().join(format!("chau7-quit-{}", uuid::Uuid::new_v4())),
            true,
        );
        root.ensure_dirs().expect("create owned quit-test profile");
        let fake_shell = root.home().join("quit-test-shell");
        std::fs::write(
            &fake_shell,
            b"#!/bin/sh\nprintf started > quit-test-shell-started\nexec /bin/cat > quit-test-shell-input\n",
        )
        .expect("write owned quit-test shell");
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&fake_shell, std::fs::Permissions::from_mode(0o700))
                .expect("make owned quit-test shell executable");
        }
        harness.update(|cx| {
            gpui_kit::init(cx);
            let mut settings = Settings::default();
            settings.general.full_disk_access_guard_enabled = false;
            settings.terminal.shell = Some(fake_shell.to_string_lossy().into_owned());
            cx.set_global(settings);
            cx.set_global(AppData::new(root.clone()));
            #[cfg(unix)]
            cx.set_global(crate::terminal::session::ManuallyDrivenRestoreFixture);
            crate::terminal::command_guard::init(cx);
            crate::observability::init_for_test(cx);
            crate::restore::writer::init(cx);
        });
        root
    }

    fn open_two_windows(
        cx: &mut App,
    ) -> (
        AnyWindowHandle,
        Entity<Workspace>,
        AnyWindowHandle,
        Entity<Workspace>,
    ) {
        open_two_windows_with_scrollback(cx, false)
    }

    fn open_two_windows_with_scrollback(
        cx: &mut App,
        has_scrollback: bool,
    ) -> (
        AnyWindowHandle,
        Entity<Workspace>,
        AnyWindowHandle,
        Entity<Workspace>,
    ) {
        let (first_handle, first) = crate::open_window_for_transfer(cx).unwrap();
        let first_panes = cx.new(|_| PaneTree::empty_for_test());
        let mut first_meta = TabMeta::new(0, TabColor::Blue);
        first_meta.custom_title = Some("first-window-live".into());
        first.update(cx, |workspace, cx| {
            workspace.adopt_tab_public(first_meta, first_panes, true, cx)
        });

        let (second_handle, second) = crate::open_window_for_transfer(cx).unwrap();
        let second_tab_uuid = uuid::Uuid::new_v4();
        let fresh_tab = SavedTab {
            uuid: Some(second_tab_uuid),
            layout: Some(SavedSplitNode::Split {
                id: 8303,
                axis: SavedAxis::Horizontal,
                ratios: vec![0.65, 0.35],
                children: vec![
                    SavedSplitNode::Terminal {
                        id: 8301,
                        directory: Some("/tmp/quit-test".into()),
                    },
                    SavedSplitNode::Editor {
                        id: 8302,
                        path: Some("/tmp/quit-test.md".into()),
                    },
                ],
            }),
            focused_pane: Some(8302),
            archived_context: Some(ArchivedTabContext {
                command_blocks: Some(vec![serde_json::json!({
                    "name": "latest codex session",
                    "command": "codex resume thread-prequit-window-two"
                })]),
                preview_snapshot_png_data: Some("dGVzdC1jb250ZXh0".into()),
            }),
            panes: vec![SavedPane {
                id: 8301,
                scrollback: has_scrollback,
                ai_provider: Some("codex".into()),
                ai_session_id: Some("thread-prequit-window-two".into()),
                ai_resume_command: Some("codex resume thread-prequit-window-two".into()),
                last_exit_code: Some(73),
                ..Default::default()
            }],
            ..Default::default()
        };
        let second_panes = second_handle
            .update(cx, |_, window, cx| {
                cx.new(|cx| {
                    PaneTree::from_saved_deferred_with_owner(
                        Some(&fresh_tab),
                        None,
                        second_tab_uuid,
                        window,
                        cx,
                    )
                })
            })
            .unwrap();
        let mut second_meta = TabMeta::new(0, TabColor::Blue);
        second_meta.custom_title = Some("second-window-fresh-at-quit".into());
        second.update(cx, |workspace, cx| {
            workspace.adopt_tab_public(second_meta, second_panes, true, cx)
        });
        (first_handle, first, second_handle, second)
    }

    fn park_window(handle: AnyWindowHandle, workspace: Entity<Workspace>, cx: &mut App) {
        let parked = handle
            .update(cx, |_, window, cx| {
                let parked = workspace.update(cx, |workspace, _| workspace.park_tabs(window));
                window.remove_window();
                parked
            })
            .expect("remove the native test window")
            .expect("test window has a tab to park");
        cx.global_mut::<AppData>().hidden.push(parked);
    }

    fn saved_after_writer_shutdown(harness: &mut TestAppContext, root: &DataRoot) -> SavedSession {
        harness.run_until_parked();
        let writer = harness
            .update(crate::restore::writer::shutdown)
            .expect("restore writer was initialized");
        writer.join().expect("restore writer joins");
        crate::session_store::load(root).expect("restore snapshot was saved")
    }

    fn previous_complete_session() -> SavedSession {
        SavedSession {
            version: 1,
            windows: ["previous-window-one", "previous-window-two"]
                .into_iter()
                .map(|title| SavedWindow {
                    tabs: vec![SavedTab {
                        custom_title: Some(title.into()),
                        ..Default::default()
                    }],
                    ..Default::default()
                })
                .collect(),
        }
    }

    #[gpui::test]
    fn failed_nested_window_capture_keeps_the_previous_complete_snapshot(
        harness: &mut TestAppContext,
    ) {
        let root = init(harness);
        let (first_window, _, second_window, _) = harness.update(open_two_windows);
        let previous = previous_complete_session();
        crate::session_store::save(&root, &previous).unwrap();

        // During a nested update GPUI temporarily removes the current window
        // from the handle map. A failed capture must not submit window one's
        // successful snapshot by itself.
        second_window
            .update(harness, |_, _, cx| {
                assert!(first_window.update(cx, |_, _, _| ()).is_ok());
                assert!(second_window.update(cx, |_, _, _| ()).is_err());
                assert!(!crate::save_session(cx, false));
            })
            .unwrap();
        harness.run_until_parked();

        let writer = harness
            .update(crate::restore::writer::shutdown)
            .expect("restore writer was initialized");
        writer.join().expect("restore writer joins");
        let saved = crate::session_store::load(&root).unwrap();
        assert_eq!(saved.windows.len(), 2);
        assert_eq!(
            saved.windows[0].tabs[0].custom_title.as_deref(),
            Some("previous-window-one")
        );
        assert_eq!(
            saved.windows[1].tabs[0].custom_title.as_deref(),
            Some("previous-window-two")
        );
        let _ = std::fs::remove_dir_all(root.home());
    }

    #[gpui::test]
    fn cmd_q_from_second_window_saves_its_fresh_metadata_and_both_windows(
        harness: &mut TestAppContext,
    ) {
        let root = init(harness);
        let (_, _, second_window, _) = harness.update(open_two_windows);

        // This is the normal Cmd+Q handler, invoked while window two is still
        // on the Window::update stack. Its deferred capture must run after that
        // stack has returned so the final restore manifest contains both.
        second_window
            .update(harness, |_, _, cx| request_quit(cx))
            .unwrap();
        harness.run_until_parked();

        let writer = harness
            .update(crate::restore::writer::shutdown)
            .expect("restore writer was initialized");
        writer.join().expect("restore writer joins");
        let saved = crate::session_store::load(&root).unwrap();
        assert_eq!(saved.windows.len(), 2);
        assert_eq!(
            saved.windows[0].tabs[0].custom_title.as_deref(),
            Some("first-window-live")
        );
        let second_tab = &saved.windows[1].tabs[0];
        assert_eq!(
            second_tab.custom_title.as_deref(),
            Some("second-window-fresh-at-quit")
        );
        let pane = &second_tab.panes[0];
        assert_eq!(
            pane.ai_session_id.as_deref(),
            Some("thread-prequit-window-two")
        );
        assert_eq!(
            pane.ai_resume_command.as_deref(),
            Some("codex resume thread-prequit-window-two")
        );
        assert_eq!(pane.last_exit_code, Some(73));
        let _ = std::fs::remove_dir_all(root.home());
    }

    #[gpui::test]
    fn autosave_includes_parked_window_and_preserves_its_restore_context(
        harness: &mut TestAppContext,
    ) {
        let root = init(harness);
        let (_, _first_workspace, second_handle, second_workspace) =
            harness.update(|cx| open_two_windows_with_scrollback(cx, true));
        let scrollback = crate::restore::scrollback_file(&root, 8301);
        std::fs::create_dir_all(scrollback.parent().unwrap()).expect("create scrollback folder");
        std::fs::write(&scrollback, "parked terminal history").expect("write parked scrollback");

        harness.update(|cx| park_window(second_handle, second_workspace, cx));
        harness.run_until_parked();
        harness.update(|cx| crate::save_session(cx, false));

        let saved = saved_after_writer_shutdown(harness, &root);
        assert_eq!(saved.windows.len(), 2);
        assert_eq!(
            saved.windows[0].tabs[0].custom_title.as_deref(),
            Some("first-window-live")
        );
        let parked = &saved.windows[1];
        assert_eq!(parked.selected, 0);
        assert!(parked.width > 0.0 && parked.height > 0.0);
        let tab = &parked.tabs[0];
        assert_eq!(
            tab.custom_title.as_deref(),
            Some("second-window-fresh-at-quit")
        );
        assert_eq!(tab.focused_pane, Some(8302));
        assert!(matches!(
            tab.layout.as_ref(),
            Some(SavedSplitNode::Split { .. })
        ));
        assert_eq!(
            tab.archived_context
                .as_ref()
                .and_then(|context| context.preview_snapshot_png_data.as_deref()),
            Some("dGVzdC1jb250ZXh0")
        );
        let pane = &tab.panes[0];
        assert!(pane.scrollback);
        assert_eq!(pane.ai_provider.as_deref(), Some("codex"));
        assert_eq!(
            pane.ai_session_id.as_deref(),
            Some("thread-prequit-window-two")
        );
        assert_eq!(
            pane.ai_resume_command.as_deref(),
            Some("codex resume thread-prequit-window-two")
        );
        assert!(
            scrollback.is_file(),
            "parked scrollback must survive pruning"
        );
        let _ = std::fs::remove_dir_all(root.home());
    }

    #[gpui::test]
    fn quit_with_every_window_parked_saves_the_latest_provider_identity(
        harness: &mut TestAppContext,
    ) {
        let root = init(harness);
        let (first_handle, first_workspace, second_handle, second_workspace) =
            harness.update(open_two_windows);

        harness.update(|cx| {
            park_window(first_handle, first_workspace, cx);
            park_window(second_handle, second_workspace, cx);
        });
        harness.run_until_parked();
        harness.update(|cx| {
            assert!(
                AppData::live(cx).is_empty(),
                "all terminal windows are parked"
            );
            crate::save_session(cx, true);
        });

        let saved = saved_after_writer_shutdown(harness, &root);
        assert_eq!(saved.windows.len(), 2);
        let parked = saved
            .windows
            .iter()
            .flat_map(|window| &window.tabs)
            .find(|tab| tab.custom_title.as_deref() == Some("second-window-fresh-at-quit"))
            .expect("second parked tab is part of the quit snapshot");
        assert!(matches!(
            parked.layout.as_ref(),
            Some(SavedSplitNode::Split { .. })
        ));
        assert_eq!(
            parked.panes[0].ai_session_id.as_deref(),
            Some("thread-prequit-window-two")
        );
        assert_eq!(
            parked.panes[0].ai_resume_command.as_deref(),
            Some("codex resume thread-prequit-window-two")
        );
        let _ = std::fs::remove_dir_all(root.home());
    }

    #[gpui::test]
    fn failed_parked_window_creation_requeues_its_tabs(harness: &mut TestAppContext) {
        let root = init(harness);
        let (_, _, handle, workspace) = harness.update(open_two_windows);
        harness.update(|cx| park_window(handle, workspace, cx));
        harness.run_until_parked();

        harness.update(|cx| {
            let parked = cx
                .global_mut::<AppData>()
                .hidden
                .pop()
                .expect("window was parked");
            open_parked_window_or_requeue(parked, cx, |parked, _| Err(parked));

            let hidden = hidden_windows(cx);
            assert_eq!(hidden.len(), 1);
            assert_eq!(hidden[0].tabs.len(), 1);
            assert_eq!(hidden[0].selected, 0);
            assert_eq!(
                hidden[0].tabs[0].0.custom_title.as_deref(),
                Some("second-window-fresh-at-quit")
            );
            assert_eq!(
                hidden[0].tabs[0].1.read(cx).deferred_saved().unwrap().panes[0]
                    .ai_session_id
                    .as_deref(),
                Some("thread-prequit-window-two")
            );
        });

        let writer = harness
            .update(crate::restore::writer::shutdown)
            .expect("restore writer was initialized");
        writer.join().expect("restore writer joins");
        let _ = std::fs::remove_dir_all(root.home());
    }
}
