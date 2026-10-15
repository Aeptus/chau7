//! Nonblocking ordered admission for writes from UI callbacks. Only this
//! worker performs admitted writes; accepted jobs drain before clean termination.
use std::sync::{Arc, Mutex, mpsc};
use std::thread::JoinHandle;

use super::super::store::TelemetryStore;

pub const MAX_JOBS: usize = 1024;
pub const MAX_BYTES: usize = 32 * 1024 * 1024;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AdmissionError {
    Closed,
    Full,
    Oversize,
    WorkerUnavailable,
    PersistenceFailed,
}
impl std::fmt::Display for AdmissionError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{self:?}")
    }
}
impl std::error::Error for AdmissionError {}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct WriterStatus {
    pub accepted: u64,
    pub rejected: u64,
    pub processed: u64,
    pub failed: u64,
    pub pending_bytes: usize,
    pub accepting: bool,
    pub last_error: Option<String>,
}

type Job = Box<dyn FnOnce(&TelemetryStore) -> Result<(), String> + Send>;
type WorkerTask = Box<dyn FnOnce() -> WriterStatus + Send>;
struct Command {
    job: Job,
    bytes: usize,
    label: &'static str,
}
struct State {
    sender: Option<mpsc::SyncSender<Command>>,
    status: WriterStatus,
    caught_job_panic: bool,
}

/// Once the receiver is gone, every accepted but unprocessed command has been
/// dropped or interrupted. Account for those commands before publishing the
/// closed state so accepted = processed + pending remains meaningful.
fn mark_worker_unavailable(state: &mut State) {
    state.sender.take();
    state.status.accepting = false;
    let pending = state.status.accepted.saturating_sub(state.status.processed);
    state.status.processed = state.status.processed.saturating_add(pending);
    state.status.failed = state.status.failed.saturating_add(pending);
    state.status.pending_bytes = 0;
    state.status.last_error = Some("telemetry writer unavailable".into());
}

