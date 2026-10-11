//! Current MCP control and launch policy. Capabilities are process-local,
//! caller-specific, and bound to the exact focused terminal incarnation.
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};
use std::collections::{HashMap, HashSet};
use uuid::Uuid;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum GrantOrigin {
    Created,
    UserConfirmed,
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Grant {
    pub owner: String,
    pub terminal_identity: String,
    pub origin: GrantOrigin,
}
#[derive(Debug, Default)]
pub struct ControlGrants {
    grants: HashMap<Uuid, Grant>,
    live_clients: HashSet<String>,
}
impl ControlGrants {
    pub fn connect(&mut self, owner: &str) -> Result<(), &'static str> {
        if owner.trim().is_empty() {
            return Err("Missing MCP client identity");
        }
        self.live_clients.insert(owner.to_string());
        Ok(())
    }
    pub fn is_connected(&self, owner: &str) -> bool {
        self.live_clients.contains(owner)
    }
    pub fn grant(
        &mut self,
        tab: Uuid,
        owner: &str,
        terminal_identity: &str,
        origin: GrantOrigin,
    ) -> Result<(), &'static str> {
        if !self.is_connected(owner) {
            return Err("MCP client connection closed");
        }
        if owner.trim().is_empty() || terminal_identity.trim().is_empty() {
            return Err("Control requires a client and terminal identity");
        }
        self.grants.insert(
            tab,
            Grant {
                owner: owner.into(),
                terminal_identity: terminal_identity.into(),
                origin,
            },
        );
        Ok(())
    }
    pub fn allows(&self, tab: Uuid, owner: &str, identity: &str) -> bool {
        self.grants
            .get(&tab)
            .is_some_and(|grant| grant.owner == owner && grant.terminal_identity == identity)
    }
    pub fn release(&mut self, tab: Uuid, owner: &str, identity: &str) -> Result<(), &'static str> {
        if !self.allows(tab, owner, identity) {
            return Err("This client does not control the current terminal");
        }
        self.grants.remove(&tab);
        Ok(())
    }
    pub fn disconnect(&mut self, owner: &str) -> Vec<Uuid> {
        self.live_clients.remove(owner);
        let removed = self
            .grants
            .iter()
            .filter(|(_, grant)| grant.owner == owner)
            .map(|(tab, _)| *tab)
            .collect();
        self.grants.retain(|_, grant| grant.owner != owner);
        removed
    }
    pub fn has_tab(&self, tab: Uuid) -> bool {
        self.grants.contains_key(&tab)
    }
    pub fn forget(&mut self, tab: Uuid) {
        self.grants.remove(&tab);
    }
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ExecutionSnapshot {
    pub shell_loading: bool,
    pub at_prompt: bool,
    pub has_view: bool,
    pub status: String,
    pub approval_pending: bool,
}
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum AcceptanceMode {
    Immediate,
    Queued,
    Blocked,
}
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum ReadinessReason {
    Ready,
    Exited,
    CommandApprovalPending,
    ShellLoading,
    ViewUnattached,
    NotAtPrompt,
    McpControlRequired,
}
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Readiness {
    pub ready: bool,
    pub can_accept: bool,
    pub mode: AcceptanceMode,
    pub reason: ReadinessReason,
}
impl Readiness {
    pub fn evaluate(snapshot: &ExecutionSnapshot) -> Self {
        let status = snapshot.status.trim().to_ascii_lowercase();
        let (ready, can_accept, mode, reason) =
            if snapshot.approval_pending || status == "command_approval_pending" {
                (
                    false,
                    false,
                    AcceptanceMode::Blocked,
                    ReadinessReason::CommandApprovalPending,
                )
            } else if status == "exited" {
                (
                    false,
                    false,
                    AcceptanceMode::Blocked,
                    ReadinessReason::Exited,
                )
            } else if snapshot.shell_loading {
                (
                    false,
                    true,
                    AcceptanceMode::Queued,
                    ReadinessReason::ShellLoading,
                )
            } else if !snapshot.at_prompt {
                (
                    false,
                    false,
                    AcceptanceMode::Blocked,
                    ReadinessReason::NotAtPrompt,
                )
            } else if !snapshot.has_view {
                (
                    false,
                    true,
                    AcceptanceMode::Queued,
                    ReadinessReason::ViewUnattached,
                )
            } else {
                (
                    true,
                    true,
                    AcceptanceMode::Immediate,
                    ReadinessReason::Ready,
                )
            };
        Self {
            ready,
            can_accept,
            mode,
            reason,
        }
    }
    pub fn project(self, authorized: bool) -> Self {
        if authorized {
            self
        } else {
            Self {
                ready: false,
                can_accept: false,
                mode: AcceptanceMode::Blocked,
                reason: ReadinessReason::McpControlRequired,
            }
        }
    }
    pub fn insert(self, out: &mut Map<String, Value>) {
        out.insert("can_accept_exec".into(), self.can_accept.into());
        out.insert("ready_for_exec".into(), self.ready.into());
        out.insert(
            "exec_acceptance_mode".into(),
            serde_json::to_value(self.mode).unwrap(),
        );
        out.insert(
            "readiness_reason".into(),
            serde_json::to_value(self.reason).unwrap(),
        );
    }
}

