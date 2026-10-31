//! AI run telemetry (`Telemetry/*.swift`): one run per AI CLI session in a
//! terminal, stored in Chau7 Next's own `runs.db` (`DataRoot::telemetry_db`).
//!
//! The store, recorder and transcript readers are in
//! `chau7_next_core::telemetry`. This module owns the shared recorder, is
//! called by terminal sessions when an AI CLI starts and exits (TRM-046),
//! and plugs the store into the modules that read it ([`connect`]): MCP
//! tools, repository stats (hover card), Data Explorer, Debug Console
//! Analytics and the iOS client events of remote control.

mod admission;
mod cache;

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
use chau7_next_core::telemetry::store::{StoreReadiness, TelemetryStore};
use chau7_next_core::telemetry::turn::{TelemetryToolCall, TelemetryTurn};
use chrono::{DateTime, Utc};
use futures::{FutureExt as _, StreamExt as _};
use gpui::{App, Global};
use parking_lot::Mutex;
use serde_json::{Map, Value};

use crate::mcp::sources as mcp_sources;
use crate::workspace::AppData;

/// Runs listed by the Debug Console "Rebuild Transcript Metrics".
const REPAIR_LIMIT: i64 = 500;
struct TranscriptMonitor {
    wake: Mutex<futures::channel::mpsc::Sender<()>>,
    task: Option<gpui::Task<()>>,
    activity: Arc<cache::Activity>,
}
impl Global for TranscriptMonitor {}

pub(crate) struct Shutdown {
    transcript: cache::Drain,
    reads: Vec<cache::Drain>,
    maintenance: Option<cache::Drain>,
    store: Option<Arc<TelemetryStore>>,
    writer: Option<chau7_next_core::telemetry::recorder::WriterShutdown>,
}
impl Shutdown {
    /// Called only by the existing background quit future.
    pub(crate) fn finish(self) -> Result<(), String> {
        self.transcript.finish();
        if let Some(maintenance) = self.maintenance {
            maintenance.finish();
        }
        for read in self.reads {
            read.finish();
        }
        let drained = if let Some(writer) = self.writer {
            match writer.finish() {
                Ok(status) => {
                    log::info!(
                        "Telemetry writer drained: accepted={} processed={} rejected={} failed={}",
                        status.accepted,
                        status.processed,
                        status.rejected,
                        status.failed
                    );
                    if status.failed > 0 {
                        Err("accepted telemetry writes failed".into())
                    } else {
                        Ok(())
                    }
                }
                Err(error) => Err(error),
            }
        } else if self.store.is_some() {
            // No handle is not a successful drain: OS worker creation may have
            // failed before any initialization job could be admitted.
            Err("telemetry writer unavailable for shutdown".into())
        } else {
            Ok(())
        };
        let unavailable = self.store.as_ref().is_some_and(|store| {
            matches!(
                store.readiness(),
                StoreReadiness::Loading | StoreReadiness::Failed
            )
        });
        // Retained Global/MCP Arc wrappers must not retain a SQLite handle.
        if let Some(store) = self.store {
            store
                .close()
                .map_err(|_| "telemetry SQLite close failed".to_string())?;
        }
        drained?;
        if unavailable {
            Err("telemetry initialization did not succeed".into())
        } else {
            Ok(())
        }
    }
}
pub(crate) fn shutdown(cx: &mut App) -> Option<Shutdown> {
    cx.try_global::<TranscriptMonitor>()?;
    let monitor = cx.global_mut::<TranscriptMonitor>();
    drop(monitor.task.take());
    let transcript = monitor.activity.stop();
    let maintenance = usage::shutdown_maintenance(cx);
    let store = recorder(cx).map(|recorder| recorder.store().clone());
    let mut reads = cx
        .try_global::<ReadSnapshots>()
        .map(|s| {
            vec![
                s.hover.stop(),
                s.analytics.stop(),
                s.repairs.stop(),
                s.bootstrap.stop(),
            ]
        })
        .unwrap_or_default();
    if let Some(quota) = usage::shutdown_quota(cx) {
        reads.push(quota);
    }
    let writer = recorder(cx).and_then(|recorder| recorder.shutdown());
    Some(Shutdown {
        transcript,
        writer,
        reads,
        maintenance,
        store,
    })
}

