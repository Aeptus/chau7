//! Saving the state of a tab's panes for the next launch: the split layout,
//! each pane's directory and scrollback, and the AI session it was running
//! (`exportTabStates` in `Overlay/OverlayTabsModel.swift`). The scrollback of
//! each pane is a text file in the Chau7 Next state folder
//! (`DataRoot::scrollback_dir`); `PaneTree::from_saved` replays it.

pub(crate) use chau7_next_core::session_restore::preparation;
pub(crate) mod writer;

use std::collections::HashSet;
use std::path::PathBuf;

use chau7_next_core::data_root::DataRoot;
use chau7_next_core::session_restore::{
    REPLAY_FILE_PREFIX, SavedSplitNode, build_ai_resume_command, capture_styled_scrollback,
    strip_restore_commands,
};
use gpui::{App, Entity};

use crate::pane::{PaneId, PaneTree};
use crate::session_store::SavedPane;
use crate::settings::Settings;

/// Everything saved for one tab beyond its title and color.
pub struct TabCapture {
    pub layout: Option<SavedSplitNode>,
    pub focused: Option<PaneId>,
    pub panes: Vec<SavedPane>,
    pub archived_context: Option<chau7_next_core::session_restore::models::ArchivedTabContext>,
}

pub fn scrollback_file(root: &DataRoot, pane: PaneId) -> PathBuf {
    root.scrollback_dir().join(format!("{pane}.txt"))
}

pub(crate) fn archived_ai_resume_for_capture(
    restored: Option<&SavedPane>,
) -> Option<chau7_next_core::session_restore::models::ArchivedAIResumeMetadata> {
    restored.and_then(|pane| pane.archived_ai_resume.clone())
}

/// Capture the layout and per-pane state of one tab. `claimed` holds the AI
/// session ids already given to other panes of the window, so two panes in
/// the same directory never resume the same session.
pub fn capture_tab(
    panes: &Entity<PaneTree>,
    claimed: &mut HashSet<String>,
    cx: &App,
) -> TabCapture {
    let max_lines = Settings::get(cx).terminal.restored_scrollback_lines;
    let tree = panes.read(cx);
    if let Some(saved) = tree.deferred_saved() {
        for pane in &saved.panes {
            if let Some(id) = &pane.ai_session_id {
                claimed.insert(format!(
                    "{}:{id}",
                    pane.ai_provider.as_deref().unwrap_or_default()
                ));
            }
        }
        return TabCapture {
            layout: saved.layout.clone(),
            focused: saved.focused_pane,
            panes: saved.panes.clone(),
            archived_context: saved.archived_context.clone(),
        };
    }
    let archived_context = tree.archived_context().cloned();
    let mut saved = Vec::new();
    for (id, session) in tree.pane_sessions(cx) {
        // Not replayed yet (the app was closed right after launch): keep what
        // was loaded instead of saving the still empty terminal.
        if let Some(pending) = tree.pending_restore(id) {
            if let Some(session_id) = &pending.ai_session_id {
                claimed.insert(format!(
                    "{}:{session_id}",
                    pending.ai_provider.as_deref().unwrap_or_default()
                ));
            }
            let mut pending = pending.clone();
            // Typing can begin before scrollback/resume replay finishes.
            // Preserve the current pane's history even on this early save path.
            pending.input_history = session.read(cx).input_history.clone();
            saved.push(pending);
            continue;
        }
        let session = session.read(cx);
        let directory = session
            .cwd
            .as_ref()
            .map(|p| p.to_string_lossy().to_string());
        let scrollback = if max_lines > 0 {
            let styled = session.styled_buffer_for_restore();
            let styled = strip_restore_commands(&styled);
            capture_styled_scrollback(
                Some(&styled),
                || strip_restore_commands(&session.buffer_text()),
                max_lines,
            )
        } else {
            None
        };
        let has_file = writer::record(id, scrollback, cx);

        // Persistence uses already captured identity only. Transcript validation
        // happens off UI during restore preparation. A fresh launch that clears
        // its native ID must not resurrect the preceding restored session.
        let available = |provider: &str, id: &str| !claimed.contains(&format!("{provider}:{id}"));
        let meta = session
            .shell()
            .ai_provider()
            .zip(session.shell().ai_session_id())
            .filter(|(provider, id)| available(provider, id))
            .map(|(provider, id)| (provider.to_owned(), id.to_owned()));
        // Missing ownership stays missing. Cwd/activity-based guesses can give
        // a tab a sibling's resume link before that sibling is captured.

        let inherited = tree.restored_metadata(id).filter(|pane| {
            meta.as_ref().is_some_and(|(provider, id)| {
                pane.ai_provider.as_deref() == Some(provider)
                    && pane.ai_session_id.as_deref() == Some(id)
            })
        });
        if let Some((provider, session_id)) = &meta {
            claimed.insert(format!("{provider}:{session_id}"));
        }
        saved.push(SavedPane {
            id,
            directory,
            scrollback: has_file,
            input_history: session.input_history.clone(),
            ai_resume_command: build_ai_resume_command(
                meta.as_ref().map(|m| m.0.as_str()),
                meta.as_ref().map(|m| m.1.as_str()),
            ),
            ai_provider: meta
                .as_ref()
                .map(|m| m.0.clone())
                .or_else(|| session.shell().ai_provider().map(str::to_owned)),
            ai_session_id: meta.map(|m| m.1),
            ai_session_id_source: inherited.and_then(|pane| pane.ai_session_id_source.clone()),
            archived_ai_resume: archived_ai_resume_for_capture(tree.restored_metadata(id)),
            last_input_at: Some(session.shell().last_input_at()),
            last_output_at: Some(session.shell().last_output_at()),
            known_repo_root: session
                .git_root
                .as_ref()
                .map(|p| p.to_string_lossy().into_owned()),
            known_git_branch: session.git_branch.clone(),
            last_status: Some(session.status().as_str().into()),
            agent_launch_command: session
                .is_ai_running()
                .then(|| session.shell().pending_command().map(str::to_owned))
                .flatten(),
            agent_started_at: session
                .is_ai_running()
                .then(|| session.shell().command_started_at()),
            last_exit_code: session
                .last_command
                .as_ref()
                .map(|command| command.exit_code),
            last_exit_at: session.blocks().blocks().iter().rev().find_map(|block| {
                block
                    .end_time
                    .map(|time| time.timestamp_millis() as f64 / 1000.0)
            }),
        });
    }
    TabCapture {
        layout: tree.export_layout(cx),
        focused: tree.focused_pane_id(),
        panes: saved,
        archived_context,
    }
}

