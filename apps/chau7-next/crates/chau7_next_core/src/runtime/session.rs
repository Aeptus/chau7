//! Port of `Runtime/RuntimeSession.swift`: one agent session driven by the
//! runtime. It names a tab (it does not own it), runs the state machine,
//! counts the current turn's tools and tokens, and journals every event.
//!
//! Thread safe: the mutable state sits behind one lock and the journal has
//! its own, like the Swift class.

use std::collections::HashMap;
use std::sync::{Condvar, Mutex, MutexGuard};

use chrono::{DateTime, Utc};
use serde_json::{Map, Value, json};

use super::agent_backend::{AgentBackend, SessionConfig};
use super::delegated_task::TurnResult;
use super::event_journal::EventJournal;
use super::exit_classifier::{TurnExitReason, classify};
use super::runtime_event::RuntimeEventType;
use super::session_state::{RuntimeSessionStateMachine, State, Trigger};
use super::turn_stats::TurnStats;
use crate::telemetry::date_codec::format_iso8601_fractional;
use crate::telemetry::token_metrics::TokenUsage;

/// A pending tool permission request (`PendingApproval`).
#[derive(Debug, Clone, PartialEq)]
pub struct PendingApproval {
    pub id: String,
    pub session_id: String,
    pub tool: String,
    pub description: String,
    pub requested_at: DateTime<Utc>,
}

impl PendingApproval {
    /// `{id, tool, description}` as the MCP tools return it.
    pub fn json(&self) -> Value {
        json!({"id": self.id, "tool": self.tool, "description": self.description})
    }
}

/// What a finished turn reports (`TurnCompletionResult`).
#[derive(Debug, Clone, PartialEq)]
pub struct TurnCompletion {
    pub stats: TurnStats,
    pub exit_reason: TurnExitReason,
    pub duration_ms: Option<u64>,
    pub completed_turn_cost_usd: Option<f64>,
}
#[derive(Debug, Clone, PartialEq, serde::Serialize, serde::Deserialize)]
pub struct CompletedTurnSnapshot {
    pub turn_id: String,
    pub stats: TurnStats,
    pub exit_reason: TurnExitReason,
    pub duration_ms: u64,
    pub estimated_cost_usd: Option<f64>,
    pub usage_known: bool,
}

#[derive(Default)]
struct Inner {
    machine: RuntimeSessionStateMachine,
    current_turn_id: Option<String>,
    turn_count: u64,
    pending_approval: Option<PendingApproval>,
    current_stats: TurnStats,
    last_denied_approval: bool,
    was_interrupted: bool,
    last_exit_reason: Option<TurnExitReason>,
    last_turn_submitted_at: Option<DateTime<Utc>>,
    last_turn_completed_at: Option<DateTime<Utc>>,
    last_completed_turn_id: Option<String>,
    last_prompt: Option<String>,
    last_completed_turn_snapshot: Option<CompletedTurnSnapshot>,
    active_duration_ms: u64,
    estimated_cost_usd: Option<f64>,
    current_result_schema: Option<Value>,
    turn_results: HashMap<String, TurnResult>,
    cumulative_tokens: TokenUsage,
    cumulative_cache_creation: i64,
    cumulative_cache_read: i64,
    observed_turn_activity: bool,
    previous_terminal_status: Option<String>,
    current_usage_evidence: bool,
    usage_known_turns: u64,
    completed_turn_count: u64,
    native_session_id: Option<String>,
    pending_initial_prompt: Option<String>,
}

/// One runtime session.
pub struct RuntimeSession {
    /// `rs_` plus 8 lower-case hex characters.
    pub id: String,
    /// The tab hosting the session (its MCP `tab_id`).
    pub tab_id: String,
    pub backend: Box<dyn AgentBackend>,
    pub config: SessionConfig,
    pub created_at: DateTime<Utc>,
    pub auto_approve: bool,
    /// Adopted from an existing tab (passive; nothing was launched).
    pub adopted: bool,
    pub journal: EventJournal,
    inner: Mutex<Inner>,
    readiness_changed: Condvar,
}

/// `"rs_" + UUID().uuidString.prefix(8).lowercased()`.
pub fn new_session_id() -> String {
    let uuid = uuid::Uuid::new_v4().simple().to_string();
    format!("rs_{}", &uuid[..8])
}

fn data(pairs: &[(&str, String)]) -> HashMap<String, String> {
    pairs
        .iter()
        .map(|(k, v)| (k.to_string(), v.clone()))
        .collect()
}

impl RuntimeSession {
    /// A new session in `starting` with a 1,000 event journal.
    pub fn new(
        tab_id: impl Into<String>,
        backend: Box<dyn AgentBackend>,
        config: SessionConfig,
        auto_approve: bool,
        adopted: bool,
    ) -> Self {
        Self::with_journal_capacity(tab_id, backend, config, auto_approve, adopted, 1000)
    }

