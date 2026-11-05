//! Bounded matching of owned startup artifacts without changing terminal styling.

/// Normalize saved terminal context before it is persisted or replayed.
///
/// Old ANSI exports included every viewport row, so blank rows can sit between
/// earlier output and a later startup tip. Remove only complete boxes generated
/// from the built-in tip list: a box at the beginning, or one preceded by at
/// least eight contiguous blank rows. This repairs known restore artifacts
/// while preserving ordinary interior blank lines and other boxed user output.
pub fn normalize_scrollback_for_restore(text: &str) -> String {
    normalize_with(text, known_startup_tip_box_line_count)
}

fn normalize_with(
    text: &str,
    mut recognize: impl FnMut(&[&str], usize) -> Option<usize>,
) -> String {
    const MIN_INTERIOR_TIP_PADDING_ROWS: usize = 8;

    let lines: Vec<&str> = text.split('\n').collect();
    let mut removed = vec![false; lines.len()];
    let mut index = 0;
    let mut padding_rows = 0;
    while index < lines.len() {
        // An interior box can only be removed after a legacy viewport gap.
        // Track the gap once rather than constructing every candidate first.
        if (index == 0 || padding_rows >= MIN_INTERIOR_TIP_PADDING_ROWS)
            && let Some(box_lines) = recognize(&lines, index)
        {
            if padding_rows >= MIN_INTERIOR_TIP_PADDING_ROWS {
                removed[index - padding_rows..index].fill(true);
            }
            let end = (index + box_lines).min(lines.len());
            removed[index..end].fill(true);
            index = end;
            padding_rows = 0;
            continue;
        }
        padding_rows = if terminal_line_is_blank(lines[index]) {
            padding_rows + 1
        } else {
            0
        };
        index += 1;
    }

    let mut retained: Vec<&str> = lines
        .into_iter()
        .enumerate()
        .filter_map(|(index, line)| (!removed[index]).then_some(line))
        .collect();
    while retained
        .last()
        .is_some_and(|line| terminal_line_is_blank(line))
    {
        retained.pop();
    }
    let mut normalized = retained.join("\n");
    if normalized.ends_with('\r') {
        normalized.pop();
    }
    normalized
}

fn terminal_line_is_blank(line: &str) -> bool {
    // Most rows contain text. Stop at its first visible non-whitespace
    // character instead of allocating and scanning a copy of every row.
    visible_chars_for_restore(line).all(char::is_whitespace)
}

/// Return the physical line count only for a complete built-in startup tip
/// box. The leading border bounds candidate widths; visible row text then has
/// to match a generated tip exactly, allowing only terminal cell padding after
/// each row. header_box uses the message width cols - (hint reserve + 6):
/// the reserved hint plus fixed side margins and border padding.
pub(super) fn known_startup_tip_box_line_count(lines: &[&str], start: usize) -> Option<usize> {
    recognize_with(lines, start, crate::shell_tips::header_box)
}

fn recognize_with(
    lines: &[&str],
    start: usize,
    mut generate: impl FnMut(usize, &str) -> Option<String>,
) -> Option<usize> {
    let first = visible_for_restore(lines.get(start)?);
    let border = first.trim_end_matches(['\r', ' ']);
    let dashes = border.strip_prefix("  +")?.strip_suffix('+')?;
    if dashes.is_empty() || !dashes.chars().all(|ch| ch == '-') {
        return None;
    }
    let minimum_width = dashes.chars().count().checked_sub(2)?;

    // Greedy wrapping at W has exactly the same rows when repeated at the
    // longest produced row M <= W: accepted groups fit M and rejected groups
    // exceed W. Split long words force M == W. The border gives M directly,
    // so enumerating every width through the message length is unnecessary.
    static TIPS: std::sync::OnceLock<Vec<(String, usize)>> = std::sync::OnceLock::new();
    let tips = TIPS.get_or_init(|| {
        (0..crate::shell_tips::TIPS.len())
            .map(|index| {
                let tip = crate::shell_tips::formatted_tip(index);
                let width = crate::shell_tips::sanitize_box_message(&tip)
                    .chars()
                    .count();
                (tip, width)
            })
            .collect()
    });
    for (tip, maximum_width) in tips {
        if minimum_width > *maximum_width {
            continue;
        }
        let cols = minimum_width + crate::shell_tips::HINT_RESERVE_COLS + 6;
        let Some(generated) = generate(cols, tip) else {
            continue;
        };
        let visible = visible_for_restore(&generated);
        let expected: Vec<&str> = visible.split_terminator('\n').collect();
        if expected.is_empty() || start + expected.len() > lines.len() {
            continue;
        }
        let matches = expected.iter().enumerate().all(|(offset, expected_line)| {
            let actual = visible_for_restore(lines[start + offset]);
            let actual = actual.strip_suffix('\r').unwrap_or(actual.as_str());
            let expected_line = expected_line.strip_suffix('\r').unwrap_or(*expected_line);
            actual
                .strip_prefix(expected_line)
                .is_some_and(|padding| padding.chars().all(|ch| ch == ' '))
        });
        if matches {
            return Some(expected.len());
        }
    }
    None
}

