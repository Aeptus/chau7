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
