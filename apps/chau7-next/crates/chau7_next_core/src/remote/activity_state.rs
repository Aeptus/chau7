//! Remote activity state: project tab activity candidates into the single
//! activity shown on iOS (Live Activity).
//!
//! Port of `RemoteActivityState.swift` (`apps/chau7-macos/Sources/Chau7Core`).
//! It needs no AI event types: candidates carry plain strings and the local
//! [`RemoteActivityStatus`] enum. JSON keys follow the Swift `CodingKeys`;
//! `RemoteActivityApproval` has none, so its keys are the Swift property names
//! (`requestID`, `command`, `flaggedCommand`). Status raw values are the Swift
//! case names (`waitingInput`, not `waiting_input`). Dates are seconds since
//! 2001-01-01 UTC.

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum RemoteActivityStatus {
    #[serde(rename = "idle")]
    Idle,
    #[serde(rename = "running")]
    Running,
    #[serde(rename = "waitingInput")]
    WaitingInput,
    #[serde(rename = "completed")]
    Completed,
    #[serde(rename = "failed")]
    Failed,
}

#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct RemoteActivityApproval {
    #[serde(rename = "requestID")]
    pub request_id: String,
    pub command: String,
    #[serde(rename = "flaggedCommand")]
    pub flagged_command: String,
}

impl RemoteActivityApproval {
    pub fn new(
        request_id: impl Into<String>,
        command: impl Into<String>,
        flagged_command: impl Into<String>,
    ) -> Self {
        Self {
            request_id: request_id.into(),
            command: command.into(),
            flagged_command: flagged_command.into(),
        }
    }

