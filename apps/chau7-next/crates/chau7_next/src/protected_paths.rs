//! Protected folders (`ProtectedPathPolicy`): background repo detection
//! skips Downloads, Desktop, Documents, Library and system folders, so macOS
//! shows no privacy prompt the user did not ask for.
//!
//! Folders picked in the "Grant access" dialog are kept as security-scoped
//! bookmarks (`DataRoot::protected_folder_bookmarks_file`, base64 per root),
//! started again at launch and refreshed when stale, so they stay readable
//! without a new prompt. A root without a bookmark needs an explicit grant;
//! a failed activation is retried after 5 minutes. Reset Checks stops bookmarks
//! and forgets the decisions (the bookmarks stay saved, as in Swift).

use std::collections::{BTreeMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Mutex, OnceLock};
use std::time::Instant;

use base64::Engine;
use chau7_next_core::data_root::DataRoot;
use chau7_next_core::permission_center::{
    ProtectedEvidence, ProtectedSnapshot, ProtectedState, protected_snapshot,
};
use chau7_next_core::protected_path::{AccessPolicy, protected_root_for, protected_roots};

use crate::platform::{PlatformError, bookmarks};

/// `Settings > allowProtectedFolderAccess`, kept current by the settings.
static ALLOW: AtomicBool = AtomicBool::new(true);

/// Where the bookmarks are saved (set by [`init`]).
static BOOKMARKS_FILE: OnceLock<PathBuf> = OnceLock::new();
static HOME_DIR: OnceLock<PathBuf> = OnceLock::new();

/// Saved bookmarks by protected root, and the roots started this launch.
#[derive(Default)]
struct Bookmarks {
    by_root: BTreeMap<String, Vec<u8>>,
    started: HashSet<String>,
    stale: HashSet<String>,
}

fn bookmarks_state() -> &'static Mutex<Bookmarks> {
    static STATE: OnceLock<Mutex<Bookmarks>> = OnceLock::new();
    STATE.get_or_init(Default::default)
}

fn policy() -> &'static Mutex<AccessPolicy> {
    static POLICY: OnceLock<Mutex<AccessPolicy>> = OnceLock::new();
    POLICY.get_or_init(|| Mutex::new(AccessPolicy::default()))
}

fn clock() -> f64 {
    static START: OnceLock<Instant> = OnceLock::new();
    START.get_or_init(Instant::now).elapsed().as_secs_f64()
}

fn home() -> String {
    HOME_DIR
        .get()
        .cloned()
        .unwrap_or_else(|| DataRoot::from_env().home().to_path_buf())
        .to_string_lossy()
        .into_owned()
}

/// Load the saved bookmarks and start them in the background
/// (`activatePersistedBookmarks`), so repo detection in a granted folder
/// works on the first check.
pub fn init(root: &DataRoot) {
    let _ = HOME_DIR.set(root.home().to_path_buf());
    let file = root.protected_folder_bookmarks_file();
    let saved = load(&file);
    let _ = BOOKMARKS_FILE.set(file);
    if saved.is_empty() {
        return;
    }
    bookmarks_state()
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .by_root = saved;
    std::thread::spawn(|| {
        let roots: Vec<String> = bookmarks_state()
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .by_root
            .keys()
            .cloned()
            .collect();
        for root in roots {
            if start_bookmark(&root, "launch") {
                log::info!("ProtectedPathPolicy: pre-activated bookmark for {root}");
                policy()
                    .lock()
                    .unwrap_or_else(|e| e.into_inner())
                    .grant(&root);
            }
        }
    });
}

/// `{root: base64 bookmark}`.
fn load(file: &Path) -> BTreeMap<String, Vec<u8>> {
    let Ok(text) = std::fs::read_to_string(file) else {
        return BTreeMap::new();
    };
    let Ok(map) = serde_json::from_str::<BTreeMap<String, String>>(&text) else {
        log::warn!("protected folders: unreadable {}", file.display());
        return BTreeMap::new();
    };
    map.into_iter()
        .filter_map(|(root, data)| {
            let bytes = base64::engine::general_purpose::STANDARD
                .decode(data)
                .ok()?;
            Some((root, bytes))
        })
        .collect()
}

fn save(by_root: &BTreeMap<String, Vec<u8>>) {
    let Some(file) = BOOKMARKS_FILE.get() else {
        return;
    };
    let map: BTreeMap<&String, String> = by_root
        .iter()
        .map(|(root, data)| (root, base64::engine::general_purpose::STANDARD.encode(data)))
        .collect();
    let result = serde_json::to_string_pretty(&map)
        .map_err(std::io::Error::other)
        .and_then(|text| std::fs::write(file, text));
    if let Err(err) = result {
        log::warn!("protected folders: cannot save bookmarks: {err}");
    }
}

