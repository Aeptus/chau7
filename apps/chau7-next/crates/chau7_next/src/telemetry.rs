//! AI run telemetry (`Telemetry/*.swift`): one run per AI CLI session in a
//! terminal, stored in Chau7 Next's own `runs.db` (`DataRoot::telemetry_db`).
//!
//! The store, recorder and transcript readers are in
//! `chau7_next_core::telemetry`. This module owns the shared recorder, is
//! called by terminal sessions when an AI CLI starts and exits (TRM-046),
//! and plugs the store into the modules that read it ([`connect`]): MCP
//! tools, repository stats (hover card), Data Explorer, Debug Console
//! Analytics and the iOS client events of remote control.

#[path = "usage.rs"]
pub mod usage;

use std::path::PathBuf;
use std::sync::Arc;

use chau7_next_core::ai::event::AiEventSource;
use chau7_next_core::data_explorer::CommandTotals;
use chau7_next_core::debug_console::{AnalyticsData, RepoAnalytics};
use chau7_next_core::history_record::HistoryRecord;
use chau7_next_core::history_store::HistoryStore;
use chau7_next_core::proxy::ProxyAnalyticsStore;
use chau7_next_core::repository::AiRepoStats;
use chau7_next_core::telemetry::providers::default_providers;
use chau7_next_core::telemetry::recorder::TelemetryRecorder;
use chau7_next_core::telemetry::run::{TelemetryRun, TelemetryRunFilter};
use chau7_next_core::telemetry::store::TelemetryStore;
use chau7_next_core::telemetry::turn::{TelemetryToolCall, TelemetryTurn};
use gpui::{App, Global};
use parking_lot::Mutex;
use serde_json::{Map, Value};

use crate::mcp::sources as mcp_sources;
use crate::workspace::AppData;

/// Runs listed by the Debug Console "Rebuild Transcript Metrics".
const REPAIR_LIMIT: i64 = 500;
/// Wait before reading a finished run's PTY log.
const PTY_LOG_DRAIN: std::time::Duration = std::time::Duration::from_millis(500);

struct TelemetryGlobal(Arc<TelemetryRecorder>);
struct LiveTranscriptsGlobal(Arc<LiveTranscripts>);
impl Global for LiveTranscriptsGlobal {}

pub fn register_live_log(tab: &str, path: Option<PathBuf>, cx: &App) {
    if let Some(cache) = cx.try_global::<LiveTranscriptsGlobal>() {
        let mut paths = cache.0.paths.lock();
        if let Some(path) = path {
            paths.insert(tab.into(), path);
        } else {
            paths.remove(tab);
        }
    }
}
struct PromptTimings(Mutex<chau7_next_core::telemetry::latency::PromptTiming>);
impl Global for PromptTimings {}
struct TokenRates(Arc<Mutex<chau7_next_core::telemetry::token_rate::TokenRateStore>>);
impl Global for TokenRates {}
/// Current observed reading only. Absence remains absence, never a zero rate.
pub fn token_rate(
    tab: &str,
    cx: &App,
) -> Option<chau7_next_core::telemetry::token_rate::TokenRateReading> {
    cx.try_global::<TokenRates>()?
        .0
        .lock()
        .reading(tab)
        .cloned()
}
pub fn token_rates(
    cx: &App,
) -> std::collections::HashMap<String, chau7_next_core::telemetry::token_rate::TokenRateReading> {
    cx.try_global::<TokenRates>()
        .map(|g| g.0.lock().snapshot())
        .unwrap_or_default()
}
pub fn record_token_rate(
    tab: &str,
    reading: chau7_next_core::telemetry::token_rate::TokenRateReading,
    cx: &App,
) {
    let previous = token_rate(tab, cx);
    if let Some(store) = cx.try_global::<TokenRates>() {
        store.0.lock().record_rate(
            tab,
            &reading.provider,
            reading.tokens_per_second,
            reading.output_tokens,
            reading.duration_ms,
            reading.source,
            reading.updated_at,
        );
    }
    if previous.as_ref() != Some(&reading) {
        log::debug!(
            "Token rate tab={tab} source={:?} rate={:.2} output={} duration_ms={}",
            reading.source,
            reading.tokens_per_second,
            reading.output_tokens,
            reading.duration_ms
        );
    }
}

