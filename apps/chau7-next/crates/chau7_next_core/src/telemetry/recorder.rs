//! Ports of `Telemetry/TelemetryRecorder.swift` and
//! `TelemetryRepairService.swift`: one run per AI CLI session in a tab,
//! started when the CLI is detected and finished when it exits, with the
//! transcript read from the CLI's own files (or the terminal as a fallback).
//!
//! The recorder is shared between threads: the app starts and ends runs on
//! the main thread and does the slow part ([`TelemetryRecorder::complete`],
//! reading transcripts) on a background thread.

mod writer;
use writer::Writer;
pub use writer::{AdmissionError, WriterShutdown, WriterStatus};

use std::collections::HashMap;
use std::io::{Read, Seek, SeekFrom};
use std::path::Path;
use std::sync::{Arc, Mutex};

use chrono::Utc;

use super::metrics_sanitizer;
use super::run::{TelemetryRun, TelemetryRunFilter};
use super::run_content::RunContentProvider;
use super::store::TelemetryStore;
use super::token_metrics::TelemetryMetricState;
use super::turn::{TelemetryToolCall, TelemetryTurn, TurnRole};
use crate::escape_sanitizer;

/// Bytes of the PTY log read for the fallback transcript.
pub const PTY_LOG_TAIL_BYTES: u64 = 1_024_000;

#[derive(Default)]
struct Active {
    /// Tab identifier -> run in progress.
    by_tab: HashMap<String, String>,
    /// Run id -> run.
    runs: HashMap<String, TelemetryRun>,
}

type InitializeStore = Box<dyn FnOnce(&TelemetryStore) -> Result<(), String> + Send>;

pub struct TelemetryRecorder {
    store: Arc<TelemetryStore>,
    providers: Arc<Vec<Box<dyn RunContentProvider>>>,
    writer: Writer,
    active: Mutex<Active>,
}

impl TelemetryRecorder {
    pub fn new(store: Arc<TelemetryStore>, providers: Vec<Box<dyn RunContentProvider>>) -> Self {
        let writer = Writer::new(store.clone());
        Self {
            store,
            providers: Arc::new(providers),
            writer,
            active: Mutex::new(Active::default()),
        }
    }