/// Strip terminal control sequences without collapsing spaces. Matching restore
/// artifacts must not rewrite actual styled output or column alignment.
pub fn visible_for_restore(text: &str) -> String {
    let mut result = String::with_capacity(text.len());
    result.extend(visible_chars_for_restore(text));
    result
}

fn visible_chars_for_restore(text: &str) -> impl Iterator<Item = char> + '_ {
    let mut chars = text.chars().peekable();
    std::iter::from_fn(move || {
        while let Some(c) = chars.next() {
            if c != '\u{1b}' {
                if matches!(c, '\n' | '\r' | '\t') || (c >= ' ' && c != '\u{7f}') {
                    return Some(c);
                }
                continue;
            }
            match chars.next() {
                Some('[') => {
                    for c in chars.by_ref() {
                        if ('@'..='~').contains(&c) {
                            break;
                        }
                    }
                }
                Some(']') => {
                    while let Some(c) = chars.next() {
                        if c == '\u{7}' {
                            break;
                        }
                        if c == '\u{1b}' && chars.peek() == Some(&'\\') {
                            chars.next();
                            break;
                        }
                    }
                }
                _ => {}
            }
        }
        None
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn blank_rows_ignore_controls_but_preserve_visible_unicode() {
        for text in [
            "",
            " \t\r",
            "\u{2003}",
            "\x1b[31m  \x1b[0m",
            "\x1b]0;title\x07\t",
            "\x1b]0;title\x1b\\ ",
            "\x01\x7f",
            "\x1b[",
            "\x1b]unfinished",
        ] {
            assert!(terminal_line_is_blank(text), "{text:?}");
            assert!(visible_for_restore(text).trim().is_empty(), "{text:?}");
        }
        for text in [
            "x",
            "\x1b[31mx\x1b[0m",
            "\x1b]0;title\x07界",
            "\x1b]0;title\x1b\\ 🦀",
            "\x1b[0m  +----+",
        ] {
            assert!(!terminal_line_is_blank(text), "{text:?}");
            assert!(!visible_for_restore(text).trim().is_empty(), "{text:?}");
        }
        assert_eq!(
            visible_for_restore("\x1b[31mred\x1b[0m\t\x1b]0;hidden\x07界\r\n"),
            "red\t界\r\n"
        );
    }

    #[test]
    fn normalization_preserves_styling_and_removes_only_blank_tail() {
        let row = "\x1b[31mreal output 界\x1b[0m";
        let input = format!("{row}\n\x1b[0m \t\r\n\x1b]0;title\x07");
        assert_eq!(normalize_scrollback_for_restore(&input), row);
    }

    #[test]
    fn ordinary_boxed_output_only_checks_the_initial_position() {
        let input = format!(
            "ordinary output\n{}",
            "  +----+\n  | xx |\n  +----+\n".repeat(16)
        );
        let mut calls = 0;
        let result = normalize_with(&input, |lines, index| {
            calls += 1;
            known_startup_tip_box_line_count(lines, index)
        });
        assert_eq!(result, input.trim_end_matches('\n'));
        assert_eq!(
            calls, 1,
            "interior rows without legacy padding cannot be removed"
        );
    }

    #[test]
    fn border_width_requires_at_most_one_generation_per_tip() {
        let lines = ["  +----+", "  | xx |", "  +----+"];
        let mut generated = 0;
        assert_eq!(
            recognize_with(&lines, 0, |cols, tip| {
                generated += 1;
                crate::shell_tips::header_box(cols, tip)
            }),
            None
        );
        assert!(
            generated <= crate::shell_tips::TIPS.len(),
            "generated {generated} candidates"
        );
    }

    #[test]
    fn tip_matching_preserves_every_tip_and_wrap_width() {
        for cols in 48..=180 {
            for tip in 0..crate::shell_tips::TIPS.len() {
                let generated =
                    crate::shell_tips::header_box(cols, &crate::shell_tips::formatted_tip(tip))
                        .unwrap();
                let padded = generated.replace("\r\n", "   \r\n");
                let lines: Vec<_> = padded.split('\n').collect();
                assert_eq!(
                    known_startup_tip_box_line_count(&lines, 0),
                    Some(
                        visible_for_restore(&generated)
                            .split_terminator('\n')
                            .count()
                    ),
                    "tip {tip} cols {cols}"
                );
            }
        }
    }

    #[test]
    #[ignore = "explicit serial normalization benchmark; no application or agents"]
    fn boxed_output_normalization_cost() {
        let input = format!(
            "ordinary output\n{}",
            "  +----+\n  | xx |\n  +----+\n".repeat(64)
        );
        let started = std::time::Instant::now();
        for _ in 0..3 {
            let output = normalize_scrollback_for_restore(std::hint::black_box(&input));
            assert_eq!(output, input.trim_end_matches('\n'));
            std::hint::black_box(output);
        }
        eprintln!(
            "normalization fixture: bytes={} iterations=3 elapsed_us={}",
            input.len(),
            started.elapsed().as_micros()
        );
    }
}
