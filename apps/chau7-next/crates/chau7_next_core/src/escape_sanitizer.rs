//! Remove terminal escape sequences from text for logs and history.
//!
//! Ports `apps/chau7-macos/Sources/Chau7Core/EscapeSequenceSanitizer.swift`.
//!
//! `RustEscapeSanitizer.swift` is not a second implementation: it is a
//! `dlopen` shim that looks up `chau7_escape_sanitize` in `libchau7_parse` and
//! falls back to the Swift code when the symbol is missing. In this checkout
//! `rust/chau7_parse/src/lib.rs` is an empty stub, so the symbol does not exist
//! and the Swift patterns below are the only logic. This module ports those.

use regex::Regex;
use std::sync::OnceLock;

struct Patterns {
    /// OSC: ESC ] ... (BEL | ESC \)
    osc: Regex,
    /// OSC without the ESC prefix
    bare_osc: Regex,
    /// CSI: ESC [ params final_byte
    csi: Regex,
    /// CSI without the ESC prefix
    bare_csi: Regex,
    /// Bracketed paste markers
    paste: Regex,
    bare_paste: Regex,
    /// ESC + one character that is not `[` or `]`
    simple_esc: Regex,
}

fn patterns() -> &'static Patterns {
    static PATTERNS: OnceLock<Patterns> = OnceLock::new();
    PATTERNS.get_or_init(|| {
        let compile = |p: &str| Regex::new(p).expect("valid escape pattern");
        Patterns {
            osc: compile(r"\x{1b}\][^\x{07}\x{1b}]*(?:\x{07}|\x{1b}\\)?"),
            bare_osc: compile(r"\][0-9;]*[^\x{07}\x{1b}]*(?:\x{07})?"),
            csi: compile(r"\x{1b}\[[0-9;?]*[@-~]"),
            bare_csi: compile(r"\[[0-9;?]*[A-Za-z]"),
            paste: compile(r"\x{1b}\[20[01]~"),
            bare_paste: compile(r"\[20[01]~"),
            simple_esc: compile(r"\x{1b}[^\[\]]"),
        }
    })
}

/// `CharacterSet.whitespaces`: Unicode category Zs plus tab.
pub(crate) fn is_foundation_whitespace(c: char) -> bool {
    matches!(
        c,
        '\t' | ' ' | '\u{00A0}' | '\u{1680}' | '\u{2000}'
            ..='\u{200A}' | '\u{202F}' | '\u{205F}' | '\u{3000}'
    )
}

/// `CharacterSet.whitespacesAndNewlines`: Z* categories, U+0009 to U+000D
/// and U+0085.
pub(crate) fn is_foundation_whitespace_or_newline(c: char) -> bool {
    is_foundation_whitespace(c)
        || matches!(
            c,
            '\n' | '\u{0B}' | '\u{0C}' | '\r' | '\u{85}' | '\u{2028}' | '\u{2029}'
        )
}

/// `trimmingCharacters(in: .whitespaces)`.
pub(crate) fn trim_whitespaces(text: &str) -> &str {
    text.trim_matches(is_foundation_whitespace)
}

/// `trimmingCharacters(in: .whitespacesAndNewlines)`.
pub(crate) fn trim_whitespaces_and_newlines(text: &str) -> &str {
    text.trim_matches(is_foundation_whitespace_or_newline)
}

/// Strip all terminal escape sequences: CSI, OSC, focus events, cursor
/// reports, device attributes, bracketed paste markers, remaining control
/// characters (newline, carriage return and tab are kept), then collapse runs
/// of spaces and trim.
pub fn sanitize(text: &str) -> String {
    let p = patterns();
    // Order matters: most specific first.
    let mut result = p.osc.replace_all(text, "").into_owned();
    for re in [
        &p.bare_osc,
        &p.csi,
        &p.bare_csi,
        &p.paste,
        &p.bare_paste,
        &p.simple_esc,
    ] {
        result = re.replace_all(&result, "").into_owned();
    }

    let filtered: String = result
        .chars()
        .filter(|&c| {
            let v = c as u32;
            if v == 0x0A || v == 0x0D || v == 0x09 {
                return true;
            }
            !(v < 0x20 || v == 0x7F)
        })
        .collect();

    let mut collapsed = String::with_capacity(filtered.len());
    let mut last_was_space = false;
    for ch in filtered.chars() {
        if ch == ' ' {
            if !last_was_space {
                collapsed.push(ch);
            }
            last_was_space = true;
        } else {
            collapsed.push(ch);
            last_was_space = false;
        }
    }

    trim_whitespaces(&collapsed).to_string()
}

