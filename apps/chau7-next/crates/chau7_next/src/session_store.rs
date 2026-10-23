//! Window and tab restore across launches (`session.json` in the Chau7 Next
//! state folder; the Swift app keeps its own in UserDefaults).
//!
//! Full restore bundle commits precede the lightweight index. Tokens prove
//! freshness, and immutable sidecars carry byte counts and SHA256 checksums.
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
use chau7_next_core::session_restore::transaction::{ContextRef, SourceDecision, source_decision};
use chau7_next_core::session_restore::{
    MAX_SCROLLBACK_BYTES, build_ai_resume_command, resolve_resume_metadata_from_saved,
};
#[cfg(test)]
use chau7_next_core::{session_restore::SavedSplitNode, token_optimization::TabTokenOptOverride};
use serde::{Deserialize, Serialize};

pub use chau7_next_core::session_restore::models::{
    SavedPane, SavedSession, SavedTab, SavedWindow,
};

/// Archive at most every five minutes, with current Swift count/byte bounds.
const ARCHIVE_INTERVAL: Duration = Duration::from_secs(300);
const ARCHIVE_KEEP: usize = 120;
const ARCHIVE_MAX_AGE: Duration = Duration::from_secs(30 * 24 * 60 * 60);
const MAX_MANIFEST_BYTES: u64 = 16 * 1024 * 1024;
const MAX_ARCHIVE_BYTES: u64 = 128 * 1024 * 1024;
static LAST_ARCHIVE: Mutex<Option<(PathBuf, u64, SystemTime)>> = Mutex::new(None);
static IMPORTED_ROOTS: Mutex<Option<std::collections::HashSet<PathBuf>>> = Mutex::new(None);
/// Serializes every writer of the restore files (the restore writer thread,
/// Reset Window Positions, the restore-source archive): a transaction writes
/// its context sidecars before the bundle that references them, so a
/// concurrent `prune_contexts` would otherwise delete them in between.
static STORE_LOCK: Mutex<()> = Mutex::new(());
fn store_lock() -> std::sync::MutexGuard<'static, ()> {
    STORE_LOCK.lock().unwrap_or_else(|e| e.into_inner())
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct RestoreIndex {
    #[serde(default)]
    save_token: Option<String>,
    #[serde(default)]
    explicit_clear: bool,
    #[serde(flatten)]
    session: SavedSession,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct RestoreBundle {
    schema_version: u32,
    save_token: String,
    previous_index_token: Option<String>,
    explicit_clear: bool,
    session: SavedSession,
    contexts: std::collections::BTreeMap<u64, ContextRef>,
}

fn bundle_file(root: &DataRoot) -> PathBuf {
    root.state_dir().join("TabRestoreBundles/current.json")
}
fn contexts_dir(root: &DataRoot) -> PathBuf {
    root.state_dir().join("TabRestoreBundles/contexts")
}

fn read_bounded(path: &Path, maximum: u64) -> std::io::Result<Vec<u8>> {
    use std::io::Read;
    let file = std::fs::File::open(path)?;
    if file.metadata()?.len() > maximum {
        return Err(std::io::Error::other("restore file exceeds byte bound"));
    }
    let mut bytes = Vec::new();
    file.take(maximum + 1).read_to_end(&mut bytes)?;
    if bytes.len() as u64 > maximum {
        return Err(std::io::Error::other("restore file exceeds byte bound"));
    }
    Ok(bytes)
}
fn parse_index(path: &Path) -> Option<RestoreIndex> {
    serde_json::from_slice(&read_bounded(path, MAX_MANIFEST_BYTES).ok()?).ok()
}
fn parse_bundle(path: &Path) -> Option<RestoreBundle> {
    let bundle: RestoreBundle =
        serde_json::from_slice(&read_bounded(path, MAX_MANIFEST_BYTES).ok()?).ok()?;
    (bundle.schema_version == 1
        && (bundle.explicit_clear || bundle.session.windows.iter().any(|w| !w.tabs.is_empty())))
    .then_some(bundle)
}

// Temp files are exclusive and private; both content and parent directory
// are flushed before publishing the next transaction marker.
pub(crate) use chau7_next_core::atomic_file::write as atomic_write;

fn decoded_contexts(root: &DataRoot, bundle: &RestoreBundle) -> Option<Vec<(u64, Vec<u8>)>> {
    let mut decoded = Vec::new();
    for pane in bundle
        .session
        .windows
        .iter()
        .flat_map(|w| &w.tabs)
        .flat_map(|t| &t.panes)
        .filter(|p| p.scrollback)
    {
        let reference = bundle.contexts.get(&pane.id)?;
        if !reference.valid_name() || reference.byte_count > MAX_SCROLLBACK_BYTES {
            return None;
        }
        let bytes = read_bounded(
            &contexts_dir(root).join(format!("{}.txt", reference.sha256)),
            MAX_SCROLLBACK_BYTES as u64,
        )
        .ok()?;
        if !reference.verifies(&bytes) || std::str::from_utf8(&bytes).is_err() {
            return None;
        }
        decoded.push((pane.id, bytes));
    }
    Some(decoded)
}

fn hydrate_bundle(root: &DataRoot, bundle: &RestoreBundle) -> Option<SavedSession> {
    // Validate every sidecar before changing even one canonical scrollback.
    let decoded = decoded_contexts(root, bundle)?;
    for (pane, bytes) in decoded {
        atomic_write(&root.scrollback_dir().join(format!("{pane}.txt")), &bytes).ok()?;
    }
    Some(sanitize_session(bundle.session.clone()))
}

/// First occurrence wins across all windows; selection follows its identity.
/// A provider/session pair belongs to one saved pane, never a sibling tab.
fn sanitize_session(mut session: SavedSession) -> SavedSession {
    let mut tab_ids = std::collections::HashSet::new();
    let mut ai_ids = std::collections::HashSet::new();
    for window in &mut session.windows {
        let selected_uuid = window.tabs.get(window.selected).and_then(|t| t.uuid);
        let former_selected = window.selected;
        window.tabs.retain_mut(|tab| {
            if tab.uuid.is_some_and(|id| !tab_ids.insert(id)) {
                return false;
            }
            for pane in &mut tab.panes {
                if let Some(meta) = resolve_resume_metadata_from_saved(
                    pane.ai_provider.as_deref(),
                    pane.ai_session_id.as_deref(),
                    pane.ai_resume_command.as_deref(),
                ) && !ai_ids.insert((meta.provider.clone(), meta.session_id.clone()))
                {
                    pane.ai_provider = None;
                    pane.ai_session_id = None;
                    pane.ai_resume_command = None;
                }
            }
            true
        });
        window.selected = selected_uuid
            .and_then(|id| window.tabs.iter().position(|t| t.uuid == Some(id)))
            .unwrap_or(former_selected.min(window.tabs.len().saturating_sub(1)));
    }
    session.windows.retain(|w| !w.tabs.is_empty());
    session
}

/// Recovery fills missing AI fields for the same stable tab and pane only.
/// Integrity-checked bundles preserve an intentionally plain shell identity.
fn recover_resume_metadata(
    base: &mut SavedSession,
    candidates: &[SavedSession],
    recover_empty: bool,
) {
    for tab in base.windows.iter_mut().flat_map(|w| &mut w.tabs) {
        let Some(id) = tab.uuid else {
            continue;
        };
        if recover_empty
            && tab.panes.is_empty()
            && let Some(fallback) = candidates
                .iter()
                .flat_map(|c| &c.windows)
                .flat_map(|w| &w.tabs)
                .find(|candidate| {
                    candidate.uuid == Some(id)
                        && candidate.cwd == tab.cwd
                        && !candidate.panes.is_empty()
                })
        {
            tab.panes = fallback.panes.clone();
            if tab.layout.is_none() {
                tab.layout = fallback.layout.clone();
                tab.focused_pane = fallback.focused_pane;
            }
        }
        for pane in &mut tab.panes {
            if resolve_resume_metadata_from_saved(
                pane.ai_provider.as_deref(),
                pane.ai_session_id.as_deref(),
                pane.ai_resume_command.as_deref(),
            )
            .is_some()
            {
                continue;
            }
            if !recover_empty
                && pane.ai_provider.is_none()
                && pane.ai_session_id.is_none()
                && pane.ai_resume_command.is_none()
            {
                continue;
            }
            for candidate in candidates {
                let fallback = candidate
                    .windows
                    .iter()
                    .flat_map(|w| &w.tabs)
                    .find(|t| t.uuid == Some(id))
                    .and_then(|t| t.panes.iter().find(|p| p.id == pane.id));
                let Some(fallback) = fallback else {
                    continue;
                };
                // A reused tab/pane in another directory is not an identity match.
                if pane.directory != fallback.directory {
                    continue;
                }
                let Some(meta) = resolve_resume_metadata_from_saved(
                    fallback.ai_provider.as_deref(),
                    fallback.ai_session_id.as_deref(),
                    fallback.ai_resume_command.as_deref(),
                ) else {
                    continue;
                };
                if pane
                    .ai_provider
                    .as_deref()
                    .and_then(chau7_next_core::ai::resume::normalize_provider_name)
                    .is_some_and(|p| p != meta.provider)
                {
                    continue;
                }
                pane.ai_resume_command =
                    build_ai_resume_command(Some(&meta.provider), Some(&meta.session_id));
                pane.ai_provider = Some(meta.provider);
                pane.ai_session_id = Some(meta.session_id);
                break;
            }
        }
    }
}

fn needs_resume_recovery(session: &SavedSession, recover_empty: bool) -> bool {
    session.windows.iter().flat_map(|w| &w.tabs).any(|tab| {
        tab.uuid.is_some()
            && ((recover_empty && tab.panes.is_empty())
                || tab.panes.iter().any(|p| {
                    (recover_empty
                        || p.ai_provider.is_some()
                        || p.ai_session_id.is_some()
                        || p.ai_resume_command.is_some())
                        && resolve_resume_metadata_from_saved(
                            p.ai_provider.as_deref(),
                            p.ai_session_id.as_deref(),
                            p.ai_resume_command.as_deref(),
                        )
                        .is_none()
                }))
    })
}

fn recover_from_backups(
    root: &DataRoot,
    session: &mut SavedSession,
    paths: &[PathBuf],
    recover_empty: bool,
) {
    for path in paths {
        if !needs_resume_recovery(session, recover_empty) {
            break;
        }
        let bundle = parse_bundle(path);
        let candidate = bundle
            .as_ref()
            .map(|b| b.session.clone())
            .or_else(|| parse_index(path).map(|i| i.session));
        let Some(candidate) = candidate else {
            continue;
        };
        // Recover full pane payload only for legacy tabs that lost that payload.
        // Validate the selected candidate before publishing its missing history.
        let missing: std::collections::HashSet<_> = session
            .windows
            .iter()
            .flat_map(|w| &w.tabs)
            .filter(|t| recover_empty && t.panes.is_empty())
            .filter_map(|t| t.uuid)
            .collect();
        let decoded = if !missing.is_empty() {
            if let Some(bundle) = &bundle {
                let Some(decoded) = decoded_contexts(root, bundle) else {
                    continue;
                };
                decoded
            } else {
                Vec::new()
            }
        } else {
            Vec::new()
        };
        recover_resume_metadata(session, std::slice::from_ref(&candidate), recover_empty);
        let recovered: std::collections::HashSet<_> = session
            .windows
            .iter()
            .flat_map(|w| &w.tabs)
            .filter(|t| t.uuid.is_some_and(|id| missing.contains(&id)))
            .flat_map(|t| t.panes.iter().filter(|p| p.scrollback).map(|p| p.id))
            .collect();
        for (pane, bytes) in decoded {
            if recovered.contains(&pane)
                && let Err(error) =
                    atomic_write(&root.scrollback_dir().join(format!("{pane}.txt")), &bytes)
            {
                log::warn!("restore missing pane context {pane}: {error}");
            }
        }
    }
}

fn remember_restore_source(root: &DataRoot, session: &SavedSession) {
    if session.windows.is_empty() {
        return;
    }
    let mut imported = IMPORTED_ROOTS.lock().unwrap_or_else(|e| e.into_inner());
    if !imported
        .get_or_insert_with(Default::default)
        .insert(root.state_dir().to_owned())
    {
        return;
    }
    drop(imported);
    let result = (|| {
        let _store = store_lock();
        let mut contexts = std::collections::BTreeMap::new();
        for pane in session
            .windows
            .iter()
            .flat_map(|w| &w.tabs)
            .flat_map(|t| &t.panes)
            .filter(|p| p.scrollback)
        {
            let bytes = read_bounded(
                &root.scrollback_dir().join(format!("{}.txt", pane.id)),
                MAX_SCROLLBACK_BYTES as u64,
            )?;
            let reference = ContextRef::new(&bytes);
            let path = contexts_dir(root).join(format!("{}.txt", reference.sha256));
            if !read_bounded(&path, MAX_SCROLLBACK_BYTES as u64)
                .is_ok_and(|existing| reference.verifies(&existing))
            {
                atomic_write(&path, &bytes)?;
            }
            contexts.insert(pane.id, reference);
        }
        let bundle = RestoreBundle {
            schema_version: 1,
            save_token: uuid::Uuid::new_v4().to_string(),
            previous_index_token: None,
            explicit_clear: false,
            session: session.clone(),
            contexts,
        };
        write_backups(root, &bundle, Some("restoreSource"))
    })();
    if let Err(error) = result {
        log::warn!("archive imported restore source: {error}");
    }
}

/// Legacy single-window indexes may omit additional windows. Match the backup
/// primary by stable-ID overlap, then claim remaining tabs globally at hydration.
/// Fresh token-stamped indexes do not resurrect windows explicitly closed since.
fn recover_legacy_windows(root: &DataRoot, session: &mut SavedSession, paths: &[PathBuf]) {
    if session.windows.len() != 1 {
        return;
    }
    let claimed: std::collections::HashSet<_> = session.windows[0]
        .tabs
        .iter()
        .filter_map(|t| t.uuid)
        .collect();
    for path in paths {
        let bundle = parse_bundle(path);
        let candidate = bundle
            .as_ref()
            .map(|b| b.session.clone())
            .or_else(|| parse_index(path).map(|i| i.session));
        let Some(candidate) = candidate.filter(|c| c.windows.len() > 1) else {
            continue;
        };
        let best = candidate
            .windows
            .iter()
            .enumerate()
            .map(|(position, w)| {
                (
                    position,
                    w.tabs
                        .iter()
                        .filter_map(|t| t.uuid)
                        .filter(|id| claimed.contains(id))
                        .count(),
                )
            })
            .filter(|(_, score)| *score > 0)
            .max_by_key(|(position, score)| (*score, std::cmp::Reverse(*position)))
            .map(|(position, _)| position);
        // An unrelated archive is not evidence that this legacy primary lost
        // additional windows. Keep looking for a shared stable tab identity.
        let Some(best) = best else { continue };
        let decoded = if let Some(bundle) = &bundle {
            let Some(decoded) = decoded_contexts(root, bundle) else {
                continue;
            };
            decoded
        } else {
            Vec::new()
        };
        let additional: Vec<_> = candidate
            .windows
            .into_iter()
            .enumerate()
            .filter_map(|(position, w)| (position != best).then_some(w))
            .collect();
        let panes: std::collections::HashSet<_> = additional
            .iter()
            .flat_map(|w| &w.tabs)
            .flat_map(|t| &t.panes)
            .filter(|p| p.scrollback)
            .map(|p| p.id)
            .collect();
        for (pane, bytes) in decoded {
            if panes.contains(&pane)
                && let Err(error) =
                    atomic_write(&root.scrollback_dir().join(format!("{pane}.txt")), &bytes)
            {
                log::warn!("recover additional window context {pane}: {error}");
            }
        }
        session.windows.extend(additional);
        return;
    }
}

/// Primary restore identities used by owned shell-history maintenance. No
/// archive hydration or provider lookup is necessary for this read-only query.
pub(crate) fn restorable_tab_ids(root: &DataRoot) -> std::collections::HashSet<uuid::Uuid> {
    let mut ids = std::collections::HashSet::new();
    let mut collect = |session: SavedSession| {
        ids.extend(
            session
                .windows
                .into_iter()
                .flat_map(|window| window.tabs)
                .filter_map(|tab| tab.uuid),
        );
    };
    if let Some(index) = parse_index(&root.session_file()) {
        collect(index.session);
    } else if let Ok(bytes) = read_bounded(&root.session_file(), MAX_MANIFEST_BYTES) {
        // Historical single-window primary manifests have no top-level
        // windows. Only UUIDs are needed; never hydrate terminal sidecars.
        #[derive(Deserialize)]
        struct IdentityTab {
            #[serde(default)]
            uuid: Option<uuid::Uuid>,
        }
        #[derive(Deserialize)]
        struct IdentityWindow {
            tabs: Vec<IdentityTab>,
        }
        if let Ok(window) = serde_json::from_slice::<IdentityWindow>(&bytes) {
            collect(SavedSession {
                version: 1,
                windows: vec![SavedWindow {
                    tabs: window
                        .tabs
                        .into_iter()
                        .map(|tab| SavedTab {
                            uuid: tab.uuid,
                            ..Default::default()
                        })
                        .collect(),
                    ..Default::default()
                }],
            });
        }
    }
    if let Some(bundle) = parse_bundle(&bundle_file(root)) {
        collect(bundle.session);
    }
    ids
}

pub fn load(root: &DataRoot) -> Option<SavedSession> {
    let index = parse_index(&root.session_file());
    let bundle = parse_bundle(&bundle_file(root));
    let prefer_bundle = bundle.as_ref().is_some_and(|b| {
        source_decision(
            Some(&b.save_token),
            b.previous_index_token.as_deref(),
            index.as_ref().and_then(|i| i.save_token.as_deref()),
        ) != SourceDecision::IndexCurrent
    });
    let paths: Vec<PathBuf> = std::iter::once(root.tab_state_backups_dir().join("latest.json"))
        .chain(archive_files(&root.tab_state_backups_dir().join("archive")))
        .collect();
    if prefer_bundle
        && let Some(b) = &bundle
        && let Some(mut session) = hydrate_bundle(root, b)
    {
        if !b.explicit_clear {
            recover_from_backups(root, &mut session, &paths, false);
        }
        let session = sanitize_session(session);
        remember_restore_source(root, &session);
        return Some(session);
    }
    let mut legacy_empty = None;
    if let Some(index) = index {
        if index.explicit_clear {
            return Some(index.session);
        }
        if index.session.windows.iter().any(|w| !w.tabs.is_empty()) {
            let mut session = index.session;
            recover_from_backups(root, &mut session, &paths, true);
            if index.save_token.is_none() {
                recover_legacy_windows(root, &mut session, &paths);
            }
            let session = sanitize_session(session);
            remember_restore_source(root, &session);
            return Some(session);
        }
        if index.save_token.is_none() {
            legacy_empty = Some(index.session);
        }
    }
    for (position, path) in paths.iter().enumerate() {
        if let Some(b) = parse_bundle(path) {
            if let Some(mut session) = hydrate_bundle(root, &b) {
                if !b.explicit_clear {
                    recover_from_backups(root, &mut session, &paths[position + 1..], true);
                }
                let session = sanitize_session(session);
                remember_restore_source(root, &session);
                return Some(session);
            }
        } else if let Some(index) = parse_index(path)
            && (index.explicit_clear || !index.session.windows.is_empty())
        {
            return Some(sanitize_session(index.session));
        }
    }
    legacy_empty
}

pub fn save(root: &DataRoot, session: &SavedSession) -> std::io::Result<()> {
    save_for(root, session, false)
}
/// Measurements of the successfully committed current bundle, index and unique contexts.
/// Values contain sizes/counts only; no terminal content, paths or commands.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SaveMeasurements {
    pub bytes: u64,
    pub metadata: std::collections::BTreeMap<String, String>,
}

