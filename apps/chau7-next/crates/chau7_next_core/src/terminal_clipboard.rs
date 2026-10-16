//! Clipboard selection policy shared by terminal copy and Markdown paste.
use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
use serde::{Deserialize, Serialize};
use std::{io, ops::Range};

pub const STYLED_SELECTION_VERSION: u8 = 1;
pub const STYLED_SELECTION_FENCE_INFO: &str = "chau7-terminal-v1:";
const MAX_STYLED_SELECTION_BYTES: usize = 8 * 1024 * 1024;
const MAX_STYLED_SELECTION_RUNS: usize = 100_000;
const MAX_STYLED_SELECTION_LINK_BYTES: usize = 8 * 1024;

/// Versioned, private pasteboard representation for terminal selection styles.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct StyledClipboardSelection {
    pub version: u8,
    pub plain_text: String,
    pub runs: Vec<StyledClipboardRun>,
}

/// Attributes for one consecutive terminal selection run.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct StyledClipboardRun {
    pub text: String,
    pub bold: bool,
    pub italic: bool,
    pub underline: bool,
    pub strikethrough: bool,
    pub foreground: Option<[u8; 3]>,
    pub background: Option<[u8; 3]>,
    pub link: Option<String>,
}

/// Style ranges stored in a special Markdown fence. The body stays literal
/// terminal text, so markup characters, whitespace, and Unicode stay visible.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct StyledClipboardSpan {
    pub start: usize,
    pub end: usize,
    pub bold: bool,
    pub italic: bool,
    pub underline: bool,
    pub strikethrough: bool,
    pub foreground: Option<[u8; 3]>,
    pub background: Option<[u8; 3]>,
    pub link: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct StyledClipboardMetadata {
    version: u8,
    plain_bytes: usize,
    spans: Vec<StyledClipboardSpan>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ParsedStyledTerminalBlock {
    pub opening_range: Range<usize>,
    pub body_range: Range<usize>,
    pub closing_range: Range<usize>,
    pub spans: Vec<StyledClipboardSpan>,
}

/// Source bounds for any reserved terminal fence, including one with invalid
/// style metadata. Preview parsers can show its body as plain terminal text
/// without treating it as an executable code block.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ParsedTerminalSourceFence {
    pub opening_range: Range<usize>,
    pub body_range: Range<usize>,
    pub closing_range: Range<usize>,
}

impl StyledClipboardSelection {
    pub fn new(plain_text: String, runs: Vec<StyledClipboardRun>) -> Option<Self> {
        let selection = Self {
            version: STYLED_SELECTION_VERSION,
            plain_text,
            runs,
        };
        selection.is_valid().then_some(selection)
    }

    /// Decode only the bounded, versioned payload written by this app.
    pub fn decode_json(json: &str) -> Option<Self> {
        if json.len() > MAX_STYLED_SELECTION_BYTES {
            return None;
        }
        let selection: Self = serde_json::from_str(json).ok()?;
        selection.is_valid().then_some(selection)
    }

    pub fn encode_json(&self) -> Option<String> {
        if !self.is_valid() {
            return None;
        }
        let mut bytes = Vec::new();
        serde_json::to_writer(&mut BoundedJsonWriter(&mut bytes), self).ok()?;
        String::from_utf8(bytes).ok()
    }

    pub fn is_valid(&self) -> bool {
        if self.version != STYLED_SELECTION_VERSION
            || self.plain_text.len() > MAX_STYLED_SELECTION_BYTES
            || self.runs.len() > MAX_STYLED_SELECTION_RUNS
        {
            return false;
        }
        let mut joined = String::with_capacity(self.plain_text.len());
        for run in &self.runs {
            if run.text.is_empty()
                || run.link.as_ref().is_some_and(|link| {
                    link.len() > MAX_STYLED_SELECTION_LINK_BYTES || !is_safe_link(link)
                })
            {
                return false;
            }
            joined.push_str(&run.text);
            if joined.len() > self.plain_text.len() {
                return false;
            }
        }
        joined == self.plain_text
    }

