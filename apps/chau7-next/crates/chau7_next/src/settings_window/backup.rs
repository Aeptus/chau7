//! Sync & Backup (`ProfilesBackupSettingsView.swift`): iCloud sync, settings
//! export and import. Profile auto-switch belongs to the Profiles module.

use std::time::SystemTime;

use chau7_next_core::app_shell::relative_age;
use gpui::{App, PathPromptOptions, div, prelude::*};

use super::widgets::{button, description, info_row, row, section as titled, toggle_with};
use super::{SectionContext, replace_base, set_message, update};
use crate::platform::icloud;
use crate::settings::{export, sync};
use crate::workspace::AppData;

pub(super) fn section(ctx: &SectionContext) -> gpui::Div {
    let chrome = ctx.chrome;
    let on = ctx.settings.general.icloud_sync;

    let mut cloud = titled("iCloud Sync", chrome)
        .child(row(
            "Sync Settings via iCloud",
            toggle_with("icloud-sync", on, chrome, |cx, v| {
                update(cx, |s| s.general.icloud_sync = v)
            }),
            chrome,
        ))
        .child(description(
            "Keep your Chau7 Next settings synchronized across all your Macs",
            chrome,
        ));
    if on {
        if !icloud::current().is_available() {
            cloud = cloud.child(description(
                "iCloud is not available (the app must run from its bundle, signed with the iCloud entitlement): settings stay on this Mac.",
                chrome,
            ));
        }
        if let Some(synced) = ctx.sync.and_then(|s| s.last_sync) {
            let age = SystemTime::now()
                .duration_since(synced)
                .map(|d| d.as_secs())
                .unwrap_or(0);
            cloud = cloud.child(info_row("Last Sync", relative_age(age), chrome));
        }
        if let Some(message) = ctx.sync.and_then(|s| s.message.clone()) {
            cloud = cloud.child(description(message, chrome));
        }
        cloud = cloud.child(
            div()
                .flex()
                .gap_2()
                .child(button("sync-now", "Sync Now", chrome).on_click(|_, _, cx| {
                    sync::push_now(cx);
                    cx.refresh_windows();
                }))
                .child(
                    button("sync-restore", "Restore from iCloud", chrome).on_click(|_, _, cx| {
                        let _ = sync::restore(cx);
                        cx.refresh_windows();
                    }),
                ),
        );
    }

    let backup = titled("Settings Backup", chrome)
        .child(description(
            "Export your settings to a JSON file or import from a backup.",
            chrome,
        ))
        .child(
            div()
                .flex()
                .gap_2()
                .child(
                    button("export-settings", "Export Settings...", chrome)
                        .on_click(|_, _, cx| export_settings(cx)),
                )
                .child(
                    button("import-settings", "Import Settings...", chrome)
                        .on_click(|_, _, cx| import_settings(cx)),
                ),
        );

    let reset = titled("Reset All Settings to Defaults", chrome).child(
        div().flex().justify_end().child(
            button("reset-all", "Reset All Settings to Defaults", chrome)
                .on_click(|_, window, cx| super::general::confirm_reset_all(window, cx)),
        ),
    );
    div()
        .flex()
        .flex_col()
        .child(cloud)
        .child(backup)
        .child(reset)
}

/// Export Settings...: save panel, then the JSON document.
fn export_settings(cx: &mut App) {
    let home = cx.global::<AppData>().root.home().to_path_buf();
    let text = export::export_json_with_recent(
        &cx.global::<crate::settings::config_files::ConfigFiles>()
            .base,
        &home.to_string_lossy(),
        &match crate::repository::recent_roots(cx) {
            Ok(roots) => roots,
            Err(reason) => {
                set_message(cx, reason, true);
                return;
            }
        },
    );
    let text = match text {
        Ok(text) => text,
        Err(reason) => {
            set_message(cx, reason, true);
            return;
        }
    };
    let path = cx.prompt_for_new_path(&home, Some(export::EXPORT_FILE_NAME));
    let background = cx.background_executor().clone();
    cx.spawn(async move |cx| {
        if let Ok(Ok(Some(path))) = path.await {
            let write_path = path.clone();
            let result = background
                .spawn(async move { std::fs::write(write_path, text) })
                .await;
            cx.update(|cx| match result {
                Ok(()) => set_message(
                    cx,
                    format!("Settings exported to {}", path.display()),
                    false,
                ),
                Err(err) => {
                    log::error!("failed to export settings: {err}");
                    set_message(cx, format!("Failed to export settings: {err}"), true)
                }
            });
        }
    })
    .detach();
}

/// Import Settings...: pick a file, apply it, show why it failed otherwise.
fn import_settings(cx: &mut App) {
    let paths = cx.prompt_for_paths(PathPromptOptions {
        files: true,
        directories: false,
        multiple: false,
        prompt: Some("Import".into()),
    });
    let background = cx.background_executor().clone();
    cx.spawn(async move |cx| {
        let Ok(Ok(Some(paths))) = paths.await else {
            return;
        };
        let Some(path) = paths.into_iter().next() else {
            return;
        };
        let read_path = path.clone();
        let text = background
            .spawn(async move { export::read_settings_document(&read_path) })
            .await;
        cx.update(|cx| {
            let text = match text {
                Ok(text) => text,
                Err(err) => {
                    set_message(cx, format!("Failed to read file: {err}"), true);
                    return;
                }
            };
            let home = cx
                .global::<AppData>()
                .root
                .home()
                .to_string_lossy()
                .into_owned();
            let mut base = cx
                .global::<crate::settings::config_files::ConfigFiles>()
                .base
                .clone();
            match export::import_json_with_recent(&mut base, &text, &home) {
                Ok(recent_roots) => {
                    replace_base(cx, base);
                    if let Some(roots) = recent_roots {
                        crate::repository::import_recent_roots(roots, cx);
                    }
                    set_message(cx, "Settings imported".to_string(), false);
                }
                Err(reason) => {
                    set_message(cx, format!("Invalid settings file format: {reason}"), true)
                }
            }
        });
    })
    .detach();
}
