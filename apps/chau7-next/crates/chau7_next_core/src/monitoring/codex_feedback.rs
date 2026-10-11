//! Current Swift Codex feedback proposal assessment and rollout parsing.
//! Confidence describes inferred actionability, never provider authority.

use regex::Regex;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::{collections::HashSet, sync::LazyLock};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FeedbackPrompt {
    pub call_id: Option<String>,
    pub message: String,
    pub option_labels: Vec<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Confidence {
    Low,
    Medium,
    High,
}
impl Confidence {
    pub fn raw_value(self) -> &'static str {
        match self {
            Self::Low => "low",
            Self::Medium => "medium",
            Self::High => "high",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Assessment {
    pub prompt: FeedbackPrompt,
    pub confidence: Confidence,
    pub evidence: Vec<String>,
}
impl Assessment {
    pub fn should_request_attention(&self) -> bool {
        self.confidence >= Confidence::Medium
    }
}

static NUMBERED: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"^\s*(?:[-*]\s*)?#?(\d+)\s*[.):]?\s+(.+?)\s*$").unwrap());
static BULLET: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"^\s*[-*]\s+(.+?)\s*$").unwrap());
static INLINE: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"`([^`\n]{1,80})`").unwrap());
fn clean(raw: &str) -> String {
    raw.trim().replace("**", "").replace('`', "")
}
fn contains(text: &str, patterns: &[&str]) -> bool {
    patterns.iter().any(|p| text.contains(p))
}

pub fn assess(message: &str) -> Option<Assessment> {
    let normalized = message.replace("\r\n", "\n");
    let lines: Vec<_> = normalized.split('\n').collect();
    let tail = &lines[lines.len().saturating_sub(80)..];
    let lower = tail.join("\n").to_lowercase();
    let directive = contains(
        &lower,
        &[
            "tell me ",
            "choose ",
            "select ",
            "pick ",
            "reply with",
            "respond with",
            "let me know which",
            "which option",
            "confirm ",
            "needs your confirmation",
            "until you confirm",
            "pending your confirmation",
            "waiting for your choice",
            "dis-moi",
            "dites-moi",
            "choisis",
            "choisissez",
            "sélectionne",
            "sélectionnez",
            "réponds",
            "répondez",
            "indique-moi",
            "confirme",
            "confirmez",
            "tant que tu ne les confirmes pas",
            "en attente de ta confirmation",
            "les choix possibles",
        ],
    );
    let numbered: Vec<_> = tail
        .iter()
        .filter_map(|l| NUMBERED.captures(l))
        .map(|c| clean(&c[2]))
        .filter(|l| !l.is_empty())
        .collect();
    let bullets: Vec<_> = tail[tail.len().saturating_sub(20)..]
        .iter()
        .filter_map(|l| BULLET.captures(l))
        .map(|c| clean(&c[1]))
        .filter(|l| !l.is_empty())
        .collect();
    let inline_tail = tail[tail.len().saturating_sub(12)..].join("\n");
    let options = if numbered.len() >= 2 {
        numbered
    } else if bullets.len() >= 2 {
        bullets
    } else {
        INLINE
            .captures_iter(&inline_tail)
            .map(|c| c[1].to_string())
            .filter(|l| !l.contains(['/', '.', ' ']))
            .collect()
    };
    let mut seen = HashSet::new();
    let options: Vec<_> = options
        .into_iter()
        .filter(|l| seen.insert(l.to_lowercase()))
        .collect();
    let unresolved = contains(
        &lower,
        &[
            "two recommendations",
            "two decisions",
            "deux recommandations",
            "deux décisions",
        ],
    );
    let prompt = tail
        .iter()
        .rev()
        .find(|l| !l.trim().is_empty())
        .map(|l| clean(l))
        .unwrap_or_else(|| "Codex is waiting for your choice.".into());
    let direct = prompt.trim().ends_with('?')
        && contains(
            &prompt.to_lowercase(),
            &[
                "should i ",
                "shall i ",
                "do you want me ",
                "would you like me ",
                "can i ",
                "may i ",
                "which ",
                "what do you prefer",
                "how should i ",
                "proceed?",
                "continue?",
                "veux-tu ",
                "souhaites-tu ",
                "souhaitez-vous ",
                "dois-je ",
                "je continue",
                "on continue",
            ],
        );
    let (confidence, evidence) = if directive && (options.len() >= 2 || unresolved) {
        (
            Confidence::High,
            vec![
                "response_directive",
                if options.len() >= 2 {
                    "multiple_options"
                } else {
                    "multiple_unresolved_decisions"
                },
            ],
        )
    } else if direct {
        (Confidence::Medium, vec!["direct_terminal_question"])
    } else if directive
        && contains(
            &lower,
            &[
                "confirm",
                "confirmation",
                "approve",
                "approval",
                "proceed",
                "continue",
                "confirme",
                "approuve",
                "continuer",
                "poursuivre",
            ],
        )
    {
        (
            Confidence::Medium,
            vec!["response_directive", "confirmation_language"],
        )
    } else if prompt.ends_with('?') {
        (Confidence::Low, vec!["terminal_question"])
    } else {
        return None;
    };
    Some(Assessment {
        prompt: FeedbackPrompt {
            call_id: None,
            message: prompt,
            option_labels: options,
        },
        confidence,
        evidence: evidence.into_iter().map(str::to_string).collect(),
    })
}

