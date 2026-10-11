//! Kitty keyboard protocol: encode a key event for the flags a program
//! pushed with `CSI > flags u` (the emulator keeps the flag stack and answers
//! `CSI ? u` queries; see `chau7_terminal`'s `kitty_keyboard_flags`).
//!
//! Swift has the flag handling (`Chau7Core/KittyKeyboardProtocol.swift`,
//! ported as [`crate::kitty_keyboard`]) but never wires it to the terminal.
//! This module follows <https://sw.kovidgoyal.net/kitty/keyboard-protocol/>:
//!
//! - flag 1 (disambiguate): Escape, and text keys with Alt or Ctrl, become
//!   `CSI code;mods u`; plain and Shift text, Enter, Tab and Backspace stay
//!   legacy (so a crashed program still leaves a usable shell).
//! - flag 2 (event types): repeats (`:2`) and releases (`:3`) are reported.
//! - flag 4 (alternate keys): `code:shifted` for shifted text keys.
//! - flag 8 (all keys as escapes): every key, text included, is `CSI ... u`.
//! - flag 16 (associated text): the typed text as a third field.
//!
//! Key names are GPUI's (`Keystroke::key`): "a", "enter", "left", "f5", ...

use crate::key_encoding::KeyMods;
pub use crate::kitty_keyboard::KittyEventType;

pub const DISAMBIGUATE: u32 = 1;
pub const EVENT_TYPES: u32 = 2;
pub const ALTERNATE_KEYS: u32 = 4;
pub const ALL_KEYS_AS_ESCAPES: u32 = 8;
pub const ASSOCIATED_TEXT: u32 = 16;

/// What to send for a key event.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum KittyOutput {
    /// Send these bytes.
    Bytes(Vec<u8>),
    /// Use the legacy encoding (or let the input method type the text).
    Legacy,
    /// Send nothing (a release the program did not ask for).
    Nothing,
}

enum Key {
    /// A text key: its unshifted code point.
    Text(char),
    /// Escape, Enter, Tab, Backspace: `CSI code u`.
    Special(u32),
    /// Keys with a legacy CSI form: `CSI number ; mods final`.
    Functional(u32, char),
}

fn classify(key: &str) -> Option<Key> {
    Some(match key {
        "escape" => Key::Special(27),
        "enter" => Key::Special(13),
        "tab" => Key::Special(9),
        "backspace" => Key::Special(127),
        "space" => Key::Text(' '),
        "insert" => Key::Functional(2, '~'),
        "delete" => Key::Functional(3, '~'),
        "pageup" => Key::Functional(5, '~'),
        "pagedown" => Key::Functional(6, '~'),
        "up" => Key::Functional(1, 'A'),
        "down" => Key::Functional(1, 'B'),
        "right" => Key::Functional(1, 'C'),
        "left" => Key::Functional(1, 'D'),
        "end" => Key::Functional(1, 'F'),
        "home" => Key::Functional(1, 'H'),
        "f1" => Key::Functional(1, 'P'),
        "f2" => Key::Functional(1, 'Q'),
        "f3" => Key::Functional(13, '~'),
        "f4" => Key::Functional(1, 'S'),
        "f5" => Key::Functional(15, '~'),
        "f6" => Key::Functional(17, '~'),
        "f7" => Key::Functional(18, '~'),
        "f8" => Key::Functional(19, '~'),
        "f9" => Key::Functional(20, '~'),
        "f10" => Key::Functional(21, '~'),
        "f11" => Key::Functional(23, '~'),
        "f12" => Key::Functional(24, '~'),
        other => {
            let mut chars = other.chars();
            let c = chars.next()?;
            if chars.next().is_some() {
                return None;
            }
            Key::Text(c.to_lowercase().next().unwrap_or(c))
        }
    })
}

fn modifier_bits(mods: KeyMods) -> u32 {
    u32::from(mods.shift) | (u32::from(mods.alt) << 1) | (u32::from(mods.control) << 2)
}

