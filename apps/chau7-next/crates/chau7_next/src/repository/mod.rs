//! Shared repository state (`Repository/RepositoryCache.swift`,
//! `RepositoryModel.swift`, `RepoStats.swift`).
//!
//! Every tab in a repository reads the same model: one branch, one set of
//! metadata (description, labels, favorite files) and one stats block. The
//! cache lives in `chau7_next_core::repository`; this module adds the git
//! probe, the global, the metadata saves and the stats. Cross-tab file conflicts are
//! detected by `crate::ai::hub` (one detector, keyed by tab).
//!
//! All access goes through one mutex so the hover card can read from `&App`.

use std::collections::{BTreeMap, HashMap, HashSet};
use std::path::Path;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

use chau7_next_core::repo_metadata::{self, RepoMetadata};
use chau7_next_core::repository::known_identity::{self, IdentityWriter, KnownRepoIdentities};
use chau7_next_core::repository::{AiRepoStats, RepoProbe, RepoStats, RepositoryCache};
use chrono::Utc;
use gpui::{App, Global};
use parking_lot::{Condvar, Mutex};

use crate::platform::process as procinfo;

/// Stats are recomputed at most this often per repository.
const STATS_TTL: Duration = Duration::from_secs(5);

/// Supplies the AI half of the stats (runs, tokens, cost) for a repository
/// root, from the telemetry store (`seams::init` plugs it in with
/// [`set_ai_stats_provider`]).
pub type AiStatsProvider = Arc<dyn Fn(&str) -> AiRepoStats + Send + Sync>;

/// Git results captured off the UI thread, then applied under a short lock.
struct CapturedProbe {
    root: Option<String>,
    branch: Option<String>,
}
impl RepoProbe for CapturedProbe {
    fn find_root(&self, _: &str) -> Option<String> {
        self.root.clone()
    }
    fn read_branch(&self, _: &str) -> Option<String> {
        self.branch.clone()
    }
}

#[derive(Default)]
struct Inner {
    cache: RepositoryCache,
    identities: KnownRepoIdentities,
    metadata_loaded: HashSet<String>,
    metadata_overrides: HashMap<String, RepoMetadata>,
    last_probe: HashMap<String, Instant>,
    in_flight: HashSet<String>,
    stats: HashMap<String, (Instant, RepoStats)>,
    ai: Option<AiStatsProvider>,
    /// Shell OSC9 reports fence filesystem probes captured before them.
    shell_report_generation: u64,
    history_generation: u64,
}
impl Inner {
    fn report_shell_root(&mut self, root: &str, branch: Option<&str>) -> Option<String> {
        let root = root.trim();
        if !Path::new(root).is_absolute() {
            return None;
        }
        let root = known_identity::normalize_root(root)?;
        let branch = known_identity::branch_name(branch);
        self.shell_report_generation = self.shell_report_generation.wrapping_add(1);
        self.cache.forget_path_resolution(&root);
        self.cache.resolve(
            &root,
            &CapturedProbe {
                root: Some(root.clone()),
                branch: branch.clone(),
            },
        );
        self.cache.set_branch(&root, branch.clone());
        self.identities
            .record(&root, branch.as_deref(), Some(Utc::now()), false);
        Some(root)
    }

    fn accepts_probe(&self, captured_generation: u64) -> bool {
        captured_generation == self.shell_report_generation
    }
}

#[derive(Default)]
struct Jobs {
    probes: BTreeMap<String, u64>,
    metadata: BTreeMap<String, RepoMetadata>,
    recent: Vec<(u64, String)>,
    reset_recent: bool,
    writing: bool,
    closed: bool,
}
impl Jobs {
    fn is_empty(&self) -> bool {
        self.probes.is_empty()
            && self.metadata.is_empty()
            && self.recent.is_empty()
            && !self.reset_recent
    }
}

