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
        crate::open_parked_window(parked, cx);
    } else if let Some((handle, _)) = active_workspace(cx) {
        let _ = handle.update(cx, |_, window, _| window.activate_window());
    } else {
        crate::open_workspace_window(None, cx);
    }
    cx.activate(true);
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
    let Some((title, detail)) = app_shell::quit_confirmation(&running_process_names(cx)) else {
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
        quit_now(cx);
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
    crate::save_session(cx, true);
    crate::settings::sync::push_now(cx);
    platform::power::end_latency_critical();
    cx.quit();
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
