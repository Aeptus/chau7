//! Key presses given as text specs (`key` plus `shift`/`ctrl`/`alt` names),
//! encoded to terminal bytes.
//!
//! Ports `apps/chau7-macos/Sources/Chau7Core/TerminalKeyPress.swift`, used by
//! the MCP "send keys" tool. This is a different entry point from
//! [`crate::key_encoding::encode_key`], which encodes live key events from the
//! UI: here a spec is parsed first and unsupported keys or combinations are
//! rejected with an error instead of being dropped. Their tables overlap but
//! do not agree (for example a bare letter is an error here, and Shift+Enter
//! is rejected), so they stay separate and `key_encoding` is untouched.

use crate::escape_sanitizer::trim_whitespaces_and_newlines;
use serde::{Deserialize, Serialize};
use std::collections::BTreeSet;
use std::fmt;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TerminalKeyPressError {
    EmptyKey,
    UnsupportedModifier(String),
    UnsupportedKey(String),
    UnsupportedCombination { key: String, modifiers: Vec<String> },
}

impl fmt::Display for TerminalKeyPressError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::EmptyKey => write!(f, "key must not be empty"),
            Self::UnsupportedModifier(modifier) => write!(f, "unsupported modifier: {modifier}"),
            Self::UnsupportedKey(key) => write!(f, "unsupported key: {key}"),
            Self::UnsupportedCombination { key, modifiers } => {
                let suffix = if modifiers.is_empty() {
                    String::new()
                } else {
                    format!(" with modifiers {}", modifiers.join(", "))
                };
                write!(f, "unsupported key combination: {key}{suffix}")
            }
        }
    }
}

impl std::error::Error for TerminalKeyPressError {}

/// Modifier names accepted in a spec. Declared in raw-value order so the
/// derived ordering is the sorted order Swift reports.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum TerminalKeyModifier {
    Control,
    Option,
    Shift,
}

impl TerminalKeyModifier {
    pub fn raw_value(self) -> &'static str {
        match self {
            Self::Control => "control",
            Self::Option => "option",
            Self::Shift => "shift",
        }
    }

    /// `shift`, `control`/`ctrl` and `option`/`alt`/`meta`, any case, with
    /// surrounding whitespace ignored.
    pub fn parse(raw: &str) -> Option<Self> {
        match trim_whitespaces_and_newlines(raw).to_lowercase().as_str() {
            "shift" => Some(Self::Shift),
            "control" | "ctrl" => Some(Self::Control),
            "option" | "alt" | "meta" => Some(Self::Option),
            _ => None,
        }
    }
}

/// Bytes to write to the terminal, plus the same bytes as text when they are
/// valid UTF-8 (`None` for cursor and navigation keys).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EncodedTerminalKeyPress {
    pub bytes: Vec<u8>,
    pub text: Option<String>,
}

fn with_text(bytes: Vec<u8>) -> EncodedTerminalKeyPress {
    let text = String::from_utf8(bytes.clone()).ok();
    EncodedTerminalKeyPress { bytes, text }
}

fn without_text(bytes: Vec<u8>) -> EncodedTerminalKeyPress {
    EncodedTerminalKeyPress { bytes, text: None }
}

const NAMED_KEYS: &[&str] = &[
    "enter",
    "escape",
    "tab",
    "backspace",
    "up",
    "down",
    "left",
    "right",
    "home",
    "end",
    "page_up",
    "page_down",
    "delete",
    "insert",
];

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TerminalKeyPress {
    pub key: String,
    pub modifiers: BTreeSet<TerminalKeyModifier>,
}

impl TerminalKeyPress {
    /// Parse a spec. The key is trimmed, lowercased and mapped from aliases
    /// (`return`, `esc`, `pgup`, ...) to its canonical name.
    pub fn new(raw_key: &str, raw_modifiers: &[&str]) -> Result<Self, TerminalKeyPressError> {
        let key = normalize_key(raw_key);
        if key.is_empty() {
            return Err(TerminalKeyPressError::EmptyKey);
        }
        let mut modifiers = BTreeSet::new();
        for raw in raw_modifiers {
            let modifier = TerminalKeyModifier::parse(raw)
                .ok_or_else(|| TerminalKeyPressError::UnsupportedModifier((*raw).to_string()))?;
            modifiers.insert(modifier);
        }
        Ok(Self { key, modifiers })
    }

