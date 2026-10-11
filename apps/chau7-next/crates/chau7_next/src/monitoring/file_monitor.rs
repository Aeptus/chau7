//! Observe one file or directory, including atomic replacements and targets
//! that do not exist yet. Parent watches follow missing directory hierarchies
//! without permanent polling. A stopped monitor cannot be rearmed by queued
//! events or delayed recovery tasks.
#![allow(dead_code)]

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use notify::{EventKind, RecommendedWatcher, RecursiveMode, Watcher};

type Callback = Arc<dyn Fn() + Send + Sync>;
const REARM_DELAY: Duration = Duration::from_millis(200);

pub struct FileMonitor {
    url: PathBuf,
    on_change: Callback,
    watcher: Arc<Mutex<Option<RecommendedWatcher>>>,
    generation: Arc<AtomicU64>,
    arm_revision: Arc<AtomicU64>,
}

impl FileMonitor {
    pub fn new(url: impl Into<PathBuf>, on_change: impl Fn() + Send + Sync + 'static) -> Self {
        Self {
            url: url.into(),
            on_change: Arc::new(on_change),
            watcher: Arc::new(Mutex::new(None)),
            generation: Arc::new(AtomicU64::new(0)),
            arm_revision: Arc::new(AtomicU64::new(0)),
        }
    }

    pub fn url(&self) -> &Path {
        &self.url
    }

    pub fn start(&self) {
        let generation = self.generation.fetch_add(1, Ordering::SeqCst) + 1;
        if arm(
            &self.url,
            &self.on_change,
            &self.watcher,
            &self.generation,
            &self.arm_revision,
            generation,
        ) {
            self.arm_revision.fetch_add(1, Ordering::SeqCst);
        }
    }

    pub fn stop(&self) {
        self.generation.fetch_add(1, Ordering::SeqCst);
        if let Ok(mut slot) = self.watcher.lock() {
            *slot = None;
        }
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
    slot: &Arc<Mutex<Option<RecommendedWatcher>>>,
    epoch: &Arc<AtomicU64>,
    revision: &Arc<AtomicU64>,
    generation: u64,
) -> bool {
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
    let rearm_url = url.to_path_buf();
    let rearm_slot = Arc::downgrade(slot);
    let rearm_epoch = Arc::downgrade(epoch);
    let rearm_revision = Arc::downgrade(revision);
    let rearm_callback = on_change.clone();
    let pending = Arc::new(AtomicBool::new(false));
    let target_path = target.clone();
    let handler = move |result: notify::Result<notify::Event>| {
        let Some(epoch) = rearm_epoch.upgrade() else {
            return;
        };
        if epoch.load(Ordering::SeqCst) != generation {
            return;
        }
        let Ok(event) = result else { return };
        if !matches!(
            event.kind,
            EventKind::Any | EventKind::Modify(_) | EventKind::Remove(_) | EventKind::Create(_)
        ) {
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
        let replacement = matches!(
            event.kind,
            EventKind::Remove(_)
                | EventKind::Create(_)
                | EventKind::Modify(notify::event::ModifyKind::Name(_))
        );
        if (ancestor || replacement) && !pending.swap(true, Ordering::SeqCst) {
            let url = rearm_url.clone();
            let slot = rearm_slot.clone();
            let epoch = rearm_epoch.clone();
            let callback = rearm_callback.clone();
            let revision = rearm_revision.clone();
            let pending = pending.clone();
            std::thread::spawn(move || {
                std::thread::sleep(REARM_DELAY);
                if let (Some(slot), Some(epoch), Some(revision)) =
                    (slot.upgrade(), epoch.upgrade(), revision.upgrade())
                    && arm(&url, &callback, &slot, &epoch, &revision, generation)
                    && epoch.load(Ordering::SeqCst) == generation
                {
                    // Reload after recovery as well: writes during the rearm gap
                    // must be visible even when their native events were missed.
                    callback();
                    revision.fetch_add(1, Ordering::SeqCst);
                }
                pending.store(false, Ordering::SeqCst);
            });
        }
    };
    match notify::recommended_watcher(handler) {
        Ok(mut watcher) => {
            if let Err(error) = watcher.watch(&watched, RecursiveMode::NonRecursive) {
                log::debug!("FileMonitor: cannot watch {}: {error}", watched.display());
                return false;
            }
            if let Ok(mut current) = slot.lock()
                && epoch.load(Ordering::SeqCst) == generation
            {
                *current = Some(watcher);
                return true;
            }
        }
        Err(error) => log::debug!("FileMonitor: {error}"),
    }
    false
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};

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