impl Global for TelemetryGlobal {}

/// Open the store (Chau7 Next's own file) and set up the recorder.
pub fn init(cx: &mut App) {
    cx.set_global(PromptTimings(Mutex::new(Default::default())));
    cx.set_global(LiveTranscriptsGlobal(Arc::new(LiveTranscripts::new(
        cx.global::<AppData>().root.home().to_owned(),
    ))));
    usage::init(cx);
    let root = cx.global::<AppData>().root.clone();
    let store = Arc::new(TelemetryStore::open(&root.telemetry_db()));
    let recorder = TelemetryRecorder::new(store, default_providers(root.home()));
    let recorder = Arc::new(recorder);
    let rates = Arc::new(Mutex::new(
        chau7_next_core::telemetry::token_rate::TokenRateStore::default(),
    ));
    cx.set_global(TelemetryGlobal(recorder.clone()));
    cx.set_global(TokenRates(rates.clone()));
    usage::init_latency(cx);
    let home = root.home().to_owned();
    let rate_executor = cx.background_executor().clone();
    let timer = crate::observability::register_background_timer(
        cx,
        "telemetry.transcript_rate",
        "Transcript token rate observations",
        "telemetry",
        200,
    );
    cx.background_executor()
        .spawn(async move {
            let _timer = timer;
            use chau7_next_core::telemetry::{
                jsonl_tail::JsonlTail, token_rate::TranscriptRateState,
            };
            let claude =
                chau7_next_core::telemetry::providers::ClaudeCodeContentProvider::new(&home);
            let codex = chau7_next_core::telemetry::providers::CodexContentProvider::new(&home);
            let mut files: std::collections::HashMap<
                (String, PathBuf),
                (JsonlTail, TranscriptRateState),
            > = std::collections::HashMap::new();
            let mut paths_cache: std::collections::HashMap<
                String,
                (String, std::time::Instant, Vec<PathBuf>),
            > = std::collections::HashMap::new();
            loop {
                rate_executor
                    .timer(std::time::Duration::from_millis(200))
                    .await;
                let runs = recorder.all_active_runs();
                let active: std::collections::HashSet<_> =
                    runs.iter().filter_map(|r| r.tab_id.clone()).collect();
                files.retain(|(tab, _), _| active.contains(tab));
                paths_cache.retain(|tab, _| active.contains(tab));
                for run in runs {
                    let (Some(tab), Some(session)) = (run.tab_id, run.session_id) else {
                        continue;
                    };
                    let cached = paths_cache
                        .get(&tab)
                        .filter(|(id, at, _)| {
                            id == &session && at.elapsed() < std::time::Duration::from_secs(2)
                        })
                        .map(|(_, _, paths)| paths.clone());
                    let paths = if let Some(paths) = cached {
                        paths
                    } else {
                        let discovered = if matches!(run.provider.as_str(), "claude" | "anthropic")
                        {
                            claude.transcript_files(&run.cwd, &session)
                        } else if matches!(run.provider.as_str(), "codex" | "openai") {
                            codex
                                .find_rollout(&session, run.started_at)
                                .into_iter()
                                .collect()
                        } else {
                            vec![]
                        };
                        paths_cache.insert(
                            tab.clone(),
                            (
                                session.clone(),
                                std::time::Instant::now(),
                                discovered.clone(),
                            ),
                        );
                        discovered
                    };
                    for path in paths {
                        let state = files.entry((tab.clone(), path.clone())).or_default();
                        if let Ok(text) = state.0.read(&path) {
                            for line in text.lines() {
                                if let Some(r) = state.1.consume(&run.provider, line)
                                    && r.updated_at >= run.started_at
                                {
                                    rates.lock().record_rate(
                                        &tab,
                                        &r.provider,
                                        r.tokens_per_second,
                                        r.output_tokens,
                                        r.duration_ms,
                                        r.source,
                                        r.updated_at,
                                    );
                                }
                            }
                        }
                    }
                }
            }
        })
        .detach();
}

