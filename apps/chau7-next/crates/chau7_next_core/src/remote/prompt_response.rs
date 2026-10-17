//! Semantic answers are derived from the currently advertised prompt and pane.
use super::interactive_prompt::RemoteInteractivePrompt;
use serde::Deserialize;
use uuid::Uuid;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Action {
    Select,
    Toggle,
    Submit,
    Custom,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RemotePromptResponse {
    pub prompt_id: String,
    pub pane_id: Uuid,
    pub action: Action,
    pub option_id: Option<String>,
    pub custom_text: Option<String>,
}
impl RemotePromptResponse {
    pub fn response_text(
        &self,
        prompt: &RemoteInteractivePrompt,
        tab_id: u32,
        available: &[Uuid],
    ) -> Option<String> {
        if self.prompt_id != prompt.id
            || tab_id != prompt.tab_id
            || prompt.pane_id != Some(self.pane_id)
            || !available.contains(&self.pane_id)
        {
            return None;
        }
        match self.action {
            Action::Select | Action::Toggle => {
                if self.custom_text.is_some() {
                    return None;
                }
                let option = prompt
                    .options
                    .iter()
                    .find(|option| Some(&option.id) == self.option_id.as_ref())?;
                if self.action == Action::Select {
                    return Some(option.response.clone());
                }
                if prompt.is_multi_select != Some(true) {
                    return None;
                }
                let text = option.response.trim_matches(['\r', '\n']);
                (!text.is_empty()).then(|| text.to_string())
            }
            Action::Submit => (prompt.is_multi_select == Some(true)
                && self.option_id.is_none()
                && self.custom_text.is_none())
            .then(|| "\r".into()),
            Action::Custom => {
                if self.option_id.is_some() {
                    return None;
                }
                let text = self.custom_text.as_ref()?.trim();
                if text.is_empty() || text.len() > 16384 || text.chars().any(char::is_control) {
                    return None;
                }
                Some(format!("\u{1b}{text}\r"))
            }
        }
    }
}

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RemotePaneInput {
    pub pane_id: Uuid,
    pub text: Option<String>,
    pub keys: Option<Vec<super::key_input::RemoteKey>>,
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::remote::interactive_prompt::RemoteInteractivePromptOption;
    fn prompt() -> RemoteInteractivePrompt {
        RemoteInteractivePrompt {
            id: "q".into(),
            tab_id: 1,
            tab_title: "Shell".into(),
            tool_name: "Claude".into(),
            project_name: None,
            branch_name: None,
            current_directory: None,
            prompt: "Choose".into(),
            detail: None,
            options: vec![RemoteInteractivePromptOption::new(
                "1", "Keep", "1\r", false,
            )],
            detected_at: chrono::Utc::now(),
            pane_id: Some(Uuid::from_u64_pair(0, 3)),
            is_multi_select: Some(true),
        }
    }
    #[test]
    fn response_requires_current_prompt_tab_and_live_pane() {
        let prompt = prompt();
        let pane = prompt.pane_id.unwrap();
        let mut response = RemotePromptResponse {
            prompt_id: "q".into(),
            pane_id: pane,
            action: Action::Select,
            option_id: Some("1".into()),
            custom_text: None,
        };
        assert_eq!(
            response.response_text(&prompt, 1, &[pane]).as_deref(),
            Some("1\r")
        );
        assert!(response.response_text(&prompt, 2, &[pane]).is_none());
        assert!(response.response_text(&prompt, 1, &[]).is_none());
        response.prompt_id = "stale".into();
        assert!(response.response_text(&prompt, 1, &[pane]).is_none());
    }
    #[test]
    fn toggles_do_not_submit_and_custom_rejects_control_input() {
        let prompt = prompt();
        let pane = prompt.pane_id.unwrap();
        let mut response = RemotePromptResponse {
            prompt_id: "q".into(),
            pane_id: pane,
            action: Action::Toggle,
            option_id: Some("1".into()),
            custom_text: None,
        };
        assert_eq!(
            response.response_text(&prompt, 1, &[pane]).as_deref(),
            Some("1")
        );
        response.action = Action::Custom;
        response.option_id = None;
        response.custom_text = Some("hello\x1b[2J".into());
        assert!(response.response_text(&prompt, 1, &[pane]).is_none());
        response.custom_text = Some(" hello ".into());
        assert_eq!(
            response.response_text(&prompt, 1, &[pane]).as_deref(),
            Some("\x1bhello\r")
        );
    }
}