pub(super) struct Writer {
    state: Arc<Mutex<State>>,
    worker: Mutex<Option<JoinHandle<WriterStatus>>>,
    max_bytes: usize,
}
impl Writer {
    pub(super) fn new(store: Arc<TelemetryStore>) -> Self {
        Self::with_limits(store, MAX_JOBS, MAX_BYTES)
    }
    pub(super) fn with_limits(
        store: Arc<TelemetryStore>,
        max_jobs: usize,
        max_bytes: usize,
    ) -> Self {
        Self::with_spawner(store, max_jobs, max_bytes, |task| {
            std::thread::Builder::new()
                .name("next-telemetry-writer".into())
                .spawn(task)
        })
    }
    #[cfg(test)]
    pub(super) fn unavailable(store: Arc<TelemetryStore>) -> Self {
        Self::with_spawner(store, MAX_JOBS, MAX_BYTES, |_| {
            Err(std::io::Error::other(
                "owned injected worker creation failure",
            ))
        })
    }
    fn with_spawner(
        store: Arc<TelemetryStore>,
        max_jobs: usize,
        max_bytes: usize,
        spawn: impl FnOnce(WorkerTask) -> std::io::Result<JoinHandle<WriterStatus>>,
    ) -> Self {
        let (sender, receiver) = mpsc::sync_channel::<Command>(max_jobs);
        let state = Arc::new(Mutex::new(State {
            sender: Some(sender),
            status: WriterStatus {
                accepting: true,
                ..Default::default()
            },
            caught_job_panic: false,
        }));
        let shared = state.clone();
        let worker = spawn(Box::new(move || {
            while let Ok(command) = receiver.recv() {
                let mut span = crate::work_profiler::begin(crate::work_profiler::Key::work(
                    "telemetry_writer",
                    command.label,
                    "telemetry",
                    "telemetry_writer",
                    crate::work_profiler::Queue::Background,
                ));
                span.bytes(command.bytes);
                span.items(1);
                // Isolate a bad admitted closure to that command. A panic is
                // a failed, processed attempt; later commands still drain.
                let outcome = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                    (command.job)(&store)
                }));
                let mut state = shared.lock().unwrap_or_else(|e| e.into_inner());
                state.status.pending_bytes =
                    state.status.pending_bytes.saturating_sub(command.bytes);
                state.status.processed = state.status.processed.saturating_add(1);
                match outcome {
                    Ok(Ok(())) => {}
                    Ok(Err(error)) => {
                        state.status.failed = state.status.failed.saturating_add(1);
                        // SQL failure details remain diagnostic only; status has no
                        // transcript, command line, or database/profile path.
                        state.status.last_error = Some("telemetry persistence failed".into());
                        drop(state);
                        log::warn!("Telemetry writer {} failed: {error}", command.label);
                    }
                    Err(_) => {
                        state.status.failed = state.status.failed.saturating_add(1);
                        state.status.last_error = Some("telemetry writer job panicked".into());
                        state.caught_job_panic = true;
                        drop(state);
                        log::error!(
                            "Telemetry writer {} panicked; continuing with later jobs",
                            command.label
                        );
                    }
                }
            }
            shared
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .status
                .clone()
        }));
        let worker = match worker {
            Ok(worker) => Some(worker),
            Err(_) => {
                let mut state = state.lock().unwrap_or_else(|e| e.into_inner());
                state.sender.take();
                state.status.accepting = false;
                state.status.last_error = Some("telemetry writer unavailable".into());
                None
            }
        };
        Self {
            state,
            worker: Mutex::new(worker),
            max_bytes,
        }
    }
    pub(super) fn admit(
        &self,
        label: &'static str,
        bytes: usize,
        job: Job,
    ) -> Result<(), AdmissionError> {
        let mut state = self.state.lock().unwrap_or_else(|e| e.into_inner());
        let worker_exited = state.status.accepting
            && self
                .worker
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .as_ref()
                .is_some_and(|worker| worker.is_finished());
        if worker_exited {
            mark_worker_unavailable(&mut state);
        }
        let error = if worker_exited {
            Some(AdmissionError::WorkerUnavailable)
        } else if !state.status.accepting {
            Some(AdmissionError::Closed)
        } else if bytes > self.max_bytes {
            Some(AdmissionError::Oversize)
        } else if state.status.pending_bytes.saturating_add(bytes) > self.max_bytes {
            Some(AdmissionError::Full)
        } else {
            None
        };
        let result = if let Some(error) = error {
            Err(error)
        } else {
            let result = match state.sender.as_ref() {
                Some(sender) => match sender.try_send(Command { job, bytes, label }) {
                    Ok(()) => Ok(()),
                    Err(mpsc::TrySendError::Full(_)) => Err(AdmissionError::Full),
                    Err(mpsc::TrySendError::Disconnected(command)) => {
                        drop(command);
                        Err(AdmissionError::WorkerUnavailable)
                    }
                },
                None => Err(AdmissionError::WorkerUnavailable),
            };
            if result == Err(AdmissionError::WorkerUnavailable) {
                mark_worker_unavailable(&mut state);
            }
            result
        };
        match result {
            Ok(()) => {
                state.status.accepted = state.status.accepted.saturating_add(1);
                state.status.pending_bytes += bytes;
            }
            Err(error) => {
                state.status.rejected = state.status.rejected.saturating_add(1);
                state.status.last_error = Some(if error == AdmissionError::WorkerUnavailable {
                    "telemetry writer unavailable".into()
                } else {
                    format!("telemetry write rejected: {error}")
                });
            }
        }
        result
    }
    pub(super) fn status(&self) -> WriterStatus {
        let mut state = self.state.lock().unwrap_or_else(|e| e.into_inner());
        let worker_exited = state.status.accepting
            && self
                .worker
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .as_ref()
                .is_some_and(|worker| worker.is_finished());
        if worker_exited {
            mark_worker_unavailable(&mut state);
        }
        state.status.clone()
    }
    /// A background-only barrier, useful to readers requiring newly committed
    /// rows. Never called from UI callbacks, paint, or admission methods.
    pub(super) fn flush(&self) -> Result<(), AdmissionError> {
        let (sender, receiver) = mpsc::channel();
        self.admit(
            "flush",
            0,
            Box::new(move |_| {
                let _ = sender.send(());
                Ok(())
            }),
        )?;
        receiver
            .recv()
            .map_err(|_| AdmissionError::WorkerUnavailable)?;
        if self.status().failed > 0 {
            return Err(AdmissionError::PersistenceFailed);
        }
        Ok(())
    }
    pub(super) fn shutdown(&self) -> Option<WriterShutdown> {
        let mut state = self.state.lock().unwrap_or_else(|e| e.into_inner());
        let mut worker = self.worker.lock().unwrap_or_else(|e| e.into_inner());
        if state.status.accepting && worker.as_ref().is_some_and(|worker| worker.is_finished()) {
            mark_worker_unavailable(&mut state);
        }
        state.status.accepting = false;
        state.sender.take();
        worker.take().map(|worker| WriterShutdown {
            worker,
            state: self.state.clone(),
        })
    }
}
impl Drop for Writer {
    fn drop(&mut self) {
        // Closing the only sender wakes recv. Dropping a JoinHandle detaches
        // without blocking UI; normal quit explicitly takes and joins it.
        let mut state = self.state.lock().unwrap_or_else(|e| e.into_inner());
        state.status.accepting = false;
        state.sender.take();
    }
}

