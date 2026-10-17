//! Native regression for a final save dispatched from the second owned window.
//! All shells are an owned `/bin/sh` script that records input without running it.

use super::AppData;
use crate::session_store::{SavedPane, SavedSession, SavedTab, SavedWindow};
use chau7_next_core::session_restore::{SavedAxis, SavedSplitNode};
use gpui::{AnyWindowHandle, App, AsyncApp, Entity};
use objc2::MainThreadMarker;
use objc2_app_kit::{NSApplication, NSApplicationActivationPolicy};
use serde_json::json;
use std::io::{Read, Write};
use std::os::unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::sync::{
    Arc,
    atomic::{AtomicI32, Ordering},
};
use std::time::{Duration, Instant};

const FIRST_TAB_UUID: &str = "10000000-0000-4000-8000-000000000101";
const SECOND_TAB_UUID: &str = "10000000-0000-4000-8000-000000000102";
const LATE_SECOND_TAB_UUID: &str = "10000000-0000-4000-8000-000000000103";
const FIRST_RESUME_ID: &str = "fixture-first-window";
const SECOND_RESUME_ID: &str = "fixture-second-window";
const LATE_SECOND_RESUME_ID: &str = "fixture-second-window-latest";
const LATE_SECOND_EDITOR_ID: u64 = 7304;
const LATE_SECOND_SPLIT_ID: u64 = 7305;
const OWNER_RECEIPT_NAME: &str = "native-multiwindow-owner";
const FAKE_SHELL_NAME: &str = "native-multiwindow-fake-shell";
const FAKE_SHELL_CONTENT: &[u8] =
    b"#!/bin/sh\nprintf started > fixture-shell-started\nexec /bin/cat > fixture-shell-input\n";
const EDITOR_RELATIVE_PATH: &str = "pane-7303/fixture-editor.md";
const EDITOR_PANEL_CONTENT: &str =
    "Native multiwindow fixture editor panel\nContent survives a two-process restore.\n";

fn error(error: impl std::fmt::Display) -> String {
    error.to_string()
}

pub(crate) fn validate_token(token: &str) -> Result<(), String> {
    if token.len() != 32 || !token.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        return Err("multiwindow fixture owner token is malformed".into());
    }
    Ok(())
}

fn validate_home_location(home: &Path) -> Result<(), String> {
    let temporary = std::env::temp_dir().canonicalize().map_err(error)?;
    let parent = home
        .parent()
        .ok_or("multiwindow fixture home lacks a parent")?
        .canonicalize()
        .map_err(error)?;
    let name_ok = home
        .file_name()
        .and_then(|name| name.to_str())
        .is_some_and(|name| name.starts_with("chau7-native-fixture-"));
    let metadata = std::fs::symlink_metadata(home).map_err(error)?;
    if parent != temporary
        || !name_ok
        || metadata.file_type().is_symlink()
        || !metadata.is_dir()
        || home.canonicalize().map_err(error)? != home
        || metadata.uid() != unsafe { libc::geteuid() }
    {
        return Err("multiwindow fixture home is not its exact owned temporary directory".into());
    }
    Ok(())
}

pub(crate) fn create_owned_home_receipt(home: &Path, token: &str) -> Result<(), String> {
    validate_token(token)?;
    validate_home_location(home)?;
    let path = home.join(OWNER_RECEIPT_NAME);
    let mut options = std::fs::OpenOptions::new();
    options.write(true).create_new(true).mode(0o600);
    let mut receipt = options.open(path).map_err(error)?;
    receipt.write_all(token.as_bytes()).map_err(error)?;
    receipt.sync_all().map_err(error)
}

pub(crate) fn validate_owned_home_receipt(home: &Path, token: &str) -> Result<(), String> {
    validate_token(token)?;
    validate_home_location(home)?;
    let path = home.join(OWNER_RECEIPT_NAME);
    let metadata = std::fs::symlink_metadata(&path).map_err(error)?;
    if metadata.file_type().is_symlink()
        || !metadata.is_file()
        || metadata.nlink() != 1
        || metadata.uid() != unsafe { libc::geteuid() }
        || metadata.mode() & 0o777 != 0o600
        || metadata.len() != token.len() as u64
    {
        return Err("multiwindow fixture owner receipt is not a private regular file".into());
    }
    let mut bytes = Vec::with_capacity(token.len());
    std::fs::File::open(path)
        .map_err(error)?
        .take(token.len() as u64 + 1)
        .read_to_end(&mut bytes)
        .map_err(error)?;
    if bytes != token.as_bytes() {
        return Err("multiwindow fixture owner receipt does not match this run".into());
    }
    Ok(())
}

