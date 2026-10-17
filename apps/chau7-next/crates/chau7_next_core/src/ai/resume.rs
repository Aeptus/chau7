//! Port of `apps/chau7-macos/Sources/Chau7Core/AIResumeParser.swift`.
//!
//! Dates are `f64` seconds since the Unix epoch (Swift `Date`).

use super::tool_registry::{AI_TOOLS, ResumeFormat, resume_provider_key_for};
use crate::command_detection::{detect_app, normalize_token, tokenize};
use std::time::{SystemTime, UNIX_EPOCH};

/// Swift `Date.distantPast` (0001-01-01T00:00:00Z) as Unix seconds.
pub const DISTANT_PAST: f64 = -62_135_769_600.0;

/// Provider and session id extracted from a resume command
/// (`AIResumeParser.ResumeMetadata`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ResumeMetadata {
    pub provider: String,
    pub session_id: String,
}

/// Extracts AI resume metadata from a command line like
/// `claude --resume abc123` or `codex resume xyz`.
pub fn extract_metadata(command_line: &str) -> Option<ResumeMetadata> {
    let trimmed = command_line.trim();
    if trimmed.is_empty() {
        return None;
    }
    let tokens = tokenize(trimmed);
    if tokens.len() < 3 {
        return None;
    }
    let normalized: Vec<String> = tokens
        .iter()
        .map(|t| normalize_token(t).to_lowercase())
        .collect();
    let first = normalized.first()?;
    for tool in AI_TOOLS {
        let (Some(format), Some(provider_key)) = (tool.resume_format, tool.resume_provider_key)
        else {
            continue;
        };
        if !tool.command_names.contains(&first.as_str()) {
            continue;
        }
        let expected = match format {
            ResumeFormat::DashFlag { flag, .. } => flag,
            ResumeFormat::Subcommand { subcommand, .. } => subcommand,
        };
        if normalized[1] == expected && is_valid_session_id(&normalized[2]) {
            return Some(ResumeMetadata {
                provider: provider_key.to_string(),
                session_id: normalized[2].clone(),
            });
        }
    }
    None
}

/// Detects an AI provider name from a command line. Unlike
/// [`extract_metadata`] this does not require a resume flag.
pub fn detect_provider(command_line: &str) -> Option<String> {
    let app_name = detect_app(command_line)?;
    normalize_provider_name(&app_name)
}

/// Normalizes a known app name to a canonical provider key.
pub fn normalize_provider_name(value: &str) -> Option<String> {
    let trimmed = value.trim();
    if trimmed.is_empty() {
        return None;
    }
    resume_provider_key_for(trimmed).map(str::to_string)
}

/// Validates that a string looks like a plausible session ID: 1 to 36
/// letters, digits, `-` or `_`.
pub fn is_valid_session_id(session_id: &str) -> bool {
    let count = session_id.chars().count();
    if !(1..=36).contains(&count) {
        return false;
    }
    session_id
        .chars()
        .all(|c| c.is_alphabetic() || c.is_numeric() || c == '-' || c == '_')
}

fn unix_now() -> f64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs_f64())
        .unwrap_or(0.0)
}

fn is_usable_reference_date(reference: f64, now: f64) -> bool {
    reference != DISTANT_PAST && reference <= now + 60.0 && reference > DISTANT_PAST
}

/// A session id with its file modification time.
#[derive(Debug, Clone, PartialEq)]
pub struct SessionCandidate {
    pub session_id: String,
    pub touched_at: f64,
}

/// Picks the best session match from multiple candidates using temporal
/// proximity to `reference_date` (the terminal's last output time).
pub fn best_session_match(
    candidates: &[SessionCandidate],
    reference_date: Option<f64>,
) -> Option<String> {
    best_session_match_at(candidates, reference_date, unix_now())
}

