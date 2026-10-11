//! Owned single writer. Capture is memory-only; disk work and final drain run
//! outside GPUI. Pending histories stay available to a tab reopened mid-save.
use crate::session_store::SavedSession;
use crate::workspace::AppData;
use chau7_next_core::data_root::DataRoot;
use chau7_next_core::session_restore::writer::{
    BufferLedger, ContextBuffer, RestoreWriter, SubmitResult, WriterStats,
};
use gpui::{App, Global};
use std::collections::{HashMap, HashSet};
use std::sync::{Arc, Mutex};
use std::thread::JoinHandle;
struct Request {
    session: Option<SavedSession>,
    contexts: HashMap<u64, ContextBuffer>,
    keep: HashSet<u64>,
    terminating: bool,
}
struct Service {
    buffers: Arc<Mutex<BufferLedger>>,
    queue: Option<RestoreWriter<Request>>,
}
impl Global for Service {}
pub(crate) fn init(cx: &mut App) {
    let root = cx.global::<AppData>().root.clone();
    let buffers = Arc::new(Mutex::new(BufferLedger::default()));
    let work_buffers = buffers.clone();
    let queue = match RestoreWriter::start(move |request| commit(&root, &work_buffers, request)) {
        Ok(queue) => Some(queue),
        Err(error) => {
            log::error!("Cannot start restore writer: {error}");
            None
        }
    };
    cx.set_global(Service { buffers, queue });
}
pub(crate) fn record(pane: u64, text: Option<String>, cx: &App) -> bool {
    let Some(service) = cx.try_global::<Service>() else {
        return false;
    };
    let mut buffers = service.buffers.lock().unwrap_or_else(|e| e.into_inner());
    match buffers.record(pane, text) {
        Ok(present) => present,
        Err(_) => {
            log::warn!("Restore capture bound reached for pane {pane}");
            buffers.has_context(pane)
        }
    }
}
pub(crate) fn contexts_for(panes: &[u64], cx: &App) -> HashMap<u64, Option<Arc<String>>> {
    cx.try_global::<Service>()
        .map(|service| {
            service
                .buffers
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .contexts_for(panes)
        })
        .unwrap_or_default()
}
pub(crate) fn submit(
    session: Option<SavedSession>,
    keep: HashSet<u64>,
    terminating: bool,
    cx: &App,
) {
    let Some(service) = cx.try_global::<Service>() else {
        return;
    };
    let Some(queue) = &service.queue else {
        return;
    };
    let contexts = service
        .buffers
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .snapshot();
    if matches!(
        queue.submit(
            Request {
                session,
                contexts,
                keep,
                terminating
            },
            terminating
        ),
        SubmitResult::Closed | SubmitResult::FinalAlreadyQueued
    ) {
        log::warn!("Restore capture rejected after final shutdown capture");
    }
}
pub(crate) fn shutdown(cx: &mut App) -> Option<JoinHandle<WriterStats>> {
    cx.global_mut::<Service>()
        .queue
        .take()
        .map(RestoreWriter::shutdown)
}
fn commit(root: &DataRoot, buffers: &Mutex<BufferLedger>, request: Request) -> bool {
    use chau7_next_core::work_profiler::{self, Key, Queue};
    let mut work = work_profiler::begin(Key::work(
        "save_restore_transaction",
        if request.terminating {
            "termination"
        } else {
            "autosave"
        },
        "unobserved",
        "restore_writer",
        Queue::Background,
    ));
    work.items(request.contexts.len());
    let result = (|| -> std::io::Result<()> {
        // Reject oversized metadata before modifying canonical contexts. Bundle
        // serialization, hashing, fsync, archiving and pruning all run here.
        if let Some(session) = &request.session
            && serde_json::to_vec(session)
                .map_err(std::io::Error::other)?
                .len()
                > 16 * 1024 * 1024
        {
            return Err(std::io::Error::other(
                "restore metadata exceeds bounded manifest size",
            ));
        }
        write_contexts(root, &request.contexts)?;
        // Actual successfully written context bytes, not an estimated total I/O
        // count. Exact committed bundle sizes remain in the incident payload.
        work.bytes(
            request
                .contexts
                .values()
                .filter_map(|buffer| buffer.text.as_ref())
                .map(|text| text.len())
                .sum(),
        );
        match &request.session {
            Some(session) => {
                crate::session_store::save_for_measured(root, session, request.terminating)?;
            }
            None => crate::session_store::clear(root)?,
        }
        Ok(())
    })();
    match result {
        Ok(()) => {
            let mut keep = request.keep;
            {
                let mut buffers = buffers.lock().unwrap_or_else(|e| e.into_inner());
                buffers.acknowledge(&request.contexts);
                keep.extend(buffers.pending_ids());
                buffers.retain(&keep);
            }
            super::prune_scrollback(root, &keep);
            true
        }
        Err(error) => {
            // Buffers remain available even when a tab closes before retry.
            buffers
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .invalidate_persisted(&request.keep);
            log::warn!("Cannot commit restore capture: {error}");
            false
        }
    }
}
pub(super) fn write_contexts(
    root: &DataRoot,
    contexts: &HashMap<u64, ContextBuffer>,
) -> std::io::Result<()> {
    for (pane, buffer) in contexts {
        let path = super::scrollback_file(root, *pane);
        match &buffer.text {
            Some(text) => crate::session_store::atomic_write(&path, text.as_bytes())?,
            None => match std::fs::remove_file(&path) {
                Ok(()) => {
                    #[cfg(unix)]
                    std::fs::File::open(root.scrollback_dir())?.sync_all()?;
                }
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => (),
                Err(error) => return Err(error),
            },
        }
    }
    Ok(())
}
#[cfg(test)]
mod tests {
    use super::*;
    use crate::session_store::{SavedPane, SavedTab, SavedWindow};
    fn root() -> DataRoot {
        DataRoot::with_home(
            std::env::temp_dir().join(format!("next-restore-writer-{}", uuid::Uuid::new_v4())),
            true,
        )
    }
    fn session() -> SavedSession {
        SavedSession {
            version: 1,
            windows: vec![SavedWindow {
                tabs: vec![SavedTab {
                    panes: vec![SavedPane {
                        id: 1,
                        scrollback: true,
                        ..Default::default()
                    }],
                    ..Default::default()
                }],
                ..Default::default()
            }],
        }
    }
    #[test]
    fn durable_commit_acknowledges_exact_context_and_keeps_closed_history() {
        let root = root();
        let buffers = Mutex::new(BufferLedger::default());
        {
            let mut ledger = buffers.lock().unwrap();
            ledger.record(1, Some("live".into())).unwrap();
            ledger.record(2, Some("closed".into())).unwrap();
        }
        let contexts = buffers.lock().unwrap().snapshot();
        assert!(commit(
            &root,
            &buffers,
            Request {
                session: Some(session()),
                contexts,
                keep: HashSet::from([1, 2]),
                terminating: false
            }
        ));
        assert!(buffers.lock().unwrap().snapshot().is_empty());
        assert_eq!(
            std::fs::read_to_string(super::super::scrollback_file(&root, 2)).unwrap(),
            "closed"
        );
        assert_eq!(
            crate::session_store::load(&root).unwrap().windows[0].tabs[0].panes[0].id,
            1
        );
        let _ = std::fs::remove_dir_all(root.home());
    }
    #[test]
    fn failed_disk_commit_retains_reopened_context() {
        let root = root();
        std::fs::create_dir_all(root.state_dir()).unwrap();
        std::fs::write(root.scrollback_dir(), "not a directory").unwrap();
        let buffers = Mutex::new(BufferLedger::default());
        buffers
            .lock()
            .unwrap()
            .record(1, Some("pending".into()))
            .unwrap();
        let contexts = buffers.lock().unwrap().snapshot();
        assert!(!commit(
            &root,
            &buffers,
            Request {
                session: Some(session()),
                contexts,
                keep: HashSet::from([1]),
                terminating: false
            }
        ));
        assert_eq!(
            buffers.lock().unwrap().contexts_for(&[1])[&1]
                .as_deref()
                .map(String::as_str),
            Some("pending")
        );
        assert!(!root.session_file().exists());
        let _ = std::fs::remove_dir_all(root.home());
    }
    #[test]
    fn worker_shutdown_drains_final_capture_before_returning() {
        let root = root();
        let buffers = Arc::new(Mutex::new(BufferLedger::default()));
        let work_root = root.clone();
        let work_buffers = buffers.clone();
        let writer =
            RestoreWriter::start(move |request| commit(&work_root, &work_buffers, request))
                .unwrap();
        let mut initial = session();
        initial.windows[0].tabs[0].panes[0].scrollback = false;
        writer.submit(
            Request {
                session: Some(initial),
                contexts: HashMap::new(),
                keep: HashSet::new(),
                terminating: false,
            },
            false,
        );
        writer.submit(
            Request {
                session: None,
                contexts: HashMap::new(),
                keep: HashSet::new(),
                terminating: true,
            },
            true,
        );
        assert_eq!(writer.shutdown().join().unwrap().failed, 0);
        assert!(
            crate::session_store::load(&root)
                .unwrap()
                .windows
                .is_empty()
        );
        let _ = std::fs::remove_dir_all(root.home());
    }
    #[test]
    fn oversized_manifest_is_rejected_before_replacing_canonical_context() {
        let root = root();
        crate::session_store::atomic_write(&super::super::scrollback_file(&root, 1), b"durable")
            .unwrap();
        let buffers = Mutex::new(BufferLedger::default());
        buffers
            .lock()
            .unwrap()
            .record(1, Some("new pending".into()))
            .unwrap();
        let mut saved = session();
        saved.windows[0].tabs[0].custom_title = Some("x".repeat(16 * 1024 * 1024));
        let contexts = buffers.lock().unwrap().snapshot();
        assert!(!commit(
            &root,
            &buffers,
            Request {
                session: Some(saved),
                contexts,
                keep: HashSet::from([1]),
                terminating: false
            }
        ));
        assert_eq!(
            std::fs::read_to_string(super::super::scrollback_file(&root, 1)).unwrap(),
            "durable"
        );
        assert_eq!(
            buffers.lock().unwrap().contexts_for(&[1])[&1]
                .as_deref()
                .map(String::as_str),
            Some("new pending")
        );
        let _ = std::fs::remove_dir_all(root.home());
    }
    #[test]
    fn actual_save_duration_is_exposed_as_background_work() {
        let root = root();
        let buffers = Mutex::new(BufferLedger::default());
        assert!(commit(
            &root,
            &buffers,
            Request {
                session: None,
                contexts: HashMap::new(),
                keep: HashSet::new(),
                terminating: true
            }
        ));
        if chau7_next_core::work_profiler::enabled() {
            let snapshot = chau7_next_core::work_profiler::snapshot();
            let entry = snapshot["entries"]
                .as_array()
                .unwrap()
                .iter()
                .find(|entry| {
                    entry["operation"] == "save_restore_transaction"
                        && entry["phase"] == "termination"
                })
                .expect("actual restore save work");
            assert_eq!(entry["queue"], "background");
            assert!(entry["lifetime"]["sample_count"].as_u64().unwrap() >= 1);
            assert!(entry["lifetime"]["total_ms"].as_f64().unwrap() >= 0.0);
        }
        let _ = std::fs::remove_dir_all(root.home());
    }
    #[test]
    fn final_empty_capture_is_durable_explicit_clear() {
        let root = root();
        let buffers = Mutex::new(BufferLedger::default());
        assert!(commit(
            &root,
            &buffers,
            Request {
                session: None,
                contexts: HashMap::new(),
                keep: HashSet::new(),
                terminating: true
            }
        ));
        assert!(
            crate::session_store::load(&root)
                .unwrap()
                .windows
                .is_empty()
        );
        let _ = std::fs::remove_dir_all(root.home());
    }
}