pub fn save_for(root: &DataRoot, session: &SavedSession, terminating: bool) -> std::io::Result<()> {
    save_for_measured(root, session, terminating).map(|_| ())
}

pub fn save_for_measured(
    root: &DataRoot,
    session: &SavedSession,
    terminating: bool,
) -> std::io::Result<SaveMeasurements> {
    save_transaction(root, session, terminating, false)
}

fn measurements(
    bundle: &RestoreBundle,
    manifest_bytes: usize,
    index_bytes: usize,
) -> std::io::Result<SaveMeasurements> {
    let mut unique = std::collections::BTreeMap::new();
    for context in bundle.contexts.values() {
        unique.insert(&context.sha256, context.byte_count as u64);
    }
    let context_bytes = unique.values().copied().sum::<u64>();
    let mut tab_count = 0;
    let mut pane_count = 0;
    let mut largest_tab = 0;
    let mut largest_pane = 0;
    for tab in bundle.session.windows.iter().flat_map(|w| &w.tabs) {
        tab_count += 1;
        let mut tab_contexts = std::collections::BTreeMap::new();
        for pane in &tab.panes {
            pane_count += 1;
            let context_bytes = bundle.contexts.get(&pane.id).map_or(0, |r| {
                tab_contexts.insert(&r.sha256, r.byte_count as u64);
                r.byte_count as u64
            });
            let metadata_bytes = serde_json::to_vec(pane)
                .map_err(std::io::Error::other)?
                .len() as u64;
            largest_pane = largest_pane.max(metadata_bytes + context_bytes);
        }
        let metadata_bytes = serde_json::to_vec(tab)
            .map_err(std::io::Error::other)?
            .len() as u64;
        largest_tab = largest_tab.max(metadata_bytes + tab_contexts.values().copied().sum::<u64>());
    }
    let metadata = [
        ("windowCount", bundle.session.windows.len() as u64),
        ("tabCount", tab_count),
        ("paneCount", pane_count),
        ("manifestBytes", manifest_bytes as u64),
        ("indexBytes", index_bytes as u64),
        ("uniqueContextBytes", context_bytes),
        ("largestTabPayloadBytes", largest_tab),
        ("largestPanePayloadBytes", largest_pane),
    ]
    .into_iter()
    .map(|(key, value)| (key.to_string(), value.to_string()))
    .collect();
    Ok(SaveMeasurements {
        bytes: manifest_bytes as u64 + index_bytes as u64 + context_bytes,
        metadata,
    })
}

