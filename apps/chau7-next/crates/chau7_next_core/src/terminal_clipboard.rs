//! Current Swift selection policy: preserve shell lines and reconstruct TUI wraps.
use std::borrow::Cow;

pub fn copied_text(text: &str, from_tui: bool) -> Cow<'_, str> {
    if from_tui {
        Cow::Owned(single_line(text))
    } else {
        Cow::Borrowed(text)
    }
}

fn is_newline(c: char) -> bool {
    matches!(
        c,
        '\n' | '\r' | '\u{b}' | '\u{c}' | '\u{85}' | '\u{2028}' | '\u{2029}'
    )
}

/// Bare hard wraps join split tokens; whitespace or blank rows separate arguments.
pub fn single_line(text: &str) -> String {
    let normalized = text.replace("\r\n", "\n");
    let mut result = String::new();
    let mut previous_whitespace = false;
    let mut blank_separator = false;
    for line in normalized.split(is_newline) {
        let content = line.trim_matches(char::is_whitespace);
        if content.is_empty() {
            blank_separator = !result.is_empty();
            continue;
        }
        let leading = line.chars().next().is_some_and(char::is_whitespace);
        if !result.is_empty() && (previous_whitespace || leading || blank_separator) {
            result.push(' ');
        }
        result.push_str(content);
        previous_whitespace = line.chars().next_back().is_some_and(char::is_whitespace);
        blank_separator = false;
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn normal_selection_preserves_every_byte() {
        let text = "  echo hello\r\n    --flag  value\n";
        assert_eq!(copied_text(text, false), text);
        assert!(matches!(copied_text(text, false), Cow::Borrowed(_)));
        assert_eq!(copied_text(text, true), "echo hello --flag  value");
    }
    #[test]
    fn tui_command_indentation_and_crlf_blank_rows() {
        assert_eq!(
            single_line("echo hello-world\n    --flag value"),
            "echo hello-world --flag value"
        );
        assert_eq!(
            single_line("  git status\r\n\r\n  --short  "),
            "git status --short"
        );
    }
    #[test]
    fn quotes_and_interior_whitespace_are_preserved() {
        assert_eq!(
            single_line("printf 'a  b'\n    --flag  value"),
            "printf 'a  b' --flag  value"
        );
        assert_eq!(single_line("echo '\tvalue'"), "echo '\tvalue'");
    }
    #[test]
    fn unicode_and_empty_selections() {
        assert_eq!(single_line("echo café\u{2028}    😀"), "echo café 😀");
        assert_eq!(single_line("\r\n  \t"), "");
    }
    #[test]
    fn every_newline_kind_keeps_wrapped_paths_and_urls_contiguous() {
        for separator in [
            "\n", "\r\n", "\r", "\u{b}", "\u{c}", "\u{85}", "\u{2028}", "\u{2029}",
        ] {
            assert_eq!(
                single_line(&format!("cat /tmp/verylongpa{separator}th/file.md")),
                "cat /tmp/verylongpath/file.md"
            );
            assert_eq!(
                single_line(&format!("curl https://example.com/verylong{separator}path")),
                "curl https://example.com/verylongpath"
            );
        }
    }
    #[test]
    fn boundary_whitespace_separates_arguments() {
        for text in [
            "echo hello \nworld",
            "echo hello\n    world",
            "echo hello\t\nworld",
        ] {
            assert_eq!(single_line(text), "echo hello world");
        }
        assert_eq!(single_line("first\n\nsecond"), "first second");
        assert_eq!(single_line("first\r\nsecond"), "firstsecond");
    }
}
