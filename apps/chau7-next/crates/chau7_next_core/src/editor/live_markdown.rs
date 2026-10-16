//! Light editable Markdown: every marker remains in the original UTF-8 text.
//! Matches the current Swift MarkdownLiveStyler's ordered semantic attributes.
use regex::Regex;
use std::{ops::Range, sync::LazyLock};
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Kind {
    Heading(u8),
    Marker,
    Bold,
    Italic,
    CodeSpan,
    CodeFence,
    Strikethrough,
    LinkText,
    Blockquote,
    ListMarker,
    HorizontalRule,
    TaskCheckbox(bool),
    CompletedTask,
    TerminalSpan {
        bold: bool,
        italic: bool,
        underline: bool,
        strikethrough: bool,
        foreground: Option<[u8; 3]>,
        background: Option<[u8; 3]>,
    },
    TerminalLink,
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Run {
    pub kind: Kind,
    pub range: Range<usize>,
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Indent {
    /// Raw marker prefix; a native renderer measures it in the body font.
    pub prefix: Range<usize>,
    pub paragraph: Range<usize>,
}
#[derive(Debug, Clone)]
struct Line {
    range: Range<usize>,
    inside_before: bool,
    inside_after: bool,
    runs: Vec<Run>,
    indent: Option<Indent>,
}
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct Update {
    pub full: bool,
    pub restyled_lines: usize,
}
#[derive(Debug, Clone, Default)]
struct TerminalMarkdownData {
    runs: Vec<Run>,
    hidden_ranges: Vec<Range<usize>>,
    links: Vec<(Range<usize>, String)>,
}
#[derive(Debug, Clone, Default)]
pub struct Document {
    text: String,
    lines: Vec<Line>,
    runs: Vec<Run>,
    indents: Vec<Indent>,
    hidden_terminal_ranges: Vec<Range<usize>>,
    terminal_links: Vec<(Range<usize>, String)>,
    restyled: Range<usize>,
}
impl Document {
    pub fn runs(&self) -> &[Run] {
        &self.runs
    }
    pub fn indents(&self) -> &[Indent] {
        &self.indents
    }
    /// Source ranges occupied by structurally complete terminal-selection
    /// fence markers. Native rendering can hide these while retaining source.
    pub fn hidden_terminal_ranges(&self) -> &[Range<usize>] {
        &self.hidden_terminal_ranges
    }
    /// Link text ranges and their validated destinations in terminal selections.
    pub fn terminal_links(&self) -> &[(Range<usize>, String)] {
        &self.terminal_links
    }
    /// Last update window, on UTF-8 boundaries; empty when text did not change.
    pub fn restyled_range(&self) -> Range<usize> {
        self.restyled.clone()
    }
    pub fn text(&self) -> &str {
        &self.text
    }
    pub fn update(&mut self, text: &str) -> Update {
        if text == self.text {
            self.restyled = 0..0;
            return Update::default();
        }
        if self.lines.is_empty() {
            return self.replace(text);
        }
        // Terminal style metadata is byte-offset based. Reparse the complete
        // document on edits to a valid or invalid terminal fence so stale
        // offsets can never be applied to changed source.
        if self
            .text
            .contains(crate::terminal_clipboard::STYLED_SELECTION_FENCE_INFO)
            || text.contains(crate::terminal_clipboard::STYLED_SELECTION_FENCE_INFO)
        {
            return self.replace(text);
        }
        let (prefix, suffix) = common_edges(&self.text, text);
        let old_changed = prefix..self.text.len() - suffix;
        let changed = prefix..text.len() - suffix;
        let new_ranges = line_ranges(text, 0);
        let old_ranges: Vec<_> = self.lines.iter().map(|l| l.range.clone()).collect();
        if contains_fence(&self.text, &old_ranges, old_changed.clone())
            || contains_fence(text, &new_ranges, changed.clone())
        {
            return self.replace(text);
        }
        let old_window = expanded(&old_ranges, old_changed);
        let window = expanded(&new_ranges, changed);
        let delta = text.len() as isize - self.text.len() as isize;
        let start = old_window.start.min(window.start);
        let end = window.end.max(shift(old_window.end, delta));
        let old_end = shift(end, -delta);
        let before = self
            .lines
            .iter()
            .position(|l| l.range.start == start)
            .unwrap_or(0);
        let tail = self.lines.partition_point(|l| l.range.start < old_end);
        let inside = self.lines.get(before).is_some_and(|l| l.inside_before);
        let middle = parse_lines(&text[start..end], start, inside);
        // An interpretation change must restyle downstream text rather than reuse it.
        if let Some(next) = self.lines.get(tail)
            && middle.last().map_or(inside, |l| l.inside_after) != next.inside_before
        {
            return self.replace(text);
        }
        let count = middle.len();
        let mut lines = self.lines[..before].to_vec();
        lines.extend(middle);
        lines.extend(self.lines[tail..].iter().cloned().map(|mut line| {
            line.range = shift_range(line.range, delta);
            for run in &mut line.runs {
                run.range = shift_range(run.range.clone(), delta);
            }
            if let Some(indent) = &mut line.indent {
                indent.prefix = shift_range(indent.prefix.clone(), delta);
                indent.paragraph = shift_range(indent.paragraph.clone(), delta);
            }
            line
        }));
        self.text = text.into();
        self.lines = lines;
        self.restyled = start..end;
        self.flatten();
        Update {
            full: false,
            restyled_lines: count,
        }
    }
    fn replace(&mut self, text: &str) -> Update {
        self.text = text.into();
        self.lines = parse_lines(text, 0, false);
        self.restyled = 0..text.len();
        self.flatten();
        Update {
            full: true,
            restyled_lines: self.lines.len(),
        }
    }
    fn flatten(&mut self) {
        self.runs = self
            .lines
            .iter()
            .flat_map(|l| l.runs.iter().cloned())
            .collect();
        self.indents = self.lines.iter().filter_map(|l| l.indent.clone()).collect();
        let terminal = terminal_markdown_data(&self.text, &self.lines);
        self.runs.extend(terminal.runs);
        self.hidden_terminal_ranges = terminal.hidden_ranges;
        self.terminal_links = terminal.links;
    }
}
fn shift(index: usize, delta: isize) -> usize {
    index.checked_add_signed(delta).expect("bounded edit delta")
}
fn shift_range(range: Range<usize>, delta: isize) -> Range<usize> {
    shift(range.start, delta)..shift(range.end, delta)
}
fn common_edges(old: &str, new: &str) -> (usize, usize) {
    let mut prefix = old
        .bytes()
        .zip(new.bytes())
        .take_while(|(a, b)| a == b)
        .count();
    while !old.is_char_boundary(prefix) || !new.is_char_boundary(prefix) {
        prefix -= 1;
    }
    let mut suffix = old[prefix..]
        .bytes()
        .rev()
        .zip(new[prefix..].bytes().rev())
        .take_while(|(a, b)| a == b)
        .count();
    while !old.is_char_boundary(old.len() - suffix) || !new.is_char_boundary(new.len() - suffix) {
        suffix -= 1;
    }
    (prefix, suffix)
}
fn line_ranges(text: &str, offset: usize) -> Vec<Range<usize>> {
    let mut out = Vec::new();
    let mut start = 0;
    let mut chars = text.char_indices().peekable();
    while let Some((i, c)) = chars.next() {
        if matches!(c, '\n' | '\r' | '\u{85}' | '\u{2028}' | '\u{2029}') {
            let mut end = i + c.len_utf8();
            if c == '\r' && chars.peek().is_some_and(|(_, c)| *c == '\n') {
                end = chars.next().unwrap().0 + 1;
            }
            out.push(offset + start..offset + end);
            start = end;
        }
    }
    if start < text.len() {
        out.push(offset + start..offset + text.len());
    }
    out
}
fn line_body(text: &str) -> &str {
    text.trim_end_matches(['\n', '\r', '\u{85}', '\u{2028}', '\u{2029}'])
}
fn fence(text: &str) -> bool {
    let line = line_body(text).trim_start_matches(char::is_whitespace);
    line.starts_with("```") || line.starts_with("~~~")
}
fn touched(ranges: &[Range<usize>], change: Range<usize>) -> Range<usize> {
    if ranges.is_empty() {
        return 0..0;
    }
    let first = ranges
        .partition_point(|r| r.end <= change.start)
        .min(ranges.len() - 1);
    let last = ranges
        .partition_point(|r| r.start < change.end.max(change.start.saturating_add(1)))
        .max(first + 1)
        .min(ranges.len());
    first..last
}
fn expanded(ranges: &[Range<usize>], change: Range<usize>) -> Range<usize> {
    if ranges.is_empty() {
        return 0..0;
    }
    let range = touched(ranges, change);
    ranges[range.start.saturating_sub(1)].start..ranges[(range.end + 1).min(ranges.len()) - 1].end
}
fn contains_fence(text: &str, ranges: &[Range<usize>], change: Range<usize>) -> bool {
    let touched = touched(ranges, change);
    ranges[touched].iter().any(|r| fence(&text[r.clone()]))
}

fn terminal_markdown_data(text: &str, lines: &[Line]) -> TerminalMarkdownData {
    use crate::terminal_clipboard::{parse_markdown_block, parse_reserved_terminal_fence};

    let mut data = TerminalMarkdownData::default();
    let mut line_index = 0;
    while line_index < lines.len() {
        if lines[line_index].inside_before {
            line_index += 1;
            continue;
        }
        let line_start = lines[line_index].range.start;
        if let Some(block) = parse_markdown_block(text, line_start) {
            data.hidden_ranges
                .push(block.opening_range.start..block.body_range.start);
            data.hidden_ranges
                .push(line_range_with_ending(text, block.closing_range.clone()));
            for span in block.spans {
                let range = block.body_range.start + span.start..block.body_range.start + span.end;
                data.runs.push(Run {
                    kind: Kind::TerminalSpan {
                        bold: span.bold,
                        italic: span.italic,
                        underline: span.underline,
                        strikethrough: span.strikethrough,
                        foreground: span.foreground,
                        background: span.background,
                    },
                    range: range.clone(),
                });
                if let Some(link) = span.link {
                    data.links.push((range.clone(), link));
                    data.runs.push(Run {
                        kind: Kind::TerminalLink,
                        range,
                    });
                }
            }
            line_index =
                lines.partition_point(|line| line.range.start <= block.closing_range.start);
            continue;
        }

        // If style metadata no longer matches an edited body, preserve the
        // reserved fence behavior without trusting its offsets: keep the body
        // as ordinary monospace source, but hide wrapper lines only when the
        // fence still has an exact closing delimiter. An incomplete/malformed
        // block stays fully visible so source is never hidden speculatively.
        let Some(block) = parse_reserved_terminal_fence(text, line_start)
            .filter(|block| !block.closing_range.is_empty())
        else {
            line_index += 1;
            continue;
        };
        data.hidden_ranges
            .push(block.opening_range.start..block.body_range.start);
        data.hidden_ranges
            .push(line_range_with_ending(text, block.closing_range.clone()));
        line_index = lines.partition_point(|line| line.range.start <= block.closing_range.start);
    }
    data
}

fn line_range_with_ending(text: &str, range: Range<usize>) -> Range<usize> {
    let ending = &text[range.end..];
    let ending_len = if ending.starts_with("\r\n") {
        2
    } else if ending.starts_with('\n') || ending.starts_with('\r') {
        1
    } else {
        0
    };
    range.start..range.end + ending_len
}

static HEADING: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"^(\s*)(#{1,6})\s+(.*)$").unwrap());
static QUOTE: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"^\s*(>+)\s?(.*)$").unwrap());
static TASK: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"^\s*([-*+])\s+(\[[ xX]\])\s+(.*)$").unwrap());
static LIST: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"^\s*([-*+]|\d+[.)])\s+(.*)$").unwrap());
static CODE: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"`[^`\n]+`").unwrap());
static LINK: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"\[([^\]\n]+)\]\([^)\n]+\)").unwrap());
fn horizontal_rule(body: &str) -> bool {
    let trimmed = body.trim();
    trimmed.len() >= 3
        && trimmed.chars().next().is_some_and(|c| {
            matches!(c, '-' | '*' | '_') && trimmed.chars().all(|other| other == c)
        })
}
fn parse_lines(text: &str, offset: usize, mut inside: bool) -> Vec<Line> {
    let mut terminal_closing_start = None;
    line_ranges(text, offset)
        .into_iter()
        .map(|range| {
            let raw = &text[range.start - offset..range.end - offset];
            let body = line_body(raw);
            let mut runs = Vec::new();
            let local_start = range.start - offset;
            if !inside && terminal_closing_start.is_none() {
                terminal_closing_start =
                    crate::terminal_clipboard::parse_markdown_block(text, local_start)
                        .map(|block| block.closing_range.start);
            }
            if let Some(closing_start) = terminal_closing_start {
                if local_start <= closing_start {
                    let before = inside;
                    let whole = range.start..range.start + body.len();
                    if !whole.is_empty() {
                        runs.push(Run {
                            kind: Kind::CodeFence,
                            range: whole,
                        });
                    }
                    if local_start == closing_start {
                        terminal_closing_start = None;
                    }
                    return Line {
                        range,
                        inside_before: before,
                        inside_after: before,
                        runs,
                        indent: None,
                    };
                }
                terminal_closing_start = None;
            }
            let indent = TASK
                .captures(body)
                .and_then(|c| c.get(3))
                .or_else(|| LIST.captures(body).and_then(|c| c.get(2)))
                .or_else(|| QUOTE.captures(body).and_then(|c| c.get(2)))
                .map(|content| Indent {
                    prefix: range.start..range.start + content.start(),
                    paragraph: range.clone(),
                });
            let before = inside;
            // All semantic ranges use bytes, preserving GPUI caret/selection coordinates.
            let absolute = |local: Range<usize>| range.start + local.start..range.start + local.end;
            let whole = range.start..range.start + body.len();
            if fence(body) {
                runs.push(Run {
                    kind: Kind::CodeFence,
                    range: whole.clone(),
                });
                inside = !inside;
            } else if inside {
                if !whole.is_empty() {
                    runs.push(Run {
                        kind: Kind::CodeFence,
                        range: whole.clone(),
                    });
                }
            } else if let Some(c) = HEADING.captures(body) {
                let hashes = c.get(2).unwrap();
                let content = c.get(3).unwrap();
                runs.push(Run {
                    kind: Kind::Marker,
                    range: absolute(hashes.range()),
                });
                if !content.is_empty() {
                    runs.push(Run {
                        kind: Kind::Heading(hashes.len() as u8),
                        range: absolute(content.range()),
                    });
                }
            } else if horizontal_rule(body) {
                runs.push(Run {
                    kind: Kind::HorizontalRule,
                    range: whole.clone(),
                });
            } else {
                let mut content = 0..body.len();
                if let Some(c) = QUOTE.captures(body) {
                    runs.push(Run {
                        kind: Kind::Marker,
                        range: absolute(c.get(1).unwrap().range()),
                    });
                    content = c.get(2).unwrap().range();
                    if !content.is_empty() {
                        runs.push(Run {
                            kind: Kind::Blockquote,
                            range: absolute(content.clone()),
                        });
                    }
                } else if let Some(c) = TASK.captures(body) {
                    runs.push(Run {
                        kind: Kind::ListMarker,
                        range: absolute(c.get(1).unwrap().range()),
                    });
                    let box_ = c.get(2).unwrap();
                    let checked = box_.as_str().contains(['x', 'X']);
                    runs.push(Run {
                        kind: Kind::TaskCheckbox(checked),
                        range: absolute(box_.range()),
                    });
                    content = c.get(3).unwrap().range();
                    if checked && !content.is_empty() {
                        runs.push(Run {
                            kind: Kind::CompletedTask,
                            range: absolute(content.clone()),
                        });
                    }
                } else if let Some(c) = LIST.captures(body) {
                    runs.push(Run {
                        kind: Kind::ListMarker,
                        range: absolute(c.get(1).unwrap().range()),
                    });
                    content = c.get(2).unwrap().range();
                }
                let content_text = &body[content.clone()];
                let base = range.start + content.start;
                for m in CODE.find_iter(content_text) {
                    runs.push(Run {
                        kind: Kind::CodeSpan,
                        range: base + m.start()..base + m.end(),
                    });
                }
                for c in LINK.captures_iter(content_text) {
                    let whole = c.get(0).unwrap();
                    let text = c.get(1).unwrap();
                    runs.push(Run {
                        kind: Kind::Marker,
                        range: base + whole.start()..base + whole.end(),
                    });
                    runs.push(Run {
                        kind: Kind::LinkText,
                        range: base + text.start()..base + text.end(),
                    });
                }
                delimited(content_text, base, "**", Kind::Bold, false, &mut runs);
                delimited(content_text, base, "__", Kind::Bold, false, &mut runs);
                delimited(content_text, base, "*", Kind::Italic, true, &mut runs);
                delimited(content_text, base, "_", Kind::Italic, true, &mut runs);
                delimited(
                    content_text,
                    base,
                    "~~",
                    Kind::Strikethrough,
                    false,
                    &mut runs,
                );
            }
            Line {
                range,
                inside_before: before,
                inside_after: inside,
                runs,
                indent,
            }
        })
        .collect()
}
fn delimited(text: &str, base: usize, marker: &str, kind: Kind, single: bool, runs: &mut Vec<Run>) {
    // Preclassify closing delimiters once. Invalid unmatched openers cannot
    // repeatedly scan the whole line (e.g. a pasted line full of markers).
    let positions: Vec<_> = text.match_indices(marker).map(|(i, _)| i).collect();
    let closings: Vec<_> = positions
        .iter()
        .copied()
        .filter(|&end| {
            let last = text[..end].chars().next_back();
            let next = text[end + marker.len()..].chars().next();
            last.is_some_and(|c| !c.is_whitespace() && (!single || !matches!(c, '*' | '_')))
                && (!single || next.is_none_or(|c| !matches!(c, '*' | '_')))
        })
        .collect();
    let mut consumed = 0;
    for start in positions {
        if start < consumed {
            continue;
        }
        let inner = start + marker.len();
        let prev = text[..start].chars().next_back();
        let first = text[inner..].chars().next();
        if first.is_none_or(|c| c.is_whitespace() || (single && matches!(c, '*' | '_')))
            || (single && prev.is_some_and(|c| matches!(c, '*' | '_')))
        {
            continue;
        }
        if let Some(&end) = closings.get(closings.partition_point(|&end| end <= inner)) {
            consumed = end + marker.len();
            runs.push(Run {
                kind,
                range: base + start..base + consumed,
            });
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn doc(text: &str) -> Document {
        let mut doc = Document::default();
        doc.update(text);
        doc
    }
    fn spans(text: &str, kind: Kind) -> Vec<&str> {
        doc(text)
            .runs
            .into_iter()
            .filter(|r| r.kind == kind)
            .map(|r| &text[r.range])
            .collect()
    }
    #[test]
    fn native_update_window_and_fenced_indentation_preserve_unicode_edges() {
        let mut doc = Document::default();
        let initial = "# hé👩🏽‍💻\n\n```\n- [x] fenced list\n> quote\n```\nlast\n";
        let result = doc.update(initial);
        assert!(result.full);
        assert_eq!(doc.restyled_range(), 0..initial.len());
        assert_eq!(doc.indents().len(), 2);
        assert_eq!(&initial[doc.indents()[0].prefix.clone()], "- [x] ");
        assert_eq!(&initial[doc.indents()[1].prefix.clone()], "> ");
        let modified = initial.replace("last", "café");
        let result = doc.update(&modified);
        assert!(!result.full);
        let range = doc.restyled_range();
        assert!(modified.is_char_boundary(range.start) && modified.is_char_boundary(range.end));
        assert!(modified[range].contains("café"));
        doc.update(&modified);
        assert!(doc.restyled_range().is_empty());
    }

    #[test]
    fn constructs_match_current_light_markdown() {
        let text =
            "# Title **raw**\n- [x] done ~~struck~~\n> *quote* [lien](url)\n1. `code`\n---\n";
        assert_eq!(spans(text, Kind::Heading(1)), vec!["Title **raw**"]);
        assert!(spans(text, Kind::Bold).is_empty()); // headings do not inline-parse
        assert_eq!(spans(text, Kind::TaskCheckbox(true)), vec!["[x]"]);
        assert_eq!(spans(text, Kind::CompletedTask), vec!["done ~~struck~~"]);
        assert_eq!(spans(text, Kind::Italic), vec!["*quote*"]);
        assert_eq!(spans(text, Kind::LinkText), vec!["lien"]);
        assert_eq!(spans(text, Kind::CodeSpan), vec!["`code`"]);
        assert_eq!(spans(text, Kind::HorizontalRule), vec!["---"]);
        let d = doc(text);
        assert_eq!(
            d.indents
                .iter()
                .map(|i| &text[i.prefix.clone()])
                .collect::<Vec<_>>(),
            vec!["- [x] ", "> ", "1. "]
        );
    }
    #[test]
    fn styled_terminal_source_keeps_preformatted_text_and_styles_in_live_document() {
        use crate::terminal_clipboard::{StyledClipboardRun, StyledClipboardSelection};

        let literal = "  if x < y && z > 0\n\t\"é\"";
        let selection = StyledClipboardSelection::new(
            literal.to_string(),
            vec![
                StyledClipboardRun {
                    text: "  if x < y && z > 0\n\t".into(),
                    bold: true,
                    foreground: Some([230, 80, 20]),
                    ..Default::default()
                },
                StyledClipboardRun {
                    text: "\"".into(),
                    ..Default::default()
                },
                StyledClipboardRun {
                    text: "é".into(),
                    italic: true,
                    underline: true,
                    background: Some([18, 52, 86]),
                    link: Some("https://example.test".into()),
                    ..Default::default()
                },
                StyledClipboardRun {
                    text: "\"".into(),
                    ..Default::default()
                },
            ],
        )
        .unwrap();
        let text = selection.markdown_source().unwrap();
        let block = crate::terminal_clipboard::parse_markdown_block(&text, 0).unwrap();
        assert_eq!(&text[block.body_range.clone()], literal);

        let mut document = doc(&text);
        let terminal_styles: Vec<_> = document
            .runs()
            .iter()
            .filter_map(|run| match run.kind {
                Kind::TerminalSpan { .. } => Some((run.kind, &text[run.range.clone()])),
                _ => None,
            })
            .collect();
        assert_eq!(terminal_styles.len(), 4);
        assert!(matches!(
            terminal_styles[0].0,
            Kind::TerminalSpan {
                bold: true,
                foreground: Some([230, 80, 20]),
                ..
            }
        ));
        assert_eq!(terminal_styles[0].1, "  if x < y && z > 0\n\t");
        assert!(matches!(
            terminal_styles[2].0,
            Kind::TerminalSpan {
                italic: true,
                underline: true,
                background: Some([18, 52, 86]),
                ..
            }
        ));
        assert_eq!(terminal_styles[2].1, "é");
        assert_eq!(spans(&text, Kind::TerminalLink), vec!["é"]);
        assert_eq!(document.hidden_terminal_ranges().len(), 2);
        assert!(
            document
                .hidden_terminal_ranges()
                .iter()
                .all(|range| text[range.clone()].starts_with('`'))
        );
        assert_eq!(document.terminal_links().len(), 1);
        assert_eq!(document.terminal_links()[0].1, "https://example.test");

        // A body edit invalidates its byte-offset metadata. Keep the literal
        // body as plain monospace code and hide only the still-valid wrappers.
        let changed = text.replace("z > 0", "z > 00");
        assert!(document.update(&changed).full);
        assert_eq!(document.hidden_terminal_ranges().len(), 2);
        assert!(
            document
                .hidden_terminal_ranges()
                .iter()
                .all(|range| changed[range.clone()].starts_with('`'))
        );
        assert!(
            !document
                .runs()
                .iter()
                .any(|run| matches!(run.kind, Kind::TerminalSpan { .. }))
        );
        assert!(document.runs().iter().any(|run| {
            matches!(run.kind, Kind::CodeFence) && changed[run.range.clone()].contains("z > 00")
        }));
        assert!(changed.contains("  if x < y && z > 00\n\t\"é\""));

        let block = crate::terminal_clipboard::parse_markdown_block(&text, 0).unwrap();
        let malformed = changed.replacen(&text[block.closing_range.clone()], "``", 1);
        document.update(&malformed);
        assert!(document.hidden_terminal_ranges().is_empty());
        assert!(malformed.contains(crate::terminal_clipboard::STYLED_SELECTION_FENCE_INFO));

        document.update(&text);
        assert_eq!(document.runs(), doc(&text).runs());
    }
    #[test]
    fn inline_delimiters_hug_content_and_do_not_italicize_bold() {
        let text = "**bold** __other__ *italic* _italique_ ** spaced ** * spaced * ~~gone~~";
        assert_eq!(spans(text, Kind::Bold), vec!["**bold**", "__other__"]);
        assert_eq!(spans(text, Kind::Italic), vec!["*italic*", "_italique_"]);
        assert_eq!(spans(text, Kind::Strikethrough), vec!["~~gone~~"]);
    }
    #[test]
    fn unicode_byte_ranges_preserve_full_text_and_paragraphs() {
        let text = "## 👩🏽‍💻 café\r\n- [X] 漢字 é\u{2028}> שלום\n```\n**raw**\n~~~\n";
        let d = doc(text);
        assert_eq!(d.text(), text);
        assert_eq!(spans(text, Kind::Heading(2)), vec!["👩🏽‍💻 café"]);
        assert_eq!(spans(text, Kind::CodeFence), vec!["```", "**raw**", "~~~"]);
        for r in d.runs() {
            assert!(text.is_char_boundary(r.range.start));
            assert!(text.is_char_boundary(r.range.end));
        }
    }
    #[test]
    fn ordinary_edit_restyles_neighbors_and_carries_fence_state() {
        let before = "a\nb\n```\nx\ny\nz\n```\nlast\n";
        let mut d = doc(before);
        let next = before.replace("y\n", "**y**\n");
        let update = d.update(&next);
        assert!(!update.full);
        assert_eq!(update.restyled_lines, 3);
        assert_eq!(d.runs(), doc(&next).runs());
        assert_eq!(spans(&next, Kind::Bold), Vec::<&str>::new());
        let deleted = next.replacen("```\nlast", "last", 1);
        assert!(d.update(&deleted).full);
        assert_eq!(d.runs(), doc(&deleted).runs());
    }
    #[test]
    fn incremental_edits_equal_full_parse_at_every_utf8_boundary() {
        let fixtures = [
            "",
            "# Café\n- [ ] task\nlast",
            "a\r\nb\r\nc",
            "```\nraw\n```\n**after**",
            "👩🏽‍💻\n> é\n",
            "one\ntwo\nthree\nfour\nfive\n",
        ];
        let edits = ["", "x", "\n", "é", "**", "```\n", "\r\n", "\u{2028}"];
        for before in fixtures {
            let boundaries: Vec<_> = before
                .char_indices()
                .map(|(i, _)| i)
                .chain(std::iter::once(before.len()))
                .collect();
            for &start in &boundaries {
                for &end in boundaries.iter().filter(|&&end| end >= start) {
                    for inserted in edits {
                        let mut next = before.to_string();
                        next.replace_range(start..end, inserted);
                        let mut actual = doc(before);
                        actual.update(&next);
                        let expected = doc(&next);
                        assert_eq!(
                            actual.runs(),
                            expected.runs(),
                            "before={before:?} edit={start}..{end} inserted={inserted:?}"
                        );
                        assert_eq!(actual.indents(), expected.indents());
                        assert_eq!(actual.text(), next);
                    }
                }
            }
        }
    }
    #[test]
    fn bounded_restyling_and_unmatched_marker_line() {
        let text = (0..1000).map(|i| format!("line {i}\n")).collect::<String>();
        let mut d = doc(&text);
        let next = text.replace("line 500\n", "line **500**\n");
        let update = d.update(&next);
        assert!(!update.full);
        assert_eq!(update.restyled_lines, 3);
        assert_eq!(d.runs(), doc(&next).runs());
        let markers = "**x ".repeat(20_000);
        assert!(spans(&markers, Kind::Bold).is_empty());
    }
}