/// [`best_session_match`] with an explicit clock.
pub fn best_session_match_at(
    candidates: &[SessionCandidate],
    reference_date: Option<f64>,
    now: f64,
) -> Option<String> {
    if candidates.is_empty() {
        return None;
    }
    if candidates.len() == 1 {
        return Some(candidates[0].session_id.clone());
    }
    let reference = reference_date.filter(|r| is_usable_reference_date(*r, now))?;
    let mut sorted: Vec<&SessionCandidate> = candidates.iter().collect();
    sorted.sort_by(|a, b| {
        let left = (a.touched_at - reference).abs();
        let right = (b.touched_at - reference).abs();
        left.partial_cmp(&right)
            .unwrap_or(std::cmp::Ordering::Equal)
            .then_with(|| {
                b.touched_at
                    .partial_cmp(&a.touched_at)
                    .unwrap_or(std::cmp::Ordering::Equal)
            })
    });
    sorted.first().map(|c| c.session_id.clone())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn cand(id: &str, touched_at: f64) -> SessionCandidate {
        SessionCandidate {
            session_id: id.to_string(),
            touched_at,
        }
    }

    fn meta(provider: &str, id: &str) -> ResumeMetadata {
        ResumeMetadata {
            provider: provider.to_string(),
            session_id: id.to_string(),
        }
    }

    #[test]
    fn extract_metadata_from_claude_resume() {
        assert_eq!(
            extract_metadata("claude --resume abc123"),
            Some(meta("claude", "abc123"))
        );
    }

    #[test]
    fn extract_metadata_from_codex_resume() {
        assert_eq!(
            extract_metadata("codex resume my-session-42"),
            Some(meta("codex", "my-session-42"))
        );
    }

    #[test]
    fn extract_metadata_returns_nil_for_plain_command() {
        assert_eq!(extract_metadata("claude"), None);
        assert_eq!(extract_metadata("ls -la"), None);
        assert_eq!(extract_metadata(""), None);
        assert_eq!(extract_metadata("   "), None);
    }

    #[test]
    fn extract_metadata_rejects_invalid_session_id() {
        assert_eq!(extract_metadata("claude --resume $(whoami)"), None);
        assert_eq!(extract_metadata("claude --resume"), None);
    }

    #[test]
    fn extract_metadata_is_case_insensitive() {
        let result = extract_metadata("Claude --resume ABC123").unwrap();
        assert_eq!(result.provider, "claude");
        assert_eq!(result.session_id, "abc123");
    }

    #[test]
    fn detect_provider_from_claude_command() {
        assert_eq!(detect_provider("claude chat"), Some("claude".to_string()));
    }

    #[test]
    fn detect_provider_from_codex_command() {
        assert_eq!(detect_provider("codex start"), Some("codex".to_string()));
    }

    #[test]
    fn detect_provider_returns_nil_for_unknown() {
        assert_eq!(detect_provider("vim file.txt"), None);
        assert_eq!(detect_provider(""), None);
    }

    #[test]
    fn normalize_provider_name_cases() {
        assert_eq!(
            normalize_provider_name("Claude Code"),
            Some("claude".to_string())
        );
        assert_eq!(normalize_provider_name("codex"), Some("codex".to_string()));
        assert_eq!(
            normalize_provider_name("  CLAUDE  "),
            Some("claude".to_string())
        );
        assert_eq!(normalize_provider_name("vim"), None);
        assert_eq!(normalize_provider_name(""), None);
    }

    #[test]
    fn is_valid_session_id_cases() {
        assert!(is_valid_session_id("abc123"));
        assert!(is_valid_session_id("my-session_42"));
        assert!(!is_valid_session_id(""));
        assert!(!is_valid_session_id("../../etc"));
        assert!(!is_valid_session_id("$(whoami)"));
        assert!(!is_valid_session_id("a b c"));
    }

    #[test]
    fn is_valid_session_id_caps_length_at_36() {
        assert!(is_valid_session_id(&"a".repeat(36)));
        assert!(!is_valid_session_id(&"a".repeat(37)));
    }

    #[test]
    fn best_session_match_returns_single_candidate() {
        let candidates = [cand("only-one", unix_now())];
        assert_eq!(
            best_session_match(&candidates, None),
            Some("only-one".to_string())
        );
    }

    #[test]
    fn best_session_match_returns_nil_for_empty_candidates() {
        assert_eq!(best_session_match(&[], None), None);
    }

    #[test]
    fn best_session_match_returns_nil_for_multiple_without_reference() {
        let now = unix_now();
        let candidates = [cand("a", now), cand("b", now - 10.0)];
        assert_eq!(best_session_match(&candidates, None), None);
    }

    #[test]
    fn best_session_match_returns_nil_for_multiple_with_unusable_distant_past_reference() {
        let now = unix_now();
        let candidates = [cand("a", now), cand("b", now - 10.0)];
        assert_eq!(best_session_match(&candidates, Some(DISTANT_PAST)), None);
    }

    #[test]
    fn best_session_match_returns_nil_for_multiple_with_future_reference() {
        let now = unix_now();
        let candidates = [cand("a", now), cand("b", now - 10.0)];
        assert_eq!(best_session_match(&candidates, Some(now + 3600.0)), None);
    }

    #[test]
    fn best_session_match_picks_closest_to_reference() {
        let reference = unix_now();
        let candidates = [
            cand("far", reference - 100.0),
            cand("close", reference - 5.0),
            cand("medium", reference - 30.0),
        ];
        assert_eq!(
            best_session_match(&candidates, Some(reference)),
            Some("close".to_string())
        );
    }

    #[test]
    fn best_session_match_prefers_more_recent_on_tie() {
        let reference = unix_now();
        let candidates = [
            cand("older", reference - 10.0),
            cand("newer", reference + 10.0),
        ];
        assert_eq!(
            best_session_match(&candidates, Some(reference)),
            Some("newer".to_string())
        );
    }
}
