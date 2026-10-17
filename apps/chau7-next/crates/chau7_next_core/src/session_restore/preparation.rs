//! Read-only restore preparation. Run on the owned background executor before
//! constructing PTYs; never mutate provider state or launch a shell here.
use crate::ai::resume::normalize_provider_name;
use crate::data_root::DataRoot;
use crate::monitoring::{claude_resolver, codex_sessions::CodexSessionResolver};
use crate::session_restore::lifecycle::ResumeIdentity;
use crate::session_restore::models::{SavedPane, SavedTab};
use crate::session_restore::{MAX_SCROLLBACK_BYTES, SavedSplitNode, build_ai_resume_command};
use std::collections::{HashMap, HashSet};
use std::io::Read;
use std::path::{Path, PathBuf};

#[derive(Clone, Debug)]
pub struct PreparedPane {
    pub directory: PathBuf,
    pub context: Option<String>,
    pub identity: Option<ResumeIdentity>,
    pub command: Option<String>,
    /// True only when directory history supplied the missing persisted ID.
    pub discovered_identity: bool,
}
pub struct PreparedTab {
    pub saved: SavedTab,
    pub panes: HashMap<u64, PreparedPane>,
}
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
struct Claim {
    root: PathBuf,
    provider: String,
    session_id: String,
}
type Claims = HashMap<Claim, (uuid::Uuid, u64)>;
static CLAIMS: std::sync::LazyLock<std::sync::Mutex<Claims>> =
    std::sync::LazyLock::new(|| std::sync::Mutex::new(HashMap::new()));
/// Saved IDs are metadata reservations, distinct from admitted live PTY claims.
/// Registration uses only the already loaded schema; no provider/context I/O.
#[derive(Default)]
struct IdentityHints {
    generation: u64,
    owners: HashMap<String, HashSet<uuid::Uuid>>,
}
static IDENTITY_HINTS: std::sync::LazyLock<std::sync::Mutex<HashMap<PathBuf, IdentityHints>>> =
    std::sync::LazyLock::new(|| std::sync::Mutex::new(HashMap::new()));
static NEXT_HINT_GENERATION: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(1);

