//! Detect interactive AI prompts (question plus numbered options) in terminal text.
//!
//! Port of `InteractivePromptDetector.swift` (`apps/chau7-macos/Sources/Chau7Core`).
//! Only Claude and Codex tool names are supported. The signature is the first
//! 12 bytes of SHA-256 over the prompt and options, standard base64.

use crate::remote::interactive_prompt::RemoteInteractivePromptOption;
use base64::Engine as _;
use base64::engine::general_purpose::STANDARD;
use regex::Regex;
use sha2::{Digest, Sha256};
use std::sync::OnceLock;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DetectedInteractivePrompt {
    pub signature: String,
    pub prompt: String,
    pub detail: Option<String>,
    pub options: Vec<RemoteInteractivePromptOption>,
}

/// Look for a prompt in the last 80 lines of `text`.
pub fn detect(text: &str, tool_name: &str) -> Option<DetectedInteractivePrompt> {
    if !supports(tool_name) {
        return None;
    }

    let normalized = text.replace("\r\n", "\n").replace('\r', "\n");
    if normalized.is_empty() {
        return None;
    }

    let all_lines: Vec<&str> = normalized.split('\n').collect();
    let start = all_lines.len().saturating_sub(80);
    let lines = &all_lines[start..];

    let (prompt, detail, options) = find_prompt(lines)?;
    let signature = signature(&prompt, &options);
    Some(DetectedInteractivePrompt {
        signature,
        prompt,
        detail,
        options,
    })
}

fn supports(tool_name: &str) -> bool {
    let normalized = tool_name.trim().to_lowercase();
    normalized.contains("claude") || normalized.contains("codex")
}

type FoundPrompt = (String, Option<String>, Vec<RemoteInteractivePromptOption>);

fn find_prompt(lines: &[&str]) -> Option<FoundPrompt> {
    for index in (0..lines.len()).rev() {
        let line = cleaned_line(lines[index]);
        if !is_prompt_line(&line) {
            continue;
        }
        let options = parse_options(lines, index);
        if options.len() < 2 {
            continue;
        }
        let detail = parse_detail(lines, index);
        return Some((line, detail, options));
    }
    None
}

fn parse_options(lines: &[&str], prompt_index: usize) -> Vec<RemoteInteractivePromptOption> {
    let mut options = Vec::new();

    for offset in 1..=8 {
        let index = prompt_index + offset;
        if index >= lines.len() {
            break;
        }

        let raw = cleaned_line(lines[index]);
        if raw.is_empty() {
            if !options.is_empty() {
                break;
            }
            continue;
        }

        if let Some(option) = parse_option(&raw) {
            options.push(option);
            continue;
        }

        if !options.is_empty() {
            break;
        }
    }

    options
}

fn option_regex() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    // ICU's `.` excludes all line terminators (\n \v \f \r \u{85} \u{2028} \u{2029}).
    RE.get_or_init(|| {
        Regex::new(r"^[^A-Za-z0-9]*([0-9]+)\.\s+([^\n\x0B\x0C\r\x{85}\x{2028}\x{2029}]+?)$")
            .expect("valid option regex")
    })
}

fn parse_option(line: &str) -> Option<RemoteInteractivePromptOption> {
    let line = line.trim();
    let caps = option_regex().captures(line)?;
    let token = caps.get(1)?.as_str();
    let label = caps.get(2)?.as_str().trim();
    if label.is_empty() {
        return None;
    }

    const DESTRUCTIVE_WORDS: [&str; 6] = ["deny", "reject", "cancel", "abort", "stop", "no"];
    let lowered = label.to_lowercase();
    let is_destructive = DESTRUCTIVE_WORDS.iter().any(|w| lowered.contains(w));
    Some(RemoteInteractivePromptOption {
        id: token.to_string(),
        label: label.to_string(),
        response: format!("{token}\r"),
        is_destructive,
    })
}

fn parse_detail(lines: &[&str], index: usize) -> Option<String> {
    let mut details: Vec<String> = Vec::new();

    for offset in 1..=2 {
        let Some(previous_index) = index.checked_sub(offset) else {
            break;
        };
        let candidate = cleaned_line(lines[previous_index]);
        if candidate.is_empty() || is_meta_line(&candidate) || is_prompt_line(&candidate) {
            continue;
        }
        details.insert(0, candidate);
    }

    if details.is_empty() {
        None
    } else {
        Some(details.join("\n"))
    }
}

