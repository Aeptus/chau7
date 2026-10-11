//! Current Swift deferred restore, surface reveal and resume delivery policies.
//! These decisions perform no filesystem or terminal I/O.
use std::path::{Component, Path, PathBuf};
use std::time::Duration;

pub const SELECTION_QUIET_PERIOD: Duration = Duration::from_millis(450);
pub const REACTIVATION_COALESCING_DELAY: Duration = Duration::from_millis(50);
pub const NEARBY_SNAPSHOT_DISTANCE: usize = 2;

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
