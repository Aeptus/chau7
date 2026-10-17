//! Port of `Notifications/NotificationHistory.swift`: the in-memory delivery
//! ledger (last 100 events) shown in Settings > Notifications > History and
//! the debug console. Each entry follows one event from ingestion to the
//! actions it ran, or the reason it was dropped.

use std::collections::{HashMap, VecDeque};

use chrono::{DateTime, Utc};
use serde::Serialize;
use uuid::Uuid;

use crate::ai::event::{AiEvent, AiEventSource};
use crate::monitoring::codex_feedback;

/// `NotificationHistory.DeliveryState`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum DeliveryState {
    Ingested,
    Coalesced,
    RetryScheduled,
    Prepared,
    Dropped,
    RateLimited,
    ActionsExecuted,
    Completed,
}

impl DeliveryState {
    pub fn raw_value(self) -> &'static str {
        match self {
            Self::Ingested => "ingested",
            Self::Coalesced => "coalesced",
            Self::RetryScheduled => "retryScheduled",
            Self::Prepared => "prepared",
            Self::Dropped => "dropped",
            Self::RateLimited => "rateLimited",
            Self::ActionsExecuted => "actionsExecuted",
            Self::Completed => "completed",
        }
    }
}

/// `NotificationHistory.Entry`.
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct HistoryEntry {
    pub id: Uuid,
    pub source: String,
    #[serde(rename = "type")]
    pub event_type: String,
    pub raw_type: Option<String>,
    pub semantic_kind: Option<String>,
    pub tool: String,
    pub message: String,
    pub notification_type: Option<String>,
    pub timestamp: DateTime<Utc>,
    pub reliability: String,
    pub producer: Option<String>,
    pub trigger_id: Option<String>,
    pub actions_executed: Vec<String>,
    pub was_rate_limited: bool,
    pub delivery_state: DeliveryState,
    pub drop_reason: Option<String>,
    pub resolution_method: Option<String>,
    #[serde(rename = "resolvedTabID")]
    pub resolved_tab_id: Option<String>,
    pub did_dispatch_banner: bool,
    pub did_style_tab: bool,
    pub notes: Vec<String>,
    pub classification_confidence: Option<String>,
    pub classification_evidence: Vec<String>,
}

/// Swift `UUID.uuidString`: upper-case hyphenated.
fn uuid_string(id: Uuid) -> String {
    id.hyphenated().to_string().to_uppercase()
}

/// The "Notification Reliability" box of the Debug Console's Health tab
/// (DBG-023), over the entries given (Swift: the last 100).
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct ReliabilitySummary {
    pub entries: usize,
    pub completed: usize,
    pub dropped: usize,
    pub retries: usize,
    pub rate_limited: usize,
    pub authoritative: usize,
}

impl ReliabilitySummary {
    pub fn of(entries: &[HistoryEntry]) -> Self {
        let count = |f: &dyn Fn(&HistoryEntry) -> bool| entries.iter().filter(|e| f(e)).count();
        Self {
            entries: entries.len(),
            completed: count(&|e| e.delivery_state == DeliveryState::Completed),
            dropped: count(&|e| e.delivery_state == DeliveryState::Dropped),
            retries: count(&|e| e.delivery_state == DeliveryState::RetryScheduled),
            rate_limited: count(&|e| e.was_rate_limited),
            authoritative: count(&|e| e.reliability == "authoritative"),
        }
    }
}

/// The ledger (`NotificationHistory`).
#[derive(Debug)]
pub struct NotificationHistory {
    entries: HashMap<Uuid, HistoryEntry>,
    order: VecDeque<Uuid>,
    max_entries: usize,
}

impl Default for NotificationHistory {
    fn default() -> Self {
        Self::new(100)
    }
}

impl NotificationHistory {
    pub fn new(max_entries: usize) -> Self {
        Self {
            entries: HashMap::new(),
            order: VecDeque::new(),
            max_entries,
        }
    }

    /// Starts (or restarts) the entry for an accepted event.
    pub fn begin(
        &mut self,
        event: &AiEvent,
        semantic_kind: Option<&str>,
        raw_type: Option<&str>,
        notification_type: Option<&str>,
    ) {
        let effective_raw = raw_type
            .map(str::to_string)
            .or_else(|| event.raw_type.clone());
        let mut notes = Vec::new();
        if let Some(raw) = effective_raw.as_ref().filter(|r| **r != event.event_type) {
            notes.push(format!("rawType:{raw}"));
        }
        if let Some(n) = notification_type {
            notes.push(format!("notificationType:{n}"));
        }
        let assessment = (event.source.raw_value() == AiEventSource::CODEX)
            .then(|| codex_feedback::assess(&event.message))
            .flatten();
        let entry = HistoryEntry {
            id: event.id,
            source: event.source.raw_value().to_string(),
            event_type: event.event_type.clone(),
            raw_type: effective_raw,
            semantic_kind: semantic_kind.map(str::to_string),
            tool: event.tool.clone(),
            message: event.message.clone(),
            notification_type: event.notification_type.clone(),
            timestamp: Utc::now(),
            reliability: event.reliability.raw_value().to_string(),
            producer: event.producer.clone(),
            trigger_id: None,
            actions_executed: Vec::new(),
            was_rate_limited: false,
            delivery_state: DeliveryState::Ingested,
            drop_reason: None,
            resolution_method: None,
            resolved_tab_id: event.tab_id.map(uuid_string),
            did_dispatch_banner: false,
            did_style_tab: false,
            notes,
            classification_confidence: assessment
                .as_ref()
                .map(|a| a.confidence.raw_value().to_string()),
            classification_evidence: assessment.map(|a| a.evidence).unwrap_or_default(),
        };
        self.store(entry);
    }