    /// Markdown source with literal terminal text and bounded style offsets.
    pub fn markdown_source(&self) -> Option<String> {
        if !self.is_valid() {
            return None;
        }
        // Link destinations are cloned into the metadata span vector below.
        // Bound their aggregate first so many individually valid links cannot
        // allocate an oversized intermediate before the bounded JSON writer.
        let mut link_bytes = 0usize;
        for run in &self.runs {
            if let Some(link) = &run.link {
                link_bytes = link_bytes.checked_add(link.len())?;
                if link_bytes > MAX_STYLED_SELECTION_BYTES {
                    return None;
                }
            }
        }
        let metadata = StyledClipboardMetadata {
            version: STYLED_SELECTION_VERSION,
            plain_bytes: self.plain_text.len(),
            spans: self
                .runs
                .iter()
                .scan(0usize, |start, run| {
                    let end = (*start).saturating_add(run.text.len());
                    let span = StyledClipboardSpan {
                        start: *start,
                        end,
                        bold: run.bold,
                        italic: run.italic,
                        underline: run.underline,
                        strikethrough: run.strikethrough,
                        foreground: run.foreground,
                        background: run.background,
                        link: run.link.clone(),
                    };
                    *start = end;
                    Some(span)
                })
                .collect(),
        };
        let mut json = Vec::new();
        serde_json::to_writer(&mut BoundedJsonWriter(&mut json), &metadata).ok()?;
        let encoded = URL_SAFE_NO_PAD.encode(json);
        let fence_len = longest_backtick_run(&self.plain_text)
            .saturating_add(1)
            .max(3);
        let fence = "`".repeat(fence_len);
        if encoded.len() > MAX_STYLED_SELECTION_BYTES {
            return None;
        }
        let mut source =
            String::with_capacity(self.plain_text.len() + encoded.len() + fence_len * 2 + 48);
        source.push_str(&fence);
        source.push_str(STYLED_SELECTION_FENCE_INFO);
        source.push_str(&encoded);
        source.push('\n');
        source.push_str(&self.plain_text);
        source.push('\n'); // required separator before the closing Markdown fence
        source.push_str(&fence);
        Some(source)
    }

    /// Standard HTML flavor for apps that accept rich paste.
    pub fn html_fragment(&self) -> String {
        let mut html = String::with_capacity(self.plain_text.len() + 128);
        html.push_str("<pre style=\"white-space:pre; font-family:monospace\">");
        if self.is_valid() {
            for run in &self.runs {
                push_html_run(&mut html, run);
            }
        } else {
            escape_html_text(&mut html, &self.plain_text);
        }
        html.push_str("</pre>");
        html
    }
}

fn longest_backtick_run(text: &str) -> usize {
    let mut current = 0;
    let mut longest = 0;
    for character in text.chars() {
        if character == '`' {
            current += 1;
            longest = longest.max(current);
        } else {
            current = 0;
        }
    }
    longest
}

/// Add the line boundaries needed to insert a fenced block at any UTF-8
/// selection in a Markdown document. The caller replaces `selection` with
/// this value in one native edit, so undo remains a single operation.
pub fn place_markdown_block(
    document: &str,
    selection: Range<usize>,
    block: &str,
) -> Option<String> {
    if selection.start > selection.end
        || selection.end > document.len()
        || !document.is_char_boundary(selection.start)
        || !document.is_char_boundary(selection.end)
    {
        return None;
    }
    let mut insertion = String::with_capacity(block.len() + 2);
    if selection.start > 0 {
        match document[..selection.start].chars().next_back() {
            // Turn an existing standalone CR into CRLF without rewriting the
            // surrounding document; Markdown's parser needs the LF boundary.
            Some('\r') => insertion.push('\n'),
            Some(c) if is_markdown_line_break(c) => {}
            _ => insertion.push('\n'),
        }
    }
    insertion.push_str(block);
    if selection.end < document.len() {
        match document[selection.end..].chars().next() {
            // A following CRLF already terminates the fence. A standalone CR
            // needs an LF before it so the closing fence is still parseable.
            Some('\r') if !document[selection.end..].starts_with("\r\n") => insertion.push('\n'),
            Some(c) if is_markdown_line_break(c) => {}
            _ => insertion.push('\n'),
        }
    }
    Some(insertion)
}

