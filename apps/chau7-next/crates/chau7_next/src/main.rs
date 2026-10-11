//! Chau7 Next: the GPUI port of the Chau7 macOS terminal.
//!
//! Runs side by side with the Swift app (see `docs/rust-port/DUAL-SHIP.md`):
//! bundle id `com.chau7.next`, data in `~/.chau7-next/` and the Chau7 Next
//! state folder. Nothing here touches the Swift app's files.

mod actions;
mod ai;
mod analytics;
mod app_actions;
mod app_icon;
mod assets;
mod commands;
mod cto;
mod data_explorer;
mod debug;
mod history;
mod l10n;
mod logging;
mod mcp;
mod migration;
mod monitoring;
mod monitoring_status;
mod notifications;
mod pane;
mod panes;
mod performance;
mod platform;
mod profiles;
mod protected_paths;
mod proxy;
mod remote;
mod repository;
mod restore;
mod runtime;
mod scripting;
mod seams;
mod session_store;
mod settings;
mod settings_window;
mod snippets;
mod status_bar;
mod tab_bar;
mod telemetry;
mod terminal;
mod theme;
mod views;
mod workspace;

use chau7_next_core::data_root::DataRoot;
use chau7_next_core::tabs_state::TabMeta;
use gpui::{App, AppContext, Bounds, Entity, point, px, size};
use gpui_kit::component::{Theme, ThemeMode};

use crate::actions::*;
use crate::pane::PaneTree;
use crate::session_store::{SavedSession, SavedWindow};
use crate::settings::Settings;
use crate::workspace::{AppData, ParkedWindow, Workspace, window_options};

/// Drop what the Swift app sets for its shells, in case Chau7 Next was started
/// from a Chau7 tab. Runs first, before any thread exists.
fn clean_inherited_environment() {
    use chau7_next_core::shell_env::{EnvChange, inherited_cleanup};
    let vars: Vec<(String, String)> = std::env::vars_os()
        .filter_map(|(k, v)| Some((k.into_string().ok()?, v.into_string().ok()?)))
        .collect();
    let swift = chau7_next_core::data_root::DataRoot::from_env().swift_shell_paths();
    for change in inherited_cleanup(&vars, &swift) {
        // SAFETY: called at the top of main, while the process is single threaded.
        unsafe {
            match change {
                EnvChange::Remove(key) => std::env::remove_var(key),
                EnvChange::Set(key, value) => std::env::set_var(key, value),
            }
        }
    }
}

pub(crate) use logging::log_file_path;