    /// Memory-only construction on UI. Open/migrate is the first ordered job,
    /// so later admitted run IDs never overtake initialization.
    pub fn open_background(path: &Path, providers: Vec<Box<dyn RunContentProvider>>) -> Self {
        Self::with_initializer(
            path,
            providers,
            Box::new(|store| {
                store
                    .initialize_background()
                    .map_err(|_| "telemetry initialization failed".into())
            }),
        )
    }
    fn with_initializer(
        path: &Path,
        providers: Vec<Box<dyn RunContentProvider>>,
        initialize: InitializeStore,
    ) -> Self {
        let store = Arc::new(TelemetryStore::pending(path));
        let recorder = Self::new(store.clone(), providers);
        if recorder
            .writer
            .admit(
                "initialize",
                0,
                Box::new(move |store| {
                    // The guard includes any initializer failure/unwind before open.
                    struct Wake<'a>(&'a TelemetryStore);
                    impl Drop for Wake<'_> {
                        fn drop(&mut self) {
                            self.0.fail_initialization();
                        }
                    }
                    let _wake = Wake(store);
                    initialize(store)
                }),
            )
            .is_err()
        {
            store.fail_initialization();
        }
        recorder
    }

    pub fn store(&self) -> &Arc<TelemetryStore> {
        &self.store
    }

    pub fn writer_status(&self) -> WriterStatus {
        self.writer.status()
    }
    /// Background-only durability barrier, never a UI/render call.
    pub fn flush(&self) -> Result<(), AdmissionError> {
        self.writer.flush()
    }
    /// Close the sole admission sender now; join/drain the returned handle off UI.
    pub fn shutdown(&self) -> Option<WriterShutdown> {
        self.writer.shutdown()
    }
    pub fn record_latency(
        &self,
        sample: super::latency::LatencySample,
    ) -> Result<(), AdmissionError> {
        let bytes = serde_json::to_vec(&sample).map_or(usize::MAX, |v| v.len());
        self.writer.admit(
            "latency",
            bytes,
            Box::new(move |store| {
                store
                    .try_insert_latency_sample(&sample)
                    .map_err(|e| e.to_string())
            }),
        )
    }
    pub fn record_remote_event(
        &self,
        event: super::remote_client_event::RemoteClientTelemetryEvent,
    ) -> Result<(), AdmissionError> {
        let bytes = serde_json::to_vec(&event).map_or(usize::MAX, |v| v.len());
        self.writer.admit(
            "remote_event",
            bytes,
            Box::new(move |store| {
                store
                    .try_insert_remote_client_event(&event)
                    .map_err(|e| e.to_string())
            }),
        )
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, Active> {
        self.active.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// TEL-001: preassign a run ID and admit its insert without SQLite or
    /// waiting. Err means no active run/ID was accepted. Ok is queued, not a
    /// claim of committed persistence; writer_status exposes pending/failures.
    pub fn run_started(
        &self,
        tab_id: &str,
        provider: &str,
        cwd: &str,
        repo_path: Option<&str>,
        session_id: Option<&str>,
    ) -> Result<String, AdmissionError> {
        let mut run = TelemetryRun::new(provider, cwd);
        run.session_id = session_id.filter(|s| !s.is_empty()).map(str::to_string);
        run.tab_id = Some(tab_id.to_string());
        run.repo_path = repo_path.map(str::to_string);
        let id = run.id.clone();
        let mut active = self.lock();
        let queued = run.clone();
        self.writer.admit(
            "start",
            run_bytes(&run),
            Box::new(move |store| store.try_insert_run(&queued).map_err(|e| e.to_string())),
        )?;
        if let Some(previous) = active.by_tab.insert(tab_id.to_string(), id.clone()) {
            active.runs.remove(&previous);
        }
        active.runs.insert(id.clone(), run);
        Ok(id)
    }

    /// TEL-002, first half: the AI CLI exited. The run leaves the active
    /// list with its end time, duration and exit status; pass it to
    /// [`Self::complete`] to read its content and save it.
    pub fn run_ended(&self, tab_id: &str, exit_status: Option<i64>) -> Option<TelemetryRun> {
        let mut run = {
            let mut active = self.lock();
            let id = active.by_tab.remove(tab_id)?;
            active.runs.remove(&id)?
        };
        let ended = Utc::now();
        run.ended_at = Some(ended);
        run.exit_status = exit_status;
        run.duration_ms = Some((ended - run.started_at).num_milliseconds());
        Some(run)
    }

    /// Background-only synchronous completion API. Extraction and persistence
    /// run off UI; flush is an actual ordered barrier, not a sleep/assertion.
    pub fn complete(
        &self,
        run: TelemetryRun,
        terminal_buffer: Option<String>,
        pty_log_path: Option<&Path>,
    ) -> Result<TelemetryRun, AdmissionError> {
        let (run, turns, tools) =
            extract_content(&self.providers, run, terminal_buffer, pty_log_path);
        let saved = run.clone();
        let bytes = serde_json::to_vec(&(&run, &turns, &tools)).map_or(usize::MAX, |v| v.len());
        self.writer.admit(
            "finalize",
            bytes,
            Box::new(move |store| {
                store
                    .try_finalize_run(&saved, &turns, &tools)
                    .map_err(|e| e.to_string())
            }),
        )?;
        self.flush()?;
        Ok(run)
    }
    /// Admit completion on the UI exit callback, including extraction, so
    /// no detached delayed producer can outlive quit's admission close.
    pub fn enqueue_completion(
        &self,
        run: TelemetryRun,
        terminal_buffer: Option<String>,
        pty_log_path: Option<std::path::PathBuf>,
    ) -> Result<(), AdmissionError> {
        let bytes = run_bytes(&run)
            .saturating_add(terminal_buffer.as_ref().map_or(0, String::len))
            .saturating_add(pty_log_path.as_ref().map_or(0, |p| p.as_os_str().len()));
        let providers = self.providers.clone();
        let ready_at = std::time::Instant::now() + std::time::Duration::from_millis(500);
        self.writer.admit(
            "completion",
            bytes,
            Box::new(move |store| {
                std::thread::sleep(ready_at.saturating_duration_since(std::time::Instant::now()));
                let (run, turns, tools) =
                    extract_content(&providers, run, terminal_buffer, pty_log_path.as_deref());
                store
                    .try_finalize_run(&run, &turns, &tools)
                    .map_err(|e| e.to_string())
            }),
        )
    }

    /// TEL-003: the session id of a tab's running run became known.
    pub fn update_session_id(&self, tab_id: &str, session_id: &str) -> Result<(), AdmissionError> {
        let mut active = self.lock();
        let Some(id) = active.by_tab.get(tab_id).cloned() else {
            return Ok(());
        };
        let Some(run) = active.runs.get_mut(&id) else {
            return Ok(());
        };
        if run.session_id.as_deref() == Some(session_id) {
            return Ok(());
        }
        let session = session_id.to_string();
        let bytes = id.len().saturating_add(session.len());
        let queued = session.clone();
        self.writer.admit(
            "session",
            bytes,
            Box::new(move |store| {
                store
                    .try_update_run_session_id(&id, &queued)
                    .map_err(|e| e.to_string())
            }),
        )?;
        run.session_id = Some(session);
        Ok(())
    }

    /// TEL-003: a session id from a monitor that does not know the tab
    /// (Claude hooks, Codex history), matched by provider and folder (same
    /// folder, parent or child). Only runs without a session id are taken.
    pub fn update_session_id_by_cwd(
        &self,
        provider: &str,
        cwd: &str,
        session_id: &str,
    ) -> Result<(), AdmissionError> {
        let provider = provider.to_lowercase();
        let tab = self
            .lock()
            .runs
            .values()
            .find(|run| {
                run.provider.to_lowercase().contains(&provider)
                    && run.session_id.as_deref().is_none_or(str::is_empty)
                    && folders_related(&run.cwd, cwd)
            })
            .and_then(|run| run.tab_id.clone());
        if let Some(tab) = tab {
            self.update_session_id(&tab, session_id)?;
        }
        Ok(())
    }
    /// TEL-009: atomically admit the ordered update before changing memory.
    pub fn tag_run(&self, run_id: &str, tags: &[String]) -> Result<(), AdmissionError> {
        let id = run_id.to_string();
        let queued = tags.to_vec();
        let bytes = id
            .len()
            .saturating_add(queued.iter().map(String::len).sum::<usize>());
        let mut active = self.lock();
        self.writer.admit(
            "tags",
            bytes,
            Box::new(move |store| {
                store
                    .try_update_run_tags(&id, &queued)
                    .map_err(|e| e.to_string())
            }),
        )?;
        if let Some(run) = active.runs.get_mut(run_id) {
            run.tags = tags.to_vec();
        }
        Ok(())
    }

    pub fn active_run_for_tab(&self, tab_id: &str) -> Option<TelemetryRun> {
        let active = self.lock();
        let id = active.by_tab.get(tab_id)?;
        active.runs.get(id).cloned()
    }

    pub fn all_active_runs(&self) -> Vec<TelemetryRun> {
        self.lock().runs.values().cloned().collect()
    }

    /// TEL-014: re-extract the last `limit` finished Claude and Codex runs
    /// and rewrite (or invalidate) them (`TelemetryRepairService`).
    pub fn rebuild_transcript_derived_runs(&self, limit: i64) -> RepairReport {
        let runs = self.store.list_runs(&TelemetryRunFilter {
            limit: Some(limit),
            ..Default::default()
        });
        let mut report = RepairReport::default();
        for mut run in runs.into_iter().filter(|run| {
            let p = run.provider.to_lowercase();
            run.ended_at.is_some()
                && (p.contains("claude")
                    || p.contains("codex")
                    || p.contains("anthropic")
                    || p.contains("openai"))
        }) {
            report.inspected_runs += 1;
            let Some(provider) = self.providers.iter().find(|p| p.can_handle(&run.provider)) else {
                report.skipped_runs += 1;
                continue;
            };
            let Some(content) = provider.extract_content(
                &run.id,
                run.session_id.as_deref(),
                &run.cwd,
                run.started_at,
            ) else {
                if self
                    .store
                    .try_invalidate_run_metrics(
                        &run.id,
                        Some("historical transcript repair failed to extract content"),
                    )
                    .is_ok()
                {
                    report.invalidated_runs += 1;
                } else {
                    report.failed_runs += 1;
                }
                continue;
            };
            let (repaired, warning) = metrics_sanitizer::sanitize(&content, &run.provider);
            if let Some(warning) = warning {
                log::warn!("TelemetryRepairService: {warning} run={}", run.id);
            }
            const REPAIR_INVALID: &str =
                "historical transcript repair invalidated implausible token metrics";
            run.model = repaired.model.clone().or(run.model);
            run.total_input_tokens = repaired.total_input_tokens;
            run.total_cached_input_tokens = repaired.total_cached_input_tokens;
            run.total_cache_creation_input_tokens = repaired.total_cache_creation_input_tokens;
            run.total_cache_read_input_tokens = repaired.total_cache_read_input_tokens;
            run.total_output_tokens = repaired.total_output_tokens;
            run.total_reasoning_output_tokens = repaired.total_reasoning_output_tokens;
            let observed_cost = if run.cost_source
                == Some(super::token_metrics::CostSource::Observed)
                && repaired.token_usage_state != TelemetryMetricState::Invalid
            {
                run.cost_usd
            } else {
                None
            };
            run.cost_usd = observed_cost.or(repaired.cost_usd);
            run.token_usage_source = repaired.token_usage_source;
            run.token_usage_state = repaired.token_usage_state;
            run.cost_source = repaired.cost_source;
            run.cost_state = repaired.cost_state;
            if observed_cost.is_some() {
                run.cost_source = Some(super::token_metrics::CostSource::Observed);
                run.cost_state = TelemetryMetricState::Complete;
            } else if run.cost_source == Some(super::token_metrics::CostSource::Estimated) {
                run.metadata.insert(
                    "pricing_catalog_version".into(),
                    super::pricing::VERSION.into(),
                );
            }
            run.raw_transcript_ref = repaired.raw_transcript_ref.clone();
            run.turn_count = repaired.turns.len() as i64;
            let invalid = repaired.token_usage_state == TelemetryMetricState::Invalid;
            if invalid {
                run.error_message = Some(REPAIR_INVALID.into());
            } else if run.error_message.as_deref() == Some(REPAIR_INVALID) {
                run.error_message = None;
            }
            if self
                .store
                .try_rewrite_completed_run(&run, &repaired.turns, &repaired.tool_calls)
                .is_err()
            {
                report.failed_runs += 1;
                continue;
            }
            if invalid {
                report.invalidated_runs += 1;
            } else {
                report.rebuilt_runs += 1;
            }
        }
        report
    }
}

/// What a transcript repair did.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct RepairReport {
    pub inspected_runs: usize,
    pub rebuilt_runs: usize,
    pub invalidated_runs: usize,
    pub skipped_runs: usize,
    pub failed_runs: usize,
}