fn is_markdown_line_break(c: char) -> bool {
    matches!(c, '\n' | '\r')
}

/// Locate and validate a styled source-level terminal selection fence.
/// Invalid metadata returns `None`; callers can still recognize the reserved
/// fence structurally and render its body as plain, non-executable terminal text.
pub fn parse_markdown_block(text: &str, start: usize) -> Option<ParsedStyledTerminalBlock> {
    if !text.is_char_boundary(start) || (start != 0 && !text[..start].ends_with('\n')) {
        return None;
    }
    let opening_line_end = text[start..].find('\n').map(|i| start + i)?;
    let opening_line = text[start..opening_line_end]
        .strip_suffix('\r')
        .unwrap_or(&text[start..opening_line_end]);
    let (fence, encoded) = parse_fence_info(opening_line)?;
    if encoded.len() > MAX_STYLED_SELECTION_BYTES {
        return None;
    }
    let metadata_bytes = URL_SAFE_NO_PAD.decode(encoded).ok()?;
    if metadata_bytes.len() > MAX_STYLED_SELECTION_BYTES {
        return None;
    }
    let metadata: StyledClipboardMetadata = serde_json::from_slice(&metadata_bytes).ok()?;
    if metadata.version != STYLED_SELECTION_VERSION
        || metadata.plain_bytes > MAX_STYLED_SELECTION_BYTES
        || metadata.spans.len() > MAX_STYLED_SELECTION_RUNS
    {
        return None;
    }
    let body_start = opening_line_end + 1;
    let mut cursor = body_start;
    let close_start = loop {
        if cursor > text.len() {
            return None;
        }
        let line_end = text[cursor..].find('\n').map_or(text.len(), |i| cursor + i);
        let line = text[cursor..line_end]
            .strip_suffix('\r')
            .unwrap_or(&text[cursor..line_end]);
        if line == fence {
            break cursor;
        }
        if line_end == text.len() {
            return None;
        }
        cursor = line_end + 1;
    };
    // markdown_source appends one newline to put the closing fence on its own
    // line. Remove exactly that separator; the stored byte count validates it.
    if close_start <= body_start || !text[..close_start].ends_with('\n') {
        return None;
    }
    let body_end = close_start.checked_sub(1)?;
    if body_end < body_start {
        return None;
    }
    let body = &text[body_start..body_end];
    if body.len() != metadata.plain_bytes {
        return None;
    }
    let mut expected_start = 0;
    for span in &metadata.spans {
        if span.start != expected_start
            || span.end <= span.start
            || span.end > body.len()
            || !body.is_char_boundary(span.start)
            || !body.is_char_boundary(span.end)
            || span.link.as_ref().is_some_and(|link| {
                link.len() > MAX_STYLED_SELECTION_LINK_BYTES || !is_safe_link(link)
            })
        {
            return None;
        }
        expected_start = span.end;
    }
    if expected_start != body.len() {
        return None;
    }
    let close_line_end = text[close_start..]
        .find('\n')
        .map_or(text.len(), |i| close_start + i);
    Some(ParsedStyledTerminalBlock {
        opening_range: start..opening_line_end,
        body_range: body_start..body_end,
        closing_range: close_start..close_line_end,
        spans: metadata.spans,
    })
}

