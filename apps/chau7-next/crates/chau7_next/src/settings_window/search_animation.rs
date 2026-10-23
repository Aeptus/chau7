//! SettingsRootView.swift: 220ms centered easing plus a 120ms retry;
//! SettingsComponents.swift: 180ms highlight easing. Clock values come from
//! GPUI's executor so isolated tests can advance time without sleeping.
use gpui::Pixels;
use std::{
    collections::HashMap,
    time::{Duration, Instant},
};
pub(super) const SCROLL_DURATION: Duration = Duration::from_millis(220);
pub(super) const SCROLL_RETRY: Duration = Duration::from_millis(120);
pub(super) const HIGHLIGHT_DURATION: Duration = Duration::from_millis(180);
fn progress(now: Instant, start: Instant, duration: Duration) -> f32 {
    gpui::ease_in_out(
        (now.saturating_duration_since(start).as_secs_f32() / duration.as_secs_f32()).clamp(0., 1.),
    )
}
#[derive(Clone, Default)]
pub(super) struct Highlights {
    initial: HashMap<&'static str, f32>,
    active: Option<&'static str>,
    start: Option<Instant>,
}
impl Highlights {
    pub(super) fn begin(&mut self, active: Option<&'static str>, now: Instant) {
        if self.active == active {
            return;
        }
        self.initial = self
            .values(now)
            .into_iter()
            .filter(|(_, v)| *v > 0.)
            .collect();
        if let Some(id) = active {
            self.initial.entry(id).or_insert(0.);
        }
        self.active = active;
        self.start = Some(now);
    }
    pub(super) fn values(&self, now: Instant) -> HashMap<&'static str, f32> {
        let delta = self
            .start
            .map_or(1., |start| progress(now, start, HIGHLIGHT_DURATION));
        self.initial
            .iter()
            .map(|(id, from)| {
                let to = if self.active == Some(*id) { 1. } else { 0. };
                (*id, from + (to - from) * delta)
            })
            .collect()
    }
    pub(super) fn finished(&self, now: Instant) -> bool {
        self.start
            .is_none_or(|start| now.saturating_duration_since(start) >= HIGHLIGHT_DURATION)
    }
}
/// Returns whether an actual animation frame is still needed. An existing
/// motion must apply its final value on a real frame before being removed.
pub(super) fn update_motion(
    motion: &mut Option<ScrollMotion>,
    observed: Pixels,
    target: Pixels,
    now: Instant,
) -> bool {
    if let Some(motion) = motion {
        motion.retarget(observed, target, now);
        true
    } else if observed == target {
        false
    } else {
        *motion = Some(ScrollMotion::new(observed, target, now));
        true
    }
}

const SUBPIXEL_RETARGET_LIMIT: f32 = 1.0;

pub(super) struct ScrollMotion {
    from: Pixels,
    to: Pixels,
    start: Instant,
    duration: Duration,
    deadline: Instant,
}
impl ScrollMotion {
    pub(super) fn new(from: Pixels, to: Pixels, start: Instant) -> Self {
        Self::with_duration(from, to, start, SCROLL_DURATION)
    }

    fn with_duration(from: Pixels, to: Pixels, start: Instant, duration: Duration) -> Self {
        Self {
            from,
            to,
            start,
            duration,
            deadline: start + duration,
        }
    }

    fn with_deadline(
        from: Pixels,
        to: Pixels,
        start: Instant,
        duration: Duration,
        deadline: Instant,
    ) -> Self {
        Self {
            from,
            to,
            start,
            duration,
            deadline,
        }
    }

    fn remaining(&self, now: Instant) -> Duration {
        self.deadline.saturating_duration_since(now)
    }

