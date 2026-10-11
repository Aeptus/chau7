//! State snapshots and bug reports from the live app (`StateSnapshot.capture`,
//! `BugReporter`). The formats are in `chau7_next_core::bug_report`.

use std::collections::BTreeMap;
use std::path::PathBuf;
use std::sync::atomic::{AtomicUsize, Ordering};

use chau7_next_core::app_shell::version_label;
use chau7_next_core::bug_report::{
    ContextState, EventState, StateSnapshot, TabState, local_report, prefilled_issue_url,
    report_file_name,
};
use chau7_next_core::debug_context::DebugContext;
use chrono::{Local, Utc};
use gpui::{App, Entity};

use super::registry;
use crate::platform::system;
use crate::settings::Settings;
use crate::workspace::{AppData, TabDebugInfo, Workspace};

/// Lines of the log in a snapshot (`recentLogs`).
const SNAPSHOT_LOG_LINES: usize = 50;
/// Events in a snapshot (`claudeCodeEvents.suffix(20)`).
const SNAPSHOT_EVENTS: usize = 20;

/// The window shown last, while the console itself has the focus.
static LAST_WINDOW: AtomicUsize = AtomicUsize::new(0);

/// The window whose tabs the console and the reports describe: the key
/// window, else the one that was (Swift: `activeOverlayModel`).
pub fn active_workspace(cx: &App) -> Option<(usize, Entity<Workspace>)> {
    let live = AppData::live(cx);
    if live.is_empty() {
        return None;
    }
    let index = match live.iter().position(|(_, w)| w.read(cx).is_window_active()) {
        Some(index) => {
            LAST_WINDOW.store(index, Ordering::Relaxed);
            index
        }
        None => LAST_WINDOW.load(Ordering::Relaxed).min(live.len() - 1),
    };
    Some((index, live[index].1.clone()))
}

/// Tabs of the active window.
pub fn tabs(cx: &App) -> Vec<TabDebugInfo> {
    active_workspace(cx)
        .map(|(index, workspace)| workspace.read(cx).debug_tabs(index, cx))
        .unwrap_or_default()
}

/// Tabs of every window (Health tab).
#[allow(dead_code)]
pub fn all_tabs(cx: &App) -> Vec<TabDebugInfo> {
    AppData::live(cx)
        .iter()
        .enumerate()
        .flat_map(|(index, (_, workspace))| workspace.read(cx).debug_tabs(index, cx))
        .collect()
}

/// Version text, as the About page shows it.
pub fn app_version() -> String {
    let short = system::bundle_string("CFBundleShortVersionString");
    let build = system::bundle_string("CFBundleVersion");
    if short.is_none() && build.is_none() {
        return env!("CARGO_PKG_VERSION").to_string();
    }
    version_label(short.as_deref(), build.as_deref())
}

/// `featureFlags` of a snapshot.
pub fn feature_flags(cx: &App) -> BTreeMap<String, bool> {
    let productivity = &Settings::get(cx).productivity;
    let broadcast = AppData::live(cx)
        .iter()
        .any(|(_, w)| w.read(cx).broadcast_on());
    BTreeMap::from([
        ("snippets".to_string(), productivity.snippets_enabled),
        (
            "repoSnippets".to_string(),
            productivity.repo_snippets_enabled,
        ),
        ("broadcastMode".to_string(), broadcast),
        (
            "clipboardHistory".to_string(),
            productivity.clipboard_history_enabled,
        ),
        ("bookmarks".to_string(), productivity.bookmarks_enabled),
    ])
}

