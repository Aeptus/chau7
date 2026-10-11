//! The timing rules of `Events/AppEventEmitter.swift`: when a scheduled
//! event fires next, when the inactivity event fires, and the memory
//! threshold with its hysteresis and 5 minute throttle. The app runs the
//! timers and emits the events (`source` app, tool `App`).

use std::time::{Duration, Instant};

use chrono::{DateTime, Local, NaiveTime, TimeZone, Timelike};

use super::settings::{ScheduleType, ScheduledEvent};

/// First delay and repeat interval of a schedule (`calculateSchedule`).
pub fn schedule_delays(event: &ScheduledEvent, now: DateTime<Local>) -> (Duration, Duration) {
    match event.schedule_type {
        ScheduleType::Interval => {
            let secs = (event.interval_minutes.max(0) as u64) * 60;
            (Duration::from_secs(secs), Duration::from_secs(secs))
        }
        ScheduleType::Daily => {
            let (h, m) = event.daily_hour_minute();
            let day = Duration::from_secs(24 * 60 * 60);
            let target_time = NaiveTime::from_hms_opt(h, m, 0).unwrap_or_default();
            let today = now.date_naive().and_time(target_time);
            let next = match Local.from_local_datetime(&today).earliest() {
                Some(t) if t > now => Some(t),
                Some(t) => Local
                    .from_local_datetime(&(t.naive_local() + chrono::Duration::days(1)))
                    .earliest(),
                None => None,
            };
            let delay = next
                .map(|n| (n - now).num_seconds().max(1) as u64)
                .unwrap_or(24 * 60 * 60);
            (Duration::from_secs(delay), day)
        }
        ScheduleType::Hourly => {
            let mut minutes = event.hourly_minute - now.minute() as i64;
            if minutes <= 0 {
                minutes += 60;
            }
            (
                Duration::from_secs(minutes as u64 * 60),
                Duration::from_secs(60 * 60),
            )
        }
    }
}

/// Inactivity check, run every minute (`checkInactivity`).
#[derive(Debug, Clone)]
pub struct InactivityTracker {
    last_activity: Instant,
    emitted: bool,
}

impl InactivityTracker {
    pub fn new(now: Instant) -> Self {
        Self {
            last_activity: now,
            emitted: false,
        }
    }

    /// Typing or running a command (`recordActivity`).
    pub fn record_activity(&mut self, now: Instant) {
        self.last_activity = now;
        self.emitted = false;
    }

    /// The event message when the threshold is crossed (once until the next
    /// activity).
    pub fn check(&mut self, threshold_minutes: i64, now: Instant) -> Option<String> {
        if self.emitted || threshold_minutes <= 0 {
            return None;
        }
        let elapsed = now.saturating_duration_since(self.last_activity).as_secs();
        if elapsed as i64 >= threshold_minutes * 60 {
            self.emitted = true;
            return Some(format!("No activity for {} minutes", elapsed / 60));
        }
        None
    }
}

/// Memory threshold check, run every 30 s (`checkMemory`).
#[derive(Debug, Clone)]
pub struct MemoryMonitor {
    dropped_below_hysteresis: bool,
    last_warning: Option<Instant>,
}

impl Default for MemoryMonitor {
    fn default() -> Self {
        Self {
            dropped_below_hysteresis: true,
            last_warning: None,
        }
    }
}

impl MemoryMonitor {
    /// The event message when memory crossed the threshold.
    pub fn check(
        &mut self,
        memory_mb: i64,
        threshold_mb: i64,
        hysteresis_mb: i64,
        now: Instant,
    ) -> Option<String> {
        let rearm = (threshold_mb - hysteresis_mb).max(0);
        if memory_mb < rearm {
            self.dropped_below_hysteresis = true;
        }
        if memory_mb < threshold_mb || !self.dropped_below_hysteresis {
            return None;
        }
        if let Some(last) = self.last_warning
            && now.saturating_duration_since(last) < Duration::from_secs(300)
        {
            return None;
        }
        self.dropped_below_hysteresis = false;
        self.last_warning = Some(now);
        Some(format!(
            "Memory usage: {memory_mb}MB (threshold: {threshold_mb}MB)"
        ))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn at(h: u32, m: u32, s: u32) -> DateTime<Local> {
        Local
            .with_ymd_and_hms(2026, 3, 10, h, m, s)
            .earliest()
            .unwrap()
    }

    #[test]
    fn interval_schedule() {
        let e = ScheduledEvent {
            interval_minutes: 15,
            ..Default::default()
        };
        assert_eq!(
            schedule_delays(&e, at(10, 0, 0)),
            (Duration::from_secs(900), Duration::from_secs(900))
        );
    }

    #[test]
    fn daily_schedule() {
        let mut e = ScheduledEvent {
            schedule_type: ScheduleType::Daily,
            daily_time: "10:30".into(),
            ..Default::default()
        };
        let (first, repeat) = schedule_delays(&e, at(10, 0, 0));
        assert_eq!(first, Duration::from_secs(1800));
        assert_eq!(repeat, Duration::from_secs(86_400));
        e.daily_time = "09:00".into();
        let (first, _) = schedule_delays(&e, at(10, 0, 0));
        assert_eq!(first, Duration::from_secs(23 * 3600));
    }

    #[test]
    fn hourly_schedule() {
        let mut e = ScheduledEvent {
            schedule_type: ScheduleType::Hourly,
            hourly_minute: 15,
            ..Default::default()
        };
        assert_eq!(
            schedule_delays(&e, at(10, 5, 30)).0,
            Duration::from_secs(600)
        );
        e.hourly_minute = 5;
        assert_eq!(
            schedule_delays(&e, at(10, 5, 30)).0,
            Duration::from_secs(3600)
        );
    }

    #[test]
    fn inactivity_fires_once_until_activity() {
        let t0 = Instant::now();
        let mut t = InactivityTracker::new(t0);
        assert_eq!(t.check(2, t0 + Duration::from_secs(60)), None);
        assert_eq!(
            t.check(2, t0 + Duration::from_secs(125)).as_deref(),
            Some("No activity for 2 minutes")
        );
        assert_eq!(t.check(2, t0 + Duration::from_secs(400)), None);
        t.record_activity(t0 + Duration::from_secs(400));
        assert!(t.check(2, t0 + Duration::from_secs(530)).is_some());
        assert_eq!(t.check(0, t0 + Duration::from_secs(9999)), None);
    }

    #[test]
    fn memory_hysteresis_and_throttle() {
        let t0 = Instant::now();
        let mut m = MemoryMonitor::default();
        assert_eq!(m.check(100, 500, 50, t0), None);
        assert_eq!(
            m.check(600, 500, 50, t0).as_deref(),
            Some("Memory usage: 600MB (threshold: 500MB)")
        );
        // Still above: no repeat.
        assert_eq!(m.check(600, 500, 50, t0 + Duration::from_secs(600)), None);
        // Dropped below 450 re-arms, but the 5 minute throttle applies.
        assert_eq!(m.check(400, 500, 50, t0 + Duration::from_secs(10)), None);
        assert_eq!(m.check(600, 500, 50, t0 + Duration::from_secs(20)), None);
        assert!(
            m.check(600, 500, 50, t0 + Duration::from_secs(301))
                .is_some()
        );
    }
}