fn save_transaction(
    root: &DataRoot,
    session: &SavedSession,
    terminating: bool,
    explicit_clear: bool,
) -> std::io::Result<SaveMeasurements> {
    let _store = store_lock();
    root.ensure_dirs()?;
    let session = sanitize_session(session.clone());
    if !explicit_clear && session.windows.is_empty() {
        return Err(std::io::Error::other(
            "refusing implicit empty restore overwrite",
        ));
    }
    let previous_index_token = parse_index(&root.session_file()).and_then(|i| i.save_token);
    let mut contexts = std::collections::BTreeMap::new();
    for pane in session
        .windows
        .iter()
        .flat_map(|w| &w.tabs)
        .flat_map(|t| &t.panes)
        .filter(|p| p.scrollback)
    {
        let bytes = read_bounded(
            &root.scrollback_dir().join(format!("{}.txt", pane.id)),
            MAX_SCROLLBACK_BYTES as u64,
        )?;
        let reference = ContextRef::new(&bytes);
        let path = contexts_dir(root).join(format!("{}.txt", reference.sha256));
        if !read_bounded(&path, MAX_SCROLLBACK_BYTES as u64)
            .is_ok_and(|existing| reference.verifies(&existing))
        {
            atomic_write(&path, &bytes)?;
        }
        contexts.insert(pane.id, reference);
    }
    let save_token = uuid::Uuid::new_v4().to_string();
    let bundle = RestoreBundle {
        schema_version: 1,
        save_token: save_token.clone(),
        previous_index_token,
        explicit_clear,
        session: session.clone(),
        contexts,
    };
    let text = serde_json::to_vec_pretty(&bundle).map_err(std::io::Error::other)?;
    if text.len() as u64 > MAX_MANIFEST_BYTES {
        return Err(std::io::Error::other("restore manifest exceeds byte bound"));
    }
    // The complete durable bundle must precede the lightweight index. A crash
    // between commits leaves a provably newer bundle through its parent token.
    atomic_write(&bundle_file(root), &text)?;
    let index = RestoreIndex {
        save_token: Some(save_token),
        explicit_clear,
        session,
    };
    let index_text = serde_json::to_vec_pretty(&index).map_err(std::io::Error::other)?;
    let measurements = measurements(&bundle, text.len(), index_text.len())?;
    atomic_write(&root.session_file(), &index_text)?;
    crate::incidents::restore_payload(measurements.bytes, measurements.metadata.clone());
    if let Err(err) = write_backups(root, &bundle, terminating.then_some("termination")) {
        log::warn!("tab state backup: {err}");
    }
    Ok(measurements)
}