/// Default length limit for [`sanitize_for_logging`].
pub const DEFAULT_LOG_MAX_LENGTH: usize = 500;

/// Sanitize and limit the length (counted in characters); a longer text is cut
/// to `max_length - 3` characters plus `...`.
pub fn sanitize_for_logging(text: &str, max_length: usize) -> String {
    let sanitized = sanitize(text);
    if sanitized.chars().count() <= max_length {
        return sanitized;
    }
    let mut cut: String = sanitized
        .chars()
        .take(max_length.saturating_sub(3))
        .collect();
    cut.push_str("...");
    cut
}

/// True when the text has an ESC character or one of the bare sequences that
/// show up in logs once ESC was dropped.
pub fn contains_escape_sequences(text: &str) -> bool {
    if text.contains('\u{1b}') {
        return true;
    }
    ["[O", "[I", "]10;", "]11;", "]7;", "[?", "[200~", "[201~"]
        .iter()
        .any(|pattern| text.contains(pattern))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn s(text: &str) -> String {
        sanitize(text)
    }

    #[test]
    fn sanitize_csi_with_esc_prefix() {
        assert_eq!(s("Hello\u{1b}[32mWorld\u{1b}[0m"), "HelloWorld");
    }

    #[test]
    fn sanitize_csi_focus_events() {
        assert_eq!(s("before\u{1b}[Oafter\u{1b}[Iend"), "beforeafterend");
    }

    #[test]
    fn sanitize_csi_cursor_report() {
        assert_eq!(s("text\u{1b}[5;1Rmore"), "textmore");
    }

    #[test]
    fn sanitize_csi_device_attributes() {
        assert_eq!(s("\u{1b}[?65;4;1;2;6;21;22;17;28c"), "");
    }

    #[test]
    fn sanitize_bare_csi() {
        assert_eq!(s("foo[32mbar"), "foobar");
    }

    #[test]
    fn sanitize_osc_with_bel() {
        assert_eq!(s("text\u{1b}]10;rgb:ff/ff/ff\u{07}more"), "textmore");
    }

    #[test]
    fn sanitize_osc_with_esc_backslash() {
        assert_eq!(s("text\u{1b}]7;file:///home/user\u{1b}\\more"), "textmore");
    }

    #[test]
    fn sanitize_bare_osc() {
        assert_eq!(s("foo]10;rgb:00/00/00\u{07}bar"), "foobar");
    }

    #[test]
    fn sanitize_bracketed_paste_markers() {
        assert_eq!(s("\u{1b}[200~pasted text\u{1b}[201~"), "pasted text");
    }

    #[test]
    fn sanitize_bare_bracketed_paste() {
        assert_eq!(s("[200~text[201~"), "text");
    }

    #[test]
    fn sanitize_esc_reset() {
        assert_eq!(s("before\u{1b}cafter"), "beforeafter");
    }

    #[test]
    fn sanitize_esc_save_cursor() {
        assert_eq!(s("\u{1b}7text\u{1b}8"), "text");
    }

    #[test]
    fn sanitize_control_characters_removed() {
        assert_eq!(s("he\u{00}ll\u{07}o\u{08}"), "hello");
    }

    #[test]
    fn sanitize_preserves_newlines() {
        assert_eq!(s("line1\nline2\rline3"), "line1\nline2\rline3");
    }

    #[test]
    fn sanitize_preserves_tabs() {
        assert_eq!(s("col1\tcol2\tcol3"), "col1\tcol2\tcol3");
    }

    #[test]
    fn sanitize_removes_del() {
        assert_eq!(s("hel\u{7f}lo"), "hello");
    }

    #[test]
    fn sanitize_collapses_multiple_spaces() {
        assert_eq!(s("hello     world"), "hello world");
    }

    #[test]
    fn sanitize_trims_leading_trailing_whitespace() {
        assert_eq!(s("   hello world   "), "hello world");
    }

    #[test]
    fn sanitize_clean_text_unchanged() {
        assert_eq!(s("just normal text"), "just normal text");
    }

    #[test]
    fn sanitize_empty_string() {
        assert_eq!(s(""), "");
    }

    #[test]
    fn sanitize_only_escape_sequences() {
        assert_eq!(s("\u{1b}[32m\u{1b}[0m\u{1b}c"), "");
    }

    #[test]
    fn sanitize_mixed_sequence_types() {
        assert_eq!(
            s("\u{1b}[1mBold\u{1b}[0m \u{1b}]7;file:///tmp\u{07} \u{00}end"),
            "Bold end"
        );
    }

    #[test]
    fn sanitize_unicode_preserved() {
        assert_eq!(s("Tâche terminée 🎉"), "Tâche terminée 🎉");
    }

    #[test]
    fn sanitize_unicode_with_escapes() {
        assert_eq!(s("\u{1b}[32mRéussi\u{1b}[0m"), "Réussi");
    }

    #[test]
    fn sanitize_for_logging_short_text_unchanged() {
        assert_eq!(
            sanitize_for_logging("Short message", DEFAULT_LOG_MAX_LENGTH),
            "Short message"
        );
    }

    #[test]
    fn sanitize_for_logging_truncates_long_text() {
        let result = sanitize_for_logging(&"a".repeat(600), DEFAULT_LOG_MAX_LENGTH);
        assert_eq!(result.chars().count(), 500);
        assert!(result.ends_with("..."));
    }

    #[test]
    fn sanitize_for_logging_custom_max_length() {
        let result = sanitize_for_logging(&"b".repeat(50), 20);
        assert_eq!(result.chars().count(), 20);
        assert!(result.ends_with("..."));
    }

    #[test]
    fn sanitize_for_logging_exactly_max_length() {
        let result = sanitize_for_logging(&"c".repeat(500), DEFAULT_LOG_MAX_LENGTH);
        assert_eq!(result.chars().count(), 500);
        assert!(!result.ends_with("..."));
    }

    #[test]
    fn sanitize_for_logging_also_strips_escapes() {
        let input = format!("\u{1b}[31m{}\u{1b}[0m", "x".repeat(10));
        assert_eq!(
            sanitize_for_logging(&input, DEFAULT_LOG_MAX_LENGTH),
            "x".repeat(10)
        );
    }

    #[test]
    fn contains_escape_sequences_esc_character() {
        assert!(contains_escape_sequences("\u{1b}[32m"));
    }

    #[test]
    fn contains_escape_sequences_bare_focus_out() {
        assert!(contains_escape_sequences("text[Omore"));
    }

    #[test]
    fn contains_escape_sequences_bare_focus_in() {
        assert!(contains_escape_sequences("text[Imore"));
    }

    #[test]
    fn contains_escape_sequences_bare_osc_color() {
        assert!(contains_escape_sequences("]10;rgb:ff/ff/ff"));
    }

    #[test]
    fn contains_escape_sequences_bare_osc_path() {
        assert!(contains_escape_sequences("]7;file:///home"));
    }

    #[test]
    fn contains_escape_sequences_bare_bracketed_paste() {
        assert!(contains_escape_sequences("[200~"));
        assert!(contains_escape_sequences("[201~"));
    }

    #[test]
    fn contains_escape_sequences_bare_csi_question() {
        assert!(contains_escape_sequences("[?7u"));
    }

    #[test]
    fn contains_escape_sequences_clean_text() {
        assert!(!contains_escape_sequences("hello world"));
    }

    #[test]
    fn contains_escape_sequences_empty_string() {
        assert!(!contains_escape_sequences(""));
    }

    #[test]
    fn sanitize_many_consecutive_spaces() {
        let input = format!("start{}end", " ".repeat(1000));
        assert_eq!(s(&input), "start end");
    }

    // Branches without a Swift test.

    #[test]
    fn trim_keeps_newlines_but_drops_tabs_and_nbsp() {
        assert_eq!(s("\t\u{a0} hi \n"), "hi \n");
        assert_eq!(trim_whitespaces_and_newlines("\n\u{85} x \r"), "x");
    }
}
