//! Window and tab restore across launches (`session.json` in the Chau7 Next
//! state folder; the Swift app keeps its own in UserDefaults).
//!
//! Crash-safe backups (`persistTabStateBackups` in Swift): every save also
//! writes `TabStateBackups/latest.json`, and a copy goes to
//! `TabStateBackups/archive/` when the state changed and 5 minutes passed
//! since the last copy (and once per launch, for the state restored).
//! The archive keeps 120 files and nothing older than 30 days. When
//! `session.json` is missing or unreadable, restore uses `latest.json`, then
//! the newest archive that parses.

use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::{Duration, SystemTime};

use chau7_next_core::data_root::DataRoot;
use chau7_next_core::session_restore::SavedSplitNode;
use chau7_next_core::token_optimization::TabTokenOptOverride;
use serde::{Deserialize, Serialize};

/// What is saved for one terminal pane (`SavedTerminalPaneState`). The
/// scrollback text itself lives in `DataRoot::scrollback_dir()/<id>.txt`.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct SavedPane {
    pub id: u64,
    pub directory: Option<String>,
    /// A scrollback file exists for this pane.
    #[serde(default)]
    pub scrollback: bool,
    pub ai_provider: Option<String>,
    pub ai_session_id: Option<String>,
    /// `claude --resume <id>` or `codex resume <id>`, typed into the prompt
    /// (not run) after the restore.
    pub ai_resume_command: Option<String>,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct SavedTab {
    /// Stable tab identity (`OverlayTab.id`), the same after relaunch.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub uuid: Option<uuid::Uuid>,
    pub cwd: Option<PathBuf>,
    pub custom_title: Option<String>,
    pub color: Option<String>,
    pub repo_group_id: Option<String>,
    /// Per-tab token optimization override (`tokenOptOverride`), absent for "default".
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub token_opt_override: Option<TabTokenOptOverride>,
    /// When the tab was created, Unix seconds (`createdAt`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub created_at: Option<f64>,
    /// The color was picked by hand (beats the automatic AI color).
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub manual_color: bool,
    /// Split layout of the tab (`splitLayout`); `None` for a single shell
    /// started in `cwd` (sessions saved by older versions).
    #[serde(default)]
    pub layout: Option<SavedSplitNode>,
    /// Focused terminal pane (`focusedPaneID`).
    #[serde(default)]
    pub focused_pane: Option<u64>,
    #[serde(default)]
    pub panes: Vec<SavedPane>,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct SavedWindow {
    pub tabs: Vec<SavedTab>,
    pub selected: usize,
    pub x: f32,
    pub y: f32,
    pub width: f32,
    pub height: f32,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct SavedSession {
    pub version: u32,
    pub windows: Vec<SavedWindow>,
}

/// Archive at most every 5 minutes (`shouldArchiveTabStateBackup`).
const ARCHIVE_INTERVAL: Duration = Duration::from_secs(300);
/// Archive files kept (`pruneArchivedTabStateBackups`).
const ARCHIVE_KEEP: usize = 120;
/// Archive files older than this are deleted.
const ARCHIVE_MAX_AGE: Duration = Duration::from_secs(30 * 24 * 60 * 60);

/// Fingerprint and time of the last archived state.
static LAST_ARCHIVE: Mutex<Option<(u64, SystemTime)>> = Mutex::new(None);

fn parse(path: &Path) -> Option<SavedSession> {
    let text = std::fs::read_to_string(path).ok()?;
    serde_json::from_str(&text).ok()
}

/// `session.json`, else the backups (`tabStateRestoreCandidateURLs`).
pub fn load(root: &DataRoot) -> Option<SavedSession> {
    if let Some(session) = parse(&root.session_file()) {
        if let Ok(text) = serde_json::to_string_pretty(&session) {
            // `archiveImportedTabStateIfNeeded`: keep the state restored.
            let _ = write_backups(root, &text, Some("restoreSource"));
        }
        return Some(session);
    }
    let backups = root.tab_state_backups_dir();
    let mut candidates = vec![backups.join("latest.json")];
    candidates.extend(archive_files(&backups.join("archive")));
    candidates.iter().find_map(|path| {
        let session = parse(path)?;
        log::warn!("session.json unreadable: restored from {}", path.display());
        Some(session)
    })
}

pub fn save(root: &DataRoot, session: &SavedSession) -> std::io::Result<()> {
    save_for(root, session, false)
}

/// Save; at quit (`terminating`) the backup is always archived too, as Swift
/// does for the `termination` reason.
pub fn save_for(root: &DataRoot, session: &SavedSession, terminating: bool) -> std::io::Result<()> {
    root.ensure_dirs()?;
    let text = serde_json::to_string_pretty(session).map_err(std::io::Error::other)?;
    let tmp = root.session_file().with_extension("json.tmp");
    std::fs::write(&tmp, &text)?;
    std::fs::rename(tmp, root.session_file())?;
    crate::incidents::restore_payload(
        text.len() as u64,
        std::collections::BTreeMap::from([(
            "reason".into(),
            if terminating {
                "termination"
            } else {
                "autosave"
            }
            .into(),
        )]),
    );
    if let Err(err) = write_backups(root, &text, terminating.then_some("termination")) {
        log::warn!("tab state backup: {err}");
    }
    Ok(())
}

/// Archive files, newest first (names start with the time in milliseconds).
fn archive_files(dir: &Path) -> Vec<PathBuf> {
    let mut files: Vec<PathBuf> = std::fs::read_dir(dir)
        .map(|entries| {
            entries
                .filter_map(|e| e.ok().map(|e| e.path()))
                .filter(|p| p.extension().is_some_and(|x| x == "json"))
                .collect()
        })
        .unwrap_or_default();
    files.sort_by(|a, b| b.file_name().cmp(&a.file_name()));
    files
}

fn fingerprint(text: &str) -> u64 {
    use std::hash::{Hash, Hasher};
    let mut hasher = std::collections::hash_map::DefaultHasher::new();
    text.hash(&mut hasher);
    hasher.finish()
}

/// `forced`: archive now, under this reason (`restoreSource`, `termination`).
fn write_backups(root: &DataRoot, text: &str, forced: Option<&str>) -> std::io::Result<()> {
    let dir = root.tab_state_backups_dir();
    let archive = dir.join("archive");
    std::fs::create_dir_all(&archive)?;
    let latest = dir.join("latest.json");
    let tmp = latest.with_extension("json.tmp");
    std::fs::write(&tmp, text)?;
    std::fs::rename(tmp, latest)?;

    let now = SystemTime::now();
    let print = fingerprint(text);
    let mut last = LAST_ARCHIVE.lock().unwrap_or_else(|e| e.into_inner());
    let due = forced.is_some()
        || match *last {
            None => true,
            Some((previous, at)) => {
                previous != print && now.duration_since(at).unwrap_or_default() >= ARCHIVE_INTERVAL
            }
        };
    if !due {
        return Ok(());
    }
    let millis = now
        .duration_since(SystemTime::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis();
    let reason = forced.unwrap_or("periodic");
    std::fs::write(archive.join(format!("{millis:013}-{reason}.json")), text)?;
    *last = Some((print, now));
    prune_archive(&archive, now);
    Ok(())
}

/// Keep the newest 120 archive files, none older than 30 days.
fn prune_archive(dir: &Path, now: SystemTime) {
    for (index, path) in archive_files(dir).into_iter().enumerate() {
        let too_old = std::fs::metadata(&path)
            .and_then(|m| m.modified())
            .is_ok_and(|modified| {
                now.duration_since(modified).unwrap_or_default() > ARCHIVE_MAX_AGE
            });
        if index >= ARCHIVE_KEEP || too_old {
            let _ = std::fs::remove_file(path);
        }
    }
}

/// Set by Reset Window Positions: windows are saved without a frame from now
/// on, so the next launch opens them centered at the default size.
static FORGET_POSITIONS: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

/// Drop the frame of a window about to be saved when positions were reset.
pub fn apply_position_reset(window: &mut SavedWindow) {
    if FORGET_POSITIONS.load(std::sync::atomic::Ordering::Relaxed) {
        window.width = 0.0;
        window.height = 0.0;
    }
}

/// Reset Window Positions: forget the frames in the saved session, and in the
/// ones saved from now on.
pub fn forget_positions(root: &DataRoot) -> std::io::Result<()> {
    FORGET_POSITIONS.store(true, std::sync::atomic::Ordering::Relaxed);
    let Some(mut session) = load(root) else {
        return Ok(());
    };
    for window in &mut session.windows {
        apply_position_reset(window);
    }
    save(root, &session)
}

/// Forget the saved windows (quit with no visible window). An empty session
/// is saved rather than the file removed, so restore does not fall back to a
/// backup of the windows that were closed.
pub fn clear(root: &DataRoot) -> std::io::Result<()> {
    save(root, &SavedSession::default())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trip_in_isolated_home() {
        let home = std::env::temp_dir().join(format!("chau7-next-session-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&home);
        let root = DataRoot::with_home(home.clone(), true);
        let session = SavedSession {
            version: 1,
            windows: vec![SavedWindow {
                tabs: vec![SavedTab {
                    uuid: Some(uuid::Uuid::from_u128(7)),
                    cwd: Some("/tmp".into()),
                    custom_title: Some("build".into()),
                    color: Some("green".into()),
                    repo_group_id: None,
                    token_opt_override: Some(TabTokenOptOverride::ForceOn),
                    created_at: Some(1_700_000_000.0),
                    manual_color: true,
                    layout: Some(SavedSplitNode::Terminal {
                        id: 7,
                        directory: Some("/tmp".into()),
                    }),
                    focused_pane: Some(7),
                    panes: vec![SavedPane {
                        id: 7,
                        directory: Some("/tmp".into()),
                        scrollback: true,
                        ai_provider: Some("claude".into()),
                        ai_session_id: Some("abc".into()),
                        ai_resume_command: Some("claude --resume abc".into()),
                    }],
                }],
                selected: 0,
                x: 10.0,
                y: 20.0,
                width: 800.0,
                height: 600.0,
            }],
        };
        save(&root, &session).unwrap();
        assert_eq!(load(&root), Some(session.clone()));
        assert!(root.session_file().starts_with(&home));
        // A damaged session.json falls back to the backup.
        std::fs::write(root.session_file(), "{ not json").unwrap();
        assert_eq!(load(&root), Some(session.clone()));
        std::fs::remove_file(root.session_file()).unwrap();
        std::fs::remove_file(root.tab_state_backups_dir().join("latest.json")).unwrap();
        // Then the newest archive copy.
        assert_eq!(load(&root), Some(session));
        clear(&root).unwrap();
        assert_eq!(load(&root), Some(SavedSession::default()));
        clear(&root).unwrap();
        let _ = std::fs::remove_dir_all(&home);
    }

    #[test]
    fn archive_keeps_120_files() {
        let dir = std::env::temp_dir().join(format!("chau7-next-archive-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        for i in 0..130 {
            std::fs::write(dir.join(format!("{i:013}-periodic.json")), "{}").unwrap();
        }
        prune_archive(&dir, SystemTime::now());
        let files = archive_files(&dir);
        assert_eq!(files.len(), ARCHIVE_KEEP);
        assert!(files[0].ends_with("0000000000129-periodic.json"));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn sessions_saved_before_split_restore_still_load() {
        let old = r#"{"version":1,"windows":[{"tabs":[{"cwd":"/tmp","custom_title":null,"color":"blue","repo_group_id":null}],"selected":0,"x":0.0,"y":0.0,"width":800.0,"height":600.0}]}"#;
        let session: SavedSession = serde_json::from_str(old).unwrap();
        let tab = &session.windows[0].tabs[0];
        assert_eq!(tab.cwd.as_deref(), Some(std::path::Path::new("/tmp")));
        assert!(tab.layout.is_none() && tab.panes.is_empty() && tab.focused_pane.is_none());
    }
}
