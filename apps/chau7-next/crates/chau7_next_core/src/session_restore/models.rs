//! Framework-independent saved restore schema; optional metadata remains backward compatible.
use crate::session_restore::SavedSplitNode;
use crate::token_optimization::TabTokenOptOverride;
use serde::{Deserialize, Serialize};
use std::path::PathBuf;

/// Resume fields kept verbatim for migrations and future recovery. This is
/// archival data only: restore code must never treat its command as executable.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct ArchivedAIResumeMetadata {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub provider: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub session_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub session_id_source: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub resume_command: Option<String>,
}

/// Swift tab context that Chau7 Next does not yet render. Command blocks and
/// preview bytes remain opaque persisted data; callers must validate them
/// before any future display or action.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct ArchivedTabContext {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub command_blocks: Option<Vec<serde_json::Value>>,
    /// Swift's JSONEncoder representation of `Data` (standard base64).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub preview_snapshot_png_data: Option<String>,
}

/// What is saved for one terminal pane (`SavedTerminalPaneState`). The
/// scrollback text itself lives in `DataRoot::scrollback_dir()/<id>.txt`.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct SavedPane {
    pub id: u64,
    pub directory: Option<String>,
    /// A scrollback file exists for this pane.
    #[serde(default)]
    pub scrollback: bool,
    pub ai_provider: Option<String>,
    pub ai_session_id: Option<String>,
    /// `claude --resume <id>` or `codex resume <id>`, typed into the prompt
    /// (not run) after the restore.
    pub ai_resume_command: Option<String>,
    /// Raw Swift resume metadata retained separately from the active resume
    /// fields. This field is inert archival state.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub archived_ai_resume: Option<ArchivedAIResumeMetadata>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ai_session_id_source: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub agent_launch_command: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_input_at: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_output_at: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub agent_started_at: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_exit_at: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub known_repo_root: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub known_git_branch: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_status: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_exit_code: Option<i32>,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct SavedTab {
    /// Stable tab identity (`OverlayTab.id`), the same after relaunch.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub uuid: Option<uuid::Uuid>,
    pub cwd: Option<PathBuf>,
    pub custom_title: Option<String>,
    pub color: Option<String>,
    pub repo_group_id: Option<String>,
    /// Per-tab token optimization override (`tokenOptOverride`), absent for "default".
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub token_opt_override: Option<TabTokenOptOverride>,
    /// When the tab was created, Unix seconds (`createdAt`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub created_at: Option<f64>,
    /// The color was picked by hand (beats the automatic AI color).
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub manual_color: bool,
    /// Split layout of the tab (`splitLayout`); `None` for a single shell
    /// started in `cwd` (sessions saved by older versions).
    #[serde(default)]
    pub layout: Option<SavedSplitNode>,
    /// Focused terminal pane (`focusedPaneID`).
    #[serde(default)]
    pub focused_pane: Option<u64>,
    /// Swift tab previews and command history not currently rendered by Next.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub archived_context: Option<ArchivedTabContext>,
    #[serde(default)]
    pub panes: Vec<SavedPane>,
}

impl SavedTab {
    /// Saved terminal presentation remains available before any PTY/view exists.
    pub fn focused_terminal(&self) -> Option<&SavedPane> {
        self.panes
            .iter()
            .find(|pane| Some(pane.id) == self.focused_pane)
            .or_else(|| self.panes.first())
    }

