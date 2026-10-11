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
pub fn is_ready(snapshot: &LaunchSnapshot, backend: &str, purpose: Option<&str>) -> bool {
    if snapshot.shell_loading
        && !purpose.is_some_and(|purpose| purpose.trim().eq_ignore_ascii_case("code_review"))
    {
        return false;
    }
    if !matches(snapshot, backend) {
        return false;
    }
    snapshot.is_at_prompt
        || [&snapshot.effective_status, &snapshot.raw_status]
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
    fn provider_identity_shell_load_and_review_exception() {
        let mut snapshot = LaunchSnapshot {
            shell_loading: true,
            is_at_prompt: true,
            active_app: Some("Claude Code".into()),
            ..Default::default()
        };
        assert!(!is_ready(&snapshot, "claude", None));
        assert!(is_ready(&snapshot, "claude", Some("code_review")));
        assert!(!is_ready(&snapshot, "codex", Some("code_review")));
        snapshot.shell_loading = false;
        snapshot.effective_status = "waiting_for_input".into();
        assert!(is_settled(&snapshot, "claude"));
        snapshot.effective_status = "running".into();
        assert!(!is_settled(&snapshot, "claude"));
    }
}
