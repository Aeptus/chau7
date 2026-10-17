//! Find in scrollback with the find panel's options
//! (`TerminalSessionModel.updateSearch`): plain text or regex, case
//! sensitive or not, whole words only or not, at most 400 matches and 12
//! preview lines.

use std::ops::Range;

/// `maxMatches` in `refreshSearch`.
pub const MAX_MATCHES: usize = 400;
/// `maxPreviewLines` in `refreshSearch`.
pub const MAX_PREVIEW_LINES: usize = 12;

#[derive(Debug, Clone, Default, PartialEq)]
pub struct SearchSummary {
    /// (grid line, column range in characters).
    pub matches: Vec<(i32, Range<usize>)>,
    /// Text of the first matching lines, in order, each once.
    pub preview: Vec<String>,
    /// "Invalid regex" when the pattern does not compile.
    pub error: Option<String>,
}

/// The find panel's toggles.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct SearchOptions {
    pub case_sensitive: bool,
    pub regex: bool,
    pub whole_word: bool,
}

/// Search `lines` (grid line number, text).
pub fn search(
    lines: &[(i32, String)],
    query: &str,
    case_sensitive: bool,
    regex: bool,
) -> SearchSummary {
    search_with(
        lines,
        query,
        SearchOptions {
            case_sensitive,
            regex,
            whole_word: false,
        },
    )
}

/// Search `lines` with all options. Whole word wraps the pattern (escaped
/// unless regex is on) in `\b` boundaries.
pub fn search_with(lines: &[(i32, String)], query: &str, options: SearchOptions) -> SearchSummary {
    let mut summary = SearchSummary::default();
    if query.is_empty() {
        return summary;
    }
    let body = if options.regex {
        query.to_string()
    } else {
        regex::escape(query)
    };
    let pattern = if options.whole_word {
        format!(r"\b(?:{body})\b")
    } else {
        body
    };
    let Ok(re) = regex::RegexBuilder::new(&pattern)
        .case_insensitive(!options.case_sensitive)
        .build()
    else {
        summary.error = Some("Invalid regex".into());
        return summary;
    };
    'lines: for (line, text) in lines {
        let mut matched = false;
        for m in re.find_iter(text) {
            if m.start() == m.end() {
                continue;
            }
            let start = text[..m.start()].chars().count();
            let len = m.as_str().chars().count();
            summary.matches.push((*line, start..start + len));
            matched = true;
            if summary.matches.len() >= MAX_MATCHES {
                if summary.preview.len() < MAX_PREVIEW_LINES {
                    summary.preview.push(text.clone());
                }
                break 'lines;
            }
        }
        if matched && summary.preview.len() < MAX_PREVIEW_LINES {
            summary.preview.push(text.clone());
        }
    }
    summary
}

/// Delay before refreshing matches after new output, by buffer size in
/// lines (`scheduleSearchRefresh`: 50, 100 or 150 ms).
pub fn refresh_debounce_ms(buffer_lines: usize) -> u64 {
    if buffer_lines < 1000 {
        50
    } else if buffer_lines < 5000 {
        100
    } else {
        150
    }
}

/// Ranges of `query` in `line` for the preview highlight
/// (`SearchResultRow.attributedLine`): plain text only, character ranges.
pub fn highlight_ranges(line: &str, query: &str, case_sensitive: bool) -> Vec<Range<usize>> {
    if query.is_empty() {
        return Vec::new();
    }
    search(&[(0, line.to_string())], query, case_sensitive, false)
        .matches
        .into_iter()
        .map(|(_, r)| r)
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn lines() -> Vec<(i32, String)> {
        vec![
            (-2, "Error: foo error".to_string()),
            (0, "ok".to_string()),
            (1, "é error".to_string()),
        ]
    }

    #[test]
    fn plain_case_insensitive_and_sensitive() {
        let s = search(&lines(), "error", false, false);
        assert_eq!(s.matches, vec![(-2, 0..5), (-2, 11..16), (1, 2..7)]);
        assert_eq!(s.preview, vec!["Error: foo error", "é error"]);
        let s = search(&lines(), "Error", true, false);
        assert_eq!(s.matches, vec![(-2, 0..5)]);
    }

    #[test]
    fn regex_and_invalid_regex() {
        let s = search(&lines(), "f.o", false, true);
        assert_eq!(s.matches, vec![(-2, 7..10)]);
        // Without regex, "." is literal.
        assert!(search(&lines(), "f.o", false, false).matches.is_empty());
        let s = search(&lines(), "(", false, true);
        assert_eq!(s.error.as_deref(), Some("Invalid regex"));
        assert!(s.matches.is_empty());
    }

    #[test]
    fn caps_matches_and_preview() {
        let many: Vec<(i32, String)> = (0..500).map(|i| (i, "x".to_string())).collect();
        let s = search(&many, "x", false, false);
        assert_eq!(s.matches.len(), MAX_MATCHES);
        assert_eq!(s.preview.len(), MAX_PREVIEW_LINES);
    }

    #[test]
    fn highlights() {
        assert_eq!(
            highlight_ranges("a foo FOO", "foo", false),
            vec![2..5, 6..9]
        );
        assert_eq!(highlight_ranges("a foo FOO", "foo", true), vec![2..5]);
    }

    #[test]
    fn whole_word_and_debounce() {
        let lines = vec![
            (-2, "Error: foo error".to_string()),
            (-1, "errors everywhere".to_string()),
        ];
        let word = SearchOptions {
            whole_word: true,
            ..Default::default()
        };
        assert_eq!(
            search_with(&lines, "error", word).matches,
            vec![(-2, 0..5), (-2, 11..16)]
        );
        let re = SearchOptions {
            regex: true,
            ..Default::default()
        };
        assert_eq!(
            search_with(&lines, "err\\w+", re).matches,
            vec![(-2, 0..5), (-2, 11..16), (-1, 0..6)]
        );
        // Plain text with whole word escapes regex characters.
        let text = vec![(0, "a.b axb".to_string())];
        assert_eq!(search_with(&text, "a.b", word).matches, vec![(0, 0..3)]);
        assert_eq!(refresh_debounce_ms(10), 50);
        assert_eq!(refresh_debounce_ms(2000), 100);
        assert_eq!(refresh_debounce_ms(9000), 150);
    }
}