/// The repository registry.
pub struct Repositories {
    inner: Arc<Mutex<Inner>>,
    jobs: Arc<(Mutex<Jobs>, Condvar)>,
    identity_writer: Arc<IdentityWriter>,
    quitting: AtomicBool,
}

impl Global for Repositories {}

fn registry(cx: &App) -> Option<&Repositories> {
    cx.try_global::<Repositories>()
}

/// Set up the registry and the timer that writes edited metadata.
pub fn init(cx: &mut App) {
    let root = cx.global::<crate::workspace::AppData>().root.clone();
    let inner = Arc::new(Mutex::new(Inner::default()));
    let jobs = Arc::new((Mutex::new(Jobs::default()), Condvar::new()));
    let identity_writer = Arc::new(IdentityWriter::new(root.clone()));
    cx.set_global(Repositories {
        inner: inner.clone(),
        jobs: jobs.clone(),
        identity_writer: identity_writer.clone(),
        quitting: AtomicBool::new(false),
    });
    std::thread::spawn(move || worker(root, inner, jobs, identity_writer));
    let timer = crate::observability::register_timer(
        cx,
        "repository.persistence",
        "Repository metadata persistence",
        "repository",
        250,
    );
    cx.spawn(async move |cx| {
        let _timer = timer;
        loop {
            cx.background_executor()
                .timer(Duration::from_millis(250))
                .await;
            cx.update(|cx| {
                if let Some(registry) = registry(cx) {
                    let saves = registry.inner.lock().cache.take_due_saves(Instant::now());
                    if !saves.is_empty() {
                        registry.jobs.0.lock().metadata.extend(saves);
                        registry.jobs.1.notify_one();
                    }
                }
            });
        }
    })
    .detach();
}

/// Actual branch evidence distinguishes detached HEAD from a hex-named branch.
fn branch_evidence(root: &Path) -> Option<(Option<String>, String)> {
    if crate::protected_paths::should_skip(root) {
        return None;
    }
    let dot_git = root.join(".git");
    let directory = if dot_git.is_file() {
        let text = std::fs::read_to_string(&dot_git).ok()?;
        let target = Path::new(text.trim().strip_prefix("gitdir:")?.trim());
        if target.is_absolute() {
            target.to_path_buf()
        } else {
            root.join(target)
        }
    } else {
        dot_git
    };
    if crate::protected_paths::should_skip(&directory) {
        return None;
    }
    let head = std::fs::read_to_string(directory.join("HEAD")).ok()?;
    let head = head.trim();
    if let Some(reference) = head.strip_prefix("ref:") {
        let branch = reference
            .trim()
            .strip_prefix("refs/heads/")
            .unwrap_or(reference.trim());
        Some((Some(branch.into()), branch.into()))
    } else if !head.is_empty() {
        Some((None, "HEAD".into()))
    } else {
        None
    }
}