/// Delete scrollback files of panes that no longer exist, and replay copies
/// a crashed launch left behind.
pub fn prune_scrollback(root: &DataRoot, keep: &HashSet<PaneId>) {
    let Ok(entries) = std::fs::read_dir(root.scrollback_dir()) else {
        return;
    };
    for entry in entries.flatten() {
        let name = entry.file_name().to_string_lossy().to_string();
        let stale = if let Some(stem) = name.strip_suffix(".txt") {
            match stem.parse::<PaneId>() {
                Ok(id) => !keep.contains(&id),
                // restore-<token>-<pane>.txt: only old ones, a replay may be running.
                Err(_) => {
                    name.starts_with(REPLAY_FILE_PREFIX)
                        && entry
                            .metadata()
                            .and_then(|m| m.modified())
                            .ok()
                            .and_then(|t| t.elapsed().ok())
                            .is_some_and(|age| age.as_secs() > 3600)
                }
            }
        } else {
            name.ends_with(".tmp")
        };
        if stale {
            let _ = std::fs::remove_file(entry.path());
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;

    fn store_scrollback(root: &DataRoot, pane: PaneId, text: Option<&str>) -> bool {
        let contexts = HashMap::from([(
            pane,
            chau7_next_core::session_restore::writer::ContextBuffer {
                version: 1,
                text: text.map(|s| std::sync::Arc::new(s.to_owned())),
            },
        )]);
        writer::write_contexts(root, &contexts).unwrap();
        text.is_some()
    }

    fn temp_root(name: &str) -> DataRoot {
        let home = std::env::temp_dir().join(format!("chau7-next-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&home);
        DataRoot::with_home(home, true)
    }

    #[test]
    fn stores_rewrites_and_removes_scrollback() {
        let root = temp_root("scrollback-store");
        assert!(store_scrollback(&root, 11, Some("hello\nworld")));
        let path = scrollback_file(&root, 11);
        assert_eq!(std::fs::read_to_string(&path).unwrap(), "hello\nworld");
        assert!(path.starts_with(root.state_dir()));
        assert!(store_scrollback(&root, 11, Some("changed")));
        assert_eq!(std::fs::read_to_string(&path).unwrap(), "changed");
        assert!(!store_scrollback(&root, 11, None));
        assert!(!path.exists());
        let _ = std::fs::remove_dir_all(root.home());
    }

    #[test]
    fn direct_restore_reads_owned_context_without_creating_replay_files() {
        let root = temp_root("scrollback-direct-restore");
        assert!(store_scrollback(&root, 21, Some("kept")));
        let saved = crate::session_store::SavedTab {
            panes: vec![SavedPane {
                id: 21,
                scrollback: true,
                ..Default::default()
            }],
            ..Default::default()
        };
        let prepared = preparation::prepare(&root, saved, None);
        assert_eq!(prepared.panes[&21].context.as_deref(), Some("kept"));
        assert_eq!(
            std::fs::read_to_string(scrollback_file(&root, 21)).unwrap(),
            "kept"
        );
        assert_eq!(std::fs::read_dir(root.scrollback_dir()).unwrap().count(), 1);
        let _ = std::fs::remove_dir_all(root.home());
    }

    #[test]
    fn active_capture_keeps_archival_ai_metadata_inert() {
        let archived = chau7_next_core::session_restore::models::ArchivedAIResumeMetadata {
            provider: Some("codex".into()),
            session_id: Some("synth:fixture".into()),
            session_id_source: Some("synthetic".into()),
            resume_command: None,
        };
        let restored = SavedPane {
            archived_ai_resume: Some(archived.clone()),
            ..Default::default()
        };

        assert_eq!(
            archived_ai_resume_for_capture(Some(&restored)),
            Some(archived)
        );
        assert!(
            chau7_next_core::session_restore::resolve_resume_metadata_from_saved(
                restored.ai_provider.as_deref(),
                restored.ai_session_id.as_deref(),
                restored.ai_resume_command.as_deref(),
            )
            .is_none()
        );
        assert!(
            build_ai_resume_command(
                restored.ai_provider.as_deref(),
                restored.ai_session_id.as_deref(),
            )
            .is_none()
        );
    }

    #[test]
    fn prune_keeps_only_listed_panes() {
        let root = temp_root("scrollback-prune");
        assert!(store_scrollback(&root, 31, Some("a")));
        assert!(store_scrollback(&root, 32, Some("b")));
        prune_scrollback(&root, &[31].into());
        assert!(scrollback_file(&root, 31).exists());
        assert!(!scrollback_file(&root, 32).exists());
        let _ = std::fs::remove_dir_all(root.home());
    }
}
