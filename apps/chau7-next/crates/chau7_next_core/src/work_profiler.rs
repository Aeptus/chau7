//! Bounded measurements of actual render stages, terminal work and wakeups.
//! Static caller labels contain no terminal text. Durations are wall time;
//! native polling includes readiness wait, not a CPU usage measurement.
use std::collections::{HashMap, VecDeque};
use std::sync::{Mutex, OnceLock};
use std::time::{Instant, SystemTime, UNIX_EPOCH};

const MAX_KEYS: usize = 256;
const MAX_BUCKETS: usize = 120;
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Queue {
    Main,
    Background,
}
impl Queue {
    fn label(self) -> &'static str {
        match self {
            Self::Main => "main",
            Self::Background => "background",
        }
    }
}
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Kind {
    Work,
    Wakeup,
    Latency,
}
impl Kind {
    fn label(self) -> &'static str {
        match self {
            Self::Work => "work",
            Self::Wakeup => "wakeup",
            Self::Latency => "latency",
        }
    }
}
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct Key {
    pub kind: Kind,
    pub operation: &'static str,
    pub phase: &'static str,
    pub visibility: &'static str,
    pub caller: &'static str,
    pub queue: Queue,
}
impl Key {
    pub fn work(
        operation: &'static str,
        phase: &'static str,
        visibility: &'static str,
        caller: &'static str,
        queue: Queue,
    ) -> Self {
        Self {
            kind: Kind::Work,
            operation,
            phase,
            visibility,
            caller,
            queue,
        }
    }
    pub fn wakeup(source: &'static str, visibility: &'static str, queue: Queue) -> Self {
        Self {
            kind: Kind::Wakeup,
            operation: source,
            phase: "callback",
            visibility,
            caller: source,
            queue,
        }
    }
}
#[derive(Debug, Default, Clone, Copy, PartialEq)]
pub struct Aggregate {
    pub sample_count: u64,
    pub total_ms: f64,
    pub max_ms: f64,
    pub total_bytes: u64,
    pub total_items: u64,
    pub max_items: usize,
    pub idle_samples: u64,
    pub activity_unknown_samples: u64,
    pub idle_total_ms: f64,
}
impl Aggregate {
    fn add(&mut self, ms: f64, bytes: usize, items: usize, idle: Option<bool>) {
        self.sample_count = self.sample_count.saturating_add(1);
        self.total_ms = (self.total_ms + ms).min(f64::MAX);
        self.max_ms = self.max_ms.max(ms);
        self.total_bytes = self.total_bytes.saturating_add(bytes as u64);
        self.total_items = self.total_items.saturating_add(items as u64);
        self.max_items = self.max_items.max(items);
        if idle.is_none() {
            self.activity_unknown_samples = self.activity_unknown_samples.saturating_add(1);
        }
        if idle == Some(true) {
            self.idle_samples = self.idle_samples.saturating_add(1);
            self.idle_total_ms = (self.idle_total_ms + ms).min(f64::MAX);
        }
    }
    fn merge(&mut self, other: Self) {
        self.sample_count = self.sample_count.saturating_add(other.sample_count);
        self.total_ms = (self.total_ms + other.total_ms).min(f64::MAX);
        self.max_ms = self.max_ms.max(other.max_ms);
        self.total_bytes = self.total_bytes.saturating_add(other.total_bytes);
        self.total_items = self.total_items.saturating_add(other.total_items);
        self.max_items = self.max_items.max(other.max_items);
        self.idle_samples = self.idle_samples.saturating_add(other.idle_samples);
        self.activity_unknown_samples = self
            .activity_unknown_samples
            .saturating_add(other.activity_unknown_samples);
        self.idle_total_ms = (self.idle_total_ms + other.idle_total_ms).min(f64::MAX);
    }
    fn json(self) -> serde_json::Value {
        serde_json::json!({"sample_count":self.sample_count,"total_ms":self.total_ms,
            "average_ms": (self.sample_count > 0).then(||self.total_ms / self.sample_count as f64),
            "max_ms":self.max_ms,"total_bytes":self.total_bytes,"total_items":self.total_items,
            "max_items":self.max_items,"idle_samples":self.idle_samples,"idle_total_ms":self.idle_total_ms,
            "activity_unknown_samples":self.activity_unknown_samples,
            "activity_classified_samples":self.sample_count.saturating_sub(self.activity_unknown_samples)})
    }
}
#[derive(Default)]
struct Entry {
    lifetime: Aggregate,
    buckets: VecDeque<(i64, Aggregate)>,
}
#[derive(Default)]
pub struct Profiler {
    entries: HashMap<Key, Entry>,
    dropped_keys: u64,
}
impl Profiler {
    pub fn record_at(
        &mut self,
        key: Key,
        second: i64,
        ms: f64,
        bytes: usize,
        items: usize,
        idle: bool,
    ) {
        self.record_at_with_activity(key, second, ms, bytes, items, Some(idle));
    }
    pub fn record_at_with_activity(
        &mut self,
        key: Key,
        second: i64,
        ms: f64,
        bytes: usize,
        items: usize,
        idle: Option<bool>,
    ) {
        if !ms.is_finite() || ms < 0.0 {
            return;
        }
        if !self.entries.contains_key(&key) && self.entries.len() >= MAX_KEYS {
            self.dropped_keys = self.dropped_keys.saturating_add(1);
            return;
        }
        let entry = self.entries.entry(key).or_default();
        entry.lifetime.add(ms, bytes, items, idle);
        entry
            .buckets
            .retain(|(at, _)| *at > second.saturating_sub(MAX_BUCKETS as i64));
        if let Some((_, aggregate)) = entry.buckets.iter_mut().find(|(at, _)| *at == second) {
            aggregate.add(ms, bytes, items, idle);
        } else {
            entry.buckets.push_back((second, Aggregate::default()));
            entry
                .buckets
                .back_mut()
                .unwrap()
                .1
                .add(ms, bytes, items, idle);
            while entry.buckets.len() > MAX_BUCKETS {
                entry.buckets.pop_front();
            }
        }
    }
    pub fn snapshot_at(&self, now: i64) -> serde_json::Value {
        let mut entries = self.entries.iter().collect::<Vec<_>>();
        entries.sort_by_key(|(key, _)| {
            (
                key.kind.label(),
                key.operation,
                key.phase,
                key.visibility,
                key.caller,
                key.queue.label(),
            )
        });
        let entries = entries.into_iter().map(|(key,entry)| {
            let window = |seconds: i64| {
                let mut aggregate = Aggregate::default();
                for &(at, bucket) in &entry.buckets {
                    if at <= now && at > now.saturating_sub(seconds) { aggregate.merge(bucket); }
                }
                (aggregate.sample_count > 0).then(||aggregate.json())
            };
            serde_json::json!({"kind":key.kind.label(),"operation":key.operation,"phase":key.phase,
                "visibility":key.visibility,"caller":key.caller,"queue":key.queue.label(),
                "lifetime":entry.lifetime.json(),"last_10s":window(10),"last_60s":window(60)})
        }).collect::<Vec<_>>();
        serde_json::json!({"entries":entries,"dropped_new_keys":self.dropped_keys,"maximum_keys":MAX_KEYS,
            "maximum_second_buckets_per_key":MAX_BUCKETS,"duration_unit":"wall_ms", "overlapping_stages":true, "cpu_time_ms":serde_json::Value::Null,
            "gpu_completion_ms":serde_json::Value::Null,
            "gpu_completion_unavailable_reason":"GPUI does not expose a GPU completion callback to the application"})
    }
}
fn second() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
        .min(i64::MAX as u64) as i64
}
fn shared() -> &'static Mutex<Profiler> {
    static SHARED: OnceLock<Mutex<Profiler>> = OnceLock::new();
    SHARED.get_or_init(|| Mutex::new(Profiler::default()))
}
pub fn instrumentation_enabled(raw: Option<&str>) -> bool {
    !raw.is_some_and(|raw| {
        matches!(
            raw.trim().to_ascii_lowercase().as_str(),
            "0" | "false" | "no" | "off"
        )
    })
}
pub fn enabled() -> bool {
    static ENABLED: OnceLock<bool> = OnceLock::new();
    *ENABLED.get_or_init(|| {
        let raw = std::env::var("CHAU7_NEXT_WAKEUP_INSTRUMENTATION")
            .ok()
            .or_else(|| std::env::var("CHAU7_WAKEUP_INSTRUMENTATION").ok());
        instrumentation_enabled(raw.as_deref())
    })
}
pub fn record(key: Key, ms: f64, bytes: usize, items: usize, idle: bool) {
    record_with_activity(key, ms, bytes, items, Some(idle));
}
fn record_with_activity(key: Key, ms: f64, bytes: usize, items: usize, idle: Option<bool>) {
    if enabled()
        && let Ok(mut profiler) = shared().lock()
    {
        profiler.record_at_with_activity(key, second(), ms, bytes, items, idle);
    }
}
const MAX_ACTIVE_MAIN_SPANS: usize = 16;
#[derive(Default, Clone)]
struct ActiveMainWork {
    next: u64,
    spans: Vec<(u64, Key, Instant)>,
}
impl ActiveMainWork {
    fn enter(&mut self, key: Key, now: Instant) -> Option<u64> {
        if key.queue != Queue::Main
            || key.kind == Kind::Latency
            || self.spans.len() >= MAX_ACTIVE_MAIN_SPANS
        {
            return None;
        }
        self.next = self.next.wrapping_add(1);
        self.spans.push((self.next, key, now));
        Some(self.next)
    }
    fn leave(&mut self, id: u64) {
        self.spans.retain(|(current, _, _)| *current != id);
    }
    fn snapshot(&self, now: Instant) -> serde_json::Value {
        let entries: Vec<_> = self
            .spans
            .iter()
            .map(|(_, key, started)| {
                serde_json::json!({"operation":key.operation,"phase":key.phase,"caller":key.caller,
                "elapsed_ms":now.saturating_duration_since(*started).as_secs_f64()*1000.0})
            })
            .collect();
        serde_json::json!({"status":"captured","entries":entries,"maximum_entries":MAX_ACTIVE_MAIN_SPANS,
            "interpretation":"Open instrumented phases; elapsed wall time does not establish CPU usage or a blocking cause"})
    }
}
fn active_registry() -> &'static Mutex<ActiveMainWork> {
    static ACTIVE: OnceLock<Mutex<ActiveMainWork>> = OnceLock::new();
    ACTIVE.get_or_init(Default::default)
}
/// Safe from the watchdog thread while the main thread is unresponsive.
/// Never wait on a lock held by the thread being diagnosed.
pub fn active_main_work() -> serde_json::Value {
    let active = active_registry().try_lock().map(|active| active.clone());
    match active {
        Ok(active) => active.snapshot(Instant::now()),
        Err(_) => serde_json::json!({"status":"busy","entries":[]}),
    }
}