pub fn detect(message: &str) -> Option<FeedbackPrompt> {
    assess(message)
        .filter(Assessment::should_request_attention)
        .map(|a| a.prompt)
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RolloutFeedbackRecord {
    StructuredPrompt(FeedbackPrompt),
    ToolCallCompleted { call_id: String, output: String },
}
fn nonempty(v: &Value) -> Option<String> {
    v.as_str()
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(str::to_string)
}
pub fn parse_questions(questions: &[Value], call_id: Option<String>) -> Option<FeedbackPrompt> {
    if questions.is_empty() || questions.iter().any(|q| !q.is_object()) {
        return None;
    }
    let texts: Vec<_> = questions
        .iter()
        .filter_map(|q| nonempty(&q["question"]))
        .collect();
    if texts.is_empty() {
        return None;
    }
    let option_labels = questions
        .iter()
        .filter_map(|q| q["options"].as_array())
        .filter(|options| options.iter().all(Value::is_object))
        .flatten()
        .filter_map(|o| nonempty(&o["label"]))
        .collect();
    Some(FeedbackPrompt {
        call_id,
        message: texts.join("\n"),
        option_labels,
    })
}
pub fn parse_rollout_line(line: &str) -> Option<RolloutFeedbackRecord> {
    let root: Value = serde_json::from_str(line).ok()?;
    if root["type"] != "response_item" {
        return None;
    }
    let payload = &root["payload"];
    let call_id = nonempty(&payload["call_id"])?;
    match payload["type"].as_str()? {
        "function_call" if payload["name"] == "request_user_input" => {
            let args: Value = serde_json::from_str(payload["arguments"].as_str()?).ok()?;
            parse_questions(args["questions"].as_array()?, Some(call_id))
                .map(RolloutFeedbackRecord::StructuredPrompt)
        }
        "function_call_output" => {
            let v = &payload["output"];
            let output = v.as_str().map(str::to_string).unwrap_or_else(|| {
                if v.is_array() || v.is_object() {
                    v.to_string()
                } else {
                    String::new()
                }
            });
            Some(RolloutFeedbackRecord::ToolCallCompleted { call_id, output })
        }
        _ => None,
    }
}
pub fn is_unavailable_output(output: &str) -> bool {
    contains(
        &output.to_lowercase(),
        &["request_user_input is unavailable", "requires plan mode"],
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    #[test]
    fn direct_action_question_is_medium_but_conversational_question_is_low() {
        let a = assess("Should I apply it to the remaining workspaces?").unwrap();
        assert_eq!(a.confidence, Confidence::Medium);
        assert_eq!(a.evidence, ["direct_terminal_question"]);
        assert!(a.should_request_attention());
        let a = assess("Does that explanation make sense?").unwrap();
        assert_eq!(a.confidence, Confidence::Low);
        assert!(!a.should_request_attention());
        assert!(detect(&a.prompt.message).is_none());
    }
    #[test]
    fn numbered_explicit_choices_and_french_inline_labels_match_swift() {
        let a=assess("- #1 **Core**\n- #2 App\n- #3 Tests\n- #4 Docs\n- #5 CI\nTell me `all` or the numbers to apply.").unwrap();
        assert_eq!(a.confidence, Confidence::High);
        assert_eq!(
            a.prompt.option_labels,
            ["Core", "App", "Tests", "Docs", "CI"]
        );
        assert_eq!(a.prompt.message, "Tell me all or the numbers to apply.");
        let a=assess("Les choix possibles: `research_development`, `sales_marketing`, `general_administrative`.\nDis-moi lequel tu préfères.").unwrap();
        assert_eq!(a.confidence, Confidence::High);
        assert_eq!(
            a.prompt.option_labels,
            [
                "research_development",
                "sales_marketing",
                "general_administrative"
            ]
        );
    }
    #[test]
    fn unresolved_decisions_confirmation_and_options_are_deduplicated() {
        let a =
            assess("Deux décisions en attente de ta confirmation. Confirme les recommandations.")
                .unwrap();
        assert_eq!(a.confidence, Confidence::High);
        assert_eq!(
            a.evidence,
            ["response_directive", "multiple_unresolved_decisions"]
        );
        let a = assess("Please confirm before I continue.").unwrap();
        assert_eq!(a.confidence, Confidence::Medium);
        assert_eq!(a.evidence, ["response_directive", "confirmation_language"]);
        let a = assess("- Alpha\n- ALPHA\nChoose one?").unwrap();
        assert_eq!(a.prompt.option_labels, ["Alpha"]);
        assert_eq!(a.confidence, Confidence::Low);
    }
    #[test]
    fn recommendations_without_action_and_old_directives_do_not_request_attention() {
        assert!(assess("1. Improve testing\n2. Improve docs\n3. Monitor usage").is_none());
        assert!(
            assess("You can choose a deployment model later.\nThe worktree is clean.").is_none()
        );
        let old = format!(
            "Tell me which to apply.\n1. A\n2. B\n{}Done.",
            "filler\n".repeat(80)
        );
        assert!(assess(&old).is_none());
    }
    #[test]
    fn bullets_inline_filter_and_crlf_tail_match_swift() {
        let a = assess("- **Alpha**\r\n- `Beta`\r\nChoose one.\r\n").unwrap();
        assert_eq!(a.prompt.option_labels, ["Alpha", "Beta"]);
        let a = assess("Choose `yes` or `no`, not `/tmp/file`, `a.b` or `two words`.").unwrap();
        assert_eq!(a.prompt.option_labels, ["yes", "no"]);
    }
    #[test]
    fn structured_questions_and_completion_keep_call_identity() {
        let args = json!({"questions":[{"question":" Pick one? ","options":[{"label":" A (Recommended) "},{"label":"B"}]}]});
        let line=json!({"type":"response_item","payload":{"type":"function_call","name":"request_user_input","call_id":"call-1","arguments":args.to_string()}}).to_string();
        let Some(RolloutFeedbackRecord::StructuredPrompt(p)) = parse_rollout_line(&line) else {
            panic!()
        };
        assert_eq!(p.call_id.as_deref(), Some("call-1"));
        assert_eq!(p.message, "Pick one?");
        assert_eq!(p.option_labels, ["A (Recommended)", "B"]);
        let line=json!({"type":"response_item","payload":{"type":"function_call_output","call_id":"call-1","output":{"answers":{"choice":"A"}}}}).to_string();
        let Some(RolloutFeedbackRecord::ToolCallCompleted { call_id, output }) =
            parse_rollout_line(&line)
        else {
            panic!()
        };
        assert_eq!(call_id, "call-1");
        assert_eq!(
            serde_json::from_str::<Value>(&output).unwrap(),
            json!({"answers":{"choice":"A"}})
        );
    }
    #[test]
    fn invalid_or_unrelated_rollout_and_unavailable_outputs() {
        for line in [
            "bad",
            "{}",
            r#"{"type":"response_item","payload":{"type":"function_call","name":"exec_command","call_id":"x","arguments":"{}"}}"#,
        ] {
            assert!(parse_rollout_line(line).is_none());
        }
        assert!(parse_questions(&[], None).is_none());
        assert!(parse_questions(&[json!({"question":" "})], None).is_none());
        assert!(is_unavailable_output(
            "request_user_input is unavailable in Default mode"
        ));
        assert!(is_unavailable_output("This tool requires Plan mode"));
        assert!(!is_unavailable_output("answers: A"));
    }
}
