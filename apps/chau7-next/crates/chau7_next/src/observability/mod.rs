//! Ordered app-wide evidence. Disk writes run on one worker; projections run on GPUI.
use chau7_next_core::ai::event::AiEvent;
use chau7_next_core::events::{
    EventEnvelope, EventPayload, EventSpine, SpineJournalStore, StructuralEvent,
};
use futures::{StreamExt, channel::mpsc};
use gpui::{App, Global};
use serde_json::{Value, json};
use std::collections::VecDeque;
use std::sync::{Arc, Condvar, Mutex};
use std::thread::JoinHandle;
use std::time::Duration;

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
    timers: Arc<Mutex<std::collections::BTreeMap<String, Value>>>,
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
    host.journal.spine.ingest_ai(event, None, notify);
    true
}
pub fn record(event: StructuralEvent, cx: &App) {
    if let Some(host) = cx.try_global::<Observability>() {
        host.journal
            .spine
            .ingest_structural(event, None, None, None);
    }
}
/// A real scheduled task owns this guard; cancelling it updates the timer inventory.
pub struct TimerGuard {
    id: String,
    timers: Arc<Mutex<std::collections::BTreeMap<String, Value>>>,
    spine: Arc<EventSpine>,
}
impl Drop for TimerGuard {
    fn drop(&mut self) {
        if let Some(timer) = self
            .timers
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .get_mut(&self.id)
        {
            timer["active"] = json!(false);
        }
        let mut event = StructuralEvent::new("timer_updated", "observability");
        event.detail.insert("timer_id".into(), json!(self.id));
        event.detail.insert("active".into(), json!(false));
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
    let host = cx.global::<Observability>();
    let timer = json!({"id":id,"label":label,"kind":kind,"subsystem":subsystem,"queue_label":queue,"interval_ms":interval_ms,"leeway_ms":null,"active":true});
    host.timers
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .insert(id.to_string(), timer.clone());
    let mut event = StructuralEvent::new("timer_registered", subsystem);
    event.detail.insert("timer".into(), timer);
    host.journal
        .spine
        .ingest_structural(event, None, None, None);
    TimerGuard {
        id: id.into(),
        timers: host.timers.clone(),
        spine: host.journal.spine.clone(),
    }
}
pub fn timer_inventory(cx: &App) -> Value {
    let host = cx.global::<Observability>();
    let timers = host
        .timers
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .values()
        .cloned()
        .collect::<Vec<_>>();
    json!({"timers":timers,"latest_seq":host.journal.latest_seq(),"coverage":"registered Chau7 Next tasks"})
}

pub fn repo_events(
    envelopes: &[EventEnvelope],
    args: &serde_json::Map<String, Value>,
    aliases: &std::collections::HashMap<uuid::Uuid, String>,
) -> Value {
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
    let events = envelopes.iter().filter_map(|envelope| envelope.ai_event()).filter(|event| {
        let matches_repo = event.repo_path.as_deref().is_some_and(|path|normalize(path)==expected);
        let tab = event.tab_id.map(|id|aliases.get(&id).cloned().unwrap_or_else(||id.to_string()));
        matches_repo && filter("tab_id",tab.as_deref()) && filter("tool",Some(&event.tool)) && filter("producer",event.producer.as_deref()) && filter("session_id",event.session_id.as_deref()) && args.get("event_types").and_then(Value::as_array).is_none_or(|types|types.iter().any(|kind|kind.as_str()==Some(&event.event_type)))
    }).map(|event| {
        let message = if truncate {event.message.chars().take(200).collect::<String>()} else {event.message.clone()};
        let mut value = json!({"id":event.id,"source":event.source.0,"type":event.event_type,"tool":event.tool,"message":message,"ts":event.ts,"reliability":event.reliability});
        let object = value.as_object_mut().unwrap();
        for (key,value) in [("directory",event.directory.clone()),("tab_id",event.tab_id.map(|id|aliases.get(&id).cloned().unwrap_or_else(||id.to_string()))),("session_id",event.session_id.clone()),("producer",event.producer.clone())] { if let Some(value)=value {object.insert(key.into(),json!(value));} }
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
            event.tab_id.map(|id| id.to_string()),
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
    #[test]
    fn repo_query_uses_attributed_root_aliases_filters_and_unicode_limit() {
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
        spine.ingest_ai(ai, None, true);
        let events = spine.replay(0, 16).envelopes;
        let aliases = std::collections::HashMap::from([(tab, "public-tab".to_string())]);
        let args = json!({"repo_path":"/repo","tab_id":"public-tab","tool":"codex","event_types":["finished"]});
        let value = repo_events(&events, args.as_object().unwrap(), &aliases);
        assert_eq!(value["count"], 1);
        assert_eq!(value["events"][0]["tab_id"], "public-tab");
        assert_eq!(
            value["events"][0]["message"]
                .as_str()
                .unwrap()
                .chars()
                .count(),
            200
        );
        let args = json!({"repo_path":"/other"});
        assert_eq!(
            repo_events(&events, args.as_object().unwrap(), &aliases)["count"],
            0
        );
        let args = json!({"repo_path":"/repo","session_id":"other"});
        assert_eq!(
            repo_events(&events, args.as_object().unwrap(), &aliases)["count"],
            0
        );
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
}