fn worker(
    root: chau7_next_core::data_root::DataRoot,
    inner: Arc<Mutex<Inner>>,
    jobs: Arc<(Mutex<Jobs>, Condvar)>,
    identities: Arc<IdentityWriter>,
) {
    let bootstrap = !root.known_repo_identities_file().exists();
    let recent = repo_metadata::load_recent(&root.recent_repos_file());
    let loaded = known_identity::load(&root, &recent).unwrap_or_else(|error| {
        log::warn!("Known repository identity load: {error}");
        let mut list = KnownRepoIdentities::default();
        list.replace_all(&recent);
        list
    });
    {
        let mut state = inner.lock();
        // Shell observations made during disk bootstrap remain authoritative,
        // including an explicit detached-HEAD branch cleared to None.
        let loaded = if state.history_generation == 0 {
            loaded
        } else {
            KnownRepoIdentities::default()
        };
        let observed = state.identities.clone();
        let observed_roots = observed.roots();
        state.identities.restore(
            observed
                .all()
                .iter()
                .chain(
                    loaded
                        .all()
                        .iter()
                        .filter(|item| !observed_roots.contains(&item.root_path)),
                )
                .cloned(),
        );
        let merged = state.identities.clone();
        state.cache.adopt_known_identities(&merged);
        if bootstrap || state.shell_report_generation != 0 {
            identities.save(merged);
        }
    }
    loop {
        let (probes, metadata, recent, reset_recent) = {
            let mut pending = jobs.0.lock();
            while pending.is_empty() && !pending.closed {
                jobs.1.wait(&mut pending);
            }
            if pending.is_empty() && pending.closed {
                return;
            }
            pending.writing = true;
            (
                std::mem::take(&mut pending.probes),
                std::mem::take(&mut pending.metadata),
                std::mem::take(&mut pending.recent),
                std::mem::take(&mut pending.reset_recent),
            )
        };
        write_saves(&root, metadata.into_iter().collect());
        if reset_recent
            && let Err(error) = repo_metadata::save_recent(&root.recent_repos_file(), &[])
        {
            log::warn!("Recent repository reset: {error}");
        }
        if !recent.is_empty() {
            let mut saved = repo_metadata::load_recent(&root.recent_repos_file());
            let mut changed = false;
            {
                let mut state = inner.lock();
                for (generation, path) in recent {
                    if generation != state.history_generation {
                        continue;
                    }
                    repo_metadata::record_recent(&mut saved, &path);
                    state.identities.record(&path, None, Some(Utc::now()), true);
                    changed = true;
                }
                if changed {
                    identities.save(state.identities.clone());
                }
            }
            if changed
                && let Err(error) = repo_metadata::save_recent(&root.recent_repos_file(), &saved)
            {
                log::warn!("Recent repository persistence: {error}");
            }
        }
        for (path, history_generation) in probes {
            let captured_generation = {
                let mut state = inner.lock();
                if state.history_generation != history_generation {
                    state.in_flight.remove(&path);
                    continue;
                }
                state.shell_report_generation
            };
            // Filesystem work runs before acquiring the shared state lock.
            let found = procinfo::git_root(Path::new(&path))
                .map(|root| root.to_string_lossy().into_owned());
            let evidence = found
                .as_deref()
                .and_then(|root| branch_evidence(Path::new(root)));
            let metadata = found.as_deref().and_then(|repo| {
                let should_load = !inner.lock().metadata_loaded.contains(repo);
                should_load.then(|| repo_metadata::load(&root, Path::new(repo)))
            });
            let confirmed = {
                let mut state = inner.lock();
                if !state.accepts_probe(captured_generation) {
                    state.in_flight.remove(&path);
                    continue;
                }
                if let Some(repo) = &found {
                    state.cache.forget_path_resolution(&path);
                    let branch = match &evidence {
                        Some((display, _)) => display.clone(),
                        None => state
                            .identities
                            .identity(repo)
                            .and_then(|item| item.last_known_branch.clone()),
                    };
                    state.cache.resolve(
                        &path,
                        &CapturedProbe {
                            root: Some(repo.clone()),
                            branch,
                        },
                    );
                    if let Some(metadata) = metadata
                        && state.metadata_loaded.insert(repo.clone())
                    {
                        // An explicit editor save while disk reads ran takes precedence.
                        let metadata = state
                            .metadata_overrides
                            .get(repo)
                            .cloned()
                            .unwrap_or(metadata);
                        if let Some(model) = state.cache.model_mut(repo) {
                            model.adopt_metadata(metadata);
                        }
                    }
                    state.identities.record(
                        repo,
                        evidence.as_ref().map(|(_, raw)| raw.as_str()),
                        Some(Utc::now()),
                        true,
                    );
                    // Queue while the state lock still orders writers, so an
                    // older clone cannot enqueue after a newer shell report.
                    identities.save(state.identities.clone());
                    true
                } else {
                    // An unavailable protected or deleted root preserves saved evidence.
                    if state.cache.cached_root(&path).is_none() {
                        state.cache.resolve(
                            &path,
                            &CapturedProbe {
                                root: None,
                                branch: None,
                            },
                        );
                    }
                    false
                }
            };
            if confirmed && let Some(repo) = found {
                let state = inner.lock();
                if state.accepts_probe(captured_generation) {
                    enqueue_recent(&jobs, repo, state.history_generation);
                }
            }
            inner.lock().in_flight.remove(&path);
        }
        if let Some(error) = identities.take_error() {
            log::warn!("Repository identity writer: {error}");
        }
        let mut pending = jobs.0.lock();
        pending.writing = false;
        jobs.1.notify_all();
    }
}
fn write_saves(data: &chau7_next_core::data_root::DataRoot, saves: Vec<(String, RepoMetadata)>) {
    for (root, metadata) in saves {
        if let Err(err) = repo_metadata::save(data, Path::new(&root), &metadata) {
            log::warn!("repo metadata for {root}: {err}");
        }
    }
}
fn enqueue_recent(jobs: &(Mutex<Jobs>, Condvar), root: String, generation: u64) {
    let mut pending = jobs.0.lock();
    pending.recent.retain(|(_, path)| path != &root);
    pending.recent.push((generation, root));
    if pending.recent.len() > known_identity::MAX_IDENTITIES {
        pending.recent.remove(0);
    }
    jobs.1.notify_one();
}
/// Remember a root on the same serial worker, avoiding concurrent read/write races.
pub fn record_recent(root: &str, cx: &App) {
    if let Some(registry) = registry(cx) {
        let state = registry.inner.lock();
        enqueue_recent(&registry.jobs, root.into(), state.history_generation);
    }
}
/// Explicit settings reset only: fence queued and in-flight observations while
/// the existing serial worker clears the owned recent-repository file.
pub fn reset_discovered_repositories(cx: &App) {
    if let Some(registry) = registry(cx) {
        reset_registry(registry);
    }
}

