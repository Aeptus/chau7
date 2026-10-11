//! Port of `Runtime/AgentBackendProtocol.swift`: the `AgentBackend` trait and
//! `SessionConfig`.

use std::collections::HashMap;

use serde::{Deserialize, Serialize};

/// Describes how to launch and interact with a specific AI CLI agent.
///
/// Backends are stateless: session state lives in the runtime session.
pub trait AgentBackend: Send + Sync {
    /// Display name (e.g. "claude", "codex", "shell").
    fn name(&self) -> &str;

    /// Shell command to launch the backend in a terminal tab.
    fn launch_command(&self, config: &SessionConfig) -> String;

    /// Format a prompt for the agent's stdin. Returns the string to send to the PTY.
    fn format_prompt_input(&self, prompt: &str, context: Option<&str>) -> String;

    /// Provider key for session resume (e.g. Claude's `--resume` flag).
    /// `None` if the backend doesn't support resume.
    fn resume_provider_key(&self) -> Option<&str>;
}

/// Configuration for creating a runtime session.
///
/// JSON keys match the Swift synthesized `Codable` (`resumeSessionID`,
/// `autoApprove`, ...); `None` fields are omitted.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionConfig {
    /// Working directory for the session.
    pub directory: String,
    /// Backend provider name (e.g. "claude", "codex", "shell").
    pub provider: String,
    /// Model override (e.g. "opus", "sonnet").
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub model: Option<String>,
    /// Resume an existing agent session by ID.
    #[serde(
        default,
        rename = "resumeSessionID",
        skip_serializing_if = "Option::is_none"
    )]
    pub resume_session_id: Option<String>,
    /// Extra environment variables for the launched process.
    pub environment: HashMap<String, String>,
    /// Additional CLI arguments for the backend.
    pub args: Vec<String>,
    /// When true, the backend should skip its own permission prompts.
    pub auto_approve: bool,
}

impl SessionConfig {
    /// Same defaults as the Swift initializer: no model, no resume id, empty
    /// environment and args, `auto_approve` false.
    pub fn new(directory: impl Into<String>, provider: impl Into<String>) -> Self {
        Self {
            directory: directory.into(),
            provider: provider.into(),
            model: None,
            resume_session_id: None,
            environment: HashMap::new(),
            args: Vec::new(),
            auto_approve: false,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    struct Echo;
    impl AgentBackend for Echo {
        fn name(&self) -> &str {
            "echo"
        }
        fn launch_command(&self, config: &SessionConfig) -> String {
            format!("echo {}", config.directory)
        }
        fn format_prompt_input(&self, prompt: &str, context: Option<&str>) -> String {
            match context {
                Some(c) => format!("{c}\n{prompt}\n"),
                None => format!("{prompt}\n"),
            }
        }
        fn resume_provider_key(&self) -> Option<&str> {
            None
        }
    }

    #[test]
    fn session_config_defaults() {
        let c = SessionConfig::new("/tmp", "claude");
        assert!(c.model.is_none());
        assert!(c.environment.is_empty());
        assert!(c.args.is_empty());
        assert!(!c.auto_approve);
    }

    #[test]
    fn session_config_json_keys() {
        let mut c = SessionConfig::new("/tmp", "claude");
        c.resume_session_id = Some("abc".into());
        c.auto_approve = true;
        let json = serde_json::to_value(&c).unwrap();
        assert_eq!(json["resumeSessionID"], "abc");
        assert_eq!(json["autoApprove"], true);
        assert!(json.get("model").is_none());
        let back: SessionConfig = serde_json::from_value(json).unwrap();
        assert_eq!(back, c);
    }

    #[test]
    fn backend_trait_is_object_safe() {
        let b: Box<dyn AgentBackend> = Box::new(Echo);
        let c = SessionConfig::new("/x", "echo");
        assert_eq!(b.name(), "echo");
        assert_eq!(b.launch_command(&c), "echo /x");
        assert_eq!(b.format_prompt_input("hi", Some("ctx")), "ctx\nhi\n");
        assert_eq!(b.resume_provider_key(), None);
    }
}
