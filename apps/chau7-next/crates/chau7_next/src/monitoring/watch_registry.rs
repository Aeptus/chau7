//! One native watch per canonical path, shared by logical subscriptions.
//! Callbacks run on a serial worker rather than the native watcher thread;
//! pending signals coalesce per subscriber and cancellation fences queued work.

use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Condvar, LazyLock, Mutex, Weak};
use std::thread::JoinHandle;

use notify::{EventKind, RecommendedWatcher, RecursiveMode, Watcher};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Flags(u8);
impl Flags {
    pub const WRITE: Self = Self(1);
    pub const DELETE: Self = Self(2);
    pub const RENAME: Self = Self(4);
    pub const CREATE: Self = Self(8);
    pub const ALL: Self = Self(15);
    pub fn intersects(self, other: Self) -> bool {
        self.0 & other.0 != 0
    }
    pub fn union(self, other: Self) -> Self {
        Self(self.0 | other.0)
    }
    fn intersection(self, other: Self) -> Self {
        Self(self.0 & other.0)
    }
}
#[derive(Clone, Debug)]
pub struct Change {
    pub flags: Flags,
    pub paths: BTreeSet<PathBuf>,
}
type Callback = Arc<dyn Fn(Change) + Send + Sync>;
#[derive(Clone)]
struct Subscriber {
    mask: Flags,
    callback: Callback,
    cancelled: Arc<AtomicBool>,
}
struct Pending {
    change: Change,
    subscriber: Subscriber,
}
#[derive(Default)]
struct Queue {
    pending: BTreeMap<u64, Pending>,
    stopping: bool,
}
#[derive(Default)]
struct Dispatcher {
    queue: Mutex<Queue>,
    wake: Condvar,
}
impl Dispatcher {
    fn enqueue(&self, id: u64, subscriber: &Subscriber, change: &Change) {
        let mut queue = self.queue.lock().unwrap_or_else(|e| e.into_inner());
        if queue.stopping || subscriber.cancelled.load(Ordering::Acquire) {
            return;
        }
        let flags = change.flags.intersection(subscriber.mask);
        if !flags.intersects(Flags::ALL) {
            return;
        }
        let pending = queue.pending.entry(id).or_insert_with(|| Pending {
            change: Change {
                flags,
                paths: BTreeSet::new(),
            },
            subscriber: subscriber.clone(),
        });
        pending.change.flags = pending.change.flags.union(flags);
        for path in &change.paths {
            if pending.change.paths.len() < 64 {
                pending.change.paths.insert(path.clone());
            }
        }
        self.wake.notify_one();
    }
    fn run(&self) {
        loop {
            let work = {
                let mut queue = self.queue.lock().unwrap_or_else(|e| e.into_inner());
                while queue.pending.is_empty() && !queue.stopping {
                    queue = self.wake.wait(queue).unwrap_or_else(|e| e.into_inner());
                }
                if queue.stopping {
                    return;
                }
                std::mem::take(&mut queue.pending)
            };
            for (_, pending) in work {
                if !pending.subscriber.cancelled.load(Ordering::Acquire) {
                    // A failed subscriber must not stop delivery to other files.
                    let _ = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                        (pending.subscriber.callback)(pending.change)
                    }));
                }
            }
        }
    }
}
#[derive(Clone, PartialEq, Eq)]
struct Identity {
    #[cfg(unix)]
    dev: u64,
    #[cfg(unix)]
    inode: u64,
    created: Option<std::time::SystemTime>,
    directory: bool,
}
fn identity(path: &Path) -> Option<Identity> {
    let metadata = std::fs::metadata(path).ok()?;
    #[cfg(unix)]
    use std::os::unix::fs::MetadataExt;
    Some(Identity {
        #[cfg(unix)]
        dev: metadata.dev(),
        #[cfg(unix)]
        inode: metadata.ino(),
        created: metadata.created().ok(),
        directory: metadata.is_dir(),
    })
}
struct Entry {
    _watcher: RecommendedWatcher,
    identity: Option<Identity>,
    generation: u64,
    subscribers: BTreeMap<u64, Subscriber>,
}
struct Registry {
    operations: Mutex<()>,
    entries: Mutex<HashMap<PathBuf, Entry>>,
    next: AtomicU64,
    dispatch: Arc<Dispatcher>,
    worker: Mutex<Option<JoinHandle<()>>>,
}
static SHARED: LazyLock<Mutex<Weak<Registry>>> = LazyLock::new(|| Mutex::new(Weak::new()));
impl Registry {
    fn new() -> Arc<Self> {
        let dispatch = Arc::new(Dispatcher::default());
        let worker_dispatch = dispatch.clone();
        let worker = std::thread::Builder::new()
            .name("chau7-next-file-events".into())
            .spawn(move || worker_dispatch.run())
            .expect("file event dispatcher");
        Arc::new(Self {
            operations: Mutex::new(()),
            entries: Mutex::new(HashMap::new()),
            next: AtomicU64::new(1),
            dispatch,
            worker: Mutex::new(Some(worker)),
        })
    }
    fn signal(&self, path: &Path, generation: u64, event: notify::Event) {
        let flags = match event.kind {
            EventKind::Any => Flags::ALL,
            EventKind::Create(_) => Flags::CREATE,
            EventKind::Remove(_) => Flags::DELETE,
            EventKind::Modify(notify::event::ModifyKind::Name(_)) => Flags::RENAME,
            EventKind::Modify(_) => Flags::WRITE,
            _ => return,
        };
        let change = Change {
            flags,
            paths: event.paths.into_iter().take(64).collect(),
        };
        let entries = self.entries.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(entry) = entries
            .get(path)
            .filter(|entry| entry.generation == generation)
        {
            for (id, subscriber) in &entry.subscribers {
                self.dispatch.enqueue(*id, subscriber, &change);
            }
        }
    }
    fn subscribe(
        self: &Arc<Self>,
        path: PathBuf,
        mask: Flags,
        callback: Callback,
    ) -> notify::Result<Subscription> {
        let _operation = self.operations.lock().unwrap_or_else(|e| e.into_inner());
        let id = self.next.fetch_add(1, Ordering::Relaxed);
        let cancelled = Arc::new(AtomicBool::new(false));
        let subscriber = Subscriber {
            mask,
            callback,
            cancelled: cancelled.clone(),
        };
        let current_identity = identity(&path);
        let reusable = self
            .entries
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .get(&path)
            .is_some_and(|entry| entry.identity == current_identity);
        if !reusable {
            let generation = self.next.fetch_add(1, Ordering::Relaxed);
            let weak = Arc::downgrade(self);
            let watch_path = path.clone();
            let mut watcher =
                notify::recommended_watcher(move |result: notify::Result<notify::Event>| {
                    if let (Some(registry), Ok(event)) = (weak.upgrade(), result) {
                        registry.signal(&watch_path, generation, event);
                    }
                })?;
            watcher.watch(&path, RecursiveMode::NonRecursive)?;
            let mut entries = self.entries.lock().unwrap_or_else(|e| e.into_inner());
            let old = entries.remove(&path);
            let subscribers = old
                .as_ref()
                .map(|entry| entry.subscribers.clone())
                .unwrap_or_default();
            entries.insert(
                path.clone(),
                Entry {
                    _watcher: watcher,
                    identity: current_identity,
                    generation,
                    subscribers,
                },
            );
            drop(entries);
            // Cancel/join native sources outside the routing lock.
            drop(old);
        }
        self.entries
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .get_mut(&path)
            .expect("registered path")
            .subscribers
            .insert(id, subscriber);
        Ok(Subscription {
            registry: self.clone(),
            path,
            id,
            cancelled,
        })
    }
    fn cancel(&self, path: &Path, id: u64) {
        let _operation = self.operations.lock().unwrap_or_else(|e| e.into_inner());
        let mut entries = self.entries.lock().unwrap_or_else(|e| e.into_inner());
        let empty = entries.get_mut(path).is_some_and(|entry| {
            entry.subscribers.remove(&id);
            entry.subscribers.is_empty()
        });
        let old = empty.then(|| entries.remove(path)).flatten();
        drop(entries);
        drop(old);
        self.dispatch
            .queue
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .pending
            .remove(&id);
    }
}
impl Drop for Registry {
    fn drop(&mut self) {
        let mut queue = self
            .dispatch
            .queue
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        queue.stopping = true;
        queue.pending.clear();
        self.dispatch.wake.notify_all();
        drop(queue);
        // Cancellation never waits for a user callback: it may itself cancel
        // a subscription or hold an application lock. The worker owns only
        // Dispatcher and exits once any already-running callback returns.
        self.worker.lock().unwrap_or_else(|e| e.into_inner()).take();
    }
}
pub struct Subscription {
    registry: Arc<Registry>,
    path: PathBuf,
    id: u64,
    cancelled: Arc<AtomicBool>,
}
impl Subscription {
    pub fn cancel(&self) {
        if !self.cancelled.swap(true, Ordering::AcqRel) {
            self.registry.cancel(&self.path, self.id);
        }
    }
}
impl Drop for Subscription {
    fn drop(&mut self) {
        self.cancel();
    }
}
pub fn subscribe(
    path: &Path,
    mask: Flags,
    on_change: impl Fn(Change) + Send + Sync + 'static,
) -> notify::Result<Subscription> {
    let canonical = path.canonicalize().map_err(notify::Error::io)?;
    let registry = {
        let mut shared = SHARED.lock().unwrap_or_else(|e| e.into_inner());
        shared.upgrade().unwrap_or_else(|| {
            let registry = Registry::new();
            *shared = Arc::downgrade(&registry);
            registry
        })
    };
    registry.subscribe(canonical, mask, Arc::new(on_change))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::mpsc;
    use std::time::Duration;
    fn fixture() -> PathBuf {
        let path = std::env::temp_dir().join(format!(
            "chau7-next-watch-registry-{}",
            uuid::Uuid::new_v4()
        ));
        std::fs::create_dir_all(&path).unwrap();
        path
    }
    fn signal(registry: &Registry, path: &Path, kind: EventKind) {
        let entries = registry.entries.lock().unwrap();
        let generation = entries.get(path).unwrap().generation;
        drop(entries);
        registry.signal(
            path,
            generation,
            notify::Event::new(kind).add_path(path.to_path_buf()),
        );
    }
    #[test]
    fn shared_native_identity_masks_and_independent_cancellation() {
        let dir = fixture();
        let path = dir.join("file");
        std::fs::write(&path, "initial").unwrap();
        let registry = Registry::new();
        let (write_tx, write_rx) = mpsc::channel();
        let (delete_tx, delete_rx) = mpsc::channel();
        let first = registry
            .subscribe(
                path.clone(),
                Flags::WRITE,
                Arc::new(move |change| {
                    let _ = write_tx.send(change);
                }),
            )
            .unwrap();
        let generation = registry.entries.lock().unwrap()[&path].generation;
        let second = registry
            .subscribe(
                path.clone(),
                Flags::DELETE,
                Arc::new(move |change| {
                    let _ = delete_tx.send(change);
                }),
            )
            .unwrap();
        {
            let entries = registry.entries.lock().unwrap();
            assert_eq!(entries.len(), 1);
            assert_eq!(entries[&path].subscribers.len(), 2);
            assert_eq!(entries[&path].generation, generation);
        }
        signal(
            &registry,
            &path,
            EventKind::Modify(notify::event::ModifyKind::Any),
        );
        assert_eq!(
            write_rx.recv_timeout(Duration::from_secs(2)).unwrap().flags,
            Flags::WRITE
        );
        assert!(delete_rx.try_recv().is_err());
        first.cancel();
        first.cancel();
        signal(
            &registry,
            &path,
            EventKind::Remove(notify::event::RemoveKind::Any),
        );
        assert_eq!(
            delete_rx
                .recv_timeout(Duration::from_secs(2))
                .unwrap()
                .flags,
            Flags::DELETE
        );
        assert!(write_rx.try_recv().is_err());
        assert_eq!(registry.entries.lock().unwrap()[&path].subscribers.len(), 1);
        drop(second);
        assert!(registry.entries.lock().unwrap().is_empty());
        drop(first);
        drop(registry);
        std::fs::remove_dir_all(dir).unwrap();
    }
    #[test]
    fn queued_callbacks_are_bounded_coalesced_and_cancelled() {
        let dispatch = Dispatcher::default();
        let cancelled = Arc::new(AtomicBool::new(false));
        let sub = Subscriber {
            mask: Flags::ALL,
            callback: Arc::new(|_| {}),
            cancelled: cancelled.clone(),
        };
        for index in 0..1000 {
            dispatch.enqueue(
                1,
                &sub,
                &Change {
                    flags: Flags::WRITE,
                    paths: BTreeSet::from([PathBuf::from(format!("/fixture/{index}"))]),
                },
            );
        }
        dispatch.enqueue(
            1,
            &sub,
            &Change {
                flags: Flags::DELETE,
                paths: BTreeSet::new(),
            },
        );
        {
            let queue = dispatch.queue.lock().unwrap();
            assert_eq!(queue.pending.len(), 1);
            assert_eq!(queue.pending[&1].change.paths.len(), 64);
            assert!(queue.pending[&1].change.flags.intersects(Flags::WRITE));
            assert!(queue.pending[&1].change.flags.intersects(Flags::DELETE));
        }
        cancelled.store(true, Ordering::Release);
        dispatch.enqueue(
            2,
            &sub,
            &Change {
                flags: Flags::WRITE,
                paths: BTreeSet::new(),
            },
        );
        assert_eq!(dispatch.queue.lock().unwrap().pending.len(), 1);
    }
    #[test]
    fn replacement_rearms_shared_native_source_without_losing_other_subscribers() {
        let dir = fixture();
        let path = dir.join("file");
        std::fs::write(&path, "first").unwrap();
        let registry = Registry::new();
        let first = registry
            .subscribe(path.clone(), Flags::ALL, Arc::new(|_| {}))
            .unwrap();
        let generation = registry.entries.lock().unwrap()[&path].generation;
        let replacement = dir.join("replacement");
        std::fs::write(&replacement, "replacement").unwrap();
        std::fs::rename(&replacement, &path).unwrap();
        let second = registry
            .subscribe(path.clone(), Flags::ALL, Arc::new(|_| {}))
            .unwrap();
        {
            let entries = registry.entries.lock().unwrap();
            assert_eq!(entries[&path].subscribers.len(), 2);
            assert_ne!(entries[&path].generation, generation);
        }
        drop(first);
        assert_eq!(registry.entries.lock().unwrap()[&path].subscribers.len(), 1);
        drop(second);
        drop(registry);
        std::fs::remove_dir_all(dir).unwrap();
    }
    #[cfg(unix)]
    #[test]
    fn symlink_aliases_share_canonical_watch_and_last_drop_releases_it() {
        let dir = fixture();
        let path = dir.join("file");
        let alias = dir.join("alias");
        std::fs::write(&path, "first").unwrap();
        std::os::unix::fs::symlink(&path, &alias).unwrap();
        let first = subscribe(&path, Flags::ALL, |_| {}).unwrap();
        let second = subscribe(&alias, Flags::ALL, |_| {}).unwrap();
        assert!(Arc::ptr_eq(&first.registry, &second.registry));
        assert_eq!(first.path, second.path);
        let registry = first.registry.clone();
        assert_eq!(
            registry.entries.lock().unwrap()[&first.path]
                .subscribers
                .len(),
            2
        );
        drop(first);
        drop(second);
        assert!(
            !registry
                .entries
                .lock()
                .unwrap()
                .contains_key(&path.canonicalize().unwrap())
        );
        drop(registry);
        std::fs::remove_dir_all(dir).unwrap();
    }
}
