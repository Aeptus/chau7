//! Ordered app-wide evidence. Disk writes run on one worker; projections run on GPUI.
use chau7_next_core::ai::event::AiEvent;
use chau7_next_core::events::{
    EventEnvelope, EventPayload, EventSpine, SpineJournalStore, StructuralEvent,
};
use futures::{StreamExt, channel::mpsc};
use gpui::{App, Global};
use serde_json::{Value, json};
use std::collections::{BTreeMap, VecDeque};
use std::sync::{Arc, Condvar, Mutex};
use std::thread::JoinHandle;
use std::time::Duration;
use uuid::Uuid;

struct PersistenceState {
    processed: u64,
    error: Option<String>,
}
#[derive(Clone)]
pub struct Journal {
    spine: Arc<EventSpine>,
    store: Option<Arc<SpineJournalStore>>,
    progress: Arc<(Mutex<PersistenceState>, Condvar)>,
}
impl Journal {
    pub fn latest_seq(&self) -> u64 {
        self.spine.latest_cursor()
    }
    pub fn oldest_seq(&self) -> u64 {
        self.spine.oldest_cursor()
    }
    pub fn replay(&self, cursor: u64, limit: usize) -> chau7_next_core::events::Replay {
        self.spine.replay(cursor, limit)
    }
    /// Called on a client/background thread, never on the GPUI thread.
    pub fn persisted_events(&self, after: u64, limit: usize) -> Result<Vec<EventEnvelope>, String> {
        let Some(store) = &self.store else {
            return Err("Durable event journal is unavailable".into());
        };
        let target = self.latest_seq();
        let (lock, condition) = &*self.progress;
        let state = lock.lock().unwrap_or_else(|e| e.into_inner());
        let (state, timeout) = condition
            .wait_timeout_while(state, Duration::from_secs(5), |s| {
                s.processed < target && s.error.is_none()
            })
            .unwrap_or_else(|e| e.into_inner());
        if let Some(error) = &state.error {
            return Err(format!("Event journal write failed: {error}"));
        }
        if timeout.timed_out() && state.processed < target {
            return Err("Event journal is still flushing".into());
        }
        drop(state);
        store
            .envelopes(after, limit)
            .map_err(|error| error.to_string())
    }
    pub fn status(&self) -> Value {
        let state = self.progress.0.lock().unwrap_or_else(|e| e.into_inner());
        json!({"latest_seq": self.latest_seq(), "oldest_memory_seq": self.spine.oldest_cursor(), "retained_memory_events":self.spine.count(), "processed_seq":state.processed, "durable_available":self.store.is_some(), "persistence_error":state.error})
    }
}
struct Observability {
    journal: Journal,
    worker: Option<JoinHandle<()>>,
    events: VecDeque<EventEnvelope>,
    timers: TimerRecords,
}
impl Global for Observability {}