/// Same folder, or one inside the other.
fn extract_content(
    providers: &[Box<dyn RunContentProvider>],
    mut run: TelemetryRun,
    terminal_buffer: Option<String>,
    pty_log_path: Option<&Path>,
) -> (TelemetryRun, Vec<TelemetryTurn>, Vec<TelemetryToolCall>) {
    let mut turns: Vec<TelemetryTurn> = Vec::new();
    let mut tool_calls: Vec<TelemetryToolCall> = Vec::new();
    if let Some(provider) = providers.iter().find(|p| p.can_handle(&run.provider)) {
        match provider.extract_content(&run.id, run.session_id.as_deref(), &run.cwd, run.started_at)
        {
            Some(content) => {
                let (content, warning) = metrics_sanitizer::sanitize(&content, &run.provider);
                if let Some(warning) = warning {
                    log::warn!("TelemetryRecorder: {warning} run={}", run.id);
                }
                run.model = content.model.clone().or(run.model);
                run.total_input_tokens = content.total_input_tokens;
                run.total_cached_input_tokens = content.total_cached_input_tokens;
                run.total_cache_creation_input_tokens = content.total_cache_creation_input_tokens;
                run.total_cache_read_input_tokens = content.total_cache_read_input_tokens;
                run.total_output_tokens = content.total_output_tokens;
                run.total_reasoning_output_tokens = content.total_reasoning_output_tokens;
                run.cost_usd = content.cost_usd;
                run.token_usage_source = content.token_usage_source;
                run.token_usage_state = content.token_usage_state;
                run.cost_source = content.cost_source;
                run.cost_state = content.cost_state;
                if run.cost_source == Some(super::token_metrics::CostSource::Estimated) {
                    run.metadata.insert(
                        "pricing_catalog_version".into(),
                        super::pricing::VERSION.into(),
                    );
                }
                run.raw_transcript_ref = content.raw_transcript_ref.clone();
                run.turn_count = content.turns.len() as i64;
                if content.token_usage_state == TelemetryMetricState::Invalid {
                    run.error_message =
                        Some("invalidated implausible token metrics during extraction".into());
                }
                turns = content.turns;
                tool_calls = content.tool_calls;
                log::info!(
                    "TelemetryRecorder: extracted {} turns, {} tool calls, model={}",
                    turns.len(),
                    tool_calls.len(),
                    run.model.as_deref().unwrap_or("?")
                );
            }
            None => log::warn!(
                "TelemetryRecorder: content extraction returned nil for run {} session={} cwd={}",
                run.id,
                run.session_id.as_deref().unwrap_or("nil"),
                run.cwd
            ),
        }
    } else {
        log::trace!(
            "TelemetryRecorder: no content provider for {}",
            run.provider
        );
    }

    if turns.is_empty() {
        let mut fallback = pty_log_path
            .and_then(|p| read_pty_log_tail(p, PTY_LOG_TAIL_BYTES))
            .map(|text| (text, "pty_log"));
        if fallback.is_none() {
            fallback = terminal_buffer
                .map(|t| t.trim().to_string())
                .filter(|t| !t.is_empty())
                .map(|text| (text, "terminal_buffer"));
        }
        if let Some((text, source)) = fallback {
            log::info!(
                "TelemetryRecorder: using {source} fallback ({} chars) for run {}",
                text.chars().count(),
                run.id
            );
            let mut turn = TelemetryTurn::new(&run.id, 0, TurnRole::Assistant);
            turn.id = format!("{}-t0", run.id);
            turn.content = Some(text);
            turn.timestamp = run.ended_at;
            turns = vec![turn];
            run.turn_count = 1;
            run.raw_transcript_ref = Some(source.to_string());
        }
    }

    (run, turns, tool_calls)
}

