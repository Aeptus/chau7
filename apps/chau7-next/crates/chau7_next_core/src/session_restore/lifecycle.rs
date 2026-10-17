//! Current Swift deferred restore, surface reveal and resume delivery policies.
//! These decisions perform no filesystem or terminal I/O.
use std::path::{Component, Path, PathBuf};
use std::time::{Duration, Instant};

pub const SELECTION_QUIET_PERIOD: Duration = Duration::from_millis(450);
pub const REACTIVATION_COALESCING_DELAY: Duration = Duration::from_millis(50);
pub const NEARBY_SNAPSHOT_DISTANCE: usize = 2;

/// Swift TerminalRenderGeometry refuses transient collapsed layouts. The
/// terminal remains at its last authoritative size until both axes recover.
pub fn surface_dimensions(
    width: f32,
    height: f32,
    cell_width: f32,
    cell_height: f32,
) -> Option<(u16, u16)> {
    fn cells(available: f32, cell: f32) -> f32 {
        if !available.is_finite() || !cell.is_finite() || available <= 0.0 || cell <= 0.0 {
            0.0
        } else {
            (available / cell).floor()
        }
    }
    let cols = cells(width, cell_width);
    let rows = cells(height, cell_height);
    (cols > 1.0 && rows > 1.0).then(|| (cols.min(2000.0) as u16, rows.min(500.0) as u16))
}

pub const WINSIZE_NUDGE_DELAYS: [Duration; 2] =
    [Duration::from_millis(700), Duration::from_millis(1800)];
/// Current Swift AIToolRegistry flags these four display names for terminal
/// UI heuristics. Live detection, restore bootstrap and busy lifecycle evidence
/// remain separate from a persisted idle provider label.
pub fn protects_terminal_ui(
    names: &[Option<&str>],
    live: bool,
    bootstrap: bool,
    status: crate::shell_session::CommandStatus,
) -> bool {
    let known = names.iter().flatten().any(|name| {
        let name = name.trim().to_lowercase();
        ["claude", "codex", "gemini", "opencode"]
            .iter()
            .any(|tool| name.contains(tool))
    });
    known
        && (live
            || bootstrap
            || matches!(
                status,
                crate::shell_session::CommandStatus::Running
                    | crate::shell_session::CommandStatus::WaitingForInput
                    | crate::shell_session::CommandStatus::ApprovalRequired
                    | crate::shell_session::CommandStatus::Stuck
            ))
}
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum WinsizeNudgeDecision {
    Keep,
    Cancel,
    Schedule,
}
#[derive(Debug, Clone, Copy, Default)]
pub struct WinsizeNudgeState {
    visible: bool,
    hosts_tui: bool,
    dimensions: Option<(u16, u16)>,
}
impl WinsizeNudgeState {
    pub fn update(
        &mut self,
        visible: bool,
        hosts_tui: bool,
        dimensions: Option<(u16, u16)>,
    ) -> WinsizeNudgeDecision {
        let reveal = visible && hosts_tui && (!self.visible || !self.hosts_tui);
        let resized = dimensions.is_some_and(|size| Some(size) != self.dimensions);
        self.visible = visible;
        self.hosts_tui = hosts_tui;
        if dimensions.is_some() {
            self.dimensions = dimensions;
        }
        if !visible {
            WinsizeNudgeDecision::Cancel
        } else if resized || reveal {
            WinsizeNudgeDecision::Schedule
        } else {
            WinsizeNudgeDecision::Keep
        }
    }
}

pub const PREWARM_DURATION: Duration = Duration::from_secs(2);
pub const PREWARM_EXIT_GRACE: Duration = Duration::from_millis(500);
/// Prewarm is presentation work only. It never changes selection, visibility,
/// restore intent readiness or background terminal state retention.
#[derive(Debug, Clone, Copy, Default)]
pub struct SurfacePrewarm {
    until: Option<Instant>,
    hovering: bool,
}
impl SurfacePrewarm {
    pub fn begin(&mut self, now: Instant) -> bool {
        if self.hovering && self.remaining(now).is_some() {
            return false;
        }
        self.hovering = true;
        self.until = Some(now + PREWARM_DURATION);
        true
    }
    pub fn end(&mut self, now: Instant) {
        self.hovering = false;
        self.until = Some(now + PREWARM_EXIT_GRACE);
    }
    pub fn clear(&mut self) {
        *self = Self::default();
    }
    pub fn remaining(&self, now: Instant) -> Option<Duration> {
        self.until
            .and_then(|until| until.checked_duration_since(now))
            .filter(|remaining| !remaining.is_zero())
    }
}