pub fn init(cx: &mut App) {
    let path = cx
        .global::<crate::workspace::AppData>()
        .root
        .event_journal_file();
    let store = (|| {
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent).map_err(|e| e.to_string())?;
        }
        SpineJournalStore::open(&path, 50_000)
            .map(Arc::new)
            .map_err(|e| e.to_string())
    })();
    let store = match store {
        Ok(store) => Some(store),
        Err(error) => {
            log::error!("event journal open: {error}");
            None
        }
    };
    let start = store
        .as_ref()
        .and_then(|store| match store.high_water_seq() {
            Ok(seq) => Some(seq),
            Err(error) => {
                log::error!("event journal cursor: {error}");
                None
            }
        })
        .unwrap_or(0);
    let spine = Arc::new(EventSpine::new(2_000, start));
    let stream = spine.take_stream().expect("one event-spine consumer");
    let progress = Arc::new((
        Mutex::new(PersistenceState {
            processed: start,
            error: None,
        }),
        Condvar::new(),
    ));
    let journal = Journal {
        spine,
        store,
        progress,
    };
    let worker_journal = journal.clone();
    let (tx, mut rx) = mpsc::unbounded::<EventEnvelope>();
    let emergency_progress = journal.progress.clone();
    let worker = std::thread::Builder::new()
        .name("chau7-next-event-spine".into())
        .spawn(move || {
            let (writes, pending) = std::sync::mpsc::channel::<EventEnvelope>();
            let writer = std::thread::Builder::new()
                .name("chau7-next-event-journal".into())
                .spawn(move || {
                    for envelope in pending {
                        let error = worker_journal
                            .store
                            .as_ref()
                            .and_then(|store| store.persist(&envelope).err())
                            .map(|error| error.to_string());
                        if let Some(error) = &error {
                            log::error!("event journal persist seq={}: {error}", envelope.seq);
                        }
                        let mut state = worker_journal
                            .progress
                            .0
                            .lock()
                            .unwrap_or_else(|e| e.into_inner());
                        state.processed = envelope.seq;
                        if error.is_some() {
                            state.error = error;
                        }
                        worker_journal.progress.1.notify_all();
                    }
                });
            if let Err(error) = &writer {
                log::error!("event journal writer: {error}");
                emergency_progress
                    .0
                    .lock()
                    .unwrap_or_else(|e| e.into_inner())
                    .error = Some(error.to_string());
                emergency_progress.1.notify_all();
            }
            for envelope in stream {
                // Disk stalls cannot delay the main-thread notification projections.
                let _ = writes.send(envelope.clone());
                if tx.unbounded_send(envelope).is_err() {
                    break;
                }
            }
            drop(writes);
            if let Ok(writer) = writer {
                let _ = writer.join();
            }
        });
    let worker = match worker {
        Ok(worker) => Some(worker),
        Err(error) => {
            log::error!("event journal worker: {error}");
            journal
                .progress
                .0
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .error = Some(error.to_string());
            journal.progress.1.notify_all();
            None
        }
    };
    cx.set_global(Observability {
        journal,
        worker,
        events: VecDeque::new(),
        timers: Arc::default(),
    });
    cx.spawn(async move |cx| {
        while let Some(envelope) = rx.next().await {
            cx.update(|cx| {
                {
                    let events = &mut cx.global_mut::<Observability>().events;
                    events.push_back(envelope.clone());
                    while events.len() > 1_000 {
                        events.pop_front();
                    }
                }
                if let EventPayload::Ai(event) = envelope.payload {
                    crate::ai::events_out::project(*event, envelope.delivery_requested, cx);
                }
            });
        }
    })
    .detach();
    record(StructuralEvent::new("app_launched", "app"), cx);
}

pub fn journal(cx: &App) -> Option<Journal> {
    cx.try_global::<Observability>()
        .map(|host| host.journal.clone())
}

pub fn publish(event: AiEvent, notify: bool, cx: &App) -> bool {
    let Some(host) = cx.try_global::<Observability>() else {
        return false;
    };
    let public_tab_id = event.tab_id.and_then(|raw| {
        for (_, workspace) in crate::workspace::AppData::live(cx) {
            let workspace = workspace.read(cx);
            for uuid in workspace.mcp_tab_uuids() {
                if uuid == raw
                    || workspace
                        .mcp_find(uuid)
                        .is_some_and(|tab| crate::ai::events_out::tab_uuid(tab) == raw)
                {
                    return Some(uuid);
                }
            }
        }
        None
    });
    host.journal
        .spine
        .ingest_ai_attributed(event, None, notify, public_tab_id);
    true
}
pub fn record(event: StructuralEvent, cx: &App) {
    if let Some(host) = cx.try_global::<Observability>() {
        host.journal
            .spine
            .ingest_structural(event, None, None, None);
    }
}
struct TimerRecord {
    generation: Uuid,
    payload: Value,
}
type TimerRecords = Arc<Mutex<BTreeMap<String, TimerRecord>>>;

