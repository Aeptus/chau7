//! Saving the state of a tab's panes for the next launch: the split layout,
//! each pane's directory and scrollback, and the AI session it was running
//! (`exportTabStates` in `Overlay/OverlayTabsModel.swift`). The scrollback of
//! each pane is a text file in the Chau7 Next state folder
//! (`DataRoot::scrollback_dir`); `PaneTree::from_saved` replays it.

use std::collections::{HashMap, HashSet};
use std::hash::{Hash, Hasher};
use std::path::PathBuf;
use std::sync::Mutex;
use std::time::{SystemTime, UNIX_EPOCH};

use chau7_next_core::command_detection::detect_app_from_output;
use chau7_next_core::data_root::DataRoot;
use chau7_next_core::session_restore::{
    REPLAY_FILE_PREFIX, SavedSplitNode, build_ai_resume_command, capture_styled_scrollback,
    resolve_ai_resume_metadata, strip_restore_commands,
};
use gpui::{App, Entity};

use crate::pane::{PaneId, PaneTree};
use crate::session_store::SavedPane;
use crate::settings::Settings;
use crate::workspace::AppData;

/// Everything saved for one tab beyond its title and color.
pub struct TabCapture {
    pub layout: Option<SavedSplitNode>,
    pub focused: Option<PaneId>,
    pub panes: Vec<SavedPane>,
}

/// Hash of the text last written for each pane, to skip identical rewrites
/// (the session is saved every 15 seconds).
static LAST_WRITTEN: Mutex<Option<HashMap<PaneId, u64>>> = Mutex::new(None);

pub fn scrollback_file(root: &DataRoot, pane: PaneId) -> PathBuf {
    root.scrollback_dir().join(format!("{pane}.txt"))
}

fn unix_now() -> f64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs_f64())
        .unwrap_or(0.0)
}

fn text_hash(text: &str) -> u64 {
    let mut hasher = std::collections::hash_map::DefaultHasher::new();
    text.hash(&mut hasher);
    hasher.finish()
}

/// Write (or remove) the scrollback file of a pane. Returns whether a file
/// exists afterwards.
fn store_scrollback(root: &DataRoot, pane: PaneId, text: Option<&str>) -> bool {
    let path = scrollback_file(root, pane);
    let mut guard = LAST_WRITTEN.lock().unwrap_or_else(|e| e.into_inner());
    let hashes = guard.get_or_insert_with(HashMap::new);
    let Some(text) = text else {
        hashes.remove(&pane);
        let _ = std::fs::remove_file(&path);
        return false;
    };
    let hash = text_hash(text);
    if hashes.get(&pane) == Some(&hash) && path.is_file() {
        return true;
    }
    let result = std::fs::create_dir_all(root.scrollback_dir()).and_then(|_| {
        let tmp = path.with_extension("txt.tmp");
        std::fs::write(&tmp, text)?;
        std::fs::rename(&tmp, &path)
    });
    match result {
        Ok(()) => {
            hashes.insert(pane, hash);
            true
        }
        Err(err) => {
            log::warn!("save scrollback of pane {pane}: {err}");
            false
        }
    }
}

