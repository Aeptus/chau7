//! Nonblocking bounded incident producer with worker-owned disk I/O.
use chau7_next_core::{
    data_root::DataRoot,
    incidents::{Breadcrumb, Kind, Policy, Severity, Store},
};
use chrono::Utc;
use std::{
    collections::BTreeMap,
    sync::{
        Arc, Mutex, OnceLock,
        atomic::{AtomicBool, AtomicU64, Ordering},
        mpsc::{self, SyncSender},
    },
    thread::JoinHandle,
};

const CAPACITY: usize = 128;
enum Observation {
    Record(Breadcrumb),
    Memory {
        severity: Severity,
        resident: u64,
        physical: u64,
        reclaimed: u64,
    },
    Proxy(u64),
    Restore(u64, BTreeMap<String, String>),
}
struct Service {
    sender: Mutex<Option<SyncSender<Observation>>>,
    worker: Mutex<Option<JoinHandle<()>>>,
    recent: Arc<Mutex<Vec<Breadcrumb>>>,
    dropped: AtomicU64,
    alive: Arc<AtomicBool>,
}
static SERVICE: OnceLock<Service> = OnceLock::new();
pub fn start(root: &DataRoot) {
    if SERVICE.get().is_some() {
        return;
    }
    let directory = root.incidents_dir();
    let recent = Arc::new(Mutex::new(Vec::new()));
    let cached = recent.clone();
    let alive = Arc::new(AtomicBool::new(false));
    let worker_alive = alive.clone();
    let (sender, receiver) = mpsc::sync_channel(CAPACITY);
    let worker = std::thread::Builder::new()
        .name("incident-evidence".into())
        .spawn(move || {
            let mut store = match Store::open(directory) {
                Ok(store) => store,
                Err(error) => {
                    log::warn!("Incident store unavailable: {error}");
                    return;
                }
            };
            if let Err(error) = store.recover_previous_critical(Utc::now()) {
                log::warn!("Previous incident recovery failed: {error}");
            }
            *cached.lock().unwrap_or_else(|e| e.into_inner()) = store.recent(100);
            worker_alive.store(true, Ordering::Release);
            let mut policy = Policy::default();
            while let Ok(observation) = receiver.recv() {
                let now = Utc::now();
                let record = match observation {
                    Observation::Record(record) => Some(record),
                    Observation::Memory {
                        severity,
                        resident,
                        physical,
                        reclaimed,
                    } => policy.memory(now, severity, resident, physical, reclaimed),
                    Observation::Proxy(bytes) => policy.proxy(now, bytes),
                    Observation::Restore(bytes, metadata) => policy.restore(now, bytes, metadata),
                };
                if let Some(record) = record {
                    if let Err(error) = store.append(record) {
                        log::warn!("Incident persistence failed: {error}");
                    }
                    *cached.lock().unwrap_or_else(|e| e.into_inner()) = store.recent(100);
                }
            }
            worker_alive.store(false, Ordering::Release);
        });
    match worker {
        Ok(worker) => {
            let _ = SERVICE.set(Service {
                sender: Mutex::new(Some(sender)),
                worker: Mutex::new(Some(worker)),
                recent,
                dropped: AtomicU64::new(0),
                alive,
            });
        }
        Err(error) => log::warn!("Incident worker unavailable: {error}"),
    }
}
fn enqueue(observation: Observation) {
    if let Some(service) = SERVICE.get() {
        let sender = service.sender.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(sender) = sender.as_ref()
            && sender.try_send(observation).is_err()
        {
            service.dropped.fetch_add(1, Ordering::Relaxed);
        }
    }
}
pub fn record(kind: Kind, severity: Severity, message: &str, metadata: BTreeMap<String, String>) {
    enqueue(Observation::Record(Breadcrumb::new(
        Utc::now(),
        kind,
        severity,
        message,
        metadata,
    )));
}
pub fn memory(severity: Severity, resident: u64, physical: u64, reclaimed: u64) {
    enqueue(Observation::Memory {
        severity,
        resident,
        physical,
        reclaimed,
    });
}
pub fn proxy_output(line: &str) {
    if let Some(bytes) = chau7_next_core::incidents::request_length(line)
        && bytes >= 512 * 1024
    {
        enqueue(Observation::Proxy(bytes));
    }
}
pub fn restore_payload(bytes: u64, metadata: BTreeMap<String, String>) {
    let metadata = Breadcrumb::new(
        Utc::now(),
        Kind::RestorePayload,
        Severity::Info,
        "",
        metadata,
    )
    .metadata;
    enqueue(Observation::Restore(bytes, metadata));
}
pub fn recent() -> Vec<Breadcrumb> {
    SERVICE
        .get()
        .map(|service| {
            service
                .recent
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .clone()
        })
        .unwrap_or_default()
}
pub fn diagnostics() -> serde_json::Value {
    serde_json::json!({"available":SERVICE.get().is_some_and(|s|s.alive.load(Ordering::Acquire)),"queue_capacity":CAPACITY,"dropped_observations":SERVICE.get().map(|s|s.dropped.load(Ordering::Relaxed)).unwrap_or(0),"max_log_bytes":chau7_next_core::incidents::MAX_LOG_BYTES,"max_entries":chau7_next_core::incidents::MAX_ENTRIES,"recent_incidents":recent()})
}
/// Called after diagnostic producers have joined, on the quit background worker.
pub fn shutdown() {
    if let Some(service) = SERVICE.get() {
        service
            .sender
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .take();
        if let Some(worker) = service
            .worker
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .take()
        {
            let _ = worker.join();
        }
    }
}