/// Parse the shape of a reserved terminal fence without trusting its style
/// metadata. Preview can keep its body as plain terminal text, and live source
/// rendering can hide wrapper lines only when a matching close fence exists.
pub fn parse_reserved_terminal_fence(
    text: &str,
    start: usize,
) -> Option<ParsedTerminalSourceFence> {
    if !text.is_char_boundary(start) || (start != 0 && !text[..start].ends_with('\n')) {
        return None;
    }
    let opening_line_end = text[start..].find('\n').map(|i| start + i)?;
    let opening_line = text[start..opening_line_end]
        .strip_suffix('\r')
        .unwrap_or(&text[start..opening_line_end]);
    let fence_len = opening_line
        .bytes()
        .take_while(|byte| *byte == b'`')
        .count();
    if fence_len < 3 || !opening_line[fence_len..].starts_with(STYLED_SELECTION_FENCE_INFO) {
        return None;
    }
    let fence = &opening_line[..fence_len];
    let body_start = opening_line_end + 1;
    let mut cursor = body_start;
    let mut found_close = false;
    let close_start = loop {
        if cursor >= text.len() {
            break text.len();
        }
        let line_end = text[cursor..].find('\n').map_or(text.len(), |i| cursor + i);
        let line = text[cursor..line_end]
            .strip_suffix('\r')
            .unwrap_or(&text[cursor..line_end]);
        if line == fence {
            found_close = true;
            break cursor;
        }
        if line_end == text.len() {
            break text.len();
        }
        cursor = line_end + 1;
    };
    let body_end = if found_close && close_start > body_start && text[..close_start].ends_with('\n')
    {
        close_start - 1
    } else {
        close_start
    };
    let closing_end = if close_start == text.len() {
        text.len()
    } else {
        text[close_start..]
            .find('\n')
            .map_or(text.len(), |i| close_start + i)
    };
    Some(ParsedTerminalSourceFence {
        opening_range: start..opening_line_end,
        body_range: body_start..body_end,
        closing_range: close_start..closing_end,
    })
}

fn parse_fence_info(line: &str) -> Option<(&str, &str)> {
    let fence_len = line.bytes().take_while(|byte| *byte == b'`').count();
    if fence_len < 3 {
        return None;
    }
    let fence = &line[..fence_len];
    let info = line[fence_len..].strip_prefix(STYLED_SELECTION_FENCE_INFO)?;
    (!info.is_empty() && !info.bytes().any(|byte| byte.is_ascii_whitespace()))
        .then_some((fence, info))
}

struct BoundedJsonWriter<'a>(&'a mut Vec<u8>);

impl io::Write for BoundedJsonWriter<'_> {
    fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
        if self.0.len().saturating_add(bytes.len()) > MAX_STYLED_SELECTION_BYTES {
            return Err(io::Error::new(
                io::ErrorKind::WriteZero,
                "styled clipboard payload exceeds its size limit",
            ));
        }
        self.0.extend_from_slice(bytes);
        Ok(bytes.len())
    }

    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

fn push_html_run(out: &mut String, run: &StyledClipboardRun) {
    // Keep line breaks outside spans so the live editor can restyle every row
    // independently while <pre> retains blank lines and terminal columns.
    let mut part_start = 0;
    let mut chars = run.text.char_indices().peekable();
    while let Some((index, character)) = chars.next() {
        if character != '\n' && character != '\r' {
            continue;
        }
        push_html_segment(out, run, &run.text[part_start..index]);
        out.push(character);
        if character == '\r' && chars.peek().is_some_and(|(_, next)| *next == '\n') {
            let (next_index, next) = chars.next().unwrap();
            out.push(next);
            part_start = next_index + next.len_utf8();
        } else {
            part_start = index + character.len_utf8();
        }
    }
    push_html_segment(out, run, &run.text[part_start..]);
}

fn push_html_segment(out: &mut String, run: &StyledClipboardRun, text: &str) {
    if text.is_empty() {
        return;
    }
    out.push_str("<span style=\"font-family:monospace");
    if run.bold {
        out.push_str(";font-weight:bold");
    }
    if run.italic {
        out.push_str(";font-style:italic");
    }
    if run.underline || run.strikethrough {
        out.push_str(";text-decoration:");
        if run.underline {
            out.push_str("underline");
        }
        if run.underline && run.strikethrough {
            out.push(' ');
        }
        if run.strikethrough {
            out.push_str("line-through");
        }
    }
    if let Some(color) = run.foreground {
        out.push_str(";color:#");
        push_hex_color(out, color);
    }
    if let Some(color) = run.background {
        out.push_str(";background-color:#");
        push_hex_color(out, color);
    }
    out.push_str("\">");
    if run.link.as_deref().is_some_and(is_safe_link) {
        out.push_str("<a href=\"");
        escape_html_attribute(out, run.link.as_deref().unwrap_or_default());
        out.push_str("\">");
    }
    escape_html_text(out, text);
    if run.link.as_deref().is_some_and(is_safe_link) {
        out.push_str("</a>");
    }
    out.push_str("</span>");
}