fn activate_owned_application(cx: &mut App) -> Result<(), String> {
    let application = NSApplication::sharedApplication(
        MainThreadMarker::new().ok_or("multiwindow fixture is not on the main thread")?,
    );
    if application.activationPolicy() != NSApplicationActivationPolicy::Regular {
        application.setActivationPolicy(NSApplicationActivationPolicy::Regular);
    }
    if application.activationPolicy() != NSApplicationActivationPolicy::Regular {
        return Err("multiwindow fixture application could not become regular".into());
    }
    application.activate();
    cx.activate(true);
    Ok(())
}

fn saved_tab(
    home: &Path,
    uuid: &str,
    title: &str,
    pane_id: u64,
    resume_id: &str,
) -> Result<SavedTab, String> {
    let cwd = home.join(format!("pane-{pane_id}"));
    std::fs::create_dir_all(&cwd).map_err(error)?;
    let directory = cwd.to_string_lossy().into_owned();
    let layout = if uuid == LATE_SECOND_TAB_UUID {
        let editor_path = home.join(EDITOR_RELATIVE_PATH);
        std::fs::write(&editor_path, EDITOR_PANEL_CONTENT).map_err(error)?;
        Some(SavedSplitNode::Split {
            id: LATE_SECOND_SPLIT_ID,
            axis: SavedAxis::Horizontal,
            ratios: vec![0.62, 0.38],
            children: vec![
                SavedSplitNode::Terminal {
                    id: pane_id,
                    directory: Some(directory.clone()),
                },
                SavedSplitNode::Editor {
                    id: LATE_SECOND_EDITOR_ID,
                    path: Some(editor_path.to_string_lossy().into_owned()),
                },
            ],
        })
    } else {
        Some(SavedSplitNode::Terminal {
            id: pane_id,
            directory: Some(directory.clone()),
        })
    };
    Ok(SavedTab {
        uuid: Some(uuid::Uuid::parse_str(uuid).map_err(error)?),
        cwd: Some(cwd.clone()),
        custom_title: Some(title.to_owned()),
        focused_pane: Some(pane_id),
        layout,
        panes: vec![SavedPane {
            id: pane_id,
            directory: Some(directory),
            ai_provider: Some("codex".into()),
            ai_session_id: Some(resume_id.to_owned()),
            ai_resume_command: Some(format!("codex resume {resume_id}")),
            ..Default::default()
        }],
        ..Default::default()
    })
}

fn install_fake_shell(home: &Path, cx: &mut App, create: bool) -> Result<PathBuf, String> {
    let shell = home.join(FAKE_SHELL_NAME);
    if create {
        std::fs::write(&shell, FAKE_SHELL_CONTENT).map_err(error)?;
        std::fs::set_permissions(&shell, std::fs::Permissions::from_mode(0o700)).map_err(error)?;
    }
    let metadata = std::fs::symlink_metadata(&shell).map_err(error)?;
    if metadata.file_type().is_symlink()
        || !metadata.is_file()
        || metadata.uid() != unsafe { libc::geteuid() }
        || metadata.mode() & 0o777 != 0o700
        || std::fs::read(&shell).map_err(error)? != FAKE_SHELL_CONTENT
    {
        return Err(
            "multiwindow fixture fake shell does not match its bounded owned script".into(),
        );
    }
    cx.global_mut::<crate::settings::Settings>().terminal.shell =
        Some(shell.to_string_lossy().into_owned());
    Ok(shell)
}

