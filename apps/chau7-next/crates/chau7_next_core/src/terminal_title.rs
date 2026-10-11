//! Stable display titles matching current TerminalTitleChurnPolicy.
use unicode_segmentation::UnicodeSegmentation;

pub fn stable_display_title(raw: &str) -> &str {
    let trimmed = raw.trim();
    let Some(first) = trimmed.graphemes(true).next() else {
        return trimmed;
    };
    let scalar = first.chars().next().expect("nonempty grapheme");
    let spinner = (0x2800..=0x28ff).contains(&(scalar as u32))
        || matches!(
            scalar,
            '-' | '\\'
                | '|'
                | '/'
                | '◐'
                | '◓'
                | '◑'
                | '◒'
                | '◴'
                | '◷'
                | '◶'
                | '◵'
                | '✳'
                | '✴'
                | '✶'
                | '✷'
                | '✸'
                | '✹'
                | '✺'
        );
    let remaining = &trimmed[first.len()..];
    if spinner && remaining.chars().next().is_some_and(char::is_whitespace) {
        let normalized = remaining.trim();
        if !normalized.is_empty() {
            return normalized;
        }
    }
    trimmed
}

pub fn should_deliver_title(raw: &str, last_delivered: Option<&str>) -> bool {
    Some(stable_display_title(raw)) != last_delivered
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn braille_and_ascii_tokens_are_removed() {
        for raw in [
            "⠦ Mockup",
            "| Mockup",
            "  ◒ Mockup  ",
            "-\tMockup",
            "✳\u{fe0f} Mockup",
            "⠦\u{301} Mockup",
        ] {
            assert_eq!(stable_display_title(raw), "Mockup", "{raw}");
        }
        assert_eq!(stable_display_title("⠐ Audit database"), "Audit database");
    }
    #[test]
    fn substantive_paths_and_non_tokens_are_preserved() {
        for raw in [
            "/Users/me/Mockup",
            "-option",
            "Mockup",
            "⠦",
            "|",
            "⠦mockup",
            "⠦  ",
        ] {
            assert_eq!(stable_display_title(raw), raw.trim(), "{raw}");
        }
        assert_eq!(stable_display_title("\n "), "");
    }
    #[test]
    fn spinner_churn_is_suppressed_but_real_changes_are_delivered() {
        assert!(!should_deliver_title("⠧ Mockup", Some("Mockup")));
        assert!(should_deliver_title("⠧ Build finished", Some("Mockup")));
        assert!(should_deliver_title("Mockup", None));
    }
}