    /// Primary terminal follows visual split order, independently of focus.
    pub fn primary_terminal(&self) -> Option<&SavedPane> {
        match self.layout.as_ref() {
            Some(layout) => layout
                .terminal_ids()
                .first()
                .and_then(|id| self.panes.iter().find(|pane| pane.id == *id)),
            None => self.panes.first(),
        }
    }
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct SavedWindow {
    pub tabs: Vec<SavedTab>,
    pub selected: usize,
    pub x: f32,
    pub y: f32,
    pub width: f32,
    pub height: f32,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct SavedSession {
    pub version: u32,
    pub windows: Vec<SavedWindow>,
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::session_restore::SavedAxis;
    #[test]
    fn old_saved_pane_omits_new_metadata_and_decodes_unchanged() {
        let value = serde_json::json!({"id":7,"directory":"/repo","scrollback":true,"ai_provider":"codex","ai_session_id":"thread-1","ai_resume_command":"codex resume thread-1"});
        let pane: SavedPane = serde_json::from_value(value.clone()).unwrap();
        assert_eq!(pane.last_input_at, None);
        assert_eq!(pane.ai_session_id_source, None);
        assert_eq!(serde_json::to_value(pane).unwrap(), value);
    }
    #[test]
    fn primary_terminal_uses_first_visual_terminal_even_when_another_is_focused() {
        let saved = SavedTab {
            layout: Some(SavedSplitNode::Split {
                id: 1,
                axis: SavedAxis::Horizontal,
                ratios: vec![0.5, 0.5],
                children: vec![
                    SavedSplitNode::Terminal {
                        id: 10,
                        directory: Some("/primary".into()),
                    },
                    SavedSplitNode::Terminal {
                        id: 20,
                        directory: Some("/display".into()),
                    },
                ],
            }),
            focused_pane: Some(20),
            panes: vec![
                SavedPane {
                    id: 20,
                    known_repo_root: Some("/display".into()),
                    ..Default::default()
                },
                SavedPane {
                    id: 10,
                    known_repo_root: Some("/primary".into()),
                    ..Default::default()
                },
            ],
            ..Default::default()
        };
        assert_eq!(saved.primary_terminal().unwrap().id, 10);
        assert_eq!(
            saved.primary_terminal().unwrap().known_repo_root.as_deref(),
            Some("/primary")
        );
        assert_eq!(saved.focused_terminal().unwrap().id, 20);
    }

    #[test]
    fn saved_activity_and_provenance_round_trip_without_defaults_becoming_evidence() {
        let pane = SavedPane {
            id: 4,
            ai_session_id_source: Some("observed".into()),
            last_input_at: Some(10.0),
            last_output_at: Some(11.0),
            last_exit_code: Some(0),
            agent_launch_command: Some("codex resume thread".into()),
            ..Default::default()
        };
        assert_eq!(
            serde_json::from_str::<SavedPane>(&serde_json::to_string(&pane).unwrap()).unwrap(),
            pane
        );
        let empty: SavedPane = serde_json::from_str("{\"id\":5}").unwrap();
        assert_eq!(empty.last_exit_code, None);
        assert_eq!(empty.last_output_at, None);
    }

    #[test]
    fn archived_swift_metadata_round_trips_without_becoming_an_active_resume() {
        let pane = SavedPane {
            id: 9,
            archived_ai_resume: Some(ArchivedAIResumeMetadata {
                provider: Some("codex".into()),
                session_id: Some("synth:fixture".into()),
                session_id_source: Some("synthetic".into()),
                resume_command: None,
            }),
            ..Default::default()
        };
        let tab = SavedTab {
            archived_context: Some(ArchivedTabContext {
                command_blocks: Some(vec![serde_json::json!({"command": "fixture command"})]),
                preview_snapshot_png_data: Some("cG5n".into()),
            }),
            panes: vec![pane],
            ..Default::default()
        };

        let decoded: SavedTab =
            serde_json::from_str(&serde_json::to_string(&tab).unwrap()).unwrap();
        assert_eq!(decoded, tab);
        let archived_pane = &decoded.panes[0];
        assert_eq!(archived_pane.ai_provider, None);
        assert_eq!(archived_pane.ai_session_id, None);
        assert_eq!(archived_pane.ai_resume_command, None);
        assert_eq!(
            archived_pane
                .archived_ai_resume
                .as_ref()
                .and_then(|metadata| metadata.session_id.as_deref()),
            Some("synth:fixture")
        );
    }
}