fn validate_owned_editor_file(home: &Path) -> Result<(), String> {
    for pane_id in [7301, 7302, 7303] {
        let directory = home.join(format!("pane-{pane_id}"));
        let metadata = std::fs::symlink_metadata(&directory).map_err(error)?;
        if metadata.file_type().is_symlink()
            || !metadata.is_dir()
            || metadata.uid() != unsafe { libc::geteuid() }
            || directory.canonicalize().map_err(error)? != directory
        {
            return Err(format!(
                "multiwindow fixture pane {pane_id} is not an owned real directory"
            ));
        }
    }
    let editor = home.join(EDITOR_RELATIVE_PATH);
    let metadata = std::fs::symlink_metadata(&editor).map_err(error)?;
    if metadata.file_type().is_symlink()
        || !metadata.is_file()
        || metadata.nlink() != 1
        || metadata.uid() != unsafe { libc::geteuid() }
        || metadata.len() != EDITOR_PANEL_CONTENT.len() as u64
        || std::fs::read(&editor).map_err(error)? != EDITOR_PANEL_CONTENT.as_bytes()
    {
        return Err("multiwindow fixture editor panel file is not its exact owned content".into());
    }
    Ok(())
}

fn saved_tab_matches(
    tab: &SavedTab,
    home: &Path,
    uuid: &str,
    title: &str,
    pane_id: u64,
    resume_id: &str,
    with_editor: bool,
) -> bool {
    let Ok(uuid) = uuid::Uuid::parse_str(uuid) else {
        return false;
    };
    let directory = home.join(format!("pane-{pane_id}"));
    let directory_string = directory.to_string_lossy();
    let editor_path = home.join(EDITOR_RELATIVE_PATH);
    let editor_path_string = editor_path.to_string_lossy().into_owned();
    let expected_resume_command = format!("codex resume {resume_id}");
    let pane_matches = tab.panes.len() == 1
        && tab.panes[0].id == pane_id
        && tab.panes[0].directory.as_deref() == Some(directory_string.as_ref())
        && tab.panes[0].ai_provider.as_deref() == Some("codex")
        && tab.panes[0].ai_session_id.as_deref() == Some(resume_id)
        && tab.panes[0].ai_resume_command.as_deref() == Some(expected_resume_command.as_str());
    let layout_matches = match (&tab.layout, with_editor) {
        (
            Some(SavedSplitNode::Split {
                axis: SavedAxis::Horizontal,
                ratios,
                children,
                ..
            }),
            true,
        ) => {
            ratios.len() == 2
                && ratios.iter().all(|ratio| ratio.is_finite() && *ratio > 0.0)
                && (ratios.iter().sum::<f32>() - 1.0).abs() < 0.01
                && children.len() == 2
                && matches!(
                    &children[0],
                    SavedSplitNode::Terminal { id, directory: Some(path) }
                        if *id == pane_id && path == directory_string.as_ref()
                )
                && matches!(
                    &children[1],
                    SavedSplitNode::Editor { id, path: Some(path) }
                        if *id == LATE_SECOND_EDITOR_ID
                            && path == &editor_path_string
                )
        }
        (
            Some(SavedSplitNode::Terminal {
                id,
                directory: Some(path),
            }),
            false,
        ) => *id == pane_id && path == directory_string.as_ref(),
        _ => false,
    };
    tab.uuid == Some(uuid)
        && tab.custom_title.as_deref() == Some(title)
        && tab.cwd.as_deref() == Some(directory.as_path())
        && tab.focused_pane == Some(pane_id)
        && pane_matches
        && layout_matches
}

fn saved_session_matches(session: &SavedSession, home: &Path) -> bool {
    if session.version != 1
        || session.windows.len() != 2
        || session.windows[0].tabs.len() != 1
        || session.windows[1].tabs.len() != 2
        || session.windows[0].selected != 0
        || session.windows[1].selected != 1
    {
        return false;
    }
    saved_tab_matches(
        &session.windows[0].tabs[0],
        home,
        FIRST_TAB_UUID,
        "first-window",
        7301,
        FIRST_RESUME_ID,
        false,
    ) && saved_tab_matches(
        &session.windows[1].tabs[0],
        home,
        SECOND_TAB_UUID,
        "second-window-initial",
        7302,
        SECOND_RESUME_ID,
        false,
    ) && saved_tab_matches(
        &session.windows[1].tabs[1],
        home,
        LATE_SECOND_TAB_UUID,
        "second-window-latest-at-quit",
        7303,
        LATE_SECOND_RESUME_ID,
        true,
    )
}