    /// Repeated scrollTo for unchanged layout keeps the in-flight endpoint.
    /// Subpixel target corrections reuse the original deadline; larger moves
    /// get a fresh Swift-length ease from the currently observed offset.
    pub(super) fn retarget(&mut self, from: Pixels, to: Pixels, now: Instant) -> bool {
        if self.to == to {
            return false;
        }

        let target_delta = f32::from(to - self.to).abs();
        if target_delta < SUBPIXEL_RETARGET_LIMIT {
            let deadline = self.deadline;
            let remaining = self.remaining(now);
            *self = Self::with_deadline(from, to, now, remaining, deadline);
        } else {
            *self = Self::new(from, to, now);
        }
        true
    }

    #[cfg(feature = "native-parity-fixture")]
    pub(super) fn diagnostic(&self, origin: Instant, now: Instant) -> serde_json::Value {
        serde_json::json!({
            "from_px": f32::from(self.from),
            "to_px": f32::from(self.to),
            "started_microseconds": self.start.saturating_duration_since(origin).as_micros(),
            "duration_microseconds": self.duration.as_micros(),
            "nominal_duration_microseconds": SCROLL_DURATION.as_micros(),
            "remaining_microseconds": self.remaining(now).as_micros(),
            "ends_microseconds": self.deadline.saturating_duration_since(origin).as_micros(),
            "age_microseconds": now.saturating_duration_since(self.start).as_micros(),
            "finished": self.finished(now),
        })
    }

    pub(super) fn value(&self, now: Instant) -> Pixels {
        if self.duration.is_zero() || self.finished(now) {
            self.to
        } else {
            self.from + (self.to - self.from) * progress(now, self.start, self.duration)
        }
    }