fn reset_registry(registry: &Repositories) {
    let mut state = registry.inner.lock();
    state.history_generation = state.history_generation.wrapping_add(1);
    state.shell_report_generation = state.shell_report_generation.wrapping_add(1);
    state.identities.clear();
    state.last_probe.clear();
    state.in_flight.clear();
    registry.identity_writer.reset();
    let mut jobs = registry.jobs.0.lock();
    jobs.recent.clear();
    jobs.probes.clear();
    jobs.reset_recent = true;
    registry.jobs.1.notify_one();
}

/// Up to fifty durable identities, rather than the twenty-item recent list.
pub fn known_roots(cx: &App) -> Vec<String> {
    registry(cx)
        .map(|registry| registry.inner.lock().identities.roots())
        .unwrap_or_default()
}
/// Queue an explicit settings edit without filesystem work on the UI thread.
pub fn save_metadata(root: &str, metadata: RepoMetadata, cx: &App) {
    adopt_metadata(root, metadata.clone(), cx);
    if let Some(registry) = registry(cx) {
        registry
            .jobs
            .0
            .lock()
            .metadata
            .insert(root.into(), metadata);
        registry.jobs.1.notify_one();
    }
}

/// Drain pending metadata and identity writes at quit, after ordinary UI work ends.
pub fn flush(cx: &App) {
    if let Some(registry) = registry(cx) {
        registry.quitting.store(true, Ordering::Relaxed);
        let saves = registry.inner.lock().cache.take_all_saves();
        let mut jobs = registry.jobs.0.lock();
        jobs.metadata.extend(saves);
        jobs.probes.clear();
        jobs.closed = true;
        registry.jobs.1.notify_all();
        while !jobs.is_empty() || jobs.writing {
            registry.jobs.1.wait(&mut jobs);
        }
        drop(jobs);
        registry.identity_writer.flush();
    }
}