fn main() {
    clean_inherited_environment();
    platform::defaults::disable_press_and_hold();
    let root = DataRoot::from_env();
    if let Err(err) = root.ensure_dirs() {
        eprintln!("Chau7 Next: cannot create data folders: {err}");
    }
    logging::init(&root);
    logging::ai_pty::purge_large_logs(root.ai_logs_dir());
    protected_paths::init(&root);
    match root.import_from_swift_app() {
        Ok(imported) if !imported.is_empty() => log::info!("imported from Chau7: {imported:?}"),
        Ok(_) => {}
        Err(err) => log::warn!("import from Chau7 failed: {err}"),
    }
    snippets::migrate_legacy_files(&root);
    if let Err(err) = chau7_next_core::shell_integration::install(&root.shell_integration_dir()) {
        log::warn!("shell integration files: {err}");
    }
    let settings = Settings::load(&root);
    l10n::apply_setting(settings.general.app_language);
    let restored = session_store::load(&root);

    // The bundled icons (find bar, side pane headers, palette rows).
    let app = gpui_kit::application().with_assets(assets::AppAssets);
    // macOS: clicking the Dock icon with no window open brings the hidden
    // window back (or opens one).
    app.on_reopen(|cx| {
        if cx.windows().is_empty() {
            app_actions::show_overlay(cx);
        }
    });
    // Links of the URL scheme arrive on an OS callback; the app handles them
    // from its timer (`app_actions::poll`).
    app.on_open_urls(app_actions::queue_open_urls);
    app.run(move |cx: &mut App| {
        gpui_kit::init(cx);
        cx.set_app_identity("com.chau7.next", "Chau7 Next");
        app_icon::apply();
        settings::config_files::init(cx, root.config_file(), settings.clone());
        cx.set_global(settings);
        cx.set_global(AppData::new(root));
        terminal::command_guard::init(cx);
        cto::init(
            &cx.global::<AppData>().root.clone(),
            &Settings::get(cx).clone(),
            cx,
        );
        ai::init(cx);
        history::init(cx);
        telemetry::init(cx);
        repository::init(cx);
        remote::init(cx);
        proxy::init(cx);
        profiles::init(cx);
        apply_theme(cx);
        actions::bind_keys(cx);
        let input = Settings::get(cx).input.clone();
        actions::bind_shortcut_settings(&input, cx);
        cx.on_keyboard_layout_change(|cx| {
            let input = Settings::get(cx).input.clone();
            actions::bind_shortcut_settings(&input, cx);
        })
        .detach();
        commands::bind_keys(cx);
        panes::bind_keys(cx);
        commands::register(cx);
        workspace::start_clipboard_watch(cx);
        notifications::init(cx);
        cx.set_menus(actions::app_menus(&[]));
        register_app_actions(cx);
        // The first keystroke after a pause must not wait for App Nap.
        platform::power::begin_latency_critical("Terminal requires low-latency input processing");
        let url_scheme = cx.register_url_scheme(chau7_next_core::app_shell::URL_SCHEME);
        cx.background_spawn(async move {
            if let Err(err) = url_scheme.await {
                log::debug!("URL scheme registration: {err}");
            }
        })
        .detach();
        app_actions::apply_menu_bar_only_mode(cx);
        // MCP server for AI agents (`MCPServerManager.shared.start()`).
        mcp::start(cx);
        // Agent runtime sessions driven through MCP (`RuntimeSessionManager`).
        runtime::init(cx);
        // Scripting socket, when "Enable Scripting API" is on.
        scripting::init(cx);
        // Connect the modules' hooks (AI events, notifications, Debug
        // Console, history, MCP, remote control).
        seams::init(cx);
        status_bar::init(cx);
        cx.spawn(async move |cx| {
            loop {
                cx.background_executor()
                    .timer(std::time::Duration::from_millis(150))
                    .await;
                cx.update(app_actions::poll);
            }
        })
        .detach();

        let windows = restored.map(|s| s.windows).unwrap_or_default();
        if windows.is_empty() {
            open_workspace_window(None, cx);
        } else {
            for saved in windows {
                open_workspace_window(Some(saved), cx);
            }
        }

        // The welcome screen the first time, else the splash.
        views::launch(cx);
        performance::start(cx);

        cx.on_app_quit(|cx| {
            save_session(cx, true);
            repository::flush(cx);
            history::recorder::flush_on_quit();
            mcp::stop(cx);
            scripting::stop(cx);
            // Token optimizer: no flags or wrappers outlive the app.
            cto::teardown();
            // Shells get SIGTERM at once (`closeSessionForTermination`).
            terminal::session::terminate_all_for_quit();
            logging::flush();
            async {}
        })
        .detach();
        // Save periodically too, so a crash loses at most a few seconds.
        cx.spawn(async move |cx| {
            loop {
                cx.background_executor()
                    .timer(std::time::Duration::from_secs(15))
                    .await;
                cx.update(|cx| save_session(cx, false));
            }
        })
        .detach();
        cx.on_window_closed(|cx, _| {
            let data = cx.global_mut::<AppData>();
            data.workspaces.retain(|(_, w)| w.upgrade().is_some());
            if cx.windows().is_empty() && !cfg!(target_os = "macos") {
                cx.quit();
            }
        })
        .detach();
        cx.activate(true);
    });
}