    pub fn with_journal_capacity(
        tab_id: impl Into<String>,
        backend: Box<dyn AgentBackend>,
        config: SessionConfig,
        auto_approve: bool,
        adopted: bool,
        capacity: usize,
    ) -> Self {
        Self {
            id: new_session_id(),
            tab_id: tab_id.into(),
            backend,
            config,
            created_at: Utc::now(),
            auto_approve,
            adopted,
            journal: EventJournal::new(capacity),
            inner: Mutex::new(Inner::default()),
            readiness_changed: Condvar::new(),
        }
    }

    fn lock(&self) -> MutexGuard<'_, Inner> {
        self.inner.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// Journal an event of this session.
    pub fn record(&self, turn_id: Option<&str>, event_type: &str, data: HashMap<String, String>) {
        self.journal.append(&self.id, turn_id, event_type, data);
    }

    pub fn state(&self) -> State {
        self.lock().machine.state()
    }

    pub fn is_terminal(&self) -> bool {
        self.lock().machine.is_terminal()
    }

    pub fn can_accept_turn(&self) -> bool {
        self.lock().machine.can_accept_turn()
    }

    pub fn current_turn_id(&self) -> Option<String> {
        self.lock().current_turn_id.clone()
    }

    pub fn turn_count(&self) -> u64 {
        self.lock().turn_count
    }

    pub fn pending_approval(&self) -> Option<PendingApproval> {
        self.lock().pending_approval.clone()
    }

    pub fn current_turn_stats(&self) -> TurnStats {
        self.lock().current_stats.clone()
    }

    pub fn last_exit_reason(&self) -> Option<TurnExitReason> {
        self.lock().last_exit_reason
    }

    pub fn last_turn_submitted_at(&self) -> Option<DateTime<Utc>> {
        self.lock().last_turn_submitted_at
    }

    pub fn observe_terminal_status(&self, status: &str) {
        let mut inner = self.lock();
        if inner.machine.state() == State::Busy
            && status == "running"
            && inner
                .previous_terminal_status
                .as_deref()
                .is_some_and(|previous| previous != "running")
        {
            inner.observed_turn_activity = true;
        }
        inner.previous_terminal_status = Some(status.to_string());
    }
    pub fn mark_turn_activity(&self) {
        self.lock().observed_turn_activity = true;
    }
    pub fn has_observed_turn_activity(&self) -> bool {
        self.lock().observed_turn_activity
    }
    pub fn pending_initial_prompt(&self) -> Option<String> {
        self.lock().pending_initial_prompt.clone()
    }
    pub fn queue_initial_prompt(&self, prompt: String) {
        self.lock().pending_initial_prompt = Some(prompt);
        self.readiness_changed.notify_all();
    }
    pub fn clear_pending_initial_prompt(&self) {
        self.lock().pending_initial_prompt = None;
        self.readiness_changed.notify_all();
    }
    /// Wait for real readiness or a terminal state. A manual turn cancels the queued prompt.
    pub fn wait_for_pending_initial_prompt(&self) -> Result<Option<String>, State> {
        self.wait_for_pending_initial_prompt_unless(|| false)
    }
    /// Check caller cancellation while waiting, without a fixed backend startup deadline.
    pub fn wait_for_pending_initial_prompt_unless(
        &self,
        cancelled: impl Fn() -> bool,
    ) -> Result<Option<String>, State> {
        let mut inner = self.lock();
        loop {
            if cancelled() {
                inner.pending_initial_prompt = None;
                return Ok(None);
            }
            if inner.pending_initial_prompt.is_none() {
                return Ok(None);
            }
            if inner.machine.is_terminal() {
                let state = inner.machine.state();
                inner.pending_initial_prompt = None;
                return Err(state);
            }
            if inner.machine.can_accept_turn() {
                return Ok(inner.pending_initial_prompt.clone());
            }
            inner = self
                .readiness_changed
                .wait_timeout(inner, std::time::Duration::from_millis(500))
                .unwrap_or_else(|e| e.into_inner())
                .0;
        }
    }

    pub fn native_session_id(&self) -> Option<String> {
        self.lock().native_session_id.clone()
    }
    pub fn bind_native_session_id(&self, native: &str) {
        self.lock().native_session_id = Some(native.into());
    }

