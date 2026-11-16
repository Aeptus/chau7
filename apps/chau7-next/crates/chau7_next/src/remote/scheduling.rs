//! Remote work deadlines and a bounded event notification mailbox.
use futures::channel::mpsc;
use parking_lot::Mutex;
use std::sync::Arc;
use std::time::{Duration, Instant};

pub(super) const OUTPUT_BATCH: Duration = Duration::from_millis(33);
pub(super) const REFRESH_EVERY: Duration = Duration::from_millis(150);
const AGENT_HEALTH: Duration = Duration::from_secs(1);

/// The first restart of an exited agent waits this long; each further exit
/// in a row doubles the wait, up to [`RESTART_CAP`].
pub(super) const RESTART_BASE: Duration = Duration::from_secs(1);
pub(super) const RESTART_CAP: Duration = Duration::from_secs(60);
/// An agent that ran this long was healthy: its exit starts over at
/// [`RESTART_BASE`].
pub(super) const RESTART_STABLE_AFTER: Duration = Duration::from_secs(60);

/// The agent ended (or failed to start, `uptime` zero) after `failures`
/// earlier failures in a row. Returns the failures to remember and how long
/// to wait before starting it again.
pub(super) fn restart_backoff(failures: u32, uptime: Duration) -> (u32, Duration) {
    let failures = if uptime >= RESTART_STABLE_AFTER {
        0
    } else {
        failures
    };
    let factor = 1u32.checked_shl(failures).unwrap_or(u32::MAX);
    let delay = RESTART_BASE.saturating_mul(factor).min(RESTART_CAP);
    (failures.saturating_add(1), delay)
}

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

/// When pending output is due. The first bytes after a pause (a keystroke's
/// echo, a prompt) go at once; a stream is still batched, one send per
/// [`OUTPUT_BATCH`].
pub(super) fn output_due(now: Instant, last_flush: Option<Instant>) -> Instant {
    last_flush.map_or(now, |at| (at + OUTPUT_BATCH).max(now))
}

/// Disabled remote control has no timer. An enabled agent retains supervision;
/// idle helpers retain one-second metadata refresh. Terminal consumers retain
/// 150ms refresh and only pending output needs 33ms. A scheduled restart is
/// never slept through.
pub(super) fn next_delay(
    now: Instant,
    enabled: bool,
    connected: bool,
    live_terminal: bool,
    last_refresh: Instant,
    output_due: Option<Instant>,
    restart_due: Option<Instant>,
) -> Option<Duration> {
    if !enabled {
        return None;
    }
    let mut delay = AGENT_HEALTH;
    if connected {
        delay =
            delay.min((last_refresh + refresh_every(live_terminal)).saturating_duration_since(now));
    }
    for due in [output_due, restart_due].into_iter().flatten() {
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
        assert_eq!(next_delay(now, false, false, false, now, None, None), None);
        assert_eq!(
            next_delay(now, true, true, false, now, None, None),
            Some(AGENT_HEALTH)
        );
        assert_eq!(
            next_delay(now, true, true, false, now, Some(now + OUTPUT_BATCH), None),
            Some(OUTPUT_BATCH)
        );
        assert_eq!(
            next_delay(now, true, true, false, now - AGENT_HEALTH, None, None),
            Some(Duration::ZERO)
        );
        assert_eq!(
            next_delay(now, true, false, false, now, None, None),
            Some(AGENT_HEALTH)
        );
        assert_eq!(
            next_delay(now, true, true, true, now, None, None),
            Some(REFRESH_EVERY)
        );
        assert_eq!(
            next_delay(now, true, true, true, now, Some(now + OUTPUT_BATCH), None),
            Some(OUTPUT_BATCH)
        );
        assert_eq!(
            next_delay(now, true, true, true, now - REFRESH_EVERY, None, None),
            Some(Duration::ZERO)
        );
        assert_eq!(
            next_delay(now, true, false, false, now, Some(now - OUTPUT_BATCH), None),
            Some(Duration::ZERO)
        );
    }

    #[test]
    fn restart_wait_doubles_to_a_cap_and_starts_over_after_a_stable_run() {
        let crash = Duration::from_secs(2);
        let mut failures = 0;
        let mut waits = Vec::new();
        for _ in 0..9 {
            let (next, wait) = restart_backoff(failures, crash);
            failures = next;
            waits.push(wait.as_secs());
        }
        assert_eq!(waits, [1, 2, 4, 8, 16, 32, 60, 60, 60]);
        assert_eq!(failures, 9);
        // It then stayed up: the next exit is a first failure again.
        assert_eq!(
            restart_backoff(failures, RESTART_STABLE_AFTER),
            (1, RESTART_BASE)
        );
        // Just short of stable keeps backing off.
        assert_eq!(
            restart_backoff(3, RESTART_STABLE_AFTER - Duration::from_millis(1)),
            (4, Duration::from_secs(8))
        );
        // A failed start (no uptime) counts like a crash, and nothing overflows.
        assert_eq!(restart_backoff(0, Duration::ZERO), (1, RESTART_BASE));
        assert_eq!(
            restart_backoff(u32::MAX, Duration::ZERO),
            (u32::MAX, RESTART_CAP)
        );
        assert_eq!(restart_backoff(40, Duration::ZERO), (41, RESTART_CAP));
    }

    #[test]
    fn a_scheduled_restart_is_not_slept_through() {
        let now = Instant::now();
        let soon = now + Duration::from_millis(250);
        assert_eq!(
            next_delay(now, true, false, false, now, None, Some(soon)),
            Some(Duration::from_millis(250))
        );
        assert_eq!(
            next_delay(now, true, false, false, now, None, Some(now - RESTART_BASE)),
            Some(Duration::ZERO)
        );
        // A restart far away keeps the one-second health check.
        assert_eq!(
            next_delay(now, true, false, false, now, None, Some(now + RESTART_CAP)),
            Some(AGENT_HEALTH)
        );
        assert_eq!(
            next_delay(now, false, false, false, now, None, Some(soon)),
            None
        );
    }

    #[test]
    fn first_output_after_a_pause_is_due_at_once_and_a_stream_is_batched() {
        let now = Instant::now();
        assert_eq!(output_due(now, None), now);
        assert_eq!(output_due(now, Some(now - OUTPUT_BATCH * 2)), now);
        let recent = now - Duration::from_millis(10);
        assert_eq!(output_due(now, Some(recent)), recent + OUTPUT_BATCH);
    }

    #[test]
    fn one_minute_idle_helper_requires_sixty_refreshes_instead_of_four_hundred() {
        let start = Instant::now();
        for (live, expected) in [(false, 60), (true, 400)] {
            let mut now = start;
            let mut callbacks = 0;
            while now < start + Duration::from_secs(60) {
                now += next_delay(now, true, true, live, now, None, None).unwrap();
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