pub(crate) fn apply_theme(cx: &mut App) {
    // `app.theme` sets the appearance of every window (`applyAppTheme`).
    let app_theme = Settings::get(cx).appearance.app_theme;
    let _ = platform::window_style::set_app_theme(match app_theme {
        settings::AppTheme::System => None,
        settings::AppTheme::Light => Some(false),
        settings::AppTheme::Dark => Some(true),
    });
    let dark = theme::app_is_dark(cx);
    Theme::change(
        if dark {
            ThemeMode::Dark
        } else {
            ThemeMode::Light
        },
        None,
        cx,
    );
}

fn register_app_actions(cx: &mut App) {
    app_actions::register(cx);
    debug::init(cx);
    cx.on_action(|_: &NewWindow, cx| {
        open_workspace_window(None, cx);
    });
    cx.on_action(|_: &OpenSettings, cx| settings_window::open(cx));
    cx.on_action(|_: &OpenConfigFile, cx| {
        let path = cx.global::<AppData>().root.config_file();
        if !path.exists() {
            let _ = std::fs::write(&path, DEFAULT_CONFIG);
        }
        cx.open_with_system(&path);
    });
    cx.on_action(|_: &ReloadConfig, cx| settings::config_files::reload(cx));
    cx.on_action(|_: &ShowAbout, cx| settings_window::open_about(cx));
}

/// Open a window, optionally restoring saved tabs and bounds.
pub fn open_workspace_window(
    saved: Option<SavedWindow>,
    cx: &mut App,
) -> Option<Entity<Workspace>> {
    let bounds = saved
        .as_ref()
        .filter(|s| s.width >= 300.0 && s.height >= 200.0)
        .map(|s| Bounds::new(point(px(s.x), px(s.y)), size(px(s.width), px(s.height))));
    let options = window_options(bounds, cx);
    let (handle, workspace) = gpui_kit::open_window(options, cx, move |window, cx| {
        cx.new(|cx| Workspace::new(saved, window, cx))
    })
    .map_err(|err| log::error!("open window: {err}"))
    .ok()?;
    workspace.update(cx, |ws, _| ws.window_handle = Some(handle));
    cx.global_mut::<AppData>()
        .workspaces
        .push((handle, workspace.downgrade()));
    Some(workspace)
}

/// A window closed with Close Window comes back with its tabs, shells and
/// frame.
pub fn open_parked_window(parked: ParkedWindow, cx: &mut App) {
    let options = window_options(Some(parked.bounds), cx);
    let ParkedWindow { tabs, selected, .. } = parked;
    let result = gpui_kit::open_window(options, cx, move |window, cx| {
        cx.new(|cx| {
            // A window emptied by moving its tabs out comes back with a
            // fresh tab (`ensureFreshTabIfNeeded`).
            if tabs.is_empty() {
                return Workspace::new(None, window, cx);
            }
            let mut ws = Workspace::new_empty(window, cx);
            for (i, (meta, panes)) in tabs.into_iter().enumerate() {
                ws.adopt_tab_public(meta, panes, i == selected, cx);
            }
            ws.focus_selected_public(window, cx);
            ws
        })
    });
    match result {
        Ok((handle, workspace)) => {
            workspace.update(cx, |ws, _| ws.window_handle = Some(handle));
            cx.global_mut::<AppData>()
                .workspaces
                .push((handle, workspace.downgrade()));
        }
        Err(err) => log::error!("open window: {err}"),
    }
}

/// New window holding tabs moved from another window.
pub fn open_window_with_tabs(tabs: Vec<(TabMeta, Entity<PaneTree>)>, cx: &mut App) {
    let options = window_options(None, cx);
    let result = gpui_kit::open_window(options, cx, move |window, cx| {
        cx.new(|cx| {
            let mut ws = Workspace::new_empty(window, cx);
            let count = tabs.len();
            for (i, (meta, panes)) in tabs.into_iter().enumerate() {
                ws.adopt_tab_public(meta, panes, i + 1 == count, cx);
            }
            ws.focus_selected_public(window, cx);
            ws
        })
    });
    match result {
        Ok((handle, workspace)) => {
            workspace.update(cx, |ws, _| ws.window_handle = Some(handle));
            cx.global_mut::<AppData>()
                .workspaces
                .push((handle, workspace.downgrade()));
        }
        Err(err) => log::error!("open window: {err}"),
    }
}