/// The shared recorder (and through it the store).
pub fn recorder(cx: &App) -> Option<Arc<TelemetryRecorder>> {
    cx.try_global::<TelemetryGlobal>().map(|g| g.0.clone())
}

/// Arm first-response timing after a submitted prompt. Call with the submitted
/// command line, not every keypress. Actual session ID matches recorder tabs.
pub fn note_prompt(tab: &str, cx: &App) {
    let Some(run) = recorder(cx).and_then(|r| r.active_run_for_tab(tab)) else {
        return;
    };
    if let Some(timing) = cx.try_global::<PromptTimings>() {
        timing.0.lock().prompt(tab, run, chrono::Utc::now());
    }
}
/// Observe delivered PTY bytes. ANSI controls and spinner-only updates are
/// ignored; consume one prompt only, expire after 120 seconds. SQLite runs
/// off the UI thread and authoritative transcript rounds later replace it.
pub fn note_output(tab: &str, bytes: &[u8], cx: &App) {
    let sample = cx
        .try_global::<PromptTimings>()
        .and_then(|t| t.0.lock().output(tab, bytes, chrono::Utc::now()));
    if let (Some(sample), Some(recorder)) = (sample, recorder(cx)) {
        cx.background_executor()
            .spawn(async move {
                recorder.store().insert_latency_sample(&sample);
            })
            .detach();
    }
}

/// TEL-001: an AI CLI was detected in a terminal session.
pub fn run_started(
    tab_id: &str,
    tool: &str,
    cwd: &str,
    repo_path: Option<&str>,
    session_id: Option<&str>,
    cx: &App,
) {
    let Some(recorder) = recorder(cx) else { return };
    if recorder.active_run_for_tab(tab_id).is_some() {
        return;
    }
    let provider = chau7_next_core::ai::resume::normalize_provider_name(tool)
        .unwrap_or_else(|| tool.to_string());
    let session_id = session_id.filter(|s| chau7_next_core::ai::resume::is_valid_session_id(s));
    recorder.run_started(tab_id, &provider, cwd, repo_path, session_id);
}

/// TEL-002, TEL-006: the AI CLI exited. The transcript is read on a
/// background thread; `buffer` is the terminal text and `pty_log` the AI
/// session's PTY log, used when the CLI's own transcript is missing.
pub fn run_ended(
    tab_id: &str,
    exit_status: Option<i32>,
    session_id: Option<&str>,
    buffer: Option<String>,
    pty_log: Option<PathBuf>,
    cx: &App,
) {
    let Some(recorder) = recorder(cx) else { return };
    if let Some(session) =
        session_id.filter(|s| chau7_next_core::ai::resume::is_valid_session_id(s))
        && recorder
            .active_run_for_tab(tab_id)
            .is_some_and(|r| r.session_id.is_none())
    {
        recorder.update_session_id(tab_id, session);
    }
    if let Some(timing) = cx.try_global::<PromptTimings>() {
        timing.0.lock().clear(tab_id);
    }
    register_live_log(tab_id, None, cx);
    let Some(run) = recorder.run_ended(tab_id, exit_status.map(i64::from)) else {
        return;
    };
    // The PTY log is written by a background thread: give it a moment to
    // drain before the tail is read (Swift closes the log first).
    let executor = cx.background_executor().clone();
    cx.background_executor()
        .spawn(async move {
            executor.timer(PTY_LOG_DRAIN).await;
            recorder.complete(run, buffer, pty_log.as_deref());
        })
        .detach();
}

/// TEL-003: the session id of a tab's AI CLI became known.
pub fn update_session_id(tab_id: &str, session_id: &str, cx: &App) {
    if !chau7_next_core::ai::resume::is_valid_session_id(session_id) {
        return;
    }
    if let Some(recorder) = recorder(cx)
        && recorder
            .active_run_for_tab(tab_id)
            .is_some_and(|r| r.session_id.as_deref() != Some(session_id))
    {
        recorder.update_session_id(tab_id, session_id);
    }
}

