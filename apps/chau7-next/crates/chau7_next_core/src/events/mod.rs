//! Current Swift event envelope, topic catalog, ordered spine and durable journal.
//! Mirrors Chau7Core/Events and the app's SpineJournalStore. Caller wiring is app-side.
mod journal;
use crate::ai::event::AiEvent;
use chrono::{DateTime, Utc};
pub use journal::SpineJournalStore;
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};
use std::collections::{BTreeSet, VecDeque};
use std::sync::{
    Arc, Mutex, Weak,
    mpsc::{self, Receiver, Sender, SyncSender, TrySendError},
};
use uuid::Uuid;

pub const SUPPORTED_TOPICS: [&str; 7] = [
    "approval-state",
    "repo-events",
    "runtime-events",
    "session-state",
    "tab-state",
    "telemetry-runs",
    "timer-inventory",
];

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct StructuralEvent {
    pub event_type: String,
    pub subsystem: String,
    pub tab_id: Option<String>,
    pub session_id: Option<String>,
    pub run_id: Option<String>,
    pub repo_path: Option<String>,
    pub detail: Map<String, Value>,
}
impl StructuralEvent {
    pub fn new(event_type: impl Into<String>, subsystem: impl Into<String>) -> Self {
        Self {
            event_type: event_type.into(),
            subsystem: subsystem.into(),
            ..Self::default()
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "kind", content = "event", rename_all = "snake_case")]
pub enum EventPayload {
    Ai(Box<AiEvent>),
    Structural(Box<StructuralEvent>),
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct EventEnvelope {
    pub seq: u64,
    pub event_id: Uuid,
    pub correlation_id: Option<String>,
    /// Captured at admission, independently of the process-local routing ID in
    /// AiEvent. Legacy records have no public attribution and keep their raw ID.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub public_tab_id: Option<Uuid>,
    pub occurred_at: DateTime<Utc>,
    pub ingested_at: DateTime<Utc>,
    pub topics: Vec<String>,
    pub delivery_requested: bool,
    pub payload: EventPayload,
}
impl EventEnvelope {
    pub fn ai_event(&self) -> Option<&AiEvent> {
        match &self.payload {
            EventPayload::Ai(event) => Some(event),
            _ => None,
        }
    }
    pub fn structural_event(&self) -> Option<&StructuralEvent> {
        match &self.payload {
            EventPayload::Structural(event) => Some(event),
            _ => None,
        }
    }
}

#[derive(Debug, Default)]
pub struct TopicContext<'a> {
    pub event_type: &'a str,
    pub subsystem: &'a str,
    pub has_tab: bool,
    pub has_session: bool,
    pub has_run: bool,
    pub has_repo: bool,
}
/// Explicit catalog + additive identity facts. Unknown names have no prefix heuristics.
pub fn topics(context: &TopicContext<'_>) -> Vec<String> {
    let mut result = BTreeSet::from(["runtime-events"]);
    match context.event_type {
        "ai_event" => {
            result.insert("repo-events");
        }
        "tab_created" | "tab_closed" | "tab_opened" | "tab_switched" => {
            result.insert("tab-state");
        }
        "approval_waiting" | "approval_resolved" | "approval_needed" => {
            result.insert("approval-state");
        }
        "telemetry_run_started" | "telemetry_run_updated" | "telemetry_run_completed" => {
            result.insert("telemetry-runs");
        }
        "timer_registered" | "timer_updated" | "timer_scope_updated" => {
            result.insert("timer-inventory");
        }
        _ => {}
    }
    match context.subsystem {
        "tabs" => {
            result.insert("tab-state");
        }
        "mcp_approvals" => {
            result.insert("approval-state");
        }
        _ => {}
    }
    if context.has_tab {
        result.insert("tab-state");
    }
    if context.has_session {
        result.insert("session-state");
    }
    if context.has_run {
        result.insert("telemetry-runs");
    }
    if context.has_repo {
        result.insert("repo-events");
    }
    result.into_iter().map(str::to_string).collect()
}
fn payload_topics(payload: &EventPayload) -> Vec<String> {
    let context = match payload {
        EventPayload::Ai(event) => TopicContext {
            event_type: "ai_event",
            subsystem: &event.source.0,
            has_tab: event.tab_id.is_some(),
            has_session: event.session_id.is_some(),
            has_run: false,
            has_repo: event.repo_path.is_some(),
        },
        EventPayload::Structural(event) => TopicContext {
            event_type: &event.event_type,
            subsystem: &event.subsystem,
            has_tab: event.tab_id.is_some(),
            has_session: event.session_id.is_some(),
            has_run: event.run_id.is_some(),
            has_repo: event.repo_path.is_some(),
        },
    };
    topics(&context)
}

struct State {
    next_seq: u64,
    envelopes: VecDeque<EventEnvelope>,
    sender: Option<Sender<EventEnvelope>>,
    change_listeners: Vec<Weak<SyncSender<()>>>,
}
/// One allocation/delivery lock fixes global order across concurrent producers.
/// Exactly one stream consumer may take the receiver; replay does not consume it.
pub struct EventSpine {
    capacity: usize,
    state: Mutex<State>,
    receiver: Mutex<Option<Receiver<EventEnvelope>>>,
}
#[derive(Debug)]
pub struct Replay {
    pub envelopes: Vec<EventEnvelope>,
    pub cursor: u64,
    pub has_more: bool,
}
impl EventSpine {
    pub fn new(capacity: usize, start_seq: u64) -> Self {
        assert!(capacity > 0);
        let (sender, receiver) = mpsc::channel();
        Self {
            capacity,
            state: Mutex::new(State {
                next_seq: start_seq,
                envelopes: VecDeque::with_capacity(capacity),
                sender: Some(sender),
                change_listeners: Vec::new(),
            }),
            receiver: Mutex::new(Some(receiver)),
        }
    }
    pub fn take_stream(&self) -> Option<Receiver<EventEnvelope>> {
        self.receiver
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .take()
    }
    /// Register before replaying. A pending token covers all changes until the
    /// consumer drains replay; payloads stay in the bounded authoritative ring.
    /// The returned sender also wakes the consumer for arming or cancellation.
    pub fn watch_changes(&self) -> (Arc<SyncSender<()>>, Receiver<()>) {
        let (sender, receiver) = mpsc::sync_channel(1);
        let sender = Arc::new(sender);
        let mut state = self.state.lock().unwrap_or_else(|e| e.into_inner());
        state
            .change_listeners
            .retain(|listener| listener.strong_count() > 0);
        state.change_listeners.push(Arc::downgrade(&sender));
        (sender, receiver)
    }
    pub fn finish(&self) {
        self.state.lock().unwrap_or_else(|e| e.into_inner()).sender = None;
    }
    pub fn ingest_ai(
        &self,
        event: AiEvent,
        correlation_id: Option<String>,
        delivery_requested: bool,
    ) -> EventEnvelope {
        self.ingest_ai_attributed(event, correlation_id, delivery_requested, None)
    }
    pub fn ingest_ai_attributed(
        &self,
        event: AiEvent,
        correlation_id: Option<String>,
        delivery_requested: bool,
        public_tab_id: Option<Uuid>,
    ) -> EventEnvelope {
        let ingested_at = Utc::now();
        let occurred_at =
            crate::telemetry::date_codec::parse_iso8601(Some(&event.ts)).unwrap_or(ingested_at);
        self.ingest(EventEnvelope {
            seq: 0,
            event_id: event.id,
            correlation_id,
            public_tab_id,
            occurred_at,
            ingested_at,
            delivery_requested,
            topics: Vec::new(),
            payload: EventPayload::Ai(Box::new(event)),
        })
    }
    pub fn ingest_structural(
        &self,
        event: StructuralEvent,
        correlation_id: Option<String>,
        event_id: Option<Uuid>,
        occurred_at: Option<DateTime<Utc>>,
    ) -> EventEnvelope {
        let ingested_at = Utc::now();
        self.ingest(EventEnvelope {
            seq: 0,
            event_id: event_id.unwrap_or_else(Uuid::new_v4),
            correlation_id,
            public_tab_id: None,
            occurred_at: occurred_at.unwrap_or(ingested_at),
            ingested_at,
            delivery_requested: false,
            topics: Vec::new(),
            payload: EventPayload::Structural(Box::new(event)),
        })
    }
    fn ingest(&self, mut envelope: EventEnvelope) -> EventEnvelope {
        let mut state = self.state.lock().unwrap_or_else(|e| e.into_inner());
        state.next_seq = state
            .next_seq
            .checked_add(1)
            .expect("event sequence exhausted");
        envelope.seq = state.next_seq;
        envelope.topics = payload_topics(&envelope.payload);
        state.envelopes.push_back(envelope.clone());
        while state.envelopes.len() > self.capacity {
            state.envelopes.pop_front();
        }
        if let Some(sender) = &state.sender {
            let _ = sender.send(envelope.clone());
        }
        // Nonblocking and coalesced: slow subscribers never queue payloads or
        // delay producers. Weak senders disappear when subscriptions stop.
        state.change_listeners.retain(|listener| {
            let Some(sender) = listener.upgrade() else {
                return false;
            };
            matches!(sender.try_send(()), Ok(()) | Err(TrySendError::Full(())))
        });
        envelope
    }
    pub fn latest_cursor(&self) -> u64 {
        self.state
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .next_seq
    }
    pub fn oldest_cursor(&self) -> u64 {
        self.state
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .envelopes
            .front()
            .map_or(0, |e| e.seq)
    }
    pub fn count(&self) -> usize {
        self.state
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .envelopes
            .len()
    }
    pub fn replay(&self, cursor: u64, limit: usize) -> Replay {
        let state = self.state.lock().unwrap_or_else(|e| e.into_inner());
        let envelopes = state
            .envelopes
            .iter()
            .filter(|e| e.seq > cursor)
            .take(limit)
            .cloned()
            .collect::<Vec<_>>();
        let next = envelopes.last().map_or(cursor, |e| e.seq);
        let has_more = state.envelopes.iter().any(|e| e.seq > next);
        Replay {
            envelopes,
            cursor: next,
            has_more,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ai::event::{AiEventReliability, AiEventSource};
    #[test]
    fn change_wakes_coalesce_without_losing_ordered_replay() {
        let spine = EventSpine::new(4096, 0);
        spine.finish();
        let (_wake, changes) = spine.watch_changes();
        for _ in 0..4096 {
            spine.ingest_structural(
                StructuralEvent::new("tab_created", "tabs"),
                None,
                None,
                None,
            );
        }
        assert_eq!(changes.try_recv(), Ok(()));
        assert_eq!(changes.try_recv(), Err(mpsc::TryRecvError::Empty));
        let replay = spine.replay(0, 4096);
        assert_eq!(
            replay.envelopes.iter().map(|e| e.seq).collect::<Vec<_>>(),
            (1..=4096).collect::<Vec<_>>()
        );
        assert!(!replay.has_more);
        // A change after draining replay is still pending before the next wait.
        spine.ingest_structural(StructuralEvent::new("tab_closed", "tabs"), None, None, None);
        assert_eq!(changes.try_recv(), Ok(()));
        assert_eq!(spine.replay(replay.cursor, 1).envelopes[0].seq, 4097);
    }
    #[test]
    fn change_watchers_are_independent_and_reclaimed_during_idle_churn() {
        let spine = EventSpine::new(8, 0);
        spine.finish();
        let (wake, first) = spine.watch_changes();
        let (other_wake, second) = spine.watch_changes();
        assert_eq!(first.try_recv(), Err(mpsc::TryRecvError::Empty));
        spine.ingest_structural(
            StructuralEvent::new("tab_created", "tabs"),
            None,
            None,
            None,
        );
        assert_eq!(first.try_recv(), Ok(()));
        assert_eq!(second.try_recv(), Ok(()));
        drop((wake, first, other_wake, second));
        // Registration must prune even when no further event is published.
        for _ in 0..1000 {
            drop(spine.watch_changes());
        }
        assert_eq!(spine.state.lock().unwrap().change_listeners.len(), 1);
        let (wake, receiver) = spine.watch_changes();
        drop(receiver);
        spine.ingest_structural(StructuralEvent::new("tab_closed", "tabs"), None, None, None);
        assert!(spine.state.lock().unwrap().change_listeners.is_empty());
        drop(wake);
    }
    #[test]
    fn concurrent_ingest_stream_and_replay_have_the_same_dense_order() {
        let spine = Arc::new(EventSpine::new(2000, 0));
        let stream = spine.take_stream().unwrap();
        assert!(spine.take_stream().is_none());
        let workers = (0..8)
            .map(|_| {
                let spine = spine.clone();
                std::thread::spawn(move || {
                    for _ in 0..250 {
                        spine.ingest_structural(
                            StructuralEvent::new("tab_created", "tabs"),
                            None,
                            None,
                            None,
                        );
                    }
                })
            })
            .collect::<Vec<_>>();
        for worker in workers {
            worker.join().unwrap();
        }
        let replay = spine.replay(0, 2000);
        assert_eq!(
            replay.envelopes.iter().map(|e| e.seq).collect::<Vec<_>>(),
            (1..=2000).collect::<Vec<_>>()
        );
        assert!(!replay.has_more);
        assert_eq!(
            stream.try_iter().map(|e| e.seq).collect::<Vec<_>>(),
            (1..=2000).collect::<Vec<_>>()
        );
    }
    #[test]
    fn eviction_limits_cursors_and_restart_seed() {
        let spine = EventSpine::new(2, 40);
        for _ in 0..3 {
            spine.ingest_structural(StructuralEvent::new("x", "x"), None, None, None);
        }
        assert_eq!(spine.latest_cursor(), 43);
        assert_eq!(spine.oldest_cursor(), 42);
        assert_eq!(spine.count(), 2);
        let first = spine.replay(0, 1);
        assert_eq!(first.cursor, 42);
        assert!(first.has_more);
        assert_eq!(spine.replay(first.cursor, 1).cursor, 43);
        assert_eq!(spine.replay(100, 2).cursor, 100);
    }
    #[test]
    fn topics_are_declared_contextual_sorted_and_not_prefix_guesses() {
        assert_eq!(
            topics(&TopicContext {
                event_type: "timer_mystery",
                ..Default::default()
            }),
            ["runtime-events"]
        );
        assert_eq!(
            topics(&TopicContext {
                event_type: "approval_waiting",
                subsystem: "mcp_approvals",
                has_tab: true,
                ..Default::default()
            }),
            ["approval-state", "runtime-events", "tab-state"]
        );
        assert_eq!(
            topics(&TopicContext {
                has_repo: true,
                has_session: true,
                has_run: true,
                ..Default::default()
            }),
            [
                "repo-events",
                "runtime-events",
                "session-state",
                "telemetry-runs"
            ]
        );
    }
    #[test]
    fn producer_identity_time_and_all_event_fields_survive_serialization() {
        let spine = EventSpine::new(2, 0);
        let mut event = AiEvent::new(
            AiEventSource::claude_code(),
            "finished",
            "Claude",
            "done",
            "2023-11-14T22:13:20Z",
        );
        event.repo_path = Some("/test-repo".into());
        event.raw_type = Some("turn_complete".into());
        event.producer = Some("hooks".into());
        event.reliability = AiEventReliability::Fallback;
        let envelope = spine.ingest_ai(event.clone(), Some("corr-1".into()), false);
        assert_eq!(envelope.event_id, event.id);
        assert_eq!(envelope.occurred_at.timestamp(), 1700000000);
        assert!(!envelope.delivery_requested);
        let decoded: EventEnvelope =
            serde_json::from_slice(&serde_json::to_vec(&envelope).unwrap()).unwrap();
        assert_eq!(decoded, envelope);
        assert_eq!(decoded.ai_event(), Some(&event));
    }
    #[test]
    fn invalid_time_falls_back_and_structural_time_is_preserved() {
        let spine = EventSpine::new(2, 0);
        let envelope = spine.ingest_ai(
            AiEvent::new(AiEventSource::app(), "finished", "", "", "garbage"),
            None,
            true,
        );
        assert_eq!(envelope.occurred_at, envelope.ingested_at);
        let envelope = spine.ingest_structural(
            StructuralEvent::new("x", "x"),
            None,
            None,
            Some(envelope.occurred_at),
        );
        assert!(!envelope.delivery_requested);
        spine.finish();
        assert!(spine.take_stream().unwrap().iter().count() == 2);
    }
}
