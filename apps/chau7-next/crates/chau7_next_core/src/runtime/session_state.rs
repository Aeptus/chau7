//! Port of `Runtime/RuntimeSessionState.swift`: the pure state machine for
//! agent runtime session lifecycle.
//!
//! `State` serializes to the Swift raw values (`awaitingApproval`,
//! `waitingInput`, ...); `runtime_events_poll` reports it as `session_state`.

use serde::{Deserialize, Serialize};

/// Session lifecycle states.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum State {
    /// Tab created, backend launching.
    Starting,
    /// Backend idle, can accept a prompt.
    Ready,
    /// Processing a turn (agent responding, using tools).
    Busy,
    /// Agent blocked on a permission request.
    AwaitingApproval,
    /// Agent asked for user clarification.
    WaitingInput,
    /// User sent Ctrl+C.
    Interrupted,
    /// Unrecoverable error (crash, launch timeout).
    Failed,
    /// Explicitly stopped or tab closed.
    Stopped,
}

impl State {
    /// The Swift raw value.
    pub fn raw_value(self) -> &'static str {
        match self {
            State::Starting => "starting",
            State::Ready => "ready",
            State::Busy => "busy",
            State::AwaitingApproval => "awaitingApproval",
            State::WaitingInput => "waitingInput",
            State::Interrupted => "interrupted",
            State::Failed => "failed",
            State::Stopped => "stopped",
        }
    }
}

/// Events that drive state transitions.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Trigger {
    BackendReady,
    TurnSubmitted,
    TurnCompleted,
    ApprovalNeeded,
    ApprovalResolved,
    InputRequested,
    InputProvided,
    Interrupted,
    ProcessCrashed(String),
    TabClosed,
    LaunchTimeout,
}

/// Pure state machine; mutation returns whether the transition was accepted.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RuntimeSessionStateMachine {
    state: State,
}

impl Default for RuntimeSessionStateMachine {
    fn default() -> Self {
        Self::new()
    }
}

impl RuntimeSessionStateMachine {
    pub fn new() -> Self {
        Self {
            state: State::Starting,
        }
    }

    /// Current state of the session.
    pub fn state(&self) -> State {
        self.state
    }

    /// Apply a trigger. Returns `true` if the transition was accepted,
    /// `false` if invalid (the state is unchanged).
    pub fn handle(&mut self, trigger: &Trigger) -> bool {
        match Self::next_state(self.state, trigger) {
            Some(next) => {
                self.state = next;
                true
            }
            None => false,
        }
    }

    /// Whether the session has reached a terminal state.
    pub fn is_terminal(&self) -> bool {
        self.state == State::Failed || self.state == State::Stopped
    }

    /// Whether the session can accept a new turn.
    pub fn can_accept_turn(&self) -> bool {
        self.state == State::Ready
    }