/// The AI session row of a tab's hover card (TEL-011, OVL-060): the run in
/// progress in one of the tab's terminals, else the latest run when it
/// belongs to the tab, with its top three tools.
pub fn hover_summary(tab_ids: &[String], cx: &App) -> Option<(TelemetryRun, Vec<(String, i64)>)> {
    let recorder = recorder(cx)?;
    let run = tab_ids
        .iter()
        .find_map(|id| recorder.active_run_for_tab(id))
        .or_else(|| {
            recorder
                .store()
                .list_runs(&TelemetryRunFilter {
                    limit: Some(1),
                    ..Default::default()
                })
                .into_iter()
                .next()
                .filter(|r| r.tab_id.as_ref().is_some_and(|t| tab_ids.contains(t)))
        })?;
    let mut tools = recorder.store().tool_call_summary(&run.id);
    tools.truncate(3);
    Some((run, tools))
}

/// The AI half of a repository's stats (`RepoStatsProvider`).
pub(crate) fn ai_repo_stats(store: &TelemetryStore, repo: &str) -> AiRepoStats {
    let runs = store.run_stats_for_repo(repo);
    AiRepoStats {
        total_runs: runs.total_runs,
        total_tokens: runs.total_tokens,
        total_cost: runs.total_cost,
        total_turns: runs.total_turns,
        last_run_at: runs.last_run_at,
        providers: store.providers_for_repo(repo),
        top_tools: store.tool_call_distribution_for_repo(repo, 5),
    }
}

/// Plug the store into its readers. Call once, after the history, remote,
/// repository and MCP modules started.
pub fn connect(cx: &mut App) {
    let Some(recorder) = recorder(cx) else { return };
    let store = recorder.store().clone();

    // MCP-009 to MCP-016, MCP-039.
    mcp_sources::set_telemetry(Arc::new(McpTelemetry(
        recorder.clone(),
        cx.global::<LiveTranscriptsGlobal>().0.clone(),
    )));

    // REP-009, REP-010, OVL-061.
    let repo_store = store.clone();
    crate::repository::set_ai_stats_provider(
        Arc::new(move |root| ai_repo_stats(&repo_store, root)),
        cx,
    );

    // DEX-002 to DEX-005.
    let history = crate::history::service(cx).map(|s| s.store_handle());
    crate::data_explorer::set_source(
        Arc::new(ExplorerData {
            store: store.clone(),
            history,
        }),
        cx,
    );

    // RMT-024, TEL-015.
    let remote_store = store.clone();
    crate::remote::set_telemetry_sink(
        Box::new(move |event, _cx| remote_store.insert_remote_client_event(&event)),
        cx,
    );

    // DBG-018 to DBG-020, TEL-014, PRX-020.
    let rebuild_recorder = recorder.clone();
    crate::debug::set_analytics_source(
        cx,
        crate::debug::AnalyticsSource {
            data: std::rc::Rc::new(analytics_data),
            rebuild: Some(std::rc::Rc::new(move |cx: &mut App| {
                let recorder = rebuild_recorder.clone();
                cx.background_executor()
                    .spawn(async move {
                        let report = recorder.rebuild_transcript_derived_runs(REPAIR_LIMIT);
                        log::info!(
                            "Telemetry repair: inspected={} rebuilt={} invalidated={} skipped={}",
                            report.inspected_runs,
                            report.rebuilt_runs,
                            report.invalidated_runs,
                            report.skipped_runs
                        );
                    })
                    .detach();
            })),
        },
    );

    // TEL-003: session ids from Claude Code hooks and the Codex history.
    crate::ai::events_out::subscribe(cx, move |event, _notify, _cx| {
        let (Some(session), Some(directory)) = (&event.session_id, &event.directory) else {
            return;
        };
        if session.is_empty() || directory.is_empty() {
            return;
        }
        let provider = match event.source.raw_value() {
            AiEventSource::CLAUDE_CODE => "claude",
            AiEventSource::CODEX => "codex",
            _ => return,
        };
        recorder.update_session_id_by_cwd(provider, directory, session);
    });
}

