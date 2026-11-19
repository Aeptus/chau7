//! Typed remote keyboard input and provider-aware submission timing.
use crate::terminal_key_press::TerminalKeyPress;
use serde::Deserialize;

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RemoteKey {
    pub key: String,
    pub modifiers: Option<Vec<String>>,
}
#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RemoteKeyInput {
    pub keys: Vec<RemoteKey>,
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct InputStep {
    pub bytes: Vec<u8>,
    pub delay_ms: u64,
}

pub fn key_steps(keys: &[RemoteKey], app_cursor: bool) -> Vec<InputStep> {
    let capped = &keys[..keys.len().min(32)];
    capped
        .iter()
        .enumerate()
        .filter_map(|(index, key)| {
            let modifiers: Vec<&str> = key
                .modifiers
                .as_deref()
                .unwrap_or_default()
                .iter()
                .map(String::as_str)
                .collect();
            let press = TerminalKeyPress::new(&key.key, &modifiers).ok()?;
            let delayed = index > 0
                && index + 1 == capped.len()
                && press.key == "enter"
                && modifiers.is_empty();
            Some(InputStep {
                bytes: press.encode(app_cursor).ok()?.bytes,
                delay_ms: if delayed { 60 } else { 0 },
            })
        })
        .collect()
}

pub fn text_steps(text: &str, codex: bool, bracketed_paste: bool) -> Vec<InputStep> {
    let body = text.trim_end_matches(['\r', '\n']);
    if body.len() == text.len() {
        return vec![InputStep {
            bytes: text.as_bytes().to_vec(),
            delay_ms: 0,
        }];
    }
    let mut steps = Vec::new();
    if !body.is_empty() {
        steps.push(InputStep {
            bytes: vec![0x15],
            delay_ms: 0,
        });
        let bytes = if codex && bracketed_paste {
            format!("\x1b[200~{body}\x1b[201~").into_bytes()
        } else {
            body.as_bytes().to_vec()
        };
        steps.push(InputStep { bytes, delay_ms: 0 });
    }
    steps.push(InputStep {
        bytes: vec![0x0d],
        delay_ms: if body.is_empty() {
            0
        } else if codex {
            120
        } else {
            60
        },
    });
    steps
}

/// Codex shows its async question editor in the follow-up input stack. A
/// digit or paste goes to the main composer until the question is expanded.
#[derive(Debug, PartialEq, Eq)]
pub enum CodexQuestionEditor {
    Collapsed,
    Ready,
}

pub fn codex_question_editor(screen: &str, title: &str) -> Option<CodexQuestionEditor> {
    let (_, stack) = screen.rsplit_once("Queued follow-up inputs")?;
    let mut lines = stack.lines().map(str::trim).filter(|line| !line.is_empty());
    let first = lines.next()?;
    if first == "? 1 question" && lines.next() == Some("⇧← to answer") {
        return Some(CodexQuestionEditor::Collapsed);
    }

    // The navigation footer belongs to the active editor. A title from the
    // transcript or an editor with multiple pending questions is insufficient.
    let footer = lines.next_back()?;
    if !footer.contains(" skip ")
        || !footer.ends_with(" main prompt")
        || footer.contains("next question")
        || footer.contains("prev question")
    {
        return None;
    }
    let title = title.split_whitespace().collect::<Vec<_>>().join(" ");
    let mut rendered_title = first.split_whitespace().collect::<Vec<_>>().join(" ");
    for line in lines {
        if rendered_title.len() >= title.len() {
            break;
        }
        rendered_title.push(' ');
        rendered_title.push_str(&line.split_whitespace().collect::<Vec<_>>().join(" "));
    }
    (rendered_title == title).then_some(CodexQuestionEditor::Ready)
}

/// Queue the answer and its submit in one PTY write. Codex handles bracketed
/// paste as a single event, independently of normal typing and paste detection.
pub fn codex_answer_step(answer: &str) -> InputStep {
    InputStep {
        bytes: format!("\x15\x1b[200~{answer}\x1b[201~\r").into_bytes(),
        delay_ms: 0,
    }
}