/// Encode one key event. `key_char` is the text the key types (with Shift
/// and Option applied). `flags` are the current enhancement flags.
pub fn encode(
    key: &str,
    key_char: Option<&str>,
    mods: KeyMods,
    flags: u32,
    event: KittyEventType,
) -> KittyOutput {
    if flags == 0 || mods.platform {
        return KittyOutput::Legacy;
    }
    let Some(kind) = classify(key) else {
        return KittyOutput::Legacy;
    };
    let all = flags & ALL_KEYS_AS_ESCAPES != 0;
    let disambiguate = flags & DISAMBIGUATE != 0;
    let report_types = flags & EVENT_TYPES != 0;
    let bits = modifier_bits(mods);
    // Without event types, a repeat is just another press and a release is
    // never sent.
    let event = match event {
        KittyEventType::Release if !report_types => return KittyOutput::Nothing,
        KittyEventType::Repeat if !report_types => KittyEventType::Press,
        other => other,
    };
    // A key that stays legacy sends nothing on release.
    let legacy = |event: KittyEventType| {
        if event == KittyEventType::Release {
            KittyOutput::Nothing
        } else {
            KittyOutput::Legacy
        }
    };
    let (code, final_char, shifted) = match kind {
        Key::Text(c) => {
            let only_shift = bits & !1 == 0;
            if !all && (only_shift || !disambiguate) {
                return legacy(event);
            }
            let shifted = (flags & ALTERNATE_KEYS != 0 && mods.shift)
                .then(|| key_char.and_then(single_char))
                .flatten()
                .filter(|s| *s != c);
            (c as u32, 'u', shifted)
        }
        Key::Special(code) => {
            let is_escape = code == 27;
            if !all && !(is_escape && disambiguate) && (bits == 0 || !disambiguate) {
                return legacy(event);
            }
            (code, 'u', None)
        }
        Key::Functional(number, final_char) => {
            if bits == 0 && event == KittyEventType::Press {
                return KittyOutput::Legacy;
            }
            (number, final_char, None)
        }
    };
    let mut out = format!("\x1b[{code}");
    if let Some(s) = shifted {
        out.push_str(&format!(":{}", s as u32));
    }
    let typed = report_types && event != KittyEventType::Press;
    let text: Option<Vec<u32>> = (flags & ASSOCIATED_TEXT != 0
        && all
        && event != KittyEventType::Release
        && !mods.control
        && !mods.alt)
        .then(|| {
            key_char.map(|t| {
                t.chars()
                    .filter(|c| !c.is_control())
                    .map(|c| c as u32)
                    .collect()
            })
        })
        .flatten()
        .filter(|t: &Vec<u32>| !t.is_empty());
    if bits > 0 || typed || text.is_some() {
        out.push_str(&format!(";{}", bits + 1));
        if typed {
            out.push_str(&format!(":{}", event as i32));
        }
    }
    if let Some(text) = text {
        let joined: Vec<String> = text.iter().map(u32::to_string).collect();
        out.push_str(&format!(";{}", joined.join(":")));
    }
    // Legacy-form keys with no parameters keep the `1` only when needed.
    if final_char != 'u' && final_char != '~' && code == 1 && bits == 0 && !typed {
        out = format!("\x1b[{final_char}");
    } else {
        out.push(final_char);
    }
    KittyOutput::Bytes(out.into_bytes())
}

fn single_char(text: &str) -> Option<char> {
    let mut chars = text.chars();
    let c = chars.next()?;
    chars.next().is_none().then_some(c)
}

#[cfg(test)]
mod tests {
    use super::*;

    const NONE: KeyMods = KeyMods {
        shift: false,
        alt: false,
        control: false,
        platform: false,
    };

    fn ctrl() -> KeyMods {
        KeyMods {
            control: true,
            ..NONE
        }
    }