/// Save the open windows. Hidden windows are not saved; at quit with no
/// visible window the saved state is cleared (`saveAllWindowStates`).
pub(crate) fn save_session(cx: &mut App, terminating: bool) {
    let mut windows = Vec::new();
    for (handle, ws) in AppData::live(cx) {
        let snapshot = handle.update(cx, |_, window, cx| ws.read(cx).snapshot(window, cx));
        if let Ok(mut snapshot) = snapshot {
            session_store::apply_position_reset(&mut snapshot);
            windows.push(snapshot);
        }
    }
    // Closed tabs keep their scrollback for Reopen Closed Tab.
    let closed_panes: Vec<_> = AppData::live(cx)
        .iter()
        .flat_map(|(_, ws)| ws.read(cx).closed_scrollback_panes())
        .collect();
    let root = cx.global::<AppData>().root.clone();
    if windows.is_empty() {
        if terminating && let Err(err) = session_store::clear(&root) {
            log::warn!("clear session: {err}");
        }
        return;
    }
    // Scrollback files of panes that are gone are deleted after the save.
    let keep: std::collections::HashSet<_> = windows
        .iter()
        .flat_map(|w| &w.tabs)
        .flat_map(|t| &t.panes)
        .filter(|p| p.scrollback)
        .map(|p| p.id)
        .chain(closed_panes)
        .collect();
    match session_store::save_for(
        &root,
        &SavedSession {
            version: 1,
            windows,
        },
        terminating,
    ) {
        Ok(()) => restore::prune_scrollback(&root, &keep),
        Err(err) => log::warn!("save session: {err}"),
    }
}

pub(crate) const DEFAULT_CONFIG: &str = r#"# Chau7 Next settings. Same format as the Chau7 config.toml.
# Reload with "Reload Settings" in the app menu.

[general]
# shell = "/bin/zsh"
# startup_command = ""       # run with eval after your shell config
# default_directory = "~"
# close_on_exit = true

[appearance]
# font_family = "SF Mono"
# font_size = 11
# color_scheme = "Default"   # Default, Solarized Dark, Solarized Light, Dracula, Nord, Monokai, Gruvbox Dark, Tokyo Night
# cursor_style = "block"     # block, bar, underline
# cursor_blink = true

[terminal]
# scrollback_lines = 10000
# bell_enabled = true
# bell_sound = "default"     # default, subtle, none (visual flash)
# mouse_reporting = false

# Keys only Chau7 Next reads.
[next]
# new_tab_position = "end"   # end, after
# idle_tab_minutes = 10
# group_idle_tabs = true
# repo_grouping_mode = "off"  # off, auto, manual
# new_tabs_use_current_directory = true
# last_tab_close_behavior = "keepWindow"   # keepWindow, closeWindow
# always_show_tab_bar = true
# custom_title_only = false
# show_tab_icons = true
# auto_tab_theme = true
# show_tab_path = true
# show_tab_git_indicator = true
# show_tab_broadcast_indicator = true
# last_command_badge = true
# copy_on_select = true
# warn_on_close_running = true
# highlight_dangerous_commands = true
# clipboard_history_max = 50
# padding = 4
# shell_type = "system"      # system, /bin/zsh, /bin/bash, /opt/homebrew/bin/fish, /usr/local/bin/fish, custom
# custom_shell_path = ""
# ls_colors_enabled = true
# restored_scrollback_lines = 500
# smart_scroll_enabled = true
# default_zoom_percent = 100

# Same format as Chau7: "keys" = "action" (Swift action names).
[keybindings]
# cmd+shift+b = "toggleBroadcast"
"#;