    pub fn completed_turn_count(&self) -> u64 {
        self.lock().completed_turn_count
    }
    pub fn has_token_usage_evidence(&self) -> bool {
        self.lock().usage_known_turns > 0
    }
    pub fn token_usage_state(&self) -> crate::telemetry::token_metrics::TelemetryMetricState {
        let inner = self.lock();
        if inner.usage_known_turns == 0 {
            crate::telemetry::token_metrics::TelemetryMetricState::Missing
        } else if inner.usage_known_turns == inner.completed_turn_count {
            crate::telemetry::token_metrics::TelemetryMetricState::Complete
        } else {
            crate::telemetry::token_metrics::TelemetryMetricState::Estimated
        }
    }
    pub fn cumulative_token_usage(&self) -> TokenUsage {
        self.lock().cumulative_tokens
    }
    pub fn cumulative_cache_creation_tokens(&self) -> i64 {
        self.lock().cumulative_cache_creation
    }
    pub fn cumulative_cache_read_tokens(&self) -> i64 {
        self.lock().cumulative_cache_read
    }
    pub fn last_completed_turn_snapshot(&self) -> Option<CompletedTurnSnapshot> {
        self.lock().last_completed_turn_snapshot.clone()
    }
    pub fn active_duration_ms(&self) -> u64 {
        self.lock().active_duration_ms
    }
    pub fn estimated_cost_usd(&self) -> Option<f64> {
        self.lock().estimated_cost_usd
    }
    pub fn current_turn_usage_known(&self) -> bool {
        self.lock().current_usage_evidence
    }
    pub fn average_visible_tokens_per_completed_turn(&self) -> Option<f64> {
        let inner = self.lock();
        (inner.usage_known_turns > 0 && inner.completed_turn_count > 0).then(|| {
            inner.cumulative_tokens.total_visible_tokens() as f64
                / inner.completed_turn_count as f64
        })
    }
    pub fn current_turn_cost_usd(&self) -> Option<f64> {
        let inner = self.lock();
        if !inner.current_usage_evidence {
            return None;
        }
        crate::telemetry::pricing::pricing(self.config.model.as_deref(), Some(self.backend.name()))
            .map(|p| p.estimate(&inner.current_stats.token_usage()))
    }
    pub fn last_prompt(&self) -> Option<String> {
        self.lock().last_prompt.clone()
    }
    pub fn last_completed_turn_id(&self) -> Option<String> {
        self.lock().last_completed_turn_id.clone()
    }
    pub fn last_turn_completed_at(&self) -> Option<DateTime<Utc>> {
        self.lock().last_turn_completed_at
    }
    pub fn latest_turn_result(&self) -> Option<TurnResult> {
        self.turn_result(None)
    }
    pub fn turn_result(&self, turn: Option<&str>) -> Option<TurnResult> {
        let inner = self.lock();
        let id = turn.or(inner.last_completed_turn_id.as_deref())?;
        inner.turn_results.get(id).cloned()
    }
    pub fn policy_error_for_next_turn(&self) -> Option<String> {
        self.config.policy.validate_start(
            self.turn_count().saturating_add(1),
            (Utc::now() - self.created_at).num_milliseconds(),
            self.config.delegation_depth,
        )
    }
    pub fn record_policy_block(&self, tool: &str, reason: &str) {
        self.record(
            self.current_turn_id().as_deref(),
            "policy_blocked",
            data(&[("tool", tool.into()), ("reason", reason.into())]),
        );
    }

    /// Apply a trigger; journals `state_changed` when accepted.
    pub fn transition(&self, trigger: Trigger) -> bool {
        let (previous, accepted, next, turn) = {
            let mut inner = self.lock();
            let previous = inner.machine.state();
            let accepted = inner.machine.handle(&trigger);
            (
                previous,
                accepted,
                inner.machine.state(),
                inner.current_turn_id.clone(),
            )
        };
        if accepted {
            self.readiness_changed.notify_all();
            self.record(
                turn.as_deref(),
                RuntimeEventType::STATE_CHANGED.raw_value(),
                data(&[
                    ("from", previous.raw_value().to_string()),
                    ("to", next.raw_value().to_string()),
                ]),
            );
        } else {
            log::debug!(
                "RuntimeSession {}: transition {trigger:?} rejected in state {}",
                self.id,
                previous.raw_value()
            );
        }
        accepted
    }

    /// Start a turn (`t_<n>`), only from `ready`; moves to `busy`.
    pub fn start_turn(&self, prompt: &str) -> Option<String> {
        self.start_turn_with_schema(prompt, None)
    }

    pub fn start_turn_with_schema(&self, prompt: &str, schema: Option<Value>) -> Option<String> {
        if let Some(reason) = self.policy_error_for_next_turn() {
            self.record_policy_block("turn_submission", &reason);
            return None;
        }
        let (turn_id, next) = {
            let mut inner = self.lock();
            if !inner.machine.can_accept_turn() {
                log::debug!(
                    "RuntimeSession {}: startTurn rejected, state={}",
                    self.id,
                    inner.machine.state().raw_value()
                );
                return None;
            }
            if !inner.machine.handle(&Trigger::TurnSubmitted) {
                log::error!("RuntimeSession {}: turnSubmitted rejected", self.id);
                return None;
            }
            inner.pending_initial_prompt = None;
            inner.turn_count += 1;
            let turn_id = format!("t_{}", inner.turn_count);
            inner.current_turn_id = Some(turn_id.clone());
            inner.last_turn_submitted_at = Some(Utc::now());
            inner.last_prompt = Some(prompt.to_string());
            inner.current_result_schema = schema.or_else(|| self.config.result_schema.clone());
            inner.observed_turn_activity = false;
            inner.current_usage_evidence = false;
            inner.current_stats = TurnStats::new();
            inner.last_denied_approval = false;
            inner.was_interrupted = false;
            (turn_id, inner.machine.state())
        };
        self.readiness_changed.notify_all();
        self.record(
            Some(&turn_id),
            RuntimeEventType::STATE_CHANGED.raw_value(),
            data(&[
                ("from", State::Ready.raw_value().to_string()),
                ("to", next.raw_value().to_string()),
            ]),
        );
        self.record(
            Some(&turn_id),
            RuntimeEventType::TURN_STARTED.raw_value(),
            data(&[("prompt_length", prompt.chars().count().to_string())]),
        );
        Some(turn_id)
    }

