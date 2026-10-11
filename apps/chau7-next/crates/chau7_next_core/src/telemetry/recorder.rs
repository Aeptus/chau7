//! Ports of `Telemetry/TelemetryRecorder.swift` and
//! `TelemetryRepairService.swift`: one run per AI CLI session in a tab,
//! started when the CLI is detected and finished when it exits, with the
//! transcript read from the CLI's own files (or the terminal as a fallback).
//!
//! The recorder is shared between threads: the app starts and ends runs on
//! the main thread and does the slow part ([`TelemetryRecorder::complete`],
//! reading transcripts) on a background thread.

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

pub struct TelemetryRecorder {
    store: Arc<TelemetryStore>,
    providers: Vec<Box<dyn RunContentProvider>>,
    active: Mutex<Active>,
}

impl TelemetryRecorder {
    pub fn new(store: Arc<TelemetryStore>, providers: Vec<Box<dyn RunContentProvider>>) -> Self {
        Self {
            store,
            providers,
            active: Mutex::new(Active::default()),
        }
    }

    pub fn store(&self) -> &Arc<TelemetryStore> {
        &self.store
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, Active> {
        self.active.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// TEL-001: an AI CLI started in a tab. Returns the run id.
    pub fn run_started(
        &self,
        tab_id: &str,
        provider: &str,
        cwd: &str,
        repo_path: Option<&str>,
        session_id: Option<&str>,
    ) -> String {
        let mut run = TelemetryRun::new(provider, cwd);
        run.session_id = session_id.filter(|s| !s.is_empty()).map(str::to_string);
        run.tab_id = Some(tab_id.to_string());
        run.repo_path = repo_path.map(str::to_string);
        let id = run.id.clone();
        {
            let mut active = self.lock();
            if let Some(previous) = active.by_tab.insert(tab_id.to_string(), id.clone()) {
                active.runs.remove(&previous);
            }
            active.runs.insert(id.clone(), run.clone());
        }
        self.store.insert_run(&run);
        log::info!("TelemetryRecorder: run started {id} provider={provider} cwd={cwd}");
        id
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

    /// TEL-002, second half: content from the provider's transcript, else
    /// the PTY log tail, else the terminal text (TEL-006), then one atomic
    /// write. Slow (reads files): call it off the main thread.
    pub fn complete(
        &self,
        mut run: TelemetryRun,
        terminal_buffer: Option<String>,
        pty_log_path: Option<&Path>,
    ) -> TelemetryRun {
        let mut turns: Vec<TelemetryTurn> = Vec::new();
        let mut tool_calls: Vec<TelemetryToolCall> = Vec::new();
        if let Some(provider) = self.providers.iter().find(|p| p.can_handle(&run.provider)) {
            match provider.extract_content(
                &run.id,
                run.session_id.as_deref(),
                &run.cwd,
                run.started_at,
            ) {
                Some(content) => {
                    let (content, warning) = metrics_sanitizer::sanitize(&content, &run.provider);
                    if let Some(warning) = warning {
                        log::warn!("TelemetryRecorder: {warning} run={}", run.id);
                    }
                    run.model = content.model.clone().or(run.model);
                    run.total_input_tokens = content.total_input_tokens;
                    run.total_cached_input_tokens = content.total_cached_input_tokens;
                    run.total_output_tokens = content.total_output_tokens;
                    run.total_reasoning_output_tokens = content.total_reasoning_output_tokens;
                    run.cost_usd = content.cost_usd;
                    run.token_usage_source = content.token_usage_source;
                    run.token_usage_state = content.token_usage_state;
                    run.cost_source = content.cost_source;
                    run.cost_state = content.cost_state;
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

        self.store.finalize_run(&run, &turns, &tool_calls);
        log::info!(
            "TelemetryRecorder: run ended {} exit={} duration={}ms turns={}",
            run.id,
            run.exit_status.unwrap_or(-1),
            run.duration_ms.unwrap_or(0),
            run.turn_count
        );
        run
    }

    /// TEL-003: the session id of a tab's running run became known.
    pub fn update_session_id(&self, tab_id: &str, session_id: &str) {
        let run_id = {
            let mut active = self.lock();
            let Some(id) = active.by_tab.get(tab_id).cloned() else {
                return;
            };
            if let Some(run) = active.runs.get_mut(&id) {
                if run.session_id.as_deref() == Some(session_id) {
                    return;
                }
                run.session_id = Some(session_id.to_string());
            }
            id
        };
        self.store.update_run_session_id(&run_id, session_id);
    }

    /// TEL-003: a session id from a monitor that does not know the tab
    /// (Claude hooks, Codex history), matched by provider and folder (same
    /// folder, parent or child). Only runs without a session id are taken.
    pub fn update_session_id_by_cwd(&self, provider: &str, cwd: &str, session_id: &str) {
        let provider = provider.to_lowercase();
        let run_id = {
            let mut active = self.lock();
            let found = active.runs.values_mut().find(|run| {
                run.provider.to_lowercase().contains(&provider)
                    && run.session_id.as_deref().is_none_or(str::is_empty)
                    && folders_related(&run.cwd, cwd)
            });
            let Some(run) = found else { return };
            run.session_id = Some(session_id.to_string());
            run.id.clone()
        };
        self.store.update_run_session_id(&run_id, session_id);
        log::info!(
            "TelemetryRecorder: session ID updated via cwd match: {} -> run {}",
            session_id.chars().take(8).collect::<String>(),
            run_id.chars().take(8).collect::<String>()
        );
    }

    /// TEL-009.
    pub fn tag_run(&self, run_id: &str, tags: &[String]) {
        if let Some(run) = self.lock().runs.get_mut(run_id) {
            run.tags = tags.to_vec();
        }
        self.store.update_run_tags(run_id, tags);
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
                self.store.invalidate_run_metrics(
                    &run.id,
                    Some("historical transcript repair failed to extract content"),
                );
                report.invalidated_runs += 1;
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
            run.total_output_tokens = repaired.total_output_tokens;
            run.total_reasoning_output_tokens = repaired.total_reasoning_output_tokens;
            run.cost_usd = repaired.cost_usd;
            run.token_usage_source = repaired.token_usage_source;
            run.token_usage_state = repaired.token_usage_state;
            run.cost_source = repaired.cost_source;
            run.cost_state = repaired.cost_state;
            run.raw_transcript_ref = repaired.raw_transcript_ref.clone();
            run.turn_count = repaired.turns.len() as i64;
            let invalid = repaired.token_usage_state == TelemetryMetricState::Invalid;
            if invalid {
                run.error_message = Some(REPAIR_INVALID.into());
            } else if run.error_message.as_deref() == Some(REPAIR_INVALID) {
                run.error_message = None;
            }
            self.store
                .rewrite_completed_run(&run, &repaired.turns, &repaired.tool_calls);
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
}

/// Same folder, or one inside the other.
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
    fn run_lifecycle_with_provider_content() {
        let rec = recorder(Some(ExtractedRunContent {
            model: Some("m".into()),
            total_input_tokens: Some(10),
            ..Default::default()
        }));
        let id = rec.run_started("TAB", "claude", "/p", Some("/p"), None);
        assert_eq!(rec.active_run_for_tab("TAB").unwrap().id, id);
        assert_eq!(rec.all_active_runs().len(), 1);
        rec.update_session_id("TAB", "S1");
        assert_eq!(
            rec.store().get_run(&id).unwrap().session_id.as_deref(),
            Some("S1")
        );
        let run = rec.run_ended("TAB", Some(0)).unwrap();
        assert!(rec.active_run_for_tab("TAB").is_none());
        assert!(rec.run_ended("TAB", Some(0)).is_none());
        let run = rec.complete(run, None, None);
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

        rec.run_started("T", "claude", "/p", None, None);
        let run = rec.run_ended("T", None).unwrap();
        let run = rec.complete(run, Some("buffer".into()), Some(&log));
        assert_eq!(run.raw_transcript_ref.as_deref(), Some("pty_log"));
        let turns = rec.store().get_turns(&run.id);
        assert_eq!(turns[0].id, format!("{}-t0", run.id));
        assert_eq!(turns[0].content.as_deref(), Some("hello\n\n\nworld"));

        rec.run_started("T", "codex", "/p", None, None);
        let run = rec.run_ended("T", None).unwrap();
        let run = rec.complete(
            run,
            Some("  screen text \n".into()),
            Some(&dir.join("none")),
        );
        assert_eq!(run.raw_transcript_ref.as_deref(), Some("terminal_buffer"));
        assert_eq!(
            rec.store().get_turns(&run.id)[0].content.as_deref(),
            Some("screen text")
        );

        rec.run_started("T", "codex", "/p", None, None);
        let run = rec.run_ended("T", None).unwrap();
        let run = rec.complete(run, Some("   ".into()), None);
        assert_eq!(run.turn_count, 0);
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn session_id_by_cwd_matches_related_folders_once() {
        let rec = recorder(None);
        let id = rec.run_started("T", "claude", "/a/b", None, None);
        rec.update_session_id_by_cwd("codex", "/a/b", "X");
        assert!(rec.active_run_for_tab("T").unwrap().session_id.is_none());
        rec.update_session_id_by_cwd("Claude", "/a/b/c", "S");
        assert_eq!(
            rec.active_run_for_tab("T").unwrap().session_id.as_deref(),
            Some("S")
        );
        // Already has one: not replaced.
        rec.update_session_id_by_cwd("claude", "/a", "Z");
        assert_eq!(
            rec.store().get_run(&id).unwrap().session_id.as_deref(),
            Some("S")
        );
        assert!(folders_related("/a", "/a/b"));
        assert!(!folders_related("/a", "/ab"));
    }

    #[test]
    fn tags_and_repair() {
        let rec = recorder(Some(ExtractedRunContent {
            total_input_tokens: Some(200_000_000),
            ..Default::default()
        }));
        let id = rec.run_started("T", "claude", "/p", None, None);
        rec.tag_run(&id, &["control".into()]);
        assert_eq!(rec.active_run_for_tab("T").unwrap().tags, vec!["control"]);
        let run = rec.run_ended("T", Some(1)).unwrap();
        rec.complete(run, None, None);
        let stored = rec.store().get_run(&id).unwrap();
        assert_eq!(stored.token_usage_state, TelemetryMetricState::Invalid);
        assert_eq!(stored.tags, vec!["control"]);

        let report = rec.rebuild_transcript_derived_runs(500);
        assert_eq!(report.inspected_runs, 1);
        assert_eq!(report.invalidated_runs, 1);
        assert_eq!(
            rec.store().get_run(&id).unwrap().error_message.as_deref(),
            Some("historical transcript repair invalidated implausible token metrics")
        );
    }
}
