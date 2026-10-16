//! Native regression for a final save dispatched from the second owned window.
//! All shells are an owned `/bin/sh` script that records input without running it.

use super::AppData;
use crate::session_store::{SavedPane, SavedTab, SavedWindow};
use chau7_next_core::session_restore::SavedSplitNode;
use gpui::{App, AsyncApp};
use serde_json::json;
use std::io::Write;
use std::os::unix::fs::PermissionsExt;
use std::path::Path;
use std::sync::{
    Arc,
    atomic::{AtomicI32, Ordering},
};

const FIRST_TAB_UUID: &str = "10000000-0000-4000-8000-000000000101";
const SECOND_TAB_UUID: &str = "10000000-0000-4000-8000-000000000102";
const LATE_SECOND_TAB_UUID: &str = "10000000-0000-4000-8000-000000000103";
const FIRST_RESUME_ID: &str = "fixture-first-window";
const SECOND_RESUME_ID: &str = "fixture-second-window";
const LATE_SECOND_RESUME_ID: &str = "fixture-second-window-latest";

fn error(error: impl std::fmt::Display) -> String {
    error.to_string()
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
    Ok(SavedTab {
        uuid: Some(uuid::Uuid::parse_str(uuid).map_err(error)?),
        cwd: Some(cwd.clone()),
        custom_title: Some(title.to_owned()),
        focused_pane: Some(pane_id),
        layout: Some(SavedSplitNode::Terminal {
            id: pane_id,
            directory: Some(directory.clone()),
        }),
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

/// Install two real production workspaces in the fixture app. Their panes use
/// a bounded fake shell from this profile; resume commands are only saved data.
pub(crate) fn prepare(home: &Path, cx: &mut App) -> Result<(), String> {
    let shell = home.join("native-multiwindow-fake-shell");
    std::fs::write(
        &shell,
        b"#!/bin/sh\nprintf started > fixture-shell-started\nexec /bin/cat > fixture-shell-input\n",
    )
    .map_err(error)?;
    std::fs::set_permissions(&shell, std::fs::Permissions::from_mode(0o700)).map_err(error)?;
    cx.global_mut::<crate::settings::Settings>().terminal.shell =
        Some(shell.to_string_lossy().into_owned());

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
    for (handle, _) in &workspaces {
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
    let dispatched = second_handle
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
        .map_err(error)?;
    dispatched
}
