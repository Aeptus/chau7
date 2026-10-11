//! Shared repository models (`Repository/RepositoryCache.swift`,
//! `RepositoryModel.swift`, `RepoStats.swift`).
//!
//! One [`RepoModel`] per git root, shared by every tab inside that
//! repository: a branch change seen through one tab is the branch of all of
//! them. The cache is pure: how a root and a branch are found is given by
//! the caller ([`RepoProbe`]), so it is tested without git or a file system.
//!
//! Metadata edits (`setDescription`, `addLabel`, ...) stamp `updatedAt` and
//! are saved by the caller after a quiet period of [`SAVE_DEBOUNCE`]
//! ([`RepositoryCache::take_due_saves`]); the save is atomic and removes the
//! file when the metadata is empty ([`crate::repo_metadata::save`]).

pub mod known_identity;

use std::collections::{HashMap, HashSet};
use std::time::{Duration, Instant};

use chrono::{DateTime, Utc};

use crate::history_store::CommandStats;
use crate::iso8601::now_iso8601;
use crate::repo_metadata::RepoMetadata;

/// Metadata is written this long after the last edit.
pub const SAVE_DEBOUNCE: Duration = Duration::from_millis(500);

/// How the cache learns about git (a subprocess in Swift, `.git` reads in
/// Chau7 Next).
pub trait RepoProbe {
    /// The git root containing `path` (`None` outside a repository or in a
    /// protected folder).
    fn find_root(&self, path: &str) -> Option<String>;
    /// The branch checked out at `root`.
    fn read_branch(&self, root: &str) -> Option<String>;
}

// MARK: stats

/// AI run numbers of one repository (from the telemetry store).
#[derive(Debug, Clone, Default, PartialEq)]
pub struct AiRepoStats {
    pub total_runs: i64,
    pub total_tokens: i64,
    pub total_cost: f64,
    pub total_turns: i64,
    pub last_run_at: Option<DateTime<Utc>>,
    pub providers: Vec<String>,
    /// Most called tools, most used first.
    pub top_tools: Vec<(String, i64)>,
}

/// Per-repository metrics, assembled on demand and never saved (`RepoStats`).
#[derive(Debug, Clone, Default, PartialEq)]
pub struct RepoStats {
    pub total_commands: i64,
    pub successful_commands: i64,
    pub failed_commands: i64,
    pub average_command_duration: f64,
    pub total_runs: i64,
    pub total_tokens: i64,
    pub total_cost: f64,
    pub total_turns: i64,
    pub providers: Vec<String>,
    pub top_tools: Vec<(String, i64)>,
    pub last_command_at: Option<DateTime<Utc>>,
    pub last_run_at: Option<DateTime<Utc>>,
}

impl RepoStats {
    /// `RepoStatsProvider.stats`: command numbers from the history store, AI
    /// numbers from the telemetry store.
    pub fn assemble(
        commands: CommandStats,
        last_command_at: Option<DateTime<Utc>>,
        ai: AiRepoStats,
    ) -> Self {
        Self {
            total_commands: commands.total,
            successful_commands: commands.successful,
            failed_commands: commands.failed,
            average_command_duration: commands.avg_duration,
            total_runs: ai.total_runs,
            total_tokens: ai.total_tokens,
            total_cost: ai.total_cost,
            total_turns: ai.total_turns,
            providers: ai.providers,
            top_tools: ai.top_tools,
            last_command_at,
            last_run_at: ai.last_run_at,
        }
    }

    /// Share of commands that succeeded (0 to 1).
    pub fn success_rate(&self) -> f64 {
        if self.total_commands > 0 {
            self.successful_commands as f64 / self.total_commands as f64
        } else {
            0.0
        }
    }

    /// The hover card shows the row only when there is something to say.
    pub fn has_activity(&self) -> bool {
        self.total_runs > 0 || self.total_commands > 0
    }

