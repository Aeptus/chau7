//! Current Swift launch and settled-turn signal policy.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct LaunchSnapshot {
    pub shell_loading: bool,
    pub is_at_prompt: bool,
    pub effective_status: String,
    pub raw_status: String,
    pub active_app: Option<String>,
    pub raw_active_app: Option<String>,
    pub ai_provider: Option<String>,
    pub active_run_provider: Option<String>,
    pub process_names: Vec<String>,
    /// The agent the tab's process tree shows running (ground truth).
    pub live_agent: Option<String>,
    pub status_observed_at: Option<chrono::DateTime<chrono::Utc>>,
}
fn status(value: &str) -> String {
    value
        .to_lowercase()
        .chars()
        .filter(|c| c.is_alphabetic())
        .collect()
}
fn matches(snapshot: &LaunchSnapshot, backend: &str) -> bool {
    let backend = backend.to_lowercase();
    [
        &snapshot.active_app,
        &snapshot.raw_active_app,
        &snapshot.ai_provider,
        &snapshot.active_run_provider,
    ]
    .iter()
    .filter_map(|value| value.as_ref())
    .chain(snapshot.process_names.iter())
    .any(|signal| signal.to_lowercase().contains(&backend))
}
/// An agent's own process, not just its name typed on the command line or a
/// provider label, which both exist before the agent has started.
fn agent_is_live(snapshot: &LaunchSnapshot, backend: &str) -> bool {
    let backend = backend.to_lowercase();
    snapshot
        .live_agent
        .iter()
        .chain(snapshot.process_names.iter())
        .any(|name| name.to_lowercase().contains(&backend))
}
pub fn is_ready(snapshot: &LaunchSnapshot, backend: &str, purpose: Option<&str>) -> bool {
    if snapshot.shell_loading
        && !purpose.is_some_and(|purpose| purpose.trim().eq_ignore_ascii_case("code_review"))
    {
        return false;
    }
    if !matches(snapshot, backend) {
        return false;
    }
    if !backend.eq_ignore_ascii_case("shell") {
        // A shell prompt after an agent launch means the agent is not running
        // (not started yet, or already gone), and input would reach the shell.
        if !agent_is_live(snapshot, backend) || snapshot.is_at_prompt {
            return false;
        }
    } else if snapshot.is_at_prompt {
        return true;
    }
    [&snapshot.effective_status, &snapshot.raw_status]
        .iter()
        .any(|value| {
            matches!(
                status(value).as_str(),
                "idle" | "done" | "running" | "approvalrequired" | "waitingforinput" | "stuck"
            )
        })
}
pub fn is_settled(snapshot: &LaunchSnapshot, backend: &str) -> bool {
    !snapshot.shell_loading
        && matches(snapshot, backend)
        && [&snapshot.effective_status, &snapshot.raw_status]
            .iter()
            .any(|value| matches!(status(value).as_str(), "done" | "waitingforinput"))
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn an_agent_launch_is_ready_only_once_the_agent_itself_runs() {
        // Just after `codex` was typed: labelled Codex, but only the shell,
        // the launch wrapper and its helper are running.
        let mut snapshot = LaunchSnapshot {
            ai_provider: Some("codex".into()),
            active_app: Some("Codex".into()),
            effective_status: "running".into(),
            raw_status: "running".into(),
            process_names: vec!["zsh".into(), "sh".into(), "Python".into()],
            ..Default::default()
        };
        assert!(!is_ready(&snapshot, "codex", Some("code_review")));
        // A shell prompt (a false finish, or Codex already exited).
        snapshot.effective_status = "done".into();
        snapshot.is_at_prompt = true;
        snapshot.process_names.push("codex".into());
        assert!(!is_ready(&snapshot, "codex", None));
        // Codex is running in the tab.
        snapshot.is_at_prompt = false;
        snapshot.effective_status = "running".into();
        assert!(is_ready(&snapshot, "codex", None));
        snapshot.process_names.clear();
        snapshot.live_agent = Some("Codex".into());
        assert!(is_ready(&snapshot, "codex", None));
    }
    #[test]
    fn a_shell_session_is_ready_at_its_prompt() {
        let snapshot = LaunchSnapshot {
            is_at_prompt: true,
            process_names: vec!["zsh".into()],
            active_app: Some("shell".into()),
            ..Default::default()
        };
        assert!(is_ready(&snapshot, "shell", None));
    }
    #[test]
    fn provider_identity_shell_load_and_review_exception() {
        let mut snapshot = LaunchSnapshot {
            shell_loading: true,
            is_at_prompt: true,
            active_app: Some("Claude Code".into()),
            ..Default::default()
        };
        assert!(!is_ready(&snapshot, "claude", None));
        // The review exception still needs Claude itself running in the tab.
        assert!(!is_ready(&snapshot, "claude", Some("code_review")));
        snapshot.is_at_prompt = false;
        snapshot.effective_status = "running".into();
        snapshot.live_agent = Some("Claude".into());
        assert!(is_ready(&snapshot, "claude", Some("code_review")));
        assert!(!is_ready(&snapshot, "codex", Some("code_review")));
        snapshot.shell_loading = false;
        snapshot.effective_status = "waiting_for_input".into();
        assert!(is_settled(&snapshot, "claude"));
        snapshot.effective_status = "running".into();
        assert!(!is_settled(&snapshot, "claude"));
    }
}
