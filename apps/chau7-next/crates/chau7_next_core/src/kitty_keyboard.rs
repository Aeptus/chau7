//! Kitty progressive keyboard enhancement protocol.
//!
//! Ports `apps/chau7-macos/Sources/Chau7Core/KittyKeyboardProtocol.swift`. See
//! <https://sw.kovidgoyal.net/kitty/keyboard-protocol/>.
//!
//! Programs request modes with `CSI > flags u`, query with `CSI ? u` and pop
//! with `CSI < n u`. Flags: 1 disambiguate escape codes, 2 report event types,
//! 4 report alternate keys, 8 report all keys as escape codes, 16 report
//! associated text.

use std::ops::BitOr;

/// Enhancement flag state with its push/pop stack.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct KittyKeyboardProtocol {
    flags: u32,
    flag_stack: Vec<u32>,
}

impl KittyKeyboardProtocol {
    /// Maximum stack depth, to bound memory.
    pub const MAX_STACK_DEPTH: usize = 64;

    pub fn new() -> Self {
        Self::default()
    }

    /// Current enhancement flags.
    pub fn flags(&self) -> u32 {
        self.flags
    }

    /// Previous flag states, oldest first.
    pub fn flag_stack(&self) -> &[u32] {
        &self.flag_stack
    }

    /// Push the current flags and set new ones (`CSI > flags u`). A full stack
    /// drops the push but still sets the flags.
    pub fn push_flags(&mut self, new_flags: u32) {
        if self.flag_stack.len() < Self::MAX_STACK_DEPTH {
            self.flag_stack.push(self.flags);
        }
        self.flags = new_flags;
    }

    /// Pop `count` entries (`CSI < count u`); stops when the stack is empty.
    pub fn pop_flags(&mut self, count: i64) {
        for _ in 0..count {
            let Some(previous) = self.flag_stack.pop() else {
                break;
            };
            self.flags = previous;
        }
    }

    /// Response to a query: `CSI ? flags u`.
    pub fn query_response(&self) -> Vec<u8> {
        format!("\x1b[?{}u", self.flags).into_bytes()
    }

    pub fn disambiguate_escape_codes(&self) -> bool {
        self.flags & 1 != 0
    }

    pub fn report_event_types(&self) -> bool {
        self.flags & 2 != 0
    }

    pub fn report_alternate_keys(&self) -> bool {
        self.flags & 4 != 0
    }

    pub fn report_all_keys_as_escape_codes(&self) -> bool {
        self.flags & 8 != 0
    }

    pub fn report_associated_text(&self) -> bool {
        self.flags & 16 != 0
    }

    /// Encode a key event for the current flags:
    /// `CSI number[:shifted] ; modifiers[:event_type] u`. With no flags set the
    /// event's legacy bytes are returned unchanged.
    pub fn encode_key_event(&self, event: &KittyKeyEvent) -> Vec<u8> {
        if self.flags == 0 {
            return event.legacy_encoding.clone();
        }

        let mut parts: Vec<String> = Vec::new();

        let mut key_part = event.key_code.to_string();
        if self.report_alternate_keys()
            && let Some(shifted) = event.shifted_key
        {
            key_part.push_str(&format!(":{shifted}"));
        }
        parts.push(key_part);

        let mut mod_part = String::new();
        let mod_value = event.modifiers.wire_value();
        let typed = self.report_event_types() && event.event_type != KittyEventType::Press;
        if mod_value > 1 || typed {
            mod_part = mod_value.to_string();
        }
        if typed {
            mod_part.push_str(&format!(":{}", event.event_type as i32));
        }
        if !mod_part.is_empty() {
            parts.push(mod_part);
        }

        format!("\x1b[{}u", parts.join(";")).into_bytes()
    }

