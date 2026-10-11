//! Ports of `Runtime/Backends/*.swift` (Claude Code, Codex, plain shell) and
//! the backend registry and checks of `RuntimeControlService.swift`
//! (`backends`, `validateModel`, `binaryName`).

use super::agent_backend::{AgentBackend, SessionConfig};
use crate::shell_escaping::{escape_arguments, escape_environment_assignments};

/// `envPrefix + " " + command`, or the command alone.
fn with_env(config: &SessionConfig, command: String) -> String {
    let prefix = escape_environment_assignments(&config.environment);
    if prefix.is_empty() {
        command
    } else {
        format!("{prefix} {command}")
    }
}

/// `<context>\n\n<prompt>\n`, or `<prompt>\n` without context.
fn prompt_with_context(prompt: &str, context: Option<&str>) -> String {
    match context {
        Some(context) if !context.is_empty() => format!("{context}\n\n{prompt}\n"),
        _ => format!("{prompt}\n"),
    }
}

/// `ClaudeCodeBackend`: `claude [--resume ID] [--dangerously-skip-permissions]
/// [--model M] <args>`.
#[derive(Debug, Clone, Copy, Default)]
pub struct ClaudeCodeBackend;

impl AgentBackend for ClaudeCodeBackend {
    fn name(&self) -> &str {
        "claude"
    }

    fn launch_command(&self, config: &SessionConfig) -> String {
        let mut parts = vec!["claude".to_string()];
        if let Some(id) = &config.resume_session_id {
            parts.push("--resume".into());
            parts.push(id.clone());
        }
        if config.auto_approve {
            parts.push("--dangerously-skip-permissions".into());
        }
        if let Some(model) = &config.model {
            parts.push("--model".into());
            parts.push(model.clone());
        }
        parts.extend(config.args.iter().cloned());
        with_env(config, escape_arguments(&parts))
    }

    fn format_prompt_input(&self, prompt: &str, context: Option<&str>) -> String {
        prompt_with_context(prompt, context)
    }

    fn resume_provider_key(&self) -> Option<&str> {
        Some("claude")
    }
}

/// `CodexBackend`: `codex [resume ID] [--full-auto] [--model M] <args>`.
#[derive(Debug, Clone, Copy, Default)]
pub struct CodexBackend;

impl AgentBackend for CodexBackend {
    fn name(&self) -> &str {
        "codex"
    }

    fn launch_command(&self, config: &SessionConfig) -> String {
        let mut parts = vec!["codex".to_string()];
        if let Some(id) = &config.resume_session_id {
            parts.push("resume".into());
            parts.push(id.clone());
        }
        if config.auto_approve {
            parts.push("--full-auto".into());
        }
        if let Some(model) = &config.model {
            parts.push("--model".into());
            parts.push(model.clone());
        }
        parts.extend(config.args.iter().cloned());
        with_env(config, escape_arguments(&parts))
    }

    fn format_prompt_input(&self, prompt: &str, context: Option<&str>) -> String {
        prompt_with_context(prompt, context)
    }

    fn resume_provider_key(&self) -> Option<&str> {
        Some("codex")
    }
}

/// `GenericShellBackend`: runs `args` as the command; no turn semantics
/// (the orchestrator drives it with `tab_send_input`).
#[derive(Debug, Clone, Copy, Default)]
pub struct GenericShellBackend;

impl AgentBackend for GenericShellBackend {
    fn name(&self) -> &str {
        "shell"
    }

    fn launch_command(&self, config: &SessionConfig) -> String {
        let prefix = escape_environment_assignments(&config.environment);
        let command = escape_arguments(&config.args);
        if !prefix.is_empty() && !command.is_empty() {
            format!("{prefix} {command}")
        } else {
            command
        }
    }

    fn format_prompt_input(&self, prompt: &str, _context: Option<&str>) -> String {
        format!("{prompt}\n")
    }

    fn resume_provider_key(&self) -> Option<&str> {
        None
    }
}

/// Registered backend names, sorted (`backends.keys.sorted()`).
pub const BACKEND_NAMES: [&str; 3] = ["claude", "codex", "shell"];

/// The backend registered under `name` (`backends[name]`).
pub fn backend_named(name: &str) -> Option<Box<dyn AgentBackend>> {
    match name {
        "claude" => Some(Box::new(ClaudeCodeBackend)),
        "codex" => Some(Box::new(CodexBackend)),
        "shell" => Some(Box::new(GenericShellBackend)),
        _ => None,
    }
}

/// The error for an unknown backend name.
pub fn unknown_backend_message(name: &str) -> String {
    format!(
        "Unknown backend: {name}. Valid: {}",
        BACKEND_NAMES.join(", ")
    )
}

/// `validateModel`: `None` when the model fits the backend, else the error.
pub fn validate_model(model: &str, backend: &str) -> Option<String> {
    let trimmed = model.trim_matches([' ', '\t']);
    if trimmed.is_empty() {
        return Some("Model name is empty.".into());
    }
    let lower = trimmed.to_lowercase();
    match backend {
        "codex" => ["claude", "sonnet", "opus", "haiku"]
            .iter()
            .any(|p| lower.contains(p))
            .then(|| {
                format!(
                    "Model '{trimmed}' looks like a Claude model but backend is 'codex'. Codex models include: o3, o4-mini, gpt-4.1. Pass model names valid for the Codex CLI."
                )
            }),
        "claude" => ["gpt-", "o1", "o3", "o4", "codex"]
            .iter()
            .any(|p| lower.contains(p))
            .then(|| {
                format!(
                    "Model '{trimmed}' looks like an OpenAI model but backend is 'claude'. Claude models include: opus, sonnet, haiku. Pass model names valid for the Claude CLI."
                )
            }),
        _ => None,
    }
}

