//! Port of `Runtime/RuntimeSession.swift`: one agent session driven by the
//! runtime. It names a tab (it does not own it), runs the state machine,
//! counts the current turn's tools and tokens, and journals every event.
//!
//! Thread safe: the mutable state sits behind one lock and the journal has
//! its own, like the Swift class.

use std::collections::HashMap;
use std::sync::{Mutex, MutexGuard};

use chrono::{DateTime, Utc};
use serde_json::{Map, Value, json};

use super::agent_backend::{AgentBackend, SessionConfig};
use super::event_journal::EventJournal;
use super::exit_classifier::{TurnExitReason, classify};
use super::runtime_event::RuntimeEventType;
use super::session_state::{RuntimeSessionStateMachine, State, Trigger};
use super::turn_stats::TurnStats;
use crate::telemetry::date_codec::format_iso8601_fractional;

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
            inner.turn_count += 1;
            let turn_id = format!("t_{}", inner.turn_count);
            inner.current_turn_id = Some(turn_id.clone());
            inner.last_turn_submitted_at = Some(Utc::now());
            inner.current_stats = TurnStats::new();
            inner.last_denied_approval = false;
            inner.was_interrupted = false;
            (turn_id, inner.machine.state())
        };
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
        let (turn, stats, denied, interrupted, state) = {
            let inner = self.lock();
            (
                inner.current_turn_id.clone(),
                inner.current_stats.clone(),
                inner.last_denied_approval,
                inner.was_interrupted,
                inner.machine.state(),
            )
        };
        let exit_reason = classify(state, denied, terminal_output, interrupted);
        let mut payload: HashMap<String, String> = stats.summary().into_iter().collect();
        payload.insert("exit_reason".into(), exit_reason.raw_value().into());
        if let Some(summary) = summary {
            payload.insert("summary".into(), summary.into());
        }
        self.record(
            turn.as_deref(),
            RuntimeEventType::TURN_COMPLETED.raw_value(),
            payload,
        );
        if !self.transition(Trigger::TurnCompleted) {
            log::warn!(
                "RuntimeSession {}: completeTurn transition rejected, state={}",
                self.id,
                self.state().raw_value()
            );
        }
        {
            let mut inner = self.lock();
            inner.current_turn_id = None;
            inner.last_exit_reason = Some(exit_reason);
        }
        TurnCompletion { stats, exit_reason }
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
        self.lock()
            .current_stats
            .add_tokens(input, output, cache_creation, cache_read);
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
