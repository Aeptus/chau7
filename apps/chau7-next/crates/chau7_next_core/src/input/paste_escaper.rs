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

#[cfg(test)]
mod tests {
    use super::escape;

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
