//! Read-only restore preparation. Run on the owned background executor before
//! constructing PTYs; never mutate provider state or launch a shell here.
use crate::ai::resume::{extract_metadata, normalize_provider_name};
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
/// Admission runs on the app thread only after a live pane tree accepted the
/// prepared result. Closing a tab while validation runs cannot leak ownership.
pub fn claim(root: &DataRoot, owner: uuid::Uuid, prepared: &mut PreparedTab) {
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
        if claims.get(&key).is_some_and(|old| *old != (owner, pane.id)) {
            item.identity = None;
            item.command = None;
            pane.ai_provider = None;
            pane.ai_session_id = None;
            pane.ai_resume_command = None;
        } else {
            claims.insert(key, (owner, pane.id));
        }
    }
}
pub fn release_owner(root: &DataRoot, owner: uuid::Uuid) {
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
    let mut out = Vec::new();
    for command in [
        pane.ai_resume_command.as_deref(),
        pane.agent_launch_command.as_deref(),
    ]
    .into_iter()
    .flatten()
    {
        if let Some(m) = extract_metadata(command) {
            out.push(ResumeIdentity {
                provider: m.provider,
                session_id: m.session_id,
            });
        }
    }
    if let Some((provider, id)) = pane
        .ai_provider
        .as_deref()
        .zip(pane.ai_session_id.as_deref())
        && let Some(provider) = normalize_provider_name(provider)
        && crate::ai::resume::is_valid_session_id(id)
    {
        out.push(ResumeIdentity {
            provider,
            session_id: id.to_owned(),
        });
    }
    let mut seen = HashSet::new();
    out.retain(|m| seen.insert((m.provider.clone(), m.session_id.clone())));
    out
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
pub fn prepare(root: &DataRoot, mut saved: SavedTab, fallback: Option<PathBuf>) -> PreparedTab {
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
        let mut resume_candidates = candidates(pane);
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
        if let Some(provider) = &provider_only {
            let found = match provider.as_str() {
                "claude" => {
                    claude_resolver::session_candidates(root.home(), &directory.to_string_lossy())
                }
                "codex" => crate::monitoring::codex_sessions::session_candidates_with_limit(
                    root.home(),
                    &directory.to_string_lossy(),
                    reference,
                    14,
                )
                .into_iter()
                .map(
                    |(session_id, touched_at)| crate::ai::resume::SessionCandidate {
                        session_id,
                        touched_at,
                    },
                )
                .collect(),
                _ => Vec::new(),
            };
            let available: Vec<_> = found
                .into_iter()
                .filter(|m| !claims.contains(&(provider.clone(), m.session_id.clone())))
                .collect();
            if let Some(id) = crate::ai::resume::best_session_match(&available, reference) {
                resume_candidates.push(ResumeIdentity {
                    provider: provider.clone(),
                    session_id: id,
                });
            }
        }
        let identity = resume_candidates.into_iter().find_map(|m| {
            let valid = validate(
                root.home(),
                &m,
                &directory,
                reference,
                synthetic,
                &mut codex,
            )?;
            claims
                .insert((valid.provider.clone(), valid.session_id.clone()))
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
        let context = read_context(root, pane);
        pane.directory = Some(directory.to_string_lossy().into_owned());
        pane.ai_provider = identity
            .as_ref()
            .map(|m| m.provider.clone())
            .or(provider_only);
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
            },
        );
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
    fn command_priority_and_every_split_pane_match_current_swift_restore() {
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
            "command-id"
        );
        assert_eq!(
            prepared.panes[&2].identity.as_ref().unwrap().session_id,
            "launch-id"
        );
        assert_eq!(prepared.saved.focused_pane, Some(2));
        assert_eq!(
            prepared.saved.layout.as_ref().unwrap().terminal_ids(),
            vec![1, 2]
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
    fn provider_only_discovery_is_scoped_and_uses_actual_saved_reference() {
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
        assert_eq!(
            prepared.panes[&1].identity.as_ref().unwrap().provider,
            "claude"
        );
        assert_eq!(
            prepared.panes[&1].identity.as_ref().unwrap().session_id,
            "nearest"
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
