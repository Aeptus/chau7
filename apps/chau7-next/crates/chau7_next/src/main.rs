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
mod hang_watchdog;
mod history;
mod incidents;
mod instance;
mod l10n;
mod logging;
mod mcp;
mod memory_pressure;
mod migration;
mod monitoring;
mod monitoring_status;
#[cfg(all(feature = "native-parity-fixture", target_os = "macos"))]
mod native_parity_fixture;
mod notifications;
mod observability;
mod pane;
mod panes;
mod performance;
mod permission_center;
mod platform;
mod process_termination;
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
mod shutdown;
#[cfg(test)]
mod shutdown_policy_test;
mod snippets;
mod startup;
mod status_bar;
mod tab_bar;
mod telemetry;
mod terminal;
mod theme;
mod views;
mod window_backend;
mod workspace;

use chau7_next_core::data_root::DataRoot;
use gpui::{App, AppContext, Bounds, Entity, point, px, size};
use gpui_kit::component::{Theme, ThemeMode};

use crate::actions::*;
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

fn global_url_registration_allowed(isolated: bool) -> bool {
    !isolated
}

fn main() {
    startup::begin();
    performance::begin_launch();
    #[cfg(all(feature = "native-parity-fixture", target_os = "macos"))]
    if let Some(code) = native_parity_fixture::run_if_requested() {
        std::process::exit(code);
    }
    if let Some(code) = hang_watchdog::run_cli_if_requested() {
        std::process::exit(code);
    }
    clean_inherited_environment();
    let root = DataRoot::from_env();
    if let Some(code) = migration::swift_restore::run_cli_if_requested(&root) {
        std::process::exit(code);
    }
    if chau7_next_core::data_root::PRODUCTION_CHANNEL {
        match migration::swift_restore::requires_source_choice(&root) {
            Ok(false) => {}
            Ok(true) => {
                eprintln!(
                    "Saved Chau7 data is available. Before the first production launch, select --import-chau7-restoration swift or next with --source-home and --dry-run. See docs/rust-port/PRODUCTION-RELEASE.md. No saved data was changed."
                );
                std::process::exit(2);
            }
            Err(error) => {
                eprintln!("Cannot inspect saved restoration data: {error}. No profile was opened.");
                std::process::exit(2);
            }
        }
    }
    if chau7_next_core::data_root::PRODUCTION_CHANNEL
        && !chau7_next_core::data_root::is_isolated_test_mode()
        && platform::workspace::another_instance_is_running(chau7_next_core::data_root::BUNDLE_ID)
    {
        eprintln!(
            "Chau7 is already running. Close the existing app yourself before opening the Rust release; it has not been stopped or modified."
        );
        std::process::exit(1);
    }
    let installation = settings::installation::FreshInstallation::capture(&root);
    if let Err(err) = root.ensure_dirs() {
        eprintln!(
            "{}: cannot create data folders: {err}",
            chau7_next_core::data_root::APP_NAME
        );
    }
    let instance = match instance::acquire(&root) {
        Ok(Some(instance)) => std::sync::Arc::new(instance),
        Ok(None) => return,
        Err(error) => {
            eprintln!(
                "{}: cannot acquire application instance lock: {error}",
                chau7_next_core::data_root::APP_NAME
            );
            std::process::exit(1);
        }
    };
    if installation.initialize().is_err() {
        eprintln!(
            "{}: installation policy unavailable; preserving legacy retention default",
            chau7_next_core::data_root::APP_NAME
        );
    }
    platform::defaults::disable_press_and_hold();
    logging::init(&root);
    incidents::start(&root);
    if let Err(error) = instance::begin(&instance) {
        log::error!("Cannot record launch continuity: {error}");
        std::process::exit(1);
    }
    platform::oslog::install_feature_intervals();
    logging::ai_pty::purge_large_logs(root.ai_logs_dir());
    protected_paths::init(&root);
    match root.import_from_swift_app() {
        Ok(imported) if !imported.is_empty() => log::info!("imported from Chau7: {imported:?}"),
        Ok(_) => {}
        Err(err) => log::warn!("import from Chau7 failed: {err}"),
    }
    let settings = Settings::load(&root);
    l10n::apply_setting(settings.general.app_language);
    chau7_next_core::l10n::numbers::set_current(settings.general.regional_number_format);

    // The bundled icons (find bar, side pane headers, palette rows).
    let (platform, window_backend_state) =
        window_backend::create(settings.appearance.rendering.gpu_renderer);
    let terminal_text_system = platform.text_system();
    let app = gpui::Application::with_platform(platform).with_assets(assets::AppAssets);
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
        // Accepted work is admitted directly on background executors. Wait
        // for its drains and checked resource closes before native exit.
        cx.set_shutdown_timeout(None);
        window_backend::init(window_backend_state, cx);
        terminal::paint::init_cpu_text_system(terminal_text_system, cx);
        gpui_kit::init(cx);
        cx.set_app_identity(
            chau7_next_core::data_root::BUNDLE_ID,
            chau7_next_core::data_root::APP_NAME,
        );
        app_icon::apply();
        settings::config_files::init(cx, root.config_file(), settings.clone());
        cx.set_global(settings);
        cx.set_global(AppData::new(root));
        apply_theme(cx);
        app_actions::apply_menu_bar_only_mode(cx);
        views::register(cx);
        startup::mark(startup::Stage::AppReady);
        // A quit during the splash must preserve the saved session before its
        // workspaces exist. Once initialized, the ordinary drain hook owns quit.
        let initialized = std::rc::Rc::new(std::cell::Cell::new(false));
        let cancelled = std::rc::Rc::new(std::cell::Cell::new(false));
        let quit_initialized = initialized.clone();
        let quit_cancelled = cancelled.clone();
        let early_instance = instance.clone();
        cx.on_app_quit(move |cx| {
            quit_cancelled.set(true);
            let early = !quit_initialized.get();
            let instance = early_instance.clone();
            cx.background_spawn(async move {
                if early {
                    let closed = incidents::shutdown().is_ok();
                    if closed && let Err(error) = instance.mark_clean() {
                        log::warn!("Cannot mark early launch termination clean: {error}");
                    }
                    logging::flush();
                }
            })
        })
        .detach();
        views::prepare_launch(cx, move |cx| {
            if cancelled.get() {
                return;
            }
            let root = cx.global::<AppData>().root.clone();
            let settings = Settings::get(cx).clone();
            // AI event writers and all tailers/sessions are still quiescent.
            monitoring::log_compactor::compact_owned_queues(&root);
            snippets::migrate_legacy_files(&root);
            if let Err(err) =
                chau7_next_core::shell_integration::install(&root.shell_integration_dir())
            {
                log::warn!("shell integration files: {err}");
            }
            let mut restored = session_store::load(&root);
            if let Some(saved) = &mut restored {
                // Normalize legacy UUIDs once so every window shares the same metadata
                // owner reservations before the first selected pane activates.
                for tab in saved.windows.iter_mut().flat_map(|window| &mut window.tabs) {
                    tab.uuid.get_or_insert_with(uuid::Uuid::new_v4);
                }
                restore::preparation::register_saved_identity_hints(
                    &root,
                    saved.windows.iter().flat_map(|window| &window.tabs),
                );
            }
            history::shell_histories::prune_startup(
                &root,
                restored.as_ref(),
                settings.terminal.shell_history_max_lines,
            );

            // Service timers and background writers share this registry.
            observability::init(cx);
            restore::writer::init(cx);
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
            platform::power::begin_latency_critical(
                "Terminal requires low-latency input processing",
            );
            // An isolated owned app must not replace the user's global URL handler.
            if global_url_registration_allowed(chau7_next_core::data_root::is_isolated_test_mode())
            {
                let url_scheme = cx.register_url_scheme(chau7_next_core::app_shell::URL_SCHEME);
                cx.background_spawn(async move {
                    if let Err(err) = url_scheme.await {
                        log::debug!("URL scheme registration: {err}");
                    }
                })
                .detach();
            }
            // MCP server for AI agents (`MCPServerManager.shared.start()`).
            mcp::start(cx);
            monitoring::aethyme_delivery::start(cx);
            // Agent runtime sessions driven through MCP (`RuntimeSessionManager`).
            runtime::init(cx);
            // Scripting socket, when "Enable Scripting API" is on.
            scripting::init(cx);
            // Connect the modules' hooks (AI events, notifications, Debug
            // Console, history, MCP, remote control).
            seams::init(cx);
            status_bar::init(cx);
            let poll_timer =
                observability::register_timer(cx, "app.poll", "App actions polling", "app", 150);
            cx.spawn(async move |cx| {
                let _timer = poll_timer;
                loop {
                    cx.background_executor()
                        .timer(std::time::Duration::from_millis(150))
                        .await;
                    cx.update(app_actions::poll);
                }
            })
            .detach();

            startup::mark(startup::Stage::ServicesReady);
            let windows = restored.map(|s| s.windows).unwrap_or_default();
            if windows.is_empty() {
                open_workspace_window(None, cx);
            } else {
                for saved in windows {
                    open_workspace_window(Some(saved), cx);
                }
            }

            if !AppData::live(cx).is_empty() {
                startup::mark(startup::Stage::WorkspaceOpened);
            }
            // The welcome screen stays interactive on first launch; the splash
            // already covers startup and closes on the first ready terminal paint.
            memory_pressure::start(cx);
            views::finish_launch(cx);
            hang_watchdog::start(cx);
            permission_center::start(cx);
            performance::start(cx);

            let full_initialized = initialized.clone();
            cx.on_app_quit(move |cx| {
                if !full_initialized.get() {
                    return cx.background_spawn(async {});
                }
                let instance = instance.clone();
                let mut progress = shutdown::Progress::new();
                memory_pressure::stop(cx);
                permission_center::stop(cx);
                save_session(cx, true);
                let restore_worker = restore::writer::shutdown(cx);
                repository::flush(cx);
                history::recorder::flush_on_quit();
                monitoring::aethyme_delivery::stop(cx);
                monitoring::process_tree::stop(cx);
                mcp::stop(cx);
                scripting::stop(cx);
                // Token optimizer: no flags or wrappers outlive the app.
                cto::teardown();
                let cto_worker = cto::shutdown_state_writer();
                // Shells get SIGTERM at once (`closeSessionForTermination`).
                terminal::session::terminate_all_for_quit();
                let history_writer = history::shutdown(cx);
                let telemetry_writer = telemetry::shutdown(cx);
                logging::flush();
                let performance_worker = performance::stop(cx);
                let hang_worker = hang_watchdog::stop(cx);
                let worker = observability::shutdown(cx);
                progress.complete(shutdown::Phase::Producers, true);
                cx.background_spawn(async move {
                    // Stop and admission-close calls precede this barrier. The actual
                    // thread joins and SQLite close run on this background task.
                    progress.complete(
                        shutdown::Phase::Performance,
                        shutdown::join_worker(performance_worker).is_ok(),
                    );
                    progress.complete(
                        shutdown::Phase::Watchdog,
                        shutdown::join_worker(hang_worker).is_ok(),
                    );
                    progress.complete(
                        shutdown::Phase::Observability,
                        shutdown::join_worker(worker).is_ok(),
                    );
                    let restore_drained = match shutdown::join_worker(restore_worker) {
                        Ok(Some(stats)) if stats.failed > 0 => {
                            log::warn!(
                                "Restore writer completed with {} failed captures",
                                stats.failed
                            );
                            false
                        }
                        Err(_) => false,
                        _ => true,
                    };
                    progress.complete(shutdown::Phase::Restore, restore_drained);
                    progress.complete(
                        shutdown::Phase::Cto,
                        shutdown::join_worker(cto_worker).is_ok(),
                    );
                    let telemetry_closed = telemetry_writer
                        .map(|writer| writer.finish())
                        .unwrap_or(Ok(()));
                    if let Err(error) = &telemetry_closed {
                        log::warn!("Telemetry shutdown incomplete: {error}");
                    }
                    progress.complete(shutdown::Phase::Telemetry, telemetry_closed.is_ok());
                    let history_drained = match history_writer.map(|writer| writer.finish()) {
                        Some(Ok(outcome)) => {
                            log::debug!(
                                "History writer drained {} accepted records with {} failed inserts",
                                outcome.processed,
                                outcome.failed
                            );
                            outcome.failed == 0
                        }
                        Some(Err(error)) => {
                            log::error!("History shutdown failed: {error}");
                            false
                        }
                        None => true,
                    };
                    progress.complete(shutdown::Phase::History, history_drained);
                    let incidents_closed = incidents::shutdown();
                    progress.complete(shutdown::Phase::Incidents, incidents_closed.is_ok());
                    if progress.can_mark_clean() {
                        let marked_clean = instance.mark_clean();
                        if let Err(error) = &marked_clean {
                            log::warn!("Cannot mark clean termination: {error}");
                        }
                        progress.complete(shutdown::Phase::CleanMarker, marked_clean.is_ok());
                    } else {
                        log::warn!(
                            "Clean shutdown marker withheld after an incomplete shutdown phase"
                        );
                    }
                    logging::flush();
                })
            })
            .detach();
            // Save periodically too, so a crash loses at most a few seconds.
            let save_timer = observability::register_timer(
                cx,
                "restore.save",
                "Periodic session save",
                "restore",
                15_000,
            );
            cx.spawn(async move |cx| {
                let _timer = save_timer;
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
            initialized.set(true);
            cx.activate(true);
        });
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

/// Prepare an empty destination before removing tabs from another window.
pub fn open_window_for_transfer(
    cx: &mut App,
) -> Option<(gpui::AnyWindowHandle, Entity<Workspace>)> {
    let options = window_options(None, cx);
    let result = gpui_kit::open_window(options, cx, |window, cx| {
        cx.new(|cx| Workspace::new_empty(window, cx))
    });
    match result {
        Ok((handle, workspace)) => {
            workspace.update(cx, |ws, _| ws.window_handle = Some(handle));
            cx.global_mut::<AppData>()
                .workspaces
                .push((handle, workspace.downgrade()));
            Some((handle, workspace))
        }
        Err(error) => {
            log::error!("open transfer window: {error}");
            None
        }
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
    if windows.is_empty() {
        if terminating {
            restore::writer::submit(None, closed_panes.into_iter().collect(), true, cx);
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
    restore::writer::submit(
        Some(SavedSession {
            version: 1,
            windows,
        }),
        keep,
        terminating,
        cx,
    );
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

#[cfg(test)]
mod startup_order_tests {
    #[test]
    fn isolated_launch_preserves_the_global_url_handler() {
        assert!(!super::global_url_registration_allowed(true));
        assert!(super::global_url_registration_allowed(false));
    }

    #[test]
    fn splash_handoff_precedes_services_and_workspace_creation() {
        let source = include_str!("main.rs")
            .split_once("app.run(move |cx: &mut App| {")
            .unwrap()
            .1;
        let splash = source.find("views::prepare_launch(cx,").unwrap();
        assert!(source.find("views::register(cx);").unwrap() < splash);
        assert!(source.find("apply_menu_bar_only_mode(cx);").unwrap() < splash);
        assert!(splash < source.find("session_store::load(&root)").unwrap());
        assert!(splash < source.find("observability::init(cx);").unwrap());
        assert!(splash < source.find("open_workspace_window(None, cx);").unwrap());
        assert!(
            source.find("startup::Stage::WorkspaceOpened").unwrap()
                < source.find("views::finish_launch(cx);").unwrap()
        );
    }

    #[test]
    fn quit_before_initialization_cancels_start_without_overwriting_restore() {
        let source = include_str!("main.rs")
            .split_once("app.run(move |cx: &mut App| {")
            .unwrap()
            .1;
        let early_hook = source
            .split_once("cx.on_app_quit(move |cx| {")
            .unwrap()
            .1
            .split_once("views::prepare_launch(cx,")
            .unwrap()
            .0;
        assert!(early_hook.contains("quit_cancelled.set(true)"));
        assert!(early_hook.contains("!quit_initialized.get()"));
        assert!(!early_hook.contains("save_session("));
        let continuation = source.split_once("views::prepare_launch(cx,").unwrap().1;
        assert!(
            continuation.find("cancelled.get()").unwrap()
                < continuation.find("observability::init(cx);").unwrap()
        );
    }

    #[test]
    fn observability_precedes_services_that_register_timers() {
        let startup = include_str!("main.rs")
            .split_once("app.run(move |cx: &mut App| {")
            .unwrap()
            .1
            .split_once("ai::init(cx);")
            .unwrap()
            .0;
        let registry = startup.find("observability::init(cx);").unwrap();
        assert!(startup.find("cx.set_global(AppData::new(root));").unwrap() < registry);
        for service in [
            "restore::writer::init(cx);",
            "terminal::command_guard::init(cx);",
            "cto::init(",
        ] {
            assert!(
                registry < startup.find(service).unwrap(),
                "{service} precedes observability"
            );
        }
    }
}