/// Everything the Debug Console Analytics tab shows.
fn analytics_data(cx: &App) -> AnalyticsData {
    let root = cx.global::<AppData>().root.clone();
    let mut data = AnalyticsData::default();
    let db = root.proxy_db();
    let proxy = ProxyAnalyticsStore::new(&db);
    data.proxy_stats = proxy.overall_stats(None);
    data.proxy_providers = proxy.provider_stats();
    data.proxy_daily = proxy.daily_trend(7);
    data.proxy_recent = proxy
        .recent_calls(50)
        .iter()
        .map(|c| c.debug_call())
        .collect();
    if let Some(recorder) = recorder(cx) {
        let store = recorder.store();
        data.run_providers = store.consumption_per_provider(None);
        data.run_tabs = store.token_usage_per_tab(None);
        data.run_daily = store.daily_cost_trend(7);
        data.run_count = store.run_count();
    }
    let now = chrono::Utc::now();
    data.repos = chau7_next_core::repo_metadata::load_recent(&root.recent_repos_file())
        .into_iter()
        .map(|path| {
            let stats = crate::repository::stats(&path, cx).unwrap_or_default();
            let last = [stats.last_command_at, stats.last_run_at]
                .into_iter()
                .flatten()
                .max();
            RepoAnalytics {
                name: chau7_next_core::data_explorer::last_component(&path),
                total_commands: stats.total_commands,
                success_rate: stats.success_rate(),
                total_runs: stats.total_runs,
                total_tokens: stats.total_tokens,
                total_cost: stats.total_cost,
                providers: stats.providers.clone(),
                top_tools: stats.top_tools.clone(),
                last_activity_ago: last.map(|d| (now - d).num_seconds().max(0)),
                path,
            }
        })
        .collect();
    data
}

/// Bounded, off-UI live transcript reads. Keys use run identity so a new
/// invocation in the same tab cannot inherit an earlier run's cached content.
struct LiveTranscripts {
    home: PathBuf,
    paths: Mutex<std::collections::HashMap<String, PathBuf>>,
    cache: Mutex<std::collections::HashMap<String, (std::time::Instant, Vec<TelemetryTurn>)>>,
}
impl LiveTranscripts {
    fn new(home: PathBuf) -> Self {
        Self {
            home,
            paths: Mutex::new(Default::default()),
            cache: Mutex::new(Default::default()),
        }
    }
    fn turns(&self, run: &TelemetryRun) -> Vec<TelemetryTurn> {
        use chau7_next_core::telemetry::query_projection::{
            bounded_file_tail, codex_live_turns, pty_live_turns,
        };
        let now = std::time::Instant::now();
        if let Some((at, turns)) = self.cache.lock().get(&run.id)
            && now.duration_since(*at) < std::time::Duration::from_secs(5)
        {
            return turns.clone();
        }
        let mut turns = Vec::new();
        if run.provider.to_lowercase().contains("codex")
            && let Some(session) = &run.session_id
            && let Some(text) =
                bounded_file_tail(&self.home.join(".codex/history.jsonl"), 1_024_000)
        {
            turns = codex_live_turns(&text, session, run);
        }
        if turns.is_empty()
            && let Some(tab) = &run.tab_id
        {
            let path = self.paths.lock().get(tab).cloned();
            if let Some(text) = path.and_then(|p| bounded_file_tail(&p, 1_024_000)) {
                turns = pty_live_turns(&text, run);
            }
        }
        let mut cache = self.cache.lock();
        cache.retain(|_, (at, _)| now.duration_since(*at) < std::time::Duration::from_secs(5));
        if cache.len() >= 128
            && let Some(oldest) = cache
                .iter()
                .min_by_key(|(_, (at, _))| *at)
                .map(|(id, _)| id.clone())
        {
            cache.remove(&oldest);
        }
        cache.insert(run.id.clone(), (now, turns.clone()));
        turns
    }
}

/// The store as the MCP tools read it (from their own threads).
struct McpTelemetry(Arc<TelemetryRecorder>, Arc<LiveTranscripts>);