    /// Modifier raw values, sorted.
    pub fn sorted_modifier_names(&self) -> Vec<String> {
        self.modifiers
            .iter()
            .map(|m| m.raw_value().to_string())
            .collect()
    }

    /// Encode to bytes. `application_cursor_mode` switches unmodified arrows
    /// to `ESC O x`.
    pub fn encode(
        &self,
        application_cursor_mode: bool,
    ) -> Result<EncodedTerminalKeyPress, TerminalKeyPressError> {
        if let Some(encoded) = self.encode_special_key(application_cursor_mode) {
            return Ok(encoded);
        }
        if NAMED_KEYS.contains(&self.key.as_str()) {
            return Err(self.unsupported_combination());
        }
        let mut chars = self.key.chars();
        match (chars.next(), chars.next()) {
            (Some(character), None) => self.encode_character(character),
            _ => Err(TerminalKeyPressError::UnsupportedKey(self.key.clone())),
        }
    }

    fn unsupported_combination(&self) -> TerminalKeyPressError {
        TerminalKeyPressError::UnsupportedCombination {
            key: self.key.clone(),
            modifiers: self.sorted_modifier_names(),
        }
    }

    fn has(&self, modifier: TerminalKeyModifier) -> bool {
        self.modifiers.contains(&modifier)
    }

    /// xterm modifier parameter: 1 + shift + 2*option + 4*control.
    fn modifier_parameter(&self) -> u8 {
        let mut parameter = 1;
        if self.has(TerminalKeyModifier::Shift) {
            parameter += 1;
        }
        if self.has(TerminalKeyModifier::Option) {
            parameter += 2;
        }
        if self.has(TerminalKeyModifier::Control) {
            parameter += 4;
        }
        parameter
    }

    fn encode_special_key(&self, application_cursor_mode: bool) -> Option<EncodedTerminalKeyPress> {
        let parameter = self.modifier_parameter();
        let has_modifiers = parameter > 1;
        let only = |m: TerminalKeyModifier| self.modifiers.len() == 1 && self.has(m);

        let csi = |content: &str| format!("\x1b[{content}").into_bytes();
        let csi_mod = |prefix: &str, terminator: &str| {
            format!("\x1b[{prefix};{parameter}{terminator}").into_bytes()
        };
        let arrow = |direction: char| -> Vec<u8> {
            if has_modifiers {
                format!("\x1b[1;{parameter}{direction}").into_bytes()
            } else if application_cursor_mode {
                format!("\x1bO{direction}").into_bytes()
            } else {
                format!("\x1b[{direction}").into_bytes()
            }
        };
        let tilde = |code: &str| {
            if has_modifiers {
                csi_mod(code, "~")
            } else {
                csi(&format!("{code}~"))
            }
        };

        match self.key.as_str() {
            "enter" => self.modifiers.is_empty().then(|| with_text(vec![0x0D])),
            "escape" => self.modifiers.is_empty().then(|| with_text(vec![0x1B])),
            "tab" => {
                if only(TerminalKeyModifier::Shift) {
                    return Some(with_text(csi("Z")));
                }
                self.modifiers.is_empty().then(|| with_text(vec![0x09]))
            }
            "backspace" => {
                if only(TerminalKeyModifier::Control) {
                    return Some(with_text(vec![0x08]));
                }
                self.modifiers.is_empty().then(|| with_text(vec![0x7F]))
            }
            "up" => Some(without_text(arrow('A'))),
            "down" => Some(without_text(arrow('B'))),
            "right" => Some(without_text(arrow('C'))),
            "left" => Some(without_text(arrow('D'))),
            "home" => Some(without_text(if has_modifiers {
                csi_mod("1", "H")
            } else {
                csi("H")
            })),
            "end" => Some(without_text(if has_modifiers {
                csi_mod("1", "F")
            } else {
                csi("F")
            })),
            "page_up" => Some(without_text(tilde("5"))),
            "page_down" => Some(without_text(tilde("6"))),
            "delete" => Some(without_text(tilde("3"))),
            "insert" => Some(without_text(tilde("2"))),
            _ => None,
        }
    }