fn one() -> i64 {
    1
}
fn default_command() -> String {
    "claude".into()
}
fn default_timeout() -> i64 {
    30_000
}
#[derive(Debug, Clone, Deserialize)]
pub struct LaunchOptions {
    pub directory: Option<String>,
    pub window_id: Option<i64>,
    #[serde(default = "default_command")]
    pub agent_command: String,
    pub prompt: Option<String>,
    #[serde(default = "one")]
    pub count: i64,
    pub pr_number: Option<i64>,
    #[serde(default = "default_timeout")]
    pub ready_timeout_ms: i64,
}
impl LaunchOptions {
    pub fn parse(args: &Map<String, Value>) -> Result<Self, String> {
        let options: Self = serde_json::from_value(Value::Object(args.clone()))
            .map_err(|e| format!("Invalid agent_launch arguments: {e}"))?;
        if options.agent_command.trim().is_empty() {
            return Err("agent_command must not be empty".into());
        }
        Ok(options)
    }
    pub fn bounded_count(&self) -> usize {
        self.count.clamp(1, 50) as usize
    }
    pub fn timeout_ms(&self) -> u64 {
        self.ready_timeout_ms.clamp(1_000, 120_000) as u64
    }
    pub fn prompt_timeout_ms(&self) -> u64 {
        self.timeout_ms().min(25_000)
    }
    pub fn command(&self) -> String {
        if let Some(pr) = self.pr_number {
            format!("gh pr checkout {pr} && {}", self.agent_command)
        } else {
            self.agent_command.clone()
        }
    }
}
pub fn bounded_wait_timeout(value: i64) -> u64 {
    value.clamp(0, 120_000) as u64
}
pub fn poll_interval(
    elapsed: std::time::Duration,
    remaining: std::time::Duration,
) -> std::time::Duration {
    std::time::Duration::from_secs_f64((0.1 + elapsed.as_secs_f64() * 0.1).min(0.5)).min(remaining)
}
pub fn input_ready(output: &str, provider: Option<&str>, responsive: bool) -> bool {
    let output = output.to_lowercase();
    let mut needles = vec![
        "openai codex",
        "queued follow-up inputs",
        "usage limit resets",
        "claude code",
        "google gemini",
    ];
    if responsive {
        needles.extend(["thinking", "working..."]);
    }
    match provider.unwrap_or_default().to_lowercase() {
        provider if provider.contains("codex") => needles.push("gpt-"),
        provider if provider.contains("claude") => needles.extend(["sonnet", "opus", "haiku"]),
        provider if provider.contains("gemini") => needles.extend(["google gemini", "gemini cli"]),
        _ => {}
    }
    needles.into_iter().any(|needle| output.contains(needle))
}
pub fn visibility_needles(prompt: &str) -> Vec<String> {
    prompt
        .lines()
        .map(str::trim)
        .filter(|line| line.chars().count() >= 8)
        .take(3)
        .map(|line| line.chars().take(80).collect())
        .collect()
}
fn nonempty(value: Option<&Value>) -> bool {
    value
        .and_then(Value::as_str)
        .is_some_and(|s| !s.trim().is_empty())
}
pub fn agent_running(status: &Map<String, Value>) -> bool {
    status.get("active_run").is_some_and(Value::is_object)
        || (["active_app", "raw_active_app", "ai_provider"]
            .iter()
            .any(|key| nonempty(status.get(*key)))
            && ["status", "raw_status"].iter().any(|key| {
                status.get(*key).and_then(Value::as_str).is_some_and(|s| {
                    matches!(
                        s,
                        "running" | "waitingForInput" | "approvalRequired" | "stuck"
                    )
                })
            }))
}
pub fn exited_before_prompt(status: &Map<String, Value>) -> bool {
    !nonempty(status.get("raw_active_app"))
        && !status.get("active_run").is_some_and(Value::is_object)
        && ["status", "raw_status"].iter().any(|key| {
            status
                .get(*key)
                .and_then(Value::as_str)
                .is_some_and(|s| matches!(s, "done" | "exited"))
        })
        && [
            "raw_is_at_prompt",
            "is_at_prompt",
            "can_accept_exec",
            "ready_for_exec",
        ]
        .iter()
        .any(|key| status.get(*key).and_then(Value::as_bool) == Some(true))
}
#[derive(Debug, Clone, Serialize)]
pub struct PromptResult {
    #[serde(rename = "prompt")]
    pub status: &'static str,
    pub prompt_input_visible: bool,
    pub prompt_submitted: bool,
    pub agent_running: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}
