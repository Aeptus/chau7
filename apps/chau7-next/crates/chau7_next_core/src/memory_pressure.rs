//! Current Swift MemoryPressureResponder, TerminalMemoryBudgetPolicy,
//! TabRenderLifecyclePolicy and ScrollbackRetentionPolicy, without UI or OS calls.

use serde::{Deserialize, Serialize};
use std::collections::HashSet;
use std::time::Duration;

pub const PER_TAB_SCROLLBACK_BYTES: u64 = 64 * 1024 * 1024;
pub const PER_TAB_CACHE_BYTES: u64 = 16 * 1024 * 1024;
pub const GLOBAL_CACHE_BYTES: u64 = 64 * 1024 * 1024;
pub const WARM_SCROLLBACK_BYTES: u64 = 500 * 1024 * 1024;
pub const WARM_IDLE_DELAY: Duration = Duration::from_secs(300);
pub const TUI_IDLE_DELAY: Duration = Duration::from_secs(900);
pub const TUI_TIER_LINES: usize = 2000;
pub const HIDDEN_FLOOR_LINES: usize = 50;
pub const MAX_TRACKER_ENTRIES: usize = 5000;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PressureLevel {
    Warning,
    Critical,
}
#[derive(Default, Debug)]
pub struct PressureState {
    last_pressure: Option<Duration>,
    last_critical: Option<Duration>,
    last_self_trigger: Option<Duration>,
}
impl PressureState {
    pub fn record(&mut self, level: PressureLevel, now: Duration) {
        self.last_pressure = Some(now);
        if level == PressureLevel::Critical {
            self.last_critical = Some(now);
        }
    }
    pub fn is_under_pressure(&self, now: Duration) -> bool {
        self.last_pressure
            .is_some_and(|at| now.saturating_sub(at) < Duration::from_secs(90))
    }
    pub fn should_shed_best_effort(&self, now: Duration) -> bool {
        self.last_critical
            .is_some_and(|at| now.saturating_sub(at) < Duration::from_secs(30))
    }
    pub fn check_footprint(
        &mut self,
        used: u64,
        physical: u64,
        now: Duration,
    ) -> Option<PressureLevel> {
        let ceiling = footprint_ceiling(physical);
        if used <= ceiling
            || self
                .last_self_trigger
                .is_some_and(|at| now.saturating_sub(at) < Duration::from_secs(60))
        {
            return None;
        }
        self.last_self_trigger = Some(now);
        let level = if used > ceiling + ceiling / 2 {
            PressureLevel::Critical
        } else {
            PressureLevel::Warning
        };
        self.record(level, now);
        Some(level)
    }
}
pub fn footprint_ceiling(physical: u64) -> u64 {
    (physical / 4).clamp(4 << 30, 12 << 30)
}
pub fn normalized_budget(override_mb: Option<u64>, default: u64) -> u64 {
    override_mb
        .filter(|mb| *mb > 0)
        .map_or(default, |mb| mb.saturating_mul(1024 * 1024))
}
pub fn eviction_indices(bytes: &[u64], protected: &HashSet<usize>, budget: u64) -> Vec<usize> {
    let mut remaining = bytes.iter().copied().fold(0u64, u64::saturating_add);
    let mut candidates: Vec<usize> = (0..bytes.len())
        .filter(|i| bytes[*i] > 0 && !protected.contains(i))
        .collect();
    candidates.sort_by(|a, b| bytes[*b].cmp(&bytes[*a]).then(a.cmp(b)));
    let mut result = Vec::new();
    for i in candidates {
        if remaining <= budget {
            break;
        }
        remaining = remaining.saturating_sub(bytes[i]);
        result.push(i);
    }
    result
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RenderPhase {
    Active,
    PassiveVisible,
    Warm,
    Hidden,
}
impl RenderPhase {
    pub fn visible(self) -> bool {
        matches!(self, Self::Active | Self::PassiveVisible)
    }
}
pub fn render_phase(selected: bool, window_visible: bool, pressure: bool) -> RenderPhase {
    if selected {
        if window_visible {
            RenderPhase::Active
        } else {
            RenderPhase::Warm
        }
    } else if pressure {
        RenderPhase::Hidden
    } else {
        RenderPhase::Warm
    }
}
pub fn configured_lines(lines: usize) -> usize {
    lines.clamp(100, 100_000)
}
pub fn tracker_cap(lines: usize) -> usize {
    lines.clamp(100, MAX_TRACKER_ENTRIES)
}
pub fn ring_capacity(phase: RenderPhase, lines: usize) -> usize {
    if phase == RenderPhase::Hidden {
        HIDDEN_FLOOR_LINES
    } else {
        configured_lines(lines)
    }
}
pub fn should_idle_flush(phase: RenderPhase, armed: Option<u64>, current: Option<u64>) -> bool {
    phase == RenderPhase::Warm && armed.is_some() && armed == current
}
pub fn should_flush(from: RenderPhase, to: RenderPhase) -> bool {
    from != RenderPhase::Hidden && to == RenderPhase::Hidden
}
pub fn should_reload(from: RenderPhase, to: RenderPhase) -> bool {
    from == RenderPhase::Hidden && to != RenderPhase::Hidden
}
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum FlushKind {
    Hidden,
    Idle,
    TuiCompact,
}
#[derive(Clone, Copy, Debug, Serialize, Deserialize)]
pub struct FlushRecord {
    pub kind: FlushKind,
    pub bytes_received: Option<u64>,
}
impl FlushRecord {
    pub fn output_arrived(self, current: Option<u64>) -> bool {
        match (self.bytes_received, current) {
            (Some(before), Some(now)) => before != now,
            (None, None) => false,
            _ => true,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn pressure_and_best_effort_hints_expire_without_an_os_normal_signal() {
        let mut state = PressureState::default();
        state.record(PressureLevel::Critical, Duration::ZERO);
        assert!(state.should_shed_best_effort(Duration::from_secs(29)));
        assert!(!state.should_shed_best_effort(Duration::from_secs(30)));
        assert!(state.is_under_pressure(Duration::from_secs(89)));
        assert!(!state.is_under_pressure(Duration::from_secs(90)));
    }
    #[test]
    fn footprint_ceiling_escalation_and_cooldown_match_swift() {
        assert_eq!(footprint_ceiling(8 << 30), 4 << 30);
        assert_eq!(footprint_ceiling(32 << 30), 8 << 30);
        assert_eq!(footprint_ceiling(128 << 30), 12 << 30);
        let mut state = PressureState::default();
        assert_eq!(
            state.check_footprint(5 << 30, 8 << 30, Duration::ZERO),
            Some(PressureLevel::Warning)
        );
        assert_eq!(
            state.check_footprint(7 << 30, 8 << 30, Duration::from_secs(59)),
            None
        );
        assert_eq!(
            state.check_footprint(7 << 30, 8 << 30, Duration::from_secs(60)),
            Some(PressureLevel::Critical)
        );
    }
    #[test]
    fn selected_visible_panes_remain_active_under_pressure() {
        assert_eq!(render_phase(true, true, true), RenderPhase::Active);
        assert_eq!(render_phase(true, false, true), RenderPhase::Warm);
        assert_eq!(render_phase(false, true, false), RenderPhase::Warm);
        assert_eq!(render_phase(false, true, true), RenderPhase::Hidden);
    }
    #[test]
    fn largest_cold_caches_are_evicted_first_and_selected_panes_are_protected() {
        assert_eq!(
            eviction_indices(&[10, 30, 30, 100], &HashSet::from([3]), 140),
            vec![1]
        );
        assert_eq!(
            eviction_indices(&[10, 30, 30, 100], &HashSet::from([3]), 0),
            vec![1, 2, 0]
        );
        assert_eq!(normalized_budget(Some(0), 42), 42);
        assert_eq!(normalized_budget(Some(4), 42), 4 * 1024 * 1024);
    }
    #[test]
    fn idle_flush_fails_closed_without_counters_and_tracks_the_post_flush_seam() {
        assert!(!should_idle_flush(RenderPhase::Warm, None, None));
        assert!(!should_idle_flush(RenderPhase::Active, Some(2), Some(2)));
        assert!(!should_idle_flush(RenderPhase::Warm, Some(2), Some(3)));
        assert!(should_idle_flush(RenderPhase::Warm, Some(2), Some(2)));
        let record = FlushRecord {
            kind: FlushKind::Idle,
            bytes_received: Some(2),
        };
        assert!(!record.output_arrived(Some(2)));
        assert!(record.output_arrived(Some(3)));
        assert!(record.output_arrived(None));
        assert_eq!(tracker_cap(100_000), 5000);
        assert_eq!(ring_capacity(RenderPhase::Hidden, 10000), 50);
    }
}