    /// Recognize a keyboard-protocol request. `None` for anything else.
    pub fn parse_request(sequence: &[u8]) -> Option<KeyboardProtocolRequest> {
        if sequence.len() < 3 || sequence[0] != 0x1B || sequence[1] != 0x5B {
            return None;
        }
        let content = &sequence[2..];
        let (&last, inner) = content.split_last()?;
        if last != b'u' {
            return None;
        }
        let Some(&first) = inner.first() else {
            return Some(KeyboardProtocolRequest::Query);
        };
        // Swift reads the digits as ASCII text; non-ASCII means "use default".
        let number = |default: &str| -> String {
            let rest = &inner[1..];
            if rest.is_ascii() {
                String::from_utf8_lossy(rest).into_owned()
            } else {
                default.to_string()
            }
        };
        match first {
            b'>' => {
                let flags = number("0").parse::<u32>().unwrap_or(0);
                Some(KeyboardProtocolRequest::Push(flags))
            }
            b'<' => {
                let count = number("1").parse::<i64>().unwrap_or(1);
                Some(KeyboardProtocolRequest::Pop(count))
            }
            b'?' => Some(KeyboardProtocolRequest::Query),
            _ => None,
        }
    }
}

/// One key event to encode.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct KittyKeyEvent {
    /// Unicode code point or functional key number.
    pub key_code: i64,
    pub shifted_key: Option<i64>,
    pub base_key: Option<i64>,
    pub modifiers: KittyModifiers,
    pub event_type: KittyEventType,
    /// Associated text (flag 16).
    pub text: Option<String>,
    /// Sequence used when no enhancement is active.
    pub legacy_encoding: Vec<u8>,
}

impl KittyKeyEvent {
    /// A press of `key_code` with no modifiers and no legacy bytes.
    pub fn new(key_code: i64) -> Self {
        Self {
            key_code,
            shifted_key: None,
            base_key: None,
            modifiers: KittyModifiers::NONE,
            event_type: KittyEventType::Press,
            text: None,
            legacy_encoding: Vec::new(),
        }
    }
}

/// Modifier bit set (same bits as Swift's `OptionSet`).
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct KittyModifiers(pub u32);

impl KittyModifiers {
    pub const NONE: Self = Self(0);
    pub const SHIFT: Self = Self(1);
    pub const ALT: Self = Self(1 << 1);
    pub const CTRL: Self = Self(1 << 2);
    pub const SUPER: Self = Self(1 << 3);
    pub const HYPER: Self = Self(1 << 4);
    pub const META: Self = Self(1 << 5);
    pub const CAPS_LOCK: Self = Self(1 << 6);
    pub const NUM_LOCK: Self = Self(1 << 7);

    pub fn contains(self, other: Self) -> bool {
        self.0 & other.0 == other.0
    }

    /// The protocol's 1-based modifier value.
    pub fn wire_value(self) -> u32 {
        self.0 + 1
    }
}

impl BitOr for KittyModifiers {
    type Output = Self;
    fn bitor(self, rhs: Self) -> Self {
        Self(self.0 | rhs.0)
    }
}

/// Event type; the numbers are the wire values.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum KittyEventType {
    Press = 1,
    Repeat = 2,
    Release = 3,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum KeyboardProtocolRequest {
    Push(u32),
    Pop(i64),
    Query,
}

#[cfg(test)]
mod tests {
    use super::*;

    fn seq(text: &str) -> Vec<u8> {
        text.as_bytes().to_vec()
    }

    #[test]
    fn initial_flags_are_zero() {
        let proto = KittyKeyboardProtocol::new();
        assert_eq!(proto.flags(), 0);
        assert!(proto.flag_stack().is_empty());
    }

    #[test]
    fn push_flags() {
        let mut proto = KittyKeyboardProtocol::new();
        proto.push_flags(3);
        assert_eq!(proto.flags(), 3);
        assert_eq!(proto.flag_stack(), &[0]);
    }

    #[test]
    fn push_multiple_flags() {
        let mut proto = KittyKeyboardProtocol::new();
        proto.push_flags(1);
        proto.push_flags(3);
        proto.push_flags(7);
        assert_eq!(proto.flags(), 7);
        assert_eq!(proto.flag_stack(), &[0, 1, 3]);
    }