fn cleaned_line(line: &str) -> String {
    line.replace('\u{00A0}', " ").trim().to_string()
}

fn is_meta_line(line: &str) -> bool {
    let lowered = line.to_lowercase();
    lowered.contains("esc to cancel")
        || lowered.contains("tab to amend")
        || lowered.contains("ctrl+e")
        || lowered.contains("press ctrl")
        || lowered.contains("ctrl+c")
}

fn is_prompt_line(line: &str) -> bool {
    const KEYWORDS: [&str; 8] = [
        "do you want",
        "select an option",
        "choose an option",
        "which option",
        "continue",
        "proceed",
        "approve",
        "allow this",
    ];
    let lowered = line.to_lowercase();
    KEYWORDS.iter().any(|k| lowered.contains(k))
}

fn signature(prompt: &str, options: &[RemoteInteractivePromptOption]) -> String {
    let joined = options
        .iter()
        .map(|o| format!("{}:{}", o.id, o.label))
        .collect::<Vec<_>>()
        .join("\n");
    let basis = format!("{prompt}\n{joined}");
    let digest = Sha256::digest(basis.as_bytes());
    STANDARD.encode(&digest[..12])
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn detects_claude_proceed_prompt() {
        let transcript = "⏺ Bash(run dangerous command)\n\nBash command\n\nrun dangerous command\n\nDo you want to proceed?\n❯ 1. Yes\n  2. No\n\nEsc to cancel · Tab to amend · ctrl+e to explain";

        let prompt = detect(transcript, "Claude").unwrap();
        assert_eq!(prompt.prompt, "Do you want to proceed?");
        let ids: Vec<&str> = prompt.options.iter().map(|o| o.id.as_str()).collect();
        assert_eq!(ids, vec!["1", "2"]);
        let labels: Vec<&str> = prompt.options.iter().map(|o| o.label.as_str()).collect();
        assert_eq!(labels, vec!["Yes", "No"]);
        let responses: Vec<&str> = prompt.options.iter().map(|o| o.response.as_str()).collect();
        assert_eq!(responses, vec!["1\r", "2\r"]);
        assert!(prompt.options[1].is_destructive);
        assert!(!prompt.options[0].is_destructive);
        assert_eq!(prompt.detail.as_deref(), Some("run dangerous command"));
        // Golden: base64(sha256("Do you want to proceed?\n1:Yes\n2:No")[..12]).
        assert_eq!(prompt.signature, "EstQjN8K5+pgVACs");
    }

    #[test]
    fn detects_codex_option_prompt() {
        let transcript = "Command contains $() command substitution\n\nDo you want to continue?\n1. Continue\n2. Cancel";

        let prompt = detect(transcript, "Codex").unwrap();
        assert_eq!(prompt.prompt, "Do you want to continue?");
        let labels: Vec<&str> = prompt.options.iter().map(|o| o.label.as_str()).collect();
        assert_eq!(labels, vec!["Continue", "Cancel"]);
        assert_eq!(prompt.signature, "Yp0xbM3+mxyTiQ+q");
    }

    #[test]
    fn detects_codex_prompt_without_question_mark() {
        let transcript = "Security review is required before execution\n\nSelect an option\n1. Approve\n2. Reject";

        let prompt = detect(transcript, "Codex CLI").unwrap();
        assert_eq!(prompt.prompt, "Select an option");
        let labels: Vec<&str> = prompt.options.iter().map(|o| o.label.as_str()).collect();
        assert_eq!(labels, vec!["Approve", "Reject"]);
    }

    #[test]
    fn ignores_non_supported_tool() {
        let transcript = "Do you want to proceed?\n1. Yes\n2. No";
        assert!(detect(transcript, "Gemini").is_none());
    }

    #[test]
    fn needs_at_least_two_options_and_handles_crlf() {
        assert!(detect("Do you want to proceed?\n1. Yes", "claude").is_none());
        assert!(detect("", "claude").is_none());
        let crlf = "Do you want to proceed?\r\n1. Yes\r\n2. No\r\n";
        assert_eq!(detect(crlf, "claude").unwrap().options.len(), 2);
    }

    #[test]
    fn only_last_80_lines_are_scanned() {
        let mut text = String::from("Do you want to proceed?\n1. Yes\n2. No\n");
        for _ in 0..85 {
            text.push_str("filler\n");
        }
        assert!(detect(&text, "claude").is_none());
    }
}
