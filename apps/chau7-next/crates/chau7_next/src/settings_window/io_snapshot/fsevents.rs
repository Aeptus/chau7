//! One macOS FSEvents stream for all owned user snippets. Unlike per-file
//! kqueue watches, adding snippets does not add one open descriptor per file.
//! Construction runs off UI; disposal signals a run-loop source and joins the
//! sole event thread. There is no polling timer or unbounded event queue.
use core_foundation_sys::{array, base, runloop, string};
use fsevent_sys as fs;
use std::{
    ffi::{CStr, c_void},
    os::unix::ffi::OsStrExt,
    path::{Path, PathBuf},
    ptr,
    sync::{Arc, mpsc},
    thread::{self, JoinHandle},
};

type Callback = Arc<dyn Fn() + Send + Sync>;
struct Handler {
    target: PathBuf,
    callback: Callback,
}
extern "C" fn events(
    _: fs::FSEventStreamRef,
    info: *mut c_void,
    count: usize,
    paths: *mut c_void,
    _: *const fs::FSEventStreamEventFlags,
    _: *const fs::FSEventStreamEventId,
) {
    // FSEvents supplies count NUL-terminated filesystem paths. Handler stays
    // owned by Resources until Stop/Invalidate/Release have completed.
    let relevant = unsafe {
        let handler = &*info.cast::<Handler>();
        let paths = paths.cast::<*const std::ffi::c_char>();
        (0..count).any(|index| {
            let bytes = CStr::from_ptr(*paths.add(index)).to_bytes();
            let path = Path::new(std::ffi::OsStr::from_bytes(bytes));
            path.starts_with(&handler.target) || handler.target.starts_with(path)
        })
    };
    if relevant {
        // Never unwind through a C callback; the consumer only coalesces work.
        let _ = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| unsafe {
            ((*info.cast::<Handler>()).callback)();
        }));
    }
}
extern "C" fn stop_loop(_: *const c_void) {
    unsafe { runloop::CFRunLoopStop(runloop::CFRunLoopGetCurrent()) };
}
struct Resources {
    stream: fs::FSEventStreamRef,
    source: runloop::CFRunLoopSourceRef,
    runloop: runloop::CFRunLoopRef,
    started: bool,
    handler: Box<Handler>,
}
impl Drop for Resources {
    fn drop(&mut self) {
        unsafe {
            if !self.stream.is_null() {
                if self.started {
                    fs::FSEventStreamStop(self.stream);
                }
                fs::FSEventStreamInvalidate(self.stream);
                fs::FSEventStreamRelease(self.stream);
            }
            if !self.source.is_null() {
                runloop::CFRunLoopRemoveSource(
                    self.runloop,
                    self.source,
                    runloop::kCFRunLoopDefaultMode,
                );
                runloop::CFRunLoopSourceInvalidate(self.source);
                base::CFRelease(self.source.cast());
            }
        }
    }
}
impl Resources {
    fn create(watched: &Path, target: PathBuf, callback: Callback) -> Result<Self, String> {
        let path = watched
            .to_str()
            .ok_or("Snippet watcher path is not UTF-8")?;
        let mut owner = Self {
            stream: ptr::null_mut(),
            source: ptr::null_mut(),
            runloop: unsafe { runloop::CFRunLoopGetCurrent() },
            started: false,
            handler: Box::new(Handler { target, callback }),
        };
        // All CF objects are created and released on this dedicated thread.
        unsafe {
            let path_string = string::CFStringCreateWithBytes(
                base::kCFAllocatorDefault,
                path.as_ptr(),
                path.len() as isize,
                string::kCFStringEncodingUTF8,
                false as u8,
            );
            if path_string.is_null() {
                return Err("Could not encode snippet watch path".into());
            }
            let values = [path_string.cast::<c_void>()];
            let paths = array::CFArrayCreate(
                base::kCFAllocatorDefault,
                values.as_ptr(),
                1,
                &array::kCFTypeArrayCallBacks,
            );
            base::CFRelease(path_string.cast());
            if paths.is_null() {
                return Err("Could not create snippet watch paths".into());
            }
            let context = fs::FSEventStreamContext {
                version: 0,
                info: (&mut *owner.handler as *mut Handler).cast(),
                retain: None,
                release: None,
                copy_description: None,
            };
            owner.stream = fs::FSEventStreamCreate(
                ptr::null_mut(),
                events,
                &context,
                paths.cast_mut().cast(),
                fs::kFSEventStreamEventIdSinceNow,
                0.05,
                fs::kFSEventStreamCreateFlagFileEvents
                    | fs::kFSEventStreamCreateFlagWatchRoot
                    | fs::kFSEventStreamCreateFlagNoDefer,
            );
            base::CFRelease(paths.cast());
            if owner.stream.is_null() {
                return Err("Could not create snippet event stream".into());
            }
            let mut context = runloop::CFRunLoopSourceContext {
                version: 0,
                info: ptr::null_mut(),
                retain: None,
                release: None,
                copyDescription: None,
                equal: None,
                hash: None,
                schedule: None,
                cancel: None,
                perform: stop_loop,
            };
            owner.source =
                runloop::CFRunLoopSourceCreate(base::kCFAllocatorDefault, 0, &mut context);
            if owner.source.is_null() {
                return Err("Could not create snippet stop source".into());
            }
            runloop::CFRunLoopAddSource(
                owner.runloop,
                owner.source,
                runloop::kCFRunLoopDefaultMode,
            );
            fs::FSEventStreamScheduleWithRunLoop(
                owner.stream,
                owner.runloop.cast(),
                runloop::kCFRunLoopDefaultMode.cast_mut().cast(),
            );
            owner.started = fs::FSEventStreamStart(owner.stream) != 0;
            if !owner.started {
                return Err("Could not start snippet event stream".into());
            }
        }
        Ok(owner)
    }
}

pub(super) struct SnippetWatch {
    runloop: usize,
    source: usize,
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
                if ready_tx
                    .send(Ok((owner.runloop as usize, owner.source as usize)))
                    .is_err()
                {
                    return;
                }
                // The installed stop source keeps this loop alive. A stop signal
                // submitted even before Run is retained and handled on entry.
                unsafe { runloop::CFRunLoopRun() };
                drop(owner);
            })
            .map_err(|error| error.to_string())?;
        match ready_rx.recv() {
            Ok(Ok((runloop, source))) => Ok(Self {
                runloop,
                source,
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
        // The worker owns both objects until its stop source executes. These
        // cross-thread CF signal/wake operations are safe, and join finishes
        // stream/context release before the subscription is considered gone.
        unsafe {
            runloop::CFRunLoopSourceSignal(self.source as runloop::CFRunLoopSourceRef);
            runloop::CFRunLoopWakeUp(self.runloop as runloop::CFRunLoopRef);
        }
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
