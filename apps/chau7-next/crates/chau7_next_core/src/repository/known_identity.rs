//! Persistent repository identity evidence, independent of live filesystem access.
//! Mirrors KnownRepoIdentityStore + KnownRepoRootResolver on current Swift.
use crate::data_root::DataRoot;
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use std::collections::HashSet;
use std::io::Read;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Condvar, Mutex};
use std::time::{Duration, Instant};

pub const MAX_IDENTITIES: usize = 50;
const DEBOUNCE: Duration = Duration::from_millis(500);

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct KnownRepoIdentity {
    pub root_path: String,
    /// None represents an unconfirmed bootstrap identity (Swift distantPast).
    pub last_confirmed_at: Option<DateTime<Utc>>,
    pub last_known_branch: Option<String>,
}
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct KnownRepoIdentities {
    identities: Vec<KnownRepoIdentity>,
}

/// Lexical normalization: never canonicalize or probe a protected folder.
pub fn normalize_root(path: &str) -> Option<String> {
    if path.trim().is_empty() {
        return None;
    }
    let path = Path::new(path);
    let absolute = if path.has_root() {
        path.to_path_buf()
    } else {
        std::env::current_dir().ok()?.join(path)
    };
    let mut result = PathBuf::new();
    for component in absolute.components() {
        use std::path::Component;
        match component {
            Component::CurDir => {}
            Component::ParentDir => {
                result.pop();
            }
            component => result.push(component.as_os_str()),
        }
    }
    #[cfg(windows)]
    let normalized = result.to_string_lossy().replace('\\', "/");
    #[cfg(not(windows))]
    let normalized = result.to_string_lossy().into_owned();
    Some(normalized)
}
pub fn branch_name(branch: Option<&str>) -> Option<String> {
    let branch = branch?.trim();
    (!branch.is_empty() && branch != "HEAD").then(|| branch.to_owned())
}
pub fn resolve_root(directory: &str, preferred: Option<&str>, roots: &[String]) -> Option<String> {
    let directory = normalize_root(directory)?;
    if let Some(root) = preferred.and_then(normalize_root)
        && Path::new(&directory).starts_with(&root)
    {
        return Some(root);
    }
    roots
        .iter()
        .filter_map(|root| normalize_root(root))
        .filter(|root| Path::new(&directory).starts_with(root))
        .max_by_key(|root| root.len())
}
impl KnownRepoIdentities {
    pub fn all(&self) -> &[KnownRepoIdentity] {
        &self.identities
    }
    pub fn roots(&self) -> Vec<String> {
        self.identities
            .iter()
            .map(|item| item.root_path.clone())
            .collect()
    }
    pub fn identity(&self, root: &str) -> Option<&KnownRepoIdentity> {
        let root = normalize_root(root)?;
        self.identities.iter().find(|item| item.root_path == root)
    }
    pub fn resolve(&self, path: &str) -> Option<&KnownRepoIdentity> {
        self.identity(&resolve_root(path, None, &self.roots())?)
    }
    pub fn has_beneath(&self, path: &str) -> bool {
        let Some(path) = normalize_root(path) else {
            return false;
        };
        self.identities
            .iter()
            .any(|item| Path::new(&item.root_path).starts_with(&path))
    }
    pub fn record(
        &mut self,
        root: &str,
        branch: Option<&str>,
        confirmed_at: Option<DateTime<Utc>>,
        preserve_existing_branch: bool,
    ) {
        let Some(root) = normalize_root(root) else {
            return;
        };
        let previous = self
            .identity(&root)
            .and_then(|item| item.last_known_branch.clone());
        let preserve = preserve_existing_branch && branch.map(str::trim) != Some("HEAD");
        let branch = branch_name(branch).or_else(|| preserve.then_some(previous).flatten());
        self.identities.retain(|item| item.root_path != root);
        self.identities.insert(
            0,
            KnownRepoIdentity {
                root_path: root,
                last_known_branch: branch,
                last_confirmed_at: confirmed_at,
            },
        );
        self.identities.truncate(MAX_IDENTITIES);
    }
    pub fn restore(&mut self, identities: impl IntoIterator<Item = KnownRepoIdentity>) {
        let mut seen = HashSet::new();
        self.identities = identities
            .into_iter()
            .filter_map(|mut item| {
                item.root_path = normalize_root(&item.root_path)?;
                if !seen.insert(item.root_path.clone()) {
                    return None;
                }
                item.last_known_branch = branch_name(item.last_known_branch.as_deref());
                Some(item)
            })
            .take(MAX_IDENTITIES)
            .collect();
    }
    pub fn replace_all(&mut self, roots: &[String]) {
        self.restore(roots.iter().map(|root| KnownRepoIdentity {
            root_path: root.clone(),
            last_confirmed_at: None,
            last_known_branch: None,
        }));
    }
    pub fn merge_recent_roots(&mut self, roots: &[String]) {
        let mut result = Self::default();
        result.replace_all(roots);
        for item in &mut result.identities {
            if let Some(existing) = self.identity(&item.root_path) {
                *item = existing.clone();
            }
        }
        let roots = result.roots();
        result.identities.extend(
            self.identities
                .iter()
                .filter(|item| !roots.contains(&item.root_path))
                .cloned(),
        );
        result.identities.truncate(MAX_IDENTITIES);
        *self = result;
    }
    pub fn clear(&mut self) {
        self.identities.clear();
    }
    /// Merge confirmed observations made while an initial disk snapshot loaded.
    /// Loaded metadata survives observations with no available branch.
    pub fn overlay_observations(&mut self, observations: &Self) {
        for item in observations.all().iter().rev() {
            self.record(
                &item.root_path,
                item.last_known_branch.as_deref(),
                item.last_confirmed_at,
                true,
            );
        }
    }
}