impl mcp_sources::TelemetrySource for McpTelemetry {
    fn run(&self, run_id: &str) -> Option<TelemetryRun> {
        use chau7_next_core::telemetry::query_projection::with_proxy_metrics;
        let stored = self.0.store().get_run(run_id);
        self.0
            .all_active_runs()
            .into_iter()
            .find(|r| r.id == run_id)
            .map(|live| with_proxy_metrics(live, stored.clone()))
            .or(stored)
    }
    fn runs(&self, filter: &TelemetryRunFilter) -> Vec<TelemetryRun> {
        use chau7_next_core::telemetry::query_projection::{
            MAX_STORE_SCAN, matches_filter, merge_runs, query_window,
        };
        let (offset, limit) = query_window(filter);
        if limit == 0 {
            return Vec::new();
        }
        let active: Vec<_> = self
            .active_runs()
            .into_iter()
            .filter(|r| matches_filter(r, filter))
            .collect();
        let mut stored_filter = filter.clone();
        stored_filter.offset = None;
        stored_filter.limit = Some(
            limit
                .saturating_add(offset)
                .saturating_add(active.len())
                .min(MAX_STORE_SCAN) as i64,
        );
        merge_runs(
            active,
            self.0.store().list_runs(&stored_filter),
            offset,
            Some(limit),
        )
    }
    fn tool_calls(&self, run_id: &str) -> Vec<TelemetryToolCall> {
        self.0.store().get_tool_calls(run_id)
    }
    fn turns(&self, run_id: &str) -> Vec<TelemetryTurn> {
        let stored = self.0.store().get_turns(run_id);
        if !stored.is_empty() {
            return stored;
        }
        self.0
            .all_active_runs()
            .into_iter()
            .find(|r| r.id == run_id)
            .map(|r| self.1.turns(&r))
            .unwrap_or_default()
    }
    fn set_tags(&self, run_id: &str, tags: &[String]) {
        self.0.tag_run(run_id, tags);
    }
    fn latest_run_for_repo(&self, repo_path: &str, provider: Option<&str>) -> Option<TelemetryRun> {
        self.runs(&TelemetryRunFilter {
            repo_path: Some(repo_path.into()),
            provider: provider.map(str::to_owned),
            limit: Some(1),
            ..Default::default()
        })
        .into_iter()
        .next()
    }
    fn sessions(&self, repo_path: Option<&str>) -> Vec<Map<String, Value>> {
        use chau7_next_core::telemetry::query_projection::{MAX_STORE_SCAN, project_sessions};
        let rows = self.0.store().list_sessions(repo_path);
        let active: Vec<_> = self
            .active_runs()
            .into_iter()
            .filter(|r| repo_path.is_none_or(|p| r.repo_path.as_deref() == Some(p)))
            .collect();
        let stored = self.0.store().list_runs(&TelemetryRunFilter {
            repo_path: repo_path.map(str::to_owned),
            limit: Some(rows.len().saturating_mul(2).clamp(100, MAX_STORE_SCAN) as i64),
            ..Default::default()
        });
        project_sessions(rows, &active, &stored, false)
    }
    fn active_runs(&self) -> Vec<TelemetryRun> {
        self.0
            .all_active_runs()
            .into_iter()
            .map(|r| {
                let stored = self.0.store().get_run(&r.id);
                chau7_next_core::telemetry::query_projection::with_proxy_metrics(r, stored)
            })
            .collect()
    }
    fn active_run_for_tab(&self, tab_id: &str) -> Option<TelemetryRun> {
        self.0.active_run_for_tab(tab_id).map(|r| {
            let stored = self.0.store().get_run(&r.id);
            chau7_next_core::telemetry::query_projection::with_proxy_metrics(r, stored)
        })
    }
}

/// The Data Explorer's runs (telemetry store) and commands (history
/// database).
struct ExplorerData {
    store: Arc<TelemetryStore>,
    history: Option<Arc<Mutex<HistoryStore>>>,
}

impl ExplorerData {
    fn history<R: Default>(&self, f: impl FnOnce(&HistoryStore) -> R) -> R {
        self.history
            .as_ref()
            .map(|h| f(&h.lock()))
            .unwrap_or_default()
    }
}

