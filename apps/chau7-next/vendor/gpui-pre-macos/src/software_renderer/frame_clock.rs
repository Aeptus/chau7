//! A bounded demand clock, not a periodic frame source.
use std::time::{Duration, Instant};

const MIN_INTERVAL: Duration = Duration::from_micros(16_667);

#[derive(Default)]
pub(crate) struct DemandClock {
    pending: bool,
    last_delivery: Option<Instant>,
}

impl DemandClock {
    /// Only the first outstanding demand queues a task. A delivered but
    /// throttled frame can request a new bounded wake without losing demand.
    pub(crate) fn request(&mut self, now: Instant) -> Option<Duration> {
        if self.pending {
            return None;
        }
        self.pending = true;
        Some(self.last_delivery.map_or(Duration::ZERO, |last| {
            MIN_INTERVAL.saturating_sub(now.saturating_duration_since(last))
        }))
    }

    /// Release the pending slot before invoking native callbacks, which can
    /// synchronously request another wake when demand remains after throttling.
    pub(crate) fn delivered(&mut self, now: Instant) {
        self.pending = false;
        self.last_delivery = Some(now);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{
        cell::RefCell,
        rc::Rc,
        sync::{
            Arc,
            atomic::{AtomicBool, Ordering},
        },
    };

    #[test]
    fn coalesces_and_caps_delivery_without_an_idle_tick() {
        let now = Instant::now();
        let mut clock = DemandClock::default();
        assert_eq!(clock.request(now), Some(Duration::ZERO));
        for _ in 0..10_000 {
            assert_eq!(clock.request(now), None);
        }
        clock.delivered(now);
        assert!(!clock.pending);
        assert_eq!(
            clock.request(now + Duration::from_millis(1)),
            Some(MIN_INTERVAL - Duration::from_millis(1))
        );
        clock.delivered(now + MIN_INTERVAL);
        assert_eq!(clock.request(now + MIN_INTERVAL * 2), Some(Duration::ZERO));
    }

    #[test]
    fn throttle_retry_remains_bounded_and_demand_is_not_lost() {
        let start = Instant::now();
        let mut clock = DemandClock::default();
        clock.request(start).unwrap();
        for frame in 0..10_000 {
            let at = start + MIN_INTERVAL * frame;
            clock.delivered(at);
            assert_eq!(clock.request(at), Some(MIN_INTERVAL));
            assert_eq!(clock.request(at), None);
        }
    }

    #[test]
    fn queued_wake_keeps_only_weak_window_ownership_and_honors_close() {
        let owner = Arc::new(());
        let weak = Arc::downgrade(&owner);
        let closed = Arc::new(AtomicBool::new(false));
        let clock = Rc::new(RefCell::new(DemandClock::default()));
        clock.borrow_mut().request(Instant::now()).unwrap();
        let wake = {
            let closed = closed.clone();
            move || {
                clock.borrow_mut().delivered(Instant::now());
                !closed.load(Ordering::Acquire) && weak.upgrade().is_some()
            }
        };
        assert_eq!(Arc::strong_count(&owner), 1);
        closed.store(true, Ordering::Release);
        assert!(!wake());
        closed.store(false, Ordering::Release);
        drop(owner);
        assert!(!wake());
    }
}
