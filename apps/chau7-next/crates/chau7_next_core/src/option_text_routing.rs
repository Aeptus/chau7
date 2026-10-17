//! When an Option-modified key is literal text instead of a Meta shortcut.
//!
//! Ports `apps/chau7-macos/Sources/Chau7Core/OptionModifiedTextRouting.swift`.
//! International layouts use Option to type programming characters such as
//! `[` and `{`; those must reach the terminal as the rendered character, not
//! as an ESC-prefixed fallback. Letter chords such as Option+B keep Meta
//! behavior.

/// True when the key event should be sent as the typed character.
///
/// `characters` is the text the key produced with modifiers applied and
/// `characters_ignoring_modifiers` the text of the base key (the two
/// `NSEvent` properties of the same names).
pub fn should_treat_as_literal_text(
    characters: Option<&str>,
    characters_ignoring_modifiers: Option<&str>,
    has_option: bool,
    has_control: bool,
    has_command: bool,
) -> bool {
    if !has_option || has_control || has_command {
        return false;
    }
    let (Some(characters), Some(base_characters)) = (characters, characters_ignoring_modifiers)
    else {
        return false;
    };
    let (Some(rendered), Some(base)) = (single_scalar(characters), single_scalar(base_characters))
    else {
        return false;
    };
    if characters == base_characters
        || !rendered.is_ascii()
        || (rendered as u32) < 0x20
        || rendered as u32 == 0x7F
    {
        return false;
    }
    // Letter chords keep Meta; punctuation from non-letter base keys is text.
    !base.is_alphabetic()
}

fn single_scalar(text: &str) -> Option<char> {
    let mut chars = text.chars();
    let first = chars.next()?;
    chars.next().is_none().then_some(first)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn treats_international_bracket_shortcut_as_literal_text() {
        assert!(should_treat_as_literal_text(
            Some("["),
            Some("5"),
            true,
            false,
            false
        ));
    }

    #[test]
    fn treats_international_brace_shortcut_as_literal_text() {
        assert!(should_treat_as_literal_text(
            Some("{"),
            Some("("),
            true,
            false,
            false
        ));
    }

    #[test]
    fn keeps_option_letter_chord_as_meta_shortcut() {
        assert!(!should_treat_as_literal_text(
            Some("\u{222B}"),
            Some("b"),
            true,
            false,
            false
        ));
    }

    #[test]
    fn ignores_non_option_chord() {
        assert!(!should_treat_as_literal_text(
            Some("["),
            Some("5"),
            false,
            false,
            false
        ));
    }

    // Branches without a Swift test.

    #[test]
    fn rejects_missing_multi_scalar_equal_and_control_text() {
        assert!(!should_treat_as_literal_text(
            None,
            Some("5"),
            true,
            false,
            false
        ));
        assert!(!should_treat_as_literal_text(
            Some("["),
            None,
            true,
            false,
            false
        ));
        assert!(!should_treat_as_literal_text(
            Some("[]"),
            Some("5"),
            true,
            false,
            false
        ));
        assert!(!should_treat_as_literal_text(
            Some("5"),
            Some("5"),
            true,
            false,
            false
        ));
        assert!(!should_treat_as_literal_text(
            Some("\u{1b}"),
            Some("5"),
            true,
            false,
            false
        ));
        assert!(!should_treat_as_literal_text(
            Some("["),
            Some("5"),
            true,
            true,
            false
        ));
        assert!(!should_treat_as_literal_text(
            Some("["),
            Some("5"),
            true,
            false,
            true
        ));
    }
}
