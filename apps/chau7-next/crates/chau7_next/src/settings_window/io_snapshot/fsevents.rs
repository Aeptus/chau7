//! One macOS FSEvents stream for all owned user snippets. Unlike per-file
//! kqueue watches, adding snippets does not add one open descriptor per file.
//! Construction and Stop/Invalidate/callback barrier/Release run on the sole
//! owner thread, off UI. A serial dispatch queue delivers events; no timer or
//! unbounded event queue is added. Disposal joins only this owned subscription.
use dispatch2::{DispatchQueue, DispatchRetained};
use objc2_core_foundation::{CFArray, CFString};
use objc2_core_services as fs;
use std::{
    ffi::{CStr, c_void},
    os::unix::ffi::OsStrExt,
    path::{Path, PathBuf},
    ptr::{self, NonNull},
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
        mpsc,
    },
    thread::{self, JoinHandle},
};

type Callback = Arc<dyn Fn() + Send + Sync>;
struct Handler {
    target: PathBuf,
    callback: Callback,
    stopped: AtomicBool,
}
unsafe extern "C-unwind" fn events(
    _: fs::ConstFSEventStreamRef,
    info: *mut c_void,
    count: usize,
    paths: NonNull<c_void>,
    _: NonNull<fs::FSEventStreamEventFlags>,
    _: NonNull<fs::FSEventStreamEventId>,
) {
    // UseCFTypes is deliberately absent: eventPaths is an array of count
    // NUL-terminated filesystem paths, not a CFArray/CFString collection.
    // The Box stays stable until Invalidate and the serial callback barrier.
    // Never unwind through native delivery; the consumer only coalesces work.
    let _ = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| unsafe {
        let handler = &*info.cast::<Handler>();
        if handler.stopped.load(Ordering::Acquire) {
            return;
        }
        let paths = paths.as_ptr().cast::<*const std::ffi::c_char>();
        let relevant = (0..count).any(|index| {
            let bytes = CStr::from_ptr(*paths.add(index)).to_bytes();
            let path = Path::new(std::ffi::OsStr::from_bytes(bytes));
            path.starts_with(&handler.target) || handler.target.starts_with(path)
        });
        if relevant && !handler.stopped.load(Ordering::Acquire) {
            (handler.callback)();
        }
    }));
}
struct Resources {
    stream: fs::FSEventStreamRef,
    queue: DispatchRetained<DispatchQueue>,
    started: bool,
    handler: Box<Handler>,
}
impl Drop for Resources {
    fn drop(&mut self) {
        self.handler.stopped.store(true, Ordering::Release);
        unsafe {
            if !self.stream.is_null() {
                if self.started {
                    fs::FSEventStreamStop(self.stream);
                }
                fs::FSEventStreamInvalidate(self.stream);
                // Always on the separate owner thread, never this serial
                // callback queue. In-flight delivery completes before context
                // release, including partial construction/start failures.
                self.queue.exec_sync(|| {});
                fs::FSEventStreamRelease(self.stream);
            }
        }
    }
}
impl Resources {
    fn create(watched: &Path, target: PathBuf, callback: Callback) -> Result<Self, String> {
        Self::create_with_start(watched, target, callback, |stream| unsafe {
            fs::FSEventStreamStart(stream)
        })
    }

    fn create_with_start(
        watched: &Path,
        target: PathBuf,
        callback: Callback,
        start: impl FnOnce(fs::FSEventStreamRef) -> bool,
    ) -> Result<Self, String> {
        let path = watched
            .to_str()
            .ok_or("Snippet watcher path is not UTF-8")?;
        let path_string = CFString::from_str(path);
        let paths = CFArray::from_objects(&[&*path_string]);
        let mut owner = Self {
            stream: ptr::null_mut(),
            queue: DispatchQueue::new("chau7-next.settings.snippet-events", None),
            started: false,
            handler: Box::new(Handler {
                target,
                callback,
                stopped: AtomicBool::new(false),
            }),
        };
        let mut context = fs::FSEventStreamContext {
            version: 0,
            info: (&mut *owner.handler as *mut Handler).cast(),
            retain: None,
            release: None,
            copyDescription: None,
        };
        // Typed CFArray contains CFStrings; callbacks use raw filesystem paths
        // because UseCFTypes is not enabled. The stream owns copied watch data.
        unsafe {
            owner.stream = fs::FSEventStreamCreate(
                None,
                Some(events),
                &mut context,
                paths.as_opaque(),
                fs::kFSEventStreamEventIdSinceNow,
                0.05,
                fs::kFSEventStreamCreateFlagFileEvents
                    | fs::kFSEventStreamCreateFlagWatchRoot
                    | fs::kFSEventStreamCreateFlagNoDefer,
            );
            if owner.stream.is_null() {
                return Err("Could not create snippet event stream".into());
            }
            fs::FSEventStreamSetDispatchQueue(owner.stream, Some(&owner.queue));
        }
        owner.started = start(owner.stream);
        if !owner.started {
            return Err("Could not start snippet event stream".into());
        }
        Ok(owner)
    }
}