pub struct Span {
    key: Key,
    started: Option<Instant>,
    active_id: Option<u64>,
    bytes: usize,
    items: usize,
    idle: Option<bool>,
}
impl Span {
    pub fn bytes(&mut self, bytes: usize) {
        self.bytes = bytes;
    }
    pub fn items(&mut self, items: usize) {
        self.items = items;
    }
    pub fn idle(&mut self, idle: bool) {
        self.idle = Some(idle);
    }
}
impl Drop for Span {
    fn drop(&mut self) {
        if let Some(id) = self.active_id
            && let Ok(mut active) = active_registry().lock()
        {
            active.leave(id);
        }
        if let Some(started) = self.started {
            record_with_activity(
                self.key,
                started.elapsed().as_secs_f64() * 1000.0,
                self.bytes,
                self.items,
                self.idle,
            );
        }
    }
}
pub fn begin(key: Key) -> Span {
    let started = enabled().then(Instant::now);
    let active_id = started
        .filter(|_| key.queue == Queue::Main && key.kind != Kind::Latency)
        .and_then(|now| {
            active_registry()
                .lock()
                .ok()
                .and_then(|mut active| active.enter(key, now))
        });
    Span {
        key,
        started,
        active_id,
        bytes: 0,
        items: 0,
        idle: None,
    }
}