fn archive_files(dir: &Path) -> Vec<PathBuf> {
    let mut files: Vec<_> = std::fs::read_dir(dir)
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
fn fingerprint(bytes: &[u8]) -> u64 {
    use std::hash::{Hash, Hasher};
    let mut hasher = std::collections::hash_map::DefaultHasher::new();
    bytes.hash(&mut hasher);
    hasher.finish()
}
fn write_backups(
    root: &DataRoot,
    bundle: &RestoreBundle,
    forced: Option<&str>,
) -> std::io::Result<()> {
    let dir = root.tab_state_backups_dir();
    let archive = dir.join("archive");
    let text = serde_json::to_vec_pretty(bundle).map_err(std::io::Error::other)?;
    atomic_write(&dir.join("latest.json"), &text)?;
    let mut content = bundle.clone();
    content.save_token.clear();
    content.previous_index_token = None;
    let print = fingerprint(&serde_json::to_vec(&content).map_err(std::io::Error::other)?);
    let now = SystemTime::now();
    let mut last = LAST_ARCHIVE.lock().unwrap_or_else(|e| e.into_inner());
    let due = forced.is_some()
        || last.as_ref().is_none_or(|(previous_root, previous, at)| {
            previous_root != root.state_dir()
                || (*previous != print
                    && now.duration_since(*at).unwrap_or_default() >= ARCHIVE_INTERVAL)
        });
    if due {
        let millis = now
            .duration_since(SystemTime::UNIX_EPOCH)
            .unwrap_or_default()
            .as_millis();
        atomic_write(
            &archive.join(format!(
                "{millis:013}-{}-{}.json",
                forced.unwrap_or("periodic"),
                uuid::Uuid::new_v4()
            )),
            &text,
        )?;
        *last = Some((root.state_dir().to_owned(), print, now));
    }
    prune_archive(&archive, now);
    prune_contexts(root);
    sweep_temps(root);
    Ok(())
}
/// Remove temporary files that crashed writes left in the restore folders.
fn sweep_temps(root: &DataRoot) {
    let backups = root.tab_state_backups_dir();
    for dir in [
        root.state_dir().to_path_buf(),
        bundle_file(root)
            .parent()
            .map(Path::to_path_buf)
            .unwrap_or_default(),
        contexts_dir(root),
        backups.join("archive"),
        backups,
        root.scrollback_dir(),
    ] {
        chau7_next_core::atomic_file::sweep_stale_temps(
            &dir,
            chau7_next_core::atomic_file::STALE_TEMP_AGE,
        );
    }
}
fn prune_archive(dir: &Path, now: SystemTime) {
    let mut total = 0_u64;
    for (index, path) in archive_files(dir).into_iter().enumerate() {
        let Ok(meta) = std::fs::metadata(&path) else {
            continue;
        };
        let old = meta
            .modified()
            .is_ok_and(|at| now.duration_since(at).unwrap_or_default() > ARCHIVE_MAX_AGE);
        let effective_bytes = parse_bundle(&path)
            .map(|b| {
                b.contexts
                    .values()
                    .fold(meta.len(), |n, r| n.saturating_add(r.byte_count as u64))
            })
            .unwrap_or(meta.len());
        // The newest archive is the last resort of restore: always kept.
        // The per-file bound is Swift's `maximumArchiveFileBytes` and applies
        // to the manifest; its scrollback sidecars only count toward the
        // folder's total, or a large scrollback would delete every archive.
        if index > 0
            && (index >= ARCHIVE_KEEP
                || old
                || meta.len() > MAX_MANIFEST_BYTES
                || total.saturating_add(effective_bytes) > MAX_ARCHIVE_BYTES)
        {
            let _ = std::fs::remove_file(path);
        } else {
            total += effective_bytes;
        }
    }
}
fn prune_contexts(root: &DataRoot) {
    let paths = std::iter::once(bundle_file(root))
        .chain(std::iter::once(
            root.tab_state_backups_dir().join("latest.json"),
        ))
        .chain(archive_files(&root.tab_state_backups_dir().join("archive")));
    let mut keep = std::collections::HashSet::new();
    for path in paths {
        // On unreadable manifests retain sidecars rather than destroy recovery.
        let Some(bundle) = parse_bundle(&path) else {
            if path.exists() {
                return;
            } else {
                continue;
            }
        };
        keep.extend(
            bundle
                .contexts
                .values()
                .map(|r| format!("{}.txt", r.sha256)),
        );
    }
    if let Ok(entries) = std::fs::read_dir(contexts_dir(root)) {
        for entry in entries.flatten() {
            if entry.path().extension().is_some_and(|x| x == "txt")
                && !keep.contains(&entry.file_name().to_string_lossy().to_string())
            {
                let _ = std::fs::remove_file(entry.path());
            }
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
    if session.windows.is_empty() {
        return Ok(());
    }
    for window in &mut session.windows {
        apply_position_reset(window);
    }
    save(root, &session)
}

/// Forget the saved windows (quit with no visible window). An empty session
/// is saved rather than the file removed, so restore does not fall back to a
/// backup of the windows that were closed.
pub fn clear(root: &DataRoot) -> std::io::Result<()> {
    save_transaction(root, &SavedSession::default(), true, true).map(|_| ())
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
                    layout: Some(SavedSplitNode::Split {
                        id: 1,
                        axis: chau7_next_core::session_restore::SavedAxis::Horizontal,
                        ratios: vec![0.5, 0.5],
                        children: vec![
                            SavedSplitNode::Terminal {
                                id: 7,
                                directory: Some("/tmp".into()),
                            },
                            SavedSplitNode::Terminal {
                                id: 8,
                                directory: Some("/tmp".into()),
                            },
                        ],
                    }),
                    focused_pane: Some(7),
                    archived_context: Some(
                        chau7_next_core::session_restore::models::ArchivedTabContext {
                            command_blocks: Some(vec![serde_json::json!({
                                "command": "printf inert",
                                "startLine": 1,
                            })]),
                            preview_snapshot_png_data: Some("AQID".into()),
                        },
                    ),
                    panes: vec![SavedPane {
                        id: 7,
                        directory: Some("/tmp".into()),
                        scrollback: true,
                        ai_provider: Some("claude".into()),
                        ai_session_id: Some("abc".into()),
                        ai_resume_command: Some("claude --resume abc".into()),
                        ..Default::default()
                    }, SavedPane {
                        id: 8,
                        archived_ai_resume: Some(
                            chau7_next_core::session_restore::models::ArchivedAIResumeMetadata {
                                provider: Some("codex".into()),
                                session_id: Some("synth:fixture".into()),
                                session_id_source: Some("synthetic".into()),
                                resume_command: None,
                            },
                        ),
                        ..Default::default()
                    }],
                }],
                selected: 0,
                x: 10.0,
                y: 20.0,
                width: 800.0,
                height: 600.0,
            }],
        };
        std::fs::create_dir_all(root.scrollback_dir()).unwrap();
        std::fs::write(root.scrollback_dir().join("7.txt"), "saved history").unwrap();
        save(&root, &session).unwrap();
        assert_eq!(load(&root), Some(session.clone()));
        let restored = load(&root).unwrap();
        let archived_only = restored.windows[0].tabs[0]
            .panes
            .iter()
            .find(|pane| pane.id == 8)
            .unwrap();
        let archived_identity = archived_only.archived_ai_resume.as_ref().unwrap();
        assert!(archived_only.ai_provider.is_none());
        assert!(archived_only.ai_session_id.is_none());
        assert!(archived_only.ai_resume_command.is_none());
        assert!(
            resolve_resume_metadata_from_saved(
                archived_only.ai_provider.as_deref(),
                archived_only.ai_session_id.as_deref(),
                archived_only.ai_resume_command.as_deref(),
            )
            .is_none()
        );
        assert!(
            build_ai_resume_command(
                archived_identity.provider.as_deref(),
                archived_identity.session_id.as_deref(),
            )
            .is_none()
        );
        let tab_context = restored.windows[0].tabs[0]
            .archived_context
            .as_ref()
            .unwrap();
        assert_eq!(
            tab_context.command_blocks.as_ref().unwrap()[0]["command"],
            "printf inert"
        );
        assert_eq!(
            tab_context.preview_snapshot_png_data.as_deref(),
            Some("AQID")
        );
        assert!(root.session_file().starts_with(&home));
        // A damaged session.json falls back to the backup.
        std::fs::write(root.session_file(), "{ not json").unwrap();
        assert_eq!(load(&root), Some(session.clone()));
        std::fs::remove_file(root.session_file()).unwrap();
        std::fs::remove_file(root.tab_state_backups_dir().join("latest.json")).unwrap();
        std::fs::remove_file(bundle_file(&root)).unwrap();
        // Then the newest archive copy, including immutable scrollback.
        assert_eq!(load(&root), Some(session));
        clear(&root).unwrap();
        assert_eq!(load(&root), Some(SavedSession::default()));
        clear(&root).unwrap();
        let _ = std::fs::remove_dir_all(&home);
    }

    fn isolated_root() -> DataRoot {
        DataRoot::with_home(
            std::env::temp_dir().join(format!("chau7-next-restore-{}", uuid::Uuid::new_v4())),
            true,
        )
    }
    fn one_tab(id: u128, title: &str) -> SavedSession {
        SavedSession {
            version: 1,
            windows: vec![SavedWindow {
                tabs: vec![SavedTab {
                    uuid: Some(uuid::Uuid::from_u128(id)),
                    custom_title: Some(title.into()),
                    ..Default::default()
                }],
                ..Default::default()
            }],
        }
    }
    #[test]
    fn history_protection_reads_only_primary_index_and_bundle_without_sidecars() {
        let root = isolated_root();
        save(&root, &one_tab(1, "archived")).unwrap();
        save_for(&root, &one_tab(2, "primary"), true).unwrap();
        // Older archive UUIDs are not permanently protected. Sidecars are
        // irrelevant to this bounded identity-only read.
        assert_eq!(
            restorable_tab_ids(&root),
            [uuid::Uuid::from_u128(2)].into_iter().collect()
        );
        std::fs::write(
            root.session_file(),
            serde_json::to_vec(&one_tab(3, "legacy-single-window")).unwrap(),
        )
        .unwrap();
        assert_eq!(
            restorable_tab_ids(&root),
            [uuid::Uuid::from_u128(2), uuid::Uuid::from_u128(3)]
                .into_iter()
                .collect()
        );
        std::fs::write(bundle_file(&root), "malformed").unwrap();
        assert_eq!(
            restorable_tab_ids(&root),
            [uuid::Uuid::from_u128(3)].into_iter().collect()
        );
        std::fs::write(
            root.session_file(),
            serde_json::to_vec(&one_tab(4, "legacy").windows[0]).unwrap(),
        )
        .unwrap();
        assert_eq!(
            restorable_tab_ids(&root),
            [uuid::Uuid::from_u128(4)].into_iter().collect()
        );
        std::fs::remove_dir_all(root.home()).unwrap();
    }
    #[test]
    fn interrupted_bundle_commit_recovers_newer_source_but_not_stale_bundle() {
        let root = isolated_root();
        let old = one_tab(1, "old");
        let new = one_tab(2, "new");
        save(&root, &old).unwrap();
        let index = std::fs::read(root.session_file()).unwrap();
        save(&root, &new).unwrap();
        std::fs::write(root.session_file(), &index).unwrap();
        assert_eq!(load(&root), Some(new));
        let mut stale = parse_bundle(&bundle_file(&root)).unwrap();
        stale.previous_index_token = Some("unrelated".into());
        atomic_write(&bundle_file(&root), &serde_json::to_vec(&stale).unwrap()).unwrap();
        assert_eq!(load(&root), Some(old));
        std::fs::remove_dir_all(root.home()).unwrap();
    }
    #[test]
    fn failed_full_context_write_keeps_previous_commit_and_implicit_empty_is_refused() {
        let root = isolated_root();
        let old = one_tab(1, "old");
        save(&root, &old).unwrap();
        let before = std::fs::read(root.session_file()).unwrap();
        let mut bad = one_tab(2, "missing-context");
        bad.windows[0].tabs[0].panes.push(SavedPane {
            id: 7,
            scrollback: true,
            ..Default::default()
        });
        assert!(save(&root, &bad).is_err());
        assert!(save(&root, &SavedSession::default()).is_err());
        assert_eq!(std::fs::read(root.session_file()).unwrap(), before);
        assert_eq!(load(&root), Some(old));
        clear(&root).unwrap();
        assert_eq!(load(&root), Some(SavedSession::default()));
        std::fs::remove_dir_all(root.home()).unwrap();
    }
    #[test]
    fn archive_restores_original_context_after_live_file_changes_and_corrupt_bundle() {
        let root = isolated_root();
        let mut old = one_tab(1, "old");
        old.windows[0].tabs[0].panes.push(SavedPane {
            id: 9,
            scrollback: true,
            ..Default::default()
        });
        std::fs::create_dir_all(root.scrollback_dir()).unwrap();
        std::fs::write(root.scrollback_dir().join("9.txt"), "original history").unwrap();
        save_for(&root, &old, true).unwrap();
        std::fs::write(
            root.scrollback_dir().join("9.txt"),
            "new unrelated terminal",
        )
        .unwrap();
        std::fs::write(bundle_file(&root), "not json").unwrap();
        std::fs::write(root.session_file(), "not json").unwrap();
        assert_eq!(load(&root), Some(old));
        assert_eq!(
            std::fs::read_to_string(root.scrollback_dir().join("9.txt")).unwrap(),
            "original history"
        );
        let b = parse_bundle(&root.tab_state_backups_dir().join("latest.json")).unwrap();
        let context = b.contexts.get(&9).unwrap();
        std::fs::write(
            contexts_dir(&root).join(format!("{}.txt", context.sha256)),
            "same count wrong history",
        )
        .unwrap();
        assert!(load(&root).is_none());
        std::fs::remove_dir_all(root.home()).unwrap();
    }
    #[test]
    fn selected_identity_survives_global_tab_dedup_and_ai_session_claims() {
        let mut first = one_tab(1, "first");
        let mut duplicate = first.windows[0].clone();
        let mut selected = one_tab(2, "selected").windows.remove(0).tabs.remove(0);
        let pane = SavedPane {
            id: 3,
            ai_provider: Some("claude".into()),
            ai_session_id: Some("session-a".into()),
            ai_resume_command: Some("claude --resume session-a".into()),
            ..Default::default()
        };
        first.windows[0].tabs[0].panes.push(pane.clone());
        selected.panes.push(pane);
        duplicate.tabs.push(selected);
        duplicate.selected = 1;
        first.windows.push(duplicate);
        let restored = sanitize_session(first);
        assert_eq!(restored.windows.len(), 2);
        assert_eq!(restored.windows[1].tabs.len(), 1);
        assert_eq!(restored.windows[1].selected, 0);
        assert_eq!(
            restored.windows[1].tabs[0].uuid,
            Some(uuid::Uuid::from_u128(2))
        );
        assert!(
            restored.windows[1].tabs[0].panes[0]
                .ai_resume_command
                .is_none()
        );
    }
    #[test]
    fn backup_metadata_matches_stable_tab_pane_directory_and_preserves_plain_current_shell() {
        let mut base = one_tab(1, "base");
        base.windows[0].tabs[0].panes.push(SavedPane {
            id: 4,
            directory: Some("/repo".into()),
            ..Default::default()
        });
        let mut backup = base.clone();
        let pane = &mut backup.windows[0].tabs[0].panes[0];
        pane.ai_provider = Some("codex".into());
        pane.ai_session_id = Some("session-c".into());
        pane.ai_resume_command = Some("codex resume session-c".into());
        let mut current = base.clone();
        recover_resume_metadata(&mut current, std::slice::from_ref(&backup), false);
        assert_eq!(current, base);
        recover_resume_metadata(&mut current, std::slice::from_ref(&backup), true);
        assert_eq!(
            current.windows[0].tabs[0].panes[0].ai_provider.as_deref(),
            Some("codex")
        );
        backup.windows[0].tabs[0].panes[0].directory = Some("/other".into());
        recover_resume_metadata(&mut base, &[backup], true);
        assert!(base.windows[0].tabs[0].panes[0].ai_provider.is_none());
    }
    fn write_archive(dir: &Path, name: &str, context_bytes: u64) {
        let bundle = RestoreBundle {
            schema_version: 1,
            save_token: "x".into(),
            previous_index_token: None,
            explicit_clear: false,
            session: one_tab(1, "x"),
            contexts: [(
                1,
                ContextRef {
                    sha256: "a".repeat(64),
                    byte_count: context_bytes as usize,
                },
            )]
            .into_iter()
            .collect(),
        };
        std::fs::write(dir.join(name), serde_json::to_vec(&bundle).unwrap()).unwrap();
    }
    #[test]
    fn archive_budget_counts_contexts_but_keeps_large_scrollback_archives() {
        let root = isolated_root();
        let dir = root.tab_state_backups_dir().join("archive");
        std::fs::create_dir_all(&dir).unwrap();
        // Scrollback beyond the 16 MiB manifest bound is not a reason to
        // drop an archive; only the 128 MiB folder budget is.
        let large = MAX_MANIFEST_BYTES + 1;
        write_archive(&dir, "0000000000003.json", large);
        write_archive(&dir, "0000000000002.json", large);
        write_archive(&dir, "0000000000001.json", MAX_ARCHIVE_BYTES - large);
        prune_archive(&dir, SystemTime::now());
        let names: Vec<_> = archive_files(&dir)
            .iter()
            .map(|p| p.file_name().unwrap().to_string_lossy().into_owned())
            .collect();
        assert_eq!(names, vec!["0000000000003.json", "0000000000002.json"]);
        std::fs::remove_dir_all(root.home()).unwrap();
    }
    #[test]
    fn the_newest_archive_is_always_kept() {
        let root = isolated_root();
        let dir = root.tab_state_backups_dir().join("archive");
        std::fs::create_dir_all(&dir).unwrap();
        write_archive(&dir, "0000000000002.json", MAX_ARCHIVE_BYTES + 1);
        write_archive(&dir, "0000000000001.json", 1);
        prune_archive(&dir, SystemTime::now());
        assert_eq!(archive_files(&dir), vec![dir.join("0000000000002.json")]);
        std::fs::remove_dir_all(root.home()).unwrap();
    }
    #[test]
    fn writers_are_serialized_by_the_store_lock() {
        let root = isolated_root();
        let guard = store_lock();
        let writer = {
            let root = root.clone();
            std::thread::spawn(move || save(&root, &one_tab(1, "x")))
        };
        std::thread::sleep(Duration::from_millis(300));
        // The save waits for the lock: nothing is written meanwhile.
        assert!(!root.session_file().exists());
        drop(guard);
        writer.join().unwrap().unwrap();
        assert!(root.session_file().exists());
        std::fs::remove_dir_all(root.home()).unwrap();
    }
    #[test]
    fn concurrent_saves_never_lose_a_committed_context() {
        let root = isolated_root();
        std::fs::create_dir_all(root.scrollback_dir()).unwrap();
        let threads: Vec<_> = (0..4_u64)
            .map(|t| {
                let root = root.clone();
                std::thread::spawn(move || {
                    for i in 0..25 {
                        let pane = 100 + t;
                        std::fs::write(
                            root.scrollback_dir().join(format!("{pane}.txt")),
                            format!("thread {t} iteration {i}"),
                        )
                        .unwrap();
                        let mut session = one_tab(u128::from(pane), "x");
                        session.windows[0].tabs[0].panes.push(SavedPane {
                            id: pane,
                            scrollback: true,
                            ..Default::default()
                        });
                        save(&root, &session).unwrap();
                    }
                })
            })
            .collect();
        for thread in threads {
            thread.join().unwrap();
        }
        let bundle = parse_bundle(&bundle_file(&root)).unwrap();
        assert!(hydrate_bundle(&root, &bundle).is_some());
        std::fs::remove_dir_all(root.home()).unwrap();
    }
    #[test]
    fn stale_temporary_files_are_swept() {
        let root = isolated_root();
        save(&root, &one_tab(1, "x")).unwrap();
        let old = SystemTime::now() - Duration::from_secs(3600);
        let dirs = [
            bundle_file(&root).parent().unwrap().to_path_buf(),
            contexts_dir(&root),
            root.tab_state_backups_dir(),
            root.tab_state_backups_dir().join("archive"),
        ];
        let mut stale = Vec::new();
        let mut fresh = Vec::new();
        for dir in &dirs {
            std::fs::create_dir_all(dir).unwrap();
            let path = dir.join(format!(".restore-{}.tmp", uuid::Uuid::new_v4()));
            std::fs::write(&path, b"leak").unwrap();
            std::fs::File::options()
                .write(true)
                .open(&path)
                .unwrap()
                .set_modified(old)
                .unwrap();
            stale.push(path);
            let path = dir.join(format!(".latest.json.{}.tmp", uuid::Uuid::new_v4()));
            std::fs::write(&path, b"in flight").unwrap();
            fresh.push(path);
        }
        save(&root, &one_tab(1, "y")).unwrap();
        assert!(stale.iter().all(|p| !p.exists()), "{stale:?}");
        assert!(fresh.iter().all(|p| p.exists()), "{fresh:?}");
        std::fs::remove_dir_all(root.home()).unwrap();
    }

    #[test]
    fn unmarked_empty_bundle_or_index_never_overrides_viable_backups() {
        let root = isolated_root();
        let old = one_tab(1, "recoverable");
        save_for(&root, &old, true).unwrap();
        let mut empty = parse_bundle(&bundle_file(&root)).unwrap();
        empty.session = SavedSession::default();
        std::fs::write(bundle_file(&root), serde_json::to_vec(&empty).unwrap()).unwrap();
        std::fs::write(
            root.session_file(),
            serde_json::to_vec(&SavedSession::default()).unwrap(),
        )
        .unwrap();
        assert_eq!(load(&root), Some(old));
        clear(&root).unwrap();
        assert_eq!(load(&root), Some(SavedSession::default()));
        std::fs::remove_dir_all(root.home()).unwrap();
    }

    #[test]
    fn measurements_match_committed_bytes_and_deduplicate_shared_contexts() {
        let root = isolated_root();
        let mut saved = one_tab(1, "first");
        root.ensure_dirs().unwrap();
        std::fs::create_dir_all(root.scrollback_dir()).unwrap();
        saved.windows[0].tabs[0].panes.push(SavedPane {
            id: 1,
            ..Default::default()
        });
        let mut second = saved.windows[0].tabs[0].panes[0].clone();
        second.id = 2;
        saved.windows[0].tabs[0].panes.push(second);
        for pane in &mut saved.windows[0].tabs[0].panes {
            pane.scrollback = true;
            std::fs::write(
                root.scrollback_dir().join(format!("{}.txt", pane.id)),
                b"same transcript",
            )
            .unwrap();
        }
        let measured = save_for_measured(&root, &saved, false).unwrap();
        let manifest = std::fs::metadata(bundle_file(&root)).unwrap().len();
        let index = std::fs::metadata(root.session_file()).unwrap().len();
        assert_eq!(measured.bytes, manifest + index + 15);
        assert_eq!(measured.metadata["uniqueContextBytes"], "15");
        assert_eq!(measured.metadata["windowCount"], "1");
        assert_eq!(measured.metadata["tabCount"], "1");
        assert_eq!(measured.metadata["paneCount"], "2");
        assert!(measured.metadata.values().all(|v| v.parse::<u64>().is_ok()));
        assert!(
            measured.metadata["largestPanePayloadBytes"]
                .parse::<u64>()
                .unwrap()
                > 15
        );
        std::fs::remove_dir_all(root.home()).unwrap();
    }

    #[test]
    fn restored_source_is_archived_once_without_republishing_index() {
        let root = isolated_root();
        save(&root, &one_tab(1, "restore")).unwrap();
        let before = std::fs::read(root.session_file()).unwrap();
        let dir = root.tab_state_backups_dir().join("archive");
        let count = archive_files(&dir).len();
        load(&root).unwrap();
        assert_eq!(archive_files(&dir).len(), count + 1);
        load(&root).unwrap();
        assert_eq!(archive_files(&dir).len(), count + 1);
        assert_eq!(std::fs::read(root.session_file()).unwrap(), before);
        std::fs::remove_dir_all(root.home()).unwrap();
    }
    #[test]
    fn legacy_primary_index_recovers_other_window_without_duplicating_primary() {
        let root = isolated_root();
        let primary = one_tab(1, "primary");
        let mut full = one_tab(2, "other");
        full.windows.push(primary.windows[0].clone());
        save_for(&root, &full, true).unwrap();
        // A legacy single-window payload matches the second backup window.
        std::fs::write(root.session_file(), serde_json::to_vec(&primary).unwrap()).unwrap();
        std::fs::remove_file(bundle_file(&root)).unwrap();
        let restored = load(&root).unwrap();
        assert_eq!(restored.windows.len(), 2);
        assert_eq!(
            restored.windows[0].tabs[0].uuid,
            Some(uuid::Uuid::from_u128(1))
        );
        assert_eq!(
            restored.windows[1].tabs[0].uuid,
            Some(uuid::Uuid::from_u128(2))
        );
        // A fresh index intentionally closing the other window stays closed.
        save(&root, &primary).unwrap();
        std::fs::remove_file(bundle_file(&root)).unwrap();
        assert_eq!(load(&root), Some(primary));
        std::fs::remove_dir_all(root.home()).unwrap();
    }

    #[test]
    fn legacy_primary_does_not_resurrect_unrelated_backup_windows() {
        let root = isolated_root();
        let primary = one_tab(1, "current primary");
        let mut unrelated = one_tab(2, "old primary");
        unrelated
            .windows
            .push(one_tab(3, "old secondary").windows.remove(0));
        save_for(&root, &unrelated, true).unwrap();
        std::fs::write(root.session_file(), serde_json::to_vec(&primary).unwrap()).unwrap();
        std::fs::remove_file(bundle_file(&root)).unwrap();
        assert_eq!(load(&root), Some(primary));
        std::fs::remove_dir_all(root.home()).unwrap();
    }

    #[test]
    fn legacy_recovery_skips_unrelated_latest_and_uses_matching_archive() {
        let root = isolated_root();
        let primary = one_tab(1, "current primary");
        let mut matching = one_tab(2, "matching secondary");
        matching.windows.push(primary.windows[0].clone());
        save_for(&root, &matching, true).unwrap();
        let mut unrelated = one_tab(3, "unrelated primary");
        unrelated
            .windows
            .push(one_tab(4, "unrelated secondary").windows.remove(0));
        save_for(&root, &unrelated, true).unwrap();
        std::fs::write(root.session_file(), serde_json::to_vec(&primary).unwrap()).unwrap();
        std::fs::remove_file(bundle_file(&root)).unwrap();
        let restored = load(&root).unwrap();
        assert_eq!(restored.windows.len(), 2);
        assert_eq!(restored.windows[0], primary.windows[0]);
        assert_eq!(restored.windows[1], matching.windows[0]);
        std::fs::remove_dir_all(root.home()).unwrap();
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