    pub(super) fn finished(&self, now: Instant) -> bool {
        now >= self.deadline
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    use gpui::px;
    #[test]
    fn animation_durations_match_the_settings_motion_spec() {
        assert_eq!(SCROLL_DURATION, Duration::from_millis(220));
        assert_eq!(SCROLL_RETRY, Duration::from_millis(120));
        assert_eq!(HIGHLIGHT_DURATION, Duration::from_millis(180));
    }
    #[test]
    fn highlights_enter_leave_and_interrupt_from_the_observed_value() {
        let start = Instant::now();
        let mut values = Highlights::default();
        values.begin(Some("fontSize"), start);
        assert_eq!(values.values(start)["fontSize"], 0.);
        assert_eq!(
            values.values(start + HIGHLIGHT_DURATION / 2)["fontSize"],
            0.5
        );
        let interrupted = start + HIGHLIGHT_DURATION / 2;
        values.begin(Some("colorScheme"), interrupted);
        assert_eq!(values.values(interrupted)["fontSize"], 0.5);
        assert_eq!(values.values(interrupted)["colorScheme"], 0.);
        let end = interrupted + HIGHLIGHT_DURATION;
        assert_eq!(values.values(end)["fontSize"], 0.);
        assert_eq!(values.values(end)["colorScheme"], 1.);
        values.begin(None, end);
        assert_eq!(values.values(end + HIGHLIGHT_DURATION)["colorScheme"], 0.);
        assert!(values.finished(end + HIGHLIGHT_DURATION));
    }
    #[test]
    fn same_target_retry_and_late_layout_preserve_deadline_and_exact_endpoint() {
        let start = Instant::now();
        let mut motion = ScrollMotion::new(px(0.), px(-500.), start);
        let retry = start + SCROLL_RETRY;
        let observed = motion.value(retry);
        assert_ne!(observed, px(-500.));
        assert!(!motion.retarget(observed, px(-500.), retry));
        let late_layout = start + Duration::from_millis(190);
        assert!(!motion.retarget(motion.value(late_layout), px(-500.), late_layout));
        assert!(!motion.finished(start + SCROLL_DURATION - Duration::from_millis(1)));
        assert!(motion.finished(start + SCROLL_DURATION));
        assert_eq!(motion.value(start + SCROLL_DURATION), px(-500.));
    }

    #[test]
    fn moved_layout_retargets_from_actual_offset_with_full_swift_duration() {
        let start = Instant::now();
        let mut motion = ScrollMotion::new(px(0.), px(-500.), start);
        let moved = start + Duration::from_millis(150);
        let observed = motion.value(moved);
        assert!(motion.retarget(observed, px(-600.), moved));
        assert_eq!(motion.value(moved), observed);
        assert!(!motion.finished(start + SCROLL_DURATION));
        assert!(!motion.finished(moved + SCROLL_DURATION - Duration::from_millis(1)));
        assert!(motion.finished(moved + SCROLL_DURATION));
        assert_eq!(motion.value(moved + SCROLL_DURATION), px(-600.));
    }

    #[test]
    fn production_update_preserves_pending_final_frame_and_skips_exact_applied_endpoint() {
        let start = Instant::now();
        let mut motion = None;
        assert!(!update_motion(&mut motion, px(-500.), px(-500.), start));
        assert!(motion.is_none());
        // No visibility epsilon: a distinct observed position still needs easing.
        assert!(update_motion(&mut motion, px(-499.999), px(-500.), start));
        let end = start + SCROLL_DURATION;
        assert!(update_motion(&mut motion, px(-500.), px(-500.), end));
        assert!(motion.as_ref().unwrap().finished(end));
        assert_eq!(motion.as_ref().unwrap().value(end), px(-500.));
        // Only the real callback clears the motion after applying that endpoint.
        motion = None;
        assert!(!update_motion(&mut motion, px(-500.), px(-500.), end));
        assert!(motion.is_none());
    }

    #[test]
    fn production_update_preserves_same_target_deadline_and_retargets_actual_moves() {
        let start = Instant::now();
        let mut motion = None;
        assert!(update_motion(&mut motion, px(0.), px(-500.), start));
        let retry = start + SCROLL_RETRY;
        let observed = motion.as_ref().unwrap().value(retry);
        assert!(update_motion(&mut motion, observed, px(-500.), retry));
        assert!(motion.as_ref().unwrap().finished(start + SCROLL_DURATION));
        let moved = start + Duration::from_millis(150);
        let observed = motion.as_ref().unwrap().value(moved);
        assert!(update_motion(&mut motion, observed, px(-600.), moved));
        assert_eq!(motion.as_ref().unwrap().value(moved), observed);
        assert!(!motion.as_ref().unwrap().finished(start + SCROLL_DURATION));
        assert!(motion.as_ref().unwrap().finished(moved + SCROLL_DURATION));
        assert_eq!(
            motion.as_ref().unwrap().value(moved + SCROLL_DURATION),
            px(-600.)
        );
    }

    #[test]
    fn subpixel_retarget_is_continuous_and_preserves_original_deadline() {
        let start = Instant::now();
        let mut motion = ScrollMotion::new(px(0.), px(-130.25), start);
        let original_end = start + SCROLL_DURATION;
        let retarget_at = start + Duration::from_millis(100);
        let observed = motion.value(retarget_at);
        let target = px(-130.213_26);

        assert!(f32::from(target - motion.to).abs() < SUBPIXEL_RETARGET_LIMIT);
        assert!(motion.retarget(observed, target, retarget_at));
        assert_eq!(motion.value(retarget_at), observed);
        assert_eq!(motion.duration, original_end.duration_since(retarget_at));
        assert_eq!(motion.deadline, original_end);
        assert!(!motion.finished(original_end - Duration::from_nanos(1)));
        assert!(motion.finished(original_end));
        assert_eq!(motion.value(original_end), target);
    }

    #[test]
    fn subpixel_retargets_preserve_deadline_for_both_drift_directions() {
        for target in [px(-130.213_26), px(-130.286_74)] {
            let start = Instant::now();
            let mut motion = ScrollMotion::new(px(0.), px(-130.25), start);
            let original_end = start + SCROLL_DURATION;
            let retarget_at = start + Duration::from_millis(120);
            let observed = motion.value(retarget_at);

            assert!(f32::from(target - motion.to).abs() < SUBPIXEL_RETARGET_LIMIT);
            assert!(motion.retarget(observed, target, retarget_at));
            assert_eq!(motion.value(retarget_at), observed);
            assert_eq!(motion.deadline, original_end);
            assert_eq!(motion.value(original_end), target);
        }
    }

    #[test]
    fn repeated_subpixel_retargets_keep_the_first_deadline() {
        let start = Instant::now();
        let mut motion = ScrollMotion::new(px(0.), px(-130.25), start);
        let original_end = start + SCROLL_DURATION;
        let first = start + Duration::from_millis(80);
        let observed = motion.value(first);
        assert!(motion.retarget(observed, px(-130.1), first));
        assert_eq!(motion.deadline, original_end);

        let second = start + Duration::from_millis(150);
        let observed = motion.value(second);
        let target = px(-129.8);
        assert!(motion.retarget(observed, target, second));
        assert_eq!(motion.value(second), observed);
        assert_eq!(motion.duration, original_end.duration_since(second));
        assert_eq!(motion.deadline, original_end);
        assert!(!motion.finished(original_end - Duration::from_nanos(1)));
        assert!(motion.finished(original_end));
        assert_eq!(motion.value(original_end), target);
    }

    #[test]
    fn one_pixel_target_move_restarts_full_duration_from_observed_offset() {
        let start = Instant::now();
        let mut motion = ScrollMotion::new(px(0.), px(-130.25), start);
        let retarget_at = start + Duration::from_millis(100);
        let observed = motion.value(retarget_at);
        let target = px(-131.25);

        assert_eq!(f32::from(target - motion.to).abs(), SUBPIXEL_RETARGET_LIMIT);
        assert!(motion.retarget(observed, target, retarget_at));
        assert_eq!(motion.value(retarget_at), observed);
        assert_eq!(motion.start, retarget_at);
        assert_eq!(motion.duration, SCROLL_DURATION);
        assert_eq!(motion.deadline, retarget_at + SCROLL_DURATION);
        assert!(!motion.finished(retarget_at + SCROLL_DURATION - Duration::from_nanos(1)));
        assert!(motion.finished(retarget_at + SCROLL_DURATION));
        assert_eq!(motion.value(retarget_at + SCROLL_DURATION), target);
    }

    #[test]
    fn finished_subpixel_retarget_keeps_deadline_and_requests_exact_final_frame() {
        let start = Instant::now();
        let mut slot = Some(ScrollMotion::new(px(0.), px(-130.25), start));
        let deadline = start + SCROLL_DURATION;
        let late = deadline + Duration::from_millis(7);
        let observed = slot.as_ref().unwrap().value(late);
        let target = px(-130.75);

        assert!(slot.as_ref().unwrap().finished(late));
        assert!(update_motion(&mut slot, observed, target, late));
        let motion = slot.as_ref().unwrap();
        assert_eq!(motion.start, late);
        assert!(motion.duration.is_zero());
        assert_eq!(motion.deadline, deadline);
        assert!(motion.finished(late));
        // The caller still schedules a real frame because retarget returned true;
        // that frame applies this exact endpoint before clearing the motion.
        assert_eq!(motion.value(late), target);
    }

    #[test]
    fn finished_value_returns_exact_endpoint_for_mixed_sign_large_offsets() {
        let start = Instant::now();
        let motion = ScrollMotion::new(px(16_777_216.), px(-1.), start);
        assert_eq!(motion.value(start + SCROLL_DURATION), px(-1.));
        assert_eq!(
            motion.value(start + SCROLL_DURATION + Duration::from_secs(1)),
            px(-1.)
        );
    }

    #[test]
    fn centered_motion_uses_easing_and_reaches_the_exact_target() {
        let start = Instant::now();
        let motion = ScrollMotion::new(px(0.), px(-500.), start);
        assert_eq!(motion.value(start), px(0.));
        assert_eq!(motion.value(start + SCROLL_DURATION / 2), px(-250.));
        assert_eq!(motion.value(start + SCROLL_DURATION), px(-500.));
        assert_eq!(motion.value(start + Duration::from_secs(1)), px(-500.));
        assert!(motion.finished(start + SCROLL_DURATION));
    }
}
