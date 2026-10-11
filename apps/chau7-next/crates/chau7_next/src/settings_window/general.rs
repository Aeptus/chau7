//! General (`GeneralSettingsView.swift`, `ConfigFileSettingsView.swift`):
//! startup, language, config files, status, actions and reset.

use std::time::SystemTime;

use chau7_next_core::app_shell::abbreviate_home;
use gpui::{App, PromptLevel, SharedString, Window, div, prelude::*};

use super::widgets::{banner, button, chip, description, info_row, row, section as titled, toggle};
use super::{SectionContext, set_message, update};
use crate::monitoring_status::state_label;
use crate::platform::login_item::{self, LoginItemStatus};
use crate::settings::config_files;
use crate::settings::{AppLanguage, Settings};
use crate::workspace::AppData;

pub(super) fn section(ctx: &SectionContext) -> gpui::Div {
    let chrome = ctx.chrome;
    let g = &ctx.settings.general;

    // Startup
    let login = ctx.login_status;
    let mut startup = titled("Startup", chrome).child(row(
        "Launch at Login",
        super::widgets::toggle_with(
            "launch-at-login",
            if login == LoginItemStatus::Unsupported {
                g.launch_at_login
            } else {
                login.is_on()
            },
            chrome,
            set_launch_at_login,
        ),
        chrome,
    ));
    startup = startup.child(description(
        "Automatically start Chau7 Next when you log in to your Mac",
        chrome,
    ));
    if login == LoginItemStatus::RequiresApproval {
        startup = startup.child(
            div()
                .flex()
                .items_center()
                .gap_2()
                .child(description(
                    "Allow Chau7 Next in System Settings > General > Login Items.",
                    chrome,
                ))
                .child(
                    button("open-login-items", "Open Login Items", chrome).on_click(|_, _, _| {
                        if let Err(err) = login_item::current().open_system_settings() {
                            log::warn!("login items: {err}");
                        }
                    }),
                ),
        );
    }

    // Language
    let languages = AppLanguage::ALL.into_iter().map(|language| {
        chip(
            SharedString::from(format!("lang-{}", language.id())),
            crate::l10n::language_name(language),
            g.app_language == language,
            chrome,
        )
        .on_click(move |_, _, cx| update(cx, |s| s.general.app_language = language))
    });
    let language = titled("Language", chrome)
        .child(row(
            crate::l10n::l("settings.general.language.label", "App Language"),
            div().flex().flex_wrap().gap_1().children(languages),
            chrome,
        ))
        .child(description(
            crate::l10n::l(
                "settings.general.language.note",
                "Some changes may require restarting the app",
            ),
            chrome,
        ));

    // Config file
    let files = ctx.config;
    let abbreviate = |path: &std::path::Path| abbreviate_home(&path.to_string_lossy(), &ctx.home);
    let mut config = titled("Config File", chrome)
        .child(row(
            "Load Config Files",
            toggle("load-config", g.load_config_files, chrome, |s, v| {
                s.general.load_config_files = v
            }),
            chrome,
        ))
        .child(description(
            "Reload settings when the config file changes, and apply a per-repo .chau7/config.toml. Per-repo configs override global settings.",
            chrome,
        ))
        .child(info_row("Path", abbreviate(files.global_path()), chrome));
    if let Some(loaded) = files.last_load {
        let age = SystemTime::now()
            .duration_since(loaded)
            .map(|d| d.as_secs())
            .unwrap_or(0);
        config = config.child(info_row(
            "Last Loaded",
            chau7_next_core::l10n::relative_age(age),
            chrome,
        ));
    }
    if let Some(error) = &files.last_error {
        config = config.child(banner(error.clone(), true, chrome));
    }
    let file_exists = files.global_path().exists();
    config = config.child(
        div()
            .flex()
            .flex_wrap()
            .gap_2()
            .child(
                button("config-create", "Create Default Config", chrome)
                    .on_click(|_, _, cx| create_default_config(cx)),
            )
            .child(
                button("config-open", "Open in Editor", chrome)
                    .when(!file_exists, |d| d.opacity(0.4))
                    .on_click(move |_, window, cx| {
                        if file_exists {
                            window.dispatch_action(Box::new(crate::actions::OpenConfigFile), cx)
                        }
                    }),
            )
            .child(
                button("config-reload", "Reload Now", chrome).on_click(|_, window, cx| {
                    window.dispatch_action(Box::new(crate::actions::ReloadConfig), cx)
                }),
            ),
    );

    // Per-repo config
    let repo_path = files.repo_path();
    let repo_exists = repo_path.as_ref().is_some_and(|p| p.exists());
    let mut repo = titled("Per-Repo Config", chrome).child(description(
        "Place a .chau7/config.toml in your repository root to override global settings for that project.",
        chrome,
    ));
    if let Some(path) = &repo_path {
        repo = repo.child(info_row("Path", abbreviate(path), chrome));
    }
    if files.repo_active {
        repo = repo.child(
            div()
                .text_xs()
                .text_color(chrome.accent)
                .child(crate::l10n::tr("Repo config active")),
        );
    }
    let can_create = repo_path.is_some() && !repo_exists;
    let open_path = repo_path.clone();
    repo = repo.child(
        div()
            .flex()
            .gap_2()
            .child(
                button("repo-create", "Create Per-Repo Config", chrome)
                    .when(!can_create, |d| d.opacity(0.4))
                    .on_click(move |_, _, cx| {
                        if can_create {
                            create_repo_config(cx)
                        }
                    }),
            )
            .child(
                button("repo-open", "Open in Editor", chrome)
                    .when(!repo_exists, |d| d.opacity(0.4))
                    .on_click(move |_, _, cx| {
                        if let Some(path) = open_path.as_ref().filter(|p| p.exists()) {
                            cx.open_with_system(path);
                        }
                    }),
            ),
    );

    // Status
    let m = &ctx.monitoring;
    let status = titled("Status", chrome)
        .child(info_row("Notifications", m.notifications.clone(), chrome))
        .child(info_row("Event Monitoring", state_label(m.events), chrome))
        .child(info_row(
            "History Monitoring",
            state_label(m.history),
            chrome,
        ))
        .child(info_row(
            "Terminal Monitoring",
            state_label(m.terminal),
            chrome,
        ));

    // Actions
    let actions = titled("Actions", chrome).child(
        div()
            .flex()
            .flex_wrap()
            .gap_2()
            .child(
                button("act-overlay", "Show Overlay", chrome)
                    .on_click(|_, _, cx| crate::app_actions::show_overlay(cx)),
            )
            .child(
                button("act-positions", "Reset Window Positions", chrome)
                    .on_click(|_, _, cx| reset_window_positions(cx)),
            )
            .child(
                button("act-debug", "Debug Console", chrome).on_click(|_, window, cx| {
                    window.dispatch_action(Box::new(crate::actions::ToggleDebugConsole), cx)
                }),
            ),
    );

    div()
        .flex()
        .flex_col()
        .child(startup)
        .child(language)
        .child(config)
        .child(repo)
        .child(status)
        .child(actions)
}

