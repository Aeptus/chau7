//! "Explain This Error" (`AI/ErrorExplainer.swift`): the prompt sent to the
//! LLM for a failed command and the parsing of its answer.
//!
//! The answer is expected as one JSON object
//! `{"summary","details","confidence":"high|medium|low","fixes":[{"description","command","risk":"safe|moderate|dangerous"}]}`.
//! The first balanced `{...}` of the text is used; when it does not parse,
//! the raw text becomes the explanation with low confidence.

use serde_json::Value;

use crate::llm_provider::{
    ErrorExplanation, ExplanationConfidence, FixRiskLevel, FixSuggestion, LLMRequest,
};

/// Characters of output sent (`output.suffix(2000)`).
pub const OUTPUT_SUFFIX_CHARS: usize = 2000;

pub const SYSTEM_PROMPT: &str = r#"You are a terminal expert. Analyze the following terminal output and explain the error concisely.
Respond in this exact JSON format:
{
  "summary": "One-line summary of the error",
  "details": "2-3 sentence explanation of what went wrong and why",
  "confidence": "high|medium|low",
  "fixes": [
    {"description": "What this fix does", "command": "the command to run", "risk": "safe|moderate|dangerous"}
  ]
}
Only suggest fixes you are confident about. Use "safe" for read-only commands, "moderate" for file modifications, "dangerous" for destructive operations."#;

/// The user message: the command when known, then the last 2000
/// characters of output in a code fence.
pub fn user_message(output: &str, command: Option<&str>) -> String {
    let count = output.chars().count();
    let tail: String = output
        .chars()
        .skip(count.saturating_sub(OUTPUT_SUFFIX_CHARS))
        .collect();
    let message = format!("Terminal output:\n```\n{tail}\n```");
    match command {
        Some(command) => format!("Command: {command}\n\n{message}"),
        None => message,
    }
}

/// The request for `explain(output:command:config:)`.
pub fn request(output: &str, command: Option<&str>, max_tokens: i64) -> LLMRequest {
    LLMRequest::new(SYSTEM_PROMPT, &user_message(output, command), max_tokens)
}

/// `extractFirstBalancedJSON`: the first `{...}` with balanced braces,
/// ignoring braces inside strings (with escaped quotes).
pub fn extract_first_balanced_json(text: &str) -> Option<&str> {
    let open = text.find('{')?;
    let mut depth = 0i32;
    let mut in_string = false;
    let mut escaped = false;
    for (offset, ch) in text[open..].char_indices() {
        if escaped {
            escaped = false;
            continue;
        }
        if ch == '\\' {
            escaped = true;
            continue;
        }
        if ch == '"' {
            in_string = !in_string;
            continue;
        }
        if in_string {
            continue;
        }
        if ch == '{' {
            depth += 1;
        } else if ch == '}' {
            depth -= 1;
            if depth == 0 {
                let end = open + offset + ch.len_utf8();
                return Some(&text[open..end]);
            }
        }
    }
    None
}

/// `parseExplanation(from:)`.
pub fn parse_explanation(content: &str) -> (ErrorExplanation, Vec<FixSuggestion>) {
    let json_text = extract_first_balanced_json(content).unwrap_or(content);
    let parsed: Option<serde_json::Map<String, Value>> = serde_json::from_str::<Value>(json_text)
        .ok()
        .and_then(|v| v.as_object().cloned());
    let Some(json) = parsed else {
        let mut explanation = ErrorExplanation::new("Error explanation", content);
        explanation.confidence = ExplanationConfidence::Low;
        return (explanation, Vec::new());
    };
    let string = |key: &str| json.get(key).and_then(Value::as_str);
    let summary = string("summary").unwrap_or("Unknown error");
    let details = string("details").unwrap_or(content);
    let confidence = match string("confidence").unwrap_or("medium") {
        "high" => ExplanationConfidence::High,
        "low" => ExplanationConfidence::Low,
        _ => ExplanationConfidence::Medium,
    };
    let fixes_array = json.get("fixes").and_then(Value::as_array);
    let suggested_fix = fixes_array
        .and_then(|f| f.first())
        .and_then(|f| f.get("command"))
        .and_then(Value::as_str)
        .map(str::to_string);
    let mut explanation = ErrorExplanation::new(summary, details);
    explanation.confidence = confidence;
    explanation.suggested_fix = suggested_fix;
    let fixes = fixes_array
        .map(|fixes| {
            fixes
                .iter()
                .filter_map(|fix| {
                    let description = fix.get("description")?.as_str()?;
                    let command = fix.get("command")?.as_str()?;
                    let risk = match fix.get("risk").and_then(Value::as_str).unwrap_or("safe") {
                        "moderate" => FixRiskLevel::Moderate,
                        "dangerous" => FixRiskLevel::Dangerous,
                        _ => FixRiskLevel::Safe,
                    };
                    let mut suggestion = FixSuggestion::new(description, command);
                    suggestion.risk_level = risk;
                    Some(suggestion)
                })
                .collect()
        })
        .unwrap_or_default();
    (explanation, fixes)
}

