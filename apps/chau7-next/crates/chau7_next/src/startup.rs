//! Numeric launch milestones shared by performance diagnostics.
//!
//! Times are elapsed from Rust main() entry. Paint milestones describe
//! CPU-side callbacks and do not guarantee physical display presentation.

use std::collections::HashMap;
use std::sync::atomic::{AtomicU16, Ordering};
use std::sync::{Mutex, OnceLock};
use std::time::Instant;

use serde_json::{Map, Value, json};

#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
#[repr(u16)]
pub enum Stage {
    AppReady = 0,
    SplashPainted = 1,
    ServicesReady = 2,
    WorkspaceOpened = 3,
    TerminalPainted = 4,
    TerminalReady = 5,
    SplashDismissed = 6,
}

impl Stage {
    const ALL: [Self; 7] = [
        Self::AppReady,
        Self::SplashPainted,
        Self::ServicesReady,
        Self::WorkspaceOpened,
        Self::TerminalPainted,
        Self::TerminalReady,
        Self::SplashDismissed,
    ];

    const fn key(self) -> &'static str {
        match self {
            Self::AppReady => "app_ready",
            Self::SplashPainted => "splash_painted",
            Self::ServicesReady => "services_ready",
            Self::WorkspaceOpened => "workspace_opened",
            Self::TerminalPainted => "terminal_painted",
            Self::TerminalReady => "terminal_ready",
            Self::SplashDismissed => "splash_dismissed",
        }
    }

    const fn bit(self) -> u16 {
        1u16 << (self as u16)
    }
}

#[derive(Default)]
struct Tracker {
    milestones: Mutex<HashMap<Stage, u64>>,
    recorded: AtomicU16,
}

impl Tracker {
    fn mark(&self, stage: Stage, elapsed_ms: u64) {
        let bit = stage.bit();
        if self.recorded.load(Ordering::Acquire) & bit != 0 {
            return;
        }

        let mut milestones = self
            .milestones
            .lock()
            .unwrap_or_else(|error| error.into_inner());
        milestones.entry(stage).or_insert(elapsed_ms);
        self.recorded.fetch_or(bit, Ordering::Release);
    }

    fn reached(&self, stage: Stage) -> bool {
        self.recorded.load(Ordering::Acquire) & stage.bit() != 0
    }

    fn snapshot(&self, elapsed_ms: u64) -> Value {
        let milestones = self
            .milestones
            .lock()
            .unwrap_or_else(|error| error.into_inner());
        let mut values = Map::new();
        values.insert("main_entry".into(), json!({"elapsed_ms": 0}));
        for stage in Stage::ALL {
            let value = milestones
                .get(&stage)
                .map(|elapsed_ms| json!({"elapsed_ms": elapsed_ms}))
                .unwrap_or(Value::Null);
            values.insert(stage.key().into(), value);
        }
        json!({
            "basis": "Elapsed from Rust main() entry; paint milestones observe CPU-side paint callbacks and do not guarantee physical display presentation.",
            "elapsed_ms": elapsed_ms,
            "milestones": values,
        })
    }
}

struct Launch {
    started: Instant,
    tracker: Tracker,
}

fn launch() -> &'static Launch {
    static LAUNCH: OnceLock<Launch> = OnceLock::new();
    LAUNCH.get_or_init(|| Launch {
        started: Instant::now(),
        tracker: Tracker::default(),
    })
}

/// Start the monotonic launch clock. Repeated calls preserve the first origin.
pub fn begin() {
    let _ = launch();
}

/// Record the first observed time for a startup stage.
pub fn mark(stage: Stage) {
    let launch = launch();
    if launch.tracker.reached(stage) {
        return;
    }
    let elapsed_ms = launch.started.elapsed().as_millis().min(u64::MAX as u128) as u64;
    launch.tracker.mark(stage, elapsed_ms);
}

/// Whether a stage has been observed at least once.
pub fn reached(stage: Stage) -> bool {
    launch().tracker.reached(stage)
}

/// Return bounded numeric milestones without doing filesystem or provider work.
pub fn snapshot() -> Value {
    let launch = launch();
    let elapsed_ms = launch.started.elapsed().as_millis().min(u64::MAX as u128) as u64;
    launch.tracker.snapshot(elapsed_ms)
}

#[cfg(test)]
mod tests {
    use super::{Stage, Tracker};

    #[test]
    fn tracker_uses_a_distinct_bit_for_every_stage() {
        let tracker = Tracker::default();
        for (index, stage) in Stage::ALL.into_iter().enumerate() {
            assert!(!tracker.reached(stage));
            tracker.mark(stage, index as u64);
            assert!(tracker.reached(stage));
        }

        let snapshot = tracker.snapshot(9);
        assert_eq!(snapshot["milestones"]["app_ready"]["elapsed_ms"], 0);
        assert_eq!(snapshot["milestones"]["splash_dismissed"]["elapsed_ms"], 6);
    }

    #[test]
    fn tracker_records_first_local_milestone_and_reports_unknown_stages() {
        let tracker = Tracker::default();
        assert!(!tracker.reached(Stage::AppReady));

        tracker.mark(Stage::AppReady, 17);
        tracker.mark(Stage::AppReady, 29);

        assert!(tracker.reached(Stage::AppReady));
        assert!(!tracker.reached(Stage::TerminalReady));
        let snapshot = tracker.snapshot(31);
        assert_eq!(snapshot["elapsed_ms"], 31);
        assert_eq!(snapshot["milestones"]["main_entry"]["elapsed_ms"], 0);
        assert_eq!(snapshot["milestones"]["app_ready"]["elapsed_ms"], 17);
        assert!(snapshot["milestones"]["terminal_ready"].is_null());
        assert!(
            snapshot["basis"]
                .as_str()
                .unwrap()
                .contains("Rust main() entry")
        );
    }
}
