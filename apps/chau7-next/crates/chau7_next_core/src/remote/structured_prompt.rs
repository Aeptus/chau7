//! Bounded structured Claude and Codex questions, with authoritative clears.
use super::interactive_prompt::RemoteInteractivePromptOption;
use crate::monitoring::claude_code::ClaudeCodeEvent;
use crate::runtime::codex_feedback::Prompt as CodexQuestion;
use base64::{Engine as _, engine::general_purpose::STANDARD};
use chrono::{DateTime, Duration, Utc};
use sha2::{Digest, Sha256};
use std::collections::HashMap;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StructuredPromptEntry {
    pub tab: u64,
    pub session_id: String,
    pub tool_use_id: String,
    pub tool_name: String,
    pub prompt: String,
    pub detail: Option<String>,
    pub options: Vec<RemoteInteractivePromptOption>,
    pub is_multi_select: bool,
    /// A single Codex question can be shown and answered without options.
    pub accepts_reply: bool,
    pub created_at: DateTime<Utc>,
    pub signature: String,
}
impl StructuredPromptEntry {
    pub fn is_codex_question(&self) -> bool {
        self.tool_name == CODEX_QUESTION_TOOL
    }
}

#[derive(Default)]
pub struct StructuredPromptStore {
    entries: HashMap<(u64, String), StructuredPromptEntry>,
}
impl StructuredPromptStore {
    pub fn apply(&mut self, event: &ClaudeCodeEvent, tab: Option<u64>, now: DateTime<Utc>) -> bool {
        let before_count = self.entries.len();
        self.purge(now);
        let mut changed = before_count != self.entries.len();
        match event.raw_type.as_str() {
            "tool_start" => {
                if let Some(tab) = tab
                    && let Some(entry) = parse(event, tab, now)
                {
                    let key = (tab, event.session_id.clone());
                    changed |= self.entries.get(&key) != Some(&entry);
                    self.entries.insert(key, entry);
                    self.evict_oldest_over_limit();
                }
            }
            "tool_complete" | "tool_failed" => {
                let count = self.entries.len();
                self.entries.retain(|_, entry| {
                    !(entry.session_id == event.session_id
                        && entry.tool_name == event.tool_name
                        && (event.tool_use_id.is_empty() || entry.tool_use_id == event.tool_use_id))
                });
                changed |= count != self.entries.len();
            }
            "response_complete" | "response_failed" | "session_end" => {
                let count = self.entries.len();
                self.entries
                    .retain(|_, entry| entry.session_id != event.session_id);
                changed |= count != self.entries.len();
            }
            _ => {}
        }
        changed
    }
    /// A question Codex put on screen, read from the session's rollout. A
    /// single question carries its options and accepts a typed reply; a set
    /// of questions only marks the session as waiting.
    pub fn apply_codex_question(
        &mut self,
        tab: u64,
        session: &str,
        question: &CodexQuestion,
        now: DateTime<Utc>,
    ) -> bool {
        self.purge(now);
        if session.is_empty() || question.message.trim().is_empty() {
            return false;
        }
        let options: Vec<_> = if question.single_question {
            question
                .options
                .iter()
                .enumerate()
                .map(|(index, label)| {
                    let id = (index + 1).to_string();
                    // Keep the option ID and legacy wire response stable.
                    // The host submits the label through the Codex editor.
                    RemoteInteractivePromptOption::new(&id, label, &id, is_destructive(label))
                })
                .collect()
        } else {
            Vec::new()
        };
        let mut basis = vec![
            session,
            question.call_id.as_str(),
            question.message.as_str(),
        ];
        basis.extend(question.options.iter().map(String::as_str));
        let entry = StructuredPromptEntry {
            tab,
            session_id: session.into(),
            tool_use_id: question.call_id.clone(),
            tool_name: CODEX_QUESTION_TOOL.into(),
            prompt: question.message.trim().into(),
            detail: None,
            options,
            is_multi_select: false,
            accepts_reply: question.single_question,
            created_at: now,
            signature: signature(&basis.join("\n")),
        };
        let key = (tab, session.to_string());
        if self.entries.get(&key).is_some_and(|current| {
            current.tool_use_id == entry.tool_use_id && current.signature == entry.signature
        }) {
            return false;
        }
        self.entries.insert(key, entry);
        self.evict_oldest_over_limit();
        true
    }
    /// The user answered, or Codex withdrew, the question of this call.
    pub fn resolve_codex_question(&mut self, session: &str, call_id: &str) -> bool {
        let count = self.entries.len();
        self.entries.retain(|_, entry| {
            !(entry.session_id == session
                && entry.tool_name == CODEX_QUESTION_TOOL
                && entry.tool_use_id == call_id)
        });
        count != self.entries.len()
    }
    fn evict_oldest_over_limit(&mut self) {
        if self.entries.len() > 128
            && let Some(key) = self
                .entries
                .iter()
                .min_by_key(|(_, entry)| entry.created_at)
                .map(|(key, _)| key.clone())
        {
            self.entries.remove(&key);
        }
    }
    pub fn entry(
        &self,
        tab: u64,
        session: &str,
        now: DateTime<Utc>,
    ) -> Option<&StructuredPromptEntry> {
        self.entries
            .get(&(tab, session.into()))
            .filter(|entry| entry.created_at > now - Duration::hours(1))
    }
    fn purge(&mut self, now: DateTime<Utc>) {
        self.entries
            .retain(|_, entry| entry.created_at > now - Duration::hours(1));
    }
}
fn parse(event: &ClaudeCodeEvent, tab: u64, now: DateTime<Utc>) -> Option<StructuredPromptEntry> {
    if event.session_id.is_empty() {
        return None;
    }
    let input: serde_json::Value = serde_json::from_str(event.tool_input_json.as_deref()?).ok()?;
    let (prompt, detail, options, multi, basis) = match event.tool_name.as_str() {
        "AskUserQuestion" => {
            let questions = input.get("questions")?.as_array()?;
            if questions.len() != 1 {
                return None;
            }
            let question = &questions[0];
            let prompt = question.get("question")?.as_str()?.trim();
            let raw = question.get("options")?.as_array()?;
            if prompt.is_empty() || raw.len() < 2 || raw.len() > 64 {
                return None;
            }
            let labels: Vec<&str> = raw
                .iter()
                .map(|option| {
                    option
                        .get("label")?
                        .as_str()
                        .map(str::trim)
                        .filter(|label| !label.is_empty())
                })
                .collect::<Option<_>>()?;
            let multi = question
                .get("multiSelect")
                .and_then(|value| value.as_bool())
                .unwrap_or(false);
            let options = labels
                .iter()
                .enumerate()
                .map(|(index, label)| {
                    let id = (index + 1).to_string();
                    RemoteInteractivePromptOption::new(
                        &id,
                        *label,
                        if multi { format!("{id}\r") } else { id.clone() },
                        is_destructive(label),
                    )
                })
                .collect();
            let mut detail = question
                .get("header")
                .and_then(|value| value.as_str())
                .map(str::trim)
                .filter(|header| !header.is_empty())
                .map(str::to_string);
            if multi {
                let hint =
                    "Multi-select on the Mac; tapping an option here picks exactly that option.";
                detail = Some(
                    detail
                        .map(|header| format!("{header}\n{hint}"))
                        .unwrap_or_else(|| hint.into()),
                );
            }
            let mut basis = vec![
                event.session_id.as_str(),
                event.tool_use_id.as_str(),
                prompt,
            ];
            basis.extend(labels);
            (prompt.into(), detail, options, multi, basis.join("\n"))
        }
        "ExitPlanMode" => {
            let plan = input.get("plan")?.as_str()?.trim();
            if plan.is_empty() {
                return None;
            }
            let excerpt: String = plan.chars().take(500).collect();
            let detail = if plan.chars().count() > 500 {
                format!("{excerpt}…")
            } else {
                excerpt
            };
            (
                "Claude finished a plan and is waiting for review".into(),
                Some(detail),
                Vec::new(),
                false,
                [
                    event.session_id.as_str(),
                    event.tool_use_id.as_str(),
                    "ExitPlanMode",
                ]
                .join("\n"),
            )
        }
        _ => return None,
    };
    Some(StructuredPromptEntry {
        tab,
        session_id: event.session_id.clone(),
        tool_use_id: event.tool_use_id.clone(),
        tool_name: event.tool_name.clone(),
        prompt,
        detail,
        options,
        is_multi_select: multi,
        accepts_reply: false,
        created_at: now,
        signature: signature(&basis),
    })
}
const CODEX_QUESTION_TOOL: &str = "request_user_input_async";
fn signature(basis: &str) -> String {
    STANDARD.encode(&Sha256::digest(basis.as_bytes())[..12])
}
fn is_destructive(label: &str) -> bool {
    let label = label.to_lowercase();
    ["deny", "reject", "cancel", "abort", "stop", "no"]
        .iter()
        .any(|word| label.contains(word))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::monitoring::claude_code::parse_event_line;
    fn event(kind: &str, session: &str, tool: &str, id: &str, multi: bool) -> ClaudeCodeEvent {
        parse_event_line(&serde_json::json!({"type":kind,"sessionId":session,"toolName":tool,"toolUseID":id,"toolInput":{"questions":[{"question":"Choose a path","header":"Path","multiSelect":multi,"options":[{"label":"Keep"},{"label":"Cancel"}]}]}}).to_string(),0.).unwrap()
    }
    #[test]
    fn stable_ids_and_multi_select_options() {
        let now = Utc::now();
        let mut store = StructuredPromptStore::default();
        store.apply(
            &event("tool_start", "s", "AskUserQuestion", "q", true),
            Some(10),
            now,
        );
        let entry = store.entry(10, "s", now).unwrap();
        let signature = entry.signature.clone();
        assert!(entry.is_multi_select);
        assert_eq!(entry.options[0].response, "1\r");
        assert!(entry.options[1].is_destructive);
        store.apply(
            &event("tool_start", "s", "AskUserQuestion", "q", true),
            Some(10),
            now + Duration::seconds(1),
        );
        assert_eq!(store.entry(10, "s", now).unwrap().signature, signature);
    }
    #[test]
    fn authoritative_clears_match_session_and_tool_use() {
        let now = Utc::now();
        let mut store = StructuredPromptStore::default();
        store.apply(
            &event("tool_start", "s", "AskUserQuestion", "q", false),
            Some(10),
            now,
        );
        assert!(!store.apply(
            &event("tool_complete", "other", "AskUserQuestion", "q", false),
            Some(10),
            now
        ));
        assert!(!store.apply(
            &event("tool_complete", "s", "AskUserQuestion", "other", false),
            Some(10),
            now
        ));
        assert!(store.apply(
            &event("tool_failed", "s", "AskUserQuestion", "q", false),
            Some(10),
            now
        ));
        assert!(store.entry(10, "s", now).is_none());
    }
    #[test]
    fn expiry_binding_and_capacity_are_bounded() {
        let now = Utc::now();
        let mut store = StructuredPromptStore::default();
        assert!(!store.apply(
            &event("tool_start", "s", "AskUserQuestion", "q", false),
            None,
            now
        ));
        for index in 0..140 {
            store.apply(
                &event(
                    "tool_start",
                    &index.to_string(),
                    "AskUserQuestion",
                    "q",
                    false,
                ),
                Some(index),
                now + Duration::seconds(index as i64),
            );
        }
        assert_eq!(store.entries.len(), 128);
        assert!(store.entry(0, "0", now).is_none());
        assert!(store.entry(139, "139", now + Duration::hours(2)).is_none());
        store.apply(
            &event("response_failed", "139", "", "", false),
            None,
            now + Duration::hours(2),
        );
        assert!(store.entries.is_empty());
    }
    #[test]
    fn multiple_questions_and_missing_plan_are_not_invented() {
        let now = Utc::now();
        let mut ev = event("tool_start", "s", "AskUserQuestion", "q", false);
        ev.tool_input_json = Some(r#"{"questions":[]}"#.into());
        assert!(parse(&ev, 10, now).is_none());
        ev.tool_name = "ExitPlanMode".into();
        assert!(parse(&ev, 10, now).is_none());
        ev.tool_input_json = Some(serde_json::json!({"plan":"a".repeat(600)}).to_string());
        let entry = parse(&ev, 10, now).unwrap();
        assert_eq!(entry.detail.unwrap().chars().count(), 501);
        assert!(entry.options.is_empty());
    }

    fn codex_question(call: &str, options: &[&str], single_question: bool) -> CodexQuestion {
        CodexQuestion {
            call_id: call.into(),
            message: "May I merge?".into(),
            options: options.iter().map(|o| o.to_string()).collect(),
            single_question,
        }
    }
    #[test]
    fn codex_question_offers_digit_answers_until_its_call_is_resolved() {
        let now = Utc::now();
        let mut store = StructuredPromptStore::default();
        let question = codex_question("call_1", &["Approve", "Do not merge"], true);
        assert!(store.apply_codex_question(10, "thread", &question, now));
        assert!(!store.apply_codex_question(10, "thread", &question, now));
        let entry = store.entry(10, "thread", now).unwrap();
        assert_eq!(entry.prompt, "May I merge?");
        let sent: Vec<_> = entry.options.iter().map(|o| o.response.as_str()).collect();
        assert_eq!(
            sent,
            ["1", "2"],
            "a digit submits; a Return would hit the next screen"
        );
        assert!(!entry.options[0].is_destructive);
        assert!(entry.options[1].is_destructive);
        assert!(!store.resolve_codex_question("thread", "another_call"));
        assert!(store.resolve_codex_question("thread", "call_1"));
        assert!(store.entry(10, "thread", now).is_none());
    }
    #[test]
    fn codex_free_text_question_accepts_a_reply_and_a_question_set_does_not() {
        let now = Utc::now();
        let mut store = StructuredPromptStore::default();
        assert!(store.apply_codex_question(10, "free", &codex_question("call_2", &[], true), now));
        let free = store.entry(10, "free", now).unwrap();
        assert!(free.options.is_empty() && free.accepts_reply);
        let set = codex_question("call_3", &["A", "B", "C"], false);
        assert!(store.apply_codex_question(10, "set", &set, now));
        let set = store.entry(10, "set", now).unwrap();
        assert!(set.options.is_empty() && !set.accepts_reply);
        assert!(!store.apply_codex_question(10, "", &codex_question("call_4", &[], true), now));
    }
}