    #[test]
    fn pop_flags() {
        let mut proto = KittyKeyboardProtocol::new();
        proto.push_flags(1);
        proto.push_flags(3);
        proto.pop_flags(1);
        assert_eq!(proto.flags(), 1);
        assert_eq!(proto.flag_stack(), &[0]);
    }

    #[test]
    fn pop_multiple_flags() {
        let mut proto = KittyKeyboardProtocol::new();
        proto.push_flags(1);
        proto.push_flags(3);
        proto.push_flags(7);
        proto.pop_flags(2);
        assert_eq!(proto.flags(), 1);
        assert_eq!(proto.flag_stack(), &[0]);
    }

    #[test]
    fn pop_on_empty_stack_is_noop() {
        let mut proto = KittyKeyboardProtocol::new();
        proto.push_flags(5);
        proto.pop_flags(10);
        assert_eq!(proto.flags(), 0);
        assert!(proto.flag_stack().is_empty());
    }

    #[test]
    fn max_stack_depth() {
        let mut proto = KittyKeyboardProtocol::new();
        for i in 0..(KittyKeyboardProtocol::MAX_STACK_DEPTH + 10) {
            proto.push_flags(i as u32);
        }
        assert_eq!(
            proto.flag_stack().len(),
            KittyKeyboardProtocol::MAX_STACK_DEPTH
        );
    }

    #[test]
    fn query_response() {
        let mut proto = KittyKeyboardProtocol::new();
        proto.push_flags(5);
        assert_eq!(proto.query_response(), seq("\x1b[?5u"));
    }

    #[test]
    fn query_response_zero_flags() {
        assert_eq!(
            KittyKeyboardProtocol::new().query_response(),
            seq("\x1b[?0u")
        );
    }

    #[test]
    fn disambiguate_escape_codes() {
        let mut proto = KittyKeyboardProtocol::new();
        assert!(!proto.disambiguate_escape_codes());
        proto.push_flags(1);
        assert!(proto.disambiguate_escape_codes());
    }

    #[test]
    fn report_event_types() {
        let mut proto = KittyKeyboardProtocol::new();
        assert!(!proto.report_event_types());
        proto.push_flags(2);
        assert!(proto.report_event_types());
    }

    #[test]
    fn report_alternate_keys() {
        let mut proto = KittyKeyboardProtocol::new();
        assert!(!proto.report_alternate_keys());
        proto.push_flags(4);
        assert!(proto.report_alternate_keys());
    }

    #[test]
    fn report_all_keys_as_escape_codes() {
        let mut proto = KittyKeyboardProtocol::new();
        assert!(!proto.report_all_keys_as_escape_codes());
        proto.push_flags(8);
        assert!(proto.report_all_keys_as_escape_codes());
    }

    #[test]
    fn report_associated_text() {
        let mut proto = KittyKeyboardProtocol::new();
        assert!(!proto.report_associated_text());
        proto.push_flags(16);
        assert!(proto.report_associated_text());
    }

    #[test]
    fn combined_flags() {
        let mut proto = KittyKeyboardProtocol::new();
        proto.push_flags(0b11111);
        assert!(proto.disambiguate_escape_codes());
        assert!(proto.report_event_types());
        assert!(proto.report_alternate_keys());
        assert!(proto.report_all_keys_as_escape_codes());
        assert!(proto.report_associated_text());
    }

    #[test]
    fn encode_with_no_flags() {
        let proto = KittyKeyboardProtocol::new();
        let event = KittyKeyEvent {
            legacy_encoding: vec![0x61],
            ..KittyKeyEvent::new(97)
        };
        assert_eq!(proto.encode_key_event(&event), vec![0x61]);
    }