/// Register or remove the login item, then keep the setting in step with
/// what the OS answered.
fn set_launch_at_login(cx: &mut App, on: bool) {
    match login_item::current().set_enabled(on) {
        Ok(()) => update(cx, |s| s.general.launch_at_login = on),
        Err(err) => {
            log::warn!("launch at login: {err}");
            set_message(cx, format!("Launch at Login: {err}"), true);
        }
    }
}

/// Write `config.toml` with the default content, unless one exists
/// (`createDefaultConfig`).
fn create_default_config(cx: &mut App) {
    let path = cx.global::<AppData>().root.config_file();
    if path.exists() {
        set_message(cx, "A config file already exists.".to_string(), false);
        return;
    }
    let root = cx.global::<AppData>().root.clone();
    let result = root
        .ensure_dirs()
        .and_then(|()| std::fs::write(&path, crate::DEFAULT_CONFIG));
    match result {
        Ok(()) => config_files::reload(cx),
        Err(err) => set_message(cx, format!("Could not create the config file: {err}"), true),
    }
}

/// Write an empty per-repo config for the active tab's directory
/// (`createRepoConfig`).
fn create_repo_config(cx: &mut App) {
    let Some(path) = cx.global::<config_files::ConfigFiles>().repo_path() else {
        return;
    };
    let result = path
        .parent()
        .map_or(Ok(()), std::fs::create_dir_all)
        .and_then(|()| std::fs::write(&path, REPO_CONFIG_TEMPLATE));
    match result {
        Ok(()) => config_files::apply(cx),
        Err(err) => set_message(cx, format!("Could not create the repo config: {err}"), true),
    }
}