    /// The hover card line: `3 runs`, `12K`, `$1.20`, `45 cmds`, each left out
    /// when zero (`repoStatsParts`).
    pub fn hover_parts(&self) -> Vec<String> {
        let mut parts = Vec::new();
        if self.total_runs > 0 {
            parts.push(format!("{} runs", self.total_runs));
        }
        if self.total_tokens > 0 {
            parts.push(format_tokens(self.total_tokens));
        }
        if self.total_cost > 0.0 {
            parts.push(format!("${:.2}", self.total_cost));
        }
        if self.total_commands > 0 {
            parts.push(format!("{} cmds", self.total_commands));
        }
        parts
    }

    /// The hover card line, parts joined with ` · `.
    pub fn hover_line(&self) -> String {
        self.hover_parts().join(" \u{00b7} ")
    }

    /// The full stats as the MCP `repo_info` tool reports them.
    pub fn to_json(&self) -> serde_json::Value {
        let mut stats = serde_json::json!({
            "total_commands": self.total_commands,
            "successful_commands": self.successful_commands,
            "failed_commands": self.failed_commands,
            "success_rate": self.success_rate(),
            "avg_command_duration": self.average_command_duration,
            "total_runs": self.total_runs,
            "total_tokens": self.total_tokens,
            "total_cost": self.total_cost,
            "total_turns": self.total_turns,
            "providers": self.providers,
        });
        let map = stats.as_object_mut().expect("object");
        if !self.top_tools.is_empty() {
            map.insert(
                "top_tools".into(),
                self.top_tools
                    .iter()
                    .map(|(tool, count)| serde_json::json!({"tool": tool, "count": count}))
                    .collect(),
            );
        }
        let iso = |d: DateTime<Utc>| d.to_rfc3339_opts(chrono::SecondsFormat::Secs, true);
        if let Some(d) = self.last_command_at {
            map.insert("last_command_at".into(), iso(d).into());
        }
        if let Some(d) = self.last_run_at {
            map.insert("last_run_at".into(), iso(d).into());
        }
        stats
    }

    /// Plain text lines for the debug console and the sessions view.
    pub fn detail_lines(&self) -> Vec<String> {
        let mut lines = vec![format!(
            "Commands: {} ({} ok, {} failed, {:.0}% success, avg {})",
            self.total_commands,
            self.successful_commands,
            self.failed_commands,
            self.success_rate() * 100.0,
            format_duration(self.average_command_duration),
        )];
        lines.push(format!(
            "AI: {} runs, {} turns, {} tokens, ${:.2}",
            self.total_runs, self.total_turns, self.total_tokens, self.total_cost
        ));
        if !self.providers.is_empty() {
            lines.push(format!("Providers: {}", self.providers.join(", ")));
        }
        if !self.top_tools.is_empty() {
            let tools: Vec<String> = self
                .top_tools
                .iter()
                .map(|(tool, count)| format!("{tool} ({count})"))
                .collect();
            lines.push(format!("Top tools: {}", tools.join(", ")));
        }
        let when = |d: Option<DateTime<Utc>>| {
            d.map(|d| d.to_rfc3339_opts(chrono::SecondsFormat::Secs, true))
                .unwrap_or_else(|| "never".into())
        };
        lines.push(format!("Last command: {}", when(self.last_command_at)));
        lines.push(format!("Last AI run: {}", when(self.last_run_at)));
        lines
    }
}

/// `formatTokens` of the hover card: `1.2M`, `12K`, `999`.
pub fn format_tokens(count: i64) -> String {
    if count >= 1_000_000 {
        format!("{:.1}M", count as f64 / 1_000_000.0)
    } else if count >= 1000 {
        format!("{:.0}K", count as f64 / 1000.0)
    } else {
        count.to_string()
    }
}

fn format_duration(seconds: f64) -> String {
    if seconds < 1.0 {
        format!("{:.0}ms", seconds * 1000.0)
    } else if seconds < 60.0 {
        format!("{seconds:.1}s")
    } else {
        format!("{}m{}s", seconds as i64 / 60, seconds as i64 % 60)
    }
}

// MARK: model