    #[test]
    fn encode_simple_key_with_disambiguate() {
        let mut proto = KittyKeyboardProtocol::new();
        proto.push_flags(1);
        assert_eq!(
            proto.encode_key_event(&KittyKeyEvent::new(97)),
            seq("\x1b[97u")
        );
    }

    #[test]
    fn encode_key_with_modifiers() {
        let mut proto = KittyKeyboardProtocol::new();
        proto.push_flags(1);
        let event = KittyKeyEvent {
            modifiers: KittyModifiers::SHIFT,
            ..KittyKeyEvent::new(97)
        };
        assert_eq!(proto.encode_key_event(&event), seq("\x1b[97;2u"));
    }

    #[test]
    fn encode_key_with_event_type() {
        let mut proto = KittyKeyboardProtocol::new();
        proto.push_flags(3);
        let event = KittyKeyEvent {
            event_type: KittyEventType::Release,
            ..KittyKeyEvent::new(97)
        };
        assert_eq!(proto.encode_key_event(&event), seq("\x1b[97;1:3u"));
    }

    #[test]
    fn encode_key_with_alternate_keys() {
        let mut proto = KittyKeyboardProtocol::new();
        proto.push_flags(4);
        let event = KittyKeyEvent {
            shifted_key: Some(65),
            ..KittyKeyEvent::new(97)
        };
        assert_eq!(proto.encode_key_event(&event), seq("\x1b[97:65u"));
    }

    #[test]
    fn parse_request_push() {
        assert_eq!(
            KittyKeyboardProtocol::parse_request(&seq("\x1b[>3u")),
            Some(KeyboardProtocolRequest::Push(3))
        );
    }

    #[test]
    fn parse_request_pop() {
        assert_eq!(
            KittyKeyboardProtocol::parse_request(&seq("\x1b[<2u")),
            Some(KeyboardProtocolRequest::Pop(2))
        );
    }

    #[test]
    fn parse_request_pop_default() {
        assert_eq!(
            KittyKeyboardProtocol::parse_request(&seq("\x1b[<u")),
            Some(KeyboardProtocolRequest::Pop(1))
        );
    }

    #[test]
    fn parse_request_query() {
        assert_eq!(
            KittyKeyboardProtocol::parse_request(&seq("\x1b[?u")),
            Some(KeyboardProtocolRequest::Query)
        );
    }

    #[test]
    fn parse_request_too_short() {
        assert_eq!(KittyKeyboardProtocol::parse_request(&[0x1B, 0x5B]), None);
    }

    #[test]
    fn parse_request_wrong_terminator() {
        assert_eq!(KittyKeyboardProtocol::parse_request(&seq("\x1b[>3x")), None);
    }

    #[test]
    fn parse_request_not_csi() {
        assert_eq!(
            KittyKeyboardProtocol::parse_request(&[0x41, 0x42, 0x43]),
            None
        );
    }

    #[test]
    fn parse_request_push_large_flags() {
        assert_eq!(
            KittyKeyboardProtocol::parse_request(&seq("\x1b[>31u")),
            Some(KeyboardProtocolRequest::Push(31))
        );
    }

    // Branches without a Swift test.

    #[test]
    fn bare_csi_u_is_a_query_and_junk_numbers_use_defaults() {
        assert_eq!(
            KittyKeyboardProtocol::parse_request(&seq("\x1b[u")),
            Some(KeyboardProtocolRequest::Query)
        );
        assert_eq!(
            KittyKeyboardProtocol::parse_request(&seq("\x1b[>1;2u")),
            Some(KeyboardProtocolRequest::Push(0))
        );
        assert_eq!(KittyKeyboardProtocol::parse_request(&seq("\x1b[=1u")), None);
    }

    #[test]
    fn modifiers_combine_into_wire_value() {
        let mods = KittyModifiers::SHIFT | KittyModifiers::CTRL;
        assert_eq!(mods.wire_value(), 6);
        assert!(mods.contains(KittyModifiers::CTRL));
        assert!(!mods.contains(KittyModifiers::ALT));
    }
}