fn insert_hints(hints: &mut IdentityHints, owner: uuid::Uuid, saved: &SavedTab) {
    for pane in &saved.panes {
        // Swift reservations honor a persisted ID even when autosave lost its
        // provider. Directory discovery must not steal that sibling identity.
        if let Some(id) = pane
            .ai_session_id
            .as_deref()
            .filter(|id| !id.trim().is_empty())
        {
            hints.owners.entry(id.to_owned()).or_default().insert(owner);
        }
        for identity in candidates(pane) {
            hints
                .owners
                .entry(identity.session_id)
                .or_default()
                .insert(owner);
        }
    }
}
pub fn register_saved_identity_hints<'a>(
    root: &DataRoot,
    tabs: impl IntoIterator<Item = &'a SavedTab>,
) {
    let mut hints = IdentityHints {
        generation: NEXT_HINT_GENERATION.fetch_add(1, std::sync::atomic::Ordering::Relaxed),
        ..Default::default()
    };
    for saved in tabs {
        if let Some(owner) = saved.uuid {
            insert_hints(&mut hints, owner, saved);
        }
    }
    IDENTITY_HINTS
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .insert(root.state_dir().to_path_buf(), hints);
}
/// Reopened/moved parked tabs join the current reservation generation before
/// preparation. This is cached schema admission, never filesystem inspection.
pub fn register_owner_identity_hints(root: &DataRoot, owner: uuid::Uuid, saved: &SavedTab) {
    let mut all = IDENTITY_HINTS.lock().unwrap_or_else(|e| e.into_inner());
    let hints = all.entry(root.state_dir().to_path_buf()).or_default();
    hints.owners.retain(|_, owners| {
        owners.remove(&owner);
        !owners.is_empty()
    });
    insert_hints(hints, owner, saved);
}
pub fn identity_hint_generation(root: &DataRoot) -> u64 {
    IDENTITY_HINTS
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .get(root.state_dir())
        .map_or(0, |hints| hints.generation)
}
fn identity_available(
    root: &DataRoot,
    owner: Option<uuid::Uuid>,
    pane: u64,
    identity: &ResumeIdentity,
    discovered: bool,
) -> bool {
    if discovered
        && IDENTITY_HINTS
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .get(root.state_dir())
            .and_then(|hints| hints.owners.get(&identity.session_id))
            .is_some_and(|owners| owners.iter().any(|id| Some(*id) != owner))
    {
        return false;
    }
    let key = Claim {
        root: root.state_dir().to_path_buf(),
        provider: identity.provider.clone(),
        session_id: identity.session_id.clone(),
    };
    !CLAIMS
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .get(&key)
        .is_some_and(|old| Some(old.0) != owner || old.1 != pane)
}
/// Final metadata admission fences replacement registrations and active owners.
/// It never grants PTY control or delivers the saved resume command.
pub fn admit_identity_metadata(
    root: &DataRoot,
    owner: uuid::Uuid,
    generation: u64,
    prepared: &mut PreparedTab,
) -> bool {
    let mut all = IDENTITY_HINTS.lock().unwrap_or_else(|e| e.into_inner());
    let hints = all.entry(root.state_dir().to_path_buf()).or_default();
    if hints.generation != generation {
        return false;
    }
    // Lock order is always hints then claims, including owner release.
    let claims = CLAIMS.lock().unwrap_or_else(|e| e.into_inner());
    for pane in &mut prepared.saved.panes {
        let Some(item) = prepared.panes.get_mut(&pane.id) else {
            continue;
        };
        let Some(identity) = &item.identity else {
            continue;
        };
        let key = Claim {
            root: root.state_dir().to_path_buf(),
            provider: identity.provider.clone(),
            session_id: identity.session_id.clone(),
        };
        if claims.get(&key).is_some_and(|old| *old != (owner, pane.id))
            || (item.discovered_identity
                && hints
                    .owners
                    .get(&identity.session_id)
                    .is_some_and(|owners| owners.iter().any(|id| *id != owner)))
        {
            pane.ai_provider = item.discovered_identity.then(|| identity.provider.clone());
            item.identity = None;
            item.command = None;
            pane.ai_session_id = None;
            pane.ai_resume_command = None;
        }
    }
    hints.owners.retain(|_, owners| {
        owners.remove(&owner);
        !owners.is_empty()
    });
    insert_hints(hints, owner, &prepared.saved);
    true
}
/// Admission runs on the app thread only after a live pane tree accepted the
/// prepared result. Closing a tab while validation runs cannot leak ownership.
pub fn claim(root: &DataRoot, owner: uuid::Uuid, prepared: &mut PreparedTab) {
    let all_hints = IDENTITY_HINTS.lock().unwrap_or_else(|e| e.into_inner());
    let hints = all_hints.get(root.state_dir());
    let mut claims = CLAIMS.lock().unwrap_or_else(|e| e.into_inner());
    for pane in &mut prepared.saved.panes {
        let Some(item) = prepared.panes.get_mut(&pane.id) else {
            continue;
        };
        let Some(identity) = &item.identity else {
            continue;
        };
        let key = Claim {
            root: root.state_dir().to_path_buf(),
            provider: identity.provider.clone(),
            session_id: identity.session_id.clone(),
        };
        if claims.get(&key).is_some_and(|old| *old != (owner, pane.id))
            || (item.discovered_identity
                && hints
                    .and_then(|hints| hints.owners.get(&identity.session_id))
                    .is_some_and(|owners| owners.iter().any(|id| *id != owner)))
        {
            pane.ai_provider = item.discovered_identity.then(|| identity.provider.clone());
            item.identity = None;
            item.command = None;
            pane.ai_session_id = None;
            pane.ai_resume_command = None;
        } else {
            claims.insert(key, (owner, pane.id));
        }
    }
}
pub fn release_owner(root: &DataRoot, owner: uuid::Uuid) {
    if let Some(hints) = IDENTITY_HINTS
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .get_mut(root.state_dir())
    {
        hints.owners.retain(|_, owners| {
            owners.remove(&owner);
            !owners.is_empty()
        });
    }
    CLAIMS
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .retain(|key, value| key.root != root.state_dir() || value.0 != owner);
}