type HoverValue = Option<(TelemetryRun, Vec<(String, i64)>)>;
struct ReadSnapshots {
    hover: Arc<cache::Cache<Vec<String>, HoverValue>>,
    analytics: Arc<cache::Cache<(), AnalyticsData>>,
    repairs: Arc<cache::Activity>,
    bootstrap: Arc<cache::Activity>,
}
impl Global for ReadSnapshots {}
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
    let Some(run) = recorder(cx).and_then(|r| r.active_run_for_tab(tab)) else {
        return;
    };
    if reading.updated_at < run.started_at
        || chau7_next_core::ai::resume::normalize_provider_name(&reading.provider)
            != chau7_next_core::ai::resume::normalize_provider_name(&run.provider)
    {
        return;
    }
    if let Some(store) = cx.try_global::<TokenRates>() {
        store
            .0
            .lock()
            .record_owned(tab, &rate_owner(&run), reading.clone());
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

/// Set up memory-only globals; the first writer job opens/migrates off UI.
pub fn init(cx: &mut App) {
    cx.set_global(PromptTimings(Mutex::new(Default::default())));
    cx.set_global(LiveTranscriptsGlobal(Arc::new(LiveTranscripts::new(
        cx.global::<AppData>().root.home().to_owned(),
    ))));
    usage::init(cx);
    let root = cx.global::<AppData>().root.clone();
    let recorder =
        TelemetryRecorder::open_background(&root.telemetry_db(), default_providers(root.home()));
    let recorder = Arc::new(recorder);
    let rates = Arc::new(Mutex::new(
        chau7_next_core::telemetry::token_rate::TokenRateStore::default(),
    ));
    cx.set_global(TelemetryGlobal(recorder.clone()));
    cx.set_global(ReadSnapshots {
        hover: Arc::new(cache::Cache::new()),
        analytics: Arc::new(cache::Cache::new()),
        repairs: cache::Activity::new(1),
        bootstrap: cache::Activity::new(1),
    });
    cx.set_global(TokenRates(rates.clone()));
    usage::init_latency(cx);
    let initializing = recorder.store().clone();
    let active = cx
        .global::<ReadSnapshots>()
        .bootstrap
        .begin()
        .expect("new initialization observer accepts one worker");
    let observed = admission::background_observation(cx, async move {
        let _active = active;
        initializing.wait_until_initialized().is_ok()
    });
    cx.spawn(async move |cx| {
        let Ok(initialized) = observed.await else {
            return;
        };
        cx.update(|cx| {
            usage::refresh_latency(cx);
            if !initialized {
                log::warn!("Telemetry initialization unavailable");
            }
            cx.refresh_windows();
        });
    })
    .detach();
    start_transcript_monitor(root.home().to_owned(), recorder, rates, cx);
}

/// The active CLI owns transcript cadence, including silent reasoning/tool waits.
/// Start, identity update and exit signals wake the idle worker without polling.
fn start_transcript_monitor(
    home: PathBuf,
    recorder: Arc<TelemetryRecorder>,
    rates: Arc<Mutex<chau7_next_core::telemetry::token_rate::TokenRateStore>>,
    cx: &mut App,
) {
    let rate_executor = cx.background_executor().clone();
    let timers = crate::observability::timer_registry(cx).expect("observability initialized");
    let (mut wake, mut events) = futures::channel::mpsc::channel(1);
    // Initial discovery also handles a recorder that already has active runs.
    let _ = wake.try_send(());
    let activity = cache::Activity::new(1);
    let active = activity
        .begin()
        .expect("new transcript lifecycle accepts its worker");
    let task = cx.background_executor().spawn(async move {
        let _active = active;
        let mut timer = None;
        let mut polling = false;
        use chau7_next_core::telemetry::{jsonl_tail::JsonlTail, token_rate::TranscriptRateState};
        let claude = chau7_next_core::telemetry::providers::ClaudeCodeContentProvider::new(&home);
        let codex = chau7_next_core::telemetry::providers::CodexContentProvider::new(&home);
        let mut files: std::collections::HashMap<
            (String, String, PathBuf),
            (JsonlTail, TranscriptRateState),
        > = std::collections::HashMap::new();
        let mut paths_cache: std::collections::HashMap<
            String,
            (String, std::time::Instant, Vec<PathBuf>),
        > = std::collections::HashMap::new();
        loop {
            if polling {
                let delay = rate_executor
                    .timer(std::time::Duration::from_millis(200))
                    .fuse();
                let event = events.next().fuse();
                futures::pin_mut!(delay, event);
                futures::select_biased! {
                    event = event => if event.is_none() { break; },
                    _ = delay => {},
                }
            } else if events.next().await.is_none() {
                break;
            }
            // Lifecycle changes coalesce; a parked worker has no timer.
            while events.try_recv().is_ok() {}
            let mut callback = chau7_next_core::work_profiler::timer_callback(
                "telemetry.transcript_rate",
                "poll",
                chau7_next_core::work_profiler::Queue::Background,
            );
            let runs = recorder.all_active_runs();
            polling = !runs.is_empty();
            if polling && timer.is_none() {
                timer = Some(timers.register(
                    "telemetry.transcript_rate",
                    "Transcript token rate observations",
                    "telemetry",
                    200,
                    "background_task",
                    "gpui-background-executor",
                ));
            } else if !polling {
                drop(timer.take());
            }
            callback.items(runs.len());
            callback.idle(runs.is_empty() && files.is_empty() && paths_cache.is_empty());
            let active: std::collections::HashSet<_> = runs
                .iter()
                .filter_map(|r| Some((r.tab_id.clone()?, rate_owner(r))))
                .collect();
            files.retain(|(tab, owner, _), _| active.contains(&(tab.clone(), owner.clone())));
            paths_cache.retain(|tab, _| active.iter().any(|(id, _)| id == tab));
            for run in runs {
                let owner = rate_owner(&run);
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
                    let discovered = if matches!(run.provider.as_str(), "claude" | "anthropic") {
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
                    let state = files
                        .entry((tab.clone(), owner.clone(), path.clone()))
                        .or_default();
                    if let Ok(text) = state.0.read(&path) {
                        for line in text.lines() {
                            if let Some(r) = state.1.consume(&run.provider, line) {
                                // Exact-session history can seed a last reading after
                                // restoration. Display state keeps it historical.
                                rates.lock().record_owned(&tab, &owner, r);
                            }
                        }
                    }
                }
            }
        }
    });
    cx.set_global(TranscriptMonitor {
        wake: Mutex::new(wake),
        task: Some(task),
        activity,
    });
}

fn wake_transcript_monitor(cx: &App) {
    if let Some(monitor) = cx.try_global::<TranscriptMonitor>() {
        let _ = monitor.wake.lock().try_send(());
    }
}

/// Bounded, memory-only telemetry for the existing MCP/performance diagnostics.
/// Token rates stay keyed by local tab ID and retain their source and timestamp;
/// this does not read prompts, provider session IDs, transcript paths or SQL.
pub fn diagnostics(cx: &App) -> Value {
    // Reuse the existing in-memory store. Snapshot capture performs no transcript,
    // SQLite, or provider query.
    let token_rates_by_tab = cx
        .try_global::<TokenRates>()
        .map(|global| global.0.lock().snapshot());
    let Some(recorder) = recorder(cx) else {
        return serde_json::json!({"store_state":"unavailable", "writer":null, "store_failures":null,
            "snapshots":null, "token_rates_by_tab":token_rates_by_tab,
            "extraction":null,
            "maintenance":usage::maintenance_diagnostics(cx)});
    };
    let writer = recorder.writer_status();
    let extraction = recorder.extraction_diagnostics();
    let extraction = serde_json::json!({
        "available_providers":extraction.available_providers,
        "attempts":extraction.attempts,
        "succeeded":extraction.succeeded,
        "missing_session":extraction.missing_session,
        "transcript_missing":extraction.transcript_missing,
        "pty_fallback":extraction.pty_fallback,
        "terminal_fallback":extraction.terminal_fallback,
        "identity_associated":extraction.identity_associated,
        "identity_ambiguous":extraction.identity_ambiguous,
        "identity_unmatched":extraction.identity_unmatched,
        "identity_conflict":extraction.identity_conflict,
        "identity_explicit_tab_unresolved":extraction.identity_explicit_tab_unresolved,
    });
    let snapshots = cx.try_global::<ReadSnapshots>().map(|s| {
        serde_json::json!({
            "hover":s.hover.diagnostics(), "analytics":s.analytics.diagnostics(),
            "repair":s.repairs.diagnostics(), "initialization":s.bootstrap.diagnostics(),
        })
    });
    serde_json::json!({"store_state":recorder.store().readiness().as_str(),
        "store_failures":recorder.store().failure_count(),
        "writer":{"accepted":writer.accepted, "completed":writer.processed,
            "pending":writer.accepted.saturating_sub(writer.processed),
            "pending_bytes":writer.pending_bytes,"rejected":writer.rejected,"failed":writer.failed,
            "accepting":writer.accepting,"last_error":writer.last_error,
            "acknowledgement":"admission is queued; completed includes failed jobs; failed is separate"},
        "snapshots":snapshots,"token_rates_by_tab":token_rates_by_tab,
        "extraction":extraction,
        "maintenance":usage::maintenance_diagnostics(cx)})
}

fn terminal_tab_for_identity_event(
    public_tab: uuid::Uuid,
    provider: &str,
    directory: &str,
    session_id: &str,
    cx: &mut App,
) -> Option<String> {
    let mut candidates = Vec::new();
    for window in crate::mcp::windows::windows(cx) {
        let workspace = window.workspace.read(cx);
        let Some(tab) = workspace.mcp_find(public_tab) else {
            continue;
        };
        let Some(panes) = workspace.mcp_panes(tab) else {
            continue;
        };
        for (_, entity) in panes.read(cx).pane_sessions(cx) {
            let session = entity.read(cx);
            let shell = session.shell();
            let observed_provider = shell.effective_provider();
            let provider_matches = observed_provider.as_deref().is_some_and(|observed| {
                identity_provider_key(observed) == identity_provider_key(provider)
            });
            let observed_session = shell.ai_session_id();
            if provider_matches
                && shell.current_directory() == directory
                && observed_session.is_none_or(|observed| observed == session_id)
            {
                candidates.push(session.tab_identifier.clone());
            }
        }
    }
    (candidates.len() == 1).then(|| candidates.remove(0))
}

fn identity_provider_key(provider: &str) -> String {
    match provider.trim().to_ascii_lowercase().as_str() {
        "claude" | "claude code" | "claude_code" | "anthropic" => "claude".into(),
        "codex" | "openai" => "codex".into(),
        _ => String::new(),
    }
}

#[cfg(test)]
mod performance_diagnostics_tests {
    use super::{TelemetryGlobal, TokenRates, diagnostics};
    use chau7_next_core::telemetry::{
        recorder::TelemetryRecorder,
        store::TelemetryStore,
        token_rate::{TokenRateSource, TokenRateStore},
    };
    use parking_lot::Mutex;
    use std::sync::Arc;

    fn install_recorder(cx: &mut gpui::App) {
        let store = Arc::new(TelemetryStore::in_memory());
        cx.set_global(TelemetryGlobal(Arc::new(TelemetryRecorder::new(
            store,
            vec![],
        ))));
    }

    #[gpui::test]
    fn performance_diagnostics_distinguishes_absent_and_empty_token_rates(
        cx: &mut gpui::TestAppContext,
    ) {
        let absent = cx.update(|app| diagnostics(app));
        assert!(absent["token_rates_by_tab"].is_null(), "{absent}");

        let empty = cx.update(|app| {
            app.set_global(TokenRates(Arc::new(Mutex::new(TokenRateStore::default()))));
            diagnostics(app)
        });
        assert_eq!(
            empty["token_rates_by_tab"],
            serde_json::json!({}),
            "{empty}"
        );
    }

    #[gpui::test]
    fn performance_diagnostics_exports_typed_rate_without_paths(cx: &mut gpui::TestAppContext) {
        let updated_at = chrono::Utc::now();
        let snapshot = cx.update(|app| {
            install_recorder(app);
            let mut rates = TokenRateStore::default();
            assert!(rates.record_rate(
                "tab-local-id",
                "Claude",
                31.25,
                120,
                3_840,
                TokenRateSource::ProxyUsage,
                updated_at,
            ));
            app.set_global(TokenRates(Arc::new(Mutex::new(rates))));
            diagnostics(app)
        });
        let reading = &snapshot["token_rates_by_tab"]["tab-local-id"];
        assert_eq!(reading["provider"], "Claude");
        assert_eq!(reading["tokensPerSecond"], 31.25);
        assert_eq!(reading["outputTokens"], 120);
        assert_eq!(reading["durationMs"], 3_840);
        assert_eq!(reading["source"], "proxyUsage");
        assert_eq!(
            reading["updatedAt"],
            serde_json::to_value(updated_at).unwrap()
        );
        let mut fields = reading
            .as_object()
            .unwrap()
            .keys()
            .cloned()
            .collect::<Vec<_>>();
        fields.sort();
        assert_eq!(
            fields,
            vec![
                "durationMs",
                "outputTokens",
                "provider",
                "source",
                "tokensPerSecond",
                "updatedAt",
            ]
        );
    }

    #[gpui::test]
    fn performance_diagnostics_exports_only_bounded_extraction_counts(
        cx: &mut gpui::TestAppContext,
    ) {
        let snapshot = cx.update(|app| {
            install_recorder(app);
            diagnostics(app)
        });
        let extraction = &snapshot["extraction"];
        let mut keys = extraction
            .as_object()
            .unwrap()
            .keys()
            .cloned()
            .collect::<Vec<_>>();
        keys.sort();
        assert_eq!(
            keys,
            vec![
                "attempts",
                "available_providers",
                "identity_ambiguous",
                "identity_associated",
                "identity_conflict",
                "identity_explicit_tab_unresolved",
                "identity_unmatched",
                "missing_session",
                "pty_fallback",
                "succeeded",
                "terminal_fallback",
                "transcript_missing",
            ]
        );
        assert_eq!(extraction["available_providers"], 0);
        assert_eq!(extraction["attempts"], 0);
        assert_eq!(extraction["missing_session"], 0);
        assert_eq!(extraction["transcript_missing"], 0);
        assert_eq!(extraction["pty_fallback"], 0);
        assert_eq!(extraction["terminal_fallback"], 0);
        let encoded = extraction.to_string();
        assert!(!encoded.contains('/'));
        assert!(!encoded.contains("command"));
        assert!(!encoded.contains("path"));
    }
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
    if let (Some(sample), Some(recorder)) = (sample, recorder(cx))
        && let Err(error) = recorder.record_latency(sample)
    {
        log::warn!("Telemetry latency write rejected: {error}");
    }
}

fn rate_owner(run: &TelemetryRun) -> String {
    format!(
        "{}:{}",
        run.id,
        run.session_id.as_deref().unwrap_or_default()
    )
}
fn bind_token_rate(tab: &str, cx: &App) {
    if let Some(run) = recorder(cx).and_then(|r| r.active_run_for_tab(tab))
        && let Some(rates) = cx.try_global::<TokenRates>()
    {
        rates.0.lock().bind(tab, &rate_owner(&run));
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
    if let Err(error) = recorder.run_started(tab_id, &provider, cwd, repo_path, session_id) {
        log::warn!("Telemetry run admission rejected: {error}");
    }
    bind_token_rate(tab_id, cx);
    wake_transcript_monitor(cx);
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
        && let Err(error) = recorder.update_session_id(tab_id, session)
    {
        log::warn!("Telemetry session update rejected: {error}");
    }
    if let Some(timing) = cx.try_global::<PromptTimings>() {
        timing.0.lock().clear(tab_id);
    }
    register_live_log(tab_id, None, cx);
    let Some(run) = recorder.run_ended(tab_id, exit_status.map(i64::from)) else {
        return;
    };
    if let Some(rates) = cx.try_global::<TokenRates>() {
        rates.0.lock().unbind(tab_id);
    }
    wake_transcript_monitor(cx);
    // The owned writer captures this completion before returning. Its drain
    // includes the off-UI PTY delay, transcript read and final transaction.
    if let Err(error) = recorder.enqueue_completion(run, buffer, pty_log) {
        log::warn!("Telemetry completion rejected: {error}");
    }
}

/// TEL-003: the session id of a tab's AI CLI became known.
pub fn update_session_id(tab_id: &str, session_id: &str, cx: &App) {
    if !chau7_next_core::ai::resume::is_valid_session_id(session_id) {
        return;
    }
    let mut changed = false;
    if let Some(recorder) = recorder(cx)
        && recorder
            .active_run_for_tab(tab_id)
            .is_some_and(|r| r.session_id.as_deref() != Some(session_id))
    {
        match recorder.update_session_id(tab_id, session_id) {
            Ok(_) => changed = true,
            Err(error) => log::warn!("Telemetry session update rejected: {error}"),
        }
    }
    bind_token_rate(tab_id, cx);
    if changed {
        wake_transcript_monitor(cx);
    }
}

/// The AI session row of a tab's hover card (TEL-011, OVL-060): the run in
/// progress in one of the tab's terminals, else the latest run when it
/// belongs to the tab, with its top three tools.
pub fn hover_summary(tab_ids: &[String], cx: &App) -> Option<(TelemetryRun, Vec<(String, i64)>)> {
    let recorder = recorder(cx)?;
    let live = tab_ids
        .iter()
        .find_map(|id| recorder.active_run_for_tab(id));
    if recorder.store().readiness() != StoreReadiness::Ready {
        return live.map(|run| (run, Vec::new()));
    }
    let mut key = tab_ids.to_vec();
    // A restarted tab never displays the tools of its previous invocation.
    key.push(live.as_ref().map(|r| r.id.clone()).unwrap_or_default());
    let (snapshot, ticket) = cx.try_global::<ReadSnapshots>()?.hover.begin(key);
    if let Some(ticket) = ticket {
        let ids = tab_ids.to_vec();
        let active = live.clone();
        let observed = admission::background_observation(cx, async move {
            let mut span =
                chau7_next_core::work_profiler::begin(chau7_next_core::work_profiler::Key::work(
                    "telemetry_snapshot",
                    "hover",
                    "telemetry",
                    "telemetry_snapshot",
                    chau7_next_core::work_profiler::Queue::Background,
                ));
            span.items(1);
            let before = recorder.store().failure_count();
            let run = active.or_else(|| {
                recorder
                    .store()
                    .list_runs(&TelemetryRunFilter {
                        limit: Some(1),
                        ..Default::default()
                    })
                    .into_iter()
                    .next()
                    .filter(|r| r.tab_id.as_ref().is_some_and(|t| ids.contains(t)))
            });
            let value = run.map(|run| {
                let mut tools = recorder.store().tool_call_summary(&run.id);
                tools.truncate(3);
                (run, tools)
            });
            let failed = recorder.store().failure_count() != before || before == u64::MAX;
            ticket.apply(if failed { Err(()) } else { Ok(value) });
        });
        cx.spawn(async move |cx| {
            if observed.await.is_ok() {
                cx.update(|cx| cx.refresh_windows());
            }
        })
        .detach();
    }
    // Live identity/status is cached authoritative recorder state; tools remain
    // absent until the worker observes them, instead of synchronously querying SQL.
    match (live, snapshot.value.flatten()) {
        (Some(run), stored) => Some((run, stored.map(|(_, tools)| tools).unwrap_or_default())),
        (None, stored) => stored,
    }
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
    let remote_recorder = recorder.clone();
    crate::remote::set_telemetry_sink(
        Box::new(move |event, _cx| {
            if let Err(error) = remote_recorder.record_remote_event(event) {
                log::warn!("Telemetry remote event rejected: {error}");
            }
        }),
        cx,
    );

    // DBG-018 to DBG-020, TEL-014, PRX-020.
    let rebuild_recorder = recorder.clone();
    crate::debug::set_analytics_source(
        cx,
        crate::debug::AnalyticsSource {
            data: std::rc::Rc::new(analytics_data),
            rebuild: Some(std::rc::Rc::new(move |cx: &mut App| {
                let Some(active) = cx
                    .try_global::<ReadSnapshots>()
                    .and_then(|s| s.repairs.begin())
                else {
                    log::warn!("Telemetry repair busy or stopped; request was not accepted");
                    return;
                };
                let recorder = rebuild_recorder.clone();
                cx.background_executor()
                    .spawn(async move {
                        let _active=active;
                        let report = recorder.rebuild_transcript_derived_runs(REPAIR_LIMIT);
                        log::info!(
                            "Telemetry repair: inspected={} rebuilt={} invalidated={} skipped={} failed={}",
                            report.inspected_runs,
                            report.rebuilt_runs,
                            report.invalidated_runs,
                            report.skipped_runs,report.failed_runs
                        );
                    })
                    .detach();
            })),
        },
    );

    // TEL-003: session ids from Claude Code hooks and the Codex history.
    crate::ai::events_out::subscribe(cx, move |event, _notify, cx| {
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
        let Ok(observed_at) = DateTime::parse_from_rfc3339(&event.ts) else {
            return;
        };
        let observed_at = observed_at.with_timezone(&Utc);
        let explicit_tab = event.tab_id.is_some();
        let terminal_tab = event
            .tab_id
            .and_then(|tab| terminal_tab_for_identity_event(tab, provider, directory, session, cx));
        let unresolved_explicit_tab = explicit_tab && terminal_tab.is_none();
        match recorder.associate_session_id_for_event(
            provider,
            directory,
            terminal_tab.as_deref(),
            unresolved_explicit_tab,
            session,
            observed_at,
        ) {
            Ok(outcome) if outcome != chau7_next_core::telemetry::recorder::IdentityAssociation::AlreadyAssociated => {
                log::debug!("Telemetry identity association: {}", outcome.as_str());
            }
            Ok(_) => {}
            Err(error) => log::warn!("Telemetry identity update rejected: {error}"),
        }
    });
}

/// Everything the Debug Console Analytics tab shows.
fn analytics_data(cx: &App) -> (Option<AnalyticsData>, Option<String>) {
    if let Some(recorder) = recorder(cx) {
        match recorder.store().readiness() {
            StoreReadiness::Loading => return (None, Some("Loading telemetry database".into())),
            StoreReadiness::Failed | StoreReadiness::Closed => {
                return (None, Some("Telemetry database is unavailable".into()));
            }
            StoreReadiness::Ready => (),
        }
    }
    let Some(snapshots) = cx.try_global::<ReadSnapshots>() else {
        return (None, Some("Analytics is unavailable".into()));
    };
    let (snapshot, ticket) = snapshots.analytics.begin(());
    if let (Some(ticket), Some(recorder)) = (ticket, recorder(cx)) {
        let root = cx.global::<AppData>().root.clone();
        let observed = admission::background_observation(cx, async move {
            let mut span =
                chau7_next_core::work_profiler::begin(chau7_next_core::work_profiler::Key::work(
                    "telemetry_snapshot",
                    "analytics",
                    "telemetry",
                    "telemetry_snapshot",
                    chau7_next_core::work_profiler::Queue::Background,
                ));
            span.items(1);
            let db = root.proxy_db();
            let proxy = ProxyAnalyticsStore::new(&db);
            let before = recorder.store().failure_count();
            let data = AnalyticsData {
                proxy_stats: proxy.overall_stats(None),
                proxy_providers: proxy.provider_stats(),
                proxy_daily: proxy.daily_trend(7),
                proxy_recent: proxy
                    .recent_calls(50)
                    .iter()
                    .map(|c| c.debug_call())
                    .collect(),
                run_providers: recorder.store().consumption_per_provider(None),
                run_tabs: recorder.store().token_usage_per_tab(None),
                run_daily: recorder.store().daily_cost_trend(7),
                run_count: recorder.store().run_count(),
                ..Default::default()
            };
            let failed = proxy.failure_count() > 0
                || recorder.store().failure_count() != before
                || before == u64::MAX;
            ticket.apply(if failed { Err(()) } else { Ok(data) });
        });
        cx.spawn(async move |cx| {
            if observed.await.is_ok() {
                cx.update(|cx| cx.refresh_windows());
            }
        })
        .detach();
    }
    let mut status = if snapshot.error {
        Some("Analytics unavailable; showing the last successful observation when present".into())
    } else if snapshot.pending {
        Some("Loading analytics; showing the last successful observation when present".into())
    } else {
        None
    };
    if let Some(recorder) = recorder(cx) {
        let writer = recorder.writer_status();
        if writer.rejected > 0 || writer.failed > 0 || !writer.accepting {
            status = Some(format!(
                "Telemetry writes: queued {}, completed {}, rejected {}, failed {}; {}",
                writer.accepted,
                writer.processed,
                writer.rejected,
                writer.failed,
                writer.last_error.as_deref().unwrap_or("admission closed")
            ));
        }
    }
    let Some(mut data) = snapshot.value else {
        return (None, status);
    };
    // Repository registry snapshots already schedule their own off-UI refresh.
    // Never read recent-repos.json or probe Git from a paint callback.
    let now = chrono::Utc::now();
    data.repos = crate::repository::known_roots(cx)
        .into_iter()
        .filter_map(|path| {
            let stats = crate::repository::stats(&path, cx)?;
            let last = [stats.last_command_at, stats.last_run_at]
                .into_iter()
                .flatten()
                .max();
            Some(RepoAnalytics {
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
            })
        })
        .collect();
    (Some(data), status)
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
    fn set_tags(&self, run_id: &str, tags: &[String]) -> Result<(), String> {
        // MCP dispatch is outside the UI thread. The reply acknowledges the
        // committed ordered prefix, including these tags, rather than admission.
        self.0.tag_run(run_id, tags).map_err(|e| e.to_string())?;
        self.0.flush().map_err(|e| e.to_string())?;
        Ok(())
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
        let live_id = source
            .0
            .run_started("TAB", "claude", "/repo", Some("/repo"), Some("session"))
            .unwrap();
        source.0.flush().unwrap();
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
        let id = source
            .0
            .run_started("TAB", "claude", "/repo", None, None)
            .unwrap();
        source.0.flush().unwrap();
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
        let next = source
            .0
            .run_started("TAB", "claude", "/repo", None, None)
            .unwrap();
        source.0.flush().unwrap();
        std::fs::write(&path, "second run").unwrap();
        assert_eq!(
            source.turns(&next)[0].content.as_deref(),
            Some("second run")
        );
        std::fs::remove_dir_all(dir).unwrap();
    }
}

#[cfg(test)]
mod shutdown_tests {
    use super::*;

    #[test]
    fn missing_writer_never_authorizes_clean_shutdown_even_when_sqlite_close_succeeds() {
        let store = Arc::new(TelemetryStore::in_memory());
        assert_eq!(store.readiness(), StoreReadiness::Ready);
        let shutdown = Shutdown {
            transcript: cache::Activity::new(1).stop(),
            reads: Vec::new(),
            maintenance: None,
            store: Some(store.clone()),
            writer: None,
        };
        // The actual background quit decision must retain this Err after close;
        // no SQLite handle remains, but the absent writer was never drained.
        let result = std::thread::spawn(move || shutdown.finish())
            .join()
            .unwrap();
        assert_eq!(
            result,
            Err("telemetry writer unavailable for shutdown".to_string())
        );
        assert_eq!(store.readiness(), StoreReadiness::Closed);
        store.close().unwrap();
    }
}

#[cfg(test)]
mod transcript_monitor_tests {
    use super::*;
    use chau7_next_core::telemetry::token_rate::{TokenRateSource, TokenRateStore};
    use std::time::Duration;

    fn callbacks() -> u64 {
        chau7_next_core::work_profiler::snapshot()["entries"]
            .as_array()
            .unwrap()
            .iter()
            .filter(|e| e["operation"] == "telemetry.transcript_rate")
            .map(|e| e["lifetime"]["sample_count"].as_u64().unwrap_or(0))
            .sum()
    }

    fn timer_active(cx: &App) -> bool {
        crate::observability::timer_inventory(cx)["timers"]
            .as_array()
            .unwrap()
            .iter()
            .any(|t| t["id"] == "telemetry.transcript_rate" && t["active"] == true)
    }

    #[gpui::test]
    fn idle_transcript_monitor_parks_resumes_and_keeps_active_cadence(
        harness: &mut gpui::TestAppContext,
    ) {
        let home =
            std::env::temp_dir().join(format!("c7-transcript-demand-{}", uuid::Uuid::new_v4()));
        let day = home
            .join(".codex/sessions")
            .join(chrono::Local::now().format("%Y/%m/%d").to_string());
        std::fs::create_dir_all(&day).unwrap();
        harness.on_quit({
            let home = home.clone();
            move || {
                let _ = std::fs::remove_dir_all(home);
            }
        });
        let native = uuid::Uuid::new_v4().to_string();
        let path = day.join(format!("rollout-test-{native}.jsonl"));
        let at = Utc::now();
        let event = |seconds, payload: Value| {
            serde_json::json!({
                "type": "event_msg",
                "timestamp": (at + chrono::Duration::seconds(seconds)).to_rfc3339(),
                "payload": payload,
            })
            .to_string()
                + "\n"
        };
        let tokens = |total| {
            serde_json::json!({"type":"token_count", "info":{
                "last_token_usage":{"output_tokens":20}, "total_token_usage":{"output_tokens":total},
            }})
        };
        std::fs::write(
            &path,
            event(0, serde_json::json!({"type":"task_started"})) + &event(1, tokens(20)),
        )
        .unwrap();
        let before = callbacks();
        harness.update(|cx| {
            crate::observability::init_for_test(cx);
            let recorder = Arc::new(TelemetryRecorder::new(
                Arc::new(TelemetryStore::in_memory()),
                vec![],
            ));
            let rates = Arc::new(Mutex::new(TokenRateStore::default()));
            cx.set_global(TelemetryGlobal(recorder.clone()));
            cx.set_global(TokenRates(rates.clone()));
            start_transcript_monitor(home, recorder, rates, cx);
        });
        harness.run_until_parked();
        let parked = callbacks();
        assert!(
            parked > before,
            "exercise initial discovery before asserting a parked worker"
        );
        harness.executor().advance_clock(Duration::from_secs(2));
        harness.run_until_parked();
        assert_eq!(callbacks(), parked, "no timer callbacks without AI runs");
        assert!(!harness.update(|cx| timer_active(cx)));

        // Missing native identity must not park a live CLI or prevent later binding.
        harness.update(|cx| run_started("TAB", "codex", "/fixture", None, None, cx));
        harness.run_until_parked();
        let started = callbacks();
        assert!(started > parked, "new run must wake discovery immediately");
        assert!(harness.update(|cx| timer_active(cx)));
        harness.executor().advance_clock(Duration::from_millis(200));
        harness.run_until_parked();
        assert!(
            callbacks() > started,
            "a silent active CLI retains its polling cadence"
        );

        harness.update(|cx| update_session_id("TAB", &native, cx));
        harness.run_until_parked();
        let reading = harness
            .update(|cx| token_rate("TAB", cx))
            .expect("late identity must read its transcript");
        assert_eq!(reading.source, TokenRateSource::CodexTranscript);
        assert_eq!(reading.output_tokens, 20);
        let bound = callbacks();
        for _ in 0..32 {
            harness.update(|cx| update_session_id("TAB", &native, cx));
            harness.run_until_parked();
        }
        assert_eq!(
            callbacks(),
            bound,
            "unchanged identity must not trigger reads"
        );

        use std::io::Write as _;
        std::fs::OpenOptions::new()
            .append(true)
            .open(&path)
            .unwrap()
            .write_all(event(2, tokens(40)).as_bytes())
            .unwrap();
        harness.executor().advance_clock(Duration::from_millis(200));
        harness.run_until_parked();
        let reading = harness.update(|cx| token_rate("TAB", cx)).unwrap();
        assert_eq!(reading.updated_at, at + chrono::Duration::seconds(2));

        harness.update(|cx| run_ended("TAB", Some(0), Some(&native), None, None, cx));
        harness.run_until_parked();
        assert!(!harness.update(|cx| timer_active(cx)));
        let ended = callbacks();
        harness.executor().advance_clock(Duration::from_secs(2));
        harness.run_until_parked();
        assert_eq!(
            callbacks(),
            ended,
            "last exit must clear caches and park again"
        );
        assert_eq!(
            harness
                .update(|cx| token_rate("TAB", cx))
                .unwrap()
                .updated_at,
            reading.updated_at,
            "exit retains the historical reading without further writes"
        );

        // A bounded burst coalesces, then another run can wake the same worker.
        harness.update(|cx| {
            for _ in 0..4096 {
                wake_transcript_monitor(cx);
            }
            run_started("TAB", "codex", "/fixture", None, Some(&native), cx);
        });
        harness.run_until_parked();
        assert!(callbacks() > ended);
        assert!(harness.update(|cx| token_rate("TAB", cx)).is_some());
        harness.update(|cx| {
            drop(cx.global_mut::<TranscriptMonitor>().task.take());
        });
        harness.run_until_parked();
        assert!(
            !harness.update(|cx| timer_active(cx)),
            "cancellation must retire the timer"
        );
        let cancelled = callbacks();
        harness.executor().advance_clock(Duration::from_secs(2));
        harness.run_until_parked();
        assert_eq!(callbacks(), cancelled);
    }
}
