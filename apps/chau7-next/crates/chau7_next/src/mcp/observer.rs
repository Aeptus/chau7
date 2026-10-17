//! Owner-only current MCP state snapshots and serial per-connection subscriptions.
use super::{MainThread, approval, sources, windows};
use crate::observability::{Journal, TimerGuard, TimerRegistry};
use crate::platform::local_socket::Connection;
use chau7_next_core::events::{EventEnvelope, SUPPORTED_TOPICS};
use chau7_next_core::mcp::output::encode_sorted;
use serde_json::{Map, Value, json};
use std::collections::BTreeMap;
use std::sync::{
    Arc, Condvar, Mutex,
    atomic::{AtomicBool, Ordering},
};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

pub const NOTIFICATION_METHOD: &str = "notifications/chau7.event";
pub type Writer = Arc<Mutex<Box<dyn Connection>>>;
pub fn write_frame(writer: &Writer, value: &str) -> std::io::Result<()> {
    write_frame_with_timeout(writer, value, Duration::from_secs(5))
}
fn write_frame_with_timeout(
    writer: &Writer,
    value: &str,
    timeout: Duration,
) -> std::io::Result<()> {
    let mut writer = writer.lock().unwrap_or_else(|e| e.into_inner());
    let deadline = Instant::now() + timeout;
    let result = (|| {
        for mut remaining in [value.as_bytes(), b"\n".as_slice()] {
            while !remaining.is_empty() {
                let budget = deadline
                    .checked_duration_since(Instant::now())
                    .filter(|budget| !budget.is_zero())
                    .ok_or_else(|| {
                        std::io::Error::new(
                            std::io::ErrorKind::TimedOut,
                            "MCP frame write deadline exceeded",
                        )
                    })?;
                writer.set_write_timeout(Some(budget))?;
                match writer.write(remaining) {
                    Ok(0) => {
                        return Err(std::io::Error::new(
                            std::io::ErrorKind::WriteZero,
                            "MCP peer stopped reading",
                        ));
                    }
                    Ok(count) => remaining = &remaining[count..],
                    Err(error) if error.kind() == std::io::ErrorKind::Interrupted => continue,
                    Err(error) => return Err(error),
                }
            }
        }
        writer.flush()
    })();
    if result.is_err() {
        // Partial frames cannot be retried on this stream. Wake its reader and
        // release subscriptions/control rather than leaving a corrupt session.
        writer.shutdown();
    }
    result
}
pub fn contract() -> Value {
    json!({"version":1,"snapshot_tool":"chau7_state_snapshot","subscribe_tool":"chau7_subscribe",
        "unsubscribe_tool":"chau7_unsubscribe","notification_method":NOTIFICATION_METHOD,
        "heartbeat_event_type":"heartbeat","default_heartbeat_interval_ms":15000,
        "min_heartbeat_interval_ms":1000,"max_heartbeat_interval_ms":60000,
        "default_replay_limit":200,"max_replay_limit":500,"supported_topics":SUPPORTED_TOPICS,
        "delivery_mode":"serial"})
}
fn topics(args: &Map<String, Value>) -> Vec<String> {
    let mut topics: Vec<_> = args
        .get("topics")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(Value::as_str)
        .map(|s| s.trim().to_lowercase())
        .filter(|s| SUPPORTED_TOPICS.contains(&s.as_str()))
        .collect();
    topics.sort();
    topics.dedup();
    if topics.is_empty() {
        SUPPORTED_TOPICS.iter().map(|s| s.to_string()).collect()
    } else {
        topics
    }
}
fn change(envelope: &EventEnvelope) -> Value {
    let payload = crate::observability::runtime_projection(envelope);
    json!({"seq":envelope.seq,"timestamp_millis":envelope.occurred_at.timestamp_millis(),
        "topics":envelope.topics,"type":payload["type"],"subsystem":payload["subsystem"],"payload":payload})
}
fn snapshot_required(journal: &Journal) -> Value {
    json!({"error":"snapshot_required","observer_contract_version":1,
        "message":"Requested cursor is no longer available. Rehydrate from a fresh snapshot.",
        "latest_seq":journal.latest_seq(),"oldest_available_seq":journal.oldest_seq()})
}
fn stale(cursor: u64, oldest: u64) -> bool {
    oldest > 0 && cursor < oldest.saturating_sub(1)
}
fn repo_events(journal: &Journal) -> Vec<Value> {
    let mut groups: BTreeMap<String, Vec<Value>> = BTreeMap::new();
    let events = journal.replay(journal.oldest_seq().saturating_sub(1), 2000);
    for envelope in events.envelopes {
        if let Some(event) = envelope.ai_event()
            && let Some(repo) = &event.repo_path
        {
            groups
                .entry(repo.clone())
                .or_default()
                .push(json!({"id":event.id,
                "type":event.event_type,"tool":event.tool,"message":event.message,
                "timestamp":event.ts,"session_id":event.session_id,"producer":event.producer}));
        }
    }
    groups.into_iter().map(|(repo,events)|{
        let recent:Vec<_>=events.iter().rev().take(5).cloned().collect::<Vec<_>>().into_iter().rev().collect();
        json!({"repo_path":repo,"event_count":events.len(),"recent_events":recent,
            "last_event_at":events.last().and_then(|e|e.get("timestamp")),"retained_memory_only":true})
    }).collect()
}
fn active_telemetry() -> Value {
    let mut runs = sources::telemetry().active_runs();
    runs.sort_by(|a, b| {
        b.started_at
            .cmp(&a.started_at)
            .then_with(|| a.id.cmp(&b.id))
    });
    let mut grouped: BTreeMap<String, Vec<&chau7_next_core::telemetry::run::TelemetryRun>> =
        BTreeMap::new();
    for run in &runs {
        if let Some(id) = run.session_id.as_ref().filter(|id| !id.is_empty()) {
            grouped.entry(id.clone()).or_default().push(run);
        }
    }
    let sessions:Vec<_>=grouped.into_iter().map(|(id,runs)|{
        let latest=runs[0];
        let mut session=json!({"session_id":id,"provider":latest.provider,
            "active_run_count":runs.len(),"latest_run_id":latest.id,"last_active":latest.started_at.to_rfc3339()});
        if let Some(repo)=&latest.repo_path{session["repo_path"]=json!(repo);}
        session
    }).collect();
    json!({"active_runs":runs,"active_sessions":sessions})
}
pub fn state_snapshot(main: &MainThread, journal: Option<&Journal>) -> Value {
    let Some(journal) = journal else {
        return json!({"error":"Event spine unavailable","retryable":true});
    };
    // Cursor precedes all component reads. Mid-snapshot changes replay safely.
    let cursor = journal.latest_seq();
    let components = main.read(|cx| {
        let mut tabs = Vec::new();
        for window in windows::windows(cx) {
            let ws = window.workspace.read(cx);
            for uuid in ws.mcp_tab_uuids() {
                if let Some(tab) = ws.mcp_find(uuid) {
                    let mut summary = ws.mcp_readiness_summary(tab, cx);
                    summary.insert("window_id".into(), json!(window.id));
                    tabs.push(Value::Object(summary));
                }
            }
        }
        (
            tabs,
            approval::pending_summaries(),
            crate::observability::timer_inventory(cx),
        )
    });
    match components {
        Ok((tabs, approvals, timers)) => json!({"schema_version":1,"observer_contract_version":1,
            "generated_at_millis":chrono::Utc::now().timestamp_millis(),"latest_seq":cursor,
            "observer_contract":contract(),"runtime_info":crate::performance::runtime_info(),
            "tabs":tabs,"approvals":approvals,"repo_events":repo_events(journal),
            "telemetry":active_telemetry(),"timers":timers["timers"]}),
        Err(error) => error.payload(),
    }
}
#[derive(Debug)]
struct Health {
    next_delivery: u64,
    emitted: u64,
    dropped: u64,
    last_at: Option<i64>,
    created_at: i64,
    heartbeat_ms: u64,
    lag: &'static str,
}
impl Health {
    fn payload(&self, buffer_depth: u64) -> Value {
        json!({"delivery_mode":"serial","lag_state":self.lag,"buffer_depth":0,"pending_event_count":buffer_depth,
            "dropped_notification_count":self.dropped,"notifications_emitted_count":self.emitted,
            "last_notification_at_millis":self.last_at,"next_delivery_seq":self.next_delivery,
            "created_at_millis":self.created_at,"heartbeat_interval_ms":self.heartbeat_ms})
    }
    fn notification(&mut self, id: &str, mut params: Value, buffer_depth: u64) -> Value {
        let seq = self.next_delivery;
        self.next_delivery += 1;
        self.emitted += 1;
        self.last_at = Some(chrono::Utc::now().timestamp_millis());
        params["observer_contract_version"] = json!(1);
        params["subscription_id"] = json!(id);
        params["delivery_seq"] = json!(seq);
        params["subscription_health"] = self.payload(buffer_depth);
        json!({"jsonrpc":"2.0","method":NOTIFICATION_METHOD,"params":params})
    }
}
struct Subscription {
    id: String,
    alive: Arc<AtomicBool>,
    gate: Arc<(Mutex<bool>, Condvar)>,
    health: Arc<Mutex<Health>>,
    worker: Option<JoinHandle<()>>,
}
impl Subscription {
    fn stop(&mut self) {
        self.alive.store(false, Ordering::Release);
        self.gate.1.notify_all();
        if let Some(worker) = self.worker.take() {
            let _ = worker.join();
        }
    }
}
impl Drop for Subscription {
    fn drop(&mut self) {
        self.stop();
    }
}
pub struct Observer {
    main: MainThread,
    journal: Option<Journal>,
    timers: Option<TimerRegistry>,
    writer: Writer,
    owner: String,
    subscription: Option<Subscription>,
}
impl Observer {
    pub fn new(
        main: MainThread,
        journal: Option<Journal>,
        timers: Option<TimerRegistry>,
        writer: Writer,
        owner: String,
    ) -> Self {
        Self {
            main,
            journal,
            timers,
            writer,
            owner,
            subscription: None,
        }
    }
    pub fn arm(&self) {
        if let Some(subscription) = &self.subscription {
            *subscription
                .gate
                .0
                .lock()
                .unwrap_or_else(|e| e.into_inner()) = true;
            subscription.gate.1.notify_all();
        }
    }
    pub fn call(&mut self, name: &str, args: &Map<String, Value>) -> Option<String> {
        let value = match name {
            "chau7_state_snapshot" => state_snapshot(&self.main, self.journal.as_ref()),
            "chau7_subscribe" => self.subscribe(args),
            "chau7_unsubscribe" => self.unsubscribe(args),
            _ => return None,
        };
        Some(encode_sorted(&value))
    }
    pub fn validate_unsubscription(
        &self,
        args: &Map<String, Value>,
    ) -> Result<(), chau7_next_core::mcp::handshake::ProtocolError> {
        if let Some(requested) = args.get("subscription_id").and_then(Value::as_str)
            && let Some(current) = &self.subscription
            && requested != current.id
        {
            return Err(chau7_next_core::mcp::handshake::ProtocolError::new(
                -32602,
                format!("Unknown subscription_id: {requested}"),
            ));
        }
        Ok(())
    }
    fn unsubscribe(&mut self, args: &Map<String, Value>) -> Value {
        if let Some(requested) = args.get("subscription_id").and_then(Value::as_str)
            && let Some(current) = &self.subscription
            && requested != current.id
        {
            return json!({"error":"Unknown subscription_id","subscription_id":requested});
        }
        let previous = self.subscription.take();
        let health = previous.as_ref().map(|s| {
            s.health
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .payload(0)
        });
        let id = previous.as_ref().map(|s| s.id.clone());
        drop(previous);
        json!({"ok":true,"subscription_id":id,"observer_contract_version":1,"subscription_health":health})
    }
    fn subscribe(&mut self, args: &Map<String, Value>) -> Value {
        if !super::control::is_connected(&self.owner) {
            return json!({"error":"notifications_unavailable","observer_contract_version":1});
        }
        let Some(journal) = self.journal.clone() else {
            return json!({"error":"Event spine unavailable"});
        };
        let requested_cursor = args.get("cursor").and_then(Value::as_u64);
        let cursor = requested_cursor.unwrap_or_else(|| journal.latest_seq());
        if stale(cursor, journal.oldest_seq()) {
            return snapshot_required(&journal);
        }
        let topics = topics(args);
        let limit = args
            .get("replay_limit")
            .and_then(Value::as_i64)
            .unwrap_or(200)
            .clamp(1, 500) as usize;
        let heartbeat = args
            .get("heartbeat_interval_ms")
            .and_then(Value::as_i64)
            .unwrap_or(15000)
            .clamp(1000, 60000) as u64;
        let mut payload = state_snapshot(&self.main, Some(&journal));
        if payload.get("error").is_some() {
            return payload;
        }
        // Replay in order; any excess remains live backlog, never silently skipped.
        let batch = journal.replay(cursor, 2000);
        if stale(cursor, journal.oldest_seq()) {
            return snapshot_required(&journal);
        }
        let mut replay = Vec::new();
        let mut next = cursor;
        for envelope in &batch.envelopes {
            if envelope.topics.iter().any(|t| topics.contains(t)) {
                if replay.len() >= limit {
                    break;
                }
                replay.push(change(envelope));
            }
            next = envelope.seq;
        }
        // No native callback listener race: a single cursor continues the same
        // replay ring after the response; expiry is explicit snapshot_required.
        drop(self.subscription.take());
        let id = format!("sub_{}", uuid::Uuid::new_v4());
        let health = Arc::new(Mutex::new(Health {
            next_delivery: 1,
            emitted: 0,
            dropped: 0,
            last_at: None,
            created_at: chrono::Utc::now().timestamp_millis(),
            heartbeat_ms: heartbeat,
            lag: "healthy",
        }));
        let alive = Arc::new(AtomicBool::new(true));
        let gate = Arc::new((Mutex::new(false), Condvar::new()));
        let timer = self.timers.as_ref().map(|t| {
            t.register(
                &format!("mcp.subscription.{id}"),
                "MCP subscription heartbeat",
                "mcp",
                heartbeat,
                "thread_timer",
                &format!("chau7-next-mcp-observer-{id}"),
            )
        });
        let worker = Worker {
            main: self.main.clone(),
            owner: self.owner.clone(),
            journal,
            writer: self.writer.clone(),
            topics: topics.clone(),
            id: id.clone(),
            cursor: next,
            heartbeat: Duration::from_millis(heartbeat),
            alive: alive.clone(),
            gate: gate.clone(),
            health: health.clone(),
            timer,
        };
        let worker = match std::thread::Builder::new()
            .name(format!("chau7-next-mcp-observer-{id}"))
            .spawn(move || worker.run())
        {
            Ok(worker) => worker,
            Err(error) => {
                return json!({"error":format!("Subscription worker unavailable: {error}")});
            }
        };
        payload["subscription_id"] = json!(id);
        payload["topics"] = json!(topics);
        if !replay.is_empty() {
            payload["replay"] = json!(replay);
        }
        payload["subscription"] = json!({"subscription_id":id,"status":"active","observer_contract_version":1,
            "topics":topics,"cursor":requested_cursor,"replay_count":replay.len(),"replay_limit":limit,
            "health":health.lock().unwrap_or_else(|e|e.into_inner()).payload(0)});
        self.subscription = Some(Subscription {
            id,
            alive,
            gate,
            health,
            worker: Some(worker),
        });
        payload
    }
}
struct Worker {
    main: MainThread,
    owner: String,
    journal: Journal,
    writer: Writer,
    topics: Vec<String>,
    id: String,
    cursor: u64,
    heartbeat: Duration,
    alive: Arc<AtomicBool>,
    gate: Arc<(Mutex<bool>, Condvar)>,
    health: Arc<Mutex<Health>>,
    timer: Option<TimerGuard>,
}
impl Worker {
    fn emit(&self, value: Value) -> bool {
        let mut health = self.health.lock().unwrap_or_else(|e| e.into_inner());
        let notification = health.notification(
            &self.id,
            value,
            self.journal.latest_seq().saturating_sub(self.cursor),
        );
        if write_frame(&self.writer, &notification.to_string()).is_err() {
            health.emitted = health.emitted.saturating_sub(1);
            health.dropped += 1;
            health.lag = "disconnected";
            self.alive.store(false, Ordering::Release);
            super::control::disconnect(&self.owner, &self.main);
            self.writer
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .shutdown();
            return false;
        }
        true
    }
    fn run(mut self) {
        let _timer = self.timer.take();
        let mut gate = self.gate.0.lock().unwrap_or_else(|e| e.into_inner());
        while !*gate && self.alive.load(Ordering::Acquire) {
            gate = self
                .gate
                .1
                .wait_timeout(gate, Duration::from_millis(100))
                .unwrap_or_else(|e| e.into_inner())
                .0;
        }
        drop(gate);
        let mut heartbeat = Instant::now() + self.heartbeat;
        while self.alive.load(Ordering::Acquire) && super::control::is_connected(&self.owner) {
            if stale(self.cursor, self.journal.oldest_seq()) {
                self.health.lock().unwrap_or_else(|e| e.into_inner()).lag = "snapshot_required";
                self.emit(snapshot_required(&self.journal));
                break;
            }
            let batch = self.journal.replay(self.cursor, 500);
            for envelope in batch.envelopes {
                if !self.alive.load(Ordering::Acquire) {
                    return;
                }
                self.cursor = envelope.seq;
                if envelope.topics.iter().any(|t| self.topics.contains(t))
                    && !self.emit(change(&envelope))
                {
                    return;
                }
            }
            if Instant::now() >= heartbeat {
                if !self.emit(json!({"type":"heartbeat","topic":"subscription-control",
                    "timestamp_millis":chrono::Utc::now().timestamp_millis(),"latest_seq":self.journal.latest_seq()})){break;}
                heartbeat = Instant::now() + self.heartbeat;
            }
            if !batch.has_more {
                let guard = self.gate.0.lock().unwrap_or_else(|e| e.into_inner());
                let _ = self.gate.1.wait_timeout(guard, Duration::from_millis(100));
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn topic_normalization_and_replay_gap_are_explicit() {
        let args = json!({"topics":[" TAB-STATE ","unknown","tab-state"]});
        assert_eq!(topics(args.as_object().unwrap()), vec!["tab-state"]);
        assert_eq!(topics(&Map::new()), SUPPORTED_TOPICS);
        assert!(!stale(0, 0));
        assert!(!stale(9, 10));
        assert!(stale(8, 10));
    }
    #[test]
    fn notification_delivery_sequence_and_health_are_serial() {
        let mut health = Health {
            next_delivery: 1,
            emitted: 0,
            dropped: 0,
            last_at: None,
            created_at: 1,
            heartbeat_ms: 1000,
            lag: "healthy",
        };
        for expected in 1..=5 {
            let notification = health.notification("sub_1", json!({"type":"heartbeat"}), 0);
            assert_eq!(notification["method"], NOTIFICATION_METHOD);
            assert_eq!(notification["params"]["delivery_seq"], expected);
            assert_eq!(
                notification["params"]["subscription_health"]["notifications_emitted_count"],
                expected
            );
        }
        assert_eq!(health.next_delivery, 6);
        assert_eq!(health.dropped, 0);
    }
    #[cfg(unix)]
    #[test]
    fn concurrent_responses_and_notifications_never_interleave_frames() {
        use std::io::{BufRead, BufReader};
        let (writer, reader) = std::os::unix::net::UnixStream::pair().unwrap();
        let writer: Writer = Arc::new(Mutex::new(Box::new(writer)));
        let reader = std::thread::spawn(move || {
            BufReader::new(reader)
                .lines()
                .take(200)
                .map(|line| serde_json::from_str::<Value>(&line.unwrap()).unwrap())
                .collect::<Vec<_>>()
        });
        std::thread::scope(|scope| {
            for source in 0..4 {
                let writer = writer.clone();
                scope.spawn(move || {
                    for sequence in 0..50 {
                        write_frame(
                            &writer,
                            &json!({"source":source,"seq":sequence}).to_string(),
                        )
                        .unwrap();
                    }
                });
            }
        });
        assert_eq!(reader.join().unwrap().len(), 200);
    }
    struct SlowConnection {
        delay: Duration,
        zero: bool,
        stopped: Arc<AtomicBool>,
    }
    impl std::io::Read for SlowConnection {
        fn read(&mut self, _: &mut [u8]) -> std::io::Result<usize> {
            Ok(0)
        }
    }
    impl std::io::Write for SlowConnection {
        fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
            std::thread::sleep(self.delay);
            Ok(if self.zero { 0 } else { bytes.len().min(1) })
        }
        fn flush(&mut self) -> std::io::Result<()> {
            Ok(())
        }
    }
    impl Connection for SlowConnection {
        fn try_clone_box(&self) -> std::io::Result<Box<dyn Connection>> {
            Err(std::io::Error::other("test connection has no clone"))
        }
        fn shutdown(&self) {
            self.stopped.store(true, Ordering::Release);
        }
        fn set_write_timeout(&self, _: Option<Duration>) -> std::io::Result<()> {
            Ok(())
        }
    }
    #[test]
    fn slow_dribbling_writes_share_one_total_frame_deadline() {
        let stopped = Arc::new(AtomicBool::new(false));
        let writer: Writer = Arc::new(Mutex::new(Box::new(SlowConnection {
            delay: Duration::from_millis(5),
            zero: false,
            stopped: stopped.clone(),
        })));
        let started = Instant::now();
        let error = write_frame_with_timeout(&writer, &"x".repeat(200), Duration::from_millis(40))
            .unwrap_err();
        assert_eq!(error.kind(), std::io::ErrorKind::TimedOut);
        assert!(started.elapsed() < Duration::from_secs(1));
        assert!(stopped.load(Ordering::Acquire));
    }
    #[test]
    fn zero_write_closes_a_partial_frame_connection() {
        let stopped = Arc::new(AtomicBool::new(false));
        let writer: Writer = Arc::new(Mutex::new(Box::new(SlowConnection {
            delay: Duration::ZERO,
            zero: true,
            stopped: stopped.clone(),
        })));
        let error = write_frame_with_timeout(&writer, "frame", Duration::from_secs(1)).unwrap_err();
        assert_eq!(error.kind(), std::io::ErrorKind::WriteZero);
        assert!(stopped.load(Ordering::Acquire));
    }
}
