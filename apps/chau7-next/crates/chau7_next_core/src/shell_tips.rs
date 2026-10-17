//! The boxed power-user tip printed above the first prompt of a new terminal.
//!
//! Ports `PowerUserTips.swift` (tips, with the English text of
//! `Localizable.strings`) and `terminalHeaderBox` / `sanitizeBoxMessage` from
//! `Terminal/Views/TerminalViewRepresentable.swift`.

/// (text, shortcut) in Swift's order.
pub const TIPS: &[(&str, Option<&str>)] = &[
    ("Open a new tab instantly", Some("\u{2318}T")),
    ("Create a new window", Some("\u{2318}N")),
    ("Close the current tab", Some("\u{2318}W")),
    ("Close the entire window", Some("\u{2318}\u{21E7}W")),
    ("Jump directly to any tab", Some("\u{2318}1-9")),
    ("Cycle through tabs quickly", Some("\u{2318}\u{21E7}[ / ]")),
    ("Search through terminal output", Some("\u{2318}F")),
    ("Jump to the next search match", Some("\u{2318}G")),
    (
        "Jump to the previous search match",
        Some("\u{2318}\u{21E7}G"),
    ),
    ("Search for selected text", Some("\u{2318}E")),
    ("Split the pane vertically", Some("\u{2318}D")),
    ("Split the pane horizontally", Some("\u{2318}\u{21E7}D")),
    (
        "Navigate between split panes",
        Some("\u{2318}\u{2325}\u{2191}\u{2193}\u{2190}\u{2192}"),
    ),
    ("Close the current split pane", Some("\u{2318}\u{2303}W")),
    ("Make all panes equal size", Some("\u{2318}\u{2325}E")),
    ("Maximize the current pane", Some("\u{2318}\u{21E7}E")),
    ("Clear the terminal screen", Some("\u{2318}K")),
    (
        "Clear screen and scrollback history",
        Some("\u{2318}\u{21E7}K"),
    ),
    ("Adjust font size on the fly", Some("\u{2318}+ / \u{2318}-")),
    ("Reset font size to default", Some("\u{2318}0")),
    ("Select the current input line", Some("\u{2318}A")),
    (
        "Double-tap to select entire buffer",
        Some("\u{2318}A \u{2318}A"),
    ),
    ("Triple-click to select an entire line", None),
    ("Double-click to select a word", None),
    (
        "Cmd+click to open file paths in your editor",
        Some("\u{2318}+Click"),
    ),
    (
        "Option+click to position cursor anywhere",
        Some("\u{2325}+Click"),
    ),
    (
        "Enable copy-on-select in Settings > Input for faster copying",
        None,
    ),
    ("Print terminal output", Some("\u{2318}P")),
    (
        "Open the command palette for quick actions",
        Some("\u{2318}\u{21E7}P"),
    ),
    ("Insert code snippets quickly", Some("\u{2318};")),
    ("Open a new SSH connection", Some("\u{2318}\u{21E7}O")),
    ("Toggle fullscreen mode", Some("\u{2318}\u{2303}F")),
    (
        "Broadcast mode lets you type in multiple tabs at once",
        None,
    ),
    (
        "Tab dot colors: green=idle, orange=running, blue=waiting, red=stuck",
        None,
    ),
    (
        "Right-click a tab to change its color for organization",
        None,
    ),
    ("Double-click a tab to rename it", None),
];

/// `formattedTip`: a light bulb, the text and the shortcut in brackets.
pub fn formatted_tip(index: usize) -> String {
    let (text, shortcut) = TIPS[index % TIPS.len()];
    match shortcut {
        Some(s) => format!("\u{1F4A1} {text} [{s}]"),
        None => format!("\u{1F4A1} {text}"),
    }
}

/// A tip picked from `seed` (any varying number, such as the time).
pub fn random_formatted_tip(seed: u64) -> String {
    formatted_tip((seed % TIPS.len() as u64) as usize)
}

/// ASCII-only box text: symbols spelled out, other non-ASCII characters
/// replaced by spaces, whitespace collapsed (`sanitizeBoxMessage`).
pub fn sanitize_box_message(message: &str) -> String {
    let replacements = [
        ("\u{1F4A1}", "TIP"),
        ("\u{2318}", "CMD+"),
        ("\u{21E7}", "SHIFT+"),
        ("\u{2325}", "OPT+"),
        ("\u{2303}", "CTRL+"),
        ("\u{2192}", "->"),
        ("\u{2190}", "<-"),
        ("\u{2191}", "^"),
        ("\u{2193}", "v"),
        ("\u{2022}", "*"),
    ];
    let mut working = message.to_string();
    for (from, to) in replacements {
        working = working.replace(from, to);
    }
    let ascii: String = working
        .chars()
        .map(|c| if c.is_ascii() { c } else { ' ' })
        .collect();
    ascii.split_whitespace().collect::<Vec<_>>().join(" ")
}