/// The shared state of one repository.
#[derive(Debug, Clone, PartialEq)]
pub struct RepoModel {
    pub root: String,
    pub branch: Option<String>,
    pub metadata: RepoMetadata,
    pub stats: Option<RepoStats>,
    /// An edit waiting to be saved, with when it was made.
    dirty_since: Option<Instant>,
}

impl RepoModel {
    pub fn new(root: &str, branch: Option<String>) -> Self {
        Self {
            root: root.to_string(),
            branch,
            metadata: RepoMetadata::default(),
            stats: None,
            dirty_since: None,
        }
    }

    /// Last path component (`repoName`).
    pub fn name(&self) -> String {
        crate::repo_metadata::repo_name(&self.root)
    }

    fn touch(&mut self, now: Instant) {
        self.metadata.updated_at = Some(now_iso8601());
        self.dirty_since = Some(now);
    }

    /// Replace the metadata wholesale (`updateMetadata`).
    pub fn update_metadata(&mut self, metadata: RepoMetadata, now: Instant) {
        self.metadata = metadata;
        self.touch(now);
    }

    /// Take over metadata that was just loaded or saved elsewhere.
    pub fn adopt_metadata(&mut self, metadata: RepoMetadata) {
        self.metadata = metadata;
        self.dirty_since = None;
    }

    /// `setDescription`: an empty text clears it.
    pub fn set_description(&mut self, description: Option<&str>, now: Instant) {
        self.metadata.description = description
            .map(str::trim)
            .filter(|d| !d.is_empty())
            .map(str::to_string);
        self.touch(now);
    }

    /// `addLabel`: blanks and duplicates are ignored.
    pub fn add_label(&mut self, label: &str, now: Instant) {
        let label = label.trim();
        if label.is_empty() || self.metadata.labels.iter().any(|l| l == label) {
            return;
        }
        self.metadata.labels.push(label.to_string());
        self.touch(now);
    }

    pub fn remove_label(&mut self, label: &str, now: Instant) {
        self.metadata.labels.retain(|l| l != label);
        self.touch(now);
    }

    /// `toggleFavoriteFile`.
    pub fn toggle_favorite_file(&mut self, relative_path: &str, now: Instant) {
        let files = &mut self.metadata.favorite_files;
        if let Some(i) = files.iter().position(|f| f == relative_path) {
            files.remove(i);
        } else {
            files.push(relative_path.to_string());
        }
        self.touch(now);
    }
}

// MARK: cache

/// What [`RepositoryCache::resolve`] found.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Resolved {
    pub root: String,
    /// First time this root is seen: load its metadata, record it as a
    /// recent repository.
    pub is_new: bool,
}

/// Directories to shared repository models.
#[derive(Default)]
pub struct RepositoryCache {
    models: HashMap<String, RepoModel>,
    /// Queried path to canonical root.
    resolved: HashMap<String, String>,
    /// Paths known not to be inside a repository.
    non_git: HashSet<String>,
}

/// Remove `.` segments, doubled and trailing slashes (`standardized`).
pub fn normalize_path(path: &str) -> String {
    let absolute = path.starts_with('/');
    let mut parts: Vec<&str> = Vec::new();
    for part in path.split('/') {
        match part {
            "" | "." => {}
            ".." => {
                if parts.last().is_some_and(|p| *p != "..") {
                    parts.pop();
                } else if !absolute {
                    parts.push("..");
                }
            }
            other => parts.push(other),
        }
    }
    let joined = parts.join("/");
    if absolute {
        format!("/{joined}")
    } else {
        joined
    }
}

impl RepositoryCache {
    pub fn new() -> Self {
        Self::default()
    }

    /// Restore identity-only models without touching protected repositories.
    pub fn adopt_known_identities(&mut self, identities: &known_identity::KnownRepoIdentities) {
        for item in identities.all() {
            self.models
                .entry(item.root_path.clone())
                .or_insert_with(|| RepoModel::new(&item.root_path, item.last_known_branch.clone()));
        }
        self.reset_negative_cache();
    }