/// Read saved identity immediately, and schedule bounded live reconciliation.
pub fn resolve(dir: &Path, cx: &App) -> Option<String> {
    let registry = registry(cx)?;
    let path = known_identity::normalize_root(&dir.to_string_lossy())?;
    let mut state = registry.inner.lock();
    let known = state.cache.cached_root(&path);
    if !registry.quitting.load(Ordering::Relaxed)
        && !crate::protected_paths::should_skip(dir)
        && !state.in_flight.contains(&path)
        && state.in_flight.len() < 64
        && state
            .last_probe
            .get(&path)
            .is_none_or(|last| last.elapsed() >= Duration::from_secs(2))
    {
        state.in_flight.insert(path.clone());
        if state.last_probe.len() >= 256
            && let Some(oldest) = state
                .last_probe
                .iter()
                .min_by_key(|(_, last)| **last)
                .map(|(path, _)| path.clone())
        {
            state.last_probe.remove(&oldest);
        }
        state.last_probe.insert(path.clone(), Instant::now());
        registry
            .jobs
            .0
            .lock()
            .probes
            .insert(path, state.history_generation);
        registry.jobs.1.notify_one();
    }
    known
}
/// Learn an authoritative report from this app's shell without reading the
/// reported filesystem path, including protected repositories.
pub fn report_shell_root(root: &str, branch: Option<&str>, cx: &App) -> Option<String> {
    let registry = registry(cx)?;
    let mut state = registry.inner.lock();
    let root = state.report_shell_root(root, branch)?;
    registry.identity_writer.save(state.identities.clone());
    enqueue_recent(&registry.jobs, root.clone(), state.history_generation);
    Some(root)
}

/// Shared cached branch; live filesystem reads happen on the registry worker.
pub fn branch(root: &str, cx: &App) -> Option<String> {
    registry(cx)?.inner.lock().cache.branch(root)
}

/// The metadata of a repository.
#[allow(dead_code)]
pub fn metadata(root: &str, cx: &App) -> Option<RepoMetadata> {
    registry(cx)?
        .inner
        .lock()
        .cache
        .model(root)
        .map(|m| m.metadata.clone())
}

/// The settings editor saved `metadata` to disk: share it with the tabs.
pub fn adopt_metadata(root: &str, metadata: RepoMetadata, cx: &App) {
    if let Some(registry) = registry(cx) {
        let mut state = registry.inner.lock();
        state
            .metadata_overrides
            .insert(root.into(), metadata.clone());
        if let Some(model) = state.cache.model_mut(root) {
            model.adopt_metadata(metadata);
        }
    }
}

/// Plug in the AI run numbers (runs, tokens, cost, tools) per repository.
pub fn set_ai_stats_provider(provider: AiStatsProvider, cx: &App) {
    if let Some(r) = registry(cx) {
        r.inner.lock().ai = Some(provider);
        r.inner.lock().stats.clear();
    }
}

/// Command numbers from the history store and AI numbers from the provider
/// (`RepoStatsProvider.stats`). Cached for a few seconds.
pub fn stats(root: &str, cx: &App) -> Option<RepoStats> {
    let r = registry(cx)?;
    {
        let inner = r.inner.lock();
        if let Some((at, stats)) = inner.stats.get(root)
            && at.elapsed() < STATS_TTL
        {
            return Some(stats.clone());
        }
    }
    let service = crate::history::service(cx)?;
    let (commands, last) = service.with_store(|s| {
        (
            s.command_stats_for_repo(root),
            s.last_command_timestamp_for_repo(root),
        )
    });
    let ai = r.inner.lock().ai.clone();
    let ai = ai.map(|f| f(root)).unwrap_or_default();
    let stats = RepoStats::assemble(commands, last, ai);
    let mut inner = r.inner.lock();
    if let Some(model) = inner.cache.model_mut(root) {
        model.stats = Some(stats.clone());
    }
    inner
        .stats
        .insert(root.to_string(), (Instant::now(), stats.clone()));
    Some(stats)
}

