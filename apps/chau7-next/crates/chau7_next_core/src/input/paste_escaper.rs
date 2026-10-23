//! Paste Escaped (Edit menu, context menu, Cmd+Opt+V).
//!
//! Ports `apps/chau7-macos/Sources/Chau7/Keyboard/PasteEscaper.swift`: a
//! backslash goes before backslash, single and double quotes, dollar,
//! backtick and exclamation mark, so pasted text cannot expand variables or
//! run command substitutions.

/// Escape `text` for pasting into a shell.
pub fn escape(text: &str) -> String {
    let mut out = String::with_capacity(text.len() + 8);
    for c in text.chars() {
        if matches!(c, '\\' | '\'' | '"' | '$' | '`' | '!') {
            out.push('\\');
        }
        out.push(c);
    }
    out
}

/// Bytes for a Paste Escaped of `text`: control characters other than tab
/// and line breaks are dropped (a raw ESC or Ctrl-C in the clipboard would
/// otherwise act as a keystroke), the rest is escaped with [`escape`], then
/// encoded like a normal paste (line endings normalized, bracketed paste
/// markers when the program asked for them, end markers stripped).
pub fn encode(text: &str, bracketed: bool) -> Vec<u8> {
    let cleaned: String = text
        .chars()
        .filter(|c| !c.is_control() || matches!(c, '\t' | '\n' | '\r'))
        .collect();
    crate::key_encoding::encode_paste(&escape(&cleaned), bracketed)
}

#[cfg(test)]
mod tests {
    use super::{encode, escape};

    #[test]
    fn encode_strips_controls_and_uses_paste_encoding() {
        assert_eq!(
            encode("a$\x1b[201~\x03b\nc", true),
            b"\x1b[200~a\\$[201~b\rc\x1b[201~".to_vec()
        );
        assert_eq!(encode("x\x1b[31m\ty\r\n", false), b"x[31m\ty\r".to_vec());
    }

    // Ports of `PasteEscaperTests`.

    #[test]
    fn escape_backslash() {
        assert_eq!(escape("path\\to\\file"), "path\\\\to\\\\file");
    }

    #[test]
    fn escape_single_quote() {
        assert_eq!(escape("it's"), "it\\'s");
    }

    #[test]
    fn escape_double_quote() {
        assert_eq!(escape("say \"hello\""), "say \\\"hello\\\"");
    }

    #[test]
    fn escape_dollar_sign() {
        assert_eq!(escape("$HOME"), "\\$HOME");
    }

    #[test]
    fn escape_backtick() {
        assert_eq!(escape("`whoami`"), "\\`whoami\\`");
    }

    #[test]
    fn escape_exclamation_mark() {
        assert_eq!(escape("hello!"), "hello\\!");
    }

    #[test]
    fn multiline_text() {
        assert!(escape("line1\nline2\nline3").contains('\n'));
    }

    #[test]
    fn multiline_with_special_chars() {
        let result = escape("echo $VAR\n`cmd`\npath\\dir");
        assert!(result.contains("\\$VAR"));
        assert!(result.contains("\\`cmd\\`"));
        assert!(result.contains("path\\\\dir"));
    }

    #[test]
    fn all_special_characters_together() {
        assert_eq!(escape("\\\"'$`!"), "\\\\\\\"\\'\\$\\`\\!");
    }

    #[test]
    fn empty_input() {
        assert_eq!(escape(""), "");
    }

    #[test]
    fn unicode_passed_through() {
        let result = escape("Hello, world \u{1F600}!");
        assert!(result.contains("Hello, world \u{1F600}"));
        assert!(result.ends_with("\\!"));
    }

    #[test]
    fn japanese_text() {
        let result = escape("echo '\u{3053}\u{3093}\u{306B}\u{3061}\u{306F}'");
        assert!(result.contains("\u{3053}\u{3093}"));
        assert!(result.contains("\\'"));
    }

    #[test]
    fn plain_ascii() {
        assert_eq!(escape("hello world 123"), "hello world 123");
    }

    #[test]
    fn paste_shell_command() {
        let result = escape("echo \"$HOME\" && ls `pwd`");
        assert!(result.contains("\\$HOME"));
        assert!(result.contains("\\`pwd\\`"));
    }

    #[test]
    fn paste_url_with_special_chars() {
        let input = "https://example.com/path?q=hello&name=world";
        assert_eq!(escape(input), input);
    }
}