    /// A freshly observed root can replace a stale positive or negative result.
    pub fn forget_path_resolution(&mut self, path: &str) {
        let path = normalize_path(path);
        self.resolved.remove(&path);
        self.non_git.remove(&path);
    }

    /// Immediate identity-only lookup. Live probes may later discover nested roots.
    pub fn cached_root(&self, path: &str) -> Option<String> {
        let path = known_identity::normalize_root(path)?;
        self.models
            .keys()
            .filter(|root| std::path::Path::new(&path).starts_with(root))
            .max_by_key(|root| root.len())
            .cloned()
    }

    /// The model of the repository containing `path`, creating it the first
    /// time. Known paths cost no probing but refresh the branch. Returns
    /// `None` outside a repository (remembered for next time).
    pub fn resolve(&mut self, path: &str, probe: &dyn RepoProbe) -> Option<Resolved> {
        let normalized = normalize_path(path);
        if self.non_git.contains(&normalized) {
            return None;
        }
        if let Some(root) = self.resolved.get(&normalized).cloned()
            && self.models.contains_key(&root)
        {
            self.refresh_branch(&root, probe);
            return Some(Resolved {
                root,
                is_new: false,
            });
        }
        let best = self
            .models
            .keys()
            .filter(|root| normalized == **root || normalized.starts_with(&format!("{root}/")))
            .max_by_key(|root| root.len())
            .cloned();
        let Some(found) = probe.find_root(&normalized) else {
            return match best {
                Some(root) => {
                    self.resolved.insert(normalized, root.clone());
                    self.refresh_branch(&root, probe);
                    Some(Resolved {
                        root,
                        is_new: false,
                    })
                }
                None => {
                    self.non_git.insert(normalized);
                    None
                }
            };
        };
        let root = normalize_path(&found);
        let branch = probe.read_branch(&root);
        let is_new = !self.models.contains_key(&root);
        match self.models.get_mut(&root) {
            Some(model) => model.branch = branch,
            None => {
                self.models
                    .insert(root.clone(), RepoModel::new(&root, branch));
                self.resolved.insert(root.clone(), root.clone());
            }
        }
        self.resolved.insert(normalized, root.clone());
        Some(Resolved { root, is_new })
    }

    /// Re-read the branch of a repository; true when it changed.
    pub fn refresh_branch(&mut self, root: &str, probe: &dyn RepoProbe) -> bool {
        let branch = probe.read_branch(root);
        self.set_branch(root, branch)
    }

    /// Record a branch seen by one tab for every tab in that repository.
    pub fn set_branch(&mut self, root: &str, branch: Option<String>) -> bool {
        match self.models.get_mut(root) {
            Some(model) if model.branch != branch => {
                model.branch = branch;
                true
            }
            _ => false,
        }
    }

    pub fn model(&self, root: &str) -> Option<&RepoModel> {
        self.models.get(&normalize_path(root))
    }

    pub fn model_mut(&mut self, root: &str) -> Option<&mut RepoModel> {
        self.models.get_mut(&normalize_path(root))
    }

    /// Branch of a repository as the shared model has it.
    pub fn branch(&self, root: &str) -> Option<String> {
        self.model(root).and_then(|m| m.branch.clone())
    }

    /// Forget the negative results (after the user allowed protected folders).
    pub fn reset_negative_cache(&mut self) {
        self.non_git.clear();
    }

    pub fn cached_repo_count(&self) -> usize {
        self.models.len()
    }

    /// Edits older than [`SAVE_DEBOUNCE`] at `now`, ready to be written;
    /// they are marked saved.
    pub fn take_due_saves(&mut self, now: Instant) -> Vec<(String, RepoMetadata)> {
        let mut due = Vec::new();
        for model in self.models.values_mut() {
            if let Some(since) = model.dirty_since
                && now.saturating_duration_since(since) >= SAVE_DEBOUNCE
            {
                model.dirty_since = None;
                due.push((model.root.clone(), model.metadata.clone()));
            }
        }
        due
    }