/// Measure an actual callback phase, excluding its timer and executor waits.
/// Static source labels bound cardinality and contain no user context. Activity
/// remains unknown unless the producer explicitly classifies its observed work.
pub fn timer_callback(source: &'static str, phase: &'static str, queue: Queue) -> Span {
    begin(Key {
        kind: Kind::Wakeup,
        operation: source,
        phase,
        visibility: "application",
        caller: source,
        queue,
    })
}
pub fn measure<T>(key: Key, body: impl FnOnce() -> T) -> T {
    let _span = begin(key);
    body()
}
pub fn snapshot() -> serde_json::Value {
    let mut value = shared()
        .lock()
        .map(|p| p.snapshot_at(second()))
        .unwrap_or(serde_json::Value::Null);
    if !value.is_null() {
        value["instrumentation_enabled"] = serde_json::json!(enabled());
        value["active_main_work"] = active_main_work();
    }
    value
}
#[cfg(test)]
mod tests {
    use super::*;
    fn key(queue: Queue) -> Key {
        Key::wakeup("pty_poll", "hidden", queue)
    }
    #[test]
    fn active_main_work_preserves_nested_phases_and_is_bounded() {
        let mut active = ActiveMainWork::default();
        let now = Instant::now();
        assert!(active.enter(key(Queue::Background), now).is_none());
        let outer = active.enter(key(Queue::Main), now).unwrap();
        let inner = active.enter(key(Queue::Main), now).unwrap();
        active.leave(outer);
        let snapshot = active.snapshot(now + std::time::Duration::from_millis(250));
        assert_eq!(snapshot["entries"].as_array().unwrap().len(), 1);
        assert_eq!(snapshot["entries"][0]["elapsed_ms"], 250.0);
        active.leave(inner);
        assert!(active.spans.is_empty());
        for _ in 0..MAX_ACTIVE_MAIN_SPANS {
            assert!(active.enter(key(Queue::Main), now).is_some());
        }
        assert!(active.enter(key(Queue::Main), now).is_none());
        assert_eq!(active.spans.len(), MAX_ACTIVE_MAIN_SPANS);
    }
    #[test]
    fn measured_idle_work_queue_and_windows_are_distinct() {
        let mut p = Profiler::default();
        p.record_at(key(Queue::Background), 100, 16.0, 0, 0, true);
        p.record_at(key(Queue::Background), 105, 2.0, 24, 3, false);
        p.record_at(key(Queue::Main), 105, 0.5, 24, 1, false);
        let value = p.snapshot_at(106);
        let background = value["entries"]
            .as_array()
            .unwrap()
            .iter()
            .find(|e| e["queue"] == "background")
            .unwrap();
        assert_eq!(background["last_10s"]["sample_count"], 2);
        assert_eq!(background["last_10s"]["idle_samples"], 1);
        assert_eq!(background["last_10s"]["idle_total_ms"], 16.0);
        assert_eq!(background["last_10s"]["total_bytes"], 24);
        assert_eq!(background["last_10s"]["max_items"], 3);
        assert_eq!(background["last_10s"]["average_ms"], 9.0);
        assert!(p.snapshot_at(200)["entries"][0]["last_60s"].is_null());
        assert!(value["gpu_completion_ms"].is_null());
    }
    #[test]
    fn invalid_durations_and_future_windows_are_not_fake_samples() {
        let mut p = Profiler::default();
        for ms in [-1.0, f64::NAN, f64::INFINITY] {
            p.record_at(key(Queue::Main), 10, ms, 0, 0, false);
        }
        assert!(p.snapshot_at(10)["entries"].as_array().unwrap().is_empty());
        p.record_at(key(Queue::Main), 50, 1.0, 0, 0, false);
        assert!(p.snapshot_at(10)["entries"][0]["last_60s"].is_null());
    }
    #[test]
    fn keys_and_per_second_buckets_are_bounded() {
        let mut p = Profiler::default();
        for second in 0..1000 {
            p.record_at(key(Queue::Main), second, 1.0, 0, 0, true);
        }
        assert_eq!(p.entries[&key(Queue::Main)].buckets.len(), MAX_BUCKETS);
        for index in 0..MAX_KEYS + 20 {
            let operation: &'static str = Box::leak(format!("synthetic_{index}").into_boxed_str());
            p.record_at(
                Key::work(operation, "test", "unknown", "test", Queue::Main),
                1000,
                1.0,
                0,
                0,
                false,
            );
        }
        assert_eq!(p.entries.len(), MAX_KEYS);
        assert_eq!(p.dropped_keys, 21);
    }
    #[test]
    fn unclassified_callbacks_are_not_reported_as_active_or_idle() {
        let mut profiler = Profiler::default();
        let key = key(Queue::Main);
        profiler.record_at_with_activity(key, 100, 2.0, 0, 0, None);
        profiler.record_at_with_activity(key, 100, 3.0, 0, 0, Some(true));
        profiler.record_at_with_activity(key, 101, 5.0, 0, 1, Some(false));
        let snapshot = profiler.snapshot_at(101);
        for field in ["lifetime", "last_10s", "last_60s"] {
            let aggregate = &snapshot["entries"][0][field];
            assert_eq!(aggregate["sample_count"], 3);
            assert_eq!(aggregate["activity_unknown_samples"], 1);
            assert_eq!(aggregate["activity_classified_samples"], 2);
            assert_eq!(aggregate["idle_samples"], 1);
            assert_eq!(aggregate["idle_total_ms"], 3.0);
            assert_eq!(aggregate["total_ms"], 10.0);
        }
    }
    #[test]
    fn callback_guard_preserves_queue_and_unknown_activity_until_observed() {
        let mut span = timer_callback("test.timer", "capture", Queue::Background);
        assert_eq!(span.key.kind, Kind::Wakeup);
        assert_eq!(span.key.operation, "test.timer");
        assert_eq!(span.key.caller, "test.timer");
        assert_eq!(span.key.phase, "capture");
        assert_eq!(span.key.queue, Queue::Background);
        assert_eq!(span.idle, None);
        span.idle(true);
        assert_eq!(span.idle, Some(true));
        span.idle(false);
        assert_eq!(span.idle, Some(false));
    }
    #[test]
    fn instrumentation_switch_matches_current_swift_values() {
        for raw in [None, Some(""), Some("yes"), Some(" ON "), Some("garbage")] {
            assert!(instrumentation_enabled(raw));
        }
        for raw in [Some("0"), Some(" false "), Some("NO"), Some("off")] {
            assert!(!instrumentation_enabled(raw));
        }
    }
}
