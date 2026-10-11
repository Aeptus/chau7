//! Port of `Monitoring/FileMonitor.swift`: watch one file or folder for
//! writes, deletes and renames and call back on each. After a delete or
//! rename (an atomic save replaces the file) the watch is set up again on
//! the path 0.2 s later, as Swift does.
//!
//! Swift uses a kqueue `DispatchSource`; this uses the `notify` crate
//! (FSEvents or kqueue on macOS, inotify on Linux).
//!
//! Snippets reload their files whenever the picker filters (SNP-012), so
//! nothing uses this yet; it is here for the features that follow a file.
#![allow(dead_code)]

use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use notify::{EventKind, RecommendedWatcher, RecursiveMode, Watcher};

type Callback = Arc<dyn Fn() + Send + Sync>;

/// Delay before watching the path again after a delete or rename.
const REARM_DELAY: Duration = Duration::from_millis(200);

pub struct FileMonitor {
    url: PathBuf,
    on_change: Callback,
    watcher: Arc<Mutex<Option<RecommendedWatcher>>>,
}

impl FileMonitor {
    pub fn new(url: impl Into<PathBuf>, on_change: impl Fn() + Send + Sync + 'static) -> Self {
        Self {
            url: url.into(),
            on_change: Arc::new(on_change),
            watcher: Arc::new(Mutex::new(None)),
        }
    }

    pub fn url(&self) -> &Path {
        &self.url
    }

    /// Starts watching; a missing path is not an error (nothing happens).
    pub fn start(&self) {
        start(&self.url, &self.on_change, &self.watcher);
    }

    /// Stops watching. Stopping twice, or before starting, is fine.
    pub fn stop(&self) {
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

fn start(url: &Path, on_change: &Callback, slot: &Arc<Mutex<Option<RecommendedWatcher>>>) {
    if let Ok(mut current) = slot.lock() {
        *current = None;
    }
    if !url.exists() {
        return;
    }
    let callback = on_change.clone();
    let rearm_url = url.to_path_buf();
    let rearm_slot = Arc::downgrade(slot);
    let rearm_callback = on_change.clone();
    let handler = move |result: notify::Result<notify::Event>| {
        let Ok(event) = result else {
            return;
        };
        let relevant = matches!(
            event.kind,
            EventKind::Modify(_) | EventKind::Remove(_) | EventKind::Create(_)
        );
        if !relevant {
            return;
        }
        callback();
        let replaced = matches!(
            event.kind,
            EventKind::Remove(_) | EventKind::Modify(notify::event::ModifyKind::Name(_))
        );
        if replaced {
            let url = rearm_url.clone();
            let slot = rearm_slot.clone();
            let callback = rearm_callback.clone();
            std::thread::spawn(move || {
                std::thread::sleep(REARM_DELAY);
                if let Some(slot) = slot.upgrade() {
                    start(&url, &callback, &slot);
                }
            });
        }
    };
    match notify::recommended_watcher(handler) {
        Ok(mut watcher) => {
            if let Err(err) = watcher.watch(url, RecursiveMode::NonRecursive) {
                log::debug!("FileMonitor: cannot watch {}: {err}", url.display());
                return;
            }
            if let Ok(mut current) = slot.lock() {
                *current = Some(watcher);
            }
        }
        Err(err) => log::debug!("FileMonitor: {err}"),
    }
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
}
