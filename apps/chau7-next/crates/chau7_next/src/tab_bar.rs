//! Tab bar pieces that are independent of the workspace: tab ids, the damped
//! spring used for reorder animations, the drag state machine, and the
//! notification style a tab can carry.
//!
//! Drag behavior follows `Chau7OverlayView.swift`: the dragged tab follows the
//! cursor without animation; the other tabs slide (spring) to make room at the
//! slot given by `TabDragLayout.destinationIndex`; on release outside the
//! window, the drop point is resolved against every window's tab bar frame,
//! then its window frame (`OverlayWindowDropResolver`).

pub use chau7_next_core::tabs_state::TabId;
use gpui::{Hsla, Pixels, Point, px};
use std::collections::HashMap;
use std::time::Instant;

/// Damped spring matching SwiftUI's `spring(response:dampingFraction:)`.
#[derive(Debug, Clone, Copy)]
pub struct Spring {
    pub value: f32,
    pub velocity: f32,
    pub target: f32,
    stiffness: f32,
    damping: f32,
}

impl Spring {
    pub fn new(response: f32, damping_fraction: f32) -> Self {
        let omega = std::f32::consts::TAU / response;
        Self {
            value: 0.0,
            velocity: 0.0,
            target: 0.0,
            stiffness: omega * omega,
            damping: 2.0 * damping_fraction * omega,
        }
    }

    /// Advance by `dt` seconds (semi-implicit Euler, sub-stepped for stability).
    pub fn step(&mut self, dt: f32) {
        let steps = ((dt / 0.004).ceil() as usize).clamp(1, 16);
        let h = dt / steps as f32;
        for _ in 0..steps {
            let accel = -self.stiffness * (self.value - self.target) - self.damping * self.velocity;
            self.velocity += accel * h;
            self.value += self.velocity * h;
        }
    }

    pub fn is_settled(&self) -> bool {
        (self.value - self.target).abs() < 0.25 && self.velocity.abs() < 2.0
    }

    pub fn snap(&mut self) {
        self.value = self.target;
        self.velocity = 0.0;
    }
}

/// Per-tab horizontal offsets animated during a reorder.
#[derive(Debug, Default)]
pub struct TabAnimations {
    springs: HashMap<TabId, Spring>,
    last_tick: Option<Instant>,
}

impl TabAnimations {
    pub fn set_target(&mut self, id: TabId, target: f32) {
        self.springs
            .entry(id)
            .or_insert_with(|| Spring::new(0.25, 0.85))
            .target = target;
    }

    /// Start a spring at `from`, heading to 0.
    pub fn start(&mut self, id: TabId, from: f32, response: f32, damping_fraction: f32) {
        let mut spring = Spring::new(response, damping_fraction);
        spring.value = from;
        self.springs.insert(id, spring);
    }

    pub fn offset(&self, id: TabId) -> f32 {
        self.springs.get(&id).map(|s| s.value).unwrap_or(0.0)
    }

    /// Advance all springs to now. Returns true while something still moves.
    pub fn tick(&mut self) -> bool {
        let now = Instant::now();
        let dt = self
            .last_tick
            .map(|t| (now - t).as_secs_f32())
            .unwrap_or(1.0 / 60.0)
            .min(0.05);
        self.last_tick = Some(now);
        let mut moving = false;
        for spring in self.springs.values_mut() {
            spring.step(dt);
            if spring.is_settled() {
                spring.snap();
            } else {
                moving = true;
            }
        }
        if !moving {
            self.last_tick = None;
            self.springs
                .retain(|_, s| s.target != 0.0 || s.value != 0.0);
        }
        moving
    }

    pub fn reset(&mut self) {
        self.springs.clear();
        self.last_tick = None;
    }
}

/// What is being dragged.
#[derive(Debug, Clone, PartialEq)]
pub enum DragSubject {
    Tab(TabId),
    Group(String),
}

/// A press that may turn into a drag.
#[derive(Debug, Clone)]
pub struct TabDrag {
    pub subject: DragSubject,
    /// Window position where the mouse went down.
    pub start: Point<Pixels>,
    /// Current window position.
    pub current: Point<Pixels>,
    /// Index of the dragged tab (or the group's first tab) in the visible order.
    pub home_index: usize,
    /// Widths of the visible tabs at drag start, in visible order.
    pub widths: Vec<f32>,
    pub ids: Vec<TabId>,
    /// True once the pointer moved past the threshold.
    pub active: bool,
}