/// Columns kept free on the right of the box for the shortcut helper hint in
/// the top-right corner of the terminal (Swift kept 18, for a narrower hint).
pub const HINT_RESERVE_COLS: usize = 40;

/// The box for a terminal `cols` wide, bright white, ending with a newline;
/// `None` when the terminal is too narrow (`terminalHeaderBox`). The box hugs
/// the text (one space each side) instead of spanning the terminal and stays
/// clear of the shortcut hint; text that does not fit is wrapped onto more
/// lines rather than cut. A pane made narrower later then only rewraps the box
/// when it gets narrower than the box itself.
pub fn header_box(cols: usize, message: &str) -> Option<String> {
    let side_margin = 2;
    let max_interior = (cols as isize) - (side_margin * 2) - HINT_RESERVE_COLS as isize;
    if max_interior < 4 {
        return None;
    }
    let width = max_interior as usize - 2;
    let lines = wrap_words(&sanitize_box_message(message), width);
    let longest = lines.iter().map(|l| l.chars().count()).max().unwrap_or(0);
    let interior = longest + 2;
    let prefix = " ".repeat(side_margin as usize);
    let border = format!("{prefix}+{}+", "-".repeat(interior));
    let mut out = format!("\x1b[97m{border}\r\n");
    for line in &lines {
        let padding = interior - line.chars().count();
        let left = padding / 2;
        let right = padding - left;
        out.push_str(&format!(
            "{prefix}|{}{line}{}|\r\n",
            " ".repeat(left),
            " ".repeat(right)
        ));
    }
    out.push_str(&format!("{border}\x1b[0m\r\n"));
    Some(out)
}

/// Words of `text` in lines at most `width` characters long (a longer word
/// is split).
fn wrap_words(text: &str, width: usize) -> Vec<String> {
    let width = width.max(1);
    let mut lines: Vec<String> = Vec::new();
    let mut current = String::new();
    for word in text.split_whitespace() {
        let mut word: Vec<char> = word.chars().collect();
        while word.len() > width {
            if !current.is_empty() {
                lines.push(std::mem::take(&mut current));
            }
            lines.push(word.drain(..width).collect());
        }
        let word: String = word.into_iter().collect();
        if word.is_empty() {
            continue;
        }
        let needed =
            current.chars().count() + usize::from(!current.is_empty()) + word.chars().count();
        if !current.is_empty() && needed > width {
            lines.push(std::mem::take(&mut current));
        }
        if !current.is_empty() {
            current.push(' ');
        }
        current.push_str(&word);
    }
    if !current.is_empty() || lines.is_empty() {
        lines.push(current);
    }
    lines
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sanitizes_symbols() {
        assert_eq!(
            sanitize_box_message("\u{1F4A1} Open a new tab [\u{2318}\u{21E7}T]"),
            "TIP Open a new tab [CMD+SHIFT+T]"
        );
        assert_eq!(sanitize_box_message("a \u{e9}  b"), "a b");
    }

    #[test]
    fn box_layout() {
        let b = header_box(60, "hello").unwrap();
        let lines: Vec<&str> = b.trim_end_matches("\r\n").split("\r\n").collect();
        assert_eq!(lines.len(), 3);
        // The box hugs the text: one space on each side.
        assert_eq!(lines[0], "\x1b[97m  +-------+");
        assert_eq!(lines[1], "  | hello |");
        assert!(b.ends_with("\x1b[0m\r\n"));
        // Too narrow once the hint's columns are kept free.
        assert!(header_box(4 + HINT_RESERVE_COLS + 3, "x").is_none());
        let cols = 4 + HINT_RESERVE_COLS + 14;
        let long = header_box(cols, "a very long message that does not fit").unwrap();
        // Wrapped, not cut.
        assert!(!long.contains("..."));
        assert_eq!(long.matches('|').count(), 2 * 3);
        assert!(long.contains("does not fit"));
        // Every line stays left of the hint.
        for line in long.split("\r\n") {
            let visible = line.replace("\x1b[97m", "").replace("\x1b[0m", "");
            assert!(
                visible.chars().count() <= cols - HINT_RESERVE_COLS,
                "{visible}"
            );
        }
    }

    #[test]
    fn tips_format() {
        assert_eq!(
            formatted_tip(0),
            "\u{1F4A1} Open a new tab instantly [\u{2318}T]"
        );
        assert!(!random_formatted_tip(12345).is_empty());
        assert_eq!(TIPS.len(), 36);
    }
}