/// A real scheduled task owns this guard; cancelling it updates the timer inventory.
pub struct TimerGuard {
    id: String,
    generation: Uuid,
    timers: TimerRecords,
    spine: Arc<EventSpine>,
}
impl Drop for TimerGuard {
    fn drop(&mut self) {
        let mut timers = self.timers.lock().unwrap_or_else(|e| e.into_inner());
        let Some(timer) = timers.get_mut(&self.id) else {
            return;
        };
        // A cancelled older task must not deactivate its replacement.
        if timer.generation != self.generation {
            return;
        }
        timer.payload["active"] = json!(false);
        let mut event = StructuralEvent::new("timer_updated", "observability");
        event.detail.insert("timer_id".into(), json!(self.id));
        event.detail.insert("active".into(), json!(false));
        // Serialize timer mutation and its public spine event together.
        self.spine.ingest_structural(event, None, None, None);
    }
}
pub fn register_timer(
    cx: &App,
    id: &str,
    label: &str,
    subsystem: &str,
    interval_ms: u64,
) -> TimerGuard {
    register_task_timer(
        cx,
        id,
        label,
        subsystem,
        interval_ms,
        "gpui_task",
        "gpui-main",
    )
}
pub fn register_background_timer(
    cx: &App,
    id: &str,
    label: &str,
    subsystem: &str,
    interval_ms: u64,
) -> TimerGuard {
    register_task_timer(
        cx,
        id,
        label,
        subsystem,
        interval_ms,
        "background_task",
        "gpui-background-executor",
    )
}
fn register_task_timer(
    cx: &App,
    id: &str,
    label: &str,
    subsystem: &str,
    interval_ms: u64,
    kind: &str,
    queue: &str,
) -> TimerGuard {
    timer_registry(cx)
        .expect("observability initialized")
        .register(id, label, subsystem, interval_ms, kind, queue)
}
#[derive(Clone)]
pub struct TimerRegistry {
    timers: TimerRecords,
    spine: Arc<EventSpine>,
}
pub fn timer_registry(cx: &App) -> Option<TimerRegistry> {
    cx.try_global::<Observability>().map(|host| TimerRegistry {
        timers: host.timers.clone(),
        spine: host.journal.spine.clone(),
    })
}
impl TimerRegistry {
    pub fn register(
        &self,
        id: &str,
        label: &str,
        subsystem: &str,
        interval_ms: u64,
        kind: &str,
        queue: &str,
    ) -> TimerGuard {
        let timer = json!({"id":id,"label":label,"kind":kind,"subsystem":subsystem,"queue_label":queue,"interval_ms":interval_ms,"leeway_ms":null,"active":true});
        let generation = Uuid::new_v4();
        let mut timers = self.timers.lock().unwrap_or_else(|e| e.into_inner());
        timers.insert(
            id.into(),
            TimerRecord {
                generation,
                payload: timer.clone(),
            },
        );
        let mut event = StructuralEvent::new("timer_registered", subsystem);
        event.detail.insert("timer".into(), timer);
        self.spine.ingest_structural(event, None, None, None);
        TimerGuard {
            id: id.into(),
            generation,
            timers: self.timers.clone(),
            spine: self.spine.clone(),
        }
    }
}

pub fn timer_inventory(cx: &App) -> Value {
    let host = cx.global::<Observability>();
    let timers = host
        .timers
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .values()
        .map(|timer| timer.payload.clone())
        .collect::<Vec<_>>();
    json!({"timers":timers,"latest_seq":host.journal.latest_seq(),"coverage":"registered Chau7 Next tasks"})
}

pub fn repo_events(envelopes: &[EventEnvelope], args: &serde_json::Map<String, Value>) -> Value {
    let repo = args
        .get("repo_path")
        .and_then(Value::as_str)
        .unwrap_or_default();
    let normalize = |path: &str| {
        std::path::Path::new(path)
            .components()
            .collect::<std::path::PathBuf>()
    };
    let expected = normalize(repo);
    let limit = args
        .get("limit")
        .and_then(Value::as_u64)
        .unwrap_or(20)
        .clamp(1, 50) as usize;
    let truncate = args
        .get("truncate_messages")
        .and_then(Value::as_bool)
        .unwrap_or(true);
    let filter = |key: &str, actual: Option<&str>| {
        args.get(key)
            .and_then(Value::as_str)
            .is_none_or(|value| actual.is_some_and(|actual| actual.eq_ignore_ascii_case(value)))
    };
    let events = envelopes.iter().filter_map(|envelope| envelope.ai_event().map(|event| (envelope, event))).filter(|(envelope, event)| {
        let matches_repo = event.repo_path.as_deref().is_some_and(|path|normalize(path)==expected);
        let tab = envelope.public_tab_id.or(event.tab_id).map(|id| id.to_string());
        matches_repo && filter("tab_id",tab.as_deref()) && filter("tool",Some(&event.tool)) && filter("producer",event.producer.as_deref()) && filter("session_id",event.session_id.as_deref()) && args.get("event_types").and_then(Value::as_array).is_none_or(|types|types.iter().any(|kind|kind.as_str()==Some(&event.event_type)))
    }).map(|(envelope, event)| {
        let message = if truncate {event.message.chars().take(200).collect::<String>()} else {event.message.clone()};
        let mut value = json!({"id":event.id,"source":event.source.0,"type":event.event_type,"tool":event.tool,"message":message,"ts":event.ts,"reliability":event.reliability});
        let object = value.as_object_mut().unwrap();
        for (key,value) in [("directory",event.directory.clone()),("tab_id",envelope.public_tab_id.or(event.tab_id).map(|id| id.to_string())),("session_id",event.session_id.clone()),("producer",event.producer.clone())] { if let Some(value)=value {object.insert(key.into(),json!(value));} }
        value
    }).collect::<Vec<_>>();
    let events = events
        .into_iter()
        .rev()
        .take(limit)
        .collect::<Vec<_>>()
        .into_iter()
        .rev()
        .collect::<Vec<_>>();
    json!({"repo_path":repo,"count":events.len(),"events":events})
}

