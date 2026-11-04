//! Keep native source editing in AppKit; forward only application shortcuts.

pub(super) fn forward_to_host(key: &str, command: bool, control: bool) -> bool {
    // Cocoa navigation/function-key characters and editing controls must reach
    // NSTextView.keyDown, including Shift/Option/Command selection variants.
    if key.chars().any(|c| {
        matches!(
            c,
            '\u{f700}'..='\u{f703}' | '\u{f727}'..='\u{f72d}' | '\u{8}' | '\u{7f}' | '\r' | '\n' | '\u{1b}'
        )
    }) {
        return false;
    }
    // Function-row shortcuts (notably Chau7's F11 fullscreen action) belong
    // to the host even without Command or Control.
    if key.chars().count() == 1 && key.chars().any(|c| matches!(c, '\u{f704}'..='\u{f726}')) {
        return true;
    }
    if matches!(key, "\t" | "\u{19}") {
        return control; // Chau7's Ctrl+Tab / Ctrl+Shift+Tab tab switching.
    }
    command && !key.is_empty()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn navigation_and_editing_stay_native_with_every_modifier_combination() {
        for key in [
            "\u{f700}", "\u{f701}", "\u{f702}", "\u{f703}", "\u{f729}", "\u{f72b}", "\u{f72c}",
            "\u{f72d}", "\u{f728}", "\u{8}", "\u{7f}", "\r", "\n", "\u{1b}",
        ] {
            for command in [false, true] {
                for control in [false, true] {
                    assert!(!forward_to_host(key, command, control), "{key:?}");
                }
            }
        }
    }

    #[test]
    fn ordinary_text_emacs_navigation_and_indentation_stay_native() {
        for key in ["a", "e", "b", "f", "n", "p", "é", "😀", "", "\t", "\u{19}"] {
            assert!(!forward_to_host(key, false, false));
        }
        for key in ["a", "e", "b", "f", "n", "p", "d", "h", "k"] {
            assert!(!forward_to_host(key, false, true));
        }
    }

    #[test]
    fn application_shortcuts_and_control_tab_reach_host() {
        for key in ["t", "n", "w", ",", "1", "f"] {
            assert!(forward_to_host(key, true, false));
        }
        assert!(forward_to_host("f", true, true)); // Ctrl+Command+F fullscreen.
        for key in ["\u{f704}", "\u{f70e}", "\u{f726}"] {
            assert!(forward_to_host(key, false, false));
            assert!(forward_to_host(key, true, true));
        }
        for key in ["\t", "\u{19}"] {
            assert!(forward_to_host(key, false, true));
            assert!(!forward_to_host(key, true, false));
        }
    }
}
