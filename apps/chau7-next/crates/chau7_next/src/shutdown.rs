//! Quit progress has fixed phase labels and numeric timing only.
//!
//! A later successful phase never erases an earlier failure. This is an
//! explicit-close report, not a guarantee against crashes or forced exits.
use std::{thread::JoinHandle, time::Instant};

#[derive(Clone, Copy)]
#[repr(u8)]
pub(crate) enum Phase {
    Producers,
    Performance,
    Watchdog,
    Observability,
    Restore,
    Cto,
    Telemetry,
    History,
    Incidents,
    CleanMarker,
}
impl Phase {
    fn name(self) -> &'static str {
        match self {
            Self::Producers => "producer_stop_requested",
            Self::Performance => "performance_joined",
            Self::Watchdog => "watchdog_joined",
            Self::Observability => "observability_joined",
            Self::Restore => "restore_drained",
            Self::Cto => "cto_joined",
            Self::Telemetry => "telemetry_closed",
            Self::History => "history_drained",
            Self::Incidents => "incidents_joined",
            Self::CleanMarker => "clean_marker",
        }
    }
}

pub(crate) struct Progress {
    started: Instant,
    failed: u32,
    completed: u32,
    completed_phases: u16,
}
impl Progress {
    pub(crate) fn new() -> Self {
        Self {
            started: Instant::now(),
            failed: 0,
            completed: 0,
            completed_phases: 0,
        }
    }

    pub(crate) fn complete(&mut self, phase: Phase, succeeded: bool) {
        let bit = 1_u16 << (phase as u8);
        let succeeded = succeeded && self.completed_phases & bit == 0;
        self.completed_phases |= bit;
        self.completed += 1;
        self.failed += u32::from(!succeeded);
        log::info!(
            "Shutdown phase={} elapsed_us={} succeeded={} completed={} failed={}",
            phase.name(),
            self.started.elapsed().as_micros(),
            succeeded,
            self.completed,
            self.failed
        );
    }

    pub(crate) fn can_mark_clean(&self) -> bool {
        // Every phase before CleanMarker must complete successfully once.
        let required = (1_u16 << (Phase::CleanMarker as u8)) - 1;
        self.failed == 0 && self.completed_phases & required == required
    }
}

pub(crate) fn join_worker<T>(worker: Option<JoinHandle<T>>) -> Result<Option<T>, &'static str> {
    worker
        .map(JoinHandle::join)
        .transpose()
        .map_err(|_| "quit worker panicked")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn later_success_never_erases_a_failed_phase() {
        let phases = [
            Phase::Producers,
            Phase::Performance,
            Phase::Watchdog,
            Phase::Observability,
            Phase::Restore,
            Phase::Cto,
            Phase::Telemetry,
            Phase::History,
            Phase::Incidents,
        ];
        for failed_index in 0..phases.len() {
            let mut progress = Progress::new();
            for (index, phase) in phases.iter().enumerate() {
                progress.complete(*phase, index != failed_index);
            }
            assert!(!progress.can_mark_clean());
            assert_eq!(progress.failed, 1);
            assert_eq!(progress.completed, phases.len() as u32);
        }
    }

    #[test]
    fn successful_phases_allow_a_clean_marker() {
        let mut progress = Progress::new();
        for phase in required_phases() {
            progress.complete(phase, true);
        }
        assert!(progress.can_mark_clean());
        progress.complete(Phase::CleanMarker, false);
        assert!(!progress.can_mark_clean());
    }

    fn required_phases() -> [Phase; 9] {
        [
            Phase::Producers,
            Phase::Performance,
            Phase::Watchdog,
            Phase::Observability,
            Phase::Restore,
            Phase::Cto,
            Phase::Telemetry,
            Phase::History,
            Phase::Incidents,
        ]
    }

    #[test]
    fn every_required_phase_must_finish_before_a_clean_marker() {
        for omitted in 0..required_phases().len() {
            let mut progress = Progress::new();
            for (index, phase) in required_phases().into_iter().enumerate() {
                if index != omitted {
                    progress.complete(phase, true);
                }
            }
            assert!(!progress.can_mark_clean());
        }
    }

    #[test]
    fn repeated_phase_cannot_mask_an_incomplete_or_failed_shutdown() {
        let mut progress = Progress::new();
        for phase in required_phases() {
            progress.complete(phase, true);
        }
        progress.complete(Phase::Telemetry, true);
        assert!(!progress.can_mark_clean());
        assert_eq!(progress.failed, 1);
    }

    #[test]
    fn absent_worker_is_not_a_failed_close() {
        assert_eq!(join_worker::<u32>(None), Ok(None));
    }

    #[test]
    fn worker_result_is_retained_until_joined() {
        assert_eq!(join_worker(Some(std::thread::spawn(|| 42))), Ok(Some(42)));
    }

    #[test]
    fn panic_is_an_explicit_failed_join() {
        let worker = std::thread::spawn(|| panic!("synthetic quit worker"));
        assert_eq!(join_worker(Some(worker)), Err("quit worker panicked"));
    }
}
