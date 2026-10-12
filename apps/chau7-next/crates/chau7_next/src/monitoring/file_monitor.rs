//! Observe one file or directory, including atomic replacements and targets
//! that do not exist yet. Parent watches follow missing directory hierarchies
//! without permanent polling. A stopped monitor cannot be rearmed by queued
//! events or delayed recovery tasks.
#![allow(dead_code)]

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use std::time::{Duration, Instant};

use super::watch_registry::{self, Change, Flags, Subscription};

type Callback = Arc<dyn Fn() + Send + Sync>;
const REARM_DELAY: Duration = Duration::from_millis(200);

pub struct FileMonitor {
    url: PathBuf,
    on_change: Callback,
    watcher: Arc<Mutex<Option<Subscription>>>,
    generation: Arc<AtomicU64>,
    arm_revision: Arc<AtomicU64>,
    recovery: Arc<Recovery>,
}

impl FileMonitor {
    pub fn new(url: impl Into<PathBuf>, on_change: impl Fn() + Send + Sync + 'static) -> Self {
        Self {
            url: url.into(),
            on_change: Arc::new(on_change),
            watcher: Arc::new(Mutex::new(None)),
            generation: Arc::new(AtomicU64::new(0)),
            arm_revision: Arc::new(AtomicU64::new(0)),
            recovery: Arc::new(Recovery::default()),
        }
    }

    pub fn url(&self) -> &Path {
        &self.url
    }

    pub fn start(&self) {
        let generation = self.generation.fetch_add(1, Ordering::SeqCst) + 1;
        self.recovery.ready.store(false, Ordering::SeqCst);
        if arm(
            &self.url,
            &self.on_change,
            &self.watcher,
            &self.generation,
            &self.arm_revision,
            &self.recovery,
            generation,
        ) {
            self.arm_revision.fetch_add(1, Ordering::SeqCst);
        }
        request_recovery(
            RecoveryContext {
                url: self.url.clone(),
                callback: self.on_change.clone(),
                slot: Arc::downgrade(&self.watcher),
                epoch: Arc::downgrade(&self.generation),
                revision: Arc::downgrade(&self.arm_revision),
                recovery: Arc::downgrade(&self.recovery),
                generation,
            },
            true,
        );
    }

    pub fn stop(&self) {
        self.generation.fetch_add(1, Ordering::SeqCst);
        if let Ok(mut slot) = self.watcher.lock() {
            *slot = None;
        }
        self.recovery.ready.store(false, Ordering::SeqCst);
        let _window = self
            .recovery
            .window
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        self.recovery.wake.notify_all();
    }
}

impl Drop for FileMonitor {
    fn drop(&mut self) {
        self.stop();
    }
}

/// Resolve existing ancestors too, so a missing target under a symlinked
/// directory matches the canonical paths emitted by native watchers.
fn canonical_target(url: &Path) -> Option<PathBuf> {
    let absolute = if url.is_absolute() {
        url.to_path_buf()
    } else {
        std::env::current_dir().ok()?.join(url)
    };
    let mut existing = absolute.as_path();
    let mut suffix = Vec::new();
    loop {
        if let Ok(mut canonical) = existing.canonicalize() {
            for component in suffix.iter().rev() {
                canonical.push(component);
            }
            return Some(canonical);
        }
        suffix.push(existing.file_name()?.to_os_string());
        existing = existing.parent()?;
    }
}