fn canonical(path: &Path) -> PathBuf {
    std::fs::canonicalize(path).unwrap_or_else(|_| path.to_path_buf())
}
fn read_context(root: &DataRoot, pane: &SavedPane) -> Option<String> {
    if !pane.scrollback {
        return None;
    }
    let path = root.scrollback_dir().join(format!("{}.txt", pane.id));
    let file = std::fs::File::open(path).ok()?;
    let mut bytes = Vec::new();
    file.take((MAX_SCROLLBACK_BYTES + 1) as u64)
        .read_to_end(&mut bytes)
        .ok()?;
    if bytes.len() > MAX_SCROLLBACK_BYTES {
        return None;
    }
    String::from_utf8(bytes).ok()
}
fn candidates(pane: &SavedPane) -> Vec<ResumeIdentity> {
    // One authoritative identity: explicit fields first, then agreeing legacy
    // commands. A failed exact artifact check must not switch to another ID.
    let metadata = crate::session_restore::resolve_resume_metadata_from_saved(
        pane.ai_provider.as_deref(),
        pane.ai_session_id.as_deref(),
        pane.ai_resume_command.as_deref(),
    )
    .or_else(|| {
        crate::session_restore::resolve_resume_metadata_from_saved(
            pane.ai_provider.as_deref(),
            pane.ai_session_id.as_deref(),
            pane.agent_launch_command.as_deref(),
        )
    });
    metadata
        .into_iter()
        .map(|m| ResumeIdentity {
            provider: m.provider,
            session_id: m.session_id,
        })
        .collect()
}
fn validate(
    home: &Path,
    metadata: &ResumeIdentity,
    directory: &Path,
    reference: Option<f64>,
    synthetic: bool,
    codex: &mut CodexSessionResolver,
) -> Option<ResumeIdentity> {
    let uuid = uuid::Uuid::parse_str(&metadata.session_id).is_ok();
    let mut codex_exists = || {
        codex
            .metadata(home, &metadata.session_id, reference)
            .is_some()
    };
    let claude_exists = || {
        claude_resolver::has_restorable_transcript(
            home,
            &metadata.session_id,
            &directory.to_string_lossy(),
            None,
        )
    };
    let valid = match metadata.provider.as_str() {
        "codex" => !uuid || codex_exists(),
        "claude" => synthetic || claude_exists(),
        _ => true,
    };
    if valid {
        return Some(metadata.clone());
    }
    if synthetic {
        return None;
    }
    // Repair the provider only with an exact alternate artifact. Never guess
    // another ID or replace a newer persisted identity with directory history.
    let alternate = match metadata.provider.as_str() {
        "codex" if uuid && claude_exists() => "claude",
        "claude" if uuid && codex_exists() => "codex",
        _ => return None,
    };
    Some(ResumeIdentity {
        provider: alternate.into(),
        session_id: metadata.session_id.clone(),
    })
}
fn rewrite_layout(node: &mut SavedSplitNode, panes: &HashMap<u64, PreparedPane>) {
    match node {
        SavedSplitNode::Terminal { id, directory } => {
            if let Some(pane) = panes.get(id) {
                *directory = Some(pane.directory.to_string_lossy().into_owned());
            }
        }
        SavedSplitNode::Split { children, .. } => {
            for child in children {
                rewrite_layout(child, panes);
            }
        }
        _ => {}
    }
}
pub fn prepare(root: &DataRoot, saved: SavedTab, fallback: Option<PathBuf>) -> PreparedTab {
    prepare_with_contexts(root, saved, fallback, HashMap::new())
}
/// Captured but not yet committed contexts cover close/reopen races. All
/// provider and canonical-file inspection still runs on the background task.
pub fn prepare_with_contexts(
    root: &DataRoot,
    saved: SavedTab,
    fallback: Option<PathBuf>,
    contexts: HashMap<u64, Option<std::sync::Arc<String>>>,
) -> PreparedTab {
    prepare_profile(root, saved, fallback, contexts, true)
}
/// Validate and hydrate parked identity only. Full payload flags/layout survive;
/// scrollback files and captured contexts are deliberately not loaded.
pub fn prepare_identity(
    root: &DataRoot,
    saved: SavedTab,
    fallback: Option<PathBuf>,
) -> PreparedTab {
    prepare_profile(root, saved, fallback, HashMap::new(), false)
}
fn prepare_profile(
    root: &DataRoot,
    mut saved: SavedTab,
    fallback: Option<PathBuf>,
    contexts: HashMap<u64, Option<std::sync::Arc<String>>>,
    load_contexts: bool,
) -> PreparedTab {
    let owner = saved.uuid;
    let fallback = fallback
        .or_else(|| saved.cwd.clone())
        .unwrap_or_else(|| root.home().to_path_buf());
    let mut prepared = HashMap::new();
    let mut claims = HashSet::new();
    let mut codex = CodexSessionResolver::new();
    for pane in &mut saved.panes {
        let mut directory = canonical(
            pane.directory
                .as_deref()
                .map(Path::new)
                .unwrap_or(&fallback),
        );
        let reference = [
            pane.last_input_at,
            pane.last_output_at,
            pane.agent_started_at,
            pane.last_exit_at,
        ]
        .into_iter()
        .flatten()
        .filter(|v| v.is_finite() && *v > 0.0)
        .max_by(f64::total_cmp);
        let synthetic = pane.ai_session_id_source.as_deref() == Some("synthetic");
        let resume_candidates = candidates(pane);
        let had_no_complete_identity = resume_candidates.is_empty()
            && pane
                .ai_session_id
                .as_deref()
                .is_none_or(|s| s.trim().is_empty())
            && pane
                .ai_resume_command
                .as_deref()
                .is_none_or(|s| s.trim().is_empty());
        let provider_only = had_no_complete_identity
            .then(|| {
                pane.ai_provider
                    .as_deref()
                    .and_then(normalize_provider_name)
            })
            .flatten();
        // Directory and timing are not ownership evidence. Several tabs may
        // share a cwd, and provider history may belong to another application.
        // Keep a provider-only pane unresolved until its own session is known.
        let identity = resume_candidates.into_iter().find_map(|m| {
            let valid = validate(
                root.home(),
                &m,
                &directory,
                reference,
                synthetic,
                &mut codex,
            )?;
            (identity_available(root, owner, pane.id, &valid, false)
                && claims.insert((valid.provider.clone(), valid.session_id.clone())))
            .then_some(valid)
        });
        if let Some(identity) = &identity
            && identity.provider == "claude"
            && !synthetic
            && let Some(cwd) = claude_resolver::restore_directory(
                root.home(),
                &identity.session_id,
                &directory.to_string_lossy(),
            )
        {
            directory = canonical(Path::new(&cwd));
        }
        let command = identity
            .as_ref()
            .and_then(|m| build_ai_resume_command(Some(&m.provider), Some(&m.session_id)));
        let context = if !load_contexts {
            None
        } else {
            match contexts.get(&pane.id) {
                Some(text) => text
                    .as_ref()
                    .filter(|s| s.len() <= MAX_SCROLLBACK_BYTES)
                    .map(|s| s.as_ref().clone()),
                None => read_context(root, pane),
            }
        };
        if identity.is_none()
            && pane.archived_ai_resume.is_none()
            && (pane.ai_session_id.is_some() || pane.ai_resume_command.is_some())
        {
            // Failed validation removes execution authority, not recovery data.
            // This archive is inert and never participates in candidates().
            pane.archived_ai_resume =
                Some(crate::session_restore::models::ArchivedAIResumeMetadata {
                    provider: pane.ai_provider.clone(),
                    session_id: pane.ai_session_id.clone(),
                    session_id_source: pane.ai_session_id_source.clone(),
                    resume_command: pane.ai_resume_command.clone(),
                });
        }
        pane.directory = Some(directory.to_string_lossy().into_owned());
        pane.ai_provider = identity
            .as_ref()
            .map(|m| m.provider.clone())
            .or_else(|| provider_only.clone());
        pane.ai_session_id = identity.as_ref().map(|m| m.session_id.clone());
        pane.ai_resume_command = command.clone();
        pane.agent_launch_command = None;
        prepared.insert(
            pane.id,
            PreparedPane {
                directory,
                context,
                identity,
                command,
                discovered_identity: false,
            },
        );
    }
    if let Some(pane) = saved
        .focused_terminal()
        .and_then(|pane| prepared.get(&pane.id))
    {
        saved.cwd = Some(pane.directory.clone());
    }
    if let Some(layout) = &mut saved.layout {
        rewrite_layout(layout, &prepared);
    }
    PreparedTab {
        saved,
        panes: prepared,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn identity_only_preserves_full_payload_and_repairs_directory_without_contexts() {
        let f = Fixture::new();
        let nested = f.directory.join("nested");
        std::fs::create_dir(&nested).unwrap();
        f.claude("owned-session", &nested);
        std::fs::create_dir_all(f.root.scrollback_dir()).unwrap();
        std::fs::write(
            f.root.scrollback_dir().join("1.txt"),
            "retained full scrollback",
        )
        .unwrap();
        let mut pane = f.pane(1, "claude", "owned-session");
        pane.scrollback = true;
        let saved = SavedTab {
            uuid: Some(uuid::Uuid::new_v4()),
            focused_pane: Some(1),
            custom_title: Some("Keep title".into()),
            layout: Some(SavedSplitNode::Terminal {
                id: 1,
                directory: None,
            }),
            ..f.tab(vec![pane])
        };
        let identity = prepare_identity(&f.root, saved.clone(), None);
        assert!(identity.panes[&1].context.is_none());
        assert!(identity.saved.panes[0].scrollback);
        assert_eq!(identity.saved.custom_title, saved.custom_title);
        assert_eq!(identity.saved.uuid, saved.uuid);
        assert_eq!(identity.saved.cwd, Some(canonical(&nested)));
        assert_eq!(
            identity.saved.layout.as_ref().unwrap().terminal_ids(),
            vec![1]
        );
        assert_eq!(
            identity.saved.panes[0].ai_resume_command.as_deref(),
            Some("claude --resume owned-session")
        );
        let full = prepare(&f.root, identity.saved, None);
        assert_eq!(
            full.panes[&1].context.as_deref(),
            Some("retained full scrollback")
        );
        assert!(
            CLAIMS
                .lock()
                .unwrap()
                .keys()
                .all(|key| key.root != f.root.state_dir())
        );
    }
    #[test]
    fn releasing_a_sibling_does_not_grant_provider_only_panes_its_session() {
        let f = Fixture::new();
        f.claude("parked-session", &f.directory);
        let owner = uuid::Uuid::new_v4();
        let parked = SavedTab {
            uuid: Some(owner),
            ..f.tab(vec![SavedPane {
                ai_provider: None,
                ..f.pane(2, "codex", "parked-session")
            }])
        };
        register_saved_identity_hints(&f.root, [&parked]);
        let seeker = SavedTab {
            uuid: Some(uuid::Uuid::new_v4()),
            ..f.tab(vec![SavedPane {
                id: 1,
                directory: Some(f.directory.to_string_lossy().into_owned()),
                ai_provider: Some("claude".into()),
                ..Default::default()
            }])
        };
        let blocked = prepare_identity(&f.root, seeker.clone(), None);
        assert!(blocked.panes[&1].identity.is_none());
        release_owner(&f.root, owner);
        let available = prepare_identity(&f.root, seeker, None);
        assert!(available.panes[&1].identity.is_none());
        assert!(available.panes[&1].command.is_none());
    }
    #[test]
    fn reopened_parked_owner_joins_existing_generation_without_invalidating_other_workers() {
        let f = Fixture::new();
        let owner = uuid::Uuid::new_v4();
        register_saved_identity_hints(&f.root, std::iter::empty());
        let generation = identity_hint_generation(&f.root);
        let saved = SavedTab {
            uuid: Some(owner),
            ..f.tab(vec![f.pane(1, "codex", "thread-reopened")])
        };
        register_owner_identity_hints(&f.root, owner, &saved);
        assert_eq!(identity_hint_generation(&f.root), generation);
        let identity = ResumeIdentity {
            provider: "codex".into(),
            session_id: "thread-reopened".into(),
        };
        assert!(!identity_available(
            &f.root,
            Some(uuid::Uuid::new_v4()),
            2,
            &identity,
            true
        ));
        assert!(identity_available(&f.root, Some(owner), 1, &identity, true));
        release_owner(&f.root, owner);
        assert!(identity_available(
            &f.root,
            Some(uuid::Uuid::new_v4()),
            2,
            &identity,
            true
        ));
    }
    #[test]
    fn metadata_reservations_are_root_scoped_and_generation_fenced() {
        let f = Fixture::new();
        let other = Fixture::new();
        let owner = uuid::Uuid::new_v4();
        let saved = SavedTab {
            uuid: Some(owner),
            ..f.tab(vec![f.pane(1, "codex", "thread-owned")])
        };
        register_saved_identity_hints(&f.root, [&saved]);
        let old = identity_hint_generation(&f.root);
        let mut prepared = prepare_identity(&f.root, saved.clone(), None);
        register_saved_identity_hints(&other.root, [&saved]);
        assert!(admit_identity_metadata(&f.root, owner, old, &mut prepared));
        register_saved_identity_hints(&f.root, [&saved]);
        assert!(!admit_identity_metadata(&f.root, owner, old, &mut prepared));
        assert!(
            CLAIMS
                .lock()
                .unwrap()
                .keys()
                .all(|key| key.root != f.root.state_dir())
        );
    }
    #[test]
    fn provider_only_tabs_never_gain_identity_from_shared_directory_history() {
        let f = Fixture::new();
        f.claude("foreign-session", &f.directory);
        let make = |id| SavedTab {
            uuid: Some(uuid::Uuid::new_v4()),
            custom_title: Some(format!("tab {id}")),
            ..f.tab(vec![SavedPane {
                id,
                directory: Some(f.directory.to_string_lossy().into_owned()),
                ai_provider: Some("claude".into()),
                last_output_at: Some(crate::ai::detection_state::now_secs()),
                ..Default::default()
            }])
        };
        let a = make(1);
        let b = make(2);
        register_saved_identity_hints(&f.root, [&a, &b]);
        let generation = identity_hint_generation(&f.root);
        for saved in [b, a] {
            let mut prepared = prepare_identity(&f.root, saved.clone(), None);
            assert!(admit_identity_metadata(
                &f.root,
                saved.uuid.unwrap(),
                generation,
                &mut prepared
            ));
            let prepared = prepare(&f.root, prepared.saved, None);
            assert_eq!(prepared.saved.custom_title, saved.custom_title);
            for pane in prepared.panes.values() {
                assert!(pane.identity.is_none());
                assert!(pane.command.is_none());
            }
        }
    }
    #[test]
    fn live_admission_after_preparation_fences_late_metadata_without_claiming_a_pty() {
        let f = Fixture::new();
        let owner = uuid::Uuid::new_v4();
        let saved = SavedTab {
            uuid: Some(owner),
            ..f.tab(vec![f.pane(1, "codex", "thread-live")])
        };
        register_saved_identity_hints(&f.root, [&saved]);
        let generation = identity_hint_generation(&f.root);
        let mut late = prepare_identity(&f.root, saved, None);
        let mut live = prepare(
            &f.root,
            f.tab(vec![f.pane(2, "codex", "thread-live")]),
            None,
        );
        claim(&f.root, uuid::Uuid::new_v4(), &mut live);
        assert!(admit_identity_metadata(
            &f.root, owner, generation, &mut late
        ));
        assert!(late.panes[&1].identity.is_none());
        assert!(late.saved.panes[0].ai_resume_command.is_none());
    }
    #[test]
    fn pending_context_and_tombstone_override_old_durable_file() {
        let fixture = Fixture::new();
        std::fs::create_dir_all(fixture.root.scrollback_dir()).unwrap();
        std::fs::write(fixture.root.scrollback_dir().join("1.txt"), "old durable").unwrap();
        let tab = fixture.tab(vec![SavedPane {
            id: 1,
            scrollback: true,
            ..Default::default()
        }]);
        let prepared = prepare_with_contexts(
            &fixture.root,
            tab.clone(),
            None,
            HashMap::from([(1, Some(std::sync::Arc::new("new pending".into())))]),
        );
        assert_eq!(prepared.panes[&1].context.as_deref(), Some("new pending"));
        let cleared = prepare_with_contexts(&fixture.root, tab, None, HashMap::from([(1, None)]));
        assert!(cleared.panes[&1].context.is_none());
        assert_eq!(
            std::fs::read_to_string(fixture.root.scrollback_dir().join("1.txt")).unwrap(),
            "old durable"
        );
    }
    struct Fixture {
        root: DataRoot,
        directory: PathBuf,
    }
    impl Fixture {
        fn new() -> Self {
            let home =
                std::env::temp_dir().join(format!("next-restore-prepare-{}", uuid::Uuid::new_v4()));
            let directory = home.join("repo");
            std::fs::create_dir_all(&directory).unwrap();
            Self {
                root: DataRoot::with_home(home, true),
                directory: canonical(&directory),
            }
        }
        fn pane(&self, id: u64, provider: &str, session: &str) -> SavedPane {
            SavedPane {
                id,
                directory: Some(self.directory.to_string_lossy().into_owned()),
                ai_provider: Some(provider.into()),
                ai_session_id: Some(session.into()),
                ..Default::default()
            }
        }
        fn tab(&self, panes: Vec<SavedPane>) -> SavedTab {
            SavedTab {
                cwd: Some(self.directory.clone()),
                panes,
                ..Default::default()
            }
        }
        fn claude(&self, id: &str, project: &Path) {
            let project = project.to_string_lossy();
            let folder = self
                .root
                .home()
                .join(".claude/projects")
                .join(crate::session_restore::claude_project_dir_name(&project));
            std::fs::create_dir_all(&folder).unwrap();
            std::fs::write(folder.join(format!("{id}.jsonl")), b"{}\n").unwrap();
            std::fs::write(
                self.root.home().join(".claude/history.jsonl"),
                format!(
                    "{}\n",
                    serde_json::json!({"sessionId":id,"project":project,"timestamp":1000})
                ),
            )
            .unwrap();
        }
        fn codex(&self, id: &str) {
            let folder = self.root.home().join(".codex/sessions/2020/01/01");
            std::fs::create_dir_all(&folder).unwrap();
            std::fs::write(folder.join(format!("rollout-{id}.jsonl")),format!("{}\n",serde_json::json!({"type":"session_meta","payload":{"id":id,"cwd":self.directory}}))).unwrap();
        }
    }
    impl Drop for Fixture {
        fn drop(&mut self) {
            IDENTITY_HINTS
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .remove(self.root.state_dir());
            CLAIMS
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .retain(|key, _| key.root != self.root.state_dir());
            let _ = std::fs::remove_dir_all(self.root.home());
        }
    }
    #[test]
    fn legacy_codex_ids_remain_valid_without_rollout_but_uuid_requires_exact_file() {
        let f = Fixture::new();
        let id = "9a23874b-e51e-4851-9abd-e804d975d78c";
        let prepared = prepare(
            &f.root,
            f.tab(vec![
                f.pane(1, "codex", "thread-legacy"),
                f.pane(2, "codex", id),
            ]),
            None,
        );
        assert_eq!(
            prepared.panes[&1].command.as_deref(),
            Some("codex resume thread-legacy")
        );
        assert!(prepared.panes[&2].identity.is_none());
        assert!(prepared.saved.panes[1].ai_provider.is_none());
        f.codex(id);
        let prepared = prepare(&f.root, f.tab(vec![f.pane(2, "codex", id)]), None);
        assert_eq!(prepared.panes[&2].identity.as_ref().unwrap().session_id, id);
    }
    #[test]
    fn exact_alternate_artifact_repairs_provider_and_resolves_claude_cwd_before_launch() {
        let f = Fixture::new();
        let id = "9a23874b-e51e-4851-9abd-e804d975d78c";
        let nested = f.directory.join("nested");
        std::fs::create_dir(&nested).unwrap();
        f.claude(id, &nested);
        let prepared = prepare(&f.root, f.tab(vec![f.pane(1, "codex", id)]), None);
        let pane = &prepared.panes[&1];
        assert_eq!(pane.identity.as_ref().unwrap().provider, "claude");
        assert_eq!(pane.identity.as_ref().unwrap().session_id, id);
        assert_eq!(pane.directory, canonical(&nested));
        assert_eq!(
            prepared.saved.panes[0].directory.as_deref(),
            Some(nested.to_string_lossy().as_ref())
        );
    }
    #[test]
    fn explicit_identity_beats_stale_commands_in_every_split_pane() {
        let f = Fixture::new();
        let mut a = f.pane(1, "codex", "stale-fields");
        a.ai_resume_command = Some("codex resume command-id".into());
        let mut b = f.pane(2, "codex", "stale-b");
        b.agent_launch_command = Some("codex resume launch-id".into());
        let tab = SavedTab {
            focused_pane: Some(2),
            layout: Some(SavedSplitNode::Split {
                id: 3,
                axis: crate::session_restore::SavedAxis::Horizontal,
                ratios: vec![0.3, 0.7],
                children: vec![
                    SavedSplitNode::Terminal {
                        id: 1,
                        directory: None,
                    },
                    SavedSplitNode::Terminal {
                        id: 2,
                        directory: None,
                    },
                ],
            }),
            ..f.tab(vec![a, b])
        };
        let prepared = prepare(&f.root, tab, None);
        assert_eq!(
            prepared.panes[&1].identity.as_ref().unwrap().session_id,
            "stale-fields"
        );
        assert_eq!(
            prepared.panes[&2].identity.as_ref().unwrap().session_id,
            "stale-b"
        );
        assert_eq!(prepared.saved.focused_pane, Some(2));
        assert_eq!(
            prepared.saved.layout.as_ref().unwrap().terminal_ids(),
            vec![1, 2]
        );
    }
    #[test]
    fn tab_names_and_exact_sessions_remain_paired_across_reordered_restore_cycles() {
        let f = Fixture::new();
        let make = |number, title: &str, session: &str, stale: &str| SavedTab {
            uuid: Some(uuid::Uuid::from_u128(number)),
            custom_title: Some(title.into()),
            focused_pane: Some(number as u64),
            ..f.tab(vec![SavedPane {
                ai_resume_command: Some(format!("codex resume {stale}")),
                ..f.pane(number as u64, "codex", session)
            }])
        };
        let mut tabs = vec![
            make(1, "First task", "first-thread", "second-thread"),
            make(2, "Second task", "second-thread", "first-thread"),
        ];
        for _ in 0..3 {
            tabs.reverse();
            register_saved_identity_hints(&f.root, &tabs);
            tabs = tabs
                .into_iter()
                .map(|saved| {
                    let expected = match saved.uuid.unwrap().as_u128() {
                        1 => ("First task", "first-thread"),
                        2 => ("Second task", "second-thread"),
                        _ => unreachable!(),
                    };
                    let metadata = prepare_identity(&f.root, saved, None);
                    let prepared = prepare(&f.root, metadata.saved, None);
                    assert_eq!(prepared.saved.custom_title.as_deref(), Some(expected.0));
                    let id = prepared.saved.focused_pane.unwrap();
                    assert_eq!(
                        prepared.panes[&id].identity.as_ref().unwrap().session_id,
                        expected.1
                    );
                    assert_eq!(
                        prepared.panes[&id].command.as_deref(),
                        Some(format!("codex resume {}", expected.1).as_str())
                    );
                    serde_json::from_str(&serde_json::to_string(&prepared.saved).unwrap()).unwrap()
                })
                .collect();
        }
    }

    #[test]
    fn missing_explicit_artifact_cannot_fall_back_to_another_valid_command() {
        let f = Fixture::new();
        let mut pane = f.pane(1, "codex", "12345678-1234-1234-1234-123456789abc");
        pane.ai_resume_command = Some("codex resume unrelated-valid-legacy-id".into());
        let prepared = prepare(&f.root, f.tab(vec![pane]), None);
        assert!(prepared.panes[&1].identity.is_none());
        assert!(prepared.panes[&1].command.is_none());
        let archived = prepared.saved.panes[0].archived_ai_resume.as_ref().unwrap();
        assert_eq!(
            archived.session_id.as_deref(),
            Some("12345678-1234-1234-1234-123456789abc")
        );
        let again = prepare(&f.root, prepared.saved, None);
        assert!(again.panes[&1].identity.is_none());
        assert!(again.panes[&1].command.is_none());
        assert_eq!(
            again.saved.panes[0]
                .archived_ai_resume
                .as_ref()
                .unwrap()
                .session_id
                .as_deref(),
            Some("12345678-1234-1234-1234-123456789abc")
        );
    }

    #[test]
    fn rejected_complete_identity_cannot_rediscover_history_and_synthetic_source_is_preserved() {
        let f = Fixture::new();
        f.claude("nearby", &f.directory);
        let rejected = f.pane(1, "claude", "missing-complete-id");
        let mut synthetic = f.pane(2, "claude", "synthetic-id");
        synthetic.ai_session_id_source = Some("synthetic".into());
        let prepared = prepare(&f.root, f.tab(vec![rejected, synthetic]), None);
        assert!(prepared.panes[&1].identity.is_none());
        assert!(prepared.saved.panes[0].ai_provider.is_none());
        assert_eq!(
            prepared.panes[&2].identity.as_ref().unwrap().session_id,
            "synthetic-id"
        );
        assert_eq!(
            prepared.saved.panes[1].ai_session_id_source.as_deref(),
            Some("synthetic")
        );
    }
    #[test]
    fn provider_only_history_cannot_prove_ownership_even_with_one_candidate() {
        let f = Fixture::new();
        f.claude("nearest", &f.directory);
        let pane = SavedPane {
            id: 1,
            directory: Some(f.directory.to_string_lossy().into_owned()),
            ai_provider: Some("claude".into()),
            last_input_at: Some(crate::ai::detection_state::now_secs()),
            ..Default::default()
        };
        let prepared = prepare(&f.root, f.tab(vec![pane]), None);
        assert!(prepared.panes[&1].identity.is_none());
        assert!(prepared.panes[&1].command.is_none());
        assert_eq!(
            prepared.saved.panes[0].ai_provider.as_deref(),
            Some("claude")
        );
    }
    #[test]
    fn claims_are_scoped_to_root_provider_and_live_owner_and_release_on_close() {
        let f = Fixture::new();
        let tab = f.tab(vec![f.pane(1, "codex", "thread-owned")]);
        let mut a = prepare(&f.root, tab.clone(), None);
        let mut b = prepare(&f.root, tab.clone(), None);
        let owner_a = uuid::Uuid::from_u128(1);
        let owner_b = uuid::Uuid::from_u128(2);
        claim(&f.root, owner_a, &mut a);
        claim(&f.root, owner_b, &mut b);
        assert!(a.panes[&1].identity.is_some());
        assert!(b.panes[&1].identity.is_none());
        assert!(b.saved.panes[0].ai_provider.is_none());
        release_owner(&f.root, owner_a);
        let mut reopened = prepare(&f.root, tab, None);
        claim(&f.root, owner_b, &mut reopened);
        assert!(reopened.panes[&1].identity.is_some());
    }
    #[test]
    fn context_read_is_bounded_utf8_and_never_mutates_saved_files() {
        let f = Fixture::new();
        std::fs::create_dir_all(f.root.scrollback_dir()).unwrap();
        let path = f.root.scrollback_dir().join("1.txt");
        std::fs::write(&path, "before\n€").unwrap();
        let mut pane = f.pane(1, "codex", "legacy-id");
        pane.scrollback = true;
        let prepared = prepare(&f.root, f.tab(vec![pane.clone()]), None);
        assert_eq!(prepared.panes[&1].context.as_deref(), Some("before\n€"));
        assert_eq!(std::fs::read_to_string(&path).unwrap(), "before\n€");
        std::fs::write(&path, vec![b'x'; MAX_SCROLLBACK_BYTES + 1]).unwrap();
        assert!(
            prepare(&f.root, f.tab(vec![pane.clone()]), None).panes[&1]
                .context
                .is_none()
        );
        std::fs::write(&path, [0xff]).unwrap();
        assert!(
            prepare(&f.root, f.tab(vec![pane]), None).panes[&1]
                .context
                .is_none()
        );
    }
}
