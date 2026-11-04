//! Remote work deadlines and a bounded event notification mailbox.
use futures::channel::mpsc;
use parking_lot::Mutex;
use std::sync::Arc;
use std::time::{Duration, Instant};

pub(super) const OUTPUT_BATCH: Duration = Duration::from_millis(33);
pub(super) const REFRESH_EVERY: Duration = Duration::from_millis(150);
const AGENT_HEALTH: Duration = Duration::from_secs(1);

pub(super) fn refresh_every(live_terminal: bool) -> Duration {
    if live_terminal {
        REFRESH_EVERY
    } else {
        AGENT_HEALTH
    }
}

#[derive(Clone)]
pub(super) struct Wake(Arc<Mutex<mpsc::Sender<()>>>);
impl Wake {
    pub(super) fn channel() -> (Self, mpsc::Receiver<()>) {
        let (sender, receiver) = mpsc::channel(1);
        (Self(Arc::new(Mutex::new(sender))), receiver)
    }
    pub(super) fn notify(&self) {
        let _ = self.0.lock().try_send(());
    }
    pub(super) fn callback(&self) -> Arc<dyn Fn() + Send + Sync> {
        let wake = self.clone();
        Arc::new(move || wake.notify())
    }
}

/// Disabled remote control has no timer. An enabled agent retains supervision;
/// idle helpers retain one-second metadata refresh. Terminal consumers retain
/// 150ms refresh and only pending output needs 33ms.
pub(super) fn next_delay(
    now: Instant,
    enabled: bool,
    connected: bool,
    live_terminal: bool,
    last_refresh: Instant,
    output_due: Option<Instant>,
) -> Option<Duration> {
    if !enabled {
        return None;
    }
    let mut delay = AGENT_HEALTH;
    if connected {
        delay =
            delay.min((last_refresh + refresh_every(live_terminal)).saturating_duration_since(now));
    }
    if let Some(due) = output_due {
        delay = delay.min(due.saturating_duration_since(now));
    }
    Some(delay)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn idle_has_no_batch_poll_but_live_deadlines_remain() {
        let now = Instant::now();
        assert_eq!(next_delay(now, false, false, false, now, None), None);
        assert_eq!(
            next_delay(now, true, true, false, now, None),
            Some(AGENT_HEALTH)
        );
        assert_eq!(
            next_delay(now, true, true, false, now, Some(now + OUTPUT_BATCH)),
            Some(OUTPUT_BATCH)
        );
        assert_eq!(
            next_delay(now, true, true, false, now - AGENT_HEALTH, None),
            Some(Duration::ZERO)
        );
        assert_eq!(
            next_delay(now, true, false, false, now, None),
            Some(AGENT_HEALTH)
        );
        assert_eq!(
            next_delay(now, true, true, true, now, None),
            Some(REFRESH_EVERY)
        );
        assert_eq!(
            next_delay(now, true, true, true, now, Some(now + OUTPUT_BATCH)),
            Some(OUTPUT_BATCH)
        );
        assert_eq!(
            next_delay(now, true, true, true, now - REFRESH_EVERY, None),
            Some(Duration::ZERO)
        );
        assert_eq!(
            next_delay(now, true, false, false, now, Some(now - OUTPUT_BATCH)),
            Some(Duration::ZERO)
        );
    }

    #[test]
    fn one_minute_idle_helper_requires_sixty_refreshes_instead_of_four_hundred() {
        let start = Instant::now();
        for (live, expected) in [(false, 60), (true, 400)] {
            let mut now = start;
            let mut callbacks = 0;
            while now < start + Duration::from_secs(60) {
                now += next_delay(now, true, true, live, now, None).unwrap();
                callbacks += 1;
            }
            assert_eq!(callbacks, expected);
        }
    }
    #[test]
    fn notifications_coalesce_and_rearm_without_polling() {
        use futures::{FutureExt, StreamExt};
        let (wake, mut receiver) = Wake::channel();
        assert!(receiver.next().now_or_never().is_none());
        let callback = wake.callback();
        for _ in 0..10000 {
            callback();
        }
        let mut tokens = 0;
        while receiver.try_recv().is_ok() {
            tokens += 1;
        }
        // futures mpsc retains the buffer plus its single sender reservation.
        assert!((1..=2).contains(&tokens));
        assert!(receiver.next().now_or_never().is_none());
        callback();
        assert_eq!(receiver.next().now_or_never(), Some(Some(())));
    }
}