/// Runtime evidence fields match Swift's observability projection, with exclusive cursor replay separately available.
pub fn runtime_events(since: i64, limit: usize, cx: &App) -> Value {
    let Some(host) = cx.try_global::<Observability>() else {
        return json!({"events":[],"latest_seq":0});
    };
    let limit = limit.clamp(1, 500);
    let events = host
        .events
        .iter()
        .filter(|e| e.occurred_at.timestamp_millis() >= since)
        .map(runtime_projection)
        .collect::<Vec<_>>();
    json!({"events":events.into_iter().rev().take(limit).collect::<Vec<_>>().into_iter().rev().collect::<Vec<_>>(), "latest_seq":host.journal.latest_seq()})
}
pub fn runtime_projection(envelope: &EventEnvelope) -> Value {
    let (kind, subsystem, tab, session, run, repo, detail) = match &envelope.payload {
        EventPayload::Ai(event) => (
            "ai_event",
            event.source.0.as_str(),
            envelope
                .public_tab_id
                .or(event.tab_id)
                .map(|id| id.to_string()),
            event.session_id.clone(),
            None,
            event.repo_path.clone(),
            json!({"type":event.event_type,"tool":event.tool,"message":event.message,"delivery_requested":envelope.delivery_requested}),
        ),
        EventPayload::Structural(event) => (
            event.event_type.as_str(),
            event.subsystem.as_str(),
            event.tab_id.clone(),
            event.session_id.clone(),
            event.run_id.clone(),
            event.repo_path.clone(),
            json!(event.detail),
        ),
    };
    let mut value = json!({"seq":envelope.seq,"id":envelope.event_id,"timestamp_millis":envelope.occurred_at.timestamp_millis(),"type":kind,"subsystem":subsystem,"detail":detail});
    let object = value.as_object_mut().unwrap();
    for (key, id) in [
        ("tab_id", tab),
        ("session_id", session),
        ("run_id", run),
        ("repo_path", repo),
    ] {
        if let Some(id) = id {
            object.insert(key.into(), json!(id));
        }
    }
    value
}
/// Finish admission and let the quit future drain the durable worker off the main thread.
pub fn shutdown(cx: &mut App) -> Option<JoinHandle<()>> {
    let host = cx.try_global::<Observability>()?;
    host.journal.spine.finish();
    cx.global_mut::<Observability>().worker.take()
}

#[cfg(test)]
mod tests {
    use super::*;
    fn timer_registry() -> TimerRegistry {
        TimerRegistry {
            timers: Arc::default(),
            spine: Arc::new(EventSpine::new(128, 0)),
        }
    }
    #[test]
    fn dropping_replaced_timer_does_not_deactivate_or_emit_for_its_new_owner() {
        let registry = timer_registry();
        let first = registry.register("same", "first", "test", 100, "test", "test");
        let second = registry.register("same", "second", "test", 200, "test", "test");
        let sequence = registry.spine.latest_cursor();
        drop(first);
        {
            let timers = registry.timers.lock().unwrap();
            assert_eq!(timers["same"].payload["label"], "second");
            assert_eq!(timers["same"].payload["interval_ms"], 200);
            assert_eq!(timers["same"].payload["active"], true);
            assert!(timers["same"].payload.get("generation").is_none());
        }
        assert_eq!(registry.spine.latest_cursor(), sequence);
        drop(second);
        assert_eq!(
            registry.timers.lock().unwrap()["same"].payload["active"],
            false
        );
        assert_eq!(registry.spine.latest_cursor(), sequence + 1);
    }
    #[test]
    fn concurrent_timer_replacements_only_publish_current_owner_cancellation() {
        let registry = timer_registry();
        let barrier = Arc::new(std::sync::Barrier::new(8));
        let workers: Vec<_> = (0..8)
            .map(|i| {
                let registry = registry.clone();
                let barrier = barrier.clone();
                std::thread::spawn(move || {
                    let guard = registry.register(
                        "shared",
                        &format!("owner-{i}"),
                        "test",
                        i + 1,
                        "test",
                        "test",
                    );
                    barrier.wait();
                    drop(guard);
                })
            })
            .collect();
        for worker in workers {
            worker.join().unwrap();
        }
        assert_eq!(
            registry.timers.lock().unwrap()["shared"].payload["active"],
            false
        );
        let events = registry.spine.replay(0, 128).envelopes;
        assert_eq!(events.len(), 9);
        assert!(
            events[..8]
                .iter()
                .all(|event| event.structural_event().unwrap().event_type == "timer_registered")
        );
        assert_eq!(
            events[8].structural_event().unwrap().event_type,
            "timer_updated"
        );
        assert_eq!(
            events[8].structural_event().unwrap().detail["active"],
            false
        );
    }

