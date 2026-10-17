//! Redact sensitive terminal input before it reaches logs, history and
//! analytics.
//!
//! Ports `apps/chau7-macos/Sources/Chau7Core/SensitiveInputGuard.swift`.
//! Commands that embed credentials as arguments are safe to run but must not
//! be stored verbatim; input typed while echo is off (a password prompt) is
//! never stored.

use crate::command_detection::{
    SUDO_OPTIONS_WITH_VALUE, WRAPPER_COMMANDS, normalize_token, tokenize,
};
use crate::escape_sanitizer::trim_whitespaces_and_newlines;

pub const REDACTED_PLACEHOLDER: &str = "[REDACTED SENSITIVE INPUT]";

/// Patterns that indicate a command contains inline secrets (compared
/// case-insensitively).
pub const SENSITIVE_ARGUMENT_PATTERNS: &[&str] = &[
    "-p ",
    "-p=",
    "--password=",
    "--password ",
    "--passphrase=",
    "--passphrase ",
    "--token=",
    "--token ",
    "--secret=",
    "--secret ",
    "--api-key=",
    "--api-key ",
    "--apikey=",
    "--apikey ",
    "--auth-token=",
    "authorization: bearer",
    "authorization:bearer",
    "authorization: basic",
    "authorization:basic",
    "-H 'Authorization",
    "-H \"Authorization",
    "PASSWORD=",
    "TOKEN=",
    "SECRET=",
    "API_KEY=",
    "AWS_SECRET_ACCESS_KEY=",
    "GITHUB_TOKEN=",
    "GH_TOKEN=",
];

pub fn contains_inline_secrets(text: &str) -> bool {
    let lowered = text.to_lowercase();
    SENSITIVE_ARGUMENT_PATTERNS
        .iter()
        .any(|pattern| lowered.contains(&pattern.to_lowercase()))
}

/// False for input typed with echo off and for blank input.
pub fn should_persist_input(text: &str, echo_disabled: bool) -> bool {
    if echo_disabled {
        return false;
    }
    !trim_whitespaces_and_newlines(text).is_empty()
}

/// The command as it may be stored: unchanged when safe, the placeholder (with
/// the command name in front, when one can be found) when it holds inline
/// secrets or was typed with echo off, `None` when blank.
pub fn sanitized_command_for_persistence(command: &str, echo_disabled: bool) -> Option<String> {
    let trimmed = trim_whitespaces_and_newlines(command);
    if trimmed.is_empty() {
        return None;
    }
    if echo_disabled {
        return Some(REDACTED_PLACEHOLDER.to_string());
    }
    if contains_inline_secrets(trimmed) {
        return Some(match command_summary(trimmed) {
            Some(summary) => format!("{summary} {REDACTED_PLACEHOLDER}"),
            None => REDACTED_PLACEHOLDER.to_string(),
        });
    }
    Some(trimmed.to_string())
}

/// A typed line as it may be stored: `None` for echo-off or blank input,
/// newlines turned into spaces, then [`sanitized_command_for_persistence`].
pub fn sanitized_input_line_for_persistence(text: &str, echo_disabled: bool) -> Option<String> {
    if !should_persist_input(text, echo_disabled) {
        return None;
    }
    let replaced = text.replace(['\n', '\r'], " ");
    let normalized = trim_whitespaces_and_newlines(&replaced);
    if normalized.is_empty() {
        return None;
    }
    sanitized_command_for_persistence(normalized, false)
}

/// The command name, skipping env assignments, `sudo` with its options and
/// wrapper commands such as `command` and `exec`.
fn command_summary(command: &str) -> Option<String> {
    let tokens = tokenize(command);
    if tokens.is_empty() {
        return None;
    }

    let mut index = 0;
    while index < tokens.len() {
        let token = &tokens[index];
        if token == "--" {
            index += 1;
            break;
        }
        if is_environment_assignment(token) {
            index += 1;
            continue;
        }

        let normalized = normalize_token(token);
        if normalized == "sudo" {
            index += 1;
            while index < tokens.len() {
                let option = &tokens[index];
                if option == "--" {
                    index += 1;
                    break;
                }
                if !option.starts_with('-') {
                    break;
                }
                if SUDO_OPTIONS_WITH_VALUE.contains(&option.as_str()) && index + 1 < tokens.len() {
                    index += 2;
                } else {
                    index += 1;
                }
            }
            continue;
        }

        if WRAPPER_COMMANDS.contains(&normalized.as_str()) {
            index += 1;
            continue;
        }

        return Some(normalized);
    }

    tokens.get(index).map(|token| normalize_token(token))
}

fn is_environment_assignment(token: &str) -> bool {
    match token.find('=') {
        Some(equals) if equals > 0 => !token[..equals].contains('/'),
        _ => false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn contains_inline_secrets_detects_bearer_header() {
        assert!(contains_inline_secrets(
            "curl -H 'Authorization: Bearer secret-token' https://example.com" // gitleaks:allow - deliberately fake bearer token tests detection
        ));
    }

    #[test]
    fn sanitized_command_keeps_safe_commands() {
        assert_eq!(
            sanitized_command_for_persistence("claude --continue", false).as_deref(),
            Some("claude --continue")
        );
    }

    #[test]
    fn sanitized_command_redacts_inline_secret_but_preserves_command_summary() {
        assert_eq!(
            sanitized_command_for_persistence("TOKEN=supersecret claude --continue", false),
            Some(format!("claude {REDACTED_PLACEHOLDER}"))
        );
    }

    #[test]
    fn sanitized_command_skips_sudo_wrapper_in_summary() {
        assert_eq!(
            sanitized_command_for_persistence("sudo docker login --password hunter2", false),
            Some(format!("docker {REDACTED_PLACEHOLDER}"))
        );
    }

    #[test]
    fn sanitized_command_redacts_echo_disabled_input() {
        assert_eq!(
            sanitized_command_for_persistence("hunter2", true).as_deref(),
            Some(REDACTED_PLACEHOLDER)
        );
    }

    #[test]
    fn sanitized_input_line_drops_echo_disabled_input() {
        assert_eq!(
            sanitized_input_line_for_persistence("hunter2\n", true),
            None
        );
    }

    #[test]
    fn sanitized_input_line_normalizes_newlines() {
        assert_eq!(
            sanitized_input_line_for_persistence("echo hello\r\n", false).as_deref(),
            Some("echo hello")
        );
    }

    // Branches without a Swift test.

    #[test]
    fn blank_input_is_dropped_and_summary_handles_options() {
        assert_eq!(sanitized_command_for_persistence("  \n", false), None);
        assert_eq!(sanitized_input_line_for_persistence(" \r\n ", false), None);
        // sudo option with a value is skipped; wrapper command is skipped.
        assert_eq!(
            sanitized_command_for_persistence("sudo -u bob command mysql -p secret", false),
            Some(format!("mysql {REDACTED_PLACEHOLDER}"))
        );
        // Nothing but an assignment: no command name to keep.
        assert_eq!(
            sanitized_command_for_persistence("--token=abc", false).as_deref(),
            Some(REDACTED_PLACEHOLDER)
        );
    }
}