fn run_bytes(run: &TelemetryRun) -> usize {
    // Upper bound JSON escaping without serializing a run on UI admission.
    1024usize.saturating_add(
        [
            Some(run.id.as_str()),
            Some(run.provider.as_str()),
            Some(run.cwd.as_str()),
            run.session_id.as_deref(),
            run.repo_path.as_deref(),
            run.tab_id.as_deref(),
            run.model.as_deref(),
            run.raw_transcript_ref.as_deref(),
            run.parent_run_id.as_deref(),
            run.error_message.as_deref(),
        ]
        .into_iter()
        .flatten()
        .map(str::len)
        .chain(run.tags.iter().map(String::len))
        .chain(run.metadata.iter().map(|(k, v)| k.len() + v.len()))
        .sum::<usize>()
        .saturating_mul(6),
    )
}

fn folders_related(a: &str, b: &str) -> bool {
    a == b || a.starts_with(&format!("{b}/")) || b.starts_with(&format!("{a}/"))
}

/// The readable tail of a PTY log (`readPTYLogTail`): the last `max_bytes`,
/// escape sequences stripped, lines trimmed, at most two blank lines in a
/// row. `None` when the file is missing or has no text.
pub fn read_pty_log_tail(path: &Path, max_bytes: u64) -> Option<String> {
    let mut file = std::fs::File::open(path).ok()?;
    let size = file.metadata().ok()?.len();
    if size > max_bytes {
        file.seek(SeekFrom::Start(size - max_bytes)).ok()?;
    }
    let mut data = Vec::new();
    file.read_to_end(&mut data).ok()?;
    if data.is_empty() {
        return None;
    }
    let raw = String::from_utf8_lossy(&data);
    let stripped = escape_sanitizer::sanitize(&raw);
    let mut result: Vec<&str> = Vec::new();
    let mut empty_run = 0;
    for line in stripped.split('\n') {
        let trimmed = line.trim_matches([' ', '\t', '\r']);
        if trimmed.is_empty() {
            empty_run += 1;
            if empty_run <= 2 {
                result.push("");
            }
        } else {
            empty_run = 0;
            result.push(trimmed);
        }
    }
    let text = result.join("\n").trim().to_string();
    (!text.is_empty()).then_some(text)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::telemetry::run_content::ExtractedRunContent;
    use chrono::DateTime;

    struct Fixed(Option<ExtractedRunContent>);
    impl RunContentProvider for Fixed {
        fn provider_name(&self) -> &str {
            "claude"
        }
        fn can_handle(&self, provider: &str) -> bool {
            provider.contains("claude")
        }
        fn extract_content(
            &self,
            run_id: &str,
            _: Option<&str>,
            _: &str,
            _: DateTime<Utc>,
        ) -> Option<ExtractedRunContent> {
            self.0.clone().map(|mut c| {
                let mut turn = TelemetryTurn::new(run_id, 0, TurnRole::Assistant);
                turn.content = Some("x".into());
                c.turns = vec![turn];
                c
            })
        }
    }

    fn recorder(content: Option<ExtractedRunContent>) -> TelemetryRecorder {
        TelemetryRecorder::new(
            Arc::new(TelemetryStore::in_memory()),
            vec![Box::new(Fixed(content))],
        )
    }

    #[test]
    fn background_open_is_first_and_queued_runs_drain_durably_without_ui_filesystem_work() {
        use super::super::store::StoreReadiness;
        use std::sync::mpsc;
        let directory =
            std::env::temp_dir().join(format!("next-bootstrap-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir(&directory).unwrap();
        let path = directory.join("nested/owned.db");
        let caller = std::thread::current().id();
        let (started, entered) = mpsc::channel();
        let (release, released) = mpsc::channel();
        let recorder = TelemetryRecorder::with_initializer(
            &path,
            Vec::new(),
            Box::new(move |store| {
                started.send(std::thread::current().id()).unwrap();
                released.recv().unwrap();
                store
                    .initialize_background()
                    .map_err(|_| "owned initialize failed".into())
            }),
        );
        assert_ne!(entered.recv().unwrap(), caller);
        assert_eq!(recorder.store().readiness(), StoreReadiness::Loading);
        assert!(!path.parent().unwrap().exists());
        let id = recorder
            .run_started("owned-tab", "owned-fake", "/synthetic", None, None)
            .unwrap();
        recorder
            .update_session_id("owned-tab", "owned-native-id")
            .unwrap();
        recorder.tag_run(&id, &["owned-tag".into()]).unwrap();
        let run = recorder.run_ended("owned-tab", Some(0)).unwrap();
        recorder
            .enqueue_completion(run, Some("owned-terminal-evidence".into()), None)
            .unwrap();
        assert_eq!(recorder.writer_status().accepted, 5);
        // All of those admissions returned while even the parent directory was
        // absent, proving they neither opened SQLite nor overtook its first job.
        assert!(!path.exists());
        let store = recorder.store().clone();
        let reader = store.clone();
        let waiting = std::thread::spawn(move || reader.wait_until_initialized());
        release.send(()).unwrap();
        waiting.join().unwrap().unwrap();
        recorder.flush().unwrap();
        let saved = store.get_run(&id).unwrap();
        assert_eq!(saved.session_id.as_deref(), Some("owned-native-id"));
        assert_eq!(saved.tags, vec!["owned-tag"]);
        assert!(saved.ended_at.is_some());
        assert_eq!(
            store.get_turns(&id)[0].content.as_deref(),
            Some("owned-terminal-evidence")
        );
        let shutdown = recorder.shutdown().unwrap();
        assert!(recorder.shutdown().is_none());
        let closed = store.clone();
        let outcome = std::thread::spawn(move || {
            let outcome = shutdown.finish().unwrap();
            closed.close().unwrap();
            outcome
        })
        .join()
        .unwrap();
        assert_eq!(outcome.accepted, outcome.processed);
        assert_eq!(outcome.failed, 0);
        assert_eq!(store.readiness(), StoreReadiness::Closed);
        std::fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn failed_background_open_wakes_readers_and_reports_accepted_write_failures() {
        use super::super::store::StoreReadiness;
        let directory =
            std::env::temp_dir().join(format!("next-bootstrap-failure-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir(&directory).unwrap();
        let parent = directory.join("regular-parent");
        std::fs::write(&parent, b"owned-preserved").unwrap();
        let recorder = TelemetryRecorder::open_background(&parent.join("owned.db"), Vec::new());
        recorder
            .run_started("owned", "fake", "/synthetic", None, None)
            .unwrap();
        assert_eq!(recorder.flush(), Err(AdmissionError::PersistenceFailed));
        assert!(recorder.store().wait_until_initialized().is_err());
        assert_eq!(recorder.store().readiness(), StoreReadiness::Failed);
        let store = recorder.store().clone();
        let shutdown = recorder.shutdown().unwrap();
        let outcome = std::thread::spawn(move || {
            let outcome = shutdown.finish().unwrap();
            store.close().unwrap();
            outcome
        })
        .join()
        .unwrap();
        assert_eq!(outcome.accepted, outcome.processed);
        assert_eq!(outcome.failed, 2); // initialization plus the actual admitted insert
        assert_eq!(std::fs::read(parent).unwrap(), b"owned-preserved");
        std::fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn unwinding_initializer_wakes_waiters_and_shutdown_reports_the_panic() {
        let directory =
            std::env::temp_dir().join(format!("next-bootstrap-panic-{}", uuid::Uuid::new_v4()));
        let recorder = TelemetryRecorder::with_initializer(
            &directory.join("owned.db"),
            Vec::new(),
            Box::new(|_| panic!("owned initializer failure")),
        );
        assert!(recorder.store().wait_until_initialized().is_err());
        let shutdown = recorder.shutdown().unwrap();
        assert!(
            std::thread::spawn(move || shutdown.finish())
                .join()
                .unwrap()
                .is_err()
        );
        recorder.store().close().unwrap();
        assert!(!directory.exists());
    }

    #[test]
    fn actual_sql_mutex_does_not_block_admission_and_ordered_shutdown_persists_identity_and_content()
     {
        use std::sync::mpsc;
        let directory =
            std::env::temp_dir().join(format!("next-telemetry-admission-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&directory).unwrap();
        let store = Arc::new(TelemetryStore::open(&directory.join("owned.db")));
        let rec = Arc::new(TelemetryRecorder::new(store.clone(), vec![]));
        let (locked_tx, locked_rx) = mpsc::channel();
        let (release_tx, release_rx) = mpsc::channel();
        let blocked_store = store.clone();
        let blocker =
            std::thread::spawn(move || blocked_store.hold_connection_test(locked_tx, release_rx));
        locked_rx.recv().unwrap();
        let producer = rec.clone();
        let (result_tx, result_rx) = mpsc::channel();
        let producer = std::thread::spawn(move || {
            let id = producer
                .run_started("TAB", "owned-fake", "/synthetic", None, None)
                .unwrap();
            producer
                .update_session_id("TAB", "owned-native-id")
                .unwrap();
            producer.tag_run(&id, &["owned-tag".into()]).unwrap();
            producer
                .record_latency(super::super::latency::LatencySample {
                    id: "owned-latency".into(),
                    provider: "owned-fake".into(),
                    metric_kind: super::super::latency::MetricKind::FirstResponse,
                    latency_ms: 12,
                    timestamp: Utc::now(),
                    model: None,
                    session_id: Some("owned-native-id".into()),
                    run_id: Some(id.clone()),
                    round_index: None,
                    project_path: None,
                    source_kind: "owned-synthetic".into(),
                })
                .unwrap();
            producer.record_remote_event(super::super::remote_client_event::RemoteClientTelemetryEvent::new("owned-fake",super::super::remote_client_event::RemoteClientTelemetryEventType::TabSwitched)).unwrap();
            let ended = producer.run_ended("TAB", Some(0)).unwrap();
            producer
                .enqueue_completion(ended, Some("owned fallback transcript".into()), None)
                .unwrap();
            assert_eq!(
                producer.store().readiness(),
                super::super::store::StoreReadiness::Ready
            );
            assert_eq!(producer.store().failure_count(), 0);
            assert_eq!(producer.writer_status().accepted, 6);
            result_tx.send(id).unwrap();
        });
        // A bounded watchdog diagnoses regression; release happens even on
        // failure, so no synthetic thread or SQLite handle is left behind.
        let admitted = result_rx.recv_timeout(std::time::Duration::from_secs(2));
        release_tx.send(()).unwrap();
        blocker.join().unwrap();
        producer.join().unwrap();
        let id = admitted.expect("UI admission must not wait for the real SQLite mutex");
        let shutdown = rec.shutdown().unwrap();
        assert!(rec.shutdown().is_none());
        let outcome = std::thread::spawn(move || shutdown.finish().unwrap())
            .join()
            .unwrap();
        assert_eq!(outcome.accepted, 6);
        assert_eq!(outcome.processed, 6);
        assert_eq!(outcome.failed, 0);
        assert_eq!(outcome.pending_bytes, 0);
        assert_eq!(
            store
                .latency_samples(None)
                .iter()
                .filter(|s| s.id == "owned-latency")
                .count(),
            1
        );
        assert_eq!(store.list_remote_client_events(10).len(), 1);
        let row = store.get_run(&id).unwrap();
        assert_eq!(row.id, id);
        assert_eq!(row.session_id.as_deref(), Some("owned-native-id"));
        assert_eq!(row.tags, ["owned-tag"]);
        assert!(row.ended_at.is_some());
        assert_eq!(
            store.get_turns(&id)[0].content.as_deref(),
            Some("owned fallback transcript")
        );
        drop(rec);
        drop(store);
        std::fs::remove_dir_all(directory).unwrap();
    }
    #[test]
    fn failed_start_admission_never_publishes_an_id_or_orphan_update() {
        use std::sync::mpsc;
        let store = Arc::new(TelemetryStore::in_memory());
        let rec = TelemetryRecorder {
            store: store.clone(),
            providers: Arc::new(vec![]),
            writer: Writer::with_limits(store.clone(), 1, 4096),
            active: Mutex::new(Active::default()),
        };
        let (started_tx, started_rx) = mpsc::channel();
        let (release_tx, release_rx) = mpsc::channel();
        rec.writer
            .admit(
                "blocked",
                0,
                Box::new(move |_| {
                    started_tx.send(()).unwrap();
                    release_rx.recv().unwrap();
                    Ok(())
                }),
            )
            .unwrap();
        started_rx.recv().unwrap();
        let admitted = rec
            .run_started("accepted", "fake", "/owned", None, None)
            .unwrap();
        assert_eq!(
            rec.run_started("rejected", "fake", "/owned", None, None),
            Err(AdmissionError::Full)
        );
        assert!(rec.active_run_for_tab("rejected").is_none());
        assert_eq!(
            rec.run_started("oversize", "fake", &"x".repeat(4096), None, None),
            Err(AdmissionError::Oversize)
        );
        rec.update_session_id("rejected", "native").unwrap();
        let shutdown = rec.shutdown().unwrap();
        assert_eq!(
            rec.run_started("closed", "fake", "/owned", None, None),
            Err(AdmissionError::Closed)
        );
        release_tx.send(()).unwrap();
        let outcome = std::thread::spawn(move || shutdown.finish().unwrap())
            .join()
            .unwrap();
        assert_eq!(outcome.rejected, 3);
        assert_eq!(outcome.failed, 0);
        assert_eq!(store.run_count(), 1);
        assert_eq!(
            store.get_run(&admitted).unwrap().tab_id.as_deref(),
            Some("accepted")
        );
    }

    #[test]
    fn run_lifecycle_with_provider_content() {
        let rec = recorder(Some(ExtractedRunContent {
            model: Some("m".into()),
            total_input_tokens: Some(10),
            ..Default::default()
        }));
        let id = rec
            .run_started("TAB", "claude", "/p", Some("/p"), None)
            .unwrap();
        assert_eq!(rec.active_run_for_tab("TAB").unwrap().id, id);
        assert_eq!(rec.all_active_runs().len(), 1);
        rec.update_session_id("TAB", "S1").unwrap();
        rec.flush().unwrap();
        assert_eq!(
            rec.store().get_run(&id).unwrap().session_id.as_deref(),
            Some("S1")
        );
        let run = rec.run_ended("TAB", Some(0)).unwrap();
        assert!(rec.active_run_for_tab("TAB").is_none());
        assert!(rec.run_ended("TAB", Some(0)).is_none());
        let run = rec.complete(run, None, None).unwrap();
        assert_eq!(run.turn_count, 1);
        let stored = rec.store().get_run(&id).unwrap();
        assert_eq!(stored.model.as_deref(), Some("m"));
        assert_eq!(stored.exit_status, Some(0));
        assert!(stored.ended_at.is_some());
        assert_eq!(stored.total_input_tokens, Some(10));
        assert_eq!(stored.cost_state, TelemetryMetricState::Missing);
        assert_eq!(rec.store().get_turns(&id).len(), 1);
    }

    #[test]
    fn fallbacks_pty_log_then_buffer() {
        let rec = recorder(None);
        let dir = std::env::temp_dir().join(format!("chau7-next-rec-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let log = dir.join("claude-pty.log");
        std::fs::write(&log, "\x1b[31mhello\x1b[0m  \n\n\n\n\n  world\n").unwrap();

        rec.run_started("T", "claude", "/p", None, None).unwrap();
        let run = rec.run_ended("T", None).unwrap();
        let run = rec
            .complete(run, Some("buffer".into()), Some(&log))
            .unwrap();
        assert_eq!(run.raw_transcript_ref.as_deref(), Some("pty_log"));
        let turns = rec.store().get_turns(&run.id);
        assert_eq!(turns[0].id, format!("{}-t0", run.id));
        assert_eq!(turns[0].content.as_deref(), Some("hello\n\n\nworld"));

        rec.run_started("T", "codex", "/p", None, None).unwrap();
        let run = rec.run_ended("T", None).unwrap();
        let run = rec
            .complete(
                run,
                Some("  screen text \n".into()),
                Some(&dir.join("none")),
            )
            .unwrap();
        assert_eq!(run.raw_transcript_ref.as_deref(), Some("terminal_buffer"));
        assert_eq!(
            rec.store().get_turns(&run.id)[0].content.as_deref(),
            Some("screen text")
        );

        rec.run_started("T", "codex", "/p", None, None).unwrap();
        let run = rec.run_ended("T", None).unwrap();
        let run = rec.complete(run, Some("   ".into()), None).unwrap();
        assert_eq!(run.turn_count, 0);
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn session_id_by_cwd_matches_related_folders_once() {
        let rec = recorder(None);
        let id = rec.run_started("T", "claude", "/a/b", None, None).unwrap();
        rec.update_session_id_by_cwd("codex", "/a/b", "X").unwrap();
        assert!(rec.active_run_for_tab("T").unwrap().session_id.is_none());
        rec.update_session_id_by_cwd("Claude", "/a/b/c", "S")
            .unwrap();
        assert_eq!(
            rec.active_run_for_tab("T").unwrap().session_id.as_deref(),
            Some("S")
        );
        rec.flush().unwrap();
        // Already has one: not replaced.
        rec.update_session_id_by_cwd("claude", "/a", "Z").unwrap();
        rec.flush().unwrap();
        assert_eq!(
            rec.store().get_run(&id).unwrap().session_id.as_deref(),
            Some("S")
        );
        assert!(folders_related("/a", "/a/b"));
        assert!(!folders_related("/a", "/ab"));
    }

    #[test]
    fn repair_sql_failure_is_counted_and_does_not_publish_a_false_rebuild() {
        // Fixed supplies a valid turn for the requested run. Keep an invalid
        // tool-call reference so the real SQL foreign-key failure reaches the
        // checked rewrite rather than being normalized by the fake provider.
        let bad_call = TelemetryToolCall::new(
            "missing-owned-parent",
            "missing-owned-turn",
            "owned-fake-tool",
        );
        let rec = recorder(Some(ExtractedRunContent {
            tool_calls: vec![bad_call],
            ..Default::default()
        }));
        let mut run = TelemetryRun::new("claude", "/owned");
        run.ended_at = Some(Utc::now());
        rec.store().insert_run(&run);
        let report = rec.rebuild_transcript_derived_runs(1);
        assert_eq!(report.inspected_runs, 1);
        assert_eq!(report.failed_runs, 1);
        assert_eq!(report.rebuilt_runs, 0);
        assert_eq!(report.invalidated_runs, 0);
        assert_eq!(rec.store().get_run(&run.id).unwrap().turn_count, 0);
        assert_eq!(rec.store().failure_count(), 1);
        rec.shutdown().unwrap().finish().unwrap();
    }
    #[test]
    fn tags_and_repair() {
        let rec = recorder(Some(ExtractedRunContent {
            total_input_tokens: Some(200_000_000),
            ..Default::default()
        }));
        let id = rec.run_started("T", "claude", "/p", None, None).unwrap();
        rec.tag_run(&id, &["control".into()]).unwrap();
        assert_eq!(rec.active_run_for_tab("T").unwrap().tags, vec!["control"]);
        let run = rec.run_ended("T", Some(1)).unwrap();
        rec.complete(run, None, None).unwrap();
        let stored = rec.store().get_run(&id).unwrap();
        assert_eq!(stored.token_usage_state, TelemetryMetricState::Invalid);
        assert_eq!(stored.tags, vec!["control"]);

        let report = rec.rebuild_transcript_derived_runs(500);
        assert_eq!(report.inspected_runs, 1);
        assert_eq!(report.invalidated_runs, 1);
        rec.flush().unwrap();
        assert_eq!(
            rec.store().get_run(&id).unwrap().error_message.as_deref(),
            Some("historical transcript repair invalidated implausible token metrics")
        );
    }
}
