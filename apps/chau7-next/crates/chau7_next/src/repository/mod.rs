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

use std::collections::HashMap;
use std::path::Path;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

use chau7_next_core::repo_metadata::{self, RepoMetadata};
use chau7_next_core::repository::{AiRepoStats, RepoProbe, RepoStats, RepositoryCache};
use gpui::{App, Global};
use parking_lot::Mutex;

use crate::platform::process as procinfo;

/// Stats are recomputed at most this often per repository.
const STATS_TTL: Duration = Duration::from_secs(5);

/// Supplies the AI half of the stats (runs, tokens, cost) for a repository
/// root, from the telemetry store (`seams::init` plugs it in with
/// [`set_ai_stats_provider`]).
pub type AiStatsProvider = Arc<dyn Fn(&str) -> AiRepoStats + Send + Sync>;

/// `git` knowledge from `.git` reads (no subprocess).
struct GitProbe;

impl RepoProbe for GitProbe {
    fn find_root(&self, path: &str) -> Option<String> {
        procinfo::git_root(Path::new(path)).map(|p| p.to_string_lossy().to_string())
    }

    fn read_branch(&self, root: &str) -> Option<String> {
        procinfo::git_branch(Path::new(root))
    }
}

#[derive(Default)]
struct Inner {
    cache: RepositoryCache,
    stats: HashMap<String, (Instant, RepoStats)>,
    ai: Option<AiStatsProvider>,
}

/// The repository registry.
pub struct Repositories {
    inner: Mutex<Inner>,
    quitting: AtomicBool,
}

impl Global for Repositories {}

fn registry(cx: &App) -> Option<&Repositories> {
    cx.try_global::<Repositories>()
}

/// Set up the registry and the timer that writes edited metadata.
pub fn init(cx: &mut App) {
    cx.set_global(Repositories {
        inner: Mutex::new(Inner::default()),
        quitting: AtomicBool::new(false),
    });
    cx.spawn(async move |cx| {
        loop {
            cx.background_executor()
                .timer(Duration::from_millis(250))
                .await;
            let (data, saves) = cx.update(|cx| {
                (
                    cx.global::<crate::workspace::AppData>().root.clone(),
                    registry(cx)
                        .map(|r| r.inner.lock().cache.take_due_saves(Instant::now()))
                        .unwrap_or_default(),
                )
            });
            write_saves(&data, saves);
        }
    })
    .detach();
}

fn write_saves(data: &chau7_next_core::data_root::DataRoot, saves: Vec<(String, RepoMetadata)>) {
    for (root, metadata) in saves {
        if let Err(err) = repo_metadata::save(data, Path::new(&root), &metadata) {
            log::warn!("repo metadata for {root}: {err}");
        }
    }
}

/// Write every pending edit now (at quit).
pub fn flush(cx: &App) {
    if let Some(r) = registry(cx) {
        r.quitting.store(true, Ordering::Relaxed);
        let saves = r.inner.lock().cache.take_all_saves();
        write_saves(&cx.global::<crate::workspace::AppData>().root, saves);
    }
}

/// The repository root containing `dir`, creating its model the first time.
/// A new repository has its metadata loaded and is added to the recent list.
pub fn resolve(dir: &Path, cx: &App) -> Option<String> {
    let r = registry(cx)?;
    let resolved = r
        .inner
        .lock()
        .cache
        .resolve(&dir.to_string_lossy(), &GitProbe)?;
    if resolved.is_new {
        let data = &cx.global::<crate::workspace::AppData>().root;
        let metadata = repo_metadata::load(data, Path::new(&resolved.root));
        if let Some(model) = r.inner.lock().cache.model_mut(&resolved.root) {
            model.adopt_metadata(metadata);
        }
        crate::settings_window::record_recent_repo(&resolved.root, cx);
    }
    Some(resolved.root)
}

/// The shared branch of a repository, read again from `.git/HEAD`.
pub fn branch(root: &str, cx: &App) -> Option<String> {
    let r = registry(cx)?;
    let mut inner = r.inner.lock();
    inner.cache.refresh_branch(root, &GitProbe);
    inner.cache.branch(root)
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
    if let Some(r) = registry(cx)
        && let Some(model) = r.inner.lock().cache.model_mut(root)
    {
        model.adopt_metadata(metadata);
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
