//! Refresh cap that follows host CPU load: 120 Hz on a calm machine, 60 Hz
//! above 50% busy, 30 Hz above 90%. A terminal only repaints when output
//! arrives, so this is a ceiling, never a clock.
//!
//! One process-wide sampler reads the host CPU counters once a second. It
//! slows down on the first busy sample and speeds up only after several calm
//! ones, so a load hovering at a threshold does not flap the rate.

use std::sync::OnceLock;
use std::sync::atomic::{AtomicU32, Ordering};
use std::time::Duration;

/// Stored in a session's refresh interval to mean "ask [`interval`]".
pub(super) const ADAPTIVE_NS: u64 = u64::MAX;
/// Output this soon after a keystroke is its echo: paint it without waiting.
pub(super) const ECHO_WINDOW: Duration = Duration::from_millis(150);

const SAMPLE_EVERY: Duration = Duration::from_secs(1);
const CALM_SAMPLES_TO_SPEED_UP: u8 = 3;
const BUSY_60_PERCENT: f32 = 50.0;
const BUSY_30_PERCENT: f32 = 90.0;

static HZ: AtomicU32 = AtomicU32::new(120);
/// Last sampled host busy share in hundredths of a percent; `u32::MAX` before
/// the first sample.
static BUSY_CENTI_PERCENT: AtomicU32 = AtomicU32::new(u32::MAX);

fn rate_for(busy_percent: f32) -> u32 {
    if busy_percent >= BUSY_30_PERCENT {
        30
    } else if busy_percent >= BUSY_60_PERCENT {
        60
    } else {
        120
    }
}

/// The rate decision, separate from sampling so it can be tested.
#[derive(Debug)]
struct Governor {
    hz: u32,
    calm: u8,
}

impl Governor {
    const fn new() -> Self {
        Self { hz: 120, calm: 0 }
    }

    fn observe(&mut self, busy_percent: f32) -> u32 {
        let wanted = rate_for(busy_percent);
        if wanted < self.hz {
            self.hz = wanted;
            self.calm = 0;
        } else if wanted > self.hz {
            self.calm += 1;
            if self.calm >= CALM_SAMPLES_TO_SPEED_UP {
                self.hz = wanted;
                self.calm = 0;
            }
        } else {
            self.calm = 0;
        }
        self.hz
    }
}

/// Cumulative (busy, total) host CPU ticks.
#[cfg(target_os = "macos")]
fn host_ticks() -> Option<(u64, u64)> {
    let mut info = libc::host_cpu_load_info { cpu_ticks: [0; 4] };
    let mut count = libc::HOST_CPU_LOAD_INFO_COUNT;
    // SAFETY: `info` is the structure HOST_CPU_LOAD_INFO fills, and `count`
    // holds its size in integers as the call requires.
    #[allow(deprecated)]
    let result = unsafe {
        libc::host_statistics(
            libc::mach_host_self(),
            libc::HOST_CPU_LOAD_INFO,
            (&raw mut info).cast(),
            &raw mut count,
        )
    };
    if result != libc::KERN_SUCCESS {
        return None;
    }
    let total: u64 = info.cpu_ticks.iter().map(|ticks| u64::from(*ticks)).sum();
    let idle = u64::from(info.cpu_ticks[libc::CPU_STATE_IDLE as usize]);
    Some((total.saturating_sub(idle), total))
}

#[cfg(not(target_os = "macos"))]
fn host_ticks() -> Option<(u64, u64)> {
    None
}

fn busy_percent(before: (u64, u64), after: (u64, u64)) -> Option<f32> {
    let total = after.1.checked_sub(before.1).filter(|total| *total > 0)?;
    let busy = after.0.checked_sub(before.0)?;
    Some(busy as f32 * 100.0 / total as f32)
}