/// Only terminal navigation sequences can be converted into semantic keys.
pub fn navigation_keys(mut text: &str) -> Option<Vec<RemoteKey>> {
    let mut keys = Vec::new();
    while text.starts_with("\x1b[A") || text.starts_with("\x1b[B") {
        if keys.len() >= 32 {
            return None;
        }
        keys.push(RemoteKey {
            key: if text.starts_with("\x1b[A") {
                "up"
            } else {
                "down"
            }
            .into(),
            modifiers: None,
        });
        text = &text[3..];
    }
    if text == "\r" || text == "\n" {
        keys.push(RemoteKey {
            key: "enter".into(),
            modifiers: None,
        });
        text = "";
    }
    (text.is_empty() && !keys.is_empty() && keys.len() <= 32).then_some(keys)
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn provider_submit_preserves_controls_and_bare_enter() {
        assert_eq!(text_steps("\x1b[A", true, true)[0].bytes, b"\x1b[A");
        assert_eq!(
            text_steps("\r", true, true),
            vec![InputStep {
                bytes: vec![13],
                delay_ms: 0
            }]
        );
        let steps = text_steps("hello\r\n", true, true);
        assert_eq!(steps[0].bytes, [21]);
        assert_eq!(steps[1].bytes, b"\x1b[200~hello\x1b[201~");
        assert_eq!(steps[2].delay_ms, 120);
        assert_eq!(text_steps("hello\n", false, true)[2].delay_ms, 60);
    }
    #[test]
    fn codex_answer_and_submit_are_one_bracketed_write() {
        let step = codex_answer_step("Leave it");
        assert_eq!(step.bytes, b"\x15\x1b[200~Leave it\x1b[201~\r");
        assert_eq!(step.delay_ms, 0);
    }

    #[test]
    fn codex_question_requires_the_live_editor_and_matching_title() {
        let collapsed =
            "• Queued follow-up inputs\n  ? 1 question\n    ⇧← to answer\n\n› Main draft";
        let expanded = "• Queued follow-up inputs\n  Which environment\n  should I use?\n  › 1. Staging\n    2. Production\n\n  enter submit   ⌃] skip   ⇧→ main prompt\n ";
        let title = "Which environment should I use?";
        assert_eq!(
            codex_question_editor(collapsed, title),
            Some(CodexQuestionEditor::Collapsed)
        );
        assert_eq!(
            codex_question_editor(expanded, title),
            Some(CodexQuestionEditor::Ready)
        );
        assert_eq!(codex_question_editor(expanded, "Other question?"), None);
        assert_eq!(
            codex_question_editor(&collapsed.replace("1 question", "2 questions"), title),
            None
        );
        assert_eq!(
            codex_question_editor(
                &expanded.replace("main prompt", "main prompt   ⇧← next question"),
                title
            ),
            None
        );
        assert_eq!(
            codex_question_editor("Which environment should I use?\n› Main draft", title),
            None
        );
    }

    #[test]
    fn navigation_bounded_and_submit_delayed() {
        let keys = navigation_keys("\x1b[B\r").unwrap();
        let steps = key_steps(&keys, false);
        assert_eq!(steps[0].bytes, b"\x1b[B");
        assert_eq!(steps[1].delay_ms, 60);
        assert!(navigation_keys("hello\r").is_none());
        assert!(navigation_keys(&"\x1b[A".repeat(33)).is_none());
    }
    #[test]
    fn unsupported_keys_are_skipped_and_cap_is_before_encoding() {
        let keys: RemoteKeyInput =
            serde_json::from_str(r#"{"keys":[{"key":"garbage"},{"key":"enter","modifiers":[]}]}"#)
                .unwrap();
        assert_eq!(
            key_steps(&keys.keys, false),
            vec![InputStep {
                bytes: vec![13],
                delay_ms: 60
            }]
        );
    }
}