impl PromptResult {
    pub fn skipped() -> Self {
        Self {
            status: "skipped",
            prompt_input_visible: false,
            prompt_submitted: false,
            agent_running: false,
            error: None,
        }
    }
    pub fn failed(status: &'static str, error: impl Into<String>) -> Self {
        Self {
            status,
            error: Some(error.into()),
            ..Self::skipped()
        }
    }
    pub fn submitted(input_visible: bool, running: bool) -> Self {
        let (status, error) = match (input_visible, running) {
            (true, true) => ("sent", None),
            (false, true) => ("sent_unverified", Some("prompt was submitted and the agent is running, but prompt echo was not observed before submit".into())),
            (false, false) => ("input_not_visible", Some("prompt text was not observed in the tab before submit".into())),
            (true, false) => ("submitted_not_running", Some("prompt was submitted, but the tab did not report a running agent".into())),
        };
        Self {
            status,
            prompt_input_visible: input_visible,
            prompt_submitted: true,
            agent_running: running,
            error,
        }
    }
    pub fn accepted(&self) -> bool {
        self.prompt_submitted && self.agent_running
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    #[test]
    fn grants_bind_owner_and_terminal_and_are_process_local() {
        let tab = Uuid::new_v4();
        let mut grants = ControlGrants::default();
        grants.connect("one").unwrap();
        grants.connect("two").unwrap();
        assert!(!grants.allows(tab, "one", "terminal"));
        grants
            .grant(tab, "one", "terminal", GrantOrigin::Created)
            .unwrap();
        assert!(grants.allows(tab, "one", "terminal"));
        assert!(!grants.allows(tab, "two", "terminal"));
        assert!(!grants.allows(tab, "one", "replacement"));
        assert!(grants.release(tab, "two", "terminal").is_err());
        assert_eq!(grants.disconnect("two"), Vec::<Uuid>::new());
        assert_eq!(grants.disconnect("one"), vec![tab]);
        assert!(!grants.allows(tab, "one", "terminal"));
        assert!(
            grants
                .grant(tab, "one", "terminal", GrantOrigin::Created)
                .is_err()
        );
        assert!(
            grants
                .grant(tab, "", "terminal", GrantOrigin::Created)
                .is_err()
        );
    }
    #[test]
    fn confirmed_transfer_and_release_are_exact() {
        let tab = Uuid::new_v4();
        let mut grants = ControlGrants::default();
        grants.connect("one").unwrap();
        grants.connect("two").unwrap();
        grants
            .grant(tab, "one", "old", GrantOrigin::Created)
            .unwrap();
        grants
            .grant(tab, "two", "new", GrantOrigin::UserConfirmed)
            .unwrap();
        assert!(!grants.allows(tab, "one", "old"));
        assert!(grants.release(tab, "two", "new").is_ok());
        assert!(!grants.allows(tab, "two", "new"));
    }
    #[test]
    fn readiness_matches_current_swift_priority() {
        let mut snapshot = ExecutionSnapshot {
            shell_loading: true,
            at_prompt: false,
            has_view: false,
            status: "running".into(),
            approval_pending: false,
        };
        assert_eq!(
            Readiness::evaluate(&snapshot).reason,
            ReadinessReason::ShellLoading
        );
        assert!(Readiness::evaluate(&snapshot).can_accept);
        snapshot.approval_pending = true;
        assert!(!Readiness::evaluate(&snapshot).can_accept);
        snapshot.approval_pending = false;
        snapshot.status = " exited ".into();
        assert_eq!(
            Readiness::evaluate(&snapshot).reason,
            ReadinessReason::Exited
        );
        snapshot.status = "idle".into();
        snapshot.shell_loading = false;
        assert_eq!(
            Readiness::evaluate(&snapshot).reason,
            ReadinessReason::NotAtPrompt
        );
        snapshot.at_prompt = true;
        assert_eq!(
            Readiness::evaluate(&snapshot).reason,
            ReadinessReason::ViewUnattached
        );
        snapshot.has_view = true;
        let ready = Readiness::evaluate(&snapshot);
        assert!(ready.ready);
        assert_eq!(
            ready.project(false).reason,
            ReadinessReason::McpControlRequired
        );
        assert!(!ready.project(false).can_accept);
    }
    #[test]
    fn launch_bounds_and_command() {
        let defaults = LaunchOptions::parse(&Map::new()).unwrap();
        assert_eq!(defaults.command(), "claude");
        assert_eq!(defaults.bounded_count(), 1);
        let options = LaunchOptions::parse(
            json!({"count":100,"pr_number":229,"agent_command":"codex","ready_timeout_ms":999999})
                .as_object()
                .unwrap(),
        )
        .unwrap();
        assert_eq!(options.command(), "gh pr checkout 229 && codex");
        assert_eq!(options.bounded_count(), 50);
        assert_eq!(options.timeout_ms(), 120000);
        assert_eq!(options.prompt_timeout_ms(), 25000);
        assert_eq!(bounded_wait_timeout(-1), 0);
        assert!(LaunchOptions::parse(json!({"count":"2"}).as_object().unwrap()).is_err());
    }
    #[test]
    fn prompt_checks_report_unverified_handoffs() {
        assert!(input_ready("Claude Code · Sonnet", Some("claude"), false));
        assert!(!input_ready("shell prompt", None, false));
        assert!(input_ready("thinking", None, true));
        assert_eq!(visibility_needles("short\n a sufficiently long task \n second task line\n third task line\n fourth task line").len(),3);
        assert_eq!(visibility_needles(&"é".repeat(100))[0].chars().count(), 80);
        assert_eq!(
            PromptResult::submitted(false, true).status,
            "sent_unverified"
        );
        assert!(PromptResult::submitted(false, true).accepted());
        assert!(!PromptResult::submitted(true, false).accepted());
    }
    #[test]
    fn identities_and_statuses_prevent_shell_false_positives() {
        let shell = json!({"status":"running","is_at_prompt":false});
        assert!(!agent_running(shell.as_object().unwrap()));
        let agent = json!({"status":"approvalRequired","ai_provider":"codex"});
        assert!(agent_running(agent.as_object().unwrap()));
        let exited = json!({"status":"done","raw_is_at_prompt":true});
        assert!(exited_before_prompt(exited.as_object().unwrap()));
        let running = json!({"status":"done","raw_is_at_prompt":true,"active_run":{}});
        assert!(!exited_before_prompt(running.as_object().unwrap()));
    }
}