    /// Close the current turn: journals `turn_completed` with the stats and
    /// the exit reason, then moves back to `ready`.
    pub fn complete_turn(
        &self,
        summary: Option<&str>,
        terminal_output: Option<&str>,
    ) -> TurnCompletion {
        let (turn, stats, denied, interrupted, state, started_at, usage_known, result_schema) = {
            let mut inner = self.lock();
            (
                inner.current_turn_id.take(),
                inner.current_stats.clone(),
                inner.last_denied_approval,
                inner.was_interrupted,
                inner.machine.state(),
                inner.last_turn_submitted_at,
                inner.current_usage_evidence,
                inner.current_result_schema.take(),
            )
        };
        if turn.is_none() {
            return TurnCompletion {
                stats,
                exit_reason: classify(state, denied, terminal_output, interrupted),
                duration_ms: None,
                completed_turn_cost_usd: None,
            };
        }
        let completed_at = Utc::now();
        let duration_ms = started_at
            .map(|start| (completed_at - start).num_milliseconds().max(0) as u64)
            .unwrap_or(0);
        let turn_cost = usage_known
            .then(|| {
                crate::telemetry::pricing::pricing(
                    self.config.model.as_deref(),
                    Some(self.backend.name()),
                )
                .map(|p| p.estimate(&stats.token_usage()))
            })
            .flatten();
        let structured = turn.as_deref().and_then(|turn| {
            super::structured_result::capture(
                &self.id,
                turn,
                summary,
                terminal_output,
                result_schema.as_ref(),
            )
        });
        let exit_reason = classify(state, denied, terminal_output, interrupted);
        let mut payload: HashMap<String, String> = stats.summary().into_iter().collect();
        payload.insert("exit_reason".into(), exit_reason.raw_value().into());
        payload.insert("turn_duration_ms".into(), duration_ms.to_string());
        if let Some(cost) = turn_cost {
            payload.insert("estimated_cost_usd".into(), cost.to_string());
        }
        if let Some(summary) = summary {
            payload.insert("summary".into(), summary.into());
        }
        self.record(
            turn.as_deref(),
            RuntimeEventType::TURN_COMPLETED.raw_value(),
            payload,
        );
        {
            let mut inner = self.lock();
            // Complete counters and state atomically: a concurrent new turn cannot be cleared.
            inner.last_exit_reason = Some(exit_reason);
            if let Some(turn) = turn.as_ref() {
                inner.completed_turn_count += 1;
                if inner.current_usage_evidence {
                    inner.usage_known_turns += 1;
                }
                inner.cumulative_tokens.add(&stats.token_usage());
                inner.cumulative_cache_creation += stats.cache_creation_tokens();
                inner.cumulative_cache_read += stats.cache_read_tokens();
                inner.last_completed_turn_id = Some(turn.clone());
                inner.last_turn_completed_at = Some(completed_at);
                inner.active_duration_ms = inner.active_duration_ms.saturating_add(duration_ms);
                if let Some(cost) = turn_cost {
                    inner.estimated_cost_usd = Some(inner.estimated_cost_usd.unwrap_or(0.0) + cost);
                }
                inner.last_completed_turn_snapshot = Some(CompletedTurnSnapshot {
                    turn_id: turn.clone(),
                    stats: stats.clone(),
                    exit_reason,
                    duration_ms,
                    estimated_cost_usd: turn_cost,
                    usage_known,
                });
                if let Some(result) = structured.as_ref() {
                    inner.turn_results.insert(turn.clone(), result.clone());
                }
            }
            let from = inner.machine.state();
            if inner.machine.handle(&Trigger::TurnCompleted) {
                self.record(
                    turn.as_deref(),
                    RuntimeEventType::STATE_CHANGED.raw_value(),
                    data(&[
                        ("from", from.raw_value().into()),
                        ("to", inner.machine.state().raw_value().into()),
                    ]),
                );
            }
        }
        self.readiness_changed.notify_all();
        if let Some(result) = structured {
            self.record(
                Some(&result.turn_id),
                "turn_result_captured",
                data(&[
                    (
                        "status",
                        serde_json::to_value(&result.status)
                            .unwrap()
                            .as_str()
                            .unwrap()
                            .to_string(),
                    ),
                    ("source", result.source.clone()),
                ]),
            );
        }
        TurnCompletion {
            stats,
            exit_reason,
            duration_ms: Some(duration_ms),
            completed_turn_cost_usd: turn_cost,
        }
    }