    /// Every edit not saved yet, regardless of the delay (quit).
    pub fn take_all_saves(&mut self) -> Vec<(String, RepoMetadata)> {
        let far = Instant::now() + SAVE_DEBOUNCE * 2;
        self.take_due_saves(far)
    }

    /// Whether an edit is waiting to be saved.
    pub fn has_pending_saves(&self) -> bool {
        self.models.values().any(|m| m.dirty_since.is_some())
    }
}

/// The AI half of a repository's stats from its telemetry runs, as
/// `TelemetryStore.runStatsForRepo`, `providersForRepo` and
/// `toolCallDistributionForRepo` compute them: tokens count runs that have
/// both input and output totals, providers are sorted, the 5 most called
/// tools come first. `tool_names` gives the tool calls of a run.
pub fn ai_repo_stats_from_runs(
    runs: &[crate::telemetry::run::TelemetryRun],
    tool_names: impl Fn(&str) -> Vec<String>,
) -> AiRepoStats {
    let mut providers: Vec<String> = runs.iter().map(|r| r.provider.clone()).collect();
    providers.sort();
    providers.dedup();
    let mut counts: HashMap<String, i64> = HashMap::new();
    for run in runs {
        for name in tool_names(&run.id) {
            *counts.entry(name).or_default() += 1;
        }
    }
    let mut top_tools: Vec<(String, i64)> = counts.into_iter().collect();
    top_tools.sort_by(|a, b| b.1.cmp(&a.1).then_with(|| a.0.cmp(&b.0)));
    top_tools.truncate(5);
    AiRepoStats {
        total_runs: runs.len() as i64,
        total_tokens: runs
            .iter()
            .filter_map(|r| Some(r.total_input_tokens? + r.total_output_tokens?))
            .sum(),
        total_cost: runs.iter().filter_map(|r| r.cost_usd).sum(),
        total_turns: runs.iter().map(|r| r.turn_count).sum(),
        last_run_at: runs.iter().map(|r| r.started_at).max(),
        providers,
        top_tools,
    }
}

#[cfg(test)]
mod tests {

    #[test]
    fn ai_stats_from_runs() {
        use crate::telemetry::run::TelemetryRun;
        let run = |id: &str, provider: &str, tokens: Option<(i64, i64)>, cost: f64, turns: i64| {
            let mut r = TelemetryRun::new(provider, "/r");
            r.id = id.to_string();
            r.started_at =
                chrono::DateTime::parse_from_rfc3339(&format!("2026-01-0{}T00:00:00Z", &id[1..]))
                    .unwrap()
                    .with_timezone(&chrono::Utc);
            r.total_input_tokens = tokens.map(|t| t.0);
            r.total_output_tokens = tokens.map(|t| t.1);
            r.cost_usd = Some(cost);
            r.turn_count = turns;
            r
        };
        let runs = vec![
            run("r1", "codex", Some((100, 50)), 0.5, 2),
            run("r2", "claude", None, 0.25, 3),
        ];
        let stats = ai_repo_stats_from_runs(&runs, |id| {
            if id == "r1" {
                vec!["Bash".into(), "Read".into(), "Bash".into()]
            } else {
                vec!["Read".into()]
            }
        });
        assert_eq!(stats.total_runs, 2);
        assert_eq!(stats.total_tokens, 150);
        assert!((stats.total_cost - 0.75).abs() < 1e-9);
        assert_eq!(stats.total_turns, 5);
        assert_eq!(
            stats.providers,
            vec!["claude".to_string(), "codex".to_string()]
        );
        assert_eq!(
            stats.top_tools,
            vec![("Bash".to_string(), 2), ("Read".to_string(), 2)]
        );
        assert_eq!(stats.last_run_at, Some(runs[1].started_at));
    }

    use super::*;
    use std::cell::{Cell, RefCell};

    #[derive(Default)]
    struct FakeProbe {
        roots: HashMap<String, String>,
        branches: RefCell<HashMap<String, String>>,
        calls: Cell<u32>,
    }