pub struct WriterShutdown {
    worker: JoinHandle<WriterStatus>,
    state: Arc<Mutex<State>>,
}
impl WriterShutdown {
    /// Off-UI only; waits for every accepted job and returns truthful failures.
    pub fn finish(self) -> Result<WriterStatus, String> {
        let WriterShutdown { worker, state } = self;
        match worker.join() {
            Ok(status) => {
                let state = state.lock().unwrap_or_else(|e| e.into_inner());
                if state.caught_job_panic {
                    Err("telemetry writer job panicked".into())
                } else {
                    Ok(status)
                }
            }
            Err(_) => {
                let mut state = state.lock().unwrap_or_else(|e| e.into_inner());
                mark_worker_unavailable(&mut state);
                Err("telemetry writer panicked".into())
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn nonblocking_admission_is_bounded_and_shutdown_drains_and_is_idempotent() {
        let store = Arc::new(TelemetryStore::in_memory());
        let writer = Writer::with_limits(store.clone(), 1, 16);
        let (started_tx, started_rx) = mpsc::channel();
        let (release_tx, release_rx) = mpsc::channel();
        writer
            .admit(
                "blocked",
                8,
                Box::new(move |_| {
                    started_tx.send(()).unwrap();
                    release_rx.recv().unwrap();
                    Ok(())
                }),
            )
            .unwrap();
        started_rx.recv().unwrap();
        writer
            .admit(
                "queued",
                8,
                Box::new(|store| {
                    store.execute_raw(
                        "INSERT INTO maintenance_state(name,cursor) VALUES ('ordered_test','yes')",
                    );
                    Ok(())
                }),
            )
            .unwrap();
        assert_eq!(
            writer.admit("full", 1, Box::new(|_| Ok(()))),
            Err(AdmissionError::Full)
        );
        assert_eq!(
            writer.admit("oversize", 17, Box::new(|_| Ok(()))),
            Err(AdmissionError::Oversize)
        );
        let shutdown = writer.shutdown().unwrap();
        assert!(writer.shutdown().is_none());
        assert_eq!(
            writer.admit("closed", 0, Box::new(|_| Ok(()))),
            Err(AdmissionError::Closed)
        );
        release_tx.send(()).unwrap();
        let caller = std::thread::current().id();
        let (thread, status) =
            std::thread::spawn(move || (std::thread::current().id(), shutdown.finish().unwrap()))
                .join()
                .unwrap();
        assert_ne!(caller, thread);
        assert_eq!(status.accepted, 2);
        assert_eq!(status.processed, 2);
        assert_eq!(status.rejected, 3);
        assert_eq!(status.failed, 0);
        assert_eq!(status.pending_bytes, 0);
        assert_eq!(
            store.query_values("SELECT cursor FROM maintenance_state WHERE name='ordered_test'")[0]
                [0],
            rusqlite::types::Value::Text("yes".into())
        );
    }
    #[test]
    fn actual_sql_failure_is_reported_without_preventing_later_drain() {
        let writer = Writer::new(Arc::new(TelemetryStore::in_memory()));
        writer
            .admit(
                "invalid",
                0,
                Box::new(|store| {
                    store
                        .try_execute_test("INSERT INTO missing_owned_table VALUES(1)")
                        .map_err(|e| e.to_string())
                }),
            )
            .unwrap();
        assert_eq!(writer.flush(), Err(AdmissionError::PersistenceFailed));
        let status = writer.shutdown().unwrap().finish().unwrap();
        assert_eq!(status.accepted, 2);
        assert_eq!(status.processed, 2);
        assert_eq!(status.failed, 1);
    }

    #[test]
    fn panicking_job_is_failed_and_later_jobs_still_drain() {
        let store = Arc::new(TelemetryStore::in_memory());
        let writer = Writer::with_limits(store.clone(), 4, 16);
        writer
            .admit("panic_test", 3, Box::new(|_| panic!("owned test panic")))
            .unwrap();
        writer
            .admit(
                "after_panic",
                4,
                Box::new(|store| {
                    store.execute_raw(
                        "INSERT INTO maintenance_state(name,cursor) VALUES ('after_panic','yes')",
                    );
                    Ok(())
                }),
            )
            .unwrap();

        assert_eq!(writer.flush(), Err(AdmissionError::PersistenceFailed));
        assert_eq!(
            writer.shutdown().unwrap().finish().unwrap_err(),
            "telemetry writer job panicked"
        );
        let status = writer.status();
        assert_eq!(status.accepted, 3);
        assert_eq!(status.processed, 3);
        assert_eq!(status.failed, 1);
        assert_eq!(status.pending_bytes, 0);
        assert!(!status.accepting);
        assert_eq!(
            store.query_values("SELECT cursor FROM maintenance_state WHERE name='after_panic'")[0]
                [0],
            rusqlite::types::Value::Text("yes".into())
        );
    }

    #[test]
    fn disconnected_worker_closes_admission_and_accounts_for_pending_jobs() {
        let (release_tx, release_rx) = mpsc::channel();
        let (receiver_dropped_tx, receiver_dropped_rx) = mpsc::channel();
        let writer =
            Writer::with_spawner(Arc::new(TelemetryStore::in_memory()), 2, 16, move |task| {
                Ok(std::thread::spawn(move || {
                    let _ = release_rx.recv();
                    drop(task);
                    let _ = receiver_dropped_tx.send(());
                    WriterStatus::default()
                }))
            });
        writer
            .admit("will_be_abandoned", 7, Box::new(|_| Ok(())))
            .unwrap();

        release_tx.send(()).unwrap();
        receiver_dropped_rx.recv().unwrap();
        assert_eq!(
            writer.admit("after_disconnect", 0, Box::new(|_| Ok(()))),
            Err(AdmissionError::WorkerUnavailable)
        );
        let status = writer.status();
        assert_eq!(status.accepted, 1);
        assert_eq!(status.rejected, 1);
        assert_eq!(status.processed, 1);
        assert_eq!(status.failed, 1);
        assert_eq!(status.pending_bytes, 0);
        assert!(!status.accepting);
        assert_eq!(
            writer.admit("closed", 0, Box::new(|_| Ok(()))),
            Err(AdmissionError::Closed)
        );
        writer.shutdown().unwrap().finish().unwrap();
    }
}