fn editor_panel_loaded(workspace: &super::Workspace, home: &Path, cx: &App) -> bool {
    let editor_path = home.join(EDITOR_RELATIVE_PATH);
    let Some(tab_id) = workspace.state.selected() else {
        return false;
    };
    let Some(entry) = workspace.entries.get(&tab_id) else {
        return false;
    };
    let tree = entry.panes.read(cx);
    tree.views().len() == 1
        && tree.leaves().into_iter().any(|item| match item {
            crate::pane::PaneItem::Editor(editor) => {
                let editor = editor.read(cx);
                !editor.is_loading()
                    && editor.path() == Some(editor_path.as_path())
                    && editor.content(cx) == EDITOR_PANEL_CONTENT
            }
            _ => false,
        })
}

fn live_restore_matches(
    workspaces: &[(AnyWindowHandle, Entity<super::Workspace>)],
    home: &Path,
    cx: &mut App,
) -> Result<bool, String> {
    if workspaces.len() != 2 {
        return Err(format!(
            "fixture has {} live workspaces during relaunch verification",
            workspaces.len()
        ));
    }
    let mut windows = Vec::with_capacity(workspaces.len());
    for (handle, workspace) in workspaces {
        let snapshot = handle
            .update(cx, |_, window, app| {
                workspace.read(app).snapshot(window, app)
            })
            .map_err(error)?;
        windows.push(snapshot);
    }
    let session = SavedSession {
        version: 1,
        windows,
    };
    let second_workspace = workspaces[1].1.read(cx);
    Ok(saved_session_matches(&session, home) && editor_panel_loaded(second_workspace, home, cx))
}

/// Install two real production workspaces in the fixture app. Their panes use
/// a bounded fake shell from this profile; resume commands are only saved data.
pub(crate) fn prepare(home: &Path, token: &str, cx: &mut App) -> Result<(), String> {
    create_owned_home_receipt(home, token)?;
    install_fake_shell(home, cx, true)?;

    let first = saved_tab(home, FIRST_TAB_UUID, "first-window", 7301, FIRST_RESUME_ID)?;
    let second = saved_tab(
        home,
        SECOND_TAB_UUID,
        "second-window-initial",
        7302,
        SECOND_RESUME_ID,
    )?;
    for tab in [first, second] {
        let saved = SavedWindow {
            tabs: vec![tab],
            selected: 0,
            ..Default::default()
        };
        crate::open_workspace_window(Some(saved), cx)
            .ok_or_else(|| "could not open an owned native restore window".to_owned())?;
    }
    Ok(())
}

pub(crate) fn prepare_relaunch(
    home: &Path,
    token: &str,
    cx: &mut App,
) -> Result<Vec<(AnyWindowHandle, Entity<super::Workspace>)>, String> {
    validate_owned_home_receipt(home, token)?;
    validate_owned_editor_file(home)?;
    install_fake_shell(home, cx, false)?;
    let root = cx.global::<AppData>().root.clone();
    let mut saved = crate::session_store::load(&root)
        .ok_or("multiwindow fixture session_store::load returned no saved session")?;
    if !saved_session_matches(&saved, home) {
        return Err(
            "production session_store::load did not retain the expected two-window fixture state"
                .into(),
        );
    }
    for tab in saved.windows.iter_mut().flat_map(|window| &mut window.tabs) {
        tab.uuid.get_or_insert_with(uuid::Uuid::new_v4);
    }
    crate::restore::preparation::register_saved_identity_hints(
        &root,
        saved.windows.iter().flat_map(|window| &window.tabs),
    );
    for window in saved.windows {
        crate::open_workspace_window(Some(window), cx)
            .ok_or("production open_workspace_window failed for a restored fixture window")?;
    }
    let workspaces = AppData::live(cx);
    if workspaces.len() != 2 {
        return Err(format!(
            "production open_workspace_window opened {} restored fixture workspaces instead of two",
            workspaces.len()
        ));
    }
    Ok(workspaces)
}

