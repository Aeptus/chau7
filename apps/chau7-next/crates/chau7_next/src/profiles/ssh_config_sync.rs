//! App-wide SSH-config cache. Native watches, bounded reads and parsing run
//! on one serial worker; Settings rendering only copies this snapshot.
use crate::{mcp::MainThread, monitoring::file_monitor::FileMonitor, workspace::AppData};
use chau7_next_core::ssh_config::{self, SSHConfigEntry};
use gpui::{App, Global};
use std::{
    fs::File,
    io::Read,
    path::{Path, PathBuf},
    sync::{
        Arc, Condvar, Mutex,
        atomic::{AtomicBool, Ordering},
    },
    thread::JoinHandle,
    time::{Duration, Instant},
};

const READ_LIMIT: u64 = 1024 * 1024;
const ENTRY_LIMIT: usize = 4096;
const COALESCE: Duration = Duration::from_millis(100);

#[derive(Clone, Debug, Default)]
pub struct Snapshot {
    /// None until the producer has actually attempted watch registration.
    pub watching: Option<bool>,
    pub entries: Arc<Vec<SSHConfigEntry>>,
    /// Last successful read/parse, in Unix seconds, never file existence.
    pub last_sync: Option<i64>,
    /// Local conversion occurs on the producer, never during UI rendering.
    pub last_sync_local: Option<chrono::NaiveDateTime>,
    pub error: Option<String>,
}
impl Snapshot {
    fn apply(
        &mut self,
        result: Result<Vec<SSHConfigEntry>, String>,
        watching: bool,
        now: i64,
        local: Option<chrono::NaiveDateTime>,
    ) {
        self.watching = Some(watching);
        match result {
            Ok(entries) => {
                self.entries = Arc::new(entries);
                self.last_sync = Some(now);
                self.last_sync_local = local;
                self.error = None;
            }
            // Match Swift: failed reads leave the previous entries/time intact.
            Err(error) => self.error = Some(error),
        }
    }
}
#[derive(Default)]
struct Requests {
    refresh: bool,
    stopping: bool,
}
#[derive(Default)]
struct Wake {
    pending: Mutex<Requests>,
    changed: Condvar,
}
impl Wake {
    fn request(&self) {
        let mut state = self.pending.lock().unwrap_or_else(|e| e.into_inner());
        if !state.stopping {
            state.refresh = true;
            self.changed.notify_one();
        }
    }
    fn stop(&self) {
        let mut state = self.pending.lock().unwrap_or_else(|e| e.into_inner());
        state.stopping = true;
        state.refresh = false;
        self.changed.notify_all();
    }
    fn next(&self) -> bool {
        let mut state = self.pending.lock().unwrap_or_else(|e| e.into_inner());
        while !state.refresh && !state.stopping {
            state = self.changed.wait(state).unwrap_or_else(|e| e.into_inner());
        }
        // A fixed window coalesces bursts without starving refreshes under
        // continuous events, and lets the watch rearm state settle off UI.
        let deadline = Instant::now() + COALESCE;
        while !state.stopping && Instant::now() < deadline {
            let remaining = deadline.saturating_duration_since(Instant::now());
            state = self
                .changed
                .wait_timeout(state, remaining)
                .unwrap_or_else(|e| e.into_inner())
                .0;
        }
        if state.stopping {
            return false;
        }
        state.refresh = false;
        true
    }
}
pub struct SshConfigSync {
    snapshot: Arc<Mutex<Snapshot>>,
    wake: Arc<Wake>,
    // Dropping the handle detaches; monitor cancellation/cleanup stays on its
    // worker rather than doing disk/native-watcher teardown from a UI Drop.
    worker: Option<JoinHandle<()>>,
}
impl Global for SshConfigSync {}
impl SshConfigSync {
    fn new(path: PathBuf, publish: impl Fn() + Send + 'static) -> Self {
        let snapshot = Arc::new(Mutex::new(Snapshot::default()));
        let wake = Arc::new(Wake::default());
        let worker_snapshot = snapshot.clone();
        let worker_wake = wake.clone();
        let events = wake.clone();
        let worker = std::thread::Builder::new()
            .name("chau7-next-ssh-config".into())
            .spawn(move || {
                let monitor = FileMonitor::new(&path, move || events.request());
                monitor.start();
                worker_wake.request();
                while worker_wake.next() {
                    let result = read_config(&path);
                    let watching = monitor.is_watching_target();
                    let now = chrono::Utc::now().timestamp();
                    // Resolve timezone information before taking the UI cache
                    // lock; an OS timezone lookup may consult filesystem data.
                    let local = result
                        .as_ref()
                        .ok()
                        .and_then(|_| chrono::DateTime::from_timestamp(now, 0))
                        .map(|date| date.with_timezone(&chrono::Local).naive_local());
                    if worker_wake
                        .pending
                        .lock()
                        .unwrap_or_else(|e| e.into_inner())
                        .stopping
                    {
                        break;
                    }
                    worker_snapshot
                        .lock()
                        .unwrap_or_else(|e| e.into_inner())
                        .apply(result, watching, now, local);
                    publish();
                }
                // FileMonitor Drop fences delayed recovery and native events here.
                worker_snapshot
                    .lock()
                    .unwrap_or_else(|e| e.into_inner())
                    .watching = Some(false);
            })
            .ok();
        if worker.is_none() {
            let mut cached = snapshot.lock().unwrap_or_else(|e| e.into_inner());
            cached.watching = Some(false);
            cached.error = Some("SSH config worker could not start.".into());
        }
        Self {
            snapshot,
            wake,
            worker,
        }
    }
    fn snapshot(&self) -> Snapshot {
        self.snapshot
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .clone()
    }
}
impl Drop for SshConfigSync {
    fn drop(&mut self) {
        self.wake.stop();
        self.worker.take();
    }
}
fn read_config(path: &Path) -> Result<Vec<SSHConfigEntry>, String> {
    let metadata =
        std::fs::metadata(path).map_err(|_| "SSH config could not be read.".to_string())?;
    if !metadata.is_file() {
        return Err("SSH config is not a regular file.".into());
    }
    let file = File::open(path).map_err(|_| "SSH config could not be read.".to_string())?;
    let mut bytes = Vec::new();
    file.take(READ_LIMIT + 1)
        .read_to_end(&mut bytes)
        .map_err(|_| "SSH config could not be read.".to_string())?;
    if bytes.len() as u64 > READ_LIMIT {
        return Err(
            "SSH config exceeds the 1 MiB preview limit; previous entries retained.".into(),
        );
    }
    let text =
        std::str::from_utf8(&bytes).map_err(|_| "SSH config is not valid UTF-8.".to_string())?;
    let entries = ssh_config::parse(text);
    if entries.len() > ENTRY_LIMIT {
        return Err(
            "SSH config exceeds the 4096-host preview limit; previous entries retained.".into(),
        );
    }
    Ok(entries)
}
pub fn start(cx: &mut App) {
    if cx.try_global::<SshConfigSync>().is_some() {
        return;
    }
    let path = cx.global::<AppData>().root.home().join(".ssh/config");
    let main = MainThread::start(cx);
    let notify_pending = Arc::new(AtomicBool::new(false));
    let service = SshConfigSync::new(path, move || {
        if !notify_pending.swap(true, Ordering::AcqRel) {
            let pending = notify_pending.clone();
            if !main.dispatch(move |cx| {
                pending.store(false, Ordering::Release);
                cx.refresh_windows();
            }) {
                notify_pending.store(false, Ordering::Release);
            }
        }
    });
    cx.set_global(service);
}
pub fn snapshot(cx: &App) -> Snapshot {
    cx.try_global::<SshConfigSync>()
        .map(SshConfigSync::snapshot)
        .unwrap_or_default()
}
pub fn refresh(cx: &App) {
    if let Some(service) = cx.try_global::<SshConfigSync>() {
        service.wake.request();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn owned() -> PathBuf {
        let path =
            std::env::temp_dir().join(format!("chau7-next-ssh-sync-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&path).unwrap();
        path
    }
    fn wait(service: &SshConfigSync, predicate: impl Fn(&Snapshot) -> bool) -> Snapshot {
        let deadline = Instant::now() + Duration::from_secs(6);
        loop {
            let snapshot = service.snapshot();
            if predicate(&snapshot) {
                return snapshot;
            }
            assert!(Instant::now() < deadline, "snapshot timeout: {snapshot:?}");
            std::thread::sleep(Duration::from_millis(10));
        }
    }
    fn close(mut service: SshConfigSync) {
        service.wake.stop();
        if let Some(worker) = service.worker.take() {
            worker.join().unwrap();
        }
    }
    #[test]
    fn successful_read_only_advances_sync_and_failures_retain_prior_entries() {
        let root = owned();
        let path = root.join("config");
        let mut cache = Snapshot::default();
        assert_eq!(cache.watching, None);
        assert_eq!(cache.last_sync, None);
        cache.apply(read_config(&path), false, 1, None);
        assert_eq!(cache.last_sync, None);
        std::fs::write(&path, "Host owned\n HostName synthetic.invalid\n").unwrap();
        cache.apply(read_config(&path), true, 2, None);
        assert_eq!(cache.last_sync, Some(2));
        assert_eq!(cache.entries.len(), 1);
        assert!(Arc::ptr_eq(&cache.entries, &cache.clone().entries));
        std::fs::write(&path, [0xff]).unwrap();
        cache.apply(read_config(&path), true, 3, None);
        assert_eq!(cache.last_sync, Some(2));
        assert_eq!(cache.entries.len(), 1);
        assert!(cache.error.is_some());
        std::fs::remove_file(&path).unwrap();
        cache.apply(read_config(&path), false, 4, None);
        assert_eq!(cache.last_sync, Some(2));
        assert_eq!(cache.watching, Some(false));
        assert_eq!(cache.entries.len(), 1);
        std::fs::write(&path, vec![b'a'; READ_LIMIT as usize + 1]).unwrap();
        assert!(read_config(&path).unwrap_err().contains("1 MiB"));
        let hosts = (0..=ENTRY_LIMIT)
            .map(|i| format!("Host owned{i}\n HostName synthetic.invalid\n"))
            .collect::<String>();
        std::fs::write(&path, hosts).unwrap();
        assert!(read_config(&path).unwrap_err().contains("4096-host"));
        std::fs::remove_dir_all(root).unwrap();
    }
    #[test]
    fn requests_coalesce_and_stop_fences_future_work() {
        let wake = Wake::default();
        for _ in 0..10_000 {
            wake.request();
        }
        assert!(wake.next());
        assert!(!wake.pending.lock().unwrap().refresh);
        wake.request();
        assert!(wake.pending.lock().unwrap().refresh);
        wake.stop();
        wake.request();
        assert!(!wake.next());
        assert!(!wake.pending.lock().unwrap().refresh);
    }
    #[test]
    fn existing_file_does_not_claim_native_watch_before_start_or_after_stop() {
        let root = owned();
        let path = root.join("config");
        std::fs::write(&path, "Host owned\n HostName synthetic.invalid\n").unwrap();
        let monitor = FileMonitor::new(&path, || {});
        assert!(!monitor.is_watching_target());
        monitor.start();
        assert!(monitor.is_watching_target());
        monitor.stop();
        assert!(!monitor.is_watching_target());
        drop(monitor);
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn real_shared_watch_creation_edit_and_stop_update_cached_state() {
        let root = owned();
        let path = root.join("config");
        let service = SshConfigSync::new(path.clone(), || {});
        wait(&service, |s| s.watching == Some(false) && s.error.is_some());
        std::fs::write(&path, "Host first\n HostName synthetic.invalid\n").unwrap();
        wait(&service, |s| {
            s.watching == Some(true) && s.entries.first().is_some_and(|e| e.host == "first")
        });
        std::fs::write(&path, "Host second\n HostName synthetic.invalid\n").unwrap();
        wait(&service, |s| {
            s.entries.first().is_some_and(|e| e.host == "second")
        });
        let snapshot = service.snapshot.clone();
        close(service);
        assert_eq!(snapshot.lock().unwrap().watching, Some(false));
        std::fs::remove_dir_all(root).unwrap();
    }
}