    fn encode_character(
        &self,
        character: char,
    ) -> Result<EncodedTerminalKeyPress, TerminalKeyPressError> {
        let shift = self.has(TerminalKeyModifier::Shift);
        let control = self.has(TerminalKeyModifier::Control);
        let option = self.has(TerminalKeyModifier::Option);

        if control && let Some(code) = control_character(character) {
            let bytes = if option { vec![0x1B, code] } else { vec![code] };
            return Ok(with_text(bytes));
        }

        if option {
            let text = if shift {
                character.to_uppercase().to_string()
            } else {
                character.to_string()
            };
            let mut bytes = vec![0x1B];
            bytes.extend_from_slice(text.as_bytes());
            return Ok(with_text(bytes));
        }

        Err(self.unsupported_combination())
    }
}

fn normalize_key(raw: &str) -> String {
    let lowered = trim_whitespaces_and_newlines(raw).to_lowercase();
    match lowered.as_str() {
        "return" => "enter",
        "esc" => "escape",
        "uparrow" | "arrowup" => "up",
        "downarrow" | "arrowdown" => "down",
        "leftarrow" | "arrowleft" => "left",
        "rightarrow" | "arrowright" => "right",
        "pageup" | "pgup" => "page_up",
        "pagedown" | "pgdown" => "page_down",
        "forwarddelete" | "forward_delete" | "del" => "delete",
        _ => return lowered,
    }
    .to_string()
}