/// Visibility comes from selected pane/window ownership, never a paint timer.
/// A stationary visible terminal remains live even with cursor blink disabled.
pub fn suspend_hidden_surface(
    visible: bool,
    hidden_for: Option<Duration>,
    enabled: bool,
    delay: Duration,
) -> bool {
    enabled && !visible && hidden_for.is_some_and(|age| age >= delay)
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RestorePriority {
    Selected,
    Nearest,
    Fifo,
}
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DeferredDecision {
    Idle,
    Wait(Duration),
    Restore(u64, RestorePriority),
}

/// Background work hydrates identity only; selecting a parked tab may activate
/// its full saved payload immediately, even during the quiet period.
pub fn deferred_decision(
    pending: &[u64],
    order: &[u64],
    selected: Option<u64>,
    elapsed_since_selection: Option<Duration>,
) -> DeferredDecision {
    if pending.is_empty() {
        return DeferredDecision::Idle;
    }
    if let Some(selected) = selected.filter(|id| pending.contains(id)) {
        return DeferredDecision::Restore(selected, RestorePriority::Selected);
    }
    if let Some(elapsed) = elapsed_since_selection.filter(|d| *d < SELECTION_QUIET_PERIOD) {
        return DeferredDecision::Wait(SELECTION_QUIET_PERIOD - elapsed);
    }
    if let Some(index) = selected.and_then(|id| order.iter().position(|p| *p == id)) {
        for distance in 1..=order.len() {
            if let Some(candidate) = order
                .get(index + distance)
                .filter(|id| pending.contains(id))
            {
                return DeferredDecision::Restore(*candidate, RestorePriority::Nearest);
            }
            if let Some(candidate) = index
                .checked_sub(distance)
                .and_then(|i| order.get(i))
                .filter(|id| pending.contains(id))
            {
                return DeferredDecision::Restore(*candidate, RestorePriority::Nearest);
            }
        }
    }
    DeferredDecision::Restore(pending[0], RestorePriority::Fifo)
}

pub fn retain_snapshot(index: usize, selected: usize, restore_preview: bool) -> bool {
    restore_preview || index.abs_diff(selected) <= NEARBY_SNAPSHOT_DISTANCE
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RevealTrigger {
    Selection,
    Reactivation,
    Bootstrap,
    Startup,
    ExplicitRefresh,
}
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RevealAction {
    RepaintInPlace,
    Authoritative { await_frame: bool },
}
pub fn reveal_action(
    trigger: RevealTrigger,
    visible_surface: bool,
    attached: bool,
    live_frame: bool,
) -> RevealAction {
    if matches!(
        trigger,
        RevealTrigger::Selection | RevealTrigger::Reactivation | RevealTrigger::Bootstrap
    ) && visible_surface
        && attached
        && live_frame
    {
        RevealAction::RepaintInPlace
    } else {
        RevealAction::Authoritative {
            await_frame: visible_surface,
        }
    }
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct SurfaceEvents {
    pub key: bool,
    pub main: bool,
    pub visible: bool,
    pub deminiaturized: bool,
}
impl SurfaceEvents {
    pub fn merge(&mut self, other: Self) {
        self.key |= other.key;
        self.main |= other.main;
        self.visible |= other.visible;
        self.deminiaturized |= other.deminiaturized;
    }
    pub fn requests_reveal(
        self,
        visible_surface: bool,
        window_visible: bool,
        miniaturized: bool,
        occlusion_visible: bool,
    ) -> bool {
        visible_surface
            && window_visible
            && !miniaturized
            && (self.key || self.main || self.deminiaturized || (self.visible && occlusion_visible))
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ResumeIdentity {
    pub provider: String,
    pub session_id: String,
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RestorePrefillIntent {
    pub token: u64,
    pub command: String,
    /// Resolved canonical paths are supplied by an off-thread caller.
    pub expected_directory: PathBuf,
    pub expected_identity: ResumeIdentity,
    pub input_generation: u64,
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PrefillSnapshot {
    pub current_token: u64,
    pub directory: PathBuf,
    pub provider: Option<String>,
    pub session_id: Option<String>,
    pub input_generation: u64,
    pub view_presented: bool,
    pub surface_visible: bool,
    pub at_prompt: bool,
    pub loading: bool,
    pub ai_running: bool,
    pub exited: bool,
}
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PrefillDecision {
    Wait,
    Deliver,
    Reject(PrefillRejection),
}
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PrefillRejection {
    StaleToken,
    UserInput,
    DirectoryChanged,
    ProviderChanged,
    SessionChanged,
    Exited,
    InvalidCommand,
}

fn normalized(path: &Path) -> PathBuf {
    let mut out = PathBuf::new();
    for component in path.components() {
        match component {
            Component::CurDir => {}
            Component::ParentDir => {
                out.pop();
            }
            other => out.push(other.as_os_str()),
        }
    }
    out
}
impl RestorePrefillIntent {
    /// No deadline can turn Wait into Deliver. The caller removes intents on
    /// terminal outcomes, making rejections and successful delivery sticky.
    pub fn decision(&self, state: &PrefillSnapshot) -> PrefillDecision {
        let reject = |r| PrefillDecision::Reject(r);
        if state.current_token != self.token {
            return reject(PrefillRejection::StaleToken);
        }
        if state.exited {
            return reject(PrefillRejection::Exited);
        }
        if self.command.trim().is_empty() || self.command.contains(['\r', '\n', '\0']) {
            return reject(PrefillRejection::InvalidCommand);
        }
        if state.input_generation != self.input_generation {
            return reject(PrefillRejection::UserInput);
        }
        if normalized(&state.directory) != normalized(&self.expected_directory) {
            return reject(PrefillRejection::DirectoryChanged);
        }
        if state
            .provider
            .as_deref()
            .is_some_and(|p| p != self.expected_identity.provider)
        {
            return reject(PrefillRejection::ProviderChanged);
        }
        if state
            .session_id
            .as_deref()
            .is_some_and(|id| id != self.expected_identity.session_id)
        {
            return reject(PrefillRejection::SessionChanged);
        }
        if !state.view_presented
            || !state.surface_visible
            || !state.at_prompt
            || state.loading
            || state.ai_running
        {
            return PrefillDecision::Wait;
        }
        PrefillDecision::Deliver
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn surface_geometry_preserves_terminal_during_collapsed_or_invalid_layouts() {
        for (width, height) in [
            (0.0, 0.0),
            (7.9, 32.0),
            (16.0, 31.9),
            (-1.0, 32.0),
            (f32::NAN, 32.0),
            (16.0, f32::INFINITY),
        ] {
            assert_eq!(surface_dimensions(width, height, 8.0, 16.0), None);
        }
        assert_eq!(surface_dimensions(16.0, 32.0, 8.0, 16.0), Some((2, 2)));
        assert_eq!(surface_dimensions(647.9, 401.9, 8.0, 16.0), Some((80, 25)));
        assert_eq!(
            surface_dimensions(1e30, 1e30, 0.001, 0.001),
            Some((2000, 500))
        );
        for cell in [0.0, -1.0, f32::NAN, f32::INFINITY] {
            assert_eq!(surface_dimensions(640.0, 400.0, cell, 16.0), None);
        }
    }
    #[test]
    fn nudge_policy_coalesces_resize_reveal_and_late_tui_identity() {
        use WinsizeNudgeDecision::*;
        let mut state = WinsizeNudgeState::default();
        assert_eq!(state.update(true, false, Some((80, 24))), Schedule);
        assert_eq!(state.update(true, false, Some((80, 24))), Keep);
        assert_eq!(state.update(true, true, None), Schedule);
        assert_eq!(state.update(true, true, None), Keep);
        assert_eq!(state.update(false, true, None), Cancel);
        assert_eq!(state.update(true, true, Some((80, 24))), Schedule);
        assert_eq!(state.update(true, true, Some((100, 24))), Schedule);
        assert_eq!(state.update(true, true, Some((100, 24))), Keep);
        assert_eq!(
            WINSIZE_NUDGE_DELAYS,
            [Duration::from_millis(700), Duration::from_millis(1800)]
        );
    }
    #[test]
    fn tui_protection_matches_current_swift_evidence_and_tools() {
        use crate::shell_session::CommandStatus::*;
        for tool in ["Claude Code", "Codex CLI", "Gemini", "OpenCode"] {
            for status in [Running, WaitingForInput, ApprovalRequired, Stuck] {
                assert!(protects_terminal_ui(
                    &[None, Some(tool)],
                    false,
                    false,
                    status
                ));
            }
            for status in [Idle, Done, Exited] {
                assert!(!protects_terminal_ui(&[Some(tool)], false, false, status));
                assert!(protects_terminal_ui(&[Some(tool)], true, false, status));
                assert!(protects_terminal_ui(&[Some(tool)], false, true, status));
            }
        }
        for tool in ["", "aider", "amp", "shell"] {
            assert!(!protects_terminal_ui(&[Some(tool)], true, true, Running));
        }
    }
    #[test]
    fn selected_precedes_quiet_period() {
        assert_eq!(
            deferred_decision(&[2, 3], &[1, 2, 3], Some(2), Some(Duration::ZERO)),
            DeferredDecision::Restore(2, RestorePriority::Selected)
        );
    }
    #[test]
    fn rapid_selection_waits_exact_remaining_time() {
        assert_eq!(
            deferred_decision(&[2], &[1, 2], Some(1), Some(Duration::from_millis(200))),
            DeferredDecision::Wait(Duration::from_millis(250))
        );
    }
    #[test]
    fn nearest_right_wins_equal_distance_then_left() {
        assert_eq!(
            deferred_decision(&[1, 3], &[1, 2, 3], Some(2), None),
            DeferredDecision::Restore(3, RestorePriority::Nearest)
        );
        assert_eq!(
            deferred_decision(&[1], &[1, 2, 3], Some(2), None),
            DeferredDecision::Restore(1, RestorePriority::Nearest)
        );
    }
    #[test]
    fn missing_selection_falls_back_fifo_and_empty_is_idle() {
        assert_eq!(
            deferred_decision(&[4, 3], &[1, 2], Some(7), None),
            DeferredDecision::Restore(4, RestorePriority::Fifo)
        );
        assert_eq!(
            deferred_decision(&[], &[], None, None),
            DeferredDecision::Idle
        );
    }
    #[test]
    fn snapshot_retention_is_bounded_and_preserves_restore_preview() {
        assert!(retain_snapshot(4, 2, false));
        assert!(!retain_snapshot(5, 2, false));
        assert!(retain_snapshot(100, 2, true));
    }
    #[test]
    fn live_reactivation_repaints_without_blocking_new_frame() {
        assert_eq!(
            reveal_action(RevealTrigger::Reactivation, true, true, true),
            RevealAction::RepaintInPlace
        );
        assert_eq!(
            reveal_action(RevealTrigger::Startup, true, true, true),
            RevealAction::Authoritative { await_frame: true }
        );
        assert_eq!(
            reveal_action(RevealTrigger::Selection, true, true, false),
            RevealAction::Authoritative { await_frame: true }
        );
    }
    #[test]
    fn occluded_or_miniaturized_surfaces_never_reveal() {
        let e = SurfaceEvents {
            visible: true,
            ..Default::default()
        };
        assert!(!e.requests_reveal(true, true, false, false));
        assert!(e.requests_reveal(true, true, false, true));
        let e = SurfaceEvents { key: true, ..e };
        assert!(e.requests_reveal(true, true, false, false));
        assert!(!e.requests_reveal(true, true, true, true));
        assert!(!e.requests_reveal(false, true, false, true));
    }
    fn ready() -> (RestorePrefillIntent, PrefillSnapshot) {
        (
            RestorePrefillIntent {
                token: 1,
                command: "claude --resume 'fixture'".into(),
                expected_directory: PathBuf::from("/repo"),
                expected_identity: ResumeIdentity {
                    provider: "claude".into(),
                    session_id: "fixture".into(),
                },
                input_generation: 0,
            },
            PrefillSnapshot {
                current_token: 1,
                directory: PathBuf::from("/repo"),
                provider: None,
                session_id: None,
                input_generation: 0,
                view_presented: true,
                surface_visible: true,
                at_prompt: true,
                loading: false,
                ai_running: false,
                exited: false,
            },
        )
    }
    #[test]
    fn absent_live_identity_can_deliver_without_execution_bytes() {
        let (i, s) = ready();
        assert_eq!(i.decision(&s), PrefillDecision::Deliver);
        assert!(!i.command.ends_with('\n'));
    }
    #[test]
    fn readiness_never_forces_delivery() {
        let (i, mut s) = ready();
        s.at_prompt = false;
        for _ in 0..1000 {
            assert_eq!(i.decision(&s), PrefillDecision::Wait);
        }
        s.at_prompt = true;
        s.view_presented = false;
        assert_eq!(i.decision(&s), PrefillDecision::Wait);
        s.view_presented = true;
        s.surface_visible = false;
        assert_eq!(i.decision(&s), PrefillDecision::Wait);
        s.surface_visible = true;
        s.loading = true;
        assert_eq!(i.decision(&s), PrefillDecision::Wait);
        s.loading = false;
        s.ai_running = true;
        assert_eq!(i.decision(&s), PrefillDecision::Wait);
    }
    #[test]
    fn stale_tokens_and_user_input_reject() {
        let (i, mut s) = ready();
        s.current_token = 2;
        assert_eq!(
            i.decision(&s),
            PrefillDecision::Reject(PrefillRejection::StaleToken)
        );
        s.current_token = 1;
        s.input_generation = 1;
        assert_eq!(
            i.decision(&s),
            PrefillDecision::Reject(PrefillRejection::UserInput)
        );
    }
    #[test]
    fn directory_and_native_identity_must_still_match() {
        let (i, mut s) = ready();
        s.directory = "/repo/sub".into();
        assert_eq!(
            i.decision(&s),
            PrefillDecision::Reject(PrefillRejection::DirectoryChanged)
        );
        s.directory = "/repo/./".into();
        s.provider = Some("codex".into());
        assert_eq!(
            i.decision(&s),
            PrefillDecision::Reject(PrefillRejection::ProviderChanged)
        );
        s.provider = Some("claude".into());
        s.session_id = Some("other".into());
        assert_eq!(
            i.decision(&s),
            PrefillDecision::Reject(PrefillRejection::SessionChanged)
        );
    }
    #[test]
    fn invalid_or_exited_intents_are_terminal() {
        let (mut i, mut s) = ready();
        s.exited = true;
        assert_eq!(
            i.decision(&s),
            PrefillDecision::Reject(PrefillRejection::Exited)
        );
        s.exited = false;
        i.command.push('\n');
        assert_eq!(
            i.decision(&s),
            PrefillDecision::Reject(PrefillRejection::InvalidCommand)
        );
    }
}

#[cfg(test)]
mod surface_visibility_tests {
    use super::*;
    #[test]
    fn stationary_visible_surface_never_suspends() {
        assert!(!suspend_hidden_surface(
            true,
            Some(Duration::from_secs(3600)),
            true,
            Duration::ZERO
        ));
    }
    #[test]
    fn actual_hidden_duration_controls_suspension_and_disabled_is_honored() {
        let delay = Duration::from_secs(5);
        assert!(!suspend_hidden_surface(false, None, true, delay));
        assert!(!suspend_hidden_surface(
            false,
            Some(Duration::from_millis(4999)),
            true,
            delay
        ));
        assert!(suspend_hidden_surface(false, Some(delay), true, delay));
        assert!(!suspend_hidden_surface(false, Some(delay), false, delay));
    }
}

#[cfg(test)]
mod prewarm_tests {
    use super::*;
    #[test]
    fn prewarm_is_bounded_and_repeated_hover_does_not_extend_it() {
        let now = Instant::now();
        let mut state = SurfacePrewarm::default();
        assert!(state.begin(now));
        assert_eq!(state.remaining(now), Some(PREWARM_DURATION));
        assert!(!state.begin(now + Duration::from_secs(1)));
        assert_eq!(
            state.remaining(now + Duration::from_secs(1)),
            Some(Duration::from_secs(1))
        );
        assert_eq!(state.remaining(now + PREWARM_DURATION), None);
    }
    #[test]
    fn leaving_has_half_second_grace_and_reentering_starts_new_bounded_prewarm() {
        let now = Instant::now();
        let mut state = SurfacePrewarm::default();
        state.begin(now);
        let leave = now + Duration::from_millis(100);
        state.end(leave);
        assert_eq!(state.remaining(leave), Some(PREWARM_EXIT_GRACE));
        assert!(state.begin(leave + Duration::from_millis(100)));
        assert_eq!(
            state.remaining(leave + Duration::from_millis(100)),
            Some(PREWARM_DURATION)
        );
    }
    #[test]
    fn actual_selection_clears_prewarm_without_a_deadline() {
        let now = Instant::now();
        let mut state = SurfacePrewarm::default();
        state.begin(now);
        state.clear();
        assert_eq!(state.remaining(now), None);
    }
}