/// The state of the whole app now (`StateSnapshot.capture`).
pub fn capture(cx: &App) -> StateSnapshot {
    let tabs = tabs(cx);
    let active = tabs.iter().position(|t| t.selected).unwrap_or(0);
    let tab_states = tabs
        .iter()
        .map(|t| TabState {
            id: t.id.to_string(),
            title: if t.title.is_empty() {
                "(no terminal)".into()
            } else {
                t.title.clone()
            },
            custom_title: t.custom_title.clone(),
            active_app_name: Some(t.ai_app.clone().unwrap_or_default()),
            status: t.status.clone(),
            current_directory: t.cwd.clone(),
            is_git_repo: t.is_git_repo,
            git_branch: t.git_branch.clone(),
        })
        .collect::<Vec<_>>();
    let mut events = registry::events(cx);
    events.retain(|e| e.hook.is_some());
    events.truncate(SNAPSHOT_EVENTS);
    // Oldest first, like `suffix(20)`.
    events.reverse();
    let recent_events = events
        .into_iter()
        .map(|e| EventState {
            timestamp: e.timestamp,
            kind: e.kind,
            hook: e.hook.unwrap_or_default(),
            tool_name: e.tool,
            message: e.message,
        })
        .collect();
    let recent_logs = crate::logging::recent_lines(SNAPSHOT_LOG_LINES);
    StateSnapshot {
        timestamp: Utc::now(),
        app_version: app_version(),
        os_version: system::os_version(),
        tab_count: tab_states.len(),
        active_tab_index: active,
        tab_states,
        claude_sessions: registry::claude_sessions(cx),
        recent_events,
        feature_flags: feature_flags(cx),
        recent_logs,
        recent_incidents: crate::incidents::recent(),
        active_contexts: DebugContext::active()
            .iter()
            .map(|c| ContextState {
                id: c.id.clone(),
                operation: c.operation.clone(),
                start_time: c.start_time,
                duration_ms: c.running_ms(),
            })
            .collect(),
    }
}

/// Write the snapshot JSON to the snapshots folder; returns its path.
pub fn save_snapshot(snapshot: &StateSnapshot, cx: &App) -> Result<PathBuf, String> {
    let dir = cx.global::<AppData>().root.snapshots_dir();
    let path = dir.join(StateSnapshot::file_name(Local::now().naive_local()));
    std::fs::create_dir_all(&dir)
        .and_then(|()| std::fs::write(&path, snapshot.to_json()))
        .map_err(|err| {
            log::error!("Failed to save snapshot: {err}");
            err.to_string()
        })?;
    log::info!("State snapshot saved to {}", path.display());
    Ok(path)
}

/// Write the full local report and a snapshot next to it
/// (`BugReporter.generateReport`); returns the report path.
pub fn save_report(description: &str, cx: &App) -> Result<PathBuf, String> {
    let snapshot = capture(cx);
    let report = local_report(&snapshot, description, Utc::now());
    let dir = cx.global::<AppData>().root.reports_dir();
    let path = dir.join(report_file_name(Local::now().naive_local()));
    std::fs::create_dir_all(&dir)
        .and_then(|()| std::fs::write(&path, report))
        .map_err(|err| {
            log::error!("Failed to save bug report: {err}");
            err.to_string()
        })?;
    // The JSON snapshot goes along with it.
    let _ = save_snapshot(&snapshot, cx);
    log::info!("Bug report saved to {}", path.display());
    Ok(path)
}

/// The prefilled GitHub issue for the Report tab's "Generate Github Report".
pub fn issue_url(description: &str, cx: &App) -> String {
    let snapshot = capture(cx);
    let report = local_report(&snapshot, description, Utc::now());
    prefilled_issue_url(&snapshot.issue_title("Chau7"), &report)
}

/// Last lines of a tab's terminal, for "Terminal history" in reports.
pub fn terminal_history(tab: &str, cx: &App) -> Option<String> {
    let id: usize = tab.parse().ok()?;
    let (_, workspace) = active_workspace(cx)?;
    let session = workspace.read(cx).debug_session(id as _, cx)?;
    let text = session.read(cx).buffer_text();
    let lines: Vec<&str> = text.lines().collect();
    let start = lines.len().saturating_sub(50);
    let tail = lines[start..].join("\n");
    let tail = tail.trim_end();
    (!tail.is_empty()).then(|| tail.to_string())
}