    /// Mark the current turn failed (`turn_failed`) and go back to `ready`.
    pub fn fail_turn(&self, reason: &str) {
        let turn = self.lock().current_turn_id.take();
        self.record(
            turn.as_deref(),
            RuntimeEventType::TURN_FAILED.raw_value(),
            data(&[("reason", reason.to_string())]),
        );
        if !self.transition(Trigger::TurnCompleted) {
            log::warn!(
                "RuntimeSession {}: failTurn transition rejected, state={}",
                self.id,
                self.state().raw_value()
            );
        }
    }

    pub fn record_tool_use(&self, name: &str, file: Option<&str>) {
        self.lock().current_stats.record_tool_use(name, file);
    }

    pub fn add_tokens(&self, input: i64, output: i64, cache_creation: i64, cache_read: i64) {
        self.add_tokens_with_reasoning(input, output, cache_creation, cache_read, 0);
    }
    pub fn add_tokens_with_reasoning(
        &self,
        input: i64,
        output: i64,
        creation: i64,
        read: i64,
        reasoning: i64,
    ) {
        let mut inner = self.lock();
        if inner.current_turn_id.is_none() {
            return;
        }
        inner.current_usage_evidence = true;
        inner
            .current_stats
            .add_tokens_with_reasoning(input, output, creation, read, reasoning);
    }
    pub fn add_token_usage(&self, usage: TokenUsage) {
        self.add_tokens_with_reasoning(
            usage.input_tokens,
            usage.output_tokens,
            usage.cache_creation_input_tokens,
            usage.cache_read_input_tokens + usage.uncategorized_cache(),
            usage.reasoning_output_tokens,
        );
    }

    pub fn mark_interrupted(&self) {
        self.lock().was_interrupted = true;
    }

    /// A permission request: `awaitingApproval` plus `approval_needed`.
    /// `None` (and no pending approval) when the state machine refuses.
    pub fn request_approval(&self, tool: &str, description: &str) -> Option<PendingApproval> {
        let approval = PendingApproval {
            id: uuid::Uuid::new_v4().hyphenated().to_string().to_uppercase(),
            session_id: self.id.clone(),
            tool: tool.to_string(),
            description: description.to_string(),
            requested_at: Utc::now(),
        };
        let turn = {
            let mut inner = self.lock();
            inner.pending_approval = Some(approval.clone());
            inner.current_turn_id.clone()
        };
        if !self.transition(Trigger::ApprovalNeeded) {
            log::warn!(
                "RuntimeSession {}: approvalNeeded rejected, clearing orphaned approval",
                self.id
            );
            self.lock().pending_approval = None;
            return None;
        }
        self.record(
            turn.as_deref(),
            RuntimeEventType::APPROVAL_NEEDED.raw_value(),
            data(&[
                ("approval_id", approval.id.clone()),
                ("tool", tool.to_string()),
                ("description", description.to_string()),
            ]),
        );
        Some(approval)
    }

    /// An authoritative backend resolution carries no approve/deny verdict.
    pub fn reconcile_approval_resolution(&self, source: &str) -> bool {
        let (turn, approval) = {
            let mut inner = self.lock();
            (inner.current_turn_id.clone(), inner.pending_approval.take())
        };
        let Some(approval) = approval else {
            return false;
        };
        self.transition(Trigger::ApprovalResolved);
        self.record(
            turn.as_deref(),
            RuntimeEventType::APPROVAL_RESOLVED.raw_value(),
            data(&[("approval_id", approval.id), ("source", source.into())]),
        );
        true
    }

    /// Resolve the pending approval with this id: back to `busy`, journals
    /// `approval_resolved`. `false` when no such approval is pending.
    pub fn resolve_approval(&self, approval_id: &str, approved: bool, resolved_by: &str) -> bool {
        let turn = {
            let mut inner = self.lock();
            if inner.pending_approval.as_ref().map(|a| a.id.as_str()) != Some(approval_id) {
                log::warn!(
                    "RuntimeSession {}: resolveApproval mismatch, expected={} got={approval_id}",
                    self.id,
                    inner
                        .pending_approval
                        .as_ref()
                        .map(|a| a.id.as_str())
                        .unwrap_or("none")
                );
                return false;
            }
            inner.pending_approval = None;
            if !approved {
                inner.last_denied_approval = true;
            }
            inner.current_turn_id.clone()
        };
        self.transition(Trigger::ApprovalResolved);
        self.record(
            turn.as_deref(),
            RuntimeEventType::APPROVAL_RESOLVED.raw_value(),
            data(&[
                ("approval_id", approval_id.to_string()),
                ("approved", if approved { "true" } else { "false" }.into()),
                ("resolved_by", resolved_by.to_string()),
            ]),
        );
        true
    }