    pub fn mark_canonicalized(
        &mut self,
        id: Uuid,
        semantic_kind: &str,
        raw_type: Option<&str>,
        notification_type: Option<&str>,
    ) {
        self.update(id, |e| {
            e.semantic_kind = Some(semantic_kind.to_string());
            if let Some(raw) = raw_type {
                e.notes.push(format!("rawType:{raw}"));
            }
            if let Some(n) = notification_type {
                e.notes.push(format!("notificationType:{n}"));
            }
        });
    }

    pub fn mark_coalesced(&mut self, id: Uuid, key: &str) {
        self.update(id, |e| {
            e.delivery_state = DeliveryState::Coalesced;
            e.notes.push(format!("coalesced:{key}"));
        });
    }

    pub fn mark_retry_scheduled(&mut self, id: Uuid, attempt: usize, reason: &str) {
        self.update(id, |e| {
            e.delivery_state = DeliveryState::RetryScheduled;
            e.drop_reason = None;
            e.notes.push(format!("retry#{attempt}:{reason}"));
        });
    }

    pub fn mark_prepared(&mut self, event: &AiEvent, resolution_method: &str) {
        self.update(event.id, |e| {
            e.delivery_state = DeliveryState::Prepared;
            e.resolution_method = Some(resolution_method.to_string());
            e.resolved_tab_id = event.tab_id.map(uuid_string);
        });
    }

    pub fn mark_dropped(&mut self, id: Uuid, trigger_id: Option<&str>, reason: &str) {
        self.update(id, |e| {
            e.delivery_state = DeliveryState::Dropped;
            if let Some(t) = trigger_id {
                e.trigger_id = Some(t.to_string());
            }
            e.drop_reason = Some(reason.to_string());
        });
    }

    pub fn mark_rate_limited(&mut self, id: Uuid, trigger_id: &str) {
        self.update(id, |e| {
            e.delivery_state = DeliveryState::RateLimited;
            e.trigger_id = Some(trigger_id.to_string());
            e.was_rate_limited = true;
        });
    }

    pub fn mark_actions_executed(
        &mut self,
        id: Uuid,
        trigger_id: Option<&str>,
        actions: &[String],
        did_dispatch_banner: bool,
        did_style_tab: bool,
    ) {
        self.update(id, |e| {
            e.delivery_state = DeliveryState::ActionsExecuted;
            if let Some(t) = trigger_id {
                e.trigger_id = Some(t.to_string());
            }
            e.actions_executed = actions.to_vec();
            e.did_dispatch_banner |= did_dispatch_banner;
            e.did_style_tab |= did_style_tab;
            e.drop_reason = None;
        });
    }

    pub fn mark_completed(&mut self, id: Uuid) {
        self.update(id, |e| e.delivery_state = DeliveryState::Completed);
    }

    pub fn append_note(&mut self, id: Uuid, note: impl Into<String>) {
        let note = note.into();
        self.update(id, |e| e.notes.push(note));
    }

    /// Newest first, at most `limit`.
    pub fn recent(&self, limit: usize) -> Vec<HistoryEntry> {
        self.order
            .iter()
            .rev()
            .take(limit)
            .filter_map(|id| self.entries.get(id).cloned())
            .collect()
    }

    pub fn clear(&mut self) {
        self.entries.clear();
        self.order.clear();
    }