fn arm(
    url: &Path,
    on_change: &Callback,
    slot: &Arc<Mutex<Option<Subscription>>>,
    epoch: &Arc<AtomicU64>,
    revision: &Arc<AtomicU64>,
    recovery: &Arc<Recovery>,
    generation: u64,
) -> bool {
    let _attempt = recovery.attempts.lock().unwrap_or_else(|e| e.into_inner());
    if epoch.load(Ordering::SeqCst) != generation {
        return false;
    }
    let Some(target) = canonical_target(url) else {
        return false;
    };
    let is_directory = target.is_dir();
    // On macOS use notify's kqueue backend, matching Swift's vnode source.
    // Watch an existing target directly; a missing target waits on the
    // nearest existing parent and advances as its hierarchy is created.
    let mut watched = target.clone();
    while !watched.exists() {
        let Some(parent) = watched.parent() else {
            return false;
        };
        watched = parent.to_path_buf();
    }
    let callback = on_change.clone();
    let context = RecoveryContext {
        url: url.to_path_buf(),
        callback: on_change.clone(),
        slot: Arc::downgrade(slot),
        epoch: Arc::downgrade(epoch),
        revision: Arc::downgrade(revision),
        recovery: Arc::downgrade(recovery),
        generation,
    };
    let parent_mode = Arc::new(AtomicBool::new(watched != target));
    let handler_parent_mode = parent_mode.clone();
    let pending = Arc::new(AtomicBool::new(false));
    let target_path = target.clone();
    let handler: Arc<dyn Fn(Change) + Send + Sync> = Arc::new(move |event: Change| {
        let Some(recovery) = context.recovery.upgrade() else {
            return;
        };
        let parent = handler_parent_mode.load(Ordering::SeqCst);
        if !context.current() || (parent && recovery.ready.load(Ordering::SeqCst)) {
            return;
        }
        let relevant = event.paths.iter().any(|path| {
            path == &target_path || (is_directory && path.parent() == Some(target_path.as_path()))
        });
        let ancestor = event
            .paths
            .iter()
            .any(|path| target_path.starts_with(path) && path != &target_path);
        if !relevant && !ancestor {
            return;
        }
        if relevant {
            callback();
        }
        let replacement = event
            .flags
            .intersects(Flags::DELETE.union(Flags::CREATE).union(Flags::RENAME));
        if (ancestor || replacement || parent) && !pending.swap(true, Ordering::SeqCst) {
            recovery.ready.store(false, Ordering::SeqCst);
            let context = context.clone();
            let pending = pending.clone();
            std::thread::spawn(move || {
                std::thread::sleep(REARM_DELAY);
                context.arm();
                request_recovery(context, replacement);
                pending.store(false, Ordering::SeqCst);
            });
        }
    });
    let first = subscribe_target(&watched, handler.clone());
    let (watcher, target_ready) = match first {
        Ok(watcher) => (Some(watcher), watched == target),
        Err(error) => {
            log::debug!("FileMonitor target subscription failed: {error}");
            // Keep an existing parent observable when opening a real target
            // fails, including permission and transient native watcher errors.
            parent_mode.store(true, Ordering::SeqCst);
            let mut parent = watched.parent();
            while let Some(candidate) = parent {
                if candidate.exists() {
                    break;
                }
                parent = candidate.parent();
            }
            (
                parent.and_then(|parent| subscribe_target(parent, handler).ok()),
                false,
            )
        }
    };
    if let Some(watcher) = watcher
        && let Ok(mut current) = slot.lock()
        && epoch.load(Ordering::SeqCst) == generation
    {
        *current = Some(watcher);
        recovery.ready.store(target_ready, Ordering::SeqCst);
        return true;
    }
    recovery.ready.store(false, Ordering::SeqCst);
    false
}

const RECOVERY_WINDOW: Duration = Duration::from_secs(60);

fn recovery_delay(attempt: u32, elapsed: Duration) -> Option<Duration> {
    (elapsed < RECOVERY_WINDOW).then(|| {
        REARM_DELAY
            .saturating_mul(1u32 << attempt.min(30))
            .min(Duration::from_secs(5))
    })
}

struct RecoveryWindow {
    generation: u64,
    started: Instant,
    active: bool,
}
struct Recovery {
    ready: AtomicBool,
    attempts: Mutex<()>,
    window: Mutex<RecoveryWindow>,
    wake: Condvar,
}
impl Default for Recovery {
    fn default() -> Self {
        Self {
            ready: AtomicBool::new(false),
            attempts: Mutex::new(()),
            window: Mutex::new(RecoveryWindow {
                generation: 0,
                started: Instant::now(),
                active: false,
            }),
            wake: Condvar::new(),
        }
    }
}