/// Start the saved bookmark of `root` (`startAccessingBookmark`). A bookmark
/// that no longer resolves is removed; a stale one is saved again.
fn start_bookmark(root: &str, source: &str) -> bool {
    let mut state = bookmarks_state().lock().unwrap_or_else(|e| e.into_inner());
    if state.started.contains(root) {
        return true;
    }
    let Some(data) = state.by_root.get(root).cloned() else {
        return false;
    };
    match bookmarks::start(&data) {
        Ok(started) => {
            if let Some(refreshed) = started.refreshed {
                state.by_root.insert(root.to_string(), refreshed);
                save(&state.by_root);
                log::info!("ProtectedPathPolicy: refreshed stale bookmark for {root}");
            }
            state.started.insert(root.to_string());
            state.stale.remove(root);
            true
        }
        Err(PlatformError::Failed(message)) if message.starts_with("resolve bookmark") => {
            state.by_root.remove(root);
            state.stale.insert(root.to_string());
            save(&state.by_root);
            log::warn!("ProtectedPathPolicy: failed to resolve bookmark for {root}, removed");
            false
        }
        Err(err) => {
            log::warn!("ProtectedPathPolicy: {err} for {root} (source={source})");
            false
        }
    }
}

/// Called when the settings change.
pub fn set_allowed(allowed: bool) {
    ALLOW.store(allowed, Ordering::Relaxed);
}

/// Snapshot only known state; never probe a protected folder from a settings render.
pub fn snapshot(path: &Path, known_repo_roots: &[String]) -> ProtectedSnapshot {
    let root = path
        .to_str()
        .and_then(|path| protected_root_for(path, &home()));
    let Some(root) = root else {
        return protected_snapshot(None, ProtectedEvidence::default());
    };
    let (active_scope, bookmark, stale) = {
        let state = bookmarks_state().lock().unwrap_or_else(|e| e.into_inner());
        (
            state.started.contains(&root),
            state.by_root.contains_key(&root),
            state.stale.contains(&root),
        )
    };
    let denied_by_cooldown = policy()
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .denied_by_cooldown(&root, clock());
    let root_path = Path::new(&root);
    let known_identity = known_repo_roots
        .iter()
        .any(|path| Path::new(path).starts_with(root_path));
    protected_snapshot(
        Some(root.into()),
        ProtectedEvidence {
            feature_enabled: ALLOW.load(Ordering::Relaxed),
            active_scope,
            bookmark,
            denied_by_cooldown,
            known_identity,
            bookmark_resolve_failed: stale,
        },
    )
}
pub fn snapshots_with_known_roots(known_repo_roots: &[String]) -> Vec<ProtectedSnapshot> {
    if !cfg!(target_os = "macos") {
        return Vec::new();
    }
    protected_roots(&home())
        .iter()
        .map(|root| snapshot(Path::new(root), known_repo_roots))
        .collect()
}

/// Current Swift policy: a saved bookmark may be activated; a missing grant is
/// never probed automatically. Active scopes remain available if the toggle is off.
pub fn should_skip(path: &Path) -> bool {
    if !cfg!(target_os = "macos") {
        return false;
    }
    let initial = snapshot(path, &[]);
    if initial.state != ProtectedState::AvailableBookmarkedScope {
        return !initial.can_probe_live;
    }
    let Some(root) = initial
        .root
        .and_then(|path| path.into_os_string().into_string().ok())
    else {
        return true;
    };
    if start_bookmark(&root, "auto") {
        policy()
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .grant(&root);
    } else {
        policy()
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .mark_denied(&root, clock());
    }
    !snapshot(path, &[]).can_probe_live
}

/// The user picked these folders in the grant dialog: each one under a
/// protected root is kept as a security-scoped bookmark and used from now
/// on. Without bookmark support the folder is read once (the system prompt
/// appears) instead. Returns the roots that were granted.
pub fn grant(paths: &[PathBuf]) -> Vec<String> {
    let mut granted = Vec::new();
    for path in paths {
        let Some(root) = path
            .to_str()
            .and_then(|text| protected_root_for(text, &home()))
        else {
            log::info!(
                "protected folders: ignored non-protected selection {}",
                path.display()
            );
            continue;
        };
        let ok = match bookmarks::create(path) {
            Ok(data) => {
                {
                    let mut state = bookmarks_state().lock().unwrap_or_else(|e| e.into_inner());
                    state.by_root.insert(root.clone(), data);
                    state.started.remove(&root);
                    state.stale.remove(&root);
                    save(&state.by_root);
                }
                start_bookmark(&root, "grant")
            }
            Err(PlatformError::Unsupported(_)) => std::fs::read_dir(&root).is_ok(),
            Err(err) => {
                log::warn!("ProtectedPathPolicy: failed to create bookmark for {root}: {err}");
                false
            }
        };
        if ok {
            policy()
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .grant(&root);
            granted.push(root);
        } else {
            log::warn!("protected folders: access to {root} was refused");
        }
    }
    granted
}

/// Forget every decision and stop the bookmarks in use (`resetAccessChecks`).
pub fn reset() {
    bookmarks::stop_all();
    {
        let mut state = bookmarks_state().lock().unwrap_or_else(|e| e.into_inner());
        state.started.clear();
        state.stale.clear();
    }
    policy().lock().unwrap_or_else(|e| e.into_inner()).reset();
}