    /// The flagged command when it is non-blank, otherwise the full command.
    pub fn display_command(&self) -> &str {
        let trimmed = self.flagged_command.trim();
        if trimmed.is_empty() {
            &self.command
        } else {
            trimmed
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RemoteActivityCandidate {
    pub activity_id: String,
    pub tab_id: u32,
    pub tab_title: String,
    pub tool_name: String,
    pub project_name: Option<String>,
    pub session_id: Option<String>,
    pub status: RemoteActivityStatus,
    pub detail: Option<String>,
    pub is_selected: bool,
    pub updated_at: DateTime<Utc>,
    pub started_at: Option<DateTime<Utc>>,
    pub approval: Option<RemoteActivityApproval>,
}

impl RemoteActivityCandidate {
    /// Candidate with all optional fields unset (the Swift init defaults).
    pub fn new(
        activity_id: impl Into<String>,
        tab_id: u32,
        tab_title: impl Into<String>,
        tool_name: impl Into<String>,
        status: RemoteActivityStatus,
        is_selected: bool,
        updated_at: DateTime<Utc>,
    ) -> Self {
        Self {
            activity_id: activity_id.into(),
            tab_id,
            tab_title: tab_title.into(),
            tool_name: tool_name.into(),
            project_name: None,
            session_id: None,
            status,
            detail: None,
            is_selected,
            updated_at,
            started_at: None,
            approval: None,
        }
    }
}

/// JSON body of `ACTIVITY_STATE` (0x12).
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct RemoteActivityState {
    pub activity_id: String,
    pub tab_id: u32,
    pub tab_title: String,
    pub tool_name: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub project_name: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub session_id: Option<String>,
    pub status: RemoteActivityStatus,
    pub headline: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub detail: Option<String>,
    pub is_selected_tab: bool,
    #[serde(
        default,
        skip_serializing_if = "Option::is_none",
        with = "super::apple_date::option"
    )]
    pub started_at: Option<DateTime<Utc>>,
    #[serde(with = "super::apple_date")]
    pub updated_at: DateTime<Utc>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub approval: Option<RemoteActivityApproval>,
}

/// Pick the single highest-priority non-idle candidate (`RemoteActivityProjection`).
pub fn project(candidates: &[RemoteActivityCandidate]) -> Option<RemoteActivityState> {
    // Swift's `max(by:)` keeps the first element on ties; reproduce that.
    let mut best: Option<&RemoteActivityCandidate> = None;
    for c in candidates
        .iter()
        .filter(|c| c.status != RemoteActivityStatus::Idle)
    {
        best = match best {
            Some(current) if !is_lower_priority(current, c) => Some(current),
            _ => Some(c),
        };
    }
    let best = best?;

    Some(RemoteActivityState {
        activity_id: best.activity_id.clone(),
        tab_id: best.tab_id,
        tab_title: best.tab_title.clone(),
        tool_name: best.tool_name.clone(),
        project_name: best.project_name.clone(),
        session_id: best.session_id.clone(),
        status: best.status,
        headline: headline(best),
        detail: normalized_detail(best),
        is_selected_tab: best.is_selected,
        started_at: best.started_at,
        updated_at: best.updated_at,
        approval: best.approval.clone(),
    })
}

fn is_lower_priority(lhs: &RemoteActivityCandidate, rhs: &RemoteActivityCandidate) -> bool {
    let (lp, rp) = (priority(lhs.status), priority(rhs.status));
    if lp != rp {
        return lp < rp;
    }
    if lhs.is_selected != rhs.is_selected {
        return !lhs.is_selected && rhs.is_selected;
    }
    if lhs.updated_at != rhs.updated_at {
        return lhs.updated_at < rhs.updated_at;
    }
    lhs.tab_id < rhs.tab_id
}

fn priority(status: RemoteActivityStatus) -> i32 {
    match status {
        RemoteActivityStatus::WaitingInput => 4,
        RemoteActivityStatus::Failed => 3,
        RemoteActivityStatus::Running => 2,
        RemoteActivityStatus::Completed => 1,
        RemoteActivityStatus::Idle => 0,
    }
}

fn headline(c: &RemoteActivityCandidate) -> String {
    match c.status {
        RemoteActivityStatus::WaitingInput => {
            if c.approval.is_some() {
                "Approval required".to_string()
            } else {
                format!("{} needs input", c.tool_name)
            }
        }
        RemoteActivityStatus::Failed => format!("{} failed", c.tool_name),
        RemoteActivityStatus::Running => format!("{} is active", c.tool_name),
        RemoteActivityStatus::Completed => format!("{} finished", c.tool_name),
        RemoteActivityStatus::Idle => c.tool_name.clone(),
    }
}

fn normalized_detail(c: &RemoteActivityCandidate) -> Option<String> {
    if let Some(approval) = &c.approval {
        let display = approval.display_command().trim();
        if !display.is_empty() {
            return Some(display.to_string());
        }
    }
    let trimmed = c.detail.as_deref().unwrap_or("").trim();
    if !trimmed.is_empty() {
        return Some(trimmed.to_string());
    }
    let project = c.project_name.as_deref().unwrap_or("").trim();
    if project.is_empty() {
        None
    } else {
        Some(project.to_string())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::{Duration, TimeZone};

    fn at(unix: i64) -> DateTime<Utc> {
        Utc.timestamp_opt(unix, 0).unwrap()
    }

    #[test]
    fn waiting_input_beats_selected_running_session() {
        let now = at(1000);
        let mut running = RemoteActivityCandidate::new(
            "tab-1",
            1,
            "Claude",
            "Claude",
            RemoteActivityStatus::Running,
            true,
            now,
        );
        running.project_name = Some("repo-a".into());
        let mut waiting = RemoteActivityCandidate::new(
            "tab-2",
            2,
            "Codex",
            "Codex",
            RemoteActivityStatus::WaitingInput,
            false,
            now - Duration::seconds(10),
        );
        waiting.project_name = Some("repo-b".into());
        waiting.approval = Some(RemoteActivityApproval::new(
            "req-1",
            "rm -rf build",
            "rm -rf build",
        ));

        let projected = project(&[running, waiting]).unwrap();
        assert_eq!(projected.tab_id, 2);
        assert_eq!(projected.status, RemoteActivityStatus::WaitingInput);
        assert_eq!(projected.headline, "Approval required");
        assert_eq!(projected.detail.as_deref(), Some("rm -rf build"));
    }

    #[test]
    fn selected_running_session_beats_more_recent_background_running_session() {
        let now = at(2000);
        let mut selected = RemoteActivityCandidate::new(
            "tab-1",
            1,
            "Claude",
            "Claude",
            RemoteActivityStatus::Running,
            true,
            now - Duration::seconds(5),
        );
        selected.project_name = Some("repo-a".into());
        let mut background = RemoteActivityCandidate::new(
            "tab-2",
            2,
            "Codex",
            "Codex",
            RemoteActivityStatus::Running,
            false,
            now,
        );
        background.project_name = Some("repo-b".into());

        let projected = project(&[background, selected]).unwrap();
        assert_eq!(projected.tab_id, 1);
        assert_eq!(projected.headline, "Claude is active");
        assert_eq!(projected.detail.as_deref(), Some("repo-a"));
    }

    #[test]
    fn completed_state_uses_explicit_detail() {
        let mut completed = RemoteActivityCandidate::new(
            "tab-3",
            3,
            "Gemini",
            "Gemini",
            RemoteActivityStatus::Completed,
            false,
            at(3000),
        );
        completed.project_name = Some("repo-c".into());
        completed.detail = Some("Updated 4 files".into());

        let projected = project(&[completed]).unwrap();
        assert_eq!(projected.status, RemoteActivityStatus::Completed);
        assert_eq!(projected.headline, "Gemini finished");
        assert_eq!(projected.detail.as_deref(), Some("Updated 4 files"));
    }

    #[test]
    fn idle_only_candidates_return_none() {
        let idle = RemoteActivityCandidate::new(
            "tab-1",
            1,
            "Shell",
            "Claude",
            RemoteActivityStatus::Idle,
            true,
            Utc::now(),
        );
        assert!(project(&[idle]).is_none());
    }

    #[test]
    fn tie_on_everything_but_tab_id_prefers_higher_tab_id() {
        let now = at(10);
        let a = RemoteActivityCandidate::new(
            "a",
            1,
            "A",
            "Claude",
            RemoteActivityStatus::Running,
            false,
            now,
        );
        let b = RemoteActivityCandidate::new(
            "b",
            2,
            "B",
            "Claude",
            RemoteActivityStatus::Running,
            false,
            now,
        );
        assert_eq!(project(&[a.clone(), b.clone()]).unwrap().tab_id, 2);
        assert_eq!(project(&[b, a]).unwrap().tab_id, 2);
    }

    #[test]
    fn blank_flagged_command_falls_back_to_command() {
        let approval = RemoteActivityApproval::new("r", "ls -la", "  \n");
        assert_eq!(approval.display_command(), "ls -la");
    }

    #[test]
    fn json_wire_format_matches_swift_codable() {
        let state = RemoteActivityState {
            activity_id: "tab-2".into(),
            tab_id: 2,
            tab_title: "Codex".into(),
            tool_name: "Codex".into(),
            project_name: None,
            session_id: None,
            status: RemoteActivityStatus::WaitingInput,
            headline: "Approval required".into(),
            detail: Some("rm -rf build".into()),
            is_selected_tab: false,
            started_at: None,
            updated_at: at(1_742_000_000),
            approval: Some(RemoteActivityApproval::new("req-1", "rm", "rm")),
        };
        let value: serde_json::Value =
            serde_json::from_str(&serde_json::to_string(&state).unwrap()).unwrap();
        let obj = value.as_object().unwrap();
        assert_eq!(obj["status"], "waitingInput");
        assert_eq!(obj["updated_at"].to_string(), "763692800");
        assert!(!obj.contains_key("started_at"));
        assert!(!obj.contains_key("project_name"));
        assert_eq!(obj["is_selected_tab"], false);
        let approval = obj["approval"].as_object().unwrap();
        assert_eq!(approval["requestID"], "req-1");
        assert_eq!(approval["flaggedCommand"], "rm");
        let back: RemoteActivityState = serde_json::from_value(value).unwrap();
        assert_eq!(back, state);
    }

    #[test]
    fn status_raw_values() {
        for (status, raw) in [
            (RemoteActivityStatus::Idle, "\"idle\""),
            (RemoteActivityStatus::Running, "\"running\""),
            (RemoteActivityStatus::WaitingInput, "\"waitingInput\""),
            (RemoteActivityStatus::Completed, "\"completed\""),
            (RemoteActivityStatus::Failed, "\"failed\""),
        ] {
            assert_eq!(serde_json::to_string(&status).unwrap(), raw);
        }
    }
}