/// `binaryName(for:)`: the CLI a backend needs on `PATH`, `None` for the
/// shell backend.
pub fn binary_name(backend: &str) -> Option<&'static str> {
    match backend {
        "claude" => Some("claude"),
        "codex" => Some("codex"),
        _ => None,
    }
}

/// The error when the backend's CLI is not on `PATH`.
pub fn missing_binary_message(backend: &str, binary: &str) -> String {
    format!(
        "Backend '{backend}' requires '{binary}' in PATH but it was not found. Install it first."
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;

    // Ported from BackendLaunchCommandTests.swift.

    #[test]
    fn codex_launch_command_escapes_resume_session_id() {
        let mut config = SessionConfig::new("/tmp", "codex");
        config.resume_session_id = Some("abc; touch /tmp/pwned".into());
        assert_eq!(
            CodexBackend.launch_command(&config),
            "'codex' 'resume' 'abc; touch /tmp/pwned'"
        );
    }

    #[test]
    fn claude_launch_command_escapes_resume_session_id() {
        let mut config = SessionConfig::new("/tmp", "claude");
        config.resume_session_id = Some("abc; touch /tmp/pwned".into());
        assert_eq!(
            ClaudeCodeBackend.launch_command(&config),
            "'claude' '--resume' 'abc; touch /tmp/pwned'"
        );
    }

    #[test]
    fn launch_command_drops_invalid_environment_variable_names() {
        let mut config = SessionConfig::new("/tmp", "claude");
        config.environment = HashMap::from([
            ("SAFE_KEY".to_string(), "safe value".to_string()),
            ("BAD;KEY".to_string(), "touch /tmp/pwned".to_string()),
        ]);
        let command = ClaudeCodeBackend.launch_command(&config);
        assert_eq!(command, "SAFE_KEY='safe value' 'claude'");
        assert!(!command.contains("BAD;KEY"));
        assert!(!command.contains("touch /tmp/pwned"));
    }

    #[test]
    fn shell_backend_preserves_argument_boundaries() {
        let mut config = SessionConfig::new("/tmp", "shell");
        config.args = vec![
            "python3".into(),
            "-c".into(),
            "print('hello world'); touch /tmp/pwned".into(),
        ];
        assert_eq!(
            GenericShellBackend.launch_command(&config),
            "'python3' '-c' 'print('\\''hello world'\\''); touch /tmp/pwned'"
        );
    }

    #[test]
    fn flags_follow_the_swift_order() {
        let mut config = SessionConfig::new("/w", "claude");
        config.auto_approve = true;
        config.model = Some("opus".into());
        config.args = vec!["--verbose".into()];
        assert_eq!(
            ClaudeCodeBackend.launch_command(&config),
            "'claude' '--dangerously-skip-permissions' '--model' 'opus' '--verbose'"
        );
        assert_eq!(
            CodexBackend.launch_command(&config),
            "'codex' '--full-auto' '--model' 'opus' '--verbose'"
        );
        // Shell: no command means no env prefix either.
        let mut shell = SessionConfig::new("/w", "shell");
        shell.environment = HashMap::from([("A".to_string(), "1".to_string())]);
        assert_eq!(GenericShellBackend.launch_command(&shell), "");
        shell.args = vec!["./agent.sh".into()];
        assert_eq!(
            GenericShellBackend.launch_command(&shell),
            "A='1' './agent.sh'"
        );
    }

    #[test]
    fn prompts_carry_context_first() {
        assert_eq!(
            ClaudeCodeBackend.format_prompt_input("do it", Some("ctx")),
            "ctx\n\ndo it\n"
        );
        assert_eq!(
            CodexBackend.format_prompt_input("do it", Some("")),
            "do it\n"
        );
        assert_eq!(
            GenericShellBackend.format_prompt_input("ls", Some("ignored")),
            "ls\n"
        );
    }

    #[test]
    fn registry_and_checks() {
        assert_eq!(backend_named("codex").unwrap().name(), "codex");
        assert!(backend_named("gemini").is_none());
        assert_eq!(
            unknown_backend_message("gemini"),
            "Unknown backend: gemini. Valid: claude, codex, shell"
        );
        assert_eq!(
            validate_model("  ", "claude").as_deref(),
            Some("Model name is empty.")
        );
        assert!(validate_model("sonnet", "claude").is_none());
        assert!(
            validate_model("gpt-4.1", "claude")
                .unwrap()
                .contains("OpenAI model")
        );
        assert!(
            validate_model("Claude-Opus", "codex")
                .unwrap()
                .contains("Claude model")
        );
        assert!(validate_model("o3", "codex").is_none());
        assert!(validate_model("anything", "shell").is_none());
        assert_eq!(binary_name("claude"), Some("claude"));
        assert_eq!(binary_name("shell"), None);
    }
}