impl crate::data_explorer::ExplorerSource for ExplorerData {
    fn runs(&self, limit: usize) -> Vec<TelemetryRun> {
        self.store.list_runs(&TelemetryRunFilter {
            limit: Some(limit as i64),
            ..Default::default()
        })
    }
    fn tool_calls(&self, run_id: &str) -> Vec<(String, i64)> {
        self.store.tool_call_summary(run_id)
    }
    fn repo_cost(&self, repo: &str) -> f64 {
        self.store.run_stats_for_repo(repo).total_cost
    }
    fn command_totals(&self, repo: &str) -> CommandTotals {
        self.history(|h| {
            let stats = h.command_stats_for_repo(repo);
            CommandTotals {
                total: stats.total,
                successful: stats.successful,
            }
        })
    }
    fn recent_commands(&self, limit: usize) -> Vec<HistoryRecord> {
        self.history(|h| h.recent(limit))
    }
    fn search_commands(&self, query: &str, limit: usize) -> Vec<HistoryRecord> {
        self.history(|h| h.search(query, limit))
    }
    fn command_count(&self) -> i64 {
        self.history(|h| h.total_count())
    }
}

#[cfg(test)]
mod query_tests {
    use super::*;
    use crate::mcp::sources::TelemetrySource;

    fn source() -> McpTelemetry {
        McpTelemetry(
            Arc::new(TelemetryRecorder::new(
                Arc::new(TelemetryStore::in_memory()),
                vec![],
            )),
            Arc::new(LiveTranscripts::new(PathBuf::from("/unused-test-home"))),
        )
    }
    #[test]
    fn current_snapshot_and_sql_pagination_do_not_duplicate_runs() {
        let source = source();
        let live_id =
            source
                .0
                .run_started("TAB", "claude", "/repo", Some("/repo"), Some("session"));
        let mut stale = source.0.store().get_run(&live_id).unwrap();
        stale.ended_at = Some(chrono::Utc::now());
        source.0.store().rewrite_completed_run(&stale, &[], &[]);
        assert!(source.run(&live_id).unwrap().ended_at.is_none());
        assert!(source.active_run_for_tab("TAB").unwrap().ended_at.is_none());
        for n in 0..4 {
            let mut stored = TelemetryRun::new("claude", "/repo");
            stored.repo_path = Some("/repo".into());
            stored.parent_run_id = Some("parent".into());
            stored.started_at -= chrono::Duration::seconds(n + 1);
            source.0.store().insert_run(&stored);
        }
        let rows = source.runs(&TelemetryRunFilter {
            limit: Some(2),
            offset: Some(1),
            ..Default::default()
        });
        assert_eq!(rows.len(), 2);
        assert!(rows.iter().all(|r| r.id != live_id));
        assert_ne!(rows[0].id, rows[1].id);
        assert_eq!(
            source.latest_run_for_repo("/repo", None).unwrap().id,
            live_id
        );
        assert_eq!(
            source
                .runs(&TelemetryRunFilter {
                    parent_run_id: Some("parent".into()),
                    ..Default::default()
                })
                .len(),
            4
        );
        let sessions = source.sessions(None);
        assert_eq!(sessions[0]["active_run_count"], 1);
        assert_eq!(sessions[0]["latest_run_state"], "active");
    }
    #[test]
    fn transcript_cache_expires_and_never_crosses_run_identity() {
        let source = source();
        let dir = std::env::temp_dir().join(format!("chau7-next-query-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("one-pty.log");
        std::fs::write(&path, "first run").unwrap();
        let id = source.0.run_started("TAB", "claude", "/repo", None, None);
        source.1.paths.lock().insert("TAB".into(), path.clone());
        assert_eq!(source.turns(&id)[0].content.as_deref(), Some("first run"));
        std::fs::write(&path, "changed output").unwrap();
        assert_eq!(source.turns(&id)[0].content.as_deref(), Some("first run"));
        source.1.cache.lock().get_mut(&id).unwrap().0 -= std::time::Duration::from_secs(6);
        assert_eq!(
            source.turns(&id)[0].content.as_deref(),
            Some("changed output")
        );
        source.0.run_ended("TAB", Some(0));
        assert!(source.turns(&id).is_empty());
        let next = source.0.run_started("TAB", "claude", "/repo", None, None);
        std::fs::write(&path, "second run").unwrap();
        assert_eq!(
            source.turns(&next)[0].content.as_deref(),
            Some("second run")
        );
        std::fs::remove_dir_all(dir).unwrap();
    }
}