/// Control byte for an ASCII character; `None` for anything else.
fn control_character(character: char) -> Option<u8> {
    if !character.is_ascii() {
        return None;
    }
    let ascii = character as u8;
    if (0x61..=0x7A).contains(&ascii) {
        return Some(ascii - 0x60);
    }
    if (0x41..=0x5A).contains(&ascii) {
        return Some(ascii - 0x40);
    }
    match character {
        '[' | '{' | '3' => Some(0x1B),
        '\\' | '4' => Some(0x1C),
        ']' | '}' | '5' => Some(0x1D),
        '^' | '~' | '6' => Some(0x1E),
        '_' | '?' | '7' => Some(0x1F),
        '@' | ' ' | '2' => Some(0x00),
        '8' => Some(0x7F),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn press(key: &str, modifiers: &[&str]) -> TerminalKeyPress {
        TerminalKeyPress::new(key, modifiers).unwrap()
    }

    #[test]
    fn encode_enter_uses_carriage_return() {
        let encoded = press("enter", &[]).encode(false).unwrap();
        assert_eq!(encoded.bytes, vec![0x0D]);
        assert_eq!(encoded.text.as_deref(), Some("\r"));
    }

    #[test]
    fn encode_shift_tab_uses_backtab_sequence() {
        let encoded = press("tab", &["shift"]).encode(false).unwrap();
        assert_eq!(encoded.bytes, b"\x1b[Z".to_vec());
    }

    #[test]
    fn encode_control_c_uses_control_character() {
        let encoded = press("c", &["ctrl"]).encode(false).unwrap();
        assert_eq!(encoded.bytes, vec![0x03]);
        assert_eq!(encoded.text.as_deref(), Some("\u{3}"));
    }

    #[test]
    fn encode_alt_b_prefixes_escape() {
        let encoded = press("b", &["alt"]).encode(false).unwrap();
        assert_eq!(encoded.bytes, vec![0x1B, 0x62]);
        assert_eq!(encoded.text.as_deref(), Some("\u{1b}b"));
    }

    #[test]
    fn encode_up_arrow_respects_application_cursor_mode() {
        let encoded = press("up", &[]).encode(true).unwrap();
        assert_eq!(encoded.bytes, b"\x1bOA".to_vec());
    }

    #[test]
    fn encode_control_backspace_uses_bs() {
        let encoded = press("backspace", &["control"]).encode(false).unwrap();
        assert_eq!(encoded.bytes, vec![0x08]);
        assert_eq!(encoded.text.as_deref(), Some("\u{8}"));
    }

    #[test]
    fn reject_unsupported_modifier() {
        assert_eq!(
            TerminalKeyPress::new("enter", &["hyper"]),
            Err(TerminalKeyPressError::UnsupportedModifier("hyper".into()))
        );
    }

    #[test]
    fn reject_unsupported_combination() {
        let error = press("enter", &["shift"]).encode(false).unwrap_err();
        assert_eq!(
            error,
            TerminalKeyPressError::UnsupportedCombination {
                key: "enter".into(),
                modifiers: vec!["shift".into()],
            }
        );
    }

    // Branches without a Swift test.

    #[test]
    fn aliases_empty_and_error_messages() {
        assert_eq!(press(" Return ", &[]).key, "enter");
        assert_eq!(press("PgDown", &[]).key, "page_down");
        assert_eq!(press("ForwardDelete", &[]).key, "delete");
        assert_eq!(
            TerminalKeyPress::new("  ", &[]),
            Err(TerminalKeyPressError::EmptyKey)
        );
        assert_eq!(
            TerminalKeyPressError::EmptyKey.to_string(),
            "key must not be empty"
        );
        assert_eq!(
            press("enter", &["shift", "alt"])
                .encode(false)
                .unwrap_err()
                .to_string(),
            "unsupported key combination: enter with modifiers option, shift"
        );
        assert_eq!(
            press("f5", &[]).encode(false).unwrap_err().to_string(),
            "unsupported key: f5"
        );
    }

    #[test]
    fn modified_navigation_keys_use_xterm_parameters() {
        let up = press("up", &["ctrl"]).encode(true).unwrap();
        assert_eq!(up.bytes, b"\x1b[1;5A".to_vec());
        assert_eq!(up.text, None);
        assert_eq!(
            press("home", &[]).encode(false).unwrap().bytes,
            b"\x1b[H".to_vec()
        );
        assert_eq!(
            press("end", &["shift", "alt"]).encode(false).unwrap().bytes,
            b"\x1b[1;4F".to_vec()
        );
        assert_eq!(
            press("page_up", &["ctrl"]).encode(false).unwrap().bytes,
            b"\x1b[5;5~".to_vec()
        );
        assert_eq!(
            press("delete", &[]).encode(false).unwrap().bytes,
            b"\x1b[3~".to_vec()
        );
        assert_eq!(
            press("insert", &[]).encode(false).unwrap().bytes,
            b"\x1b[2~".to_vec()
        );
        assert_eq!(
            press("escape", &[]).encode(false).unwrap().bytes,
            vec![0x1B]
        );
        assert_eq!(press("tab", &[]).encode(false).unwrap().bytes, vec![0x09]);
        assert_eq!(
            press("backspace", &[]).encode(false).unwrap().bytes,
            vec![0x7F]
        );
        assert!(press("tab", &["ctrl"]).encode(false).is_err());
    }

    #[test]
    fn character_combinations() {
        assert_eq!(
            press("c", &["ctrl", "alt"]).encode(false).unwrap().bytes,
            vec![0x1B, 0x03]
        );
        assert_eq!(
            press("b", &["alt", "shift"]).encode(false).unwrap().bytes,
            vec![0x1B, b'B']
        );
        assert_eq!(
            press("[", &["ctrl"]).encode(false).unwrap().bytes,
            vec![0x1B]
        );
        assert_eq!(
            press("8", &["ctrl"]).encode(false).unwrap().bytes,
            vec![0x7F]
        );
        // Control with no control code and no option is rejected.
        assert!(press(";", &["ctrl"]).encode(false).is_err());
        // A bare character is rejected too.
        assert!(press("a", &[]).encode(false).is_err());
    }
}
