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
pub(super) struct ScrollMotion {
    from: Pixels,
    to: Pixels,
    start: Instant,
}
impl ScrollMotion {
    pub(super) fn new(from: Pixels, to: Pixels, start: Instant) -> Self {
        Self { from, to, start }
    }
    pub(super) fn value(&self, now: Instant) -> Pixels {
        self.from + (self.to - self.from) * progress(now, self.start, SCROLL_DURATION)
    }
    pub(super) fn finished(&self, now: Instant) -> bool {
        now.saturating_duration_since(self.start) >= SCROLL_DURATION
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    use gpui::px;
    #[test]
    fn actual_swift_source_declares_the_animation_durations() {
        let root = include_str!(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../../chau7-macos/Sources/Chau7/Settings/SettingsRootView.swift"
        ));
        let anchors = include_str!(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../../chau7-macos/Sources/Chau7/Settings/SettingsComponents.swift"
        ));
        assert!(root.contains(".easeInOut(duration: 0.22)"));
        assert!(root.contains(".now() + 0.12"));
        assert!(anchors.contains(".easeInOut(duration: 0.18)"));
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