    impl FakeProbe {
        fn with(roots: &[(&str, &str, &str)]) -> Self {
            let mut fake = FakeProbe::default();
            for (dir, root, branch) in roots {
                fake.roots.insert((*dir).into(), (*root).into());
                fake.branches
                    .borrow_mut()
                    .insert((*root).into(), (*branch).into());
            }
            fake
        }
    }

    impl RepoProbe for FakeProbe {
        fn find_root(&self, path: &str) -> Option<String> {
            self.calls.set(self.calls.get() + 1);
            self.roots.get(path).cloned()
        }
        fn read_branch(&self, root: &str) -> Option<String> {
            self.branches.borrow().get(root).cloned()
        }
    }

    #[test]
    fn resolve_discovers_a_nested_repository_after_the_parent_was_cached() {
        let probe = FakeProbe::with(&[
            ("/repos/main", "/repos/main", "main"),
            (
                "/repos/main/submodule/worktree",
                "/repos/main/submodule",
                "feature/submodule",
            ),
        ]);
        let mut cache = RepositoryCache::new();
        let first = cache.resolve("/repos/main", &probe).unwrap();
        assert_eq!(first.root, "/repos/main");
        assert!(first.is_new);
        let nested = cache
            .resolve("/repos/main/submodule/worktree", &probe)
            .unwrap();
        assert_eq!(nested.root, "/repos/main/submodule");
        assert_eq!(
            cache.branch("/repos/main/submodule").as_deref(),
            Some("feature/submodule")
        );
        assert_eq!(cache.cached_repo_count(), 2);
    }

    #[test]
    fn known_paths_do_not_probe_and_non_git_is_remembered() {
        let probe = FakeProbe::with(&[("/r", "/r", "main")]);
        let mut cache = RepositoryCache::new();
        cache.resolve("/r", &probe).unwrap();
        let calls = probe.calls.get();
        let again = cache.resolve("/r/", &probe).unwrap();
        assert!(!again.is_new);
        assert_eq!(probe.calls.get(), calls);
        assert!(cache.resolve("/nowhere", &probe).is_none());
        let calls = probe.calls.get();
        assert!(cache.resolve("/nowhere", &probe).is_none());
        assert_eq!(probe.calls.get(), calls);
        cache.reset_negative_cache();
        assert!(cache.resolve("/nowhere", &probe).is_none());
        assert_eq!(probe.calls.get(), calls + 1);
    }

    #[test]
    fn a_subfolder_the_probe_cannot_resolve_uses_the_cached_parent() {
        let probe = FakeProbe::with(&[("/r", "/r", "main")]);
        let mut cache = RepositoryCache::new();
        cache.resolve("/r", &probe).unwrap();
        let sub = cache.resolve("/r/src/deep", &probe).unwrap();
        assert_eq!(sub.root, "/r");
        assert!(!sub.is_new);
    }

    #[test]
    fn a_branch_change_seen_by_one_tab_is_seen_by_all() {
        let probe = FakeProbe::with(&[("/r", "/r", "main"), ("/r/a", "/r", "main")]);
        let mut cache = RepositoryCache::new();
        cache.resolve("/r", &probe).unwrap();
        cache.resolve("/r/a", &probe).unwrap();
        probe
            .branches
            .borrow_mut()
            .insert("/r".into(), "dev".into());
        assert!(cache.refresh_branch("/r", &probe));
        assert!(!cache.refresh_branch("/r", &probe));
        assert_eq!(cache.branch("/r").as_deref(), Some("dev"));
        // The other tab asks for its directory and gets the shared value.
        cache.resolve("/r/a", &probe).unwrap();
        assert_eq!(cache.branch("/r").as_deref(), Some("dev"));
        assert!(cache.set_branch("/r", Some("hotfix".into())));
        assert!(!cache.set_branch("/missing", Some("x".into())));
    }

