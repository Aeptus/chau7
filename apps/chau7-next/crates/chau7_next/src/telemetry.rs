//! AI run telemetry (`Telemetry/*.swift`): one run per AI CLI session in a
//! terminal, stored in Chau7 Next's own `runs.db` (`DataRoot::telemetry_db`).
//!
//! The store, recorder and transcript readers are in
//! `chau7_next_core::telemetry`. This module owns the shared recorder, is
//! called by terminal sessions when an AI CLI starts and exits (TRM-046),
//! and plugs the store into the modules that read it ([`connect`]): MCP
//! tools, repository stats (hover card), Data Explorer, Debug Console
//! Analytics and the iOS client events of remote control.

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
    let root = cx.global::<AppData>().root.clone();
    let store = Arc::new(TelemetryStore::open(&root.telemetry_db()));
    let recorder = TelemetryRecorder::new(store, default_providers(root.home()));
    let recorder = Arc::new(recorder);
    let rates = Arc::new(Mutex::new(
        chau7_next_core::telemetry::token_rate::TokenRateStore::default(),
    ));
    cx.set_global(TelemetryGlobal(recorder.clone()));
    cx.set_global(TokenRates(rates.clone()));
    let home = root.home().to_owned();
    let rate_executor = cx.background_executor().clone();
    cx.background_executor()
        .spawn(async move {
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
            loop {
                rate_executor
                    .timer(std::time::Duration::from_millis(200))
                    .await;
                let runs = recorder.all_active_runs();
                let active: std::collections::HashSet<_> =
                    runs.iter().filter_map(|r| r.tab_id.clone()).collect();
                files.retain(|(tab, _), _| active.contains(tab));
                for run in runs {
                    let (Some(tab), Some(session)) = (run.tab_id, run.session_id) else {
                        continue;
                    };
                    let paths = if matches!(run.provider.as_str(), "claude" | "anthropic") {
                        claude.transcript_files(&run.cwd, &session)
                    } else if matches!(run.provider.as_str(), "codex" | "openai") {
                        codex
                            .find_rollout(&session, run.started_at)
                            .into_iter()
                            .collect()
                    } else {
                        vec![]
                    };
                    for path in paths {
                        let state = files.entry((tab.clone(), path.clone())).or_default();
                        if let Ok(text) = state.0.read(&path) {
                            for line in text.lines() {
                                if let Some(r) = state.1.consume(&run.provider, line) {
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
    mcp_sources::set_telemetry(Arc::new(McpTelemetry(recorder.clone())));

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

/// The store as the MCP tools read it (from their own threads).
struct McpTelemetry(Arc<TelemetryRecorder>);

impl mcp_sources::TelemetrySource for McpTelemetry {
    fn run(&self, run_id: &str) -> Option<TelemetryRun> {
        self.0
            .all_active_runs()
            .into_iter()
            .find(|r| r.id == run_id)
            .or_else(|| self.0.store().get_run(run_id))
    }
    fn runs(&self, filter: &TelemetryRunFilter) -> Vec<TelemetryRun> {
        self.0.store().list_runs(filter)
    }
    fn tool_calls(&self, run_id: &str) -> Vec<TelemetryToolCall> {
        self.0.store().get_tool_calls(run_id)
    }
    fn turns(&self, run_id: &str) -> Vec<TelemetryTurn> {
        self.0.store().get_turns(run_id)
    }
    fn set_tags(&self, run_id: &str, tags: &[String]) {
        self.0.tag_run(run_id, tags);
    }
    fn latest_run_for_repo(&self, repo_path: &str, provider: Option<&str>) -> Option<TelemetryRun> {
        self.0.store().latest_run_for_repo(repo_path, provider)
    }
    fn sessions(&self, repo_path: Option<&str>) -> Vec<Map<String, Value>> {
        self.0.store().list_sessions(repo_path)
    }
    fn active_runs(&self) -> Vec<TelemetryRun> {
        self.0.all_active_runs()
    }
    fn active_run_for_tab(&self, tab_id: &str) -> Option<TelemetryRun> {
        self.0.active_run_for_tab(tab_id)
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
