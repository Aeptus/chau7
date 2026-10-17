//! Process resources of a tab (`ProcessResourceMonitor.swift`): CPU and
//! memory of the shell's descendants, sorted by CPU. Swift parses
//! `ps -axo pid,ppid,rss,%cpu,comm`; Chau7 Next asks the OS directly
//! (`platform::process`) and computes CPU from two samples.
//!
//! Polled only while the hover card is shown: 0.75 s, backing off by 1.8x
//! per empty poll up to 3 s (`MonitoringSchedule.nextPollInterval`).

use std::collections::HashMap;
use std::time::{Duration, Instant};

use chau7_next_core::notifications::schedule::{
    DEFAULT_MAX_CONSECUTIVE_NO_DATA_POLLS, next_poll_interval_default,
};

use crate::platform::process as procinfo;

/// `ProcessGroupSnapshot`: the shell's descendants, by CPU.
#[derive(Debug, Clone, Default)]
pub struct ProcessSnapshot {
    pub children: Vec<ProcessRow>,
}

/// `ProcessResourceInfo`.
#[derive(Debug, Clone)]
pub struct ProcessRow {
    pub pid: u32,
    pub name: String,
    pub cpu_percent: f64,
    pub rss_bytes: u64,
}

impl ProcessSnapshot {
    pub fn total_cpu(&self) -> f64 {
        self.children.iter().map(|c| c.cpu_percent).sum()
    }

    pub fn total_rss(&self) -> u64 {
        self.children.iter().map(|c| c.rss_bytes).sum()
    }
}

/// CPU time samples between two polls, for CPU percentages.
pub type CpuSamples = HashMap<u32, (Duration, Instant)>;

/// Samples the shell's descendants (`captureSnapshot`).
pub fn sample(shell_pid: u32, previous: &mut CpuSamples) -> ProcessSnapshot {
    let now = Instant::now();
    let mut children = Vec::new();
    let mut next = CpuSamples::new();
    for pid in procinfo::process_tree(shell_pid).into_iter().skip(1) {
        let Some(usage) = procinfo::process_usage(pid) else {
            continue;
        };
        let cpu_percent = previous
            .get(&pid)
            .map(|(cpu, at)| {
                let wall = now.duration_since(*at).as_secs_f64();
                if wall > 0.0 {
                    usage.cpu_time.saturating_sub(*cpu).as_secs_f64() / wall * 100.0
                } else {
                    0.0
                }
            })
            .unwrap_or(0.0);
        next.insert(pid, (usage.cpu_time, now));
        children.push(ProcessRow {
            pid,
            name: procinfo::process_name(pid).unwrap_or_else(|| pid.to_string()),
            cpu_percent,
            rss_bytes: usage.resident_bytes,
        });
    }
    *previous = next;
    children.sort_by(|a, b| b.cpu_percent.total_cmp(&a.cpu_percent));
    ProcessSnapshot { children }
}

/// Poll back-off state (`consecutiveNoDataPolls`).
#[derive(Debug, Default, Clone, Copy)]
pub struct PollSchedule {
    empty_polls: i64,
}

impl PollSchedule {
    /// Records a poll and returns the delay before the next one.
    pub fn after_poll(&mut self, snapshot: &ProcessSnapshot) -> Duration {
        if snapshot.children.is_empty() {
            self.empty_polls = (self.empty_polls + 1).min(DEFAULT_MAX_CONSECUTIVE_NO_DATA_POLLS);
        } else {
            self.empty_polls = 0;
        }
        Duration::from_secs_f64(next_poll_interval_default(self.empty_polls))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn schedule_backs_off_when_empty() {
        let mut s = PollSchedule::default();
        let empty = ProcessSnapshot::default();
        let first = s.after_poll(&empty);
        assert!(first > Duration::from_millis(750));
        for _ in 0..10 {
            s.after_poll(&empty);
        }
        assert_eq!(s.after_poll(&empty), Duration::from_secs(3));
        let busy = ProcessSnapshot {
            children: vec![ProcessRow {
                pid: 1,
                name: "x".into(),
                cpu_percent: 1.0,
                rss_bytes: 2,
            }],
        };
        assert_eq!(s.after_poll(&busy), Duration::from_millis(750));
        assert_eq!(busy.total_rss(), 2);
    }
}