fn push_hex_color(out: &mut String, [red, green, blue]: [u8; 3]) {
    use std::fmt::Write;
    let _ = write!(out, "{red:02x}{green:02x}{blue:02x}");
}

fn escape_html_text(out: &mut String, text: &str) {
    for character in text.chars() {
        match character {
            '&' => out.push_str("&amp;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            _ => out.push(character),
        }
    }
}

fn escape_html_attribute(out: &mut String, text: &str) {
    for character in text.chars() {
        match character {
            '&' => out.push_str("&amp;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            '"' => out.push_str("&quot;"),
            '\'' => out.push_str("&#39;"),
            c if c.is_control() => out.push_str("%20"),
            _ => out.push(character),
        }
    }
}

/// Hyperlinks from terminal OSC 8 are data; only conventional URL schemes are clickable.
pub fn is_safe_link(link: &str) -> bool {
    if link.chars().any(char::is_control) || link.chars().any(char::is_whitespace) {
        return false;
    }
    let Some((scheme, rest)) = link.split_once(':') else {
        return false;
    };
    !rest.is_empty()
        && matches!(
            scheme.to_ascii_lowercase().as_str(),
            "http" | "https" | "mailto" | "file"
        )
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
    fn styled_source_roundtrips_text_and_terminal_attributes() {
        let plain_text = "  *literal* <tag> &\n\tlinked".to_string();
        let selection = StyledClipboardSelection::new(
            plain_text.clone(),
            vec![
                StyledClipboardRun {
                    text: "  *literal* <tag> &\n".into(),
                    bold: true,
                    foreground: Some([230, 80, 20]),
                    ..Default::default()
                },
                StyledClipboardRun {
                    text: "\tlinked".into(),
                    underline: true,
                    link: Some("https://example.test/path?a=1&b=2".into()),
                    ..Default::default()
                },
            ],
        )
        .unwrap();
        let source = selection.markdown_source().unwrap();
        let sections = crate::editor::markdown::parse_markdown(&source);
        let [crate::editor::markdown::MarkdownSection::TerminalSelection(runs)] =
            sections.as_slice()
        else {
            panic!("terminal source should parse as one styled selection")
        };
        assert_eq!(
            runs.iter().map(|run| run.text.as_str()).collect::<String>(),
            plain_text
        );
        assert!(runs.iter().any(|run| {
            run.text == "  *literal* <tag> &\n"
                && run.bold
                && run.monospace
                && run.foreground == Some([230, 80, 20])
        }));
        assert!(runs.iter().any(|run| {
            run.text == "\tlinked"
                && run.underline
                && run.monospace
                && run.link.as_deref() == Some("https://example.test/path?a=1&b=2")
        }));
    }

    #[test]
    fn private_payload_is_bounded_and_rejects_unsupported_links() {
        let unsafe_link = StyledClipboardSelection::new(
            "x".into(),
            vec![StyledClipboardRun {
                text: "x".into(),
                link: Some("javascript:alert(1)".into()),
                ..Default::default()
            }],
        );
        assert!(unsafe_link.is_none());

        let prefix = "https://example.test/";
        let large_link = format!(
            "{prefix}{}",
            "a".repeat(MAX_STYLED_SELECTION_LINK_BYTES - prefix.len())
        );
        assert_eq!(large_link.len(), MAX_STYLED_SELECTION_LINK_BYTES);
        let runs = (0..1_100)
            .map(|_| StyledClipboardRun {
                text: "x".into(),
                link: Some(large_link.clone()),
                ..Default::default()
            })
            .collect();
        let selection = StyledClipboardSelection::new("x".repeat(1_100), runs).unwrap();
        assert!(selection.encode_json().is_none());
        assert!(selection.markdown_source().is_none());
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
    fn standalone_markdown_block_paste_handles_inline_and_multiline_selections() {
        let block = StyledClipboardSelection::new(
            "body".into(),
            vec![StyledClipboardRun {
                text: "body".into(),
                ..Default::default()
            }],
        )
        .unwrap()
        .markdown_source()
        .unwrap();
        let inline = "Notes: selected text after";
        let insertion = place_markdown_block(inline, 7..21, &block).unwrap();
        assert_eq!(insertion, format!("\n{block}\n"));
        let composed = format!("{}{}{}", &inline[..7], insertion, &inline[21..]);
        let opening = composed.find("```chau7-terminal-v1:").unwrap();
        let parsed = parse_markdown_block(&composed, opening).unwrap();
        assert_eq!(&composed[parsed.body_range], "body");

        let end_of_line = "Notes:\nnext";
        assert_eq!(
            place_markdown_block(end_of_line, 6..6, &block).unwrap(),
            format!("\n{block}")
        );
        let next_line_start = "Notes:\n".len();
        assert_eq!(
            place_markdown_block(end_of_line, next_line_start..next_line_start, &block).unwrap(),
            format!("{block}\n")
        );
        assert_eq!(
            place_markdown_block("prefix", 6..6, &block).unwrap(),
            format!("\n{block}")
        );
        assert_eq!(place_markdown_block("", 0..0, &block).unwrap(), block);
        assert!(place_markdown_block("é", 1..1, &block).is_none());
        let before_standalone_cr = "prefix\rnext";
        let cr_cursor = "prefix\r".len();
        let insertion =
            place_markdown_block(before_standalone_cr, cr_cursor..cr_cursor, &block).unwrap();
        let composed = format!(
            "{}{}{}",
            &before_standalone_cr[..cr_cursor],
            insertion,
            &before_standalone_cr[cr_cursor..]
        );
        assert!(composed.starts_with("prefix\r\n"));
        let opening = composed.find(STYLED_SELECTION_FENCE_INFO).unwrap();
        let fence_start = composed[..opening].rfind('\n').map_or(0, |index| index + 1);
        assert_eq!(
            &composed[parse_markdown_block(&composed, fence_start)
                .unwrap()
                .body_range],
            "body"
        );

        let before_following_cr = "prefix\rnext";
        let cr_cursor = "prefix".len();
        let insertion =
            place_markdown_block(before_following_cr, cr_cursor..cr_cursor, &block).unwrap();
        let composed = format!(
            "{}{}{}",
            &before_following_cr[..cr_cursor],
            insertion,
            &before_following_cr[cr_cursor..]
        );
        let opening = composed.find(STYLED_SELECTION_FENCE_INFO).unwrap();
        let fence_start = composed[..opening].rfind('\n').map_or(0, |index| index + 1);
        assert_eq!(
            &composed[parse_markdown_block(&composed, fence_start)
                .unwrap()
                .body_range],
            "body"
        );

        assert_eq!(
            place_markdown_block("Notes:\n", 6..6, &block).unwrap(),
            format!("\n{block}")
        );
        assert_eq!(
            place_markdown_block("Notes:\n\nnext", 7..7, &block).unwrap(),
            block
        );

        let multiline = "before selected\ncontent after";
        let selection = "selected\ncontent";
        let selection_start = multiline.find(selection).unwrap();
        let range = selection_start..selection_start + selection.len();
        let insertion = place_markdown_block(multiline, range.clone(), &block).unwrap();
        assert_eq!(insertion, format!("\n{block}\n"));
        assert_eq!(
            format!(
                "{}{}{}",
                &multiline[..range.start],
                insertion,
                &multiline[range.end..]
            ),
            format!("before \n{block}\n after")
        );
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