/// Badge text of a confidence level (`confidenceBadge`).
pub fn confidence_badge(confidence: ExplanationConfidence) -> &'static str {
    match confidence {
        ExplanationConfidence::High => "HIGH",
        ExplanationConfidence::Medium => "MED",
        ExplanationConfidence::Low => "LOW",
    }
}

/// Dangerous fixes are copied, not applied (`fixRow`).
pub fn can_apply(risk: FixRiskLevel) -> bool {
    risk != FixRiskLevel::Dangerous
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn extracts_nested_json_with_strings() {
        let text = r#"Here: {"a": {"b": "}"}, "c": "\"{"} trailing {"x":1}"#;
        assert_eq!(
            extract_first_balanced_json(text),
            Some(r#"{"a": {"b": "}"}, "c": "\"{"}"#)
        );
        assert_eq!(extract_first_balanced_json("no json"), None);
        assert_eq!(extract_first_balanced_json("{ unbalanced"), None);
    }

    #[test]
    fn parses_full_answer() {
        let content = r#"```json
{"summary":"Command not found","details":"git is missing.","confidence":"high",
 "fixes":[{"description":"Install git","command":"brew install git","risk":"moderate"},
          {"description":"Wipe","command":"rm -rf /","risk":"dangerous"},
          {"description":"missing command"}]}
```"#;
        let (explanation, fixes) = parse_explanation(content);
        assert_eq!(explanation.summary, "Command not found");
        assert_eq!(explanation.details, "git is missing.");
        assert_eq!(explanation.confidence, ExplanationConfidence::High);
        assert_eq!(
            explanation.suggested_fix.as_deref(),
            Some("brew install git")
        );
        assert_eq!(fixes.len(), 2);
        assert_eq!(fixes[0].risk_level, FixRiskLevel::Moderate);
        assert!(!can_apply(fixes[1].risk_level));
        assert!(can_apply(fixes[0].risk_level));
    }

    #[test]
    fn defaults_for_missing_fields() {
        let (explanation, fixes) = parse_explanation(r#"{"confidence":"whatever"}"#);
        assert_eq!(explanation.summary, "Unknown error");
        assert_eq!(explanation.details, r#"{"confidence":"whatever"}"#);
        assert_eq!(explanation.confidence, ExplanationConfidence::Medium);
        assert!(fixes.is_empty());
    }

    #[test]
    fn raw_text_fallback() {
        let (explanation, fixes) = parse_explanation("Just prose.");
        assert_eq!(explanation.summary, "Error explanation");
        assert_eq!(explanation.details, "Just prose.");
        assert_eq!(explanation.confidence, ExplanationConfidence::Low);
        assert!(fixes.is_empty());
    }

    #[test]
    fn user_message_keeps_last_2000_chars_and_command() {
        let output = format!("{}{}", "a".repeat(100), "b".repeat(2000));
        let message = user_message(&output, Some("make"));
        assert!(message.starts_with("Command: make\n\nTerminal output:\n```\n"));
        assert!(!message.contains("aa"));
        assert_eq!(message.matches('b').count(), 2000);
        assert_eq!(user_message("x", None), "Terminal output:\n```\nx\n```");
        assert_eq!(request("x", None, 77).max_tokens, 77);
    }

    #[test]
    fn badges() {
        assert_eq!(confidence_badge(ExplanationConfidence::High), "HIGH");
        assert_eq!(confidence_badge(ExplanationConfidence::Medium), "MED");
        assert_eq!(confidence_badge(ExplanationConfidence::Low), "LOW");
    }
}