/// Capture the layout and per-pane state of one tab. `claimed` holds the AI
/// session ids already given to other panes of the window, so two panes in
/// the same directory never resume the same session.
pub fn capture_tab(
    panes: &Entity<PaneTree>,
    claimed: &mut HashSet<String>,
    cx: &App,
) -> TabCapture {
    let root = &cx.global::<AppData>().root;
    let max_lines = Settings::get(cx).terminal.restored_scrollback_lines;
    let tree = panes.read(cx);
    if let Some(saved) = tree.deferred_saved() {
        for pane in &saved.panes {
            if let Some(id) = &pane.ai_session_id {
                claimed.insert(id.clone());
            }
        }
        return TabCapture {
            layout: saved.layout.clone(),
            focused: saved.focused_pane,
            panes: saved.panes.clone(),
        };
    }
    let mut saved = Vec::new();
    for (id, session) in tree.pane_sessions(cx) {
        // Not replayed yet (the app was closed right after launch): keep what
        // was loaded instead of saving the still empty terminal.
        if let Some(pending) = tree.pending_restore(id) {
            if let Some(session_id) = &pending.ai_session_id {
                claimed.insert(session_id.clone());
            }
            saved.push(pending.clone());
            continue;
        }
        let session = session.read(cx);
        let directory = crate::pane::live_cwd(session).map(|p| p.to_string_lossy().to_string());
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
        let has_file = store_scrollback(root, id, scrollback.as_deref());

        // The tool running in the pane, or the one its output shows.
        let app_name = session
            .ai_app
            .clone()
            .or_else(|| scrollback.as_deref().and_then(detect_app_from_output));
        let reference = unix_now() - session.last_activity.elapsed().as_secs_f64();
        // The session id the shell tracker saw first, then the newest
        // matching session on disk, then what was restored into the pane.
        let tracked = session
            .shell()
            .ai_provider()
            .zip(session.shell().ai_session_id())
            .map(|(p, id)| (p.to_string(), id.to_string()))
            .filter(|(_, id)| !claimed.contains(id));
        // Claude sessions seen by the hook monitor come first
        // (`findClaudeSessionId` uses `ClaudeCodeMonitor`), then the files.
        let from_hooks = || {
            let dir = directory.as_deref()?;
            let provider = app_name
                .as_deref()
                .and_then(chau7_next_core::ai::resume::normalize_provider_name)?;
            if provider != "claude" {
                return None;
            }
            let candidates: Vec<chau7_next_core::ai::resume::SessionCandidate> =
                crate::ai::hub::claude_session_candidates(dir, cx)
                    .into_iter()
                    .filter(|(id, _)| !claimed.contains(id))
                    .map(
                        |(session_id, touched_at)| chau7_next_core::ai::resume::SessionCandidate {
                            session_id,
                            touched_at,
                        },
                    )
                    .collect();
            chau7_next_core::ai::resume::best_session_match(&candidates, Some(reference))
                .map(|id| (provider, id))
        };
        let meta = tracked
            .or_else(from_hooks)
            .or_else(|| {
                directory.as_deref().and_then(|dir| {
                    resolve_ai_resume_metadata(
                        root.home(),
                        app_name.as_deref(),
                        dir,
                        Some(reference),
                        claimed,
                    )
                    .map(|m| (m.provider, m.session_id))
                })
            })
            .or_else(|| {
                // Codex sessions seen in its history (`codexHistoryEntries`).
                let provider = app_name
                    .as_deref()
                    .and_then(chau7_next_core::ai::resume::normalize_provider_name)
                    .or_else(|| session.shell().ai_provider().map(str::to_string))?;
                if provider != "codex" {
                    return None;
                }
                let dir = directory.as_deref()?;
                crate::ai::hub::codex_observed_session(dir, Some(reference), claimed, cx)
                    .map(|id| (provider, id))
            })
            .or_else(|| tree.resume_meta(id));
        if let Some((_, session_id)) = &meta {
            claimed.insert(session_id.clone());
        }
        saved.push(SavedPane {
            id,
            directory,
            scrollback: has_file,
            ai_resume_command: build_ai_resume_command(
                meta.as_ref().map(|m| m.0.as_str()),
                meta.as_ref().map(|m| m.1.as_str()),
            ),
            ai_provider: meta.as_ref().map(|m| m.0.clone()),
            ai_session_id: meta.map(|m| m.1),
        });
    }
    TabCapture {
        layout: tree.export_layout(cx),
        focused: tree.focused_pane_id(),
        panes: saved,
    }
}

/// Copy a pane's saved scrollback to a short-lived file for the shell to
/// `cat` and delete, so the next autosave cannot overwrite it mid-replay.
pub fn replay_copy(root: &DataRoot, pane: PaneId, token: &str) -> Option<PathBuf> {
    let source = scrollback_file(root, pane);
    let copy = root
        .scrollback_dir()
        .join(format!("{REPLAY_FILE_PREFIX}{token}-{pane}.txt"));
    match std::fs::copy(&source, &copy) {
        Ok(_) => Some(copy),
        Err(err) => {
            log::warn!("scrollback of pane {pane} not available: {err}");
            None
        }
    }
}

/// Delete scrollback files of panes that no longer exist, and replay copies
/// a crashed launch left behind.
pub fn prune_scrollback(root: &DataRoot, keep: &HashSet<PaneId>) {
    let Ok(entries) = std::fs::read_dir(root.scrollback_dir()) else {
        return;
    };
    let mut guard = LAST_WRITTEN.lock().unwrap_or_else(|e| e.into_inner());
    for entry in entries.flatten() {
        let name = entry.file_name().to_string_lossy().to_string();
        let stale = if let Some(stem) = name.strip_suffix(".txt") {
            match stem.parse::<PaneId>() {
                Ok(id) => {
                    if !keep.contains(&id) {
                        if let Some(hashes) = guard.as_mut() {
                            hashes.remove(&id);
                        }
                        true
                    } else {
                        false
                    }
                }
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
    fn replay_copy_is_separate_from_the_saved_file() {
        let root = temp_root("scrollback-copy");
        assert!(store_scrollback(&root, 21, Some("kept")));
        let copy = replay_copy(&root, 21, "tok").unwrap();
        assert_ne!(copy, scrollback_file(&root, 21));
        assert_eq!(std::fs::read_to_string(&copy).unwrap(), "kept");
        assert!(replay_copy(&root, 22, "tok").is_none());
        let _ = std::fs::remove_dir_all(root.home());
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
