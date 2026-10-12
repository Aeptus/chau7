//! Bounded event-demand snapshots. Getters clone last successful data only;
//! SQLite/files run on background workers, coalesced per key, without a timer.
use std::collections::HashMap;
use std::hash::Hash;
use std::sync::{Arc, Condvar, Mutex, Weak};
use std::time::{Duration, Instant};

const MAX_KEYS: usize = 128;
const MAX_IN_FLIGHT: usize = 2;
const REFRESH: Duration = Duration::from_secs(5);
struct Entry<V> {
    value: Option<V>,
    success_at: Option<Instant>,
    attempted_at: Instant,
    refreshing: bool,
    error: bool,
    generation: u64,
}
struct Pending {
    stopped: bool,
    count: usize,
}
pub(super) struct Activity {
    pending: Mutex<Pending>,
    finished: Condvar,
    limit: usize,
}
impl Activity {
    pub(super) fn new(limit: usize) -> Arc<Self> {
        Arc::new(Self {
            pending: Mutex::new(Pending {
                stopped: false,
                count: 0,
            }),
            finished: Condvar::new(),
            limit,
        })
    }
    pub(super) fn stop(self: &Arc<Self>) -> Drain {
        self.pending
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .stopped = true;
        Drain(self.clone())
    }
    pub(super) fn begin(self: &Arc<Self>) -> Option<WorkGuard> {
        let mut pending = self.pending.lock().unwrap_or_else(|e| e.into_inner());
        if pending.stopped || pending.count >= self.limit {
            return None;
        }
        pending.count += 1;
        Some(WorkGuard(self.clone()))
    }
}
pub(super) struct WorkGuard(Arc<Activity>);
impl Drop for WorkGuard {
    fn drop(&mut self) {
        let mut pending = self.0.pending.lock().unwrap_or_else(|e| e.into_inner());
        pending.count -= 1;
        self.0.finished.notify_all();
    }
}
#[derive(Clone)]
pub(super) struct Snapshot<V> {
    pub value: Option<V>,
    pub pending: bool,
    pub error: bool,
}
pub(super) struct Cache<K, V> {
    entries: Mutex<HashMap<K, Entry<V>>>,
    work: Arc<Activity>,
}
impl<K: Eq + Hash + Clone, V: Clone> Cache<K, V> {
    pub(super) fn new() -> Self {
        Self {
            entries: Mutex::new(HashMap::new()),
            work: Activity::new(MAX_IN_FLIGHT),
        }
    }
    /// No I/O: bounded capture with short locks, weak/fenced apply.
    pub(super) fn begin(self: &Arc<Self>, key: K) -> (Snapshot<V>, Option<Ticket<K, V>>) {
        let now = Instant::now();
        let mut entries = self.entries.lock().unwrap_or_else(|e| e.into_inner());
        if !entries.contains_key(&key) && entries.len() >= MAX_KEYS {
            let oldest = entries
                .iter()
                .filter(|(_, v)| !v.refreshing)
                .min_by_key(|(_, v)| v.attempted_at)
                .map(|(k, _)| k.clone());
            if let Some(oldest) = oldest {
                entries.remove(&oldest);
            } else {
                return (
                    Snapshot {
                        value: None,
                        pending: false,
                        error: true,
                    },
                    None,
                );
            }
        }
        let entry = entries.entry(key.clone()).or_insert(Entry {
            value: None,
            success_at: None,
            attempted_at: now - REFRESH,
            refreshing: false,
            error: false,
            generation: 0,
        });
        let ticket = if !entry.refreshing && now.duration_since(entry.attempted_at) >= REFRESH {
            self.work.begin().map(|guard| {
                entry.refreshing = true;
                entry.attempted_at = now;
                entry.generation = entry.generation.wrapping_add(1);
                Ticket {
                    cache: Arc::downgrade(self),
                    key,
                    generation: entry.generation,
                    _guard: guard,
                }
            })
        } else {
            None
        };
        (
            Snapshot {
                value: entry.value.clone(),
                pending: entry.refreshing,
                error: entry.error,
            },
            ticket,
        )
    }
    /// Stop demand admission synchronously; await producer completion off UI.
    pub(super) fn stop(&self) -> Drain {
        self.work.stop()
    }
}
pub(super) struct Ticket<K: Eq + Hash, V> {
    cache: Weak<Cache<K, V>>,
    key: K,
    generation: u64,
    _guard: WorkGuard,
}
impl<K: Eq + Hash, V> Drop for Ticket<K, V> {
    fn drop(&mut self) {
        if let Some(cache) = self.cache.upgrade() {
            let mut entries = cache.entries.lock().unwrap_or_else(|e| e.into_inner());
            if let Some(entry) = entries
                .get_mut(&self.key)
                .filter(|e| e.generation == self.generation && e.refreshing)
            {
                entry.refreshing = false;
                entry.error = true;
            }
        }
    }
}
impl<K: Eq + Hash, V> Ticket<K, V> {
    pub(super) fn apply(self, result: Result<V, ()>) {
        let Some(cache) = self.cache.upgrade() else {
            return;
        };
        if cache
            .work
            .pending
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .stopped
        {
            return;
        }
        let mut entries = cache.entries.lock().unwrap_or_else(|e| e.into_inner());
        let Some(entry) = entries
            .get_mut(&self.key)
            .filter(|e| e.generation == self.generation)
        else {
            return;
        };
        entry.refreshing = false;
        match result {
            Ok(value) => {
                entry.value = Some(value);
                entry.success_at = Some(Instant::now());
                entry.error = false;
            }
            Err(()) => {
                entry.error = true;
            }
        }
    }
}
pub(super) struct Drain(Arc<Activity>);
impl Drain {
    pub(super) fn finish(self) {
        let mut pending = self.0.pending.lock().unwrap_or_else(|e| e.into_inner());
        while pending.count > 0 {
            pending = self
                .0
                .finished
                .wait(pending)
                .unwrap_or_else(|e| e.into_inner());
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use chau7_next_core::telemetry::{run::TelemetryRun, store::TelemetryStore};
    #[test]
    fn real_sql_snapshot_coalesces_preserves_last_success_on_error_and_stops() {
        let directory =
            std::env::temp_dir().join(format!("next-telemetry-cache-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&directory).unwrap();
        let store = Arc::new(TelemetryStore::open(&directory.join("owned.db")));
        store.insert_run(&TelemetryRun::new("owned-fake", "/synthetic"));
        let cache = Arc::new(Cache::new());
        let (first, ticket) = cache.begin("count");
        assert!(first.value.is_none());
        assert!(first.pending);
        assert!(cache.begin("count").1.is_none());
        let reader = store.clone();
        std::thread::spawn(move || {
            ticket.unwrap().apply(Ok(reader.run_count()));
        })
        .join()
        .unwrap();
        assert_eq!(cache.begin("count").0.value, Some(1));
        let success_at = cache
            .entries
            .lock()
            .unwrap()
            .get("count")
            .unwrap()
            .success_at;
        cache
            .entries
            .lock()
            .unwrap()
            .get_mut("count")
            .unwrap()
            .attempted_at -= REFRESH;
        let (_, ticket) = cache.begin("count");
        let reader = store.clone();
        std::thread::spawn(move || {
            reader.execute_raw("DROP TABLE runs");
            let failures = reader.failure_count();
            let value = reader.run_count();
            assert!(reader.failure_count() > failures);
            ticket.unwrap().apply(Err(()));
            assert_eq!(value, 0);
        })
        .join()
        .unwrap();
        let snapshot = cache.begin("count").0;
        assert_eq!(snapshot.value, Some(1));
        assert!(snapshot.error);
        assert!(!snapshot.pending);
        assert_eq!(
            cache
                .entries
                .lock()
                .unwrap()
                .get("count")
                .unwrap()
                .success_at,
            success_at
        );
        cache.stop().finish();
        assert!(cache.begin("other").1.is_none());
        drop(store);
        drop(cache);
        std::fs::remove_dir_all(directory).unwrap();
    }
    #[test]
    fn canceled_read_releases_slot_and_bounds_keys_and_workers() {
        let cache = Arc::new(Cache::<usize, usize>::new());
        let (_, first) = cache.begin(1);
        let (_, second) = cache.begin(2);
        assert!(cache.begin(3).1.is_none());
        drop(first);
        assert!(cache.begin(1).0.error);
        assert!(!cache.begin(1).0.pending);
        let (_, third) = cache.begin(3);
        assert!(third.is_some());
        drop(second);
        drop(third);
        for key in 4..MAX_KEYS * 2 {
            drop(cache.begin(key).1);
        }
        assert_eq!(cache.entries.lock().unwrap().len(), MAX_KEYS);
        cache.stop().finish();
    }
    #[test]
    fn stop_is_nonblocking_but_completion_waits_for_actual_reader() {
        let cache = Arc::new(Cache::<usize, usize>::new());
        let (_, ticket) = cache.begin(1);
        let stopped = cache.stop();
        assert!(cache.begin(2).1.is_none());
        let (tx, rx) = std::sync::mpsc::channel();
        let worker = std::thread::spawn(move || {
            stopped.finish();
            tx.send(()).unwrap();
        });
        assert!(rx.try_recv().is_err());
        drop(ticket);
        rx.recv().unwrap();
        worker.join().unwrap();
        assert!(cache.begin(1).0.value.is_none());
    }
}