fn start_sampler() {
    static STARTED: OnceLock<()> = OnceLock::new();
    STARTED.get_or_init(|| {
        let spawned = std::thread::Builder::new()
            .name("adaptive-refresh".into())
            .spawn(|| {
                let mut governor = Governor::new();
                let Some(mut before) = host_ticks() else {
                    return;
                };
                loop {
                    std::thread::sleep(SAMPLE_EVERY);
                    let Some(after) = host_ticks() else {
                        return;
                    };
                    if let Some(busy) = busy_percent(before, after) {
                        HZ.store(governor.observe(busy), Ordering::Relaxed);
                        BUSY_CENTI_PERCENT.store((busy * 100.0) as u32, Ordering::Relaxed);
                    }
                    before = after;
                }
            });
        if let Err(error) = spawned {
            log::warn!("adaptive refresh sampler did not start; staying at 120 Hz: {error}");
        }
    });
}

/// A rate pinned by the performance lab, which cannot load the host to
/// reach a tier. Honoured only in isolated test mode.
fn pinned_hz() -> Option<u32> {
    static PINNED: OnceLock<Option<u32>> = OnceLock::new();
    *PINNED.get_or_init(|| {
        if std::env::var("CHAU7_NEXT_ISOLATED_TEST_MODE").as_deref() != Ok("1") {
            return None;
        }
        let hz = std::env::var("CHAU7_NEXT_REFRESH_HZ").ok()?.parse().ok()?;
        [30, 60, 120].contains(&hz).then_some(hz)
    })
}

/// The current cap in Hz: 120, 60 or 30.
pub(super) fn hz() -> u32 {
    if let Some(hz) = pinned_hz() {
        return hz;
    }
    start_sampler();
    HZ.load(Ordering::Relaxed)
}

/// The current minimum time between refreshes.
pub(super) fn interval() -> Duration {
    Duration::from_secs_f64(1.0 / f64::from(hz()))
}

pub(super) fn diagnostics() -> serde_json::Value {
    let busy = BUSY_CENTI_PERCENT.load(Ordering::Relaxed);
    serde_json::json!({
        "hz": pinned_hz().unwrap_or_else(|| HZ.load(Ordering::Relaxed)),
        "pinned": pinned_hz().is_some(),
        "host_busy_percent": (busy != u32::MAX).then(|| f64::from(busy) / 100.0),
        "basis": "host CPU busy share over the last second; 60 Hz from 50%, 30 Hz from 90%",
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_three_rates_exist_and_thresholds_are_inclusive() {
        assert_eq!(rate_for(0.0), 120);
        assert_eq!(rate_for(49.9), 120);
        assert_eq!(rate_for(50.0), 60);
        assert_eq!(rate_for(89.9), 60);
        assert_eq!(rate_for(90.0), 30);
        assert_eq!(rate_for(100.0), 30);
    }

    #[test]
    fn slows_down_at_once_and_speeds_up_only_after_sustained_calm() {
        let mut governor = Governor::new();
        assert_eq!(governor.observe(95.0), 30);
        // Two calm samples are not enough, and a busy one restarts the count.
        assert_eq!(governor.observe(10.0), 30);
        assert_eq!(governor.observe(10.0), 30);
        assert_eq!(governor.observe(95.0), 30);
        assert_eq!(governor.observe(60.0), 30);
        assert_eq!(governor.observe(60.0), 30);
        assert_eq!(governor.observe(60.0), 60);
        assert_eq!(governor.observe(10.0), 60);
        assert_eq!(governor.observe(10.0), 60);
        assert_eq!(governor.observe(10.0), 120);
        assert_eq!(governor.observe(70.0), 60);
    }

    #[test]
    fn busy_share_comes_from_tick_deltas() {
        assert_eq!(busy_percent((100, 1000), (150, 1100)), Some(50.0));
        // No elapsed ticks, or counters that went backwards, give no sample.
        assert_eq!(busy_percent((100, 1000), (100, 1000)), None);
        assert_eq!(busy_percent((100, 1000), (50, 1100)), None);
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn host_counters_are_readable() {
        let (busy, total) = host_ticks().expect("host CPU counters");
        assert!(busy <= total && total > 0);
    }
}