    #[test]
    fn repo_query_uses_admitted_stable_identity_filters_and_unicode_limit() {
        let spine = EventSpine::new(16, 0);
        let tab = uuid::Uuid::new_v4();
        let mut ai = AiEvent::new(
            chau7_next_core::ai::event::AiEventSource::codex(),
            "finished",
            "Codex",
            "é".repeat(250),
            "2026-10-11T10:00:00Z",
        );
        ai.repo_path = Some("/repo/".into());
        ai.tab_id = Some(tab);
        ai.session_id = Some("session-1".into());
        let public = uuid::Uuid::new_v4();
        spine.ingest_ai_attributed(ai, None, true, Some(public));
        let events = spine.replay(0, 16).envelopes;
        let args =
            json!({"repo_path":"/repo","tab_id":public,"tool":"codex","event_types":["finished"]});
        let value = repo_events(&events, args.as_object().unwrap());
        assert_eq!(value["count"], 1);
        assert_eq!(value["events"][0]["tab_id"], public.to_string());
        assert_eq!(runtime_projection(&events[0])["tab_id"], public.to_string());
        assert_eq!(events[0].ai_event().unwrap().tab_id, Some(tab));
        assert_eq!(
            value["events"][0]["message"]
                .as_str()
                .unwrap()
                .chars()
                .count(),
            200
        );
        let args = json!({"repo_path":"/other"});
        assert_eq!(repo_events(&events, args.as_object().unwrap())["count"], 0);
        let args = json!({"repo_path":"/repo","session_id":"other"});
        assert_eq!(repo_events(&events, args.as_object().unwrap())["count"], 0);
    }

    #[test]
    fn runtime_projection_preserves_identity_and_optional_attribution() {
        let spine = EventSpine::new(8, 9);
        let mut event = StructuralEvent::new("tab_opened", "tabs");
        event.tab_id = Some("tab-1".into());
        event.repo_path = Some("/repo".into());
        event.detail.insert("reason".into(), json!("test"));
        let envelope = spine.ingest_structural(event, None, None, None);
        let value = runtime_projection(&envelope);
        assert_eq!(value["seq"], 10);
        assert_eq!(value["id"], envelope.event_id.to_string());
        assert_eq!(value["repo_path"], "/repo");
        assert!(value.get("session_id").is_none());
        assert_eq!(value["detail"]["reason"], "test");
    }
    #[test]
    fn reused_live_ids_do_not_relabel_events_from_a_prior_session() {
        let spine = EventSpine::new(8, 0);
        let live = crate::ai::events_out::tab_uuid(1);
        let prior = uuid::Uuid::new_v4();
        let current = uuid::Uuid::new_v4();
        for public in [prior, current] {
            let mut event = AiEvent::new(
                chau7_next_core::ai::event::AiEventSource::codex(),
                "finished",
                "Codex",
                public.to_string(),
                "2026-10-11T10:00:00Z",
            );
            event.tab_id = Some(live);
            event.repo_path = Some("/repo".into());
            spine.ingest_ai_attributed(event, None, false, Some(public));
        }
        let events = spine.replay(0, 8).envelopes;
        for public in [prior, current] {
            let args = json!({"repo_path":"/repo", "tab_id":public});
            let value = repo_events(&events, args.as_object().unwrap());
            assert_eq!(value["count"], 1);
            assert_eq!(value["events"][0]["message"], public.to_string());
        }
    }
    #[test]
    fn legacy_unattributed_records_keep_their_original_id() {
        let spine = EventSpine::new(8, 0);
        let live = crate::ai::events_out::tab_uuid(1);
        let mut event = AiEvent::new(
            chau7_next_core::ai::event::AiEventSource::codex(),
            "finished",
            "Codex",
            "legacy",
            "2026-10-11T10:00:00Z",
        );
        event.tab_id = Some(live);
        event.repo_path = Some("/repo".into());
        let envelope = spine.ingest_ai(event, None, false);
        let args = json!({"repo_path":"/repo"});
        let value = repo_events(&[envelope], args.as_object().unwrap());
        assert_eq!(value["events"][0]["tab_id"], live.to_string());
    }
}
