//! Port of
//! `apps/chau7-macos/Sources/Chau7Core/Notifications/TerminalPromptNotificationAdapter.swift`.
//!
//! Decides whether a returning shell prompt means "AI finished" (a waiting
//! input fallback event).

/// Snapshot of tab state when the shell prompt returns
/// (`TerminalPromptNotificationContext`).
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct TerminalPromptNotificationContext {
    pub previous_status: String,
    pub has_owner_tab: bool,
    pub runtime_owns_tab: bool,
    pub provider_id: Option<String>,
    pub provider_is_restored: bool,
    pub provider_has_authoritative_notifications: bool,
    pub has_pending_prefill_input: bool,
    pub suppress_until_next_user_command: bool,
    pub has_recent_system_resume_prefill: bool,
    pub command_looks_like_resume: bool,
    pub observed_ai_round_trip: bool,
    pub session_id: Option<String>,
}

const SUPPORTED_STATUSES: [&str; 4] = ["running", "stuck", "waitingForInput", "approvalRequired"];
const FALLBACK_EXCLUDED_PROVIDERS: [&str; 1] = ["claude"];

fn normalized_provider_id(value: Option<&str>) -> Option<String> {
    let value = value?.trim().to_lowercase();
    if value.is_empty() { None } else { Some(value) }
}

/// `TerminalPromptNotificationAdapter.shouldEmitWaitingInput(from:)`.
pub fn should_emit_waiting_input(context: &TerminalPromptNotificationContext) -> bool {
    if !SUPPORTED_STATUSES.contains(&context.previous_status.as_str()) {
        return false;
    }
    if !context.has_owner_tab || context.runtime_owns_tab {
        return false;
    }
    let Some(provider_id) = normalized_provider_id(context.provider_id.as_deref()) else {
        return false;
    };
    if FALLBACK_EXCLUDED_PROVIDERS.contains(&provider_id.as_str())
        || (provider_id == "codex" && context.provider_has_authoritative_notifications)
    {
        return false;
    }
    if context.has_pending_prefill_input
        || context.suppress_until_next_user_command
        || context.has_recent_system_resume_prefill
        || context.command_looks_like_resume
    {
        return false;
    }
    context.observed_ai_round_trip
}

#[cfg(test)]
mod tests {
    use super::*;

    fn base() -> TerminalPromptNotificationContext {
        TerminalPromptNotificationContext {
            previous_status: "running".into(),
            has_owner_tab: true,
            runtime_owns_tab: false,
            provider_id: Some("codex".into()),
            provider_is_restored: false,
            provider_has_authoritative_notifications: false,
            has_pending_prefill_input: false,
            suppress_until_next_user_command: false,
            has_recent_system_resume_prefill: false,
            command_looks_like_resume: false,
            observed_ai_round_trip: true,
            session_id: Some("session-1".into()),
        }
    }

    #[test]
    fn current_codex_authoritative_feedback_suppresses_duplicate_prompt_fallback() {
        let mut context = base();
        context.previous_status = "approvalRequired".into();
        assert!(should_emit_waiting_input(&context));
        context.provider_has_authoritative_notifications = true;
        assert!(!should_emit_waiting_input(&context));
    }

    #[test]
    fn does_not_emit_for_claude_fallback() {
        let mut c = base();
        c.provider_id = Some("claude".into());
        assert!(!should_emit_waiting_input(&c));
    }

    #[test]
    fn does_not_emit_for_resume_like_prompt() {
        let mut c = base();
        c.provider_is_restored = true;
        c.command_looks_like_resume = true;
        assert!(!should_emit_waiting_input(&c));
    }

    #[test]
    fn emits_for_non_claude_prompt_fallback_after_observed_round_trip() {
        assert!(should_emit_waiting_input(&base()));
    }

    #[test]
    fn does_not_emit_while_suppressed_until_next_user_command() {
        let mut c = base();
        c.provider_is_restored = true;
        c.suppress_until_next_user_command = true;
        assert!(!should_emit_waiting_input(&c));
    }

    #[test]
    fn does_not_emit_after_system_resume_prefill_until_real_user_command() {
        let mut c = base();
        c.provider_is_restored = true;
        c.has_recent_system_resume_prefill = true;
        assert!(!should_emit_waiting_input(&c));
    }

    #[test]
    fn does_not_emit_without_round_trip_owner_or_supported_status() {
        let mut c = base();
        c.observed_ai_round_trip = false;
        assert!(!should_emit_waiting_input(&c));
        let mut c = base();
        c.has_owner_tab = false;
        assert!(!should_emit_waiting_input(&c));
        let mut c = base();
        c.runtime_owns_tab = true;
        assert!(!should_emit_waiting_input(&c));
        let mut c = base();
        c.previous_status = "idle".into();
        assert!(!should_emit_waiting_input(&c));
    }

    #[test]
    fn provider_id_is_trimmed_and_lowercased_and_must_not_be_blank() {
        let mut c = base();
        c.provider_id = Some("  CLAUDE ".into());
        assert!(!should_emit_waiting_input(&c));
        c.provider_id = Some("   ".into());
        assert!(!should_emit_waiting_input(&c));
        c.provider_id = None;
        assert!(!should_emit_waiting_input(&c));
    }

    #[test]
    fn does_not_emit_with_pending_prefill_input() {
        let mut c = base();
        c.has_pending_prefill_input = true;
        assert!(!should_emit_waiting_input(&c));
    }
}