    #[test]
    fn metadata_edits_save_after_the_debounce() {
        let mut model = RepoModel::new("/r", None);
        let t0 = Instant::now();
        model.set_description(Some("  API  "), t0);
        model.add_label("rust", t0);
        model.add_label("rust", t0);
        model.add_label("  ", t0);
        model.toggle_favorite_file("Cargo.toml", t0);
        assert_eq!(model.metadata.description.as_deref(), Some("API"));
        assert_eq!(model.metadata.labels, ["rust"]);
        assert_eq!(model.metadata.favorite_files, ["Cargo.toml"]);
        assert!(model.metadata.updated_at.is_some());
        model.toggle_favorite_file("Cargo.toml", t0);
        model.remove_label("rust", t0);
        model.set_description(Some(""), t0);
        assert!(model.metadata.is_empty());

        let mut cache = RepositoryCache::new();
        let probe = FakeProbe::with(&[("/r", "/r", "main")]);
        cache.resolve("/r", &probe).unwrap();
        let t = Instant::now();
        cache.model_mut("/r").unwrap().add_label("x", t);
        assert!(cache.has_pending_saves());
        assert!(
            cache
                .take_due_saves(t + Duration::from_millis(100))
                .is_empty()
        );
        let due = cache.take_due_saves(t + Duration::from_millis(600));
        assert_eq!(due.len(), 1);
        assert_eq!(due[0].0, "/r");
        assert_eq!(due[0].1.labels, ["x"]);
        assert!(!cache.has_pending_saves());
        cache.model_mut("/r").unwrap().add_label("y", t);
        assert_eq!(cache.take_all_saves().len(), 1);
    }

    #[test]
    fn restored_known_roots_resolve_without_filesystem_probes() {
        let mut cache = RepositoryCache::new();
        let mut known = known_identity::KnownRepoIdentities::default();
        known.record("/saved/repo", Some("last-branch"), None, true);
        known.record("/saved/repo/nested", Some("nested"), None, true);
        cache.adopt_known_identities(&known);
        assert_eq!(
            cache.cached_root("/saved/repo/nested/sub"),
            Some("/saved/repo/nested".into())
        );
        assert_eq!(cache.cached_root("/saved/repository"), None);
        assert_eq!(cache.branch("/saved/repo").as_deref(), Some("last-branch"));
    }

    #[test]
    fn normalize_path_standardizes() {
        assert_eq!(normalize_path("/a/b/"), "/a/b");
        assert_eq!(normalize_path("/a/./b//c"), "/a/b/c");
        assert_eq!(normalize_path("/a/b/../c"), "/a/c");
        assert_eq!(normalize_path("/"), "/");
    }

    #[test]
    fn stats_assemble_and_format() {
        let stats = RepoStats::assemble(
            CommandStats {
                total: 45,
                successful: 40,
                failed: 5,
                avg_duration: 2.5,
            },
            None,
            AiRepoStats {
                total_runs: 3,
                total_tokens: 12_400,
                total_cost: 1.2,
                total_turns: 9,
                last_run_at: None,
                providers: vec!["claude".into()],
                top_tools: vec![("Bash".into(), 7)],
            },
        );
        assert!(stats.has_activity());
        assert!((stats.success_rate() - 40.0 / 45.0).abs() < 1e-9);
        assert_eq!(stats.hover_parts(), ["3 runs", "12K", "$1.20", "45 cmds"]);
        assert_eq!(
            stats.hover_line(),
            "3 runs \u{b7} 12K \u{b7} $1.20 \u{b7} 45 cmds"
        );
        let json = stats.to_json();
        assert_eq!(json["total_commands"], 45);
        assert_eq!(json["top_tools"][0]["tool"], "Bash");
        assert!(json.get("last_run_at").is_none());
        assert!(
            stats
                .detail_lines()
                .iter()
                .any(|l| l.contains("Top tools: Bash (7)"))
        );
        let empty = RepoStats::default();
        assert!(!empty.has_activity());
        assert_eq!(empty.success_rate(), 0.0);
        assert!(empty.hover_parts().is_empty());
        assert_eq!(format_tokens(1_500_000), "1.5M");
        assert_eq!(format_tokens(999), "999");
    }
}