/// Keys a repo file can override, commented out.
const REPO_CONFIG_TEMPLATE: &str = "# Per-repo overrides: these keys replace the global config in this folder.\n\
# [general]\n# default_directory = \"~/code\"\n\n\
# [appearance]\n# font_family = \"Menlo\"\n# font_size = 13\n# color_scheme = \"Default\"\n# cursor_style = \"block\"\n\n\
# [terminal]\n# scrollback_lines = 10000\n# bell_enabled = true\n";

/// Forget where windows were (`resetOverlayOffsets`): the next launch and new
/// windows open centered at the default size.
pub(super) fn reset_window_positions(cx: &mut App) {
    crate::workspace::reset_panel_positions(cx);
    let root = cx.global::<AppData>().root.clone();
    match crate::session_store::forget_positions(&root) {
        Ok(()) => set_message(
            cx,
            "Window positions reset. Windows open centered next time.".to_string(),
            false,
        ),
        Err(err) => set_message(cx, format!("Could not reset window positions: {err}"), true),
    }
}

/// "Reset All Settings?" (`resetAllToDefaults`).
pub(super) fn confirm_reset_all(window: &mut Window, cx: &mut App) {
    let answer = crate::l10n::prompt(
        window,
        PromptLevel::Warning,
        "Reset All Settings?",
        Some(
            "This will reset all Chau7 Next settings to their default values. This action cannot be undone.",
        ),
        &["Reset", "Cancel"],
        cx,
    );
    cx.spawn(async move |cx| {
        if answer.await.ok() == Some(0) {
            cx.update(|cx| {
                // The login item is registered with the OS, not in the file.
                let _ = login_item::current().set_enabled(false);
                update(cx, Settings::reset_all)
            });
        }
    })
    .detach();
}

/// "Grant Protected Folder Access": pick folders; each protected one is read
/// once so macOS asks for it, and is used from then on.
fn grant_protected_access(cx: &mut App) {
    let paths = cx.prompt_for_paths(gpui::PathPromptOptions {
        files: false,
        directories: true,
        multiple: true,
        prompt: Some("Grant".into()),
    });
    cx.spawn(async move |cx| {
        let Ok(Ok(Some(paths))) = paths.await else {
            return;
        };
        let granted = crate::protected_paths::grant(&paths);
        cx.update(|cx| {
            let text = if granted.is_empty() {
                "No protected folder was granted.".to_string()
            } else {
                format!("Granted: {}", granted.join(", "))
            };
            set_message(cx, text, granted.is_empty());
            crate::permission_center::refresh(cx);
        });
    })
    .detach();
}

/// Current Productivity protected-folder controls, shared with Permission Center.
pub(super) fn protected_controls(ctx: &SectionContext) -> gpui::Div {
    let chrome = ctx.chrome;
    let g = &ctx.settings.general;
    titled("Protected Folders", chrome)
        .child(row(
            "Allow Protected Folder Access",
            super::widgets::toggle_with("protected-access", g.allow_protected_folder_access, chrome, |cx, v| {
                update(cx, |s| s.general.allow_protected_folder_access = v);
                if v {crate::protected_paths::reset();}
                crate::permission_center::refresh(cx);
            }),
            chrome,
        ))
        .child(description(
            "Repo detection skips Downloads, Desktop, Documents and Library unless you allow it, so macOS shows no privacy prompt.",
            chrome,
        ))
        .when(g.allow_protected_folder_access, |d| {
            d.child(
                div()
                    .flex()
                    .gap_2()
                    .child(
                        button("protected-grant", "Grant Access...", chrome)
                            .on_click(|_, _, cx| {
                                crate::protected_paths::reset();
                                grant_protected_access(cx);
                            }),
                    )
                    .child(button("protected-system", "Open System Settings", chrome).on_click(|_, _, cx| {
                        cx.open_url("x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders");
                    }))
                    .child(button("protected-reset", "Reset Checks", chrome).on_click(
                        |_, _, cx| {
                            crate::protected_paths::reset();
                            set_message(cx, "Protected folder checks reset.".to_string(), false);
                        },
                    )),
            )
        })
}