#[cfg(test)]
mod identity_tests {
    use super::*;
    #[test]
    fn shell_reports_reject_relative_roots_normalize_and_fence_stale_probes() {
        let mut state = Inner::default();
        assert!(
            state
                .report_shell_root("relative/repo", Some("main"))
                .is_none()
        );
        assert_eq!(state.shell_report_generation, 0);
        let before = state.shell_report_generation;
        let parent = std::env::temp_dir().join("protected");
        let raw = format!(" {}/./repo// ", parent.to_string_lossy());
        let root = known_identity::normalize_root(raw.trim()).unwrap();
        assert_eq!(
            state.report_shell_root(&raw, Some("12345678")),
            Some(root.clone())
        );
        assert!(!state.accepts_probe(before));
        assert_eq!(
            state.cache.cached_root(&format!("{root}/src")),
            Some(root.clone())
        );
        assert_eq!(state.cache.branch(&root), Some("12345678".into()));
        state.report_shell_root(&root, Some("HEAD"));
        assert_eq!(state.cache.branch(&root), None);
        assert_eq!(
            state.identities.identity(&root).unwrap().last_known_branch,
            None
        );
        assert!(state.accepts_probe(state.shell_report_generation));
    }

    #[test]
    fn background_registry_preserves_saved_roots_and_records_real_detachment() {
        let home = std::env::temp_dir().join(format!("c7n-registry-{}", uuid::Uuid::new_v4()));
        let data = chau7_next_core::data_root::DataRoot::with_home(home.clone(), true);
        let repo = home.join("repo");
        std::fs::create_dir_all(repo.join(".git")).unwrap();
        std::fs::write(repo.join(".git/HEAD"), "ref: refs/heads/main\n").unwrap();
        let saved_root = home.join("offline").to_string_lossy().into_owned();
        let writer = Arc::new(IdentityWriter::new(data.clone()));
        let mut saved = KnownRepoIdentities::default();
        saved.record(&saved_root, Some("remembered"), Some(Utc::now()), true);
        writer.save(saved);
        writer.flush();
        let inner = Arc::new(Mutex::new(Inner::default()));
        let jobs = Arc::new((Mutex::new(Jobs::default()), Condvar::new()));
        let worker_inner = inner.clone();
        let worker_jobs = jobs.clone();
        let worker_data = data.clone();
        let worker_writer = writer.clone();
        let thread = std::thread::spawn(move || {
            worker(worker_data, worker_inner, worker_jobs, worker_writer)
        });
        let probe = |path: String| {
            let mut pending = jobs.0.lock();
            pending.probes.insert(path, 0);
            jobs.1.notify_one();
            while !pending.is_empty() || pending.writing {
                jobs.1.wait(&mut pending);
            }
            drop(pending);
            writer.flush();
        };
        probe(repo.to_string_lossy().into_owned());
        assert_eq!(
            inner.lock().cache.branch(&saved_root).as_deref(),
            Some("remembered")
        );
        assert_eq!(
            known_identity::load(&data, &[])
                .unwrap()
                .identity(&repo.to_string_lossy())
                .unwrap()
                .last_known_branch
                .as_deref(),
            Some("main")
        );
        std::fs::write(repo.join(".git/HEAD"), "ref: refs/heads/12345678\n").unwrap();
        probe(repo.to_string_lossy().into_owned());
        assert_eq!(
            inner
                .lock()
                .cache
                .branch(&repo.to_string_lossy())
                .as_deref(),
            Some("12345678")
        );
        assert_eq!(
            known_identity::load(&data, &[])
                .unwrap()
                .identity(&repo.to_string_lossy())
                .unwrap()
                .last_known_branch
                .as_deref(),
            Some("12345678")
        );
        std::fs::write(repo.join(".git/HEAD"), "1234567890abcdef\n").unwrap();
        probe(repo.to_string_lossy().into_owned());
        assert_eq!(
            inner
                .lock()
                .cache
                .branch(&repo.to_string_lossy())
                .as_deref(),
            None
        );
        assert_eq!(
            known_identity::load(&data, &[])
                .unwrap()
                .identity(&repo.to_string_lossy())
                .unwrap()
                .last_known_branch,
            None
        );
        std::fs::remove_file(repo.join(".git/HEAD")).unwrap();
        std::fs::remove_dir(repo.join(".git")).unwrap();
        probe(repo.to_string_lossy().into_owned());
        assert!(
            inner
                .lock()
                .cache
                .cached_root(&repo.join("sub").to_string_lossy())
                .is_some()
        );
        let mut pending = jobs.0.lock();
        pending.closed = true;
        jobs.1.notify_one();
        drop(pending);
        thread.join().unwrap();
        writer.flush();
        drop(writer);
        std::fs::remove_dir_all(home).unwrap();
    }
    #[test]
    fn explicit_reset_fences_bootstrap_and_queued_history_then_accepts_new_observations() {
        let home =
            std::env::temp_dir().join(format!("c7n-registry-reset-{}", uuid::Uuid::new_v4()));
        let data = chau7_next_core::data_root::DataRoot::with_home(home.clone(), true);
        data.ensure_dirs().unwrap();
        let old_root = home.join("old").to_string_lossy().into_owned();
        let new_root = home.join("new").to_string_lossy().into_owned();
        let mut old = KnownRepoIdentities::default();
        old.record(&old_root, Some("old"), Some(Utc::now()), true);
        let persisted = IdentityWriter::new(data.clone());
        persisted.save(old);
        persisted.flush();
        drop(persisted);
        repo_metadata::save_recent(&data.recent_repos_file(), std::slice::from_ref(&old_root))
            .unwrap();
        let registry = Repositories {
            inner: Arc::new(Mutex::new(Inner::default())),
            jobs: Arc::new((Mutex::new(Jobs::default()), Condvar::new())),
            identity_writer: Arc::new(IdentityWriter::new(data.clone())),
            quitting: AtomicBool::new(false),
        };
        let before = registry.inner.lock().shell_report_generation;
        enqueue_recent(&registry.jobs, old_root.clone(), 0);
        reset_registry(&registry);
        assert!(!registry.inner.lock().accepts_probe(before));
        assert!(registry.inner.lock().identities.roots().is_empty());
        // Emulate a stale batch retained by an in-flight worker before reset.
        enqueue_recent(&registry.jobs, old_root.clone(), 0);
        std::fs::create_dir_all(Path::new(&old_root).join(".git")).unwrap();
        std::fs::write(
            Path::new(&old_root).join(".git/HEAD"),
            "ref: refs/heads/stale\n",
        )
        .unwrap();
        registry.jobs.0.lock().probes.insert(old_root.clone(), 0);
        let inner = registry.inner.clone();
        let jobs = registry.jobs.clone();
        let writer = registry.identity_writer.clone();
        let root = data.clone();
        let thread = std::thread::spawn(move || worker(root, inner, jobs, writer));
        let drain = || {
            let mut pending = registry.jobs.0.lock();
            while !pending.is_empty() || pending.writing {
                registry.jobs.1.wait(&mut pending);
            }
            drop(pending);
            registry.identity_writer.flush();
        };
        drain();
        assert!(registry.inner.lock().identities.roots().is_empty());
        assert!(repo_metadata::load_recent(&data.recent_repos_file()).is_empty());
        assert!(known_identity::load(&data, &[]).unwrap().roots().is_empty());
        {
            let mut state = registry.inner.lock();
            state.report_shell_root(&new_root, Some("fresh"));
            registry.identity_writer.save(state.identities.clone());
            enqueue_recent(&registry.jobs, new_root.clone(), state.history_generation);
        }
        drain();
        assert_eq!(
            known_identity::load(&data, &[]).unwrap().roots(),
            vec![new_root.replace('\\', "/")]
        );
        assert_eq!(
            repo_metadata::load_recent(&data.recent_repos_file()),
            vec![new_root]
        );
        registry.jobs.0.lock().closed = true;
        registry.jobs.1.notify_one();
        thread.join().unwrap();
        drop(registry);
        std::fs::remove_dir_all(home).unwrap();
    }
}