    /// The summary `runtime_session_create`, `_list` and `_get` return.
    pub fn summary(&self) -> Value {
        let (state, turn, turns, approval) = {
            let inner = self.lock();
            (
                inner.machine.state(),
                inner.current_turn_id.clone(),
                inner.turn_count,
                inner.pending_approval.clone(),
            )
        };
        let mut out = Map::new();
        out.insert("session_id".into(), json!(self.id));
        out.insert("tab_id".into(), json!(self.tab_id));
        out.insert("backend".into(), json!(self.backend.name()));
        out.insert("state".into(), json!(state.raw_value()));
        out.insert("directory".into(), json!(self.config.directory));
        out.insert("turn_count".into(), json!(turns));
        out.insert("adopted".into(), json!(self.adopted));
        out.insert("auto_approve".into(), json!(self.auto_approve));
        out.insert(
            "created_at".into(),
            json!(format_iso8601_fractional(&self.created_at)),
        );
        out.insert("cursor".into(), json!(self.journal.latest_cursor()));
        if let Some(native) = self.native_session_id() {
            out.insert("provider_session_id".into(), json!(native));
        }
        out.insert(
            "initial_prompt_pending".into(),
            json!(self.pending_initial_prompt().is_some()),
        );
        out.insert("token_usage".into(), json!(self.cumulative_token_usage()));
        out.insert(
            "active_duration_ms".into(),
            json!(self.active_duration_ms()),
        );
        out.insert(
            "average_visible_tokens_per_completed_turn".into(),
            json!(self.average_visible_tokens_per_completed_turn()),
        );
        if let Some(cost) = self.estimated_cost_usd() {
            out.insert("estimated_cost_usd".into(), json!(cost));
        }
        if let Some(snapshot) = self.last_completed_turn_snapshot() {
            out.insert("last_completed_turn_snapshot".into(), json!(snapshot));
        }
        out.insert("token_usage_state".into(), json!(self.token_usage_state()));
        out.insert(
            "completed_turn_count".into(),
            json!(self.completed_turn_count()),
        );
        out.insert(
            "delegation_depth".into(),
            json!(self.config.delegation_depth),
        );
        out.insert("policy".into(), self.config.policy.summary());
        for (key, value) in [
            ("purpose", &self.config.purpose),
            ("parent_session_id", &self.config.parent_session_id),
            ("parent_run_id", &self.config.parent_run_id),
        ] {
            if let Some(value) = value {
                out.insert(key.into(), json!(value));
            }
        }
        if !self.config.task_metadata.is_empty() {
            out.insert("task_metadata".into(), json!(self.config.task_metadata));
        }
        if let Some(schema) = &self.config.result_schema {
            out.insert("result_schema".into(), schema.clone());
        }
        if let Some(result) = self.latest_turn_result() {
            out.insert("latest_turn_result".into(), json!(result));
        }
        if let Some(turn) = self.last_completed_turn_id() {
            out.insert("last_completed_turn_id".into(), json!(turn));
        }
        if let Some(time) = self.last_turn_completed_at() {
            out.insert(
                "last_turn_completed_at".into(),
                json!(format_iso8601_fractional(&time)),
            );
        }
        if let Some(turn) = turn {
            out.insert("current_turn_id".into(), json!(turn));
        }
        if let Some(approval) = approval {
            out.insert("pending_approval".into(), approval.json());
        }
        Value::Object(out)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::runtime::backends::{ClaudeCodeBackend, GenericShellBackend};

    fn session() -> RuntimeSession {
        RuntimeSession::new(
            "TAB",
            Box::new(ClaudeCodeBackend),
            SessionConfig::new("/w", "claude"),
            false,
            false,
        )
    }

    fn types(s: &RuntimeSession) -> Vec<String> {
        s.journal
            .events(0, 1000)
            .events
            .into_iter()
            .map(|e| e.event_type)
            .collect()
    }

    #[test]
    fn disconnected_initial_prompt_is_cleared_before_readiness() {
        let s = session();
        s.queue_initial_prompt("do not send".into());
        assert_eq!(s.wait_for_pending_initial_prompt_unless(|| true), Ok(None));
        assert!(s.pending_initial_prompt().is_none());
        s.transition(Trigger::BackendReady);
        s.queue_initial_prompt("still do not send".into());
        assert_eq!(s.wait_for_pending_initial_prompt_unless(|| true), Ok(None));
        assert!(s.pending_initial_prompt().is_none());
    }

    #[test]
    fn completed_snapshot_retains_observed_metrics_and_survives_next_turn() {
        let mut config = SessionConfig::new("/w", "claude");
        config.model = Some("gpt-5.4".into());
        let s = RuntimeSession::new("tab", Box::new(ClaudeCodeBackend), config, false, false);
        s.transition(Trigger::BackendReady);
        s.start_turn("first");
        s.lock().last_turn_submitted_at = Some(Utc::now() - chrono::Duration::seconds(1));
        s.add_tokens_with_reasoning(10, 5, 2, 3, 4);
        let result = s.complete_turn(None, None);
        let snapshot = s.last_completed_turn_snapshot().unwrap();
        assert_eq!(snapshot.stats.reasoning_output_tokens(), 4);
        assert_eq!(snapshot.stats.total_billable_tokens(), 24);
        assert!(snapshot.duration_ms >= 1000);
        assert_eq!(s.active_duration_ms(), snapshot.duration_ms);
        assert!(result.completed_turn_cost_usd.unwrap() > 0.0);
        assert_eq!(result.duration_ms, Some(snapshot.duration_ms));
        assert_eq!(s.average_visible_tokens_per_completed_turn(), Some(15.0));
        assert_eq!(s.cumulative_token_usage().cache_creation_input_tokens, 2);
        assert_eq!(s.cumulative_token_usage().cache_read_input_tokens, 3);
        let cost = s.estimated_cost_usd();
        s.complete_turn(None, None);
        assert_eq!(s.completed_turn_count(), 1);
        assert_eq!(s.estimated_cost_usd(), cost);
        s.start_turn("second");
        assert!(!s.current_turn_usage_known());
        assert_eq!(s.last_completed_turn_snapshot(), Some(snapshot));
        assert!(s.current_turn_cost_usd().is_none());
        assert_eq!(s.summary()["active_duration_ms"], s.active_duration_ms());
    }
    #[test]
    fn known_model_without_observed_usage_keeps_cost_absent() {
        let mut config = SessionConfig::new("/w", "claude");
        config.model = Some("gpt-5.4".into());
        let s = RuntimeSession::new("tab", Box::new(ClaudeCodeBackend), config, false, false);
        s.transition(Trigger::BackendReady);
        s.start_turn("first");
        s.complete_turn(None, None);
        assert!(!s.last_completed_turn_snapshot().unwrap().usage_known);
        assert!(s.estimated_cost_usd().is_none());
        assert!(s.average_visible_tokens_per_completed_turn().is_none());
        assert!(s.summary().get("estimated_cost_usd").is_none());
        s.add_tokens(100, 50, 0, 0);
        assert!(
            !s.current_turn_usage_known(),
            "late unbound usage must not be assigned to a completed turn"
        );
    }
    #[test]
    fn pending_initial_prompt_wakes_on_real_readiness_or_cancellation() {
        use std::sync::{Arc, mpsc};
        let session = Arc::new(RuntimeSession::new(
            "tab",
            Box::new(crate::runtime::backends::GenericShellBackend),
            SessionConfig::new("/c", "shell"),
            false,
            false,
        ));
        session.queue_initial_prompt("queued".into());
        let (tx, rx) = mpsc::channel();
        let worker = session.clone();
        let thread =
            std::thread::spawn(move || tx.send(worker.wait_for_pending_initial_prompt()).unwrap());
        assert!(
            rx.recv_timeout(std::time::Duration::from_millis(10))
                .is_err()
        );
        session.transition(Trigger::BackendReady);
        assert_eq!(
            rx.recv_timeout(std::time::Duration::from_secs(1)).unwrap(),
            Ok(Some("queued".into()))
        );
        thread.join().unwrap();
        session.start_turn("manual");
        assert!(session.pending_initial_prompt().is_none());
        session.queue_initial_prompt("cancel".into());
        session.clear_pending_initial_prompt();
        assert_eq!(session.wait_for_pending_initial_prompt(), Ok(None));
        session.queue_initial_prompt("stop".into());
        session.transition(Trigger::TabClosed);
        assert_eq!(
            session.wait_for_pending_initial_prompt(),
            Err(State::Stopped)
        );
        assert!(session.pending_initial_prompt().is_none());
    }

    #[test]
    fn no_observed_usage_is_missing_and_existing_running_cli_is_not_new_turn_activity() {
        let s = session();
        s.transition(Trigger::BackendReady);
        s.observe_terminal_status("running");
        s.start_turn("task");
        s.observe_terminal_status("running");
        assert!(!s.has_observed_turn_activity());
        s.observe_terminal_status("waitingForInput");
        s.observe_terminal_status("running");
        assert!(s.has_observed_turn_activity());
        s.complete_turn(None, None);
        assert!(!s.has_token_usage_evidence());
        assert_eq!(
            s.token_usage_state(),
            crate::telemetry::token_metrics::TelemetryMetricState::Missing
        );
        assert_eq!(s.completed_turn_count(), 1);
    }
    #[test]
    fn cumulative_tokens_and_structured_results_survive_next_turn() {
        let s = session();
        s.transition(Trigger::BackendReady);
        assert_eq!(
            s.start_turn_with_schema("task", Some(json!({"type":"object","required":["ok"]})))
                .as_deref(),
            Some("t_1")
        );
        s.add_tokens(10, 5, 2, 3);
        s.complete_turn(Some("{\"ok\":true}"), None);
        assert_eq!(s.cumulative_token_usage().total_visible_tokens(), 15);
        assert_eq!(
            s.token_usage_state(),
            crate::telemetry::token_metrics::TelemetryMetricState::Complete
        );
        assert_eq!(s.latest_turn_result().unwrap().turn_id, "t_1");
        s.complete_turn(Some("duplicate"), None);
        assert_eq!(s.cumulative_token_usage().total_visible_tokens(), 15);
        s.start_turn("next");
        assert_eq!(s.cumulative_token_usage().total_visible_tokens(), 15);
        assert_eq!(
            s.turn_result(Some("t_1")).unwrap().value.unwrap()["ok"],
            true
        );
    }

    #[test]
    fn ids_look_like_swift() {
        let id = new_session_id();
        assert_eq!(id.len(), 11);
        assert!(id.starts_with("rs_"));
        assert!(
            id[3..]
                .chars()
                .all(|c| c.is_ascii_hexdigit() && !c.is_uppercase())
        );
    }

    #[test]
    fn turns_only_start_when_ready() {
        let s = session();
        assert_eq!(s.start_turn("hi"), None);
        assert!(s.transition(Trigger::BackendReady));
        assert_eq!(s.start_turn("hi").as_deref(), Some("t_1"));
        assert_eq!(s.state(), State::Busy);
        assert_eq!(s.start_turn("again"), None);
        let done = s.complete_turn(Some("done"), Some("all good"));
        assert_eq!(done.exit_reason, TurnExitReason::Success);
        assert_eq!(s.state(), State::Ready);
        assert_eq!(s.current_turn_id(), None);
        assert_eq!(s.start_turn("next").as_deref(), Some("t_2"));
        assert_eq!(s.turn_count(), 2);
        assert_eq!(
            types(&s),
            [
                "state_changed",
                "state_changed",
                "turn_started",
                "turn_completed",
                "state_changed",
                "state_changed",
                "turn_started"
            ]
        );
        let events = s.journal.events(0, 100).events;
        assert_eq!(events[2].data["prompt_length"], "2");
        assert_eq!(events[3].data["summary"], "done");
        assert_eq!(events[3].data["exit_reason"], "success");
        assert_eq!(events[3].turn_id.as_deref(), Some("t_1"));
    }

    #[test]
    fn approvals_round_trip_and_deny_classifies_the_turn() {
        let s = session();
        s.transition(Trigger::BackendReady);
        // Not busy: refused, nothing pending.
        assert!(s.request_approval("Bash", "rm").is_none());
        assert!(s.pending_approval().is_none());
        s.start_turn("go");
        s.record_tool_use("Edit", Some("/a.rs"));
        s.add_tokens(10, 20, 1, 2);
        let approval = s.request_approval("Bash", "rm -rf build").unwrap();
        assert_eq!(s.state(), State::AwaitingApproval);
        assert!(!s.resolve_approval("other", true, "x"));
        assert!(s.resolve_approval(&approval.id, false, "orchestrator"));
        assert_eq!(s.state(), State::Busy);
        let done = s.complete_turn(None, None);
        assert_eq!(done.exit_reason, TurnExitReason::ApprovalDenied);
        assert_eq!(done.stats.total_tokens(), 30);
        let last = s.journal.events(0, 100).events;
        let completed = last
            .iter()
            .find(|e| e.event_type == "turn_completed")
            .unwrap();
        assert_eq!(completed.data["tool_count"], "1");
        assert_eq!(completed.data["files_touched"], "1");
        let resolved = last
            .iter()
            .find(|e| e.event_type == "approval_resolved")
            .unwrap();
        assert_eq!(resolved.data["approved"], "false");
        assert_eq!(resolved.data["resolved_by"], "orchestrator");
        assert_eq!(s.last_exit_reason(), Some(TurnExitReason::ApprovalDenied));
    }

    #[test]
    fn summary_has_the_mcp_keys() {
        let s = RuntimeSession::new(
            "TAB-1",
            Box::new(GenericShellBackend),
            SessionConfig::new("/tmp", "shell"),
            true,
            true,
        );
        s.transition(Trigger::BackendReady);
        s.start_turn("x");
        let v = s.summary();
        assert_eq!(v["tab_id"], "TAB-1");
        assert_eq!(v["backend"], "shell");
        assert_eq!(v["state"], "busy");
        assert_eq!(v["turn_count"], 1);
        assert_eq!(v["adopted"], true);
        assert_eq!(v["auto_approve"], true);
        assert_eq!(v["current_turn_id"], "t_1");
        assert_eq!(v["cursor"], 3);
        assert!(v.get("pending_approval").is_none());
        assert!(v["created_at"].as_str().unwrap().ends_with('Z'));
    }

    #[test]
    fn fail_turn_goes_back_to_ready() {
        let s = session();
        s.transition(Trigger::BackendReady);
        s.start_turn("x");
        s.fail_turn("boom");
        assert_eq!(s.state(), State::Ready);
        assert!(types(&s).contains(&"turn_failed".to_string()));
    }
}
