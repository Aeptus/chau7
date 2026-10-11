//! Serial, coalesced diagnostic writes. No filesystem work runs on GPUI.
use crate::observability::{TimerGuard, TimerRegistry};
use chau7_next_core::{
    cto_monitor::state::{self, StateSnapshot},
    cto_wrappers::CtoPaths,
};
use std::{
    sync::{Arc, Condvar, Mutex},
    thread::JoinHandle,
    time::{Duration, Instant},
};
const HEARTBEAT: Duration = Duration::from_secs(300);
enum Action {
    Write(Box<StateSnapshot>),
    Remove,
}
#[derive(Default)]
struct Pending {
    current: Option<StateSnapshot>,
    action: Option<Action>,
    closed: bool,
}
struct Shared {
    pending: Mutex<Pending>,
    wake: Condvar,
}
pub struct StateWriter {
    shared: Arc<Shared>,
    thread: Option<JoinHandle<()>>,
}
impl StateWriter {
    pub fn start(paths: CtoPaths, registry: Option<TimerRegistry>) -> Option<Self> {
        Self::start_with_interval(paths, registry, HEARTBEAT)
    }
    fn start_with_interval(
        paths: CtoPaths,
        registry: Option<TimerRegistry>,
        interval: Duration,
    ) -> Option<Self> {
        let shared = Arc::new(Shared {
            pending: Mutex::new(Pending::default()),
            wake: Condvar::new(),
        });
        let worker = shared.clone();
        match std::thread::Builder::new()
            .name("cto-state-mirror".into())
            .spawn(move || run(worker, paths, registry, interval))
        {
            Ok(thread) => Some(Self {
                shared,
                thread: Some(thread),
            }),
            Err(error) => {
                log::warn!("CTO diagnostic writer could not start: {error}");
                None
            }
        }
    }
    pub fn write(&self, snapshot: StateSnapshot) {
        let mut pending = self
            .shared
            .pending
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        if pending.closed {
            return;
        }
        pending.current = Some(snapshot.clone());
        pending.action = Some(Action::Write(Box::new(snapshot)));
        self.shared.wake.notify_one();
    }
    pub fn remove(&self) {
        let mut pending = self
            .shared
            .pending
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        if pending.closed {
            return;
        }
        pending.current = None;
        pending.action = Some(Action::Remove);
        self.shared.wake.notify_one();
    }
    /// Removal is ordered after in-flight writes; caller joins off the UI thread.
    pub fn shutdown(mut self) -> Option<JoinHandle<()>> {
        self.close();
        self.thread.take()
    }
    fn close(&self) {
        let mut pending = self
            .shared
            .pending
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        pending.current = None;
        pending.action = Some(Action::Remove);
        pending.closed = true;
        self.shared.wake.notify_one();
    }
}
impl Drop for StateWriter {
    fn drop(&mut self) {
        if self.thread.is_some() {
            self.close();
        }
    }
}
fn run(shared: Arc<Shared>, paths: CtoPaths, registry: Option<TimerRegistry>, interval: Duration) {
    let mut timer: Option<TimerGuard> = None;
    let mut due = Instant::now() + interval;
    let mut previous_error = None;
    loop {
        let action = {
            let mut pending = shared.pending.lock().unwrap_or_else(|e| e.into_inner());
            loop {
                if pending.current.is_some() && timer.is_none() {
                    timer = registry.as_ref().map(|r| {
                        r.register(
                            "cto.state_heartbeat",
                            "CTO diagnostic state heartbeat",
                            "cto",
                            interval.as_millis() as u64,
                            "background_thread",
                            "cto-state-mirror",
                        )
                    });
                }
                if pending.current.is_none() {
                    timer = None;
                }
                if let Some(action) = pending.action.take() {
                    due = Instant::now() + interval;
                    break Some(action);
                }
                if pending.closed {
                    break None;
                }
                if pending.current.is_some() {
                    let remaining = due.saturating_duration_since(Instant::now());
                    if remaining.is_zero() {
                        let mut snapshot = pending.current.clone().unwrap();
                        snapshot.updated_at = chrono::Utc::now();
                        pending.current = Some(snapshot.clone());
                        due = Instant::now() + interval;
                        break Some(Action::Write(Box::new(snapshot)));
                    }
                    pending = shared
                        .wake
                        .wait_timeout(pending, remaining)
                        .unwrap_or_else(|e| e.into_inner())
                        .0;
                } else {
                    pending = shared.wake.wait(pending).unwrap_or_else(|e| e.into_inner());
                }
            }
        };
        let Some(action) = action else {
            break;
        };
        let result = match action {
            Action::Write(snapshot) => state::save(&paths, &snapshot),
            Action::Remove => state::remove(&paths),
        };
        match result {
            Ok(()) => previous_error = None,
            Err(error) => {
                if previous_error.as_ref() != Some(&error) {
                    log::warn!("CTO diagnostic state mirror unavailable: {error}");
                }
                previous_error = Some(error);
            }
        }
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    fn sample(mode: &str) -> StateSnapshot {
        serde_json::from_value(serde_json::json!({"mode":mode,"updatedAt":"2026-10-11T12:00:00Z","lastStateChangeAt":"2026-10-11T11:00:00Z","activeSessions":[],"trackedSessions":[],"deferredSessions":[]})).unwrap()
    }
    fn fixture() -> (std::path::PathBuf, CtoPaths) {
        let home = std::env::temp_dir().join(format!("chau7-cto-worker-{}", uuid::Uuid::new_v4()));
        let paths = CtoPaths::from_root(&chau7_next_core::data_root::DataRoot::with_home(
            home.clone(),
            true,
        ));
        (home, paths)
    }
    fn await_snapshot(
        paths: &CtoPaths,
        condition: impl Fn(&StateSnapshot) -> bool,
    ) -> StateSnapshot {
        let deadline = Instant::now() + Duration::from_secs(5);
        loop {
            if let Ok(bytes) = std::fs::read(paths.state_file())
                && let Ok(state) = serde_json::from_slice::<StateSnapshot>(&bytes)
                && condition(&state)
            {
                return state;
            }
            assert!(Instant::now() < deadline, "state writer deadline");
            std::thread::sleep(Duration::from_millis(5));
        }
    }
    #[test]
    fn latest_write_heartbeat_and_shutdown_are_ordered() {
        let (home, paths) = fixture();
        let writer =
            StateWriter::start_with_interval(paths.clone(), None, Duration::from_millis(25))
                .unwrap();
        for _ in 0..100 {
            writer.write(sample("manual"));
        }
        writer.write(sample("aiOnly"));
        let first = await_snapshot(&paths, |s| s.mode == "aiOnly");
        let beat = await_snapshot(&paths, |s| s.updated_at > first.updated_at);
        assert_eq!(beat.last_state_change_at, first.last_state_change_at);
        writer.shutdown().unwrap().join().unwrap();
        assert!(!paths.state_file().exists());
        std::fs::remove_dir_all(home).unwrap();
    }
    #[test]
    fn remove_then_reenable_retains_latest_state_without_busy_wait() {
        let (home, paths) = fixture();
        let writer =
            StateWriter::start_with_interval(paths.clone(), None, Duration::from_millis(25))
                .unwrap();
        writer.write(sample("allTabs"));
        await_snapshot(&paths, |_| true);
        writer.remove();
        writer.write(sample("manual"));
        await_snapshot(&paths, |s| s.mode == "manual");
        writer.shutdown().unwrap().join().unwrap();
        assert!(!paths.state_file().exists());
        std::fs::remove_dir_all(home).unwrap();
    }
}