/// Pointer travel before a press becomes a drag.
pub const DRAG_THRESHOLD: Pixels = px(4.0);
/// Gap between tabs, used by the slot computation.
pub const TAB_SPACING: f32 = 4.0;

impl TabDrag {
    pub fn translation(&self) -> f32 {
        f32::from(self.current.x - self.start.x)
    }

    /// Destination slot in visible order (`TabDragLayout.destinationIndex`).
    pub fn destination(&self) -> usize {
        chau7_next_core::tab_bar_layout::destination_index(
            self.translation(),
            self.home_index,
            &self.widths,
            TAB_SPACING,
        )
    }

    /// Offsets for the non-dragged tabs so the destination slot opens up.
    pub fn neighbor_offsets(&self) -> Vec<(TabId, f32)> {
        let Some(&dragged_width) = self.widths.get(self.home_index) else {
            return Vec::new();
        };
        let shift = dragged_width + TAB_SPACING;
        let dest = self.destination();
        self.ids
            .iter()
            .enumerate()
            .filter(|(i, _)| *i != self.home_index)
            .map(|(i, id)| {
                let offset = if dest > self.home_index && i > self.home_index && i <= dest {
                    -shift
                } else if dest < self.home_index && i >= dest && i < self.home_index {
                    shift
                } else {
                    0.0
                };
                (*id, offset)
            })
            .collect()
    }
}

/// Visual style a tab can carry (`TabNotificationStyle` in the Swift app),
/// built in `chau7_next_core::tab_style`.
pub use chau7_next_core::tab_style::{
    BorderStyle, StyleColor, TabNotificationStyle as NotificationStyle,
};

/// SwiftUI system colors for a style color; `Primary` is the chrome text.
pub fn style_color(color: StyleColor, primary: Hsla) -> Hsla {
    let rgb = |r: f32, g: f32, b: f32| -> Hsla { gpui::Rgba { r, g, b, a: 1.0 }.into() };
    match color {
        StyleColor::Red => rgb(1.0, 0.27, 0.23),
        StyleColor::Orange => rgb(1.0, 0.62, 0.04),
        StyleColor::Yellow => rgb(1.0, 0.84, 0.04),
        StyleColor::Green => rgb(0.19, 0.82, 0.35),
        StyleColor::Blue => rgb(0.04, 0.52, 1.0),
        StyleColor::Purple => rgb(0.75, 0.35, 0.95),
        StyleColor::Pink => rgb(1.0, 0.22, 0.37),
        StyleColor::Primary => primary,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn spring_settles_on_target() {
        let mut spring = Spring::new(0.25, 0.85);
        spring.target = 100.0;
        let mut t = 0.0;
        while t < 2.0 {
            spring.step(1.0 / 60.0);
            t += 1.0 / 60.0;
        }
        assert!((spring.value - 100.0).abs() < 0.5, "{}", spring.value);
    }

    #[test]
    fn spring_overshoots_little_with_085_damping() {
        let mut spring = Spring::new(0.25, 0.85);
        spring.target = 100.0;
        let mut max: f32 = 0.0;
        for _ in 0..120 {
            spring.step(1.0 / 60.0);
            max = max.max(spring.value);
        }
        assert!(max < 102.0, "overshoot {max}");
    }

    fn drag(translation: f32) -> TabDrag {
        TabDrag {
            subject: DragSubject::Tab(2),
            start: gpui::point(px(100.0), px(10.0)),
            current: gpui::point(px(100.0 + translation), px(10.0)),
            home_index: 1,
            widths: vec![100.0, 100.0, 100.0, 100.0],
            ids: vec![1, 2, 3, 4],
            active: true,
        }
    }

    #[test]
    fn neighbors_shift_toward_the_gap() {
        // Dragged right past the next tab's center: tab 3 slides left.
        let d = drag(120.0);
        assert_eq!(d.destination(), 2);
        let offsets: HashMap<_, _> = d.neighbor_offsets().into_iter().collect();
        assert_eq!(offsets[&3], -(100.0 + TAB_SPACING));
        assert_eq!(offsets[&1], 0.0);
        // Dragged left: tab 1 slides right.
        let d = drag(-120.0);
        assert_eq!(d.destination(), 0);
        let offsets: HashMap<_, _> = d.neighbor_offsets().into_iter().collect();
        assert_eq!(offsets[&1], 100.0 + TAB_SPACING);
    }
}