    pub fn len(&self) -> usize {
        self.entries.len()
    }

    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }

    fn store(&mut self, entry: HistoryEntry) {
        if !self.entries.contains_key(&entry.id) {
            if self.order.len() >= self.max_entries
                && let Some(oldest) = self.order.pop_front()
            {
                self.entries.remove(&oldest);
            }
            self.order.push_back(entry.id);
        }
        self.entries.insert(entry.id, entry);
    }

    fn update(&mut self, id: Uuid, mutate: impl FnOnce(&mut HistoryEntry)) {
        if let Some(entry) = self.entries.get_mut(&id) {
            mutate(entry);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ai::event::{AiEventReliability, AiEventSource};

    #[test]
    fn codex_history_exports_assessment_evidence_without_assessing_other_providers() {
        let mut history = NotificationHistory::default();
        let e = AiEvent::new(
            AiEventSource::codex(),
            "waiting_input",
            "Codex",
            "Should I continue?",
            "t",
        );
        history.begin(
            &e,
            Some("waiting_for_input"),
            Some("agent-turn-complete"),
            None,
        );
        let entry = history.recent(1).remove(0);
        assert_eq!(entry.classification_confidence.as_deref(), Some("medium"));
        assert_eq!(entry.classification_evidence, ["direct_terminal_question"]);
        let json = serde_json::to_value(&entry).unwrap();
        assert_eq!(json["classificationConfidence"], "medium");
        assert_eq!(
            json["classificationEvidence"][0],
            "direct_terminal_question"
        );
        let mut non_codex = e.clone();
        non_codex.source = AiEventSource::runtime();
        history.begin(&non_codex, None, None, None);
        let entry = history.recent(1).remove(0);
        assert!(entry.classification_confidence.is_none());
        assert!(entry.classification_evidence.is_empty());
    }

    #[test]
    fn history_tracks_delivery_lifecycle() {
        let mut history = NotificationHistory::new(10);
        let mut event = AiEvent::new(
            AiEventSource::runtime(),
            "finished",
            "Claude",
            "done",
            "2026-04-01T00:00:00Z",
        );
        event.session_id = Some("session-1".into());
        event.producer = Some("runtime_session_manager".into());
        event.reliability = AiEventReliability::Authoritative;

        history.begin(
            &event,
            Some("task_finished"),
            Some("response_complete"),
            Some("idle_prompt"),
        );
        history.mark_prepared(&event, "explicit_tab");
        history.mark_actions_executed(
            event.id,
            Some("runtime.finished"),
            &["showNotification".into(), "styleTab".into()],
            true,
            true,
        );
        history.mark_completed(event.id);

        let entry = history.recent(1).remove(0);
        assert_eq!(entry.id, event.id);
        assert_eq!(entry.delivery_state, DeliveryState::Completed);
        assert_eq!(entry.trigger_id.as_deref(), Some("runtime.finished"));
        assert_eq!(entry.actions_executed, ["showNotification", "styleTab"]);
        assert!(entry.did_dispatch_banner);
        assert!(entry.did_style_tab);
        assert_eq!(entry.reliability, "authoritative");
        assert_eq!(entry.raw_type.as_deref(), Some("response_complete"));
        assert_eq!(entry.semantic_kind.as_deref(), Some("task_finished"));
        assert!(
            entry
                .notes
                .contains(&"rawType:response_complete".to_string())
        );
        assert!(
            entry
                .notes
                .contains(&"notificationType:idle_prompt".to_string())
        );
    }

    #[test]
    fn history_keeps_the_newest_entries() {
        let mut history = NotificationHistory::new(2);
        let events: Vec<_> = (0..3)
            .map(|i| AiEvent::new(AiEventSource::app(), format!("t{i}"), "App", "", "t"))
            .collect();
        for e in &events {
            history.begin(e, None, None, None);
        }
        assert_eq!(history.len(), 2);
        let recent = history.recent(10);
        assert_eq!(recent[0].event_type, "t2");
        assert_eq!(recent[1].event_type, "t1");
        // Updates to a forgotten entry are ignored.
        history.mark_dropped(events[0].id, None, "x");
        history.mark_rate_limited(events[2].id, "app.t2");
        history.mark_coalesced(events[1].id, "k");
        history.mark_retry_scheduled(events[1].id, 1, "why");
        history.append_note(events[1].id, "note");
        let recent = history.recent(10);
        assert!(recent[0].was_rate_limited);
        assert_eq!(recent[0].delivery_state, DeliveryState::RateLimited);
        assert_eq!(recent[1].delivery_state, DeliveryState::RetryScheduled);
        assert_eq!(recent[1].notes, ["coalesced:k", "retry#1:why", "note"]);
        history.clear();
        assert!(history.is_empty());
    }

    #[test]
    fn reliability_summary_counts_states() {
        let mut history = NotificationHistory::new(100);
        let mk = |t: &str, reliability| {
            let mut e = AiEvent::new(AiEventSource::app(), t, "App", "", "t");
            e.reliability = reliability;
            e
        };
        let done = mk("done", AiEventReliability::Authoritative);
        let dropped = mk("dropped", AiEventReliability::Fallback);
        let retry = mk("retry", AiEventReliability::Authoritative);
        let limited = mk("limited", AiEventReliability::Fallback);
        for e in [&done, &dropped, &retry, &limited] {
            history.begin(e, None, None, None);
        }
        history.mark_completed(done.id);
        history.mark_dropped(dropped.id, None, "no trigger");
        history.mark_retry_scheduled(retry.id, 1, "no tab");
        history.mark_rate_limited(limited.id, "t");
        let summary = ReliabilitySummary::of(&history.recent(100));
        assert_eq!(
            summary,
            ReliabilitySummary {
                entries: 4,
                completed: 1,
                dropped: 1,
                retries: 1,
                rate_limited: 1,
                authoritative: 2,
            }
        );
        assert_eq!(ReliabilitySummary::of(&[]), ReliabilitySummary::default());
    }
}
