//! A single undoable replacement for selected-line indentation (UTF-8 offsets).
use std::ops::Range;

#[derive(Debug, PartialEq, Eq)]
pub(super) struct Edit {
    pub range: Range<usize>,
    pub replacement: String,
    pub selection: Range<usize>,
}

pub(super) fn selected_lines(
    text: &str,
    selection: Range<usize>,
    tab: &str,
    outdent: bool,
) -> Option<Edit> {
    if tab.is_empty()
        || selection.start > selection.end
        || !text.is_char_boundary(selection.start)
        || !text.is_char_boundary(selection.end)
    {
        return None;
    }
    let start = text[..selection.start].rfind('\n').map_or(0, |n| n + 1);
    // Ending at the following line's start does not select that line.
    let last = if selection.end > selection.start {
        selection.end - 1
    } else {
        selection.end
    };
    let end = text.as_bytes()[last..]
        .iter()
        .position(|c| *c == b'\n')
        .map_or(text.len(), |n| last + n);
    let mut replacement = String::new();
    let mut changes = Vec::new();
    let mut offset = start;
    for line in text[start..end].split('\n') {
        let removed = if !outdent {
            0
        } else if line.starts_with('\t') {
            1
        } else {
            line.bytes()
                .take_while(|c| *c == b' ')
                .count()
                .min(tab.chars().count())
        };
        let prefix = if outdent { "" } else { tab };
        if removed > 0 || !prefix.is_empty() {
            changes.push((offset, removed, prefix.len()));
        }
        replacement.push_str(prefix);
        replacement.push_str(&line[removed..]);
        offset += line.len() + 1;
        if offset <= end {
            replacement.push('\n');
        }
    }
    if changes.is_empty() {
        return None;
    }
    let map = |position: usize| {
        let mut delta: isize = 0;
        for &(at, removed, added) in &changes {
            if position < at {
                break;
            }
            if position < at + removed {
                return (at as isize + delta) as usize;
            }
            delta += added as isize - removed as isize;
        }
        (position as isize + delta) as usize
    };
    let selected_start = if selection.start != selection.end && selection.start == start {
        start
    } else {
        map(selection.start)
    };
    Some(Edit {
        range: start..end,
        replacement,
        selection: selected_start..map(selection.end),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    fn apply(text: &str, edit: &Edit) -> String {
        format!(
            "{}{}{}",
            &text[..edit.range.start],
            edit.replacement,
            &text[edit.range.end..]
        )
    }

    #[test]
    fn indent_keeps_selected_multiline_text_and_excludes_next_line() {
        let text = "café😀\nsecond\nthird";
        let end = "café😀\nsecond\n".len();
        let edit = selected_lines(text, 0..end, "  ", false).unwrap();
        assert_eq!(apply(text, &edit), "  café😀\n  second\nthird");
        assert_eq!(edit.selection, 0..end + 4);
        let next = apply(text, &edit);
        let unindent = selected_lines(&next, edit.selection, "  ", true).unwrap();
        assert_eq!(apply(&next, &unindent), text);
        assert_eq!(unindent.selection, 0..end);
    }

    #[test]
    fn outdent_handles_partial_spaces_tabs_and_unindented_lines() {
        let text = " a\n\tb\nplain\n  c";
        let edit = selected_lines(text, 0..text.len(), "    ", true).unwrap();
        assert_eq!(apply(text, &edit), "a\nb\nplain\nc");
        assert_eq!(edit.selection, 0.."a\nb\nplain\nc".len());
    }

    #[test]
    fn collapsed_outdent_preserves_unicode_caret_and_blank_final_line() {
        let text = "  😀\n";
        let edit = selected_lines(text, 6..6, "  ", true).unwrap();
        assert_eq!(apply(text, &edit), "😀\n");
        assert_eq!(edit.selection, 4..4);
        assert!(selected_lines(text, text.len()..text.len(), "  ", true).is_none());
    }

    #[test]
    fn crlf_and_partial_line_selection_are_preserved() {
        let text = "first\r\nsecond\r\n";
        let edit = selected_lines(text, 2..10, "\t", false).unwrap();
        assert_eq!(apply(text, &edit), "\tfirst\r\n\tsecond\r\n");
        assert_eq!(edit.selection, 3..12);
        assert!(selected_lines("é", 1..2, "  ", false).is_none());
        assert!(selected_lines("a", 0..2, "  ", false).is_none());
    }
}