    fn next_state(state: State, trigger: &Trigger) -> Option<State> {
        use State as S;
        use Trigger as T;
        match (state, trigger) {
            // starting
            (S::Starting, T::BackendReady) => Some(S::Ready),
            (S::Starting, T::LaunchTimeout) => Some(S::Failed),
            (S::Starting, T::ProcessCrashed(_)) => Some(S::Failed),
            (S::Starting, T::TabClosed) => Some(S::Stopped),
            // ready
            (S::Ready, T::TurnSubmitted) => Some(S::Busy),
            (S::Ready, T::TabClosed) => Some(S::Stopped),
            // busy
            (S::Busy, T::TurnCompleted) => Some(S::Ready),
            (S::Busy, T::ApprovalNeeded) => Some(S::AwaitingApproval),
            (S::Busy, T::InputRequested) => Some(S::WaitingInput),
            (S::Busy, T::Interrupted) => Some(S::Interrupted),
            (S::Busy, T::ProcessCrashed(_)) => Some(S::Failed),
            (S::Busy, T::TabClosed) => Some(S::Stopped),
            // awaitingApproval
            (S::AwaitingApproval, T::ApprovalResolved) => Some(S::Busy),
            (S::AwaitingApproval, T::Interrupted) => Some(S::Interrupted),
            (S::AwaitingApproval, T::TabClosed) => Some(S::Stopped),
            // waitingInput
            (S::WaitingInput, T::InputProvided) => Some(S::Busy),
            (S::WaitingInput, T::TabClosed) => Some(S::Stopped),
            // interrupted
            (S::Interrupted, T::BackendReady) => Some(S::Ready),
            (S::Interrupted, T::ProcessCrashed(_)) => Some(S::Failed),
            (S::Interrupted, T::TabClosed) => Some(S::Stopped),
            // Terminal states accept nothing; everything else is invalid
            _ => None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn make_ready() -> RuntimeSessionStateMachine {
        let mut sm = RuntimeSessionStateMachine::new();
        sm.handle(&Trigger::BackendReady);
        sm
    }

    fn make_busy() -> RuntimeSessionStateMachine {
        let mut sm = make_ready();
        sm.handle(&Trigger::TurnSubmitted);
        sm
    }

    // MARK: Initial state

    #[test]
    fn initial_state() {
        let sm = RuntimeSessionStateMachine::new();
        assert_eq!(sm.state(), State::Starting);
        assert!(!sm.is_terminal());
        assert!(!sm.can_accept_turn());
    }

    // MARK: Starting transitions

    #[test]
    fn starting_to_ready() {
        let mut sm = RuntimeSessionStateMachine::new();
        assert!(sm.handle(&Trigger::BackendReady));
        assert_eq!(sm.state(), State::Ready);
        assert!(sm.can_accept_turn());
    }

    #[test]
    fn starting_to_failed_launch_timeout() {
        let mut sm = RuntimeSessionStateMachine::new();
        assert!(sm.handle(&Trigger::LaunchTimeout));
        assert_eq!(sm.state(), State::Failed);
        assert!(sm.is_terminal());
    }

    #[test]
    fn starting_to_failed_process_crashed() {
        let mut sm = RuntimeSessionStateMachine::new();
        assert!(sm.handle(&Trigger::ProcessCrashed("SIGSEGV".into())));
        assert_eq!(sm.state(), State::Failed);
    }

    #[test]
    fn starting_to_stopped_tab_closed() {
        let mut sm = RuntimeSessionStateMachine::new();
        assert!(sm.handle(&Trigger::TabClosed));
        assert_eq!(sm.state(), State::Stopped);
        assert!(sm.is_terminal());
    }

    #[test]
    fn starting_rejects_invalid_triggers() {
        let mut sm = RuntimeSessionStateMachine::new();
        assert!(!sm.handle(&Trigger::TurnSubmitted));
        assert_eq!(sm.state(), State::Starting);
        assert!(!sm.handle(&Trigger::TurnCompleted));
        assert!(!sm.handle(&Trigger::ApprovalNeeded));
        assert!(!sm.handle(&Trigger::InputProvided));
    }

    // MARK: Ready transitions

    #[test]
    fn ready_to_busy() {
        let mut sm = make_ready();
        assert!(sm.handle(&Trigger::TurnSubmitted));
        assert_eq!(sm.state(), State::Busy);
        assert!(!sm.can_accept_turn());
    }

    #[test]
    fn ready_to_stopped() {
        let mut sm = make_ready();
        assert!(sm.handle(&Trigger::TabClosed));
        assert_eq!(sm.state(), State::Stopped);
    }

    #[test]
    fn ready_rejects_invalid_triggers() {
        let mut sm = make_ready();
        assert!(!sm.handle(&Trigger::TurnCompleted));
        assert_eq!(sm.state(), State::Ready);
        assert!(!sm.handle(&Trigger::BackendReady));
    }

    // MARK: Busy transitions

    #[test]
    fn busy_to_ready() {
        let mut sm = make_busy();
        assert!(sm.handle(&Trigger::TurnCompleted));
        assert_eq!(sm.state(), State::Ready);
    }

    #[test]
    fn busy_to_awaiting_approval() {
        let mut sm = make_busy();
        assert!(sm.handle(&Trigger::ApprovalNeeded));
        assert_eq!(sm.state(), State::AwaitingApproval);
    }

    #[test]
    fn busy_to_waiting_input() {
        let mut sm = make_busy();
        assert!(sm.handle(&Trigger::InputRequested));
        assert_eq!(sm.state(), State::WaitingInput);
    }

    #[test]
    fn busy_to_interrupted() {
        let mut sm = make_busy();
        assert!(sm.handle(&Trigger::Interrupted));
        assert_eq!(sm.state(), State::Interrupted);
    }

    #[test]
    fn busy_to_failed() {
        let mut sm = make_busy();
        assert!(sm.handle(&Trigger::ProcessCrashed("exit 1".into())));
        assert_eq!(sm.state(), State::Failed);
    }

    #[test]
    fn busy_to_stopped() {
        let mut sm = make_busy();
        assert!(sm.handle(&Trigger::TabClosed));
        assert_eq!(sm.state(), State::Stopped);
    }

    // MARK: AwaitingApproval transitions

    #[test]
    fn approval_resolved_returns_to_busy() {
        let mut sm = make_busy();
        sm.handle(&Trigger::ApprovalNeeded);
        assert!(sm.handle(&Trigger::ApprovalResolved));
        assert_eq!(sm.state(), State::Busy);
    }

    #[test]
    fn awaiting_approval_to_interrupted() {
        let mut sm = make_busy();
        sm.handle(&Trigger::ApprovalNeeded);
        assert!(sm.handle(&Trigger::Interrupted));
        assert_eq!(sm.state(), State::Interrupted);
    }

    #[test]
    fn awaiting_approval_to_stopped() {
        let mut sm = make_busy();
        sm.handle(&Trigger::ApprovalNeeded);
        assert!(sm.handle(&Trigger::TabClosed));
        assert_eq!(sm.state(), State::Stopped);
    }

    // MARK: WaitingInput transitions

    #[test]
    fn input_provided_returns_to_busy() {
        let mut sm = make_busy();
        sm.handle(&Trigger::InputRequested);
        assert!(sm.handle(&Trigger::InputProvided));
        assert_eq!(sm.state(), State::Busy);
    }

    #[test]
    fn waiting_input_to_stopped() {
        let mut sm = make_busy();
        sm.handle(&Trigger::InputRequested);
        assert!(sm.handle(&Trigger::TabClosed));
        assert_eq!(sm.state(), State::Stopped);
    }

    // MARK: Interrupted transitions

    #[test]
    fn interrupted_to_ready() {
        let mut sm = make_busy();
        sm.handle(&Trigger::Interrupted);
        assert!(sm.handle(&Trigger::BackendReady));
        assert_eq!(sm.state(), State::Ready);
    }

    #[test]
    fn interrupted_to_failed() {
        let mut sm = make_busy();
        sm.handle(&Trigger::Interrupted);
        assert!(sm.handle(&Trigger::ProcessCrashed("crash".into())));
        assert_eq!(sm.state(), State::Failed);
    }

    #[test]
    fn interrupted_to_stopped() {
        let mut sm = make_busy();
        sm.handle(&Trigger::Interrupted);
        assert!(sm.handle(&Trigger::TabClosed));
        assert_eq!(sm.state(), State::Stopped);
    }

    // MARK: Terminal states

    #[test]
    fn failed_rejects_all_triggers() {
        let mut sm = RuntimeSessionStateMachine::new();
        sm.handle(&Trigger::LaunchTimeout);
        assert!(!sm.handle(&Trigger::BackendReady));
        assert!(!sm.handle(&Trigger::TabClosed));
        assert!(!sm.handle(&Trigger::TurnSubmitted));
        assert_eq!(sm.state(), State::Failed);
    }

    #[test]
    fn stopped_rejects_all_triggers() {
        let mut sm = RuntimeSessionStateMachine::new();
        sm.handle(&Trigger::TabClosed);
        assert!(!sm.handle(&Trigger::BackendReady));
        assert!(!sm.handle(&Trigger::TurnSubmitted));
        assert!(!sm.handle(&Trigger::ProcessCrashed("x".into())));
        assert_eq!(sm.state(), State::Stopped);
    }

    // MARK: Full lifecycle

    #[test]
    fn full_turn_cycle() {
        let mut sm = RuntimeSessionStateMachine::new();
        sm.handle(&Trigger::BackendReady); // starting -> ready
        sm.handle(&Trigger::TurnSubmitted); // ready -> busy
        sm.handle(&Trigger::ApprovalNeeded); // busy -> awaitingApproval
        sm.handle(&Trigger::ApprovalResolved); // awaitingApproval -> busy
        sm.handle(&Trigger::TurnCompleted); // busy -> ready
        assert_eq!(sm.state(), State::Ready);
        assert!(sm.can_accept_turn());
    }

    #[test]
    fn interrupt_recovery_cycle() {
        let mut sm = RuntimeSessionStateMachine::new();
        sm.handle(&Trigger::BackendReady);
        sm.handle(&Trigger::TurnSubmitted);
        sm.handle(&Trigger::Interrupted); // busy -> interrupted
        sm.handle(&Trigger::BackendReady); // interrupted -> ready
        sm.handle(&Trigger::TurnSubmitted); // ready -> busy
        sm.handle(&Trigger::TurnCompleted); // busy -> ready
        assert_eq!(sm.state(), State::Ready);
    }

    #[test]
    fn state_raw_values_match_serde() {
        for s in [
            State::Starting,
            State::Ready,
            State::Busy,
            State::AwaitingApproval,
            State::WaitingInput,
            State::Interrupted,
            State::Failed,
            State::Stopped,
        ] {
            assert_eq!(
                serde_json::to_string(&s).unwrap(),
                format!("\"{}\"", s.raw_value())
            );
        }
    }
}