    fn bytes(s: &str) -> KittyOutput {
        KittyOutput::Bytes(s.as_bytes().to_vec())
    }

    use KittyEventType::*;

    #[test]
    fn no_flags_is_legacy() {
        assert_eq!(
            encode("a", Some("a"), ctrl(), 0, Press),
            KittyOutput::Legacy
        );
    }

    #[test]
    fn disambiguate_keeps_plain_text_and_enter_legacy() {
        assert_eq!(encode("a", Some("a"), NONE, 1, Press), KittyOutput::Legacy);
        let shift = KeyMods {
            shift: true,
            ..NONE
        };
        assert_eq!(encode("a", Some("A"), shift, 1, Press), KittyOutput::Legacy);
        assert_eq!(encode("enter", None, NONE, 1, Press), KittyOutput::Legacy);
        assert_eq!(encode("tab", None, NONE, 1, Press), KittyOutput::Legacy);
    }

    #[test]
    fn disambiguate_encodes_escape_and_modified_keys() {
        assert_eq!(encode("escape", None, NONE, 1, Press), bytes("\x1b[27u"));
        assert_eq!(
            encode("c", Some("c"), ctrl(), 1, Press),
            bytes("\x1b[99;5u")
        );
        let alt = KeyMods { alt: true, ..NONE };
        assert_eq!(encode("b", Some("b"), alt, 1, Press), bytes("\x1b[98;3u"));
        assert_eq!(encode("enter", None, ctrl(), 1, Press), bytes("\x1b[13;5u"));
    }

    #[test]
    fn functional_keys_keep_legacy_form() {
        assert_eq!(encode("up", None, NONE, 1, Press), KittyOutput::Legacy);
        assert_eq!(encode("up", None, ctrl(), 1, Press), bytes("\x1b[1;5A"));
        assert_eq!(encode("delete", None, ctrl(), 1, Press), bytes("\x1b[3;5~"));
        assert_eq!(encode("f5", None, ctrl(), 1, Press), bytes("\x1b[15;5~"));
    }

    #[test]
    fn event_types_report_repeat_and_release() {
        assert_eq!(
            encode("a", Some("a"), NONE, 1, Release),
            KittyOutput::Nothing
        );
        assert_eq!(
            encode("escape", None, NONE, 1, Release),
            KittyOutput::Nothing
        );
        assert_eq!(
            encode("escape", None, NONE, 3, Release),
            bytes("\x1b[27;1:3u")
        );
        assert_eq!(
            encode("escape", None, NONE, 3, Repeat),
            bytes("\x1b[27;1:2u")
        );
        assert_eq!(encode("up", None, NONE, 3, Release), bytes("\x1b[1;1:3A"));
        // Repeats without the flag are plain presses.
        assert_eq!(encode("escape", None, NONE, 1, Repeat), bytes("\x1b[27u"));
    }

    #[test]
    fn all_keys_as_escapes_with_text_and_alternates() {
        assert_eq!(encode("a", Some("a"), NONE, 8, Press), bytes("\x1b[97u"));
        assert_eq!(encode("enter", None, NONE, 8, Press), bytes("\x1b[13u"));
        let shift = KeyMods {
            shift: true,
            ..NONE
        };
        assert_eq!(
            encode("a", Some("A"), shift, 8 | 4, Press),
            bytes("\x1b[97:65;2u")
        );
        assert_eq!(
            encode("a", Some("a"), NONE, 8 | 16, Press),
            bytes("\x1b[97;1;97u")
        );
        assert_eq!(
            encode("a", Some("a"), NONE, 8 | 2, Release),
            bytes("\x1b[97;1:3u")
        );
    }

    #[test]
    fn command_key_is_never_encoded() {
        let cmd = KeyMods {
            platform: true,
            ..NONE
        };
        assert_eq!(encode("c", Some("c"), cmd, 8, Press), KittyOutput::Legacy);
    }
}
