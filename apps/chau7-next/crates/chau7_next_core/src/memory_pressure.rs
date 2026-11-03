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
    Normal,
    Warning,
    Critical,
}
impl PressureLevel {
    /// Subscribe to recovery as well as warning and critical Dispatch events.
    pub const MACOS_EVENT_MASK: usize = 1 | 2 | 4;

    /// Dispatch may coalesce flags; preserve the highest reported severity.
    /// An empty or unrecognized event must not manufacture a pressure warning.
    pub fn from_macos_flags(flags: usize) -> Option<Self> {
        if flags & 4 != 0 {
            Some(Self::Critical)
        } else if flags & 2 != 0 {
            Some(Self::Warning)
        } else if flags & 1 != 0 {
            Some(Self::Normal)
        } else {
            None
        }
    }
}
#[derive(Default, Debug)]
struct PressureSignal {
    last_pressure: Option<Duration>,
    last_critical: Option<Duration>,
}
impl PressureSignal {
    fn record(&mut self, level: PressureLevel, now: Duration) {
        match level {
            PressureLevel::Normal => *self = Self::default(),
            PressureLevel::Warning => {
                self.last_pressure = Some(now);
                self.last_critical = None;
            }
            PressureLevel::Critical => {
                self.last_pressure = Some(now);
                self.last_critical = Some(now);
            }
        }
    }
    fn is_under_pressure(&self, now: Duration) -> bool {
        self.last_pressure
            .is_some_and(|at| now.saturating_sub(at) < Duration::from_secs(90))
    }
    fn should_shed_best_effort(&self, now: Duration) -> bool {
        self.last_critical
            .is_some_and(|at| now.saturating_sub(at) < Duration::from_secs(30))
    }
}
#[derive(Default, Debug)]
pub struct PressureState {
    system: PressureSignal,
    footprint: PressureSignal,
    last_self_trigger: Option<Duration>,
}
impl PressureState {
    /// A system recovery or downgrade must not clear app-footprint protection.
    pub fn record(&mut self, level: PressureLevel, now: Duration) {
        self.system.record(level, now);
    }
    pub fn is_under_pressure(&self, now: Duration) -> bool {
        self.system.is_under_pressure(now) || self.footprint.is_under_pressure(now)
    }
    pub fn should_shed_best_effort(&self, now: Duration) -> bool {
        self.system.should_shed_best_effort(now) || self.footprint.should_shed_best_effort(now)
    }
    pub fn check_footprint(
        &mut self,
        used: u64,
        physical: u64,
        now: Duration,
    ) -> Option<PressureLevel> {
        let ceiling = footprint_ceiling(physical);
        if used <= ceiling {
            self.footprint = PressureSignal::default();
            self.last_self_trigger = None;
            return None;
        }
        if self
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
        self.footprint.record(level, now);
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
/// Queue admission for the serial retention worker, matching its retention tiers.
pub struct RetentionWork {
    pub phase: RenderPhase,
    pub phase_changed: bool,
    pub archived: bool,
    pub tui: bool,
    pub alternate_screen: bool,
    pub tui_compacted: bool,
    pub idle: Duration,
    pub forced: bool,
}
impl RetentionWork {
    pub fn due(&self) -> bool {
        if self.phase.visible() {
            return if self.archived {
                !self.tui
            } else {
                self.phase_changed
            };
        }
        if self.archived
            || self.tui
                && (self.phase == RenderPhase::Hidden
                    || self.alternate_screen && self.tui_compacted)
        {
            return false;
        }
        self.forced
            || self.phase == RenderPhase::Hidden
            || self.idle
                >= if self.tui {
                    TUI_IDLE_DELAY
                } else {
                    WARM_IDLE_DELAY
                }
    }
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
    fn retention(phase: RenderPhase) -> RetentionWork {
        RetentionWork {
            phase,
            phase_changed: false,
            archived: false,
            tui: false,
            alternate_screen: false,
            tui_compacted: false,
            idle: WARM_IDLE_DELAY,
            forced: false,
        }
    }
    #[test]
    fn retention_admission_skips_archived_background_and_protected_tui() {
        let mut archived = retention(RenderPhase::Warm);
        archived.archived = true;
        archived.forced = true;
        assert!(
            !archived.due(),
            "already archived background history is no work"
        );
        let mut tui = retention(RenderPhase::Warm);
        tui.tui = true;
        assert!(!tui.due(), "TUI retention uses its longer deadline");
        tui.phase = RenderPhase::Hidden;
        tui.phase_changed = true;
        tui.idle = TUI_IDLE_DELAY;
        assert!(
            !tui.due(),
            "hidden TUI is protected even on a phase transition"
        );
    }
    #[test]
    fn retention_admission_keeps_promotion_deadlines_and_backstops() {
        let mut work = retention(RenderPhase::Warm);
        work.idle = WARM_IDLE_DELAY - Duration::from_secs(1);
        assert!(!work.due());
        work.forced = true;
        assert!(work.due());
        work.forced = false;
        work.idle = WARM_IDLE_DELAY;
        assert!(work.due());
        work.tui = true;
        work.idle = TUI_IDLE_DELAY;
        assert!(work.due());
        work.alternate_screen = true;
        work.tui_compacted = true;
        assert!(!work.due(), "alternate-screen compaction is one-shot");
        work.alternate_screen = false;
        assert!(
            work.due(),
            "normal-screen history still needs retention while a TUI runs"
        );
        work.phase = RenderPhase::Active;
        work.phase_changed = true;
        work.tui = false;
        work.archived = true;
        assert!(work.due(), "promotion restores archived history");
        work.phase_changed = false;
        assert!(
            work.due(),
            "failed restore remains eligible for bounded retries"
        );
        work.tui = true;
        assert!(!work.due(), "reload must wait for the TUI to exit");
        work.tui = false;
        work.archived = false;
        assert!(!work.due());
        work.phase_changed = true;
        assert!(work.due(), "visible promotion restores configured capacity");
        work.phase = RenderPhase::Hidden;
        work.phase_changed = false;
        work.idle = Duration::ZERO;
        assert!(work.due(), "pressure hides ordinary history immediately");
    }
    #[test]
    fn macos_subscription_and_decoding_include_recovery_without_false_warnings() {
        assert_eq!(PressureLevel::MACOS_EVENT_MASK, 7);
        assert_eq!(
            PressureLevel::from_macos_flags(1),
            Some(PressureLevel::Normal)
        );
        assert_eq!(
            PressureLevel::from_macos_flags(2),
            Some(PressureLevel::Warning)
        );
        assert_eq!(
            PressureLevel::from_macos_flags(4),
            Some(PressureLevel::Critical)
        );
        assert_eq!(
            PressureLevel::from_macos_flags(7),
            Some(PressureLevel::Critical)
        );
        assert_eq!(
            PressureLevel::from_macos_flags(3),
            Some(PressureLevel::Warning)
        );
        assert_eq!(PressureLevel::from_macos_flags(0), None);
        assert_eq!(PressureLevel::from_macos_flags(8), None);
    }
    #[test]
    fn system_normal_immediately_ends_pressure_and_critical_cache_shedding() {
        for level in [PressureLevel::Warning, PressureLevel::Critical] {
            let mut state = PressureState::default();
            state.record(level, Duration::ZERO);
            assert!(state.is_under_pressure(Duration::from_secs(1)));
            state.record(PressureLevel::Normal, Duration::from_secs(1));
            assert!(!state.is_under_pressure(Duration::from_secs(1)));
            assert!(!state.should_shed_best_effort(Duration::from_secs(1)));
        }
    }
    #[test]
    fn system_warning_ends_critical_shedding_but_keeps_pressure_protection() {
        let mut state = PressureState::default();
        state.record(PressureLevel::Critical, Duration::ZERO);
        state.record(PressureLevel::Warning, Duration::from_secs(1));
        assert!(state.is_under_pressure(Duration::from_secs(1)));
        assert!(!state.should_shed_best_effort(Duration::from_secs(1)));
    }
    #[test]
    fn system_recovery_cannot_clear_independent_high_footprint_protection() {
        let mut state = PressureState::default();
        state.check_footprint(7 << 30, 8 << 30, Duration::ZERO);
        state.record(PressureLevel::Normal, Duration::from_secs(1));
        assert!(state.is_under_pressure(Duration::from_secs(1)));
        assert!(state.should_shed_best_effort(Duration::from_secs(1)));
        // High footprint cannot keep shedding after its own hint expires.
        state.record(PressureLevel::Normal, Duration::from_secs(90));
        assert!(!state.is_under_pressure(Duration::from_secs(90)));
        assert!(!state.should_shed_best_effort(Duration::from_secs(90)));
    }
    #[test]
    fn low_footprint_clears_only_footprint_pressure_and_rearms_its_cooldown() {
        let mut state = PressureState::default();
        state.check_footprint(7 << 30, 8 << 30, Duration::ZERO);
        state.check_footprint(1 << 30, 8 << 30, Duration::from_secs(1));
        assert!(!state.is_under_pressure(Duration::from_secs(1)));
        assert!(!state.should_shed_best_effort(Duration::from_secs(1)));
        assert_eq!(
            state.check_footprint(7 << 30, 8 << 30, Duration::from_secs(2)),
            Some(PressureLevel::Critical)
        );
        state.record(PressureLevel::Warning, Duration::from_secs(3));
        state.check_footprint(1 << 30, 8 << 30, Duration::from_secs(3));
        assert!(state.is_under_pressure(Duration::from_secs(3)));
        assert!(!state.should_shed_best_effort(Duration::from_secs(3)));
    }
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