/// Wait for both owned windows to reach a native frame, then add the latest
/// second-window tab and dispatch the production quit path before that window
/// update returns. The prepared receipt is flushed before quit is requested;
/// Python validates the final manifest after the process exits.
pub(crate) async fn add_latest_tab_and_request_quit(
    cx: &mut AsyncApp,
    completion: Arc<AtomicI32>,
) -> Result<(), String> {
    let workspaces = cx.update(|cx| AppData::live(cx));
    if workspaces.len() != 2 {
        return Err(format!(
            "fixture opened {} live workspaces instead of two",
            workspaces.len()
        ));
    }
    cx.update(activate_owned_application)?;
    for (handle, _) in &workspaces {
        // Both windows share centered default bounds. Bring each one to the
        // foreground in turn so an occluded window can submit its native frame.
        handle
            .update(cx, |_, window, _| window.activate_window())
            .map_err(error)?;
        crate::native_parity_fixture::next_frame(*handle, cx).await?;
    }

    let latest = {
        let home = cx.update(|cx| cx.global::<AppData>().root.home().to_path_buf());
        saved_tab(
            &home,
            LATE_SECOND_TAB_UUID,
            "second-window-latest-at-quit",
            7303,
            LATE_SECOND_RESUME_ID,
        )?
    };
    let (second_handle, second_workspace) = workspaces[1].clone();
    second_handle
        .update(cx, |_, window, app| -> Result<(), String> {
            let tab_count = second_workspace.update(app, |workspace, workspace_cx| {
                workspace.add_tab(Some(latest), true, window, workspace_cx);
                workspace.state.tabs().len()
            });
            if tab_count != 2 {
                return Err(format!(
                    "late mutation left {tab_count} second-window tabs instead of two"
                ));
            }

            let receipt = json!({
                "case": "multiwindow-restore",
                "pid": std::process::id(),
                "passed": true,
                "phase": "late_second_window_tab_prepared",
                "expected_windows": 2,
                "expected_tabs_per_window": [1, 2],
            });
            println!("{receipt}");
            std::io::stdout().flush().map_err(error)?;
            completion.store(0, Ordering::Release);

            // This is the same production entry point registered for Cmd+Q.
            // It defers final capture until this second-window update returns.
            crate::app_actions::request_quit(app);
            Ok(())
        })
        .map_err(error)?
}

/// Reopen the production session model in a second process, wait for both
/// native windows and the editor leaf to hydrate, then quit through the same
/// production action used by Cmd+Q.
pub(crate) async fn verify_relaunch_and_request_quit(
    cx: &mut AsyncApp,
    home: PathBuf,
    workspaces: Vec<(AnyWindowHandle, Entity<super::Workspace>)>,
    completion: Arc<AtomicI32>,
) -> Result<(), String> {
    if workspaces.len() != 2 {
        return Err(format!(
            "relaunch fixture opened {} workspaces instead of two",
            workspaces.len()
        ));
    }
    cx.update(activate_owned_application)?;
    for (handle, _) in &workspaces {
        handle
            .update(cx, |_, window, _| window.activate_window())
            .map_err(error)?;
        crate::native_parity_fixture::next_frame(*handle, cx).await?;
    }

    let deadline = Instant::now() + Duration::from_secs(12);
    loop {
        if cx.update(|cx| live_restore_matches(&workspaces, &home, cx))? {
            break;
        }
        if Instant::now() >= deadline {
            return Err(
                "relaunch did not restore both windows, saved pane identities, split layout, and editor content within 12 seconds".into(),
            );
        }
        cx.background_executor()
            .timer(Duration::from_millis(100))
            .await;
    }

    let receipt = json!({
        "case": "multiwindow-restore",
        "pid": std::process::id(),
        "passed": true,
        "phase": "restored_after_relaunch",
        "restored_windows": 2,
        "restored_tabs_per_window": [1, 2],
        "resume_identity_count": 3,
        "editor_split_leaf_loaded": true,
        "editor_content_verified": true,
        "restore_path": "session_store::load + open_workspace_window",
    });
    println!("{receipt}");
    std::io::stdout().flush().map_err(error)?;
    completion.store(0, Ordering::Release);

    let (second_handle, _) = workspaces[1].clone();
    second_handle
        .update(cx, |_, _, app| crate::app_actions::request_quit(app))
        .map_err(error)?;
    Ok(())
}
