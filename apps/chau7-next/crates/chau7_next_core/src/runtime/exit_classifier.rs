//! Port of `Runtime/ExitClassifier.swift`: classify why an agent turn ended.

use serde::{Deserialize, Serialize};

use super::session_state::State;

/// Why a turn ended. Used in `turn_completed` event data.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum TurnExitReason {
    /// Normal completion
    #[serde(rename = "success")]
    Success,
    /// Agent reported error
    #[serde(rename = "error")]
    Error,
    /// Ctrl+C or external interrupt
    #[serde(rename = "interrupted")]
    Interrupted,
    /// User/orchestrator denied a tool
    #[serde(rename = "approval_denied")]
    ApprovalDenied,
    /// No activity for threshold duration
    #[serde(rename = "stalled")]
    Stalled,
    /// Context window exhausted
    #[serde(rename = "context_limit")]
    ContextLimit,
}

impl TurnExitReason {
    /// The Swift raw value.
    pub fn raw_value(self) -> &'static str {
        match self {
            TurnExitReason::Success => "success",
            TurnExitReason::Error => "error",
            TurnExitReason::Interrupted => "interrupted",
            TurnExitReason::ApprovalDenied => "approval_denied",
            TurnExitReason::Stalled => "stalled",
            TurnExitReason::ContextLimit => "context_limit",
        }
    }
}

const CONTEXT_PATTERNS: [&str; 4] = [
    "context window",
    "token limit",
    "context limit",
    "max context",
];
const ERROR_PATTERNS: [&str; 4] = ["error:", "fatal:", "panic:", "unhandled exception"];

/// Classify the turn exit reason from available signals.
///
/// Priority order (highest to lowest):
/// interrupted, approvalDenied, failed state, contextLimit, error patterns, success.
pub fn classify(
    session_state: State,
    last_denied: bool,
    terminal_output: Option<&str>,
    was_interrupted: bool,
) -> TurnExitReason {
    // 1. Interrupt takes absolute priority
    if was_interrupted {
        return TurnExitReason::Interrupted;
    }

    // 2. Explicit denial
    if last_denied {
        return TurnExitReason::ApprovalDenied;
    }

    // 3. State machine says failed
    if session_state == State::Failed {
        return TurnExitReason::Error;
    }

    // 4. Scan terminal output for known patterns
    if let Some(output) = terminal_output.map(str::to_lowercase) {
        // Context limit patterns (Claude Code emits these)
        if CONTEXT_PATTERNS.iter().any(|p| output.contains(p)) {
            return TurnExitReason::ContextLimit;
        }
        // Error patterns (only if the state machine didn't catch it)
        if ERROR_PATTERNS.iter().any(|p| output.contains(p)) {
            return TurnExitReason::Error;
        }
    }

    // 5. Default: success
    TurnExitReason::Success
}

#[cfg(test)]
mod tests {
    use super::*;

    // MARK: Default path

    #[test]
    fn success_default_path() {
        let reason = classify(State::Ready, false, None, false);
        assert_eq!(reason, TurnExitReason::Success);
    }

    #[test]
    fn success_with_normal_output() {
        let reason = classify(
            State::Ready,
            false,
            Some("Task completed successfully."),
            false,
        );
        assert_eq!(reason, TurnExitReason::Success);
    }

    // MARK: Interrupted

    #[test]
    fn interrupted() {
        let reason = classify(State::Busy, false, None, true);
        assert_eq!(reason, TurnExitReason::Interrupted);
    }

    // MARK: Approval denied

    #[test]
    fn approval_denied() {
        let reason = classify(State::Ready, true, None, false);
        assert_eq!(reason, TurnExitReason::ApprovalDenied);
    }

    // MARK: Error (failed state)

    #[test]
    fn error_from_failed_state() {
        let reason = classify(State::Failed, false, None, false);
        assert_eq!(reason, TurnExitReason::Error);
    }

    // MARK: Context limit

    #[test]
    fn context_limit_context_window() {
        let reason = classify(
            State::Ready,
            false,
            Some("Warning: context window exceeded, please start a new conversation."),
            false,
        );
        assert_eq!(reason, TurnExitReason::ContextLimit);
    }

    #[test]
    fn context_limit_token_limit() {
        let reason = classify(
            State::Ready,
            false,
            Some("Reached token limit for this session"),
            false,
        );
        assert_eq!(reason, TurnExitReason::ContextLimit);
    }

    // MARK: Error patterns in output

    #[test]
    fn error_from_output_pattern() {
        let reason = classify(
            State::Ready,
            false,
            Some("fatal: unable to read tree object"),
            false,
        );
        assert_eq!(reason, TurnExitReason::Error);
    }

    // MARK: Priority order

    #[test]
    fn priority_interrupted_beats_all() {
        // Even with denied + failed + error output, interrupted wins
        let reason = classify(
            State::Failed,
            true,
            Some("fatal: crash\ncontext window exceeded"),
            true,
        );
        assert_eq!(reason, TurnExitReason::Interrupted);
    }

    #[test]
    fn priority_denied_beats_error() {
        let reason = classify(
            State::Failed,
            true,
            Some("error: something went wrong"),
            false,
        );
        assert_eq!(reason, TurnExitReason::ApprovalDenied);
    }

    #[test]
    fn priority_failed_state_beats_context_limit() {
        let reason = classify(State::Failed, false, Some("context window exceeded"), false);
        assert_eq!(reason, TurnExitReason::Error);
    }

    #[test]
    fn raw_values_match_serde() {
        for r in [
            TurnExitReason::Success,
            TurnExitReason::Error,
            TurnExitReason::Interrupted,
            TurnExitReason::ApprovalDenied,
            TurnExitReason::Stalled,
            TurnExitReason::ContextLimit,
        ] {
            assert_eq!(
                serde_json::to_string(&r).unwrap(),
                format!("\"{}\"", r.raw_value())
            );
        }
    }
}