#[derive(Clone)]
struct RecoveryContext {
    url: PathBuf,
    callback: Callback,
    slot: std::sync::Weak<Mutex<Option<Subscription>>>,
    epoch: std::sync::Weak<AtomicU64>,
    revision: std::sync::Weak<AtomicU64>,
    recovery: std::sync::Weak<Recovery>,
    generation: u64,
}
impl RecoveryContext {
    fn current(&self) -> bool {
        self.epoch
            .upgrade()
            .is_some_and(|epoch| epoch.load(Ordering::SeqCst) == self.generation)
    }

    fn arm(&self) {
        if let (Some(slot), Some(epoch), Some(revision), Some(recovery)) = (
            self.slot.upgrade(),
            self.epoch.upgrade(),
            self.revision.upgrade(),
            self.recovery.upgrade(),
        ) && arm(
            &self.url,
            &self.callback,
            &slot,
            &epoch,
            &revision,
            &recovery,
            self.generation,
        ) && self.current()
        {
            // Catch output written between the failed watch and handoff.
            if recovery.ready.load(Ordering::SeqCst) {
                (self.callback)();
            }
            revision.fetch_add(1, Ordering::SeqCst);
        }
    }
}

fn request_recovery(context: RecoveryContext, reset: bool) {
    let Some(recovery) = context.recovery.upgrade() else {
        return;
    };
    if !context.current() {
        return;
    }
    let mut window = recovery.window.lock().unwrap_or_else(|e| e.into_inner());
    if window.generation != context.generation {
        window.active = false;
    }
    if reset || window.generation != context.generation {
        window.started = Instant::now();
        window.generation = context.generation;
    }
    if recovery.ready.load(Ordering::SeqCst) || window.active {
        recovery.wake.notify_all();
        return;
    }
    if recovery_delay(0, window.started.elapsed()).is_none() {
        return;
    }
    window.active = true;
    drop(window);
    std::thread::spawn(move || {
        let mut attempt = 0;
        let mut window_started = None;
        loop {
            let Some(recovery) = context.recovery.upgrade() else {
                return;
            };
            let mut window = recovery.window.lock().unwrap_or_else(|e| e.into_inner());
            if window.generation != context.generation {
                return;
            }
            if !context.current() || recovery.ready.load(Ordering::SeqCst) {
                window.active = false;
                return;
            }
            if window_started != Some(window.started) {
                attempt = 0;
                window_started = Some(window.started);
            }
            let Some(delay) = recovery_delay(attempt, window.started.elapsed()) else {
                window.active = false;
                return;
            };
            let remaining = RECOVERY_WINDOW.saturating_sub(window.started.elapsed());
            let (mut window, timeout) = recovery
                .wake
                .wait_timeout(window, delay.min(remaining))
                .unwrap_or_else(|e| e.into_inner());
            if window.generation != context.generation {
                return;
            }
            if !context.current()
                || recovery.ready.load(Ordering::SeqCst)
                || window.started.elapsed() >= RECOVERY_WINDOW
            {
                window.active = false;
                return;
            }
            if !timeout.timed_out() {
                continue;
            }
            drop(window);
            context.arm();
            attempt = attempt.saturating_add(1);
        }
    });
}

fn subscribe_target(
    path: &Path,
    handler: Arc<dyn Fn(Change) + Send + Sync>,
) -> notify::Result<Subscription> {
    #[cfg(test)]
    {
        let mut faults = watch_faults().lock().unwrap();
        if let Some(remaining) = faults.get_mut(path)
            && *remaining > 0
        {
            *remaining -= 1;
            return Err(notify::Error::generic("isolated transient watch failure"));
        }
    }
    watch_registry::subscribe(path, Flags::ALL, move |event| handler(event))
}