pub fn load(root: &DataRoot, bootstrap_roots: &[String]) -> Result<KnownRepoIdentities, String> {
    let path = root.known_repo_identities_file();
    let file = match std::fs::File::open(&path) {
        Ok(file) => file,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            let mut list = KnownRepoIdentities::default();
            list.replace_all(bootstrap_roots);
            return Ok(list);
        }
        Err(error) => return Err(error.to_string()),
    };
    let mut bytes = Vec::new();
    file.take(4 * 1024 * 1024 + 1)
        .read_to_end(&mut bytes)
        .map_err(|error| error.to_string())?;
    if bytes.len() > 4 * 1024 * 1024 {
        return Err("Known repository identity file exceeds 4 MiB".into());
    }
    let decoded: Vec<KnownRepoIdentity> =
        serde_json::from_slice(&bytes).map_err(|error| error.to_string())?;
    let mut list = KnownRepoIdentities::default();
    list.restore(decoded);
    Ok(list)
}

/// One serial bounded writer coalesces snapshots; reset cancels pending writes.
/// Disk work and serialization happen entirely on its worker thread.
pub struct IdentityWriter {
    shared: Arc<(Mutex<Pending>, Condvar)>,
}
struct Pending {
    snapshot: Option<Option<KnownRepoIdentities>>,
    deadline: Instant,
    generation: u64,
    writing: bool,
    closed: bool,
    error: Option<String>,
}
impl IdentityWriter {
    pub fn new(root: DataRoot) -> Self {
        let shared = Arc::new((
            Mutex::new(Pending {
                snapshot: None,
                deadline: Instant::now(),
                generation: 0,
                writing: false,
                closed: false,
                error: None,
            }),
            Condvar::new(),
        ));
        let worker = shared.clone();
        std::thread::spawn(move || {
            let (lock, changed) = &*worker;
            loop {
                let (snapshot, generation) = {
                    let mut state = lock.lock().unwrap();
                    loop {
                        if state.snapshot.is_some()
                            && (state.closed || state.deadline <= Instant::now())
                        {
                            break;
                        }
                        if state.closed {
                            return;
                        }
                        if state.snapshot.is_some() {
                            let delay = state.deadline.saturating_duration_since(Instant::now());
                            state = changed.wait_timeout(state, delay).unwrap().0;
                        } else {
                            state = changed.wait(state).unwrap();
                        }
                    }
                    state.writing = true;
                    (state.snapshot.take().unwrap(), state.generation)
                };
                let result = if generation != lock.lock().unwrap().generation {
                    Ok(())
                } else {
                    let path = root.known_repo_identities_file();
                    match snapshot {
                        Some(list) => {
                            crate::injection_rules::atomic_json(&path, root.state_dir(), list.all())
                        }
                        None => {
                            crate::injection_rules::validate_owned_path(&path, root.state_dir())
                                .and_then(|()| match std::fs::remove_file(path) {
                                    Ok(()) => Ok(()),
                                    Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                                        Ok(())
                                    }
                                    Err(error) => Err(error.to_string()),
                                })
                        }
                    }
                };
                let mut state = lock.lock().unwrap();
                if let Err(error) = result {
                    log::warn!("Known repository identity persistence: {error}");
                    state.error = Some(error);
                }
                state.writing = false;
                changed.notify_all();
            }
        });
        Self { shared }
    }
    pub fn save(&self, identities: KnownRepoIdentities) {
        let mut state = self.shared.0.lock().unwrap();
        state.snapshot = Some(Some(identities));
        state.deadline = Instant::now() + DEBOUNCE;
        self.shared.1.notify_all();
    }
    pub fn reset(&self) {
        let mut state = self.shared.0.lock().unwrap();
        state.generation = state.generation.wrapping_add(1);
        state.snapshot = Some(None);
        state.deadline = Instant::now();
        self.shared.1.notify_all();
    }
    pub fn flush(&self) {
        let mut state = self.shared.0.lock().unwrap();
        state.deadline = Instant::now();
        self.shared.1.notify_all();
        while state.snapshot.is_some() || state.writing {
            state = self.shared.1.wait(state).unwrap();
        }
    }
    pub fn take_error(&self) -> Option<String> {
        self.shared.0.lock().unwrap().error.take()
    }
}
impl Drop for IdentityWriter {
    fn drop(&mut self) {
        let mut state = self.shared.0.lock().unwrap();
        state.closed = true;
        self.shared.1.notify_all();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn normalization_dedup_limits_and_first_metadata_win() {
        let mut list = KnownRepoIdentities::default();
        let items = (0..70).map(|n| KnownRepoIdentity {
            root_path: format!("/repos/{n}/./"),
            last_confirmed_at: None,
            last_known_branch: Some(" main ".into()),
        });
        list.restore(items.chain([KnownRepoIdentity {
            root_path: "/repos/0".into(),
            last_confirmed_at: Some(Utc::now()),
            last_known_branch: Some("other".into()),
        }]));
        assert_eq!(list.all().len(), 50);
        assert_eq!(list.all()[0].root_path, "/repos/0");
        assert_eq!(list.all()[0].last_known_branch.as_deref(), Some("main"));
    }
    #[test]
    fn record_preserves_missing_branch_but_clears_detached_head() {
        let mut list = KnownRepoIdentities::default();
        let now = Utc::now();
        list.record("/a", Some("main"), Some(now), true);
        list.record("/b", Some("other"), None, true);
        list.record("/a/./", None, Some(now), true);
        assert_eq!(list.roots(), ["/a", "/b"]);
        assert_eq!(
            list.identity("/a").unwrap().last_known_branch.as_deref(),
            Some("main")
        );
        list.record("/a", Some(" HEAD "), Some(now), true);
        assert_eq!(list.identity("/a").unwrap().last_known_branch, None);
        list.record("/a", Some("main"), Some(now), true);
        list.record("/a", None, Some(now), false);
        assert_eq!(list.identity("/a").unwrap().last_known_branch, None);
    }
    #[test]
    fn merge_and_replace_preserve_the_correct_metadata_and_order() {
        let mut list = KnownRepoIdentities::default();
        let now = Utc::now();
        list.record("/a", Some("main"), Some(now), true);
        list.record("/b", Some("feature"), Some(now), true);
        list.merge_recent_roots(&["/a/".into(), "/new".into(), "/a".into()]);
        assert_eq!(list.roots(), ["/a", "/new", "/b"]);
        assert_eq!(list.identity("/a").unwrap().last_confirmed_at, Some(now));
        assert_eq!(list.identity("/new").unwrap().last_confirmed_at, None);
        list.replace_all(&["/a".into()]);
        assert_eq!(list.identity("/a").unwrap().last_known_branch, None);
    }
    #[test]
    fn longest_boundary_and_preferred_roots_work_without_probes() {
        let mut list = KnownRepoIdentities::default();
        list.replace_all(&["/repo".into(), "/repo/nested".into(), "/repo-long".into()]);
        assert_eq!(
            list.resolve("/repo/nested/sub").unwrap().root_path,
            "/repo/nested"
        );
        assert!(list.resolve("/repository").is_none());
        assert_eq!(
            resolve_root("/repo/nested/sub", Some("/repo"), &list.roots()),
            Some("/repo".into())
        );
        assert!(list.has_beneath("/repo"));
        assert!(!list.has_beneath("/rep"));
    }
    #[test]
    fn persistent_snapshots_coalesce_and_reset_cannot_resurrect_them() {
        let temp = std::env::temp_dir().join(format!("c7n-identities-{}", uuid::Uuid::new_v4()));
        let root = DataRoot::with_home(temp.clone(), true);
        let writer = IdentityWriter::new(root.clone());
        let mut list = KnownRepoIdentities::default();
        for n in 0..100 {
            list.record(&format!("/repo/{n}"), Some("main"), Some(Utc::now()), true);
            writer.save(list.clone());
        }
        writer.flush();
        assert_eq!(load(&root, &[]).unwrap(), list);
        writer.save(list);
        writer.reset();
        writer.flush();
        assert!(!root.known_repo_identities_file().exists());
        writer.flush();
        assert!(!root.known_repo_identities_file().exists());
        drop(writer);
        std::fs::remove_dir_all(temp).unwrap();
    }
    #[test]
    fn bootstrap_and_live_observations_keep_confirmed_metadata() {
        let mut list = KnownRepoIdentities::default();
        list.record("/a", Some("main"), Some(Utc::now()), true);
        let mut observations = KnownRepoIdentities::default();
        observations.record("/a", None, Some(Utc::now()), true);
        observations.record("/new", Some("topic"), Some(Utc::now()), true);
        list.overlay_observations(&observations);
        assert_eq!(list.roots(), ["/new", "/a"]);
        assert_eq!(
            list.identity("/a").unwrap().last_known_branch.as_deref(),
            Some("main")
        );
    }
}