pub(super) struct SnippetWatch {
    stop: mpsc::SyncSender<()>,
    thread: Option<JoinHandle<()>>,
}
impl SnippetWatch {
    pub(super) fn new(path: &Path, boundary: &Path, callback: Callback) -> Result<Self, String> {
        // Missing snippet folders are observed from the nearest existing
        // owned ancestor; no filesystem/config folder is created by watching.
        if !path.starts_with(boundary) {
            return Err("Snippet path is outside its owned root".into());
        }
        let mut watched = path;
        while !watched.exists() && watched != boundary {
            watched = watched
                .parent()
                .ok_or("Snippet watch has no owned parent")?;
        }
        let canonical = watched.canonicalize().map_err(|error| error.to_string())?;
        let target = canonical.join(
            path.strip_prefix(watched)
                .map_err(|error| error.to_string())?,
        );
        let (ready_tx, ready_rx) = mpsc::sync_channel(1);
        let (stop, stopped) = mpsc::sync_channel(1);
        let thread = thread::Builder::new()
            .name("chau7-settings-snippet-events".into())
            .spawn(move || {
                let owner = match Resources::create(&canonical, target, callback) {
                    Ok(owner) => owner,
                    Err(error) => {
                        let _ = ready_tx.send(Err(error));
                        return;
                    }
                };
                if ready_tx.send(Ok(())).is_err() {
                    return;
                }
                // Sender disconnection is also a stop request. No poll/timer;
                // delivery continues independently on the owned serial queue.
                let _ = stopped.recv();
                drop(owner);
            })
            .map_err(|error| error.to_string())?;
        match ready_rx.recv() {
            Ok(Ok(())) => Ok(Self {
                stop,
                thread: Some(thread),
            }),
            Ok(Err(error)) => {
                let _ = thread.join();
                Err(error)
            }
            Err(error) => {
                let _ = thread.join();
                Err(error.to_string())
            }
        }
    }
}
impl Drop for SnippetWatch {
    fn drop(&mut self) {
        let _ = self.stop.try_send(());
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use chau7_next_core::snippet_store::{self, Snippet};
    use std::{
        sync::atomic::{AtomicUsize, Ordering},
        time::Duration,
    };

    #[test]
    fn failed_stream_start_releases_its_callback_owner() {
        let root = std::env::temp_dir().join(format!(
            "chau7-next-fsevents-start-failure-{}",
            uuid::Uuid::new_v4()
        ));
        std::fs::create_dir(&root).unwrap();
        let callback: Callback = Arc::new(|| {});
        let result = Resources::create_with_start(&root, root.clone(), callback.clone(), |_| false);
        assert!(result.is_err());
        assert_eq!(Arc::strong_count(&callback), 1);
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn disposal_waits_for_actual_inflight_callback_on_another_thread() {
        let root = std::env::temp_dir().join(format!(
            "chau7-next-fsevents-callback-barrier-{}",
            uuid::Uuid::new_v4()
        ));
        std::fs::create_dir(&root).unwrap();
        let (entered_tx, entered_rx) = mpsc::sync_channel(1);
        let (release_tx, release_rx) = mpsc::sync_channel(1);
        let release_rx = std::sync::Mutex::new(release_rx);
        let first = AtomicBool::new(true);
        let callback: Callback = Arc::new(move || {
            if first.swap(false, Ordering::AcqRel) {
                entered_tx.send(thread::current().id()).unwrap();
                release_rx
                    .lock()
                    .unwrap()
                    .recv_timeout(Duration::from_secs(5))
                    .unwrap();
            }
        });
        let watch = SnippetWatch::new(&root, &root, callback.clone()).unwrap();
        std::fs::write(root.join("owned.json"), "{}").unwrap();
        let delivery_thread = entered_rx.recv_timeout(Duration::from_secs(5)).unwrap();
        assert_ne!(delivery_thread, thread::current().id());
        let (finished_tx, finished_rx) = mpsc::sync_channel(1);
        let join = thread::spawn(move || {
            drop(watch);
            finished_tx.send(()).unwrap();
        });
        assert!(matches!(
            finished_rx.try_recv(),
            Err(mpsc::TryRecvError::Empty)
        ));
        release_tx.send(()).unwrap();
        finished_rx.recv_timeout(Duration::from_secs(5)).unwrap();
        join.join().unwrap();
        assert_eq!(Arc::strong_count(&callback), 1);
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn actual_stream_observes_in_place_changes_rename_and_disposal() {
        let root = std::env::temp_dir().join(format!(
            "chau7-next-settings-fsevents-{}",
            uuid::Uuid::new_v4()
        ));
        let directory = root.join("snippets");
        std::fs::create_dir_all(&directory).unwrap();
        let file = directory.join("owned.json");
        let valid = serde_json::to_string(&Snippet::new("owned", "Owned", "synthetic")).unwrap();
        std::fs::write(&file, &valid).unwrap();
        let (sender, receiver) = mpsc::sync_channel(1);
        let count = Arc::new(AtomicUsize::new(0));
        let events = count.clone();
        let watch = SnippetWatch::new(
            &directory,
            &root,
            Arc::new(move || {
                events.fetch_add(1, Ordering::SeqCst);
                let _ = sender.try_send(());
            }),
        )
        .unwrap();
        assert_eq!(snippet_store::load_dir(&directory).len(), 1);
        std::fs::write(&file, "invalid JSON").unwrap();
        receiver.recv_timeout(Duration::from_secs(5)).unwrap();
        assert_eq!(super::super::read_snippets(&directory).unwrap(), 0);
        while receiver.try_recv().is_ok() {}
        std::fs::write(&file, &valid).unwrap();
        receiver.recv_timeout(Duration::from_secs(5)).unwrap();
        assert_eq!(super::super::read_snippets(&directory).unwrap(), 1);
        while receiver.try_recv().is_ok() {}
        std::fs::rename(&file, directory.join("owned.txt")).unwrap();
        receiver.recv_timeout(Duration::from_secs(5)).unwrap();
        assert_eq!(super::super::read_snippets(&directory).unwrap(), 0);
        drop(watch); // joined: no queued/native callback can access the consumer
        let disposed = count.load(Ordering::SeqCst);
        std::fs::write(directory.join("after.json"), &valid).unwrap();
        std::thread::sleep(Duration::from_millis(200));
        assert_eq!(count.load(Ordering::SeqCst), disposed);
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn missing_owned_folder_and_immediate_disposal_are_supported() {
        let root = std::env::temp_dir().join(format!(
            "chau7-next-settings-fsevents-missing-{}",
            uuid::Uuid::new_v4()
        ));
        std::fs::create_dir_all(&root).unwrap();
        let directory = root.join("not-yet-created").join("snippets");
        let (sender, receiver) = mpsc::sync_channel(1);
        let watch = SnippetWatch::new(
            &directory,
            &root,
            Arc::new(move || {
                let _ = sender.try_send(());
            }),
        )
        .unwrap();
        std::fs::create_dir_all(&directory).unwrap();
        snippet_store::save_snippet(&directory, &Snippet::new("owned", "Owned", "synthetic"))
            .unwrap();
        receiver.recv_timeout(Duration::from_secs(5)).unwrap();
        assert_eq!(super::super::read_snippets(&directory).unwrap(), 1);
        drop(watch);
        for _ in 0..10 {
            drop(SnippetWatch::new(&directory, &root, Arc::new(|| {})).unwrap());
        }
        assert!(SnippetWatch::new(&root, &directory, Arc::new(|| {})).is_err());
        std::fs::remove_dir_all(root).unwrap();
    }
}