#[cfg(test)]
fn watch_faults() -> &'static Mutex<std::collections::HashMap<PathBuf, usize>> {
    static FAULTS: std::sync::OnceLock<Mutex<std::collections::HashMap<PathBuf, usize>>> =
        std::sync::OnceLock::new();
    FAULTS.get_or_init(Mutex::default)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};

    #[test]
    fn recovery_backoff_and_expiry_match_current_swift() {
        for (attempt, millis) in [
            (0, 200),
            (1, 400),
            (2, 800),
            (3, 1600),
            (4, 3200),
            (5, 5000),
            (30, 5000),
            (u32::MAX, 5000),
        ] {
            assert_eq!(
                recovery_delay(attempt, Duration::ZERO),
                Some(Duration::from_millis(millis))
            );
        }
        assert_eq!(recovery_delay(0, Duration::from_secs(60)), None);
        assert_eq!(recovery_delay(0, Duration::from_secs(61)), None);
    }

    fn wait_until(mut predicate: impl FnMut() -> bool, message: &str) {
        let deadline = Instant::now() + Duration::from_secs(5);
        while !predicate() && Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(10));
        }
        assert!(predicate(), "{message}");
    }

    #[test]
    fn transient_target_failure_keeps_parent_and_recovers_without_new_events() {
        let dir = temp_dir("transient-target");
        let file = dir.join("file.txt");
        std::fs::write(&file, "initial").unwrap();
        watch_faults()
            .lock()
            .unwrap()
            .insert(file.canonicalize().unwrap(), 2);
        let count = Arc::new(AtomicUsize::new(0));
        let seen = count.clone();
        let monitor = FileMonitor::new(&file, move || {
            seen.fetch_add(1, Ordering::SeqCst);
        });
        monitor.start();
        assert!(
            monitor.watcher.lock().unwrap().is_some(),
            "native parent fallback must survive target failure"
        );
        assert!(!monitor.recovery.ready.load(Ordering::SeqCst));
        wait_until(
            || monitor.recovery.ready.load(Ordering::SeqCst),
            "bounded retries did not recover target",
        );
        wait_until(
            || !monitor.recovery.window.lock().unwrap().active,
            "recovered retry worker did not stop",
        );
        count.store(0, Ordering::SeqCst);
        std::fs::write(&file, "write after recovered native watch").unwrap();
        wait_for_change(&count);
        monitor.stop();
        watch_faults()
            .lock()
            .unwrap()
            .remove(&file.canonicalize().unwrap());
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn expired_retries_keep_parent_and_real_event_can_recover_then_stop() {
        let dir = temp_dir("expired-target");
        let file = dir.join("file.txt");
        std::fs::write(&file, "initial").unwrap();
        watch_faults()
            .lock()
            .unwrap()
            .insert(file.canonicalize().unwrap(), usize::MAX);
        let monitor = FileMonitor::new(&file, || {});
        monitor.start();
        {
            let mut window = monitor.recovery.window.lock().unwrap();
            window.started = Instant::now() - Duration::from_secs(61);
            monitor.recovery.wake.notify_all();
        }
        wait_until(
            || !monitor.recovery.window.lock().unwrap().active,
            "expired retry worker kept polling",
        );
        assert!(monitor.watcher.lock().unwrap().is_some());
        assert!(!monitor.recovery.ready.load(Ordering::SeqCst));
        watch_faults()
            .lock()
            .unwrap()
            .remove(&file.canonicalize().unwrap());
        // Creation changes the actual parent vnode even on kqueue platforms.
        std::fs::write(dir.join("wake-parent.txt"), "parent event").unwrap();
        std::fs::write(&file, "target event").unwrap();
        wait_until(
            || monitor.recovery.ready.load(Ordering::SeqCst),
            "parent event did not recover after retry expiry",
        );
        monitor.stop();
        assert!(monitor.watcher.lock().unwrap().is_none());
        std::thread::sleep(Duration::from_millis(300));
        assert!(monitor.watcher.lock().unwrap().is_none());
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn restarting_during_recovery_replaces_generation_without_stranding_worker() {
        let dir = temp_dir("restart-recovery");
        let file = dir.join("file.txt");
        std::fs::write(&file, "initial").unwrap();
        watch_faults()
            .lock()
            .unwrap()
            .insert(file.canonicalize().unwrap(), 3);
        let monitor = FileMonitor::new(&file, || {});
        monitor.start();
        monitor.stop();
        monitor.start();
        wait_until(
            || monitor.recovery.ready.load(Ordering::SeqCst),
            "new generation was stranded behind cancelled worker",
        );
        monitor.stop();
        wait_until(
            || !monitor.recovery.window.lock().unwrap().active,
            "cancelled worker did not terminate",
        );
        watch_faults()
            .lock()
            .unwrap()
            .remove(&file.canonicalize().unwrap());
        std::fs::remove_dir_all(dir).unwrap();
    }

    fn temp_dir(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "chau7-next-filemon-{name}-{}-{}",
            std::process::id(),
            uuid::Uuid::new_v4()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn start_stop_are_safe() {
        let dir = temp_dir("safe");
        let monitor = FileMonitor::new(dir.join("missing.txt"), || {});
        monitor.stop();
        monitor.start();
        monitor.stop();
        monitor.stop();
        assert_eq!(monitor.url(), dir.join("missing.txt"));
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn detects_writes() {
        let dir = temp_dir("write");
        let file = dir.join("file.txt");
        std::fs::write(&file, "initial").unwrap();
        let count = Arc::new(AtomicUsize::new(0));
        let seen = count.clone();
        let monitor = FileMonitor::new(&file, move || {
            seen.fetch_add(1, Ordering::SeqCst);
        });
        monitor.start();
        std::thread::sleep(Duration::from_millis(100));
        std::fs::write(&file, "modified content").unwrap();
        let deadline = std::time::Instant::now() + Duration::from_secs(5);
        while count.load(Ordering::SeqCst) == 0 && std::time::Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(20));
        }
        assert!(count.load(Ordering::SeqCst) > 0);
        monitor.stop();
        let _ = std::fs::remove_dir_all(dir);
    }
    fn wait_for_change(count: &AtomicUsize) {
        let deadline = std::time::Instant::now() + Duration::from_secs(5);
        while count.load(Ordering::SeqCst) == 0 && std::time::Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(20));
        }
        assert!(
            count.load(Ordering::SeqCst) > 0,
            "file observer did not deliver a change"
        );
    }

    fn wait_for_rearm(monitor: &FileMonitor) {
        let deadline = std::time::Instant::now() + Duration::from_secs(5);
        while monitor.arm_revision.load(Ordering::SeqCst) < 2
            && std::time::Instant::now() < deadline
        {
            std::thread::sleep(Duration::from_millis(20));
        }
        assert!(
            monitor.arm_revision.load(Ordering::SeqCst) >= 2,
            "file observer did not rearm"
        );
    }

    #[test]
    fn initially_missing_target_recovers_and_observes_later_writes() {
        let dir = temp_dir("missing");
        let file = dir.join("later.txt");
        let count = Arc::new(AtomicUsize::new(0));
        let seen = count.clone();
        let monitor = FileMonitor::new(&file, move || {
            seen.fetch_add(1, Ordering::SeqCst);
        });
        monitor.start();
        std::thread::sleep(Duration::from_millis(100));
        std::fs::write(&file, "created").unwrap();
        wait_for_change(&count);
        wait_for_rearm(&monitor);
        count.store(0, Ordering::SeqCst);
        std::fs::write(&file, "updated after recovery").unwrap();
        wait_for_change(&count);
        monitor.stop();
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn atomic_replacement_rearms_the_new_target() {
        let dir = temp_dir("atomic");
        let file = dir.join("file.txt");
        std::fs::write(&file, "original").unwrap();
        let count = Arc::new(AtomicUsize::new(0));
        let seen = count.clone();
        let monitor = FileMonitor::new(&file, move || {
            seen.fetch_add(1, Ordering::SeqCst);
        });
        monitor.start();
        let replacement = dir.join("replacement.txt");
        std::fs::write(&replacement, "replacement").unwrap();
        std::fs::rename(&replacement, &file).unwrap();
        wait_for_change(&count);
        wait_for_rearm(&monitor);
        count.store(0, Ordering::SeqCst);
        std::fs::write(&file, "new inode updated").unwrap();
        wait_for_change(&count);
        monitor.stop();
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn recovery_reloads_writes_that_happen_before_the_new_inode_is_watched() {
        let dir = temp_dir("rearm-gap");
        let file = dir.join("file.txt");
        std::fs::write(&file, "original").unwrap();
        let latest = Arc::new(Mutex::new(String::new()));
        let seen = latest.clone();
        let observed = file.clone();
        let monitor = FileMonitor::new(&file, move || {
            if let Ok(text) = std::fs::read_to_string(&observed) {
                *seen.lock().unwrap() = text;
            }
        });
        monitor.start();
        let replacement = dir.join("replacement.txt");
        std::fs::write(&replacement, "replacement").unwrap();
        std::fs::rename(replacement, &file).unwrap();
        std::fs::write(&file, "latest content during recovery").unwrap();
        wait_for_rearm(&monitor);
        assert_eq!(*latest.lock().unwrap(), "latest content during recovery");
        monitor.stop();
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn missing_nested_hierarchy_follows_existing_parent_events() {
        let dir = temp_dir("hierarchy");
        let file = dir.join("one/two/file.txt");
        let count = Arc::new(AtomicUsize::new(0));
        let seen = count.clone();
        let monitor = FileMonitor::new(&file, move || {
            seen.fetch_add(1, Ordering::SeqCst);
        });
        monitor.start();
        std::fs::create_dir_all(file.parent().unwrap()).unwrap();
        std::fs::write(&file, "created").unwrap();
        wait_for_rearm(&monitor);
        std::fs::write(&file, "written after hierarchy recovery").unwrap();
        wait_for_change(&count);
        monitor.stop();
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn stopped_monitor_cannot_be_resurrected_by_recovery() {
        let dir = temp_dir("stop-recovery");
        let file = dir.join("file.txt");
        std::fs::write(&file, "original").unwrap();
        let count = Arc::new(AtomicUsize::new(0));
        let seen = count.clone();
        let monitor = FileMonitor::new(&file, move || {
            seen.fetch_add(1, Ordering::SeqCst);
        });
        monitor.start();
        std::fs::remove_file(&file).unwrap();
        wait_for_change(&count);
        monitor.stop();
        let stopped_count = count.load(Ordering::SeqCst);
        std::fs::write(&file, "recreated after stop").unwrap();
        std::thread::sleep(REARM_DELAY * 3);
        std::fs::write(&file, "changed after stop").unwrap();
        std::thread::sleep(REARM_DELAY);
        assert_eq!(count.load(Ordering::SeqCst), stopped_count);
        assert!(monitor.watcher.lock().unwrap().is_none());
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn waiting_for_a_missing_file_ignores_sibling_changes() {
        let dir = temp_dir("siblings");
        let count = Arc::new(AtomicUsize::new(0));
        let seen = count.clone();
        let monitor = FileMonitor::new(dir.join("wanted.txt"), move || {
            seen.fetch_add(1, Ordering::SeqCst);
        });
        monitor.start();
        std::fs::write(dir.join("other.txt"), "unrelated").unwrap();
        std::thread::sleep(REARM_DELAY * 2);
        assert_eq!(count.load(Ordering::SeqCst), 0);
        monitor.stop();
        let _ = std::fs::remove_dir_all(dir);
    }
}
