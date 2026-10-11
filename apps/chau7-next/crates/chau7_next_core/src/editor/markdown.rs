//! Markdown runbooks (`SplitPanes/MarkdownRunbookView.swift`): the
//! lightweight block parser (headings, text, fenced code blocks) and the
//! inline markdown of text blocks (SwiftUI renders `**bold**`, `*italic*`,
//! `` `code` ``, `~~strike~~` and `[links](url)` in a `LocalizedStringKey`).

/// `MarkdownSectionKind`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum MarkdownSection {
    /// Level 1 to 4 (deeper headings show as level 4).
    Heading {
        level: usize,
        text: String,
    },
    Text(String),
    CodeBlock {
        language: Option<String>,
        code: String,
    },
}

/// `parseMarkdown`: not CommonMark, the cases runbooks use.
pub fn parse_markdown(input: &str) -> Vec<MarkdownSection> {
    let lines: Vec<&str> = input.split('\n').collect();
    let mut sections = Vec::new();
    let mut text = String::new();
    let flush = |text: &mut String, sections: &mut Vec<MarkdownSection>| {
        let trimmed = text.trim();
        if !trimmed.is_empty() {
            sections.push(MarkdownSection::Text(trimmed.to_string()));
        }
        text.clear();
    };
    let mut i = 0;
    while i < lines.len() {
        let line = lines[i];
        if let Some(lang) = line.strip_prefix("```") {
            flush(&mut text, &mut sections);
            let lang = lang.trim();
            let mut code = Vec::new();
            i += 1;
            while i < lines.len() && !lines[i].starts_with("```") {
                code.push(lines[i]);
                i += 1;
            }
            let code = code.join("\n").trim().to_string();
            if !code.is_empty() {
                sections.push(MarkdownSection::CodeBlock {
                    language: (!lang.is_empty()).then(|| lang.to_string()),
                    code,
                });
            }
            if i < lines.len() {
                i += 1; // closing fence (an unclosed block runs to the end)
            }
            continue;
        }
        if line.starts_with('#') {
            flush(&mut text, &mut sections);
            let level = line.chars().take_while(|c| *c == '#').count();
            sections.push(MarkdownSection::Heading {
                level: level.min(4),
                text: line[level..].trim().to_string(),
            });
            i += 1;
            continue;
        }
        text.push_str(line);
        text.push('\n');
        i += 1;
    }
    flush(&mut text, &mut sections);
    sections
}

/// The code of every block, in order (Run All).
pub fn code_blocks(input: &str) -> Vec<String> {
    parse_markdown(input)
        .into_iter()
        .filter_map(|s| match s {
            MarkdownSection::CodeBlock { code, .. } => Some(code),
            _ => None,
        })
        .collect()
}

/// A run of inline text with its style.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct InlineRun {
    pub text: String,
    pub bold: bool,
    pub italic: bool,
    pub code: bool,
    pub strike: bool,
    pub link: Option<String>,
}

/// Turns a style flag on.
type Apply = fn(&mut Style);

#[derive(Clone, Copy, Default)]
struct Style {
    bold: bool,
    italic: bool,
    strike: bool,
}

/// Inline markdown of a text block. Unmatched markers stay as text.
pub fn parse_inline(text: &str) -> Vec<InlineRun> {
    let mut out = Vec::new();
    inline_into(text, Style::default(), None, &mut out);
    // Merge neighbours with the same style.
    let mut merged: Vec<InlineRun> = Vec::new();
    for run in out {
        if let Some(last) = merged.last_mut()
            && (last.bold, last.italic, last.code, last.strike, &last.link)
                == (run.bold, run.italic, run.code, run.strike, &run.link)
        {
            last.text.push_str(&run.text);
            continue;
        }
        if !run.text.is_empty() {
            merged.push(run);
        }
    }
    merged
}

fn push(out: &mut Vec<InlineRun>, text: &str, style: Style, code: bool, link: Option<&str>) {
    out.push(InlineRun {
        text: text.to_string(),
        bold: style.bold,
        italic: style.italic,
        code,
        strike: style.strike,
        link: link.map(str::to_string),
    });
}

fn inline_into(text: &str, style: Style, link: Option<&str>, out: &mut Vec<InlineRun>) {
    let mut plain_start = 0;
    let mut i = 0;
    while i < text.len() {
        let rest = &text[i..];
        // Code span.
        if rest.starts_with('`')
            && let Some(end) = rest[1..].find('`')
            && end > 0
        {
            push(out, &text[plain_start..i], style, false, link);
            push(out, &rest[1..1 + end], style, true, link);
            i += end + 2;
            plain_start = i;
            continue;
        }
        // Link.
        if rest.starts_with('[')
            && link.is_none()
            && let Some(close) = rest.find("](")
            && let Some(end) = rest[close + 2..].find(')')
        {
            let label = &rest[1..close];
            let url = &rest[close + 2..close + 2 + end];
            if !label.is_empty() && !url.contains(char::is_whitespace) {
                push(out, &text[plain_start..i], style, false, link);
                inline_into(label, style, Some(url), out);
                i += close + 3 + end;
                plain_start = i;
                continue;
            }
        }
        // Emphasis: ** / __ bold, ~~ strike, * / _ italic.
        let markers: [(&str, Apply); 5] = [
            ("**", |s| s.bold = true),
            ("__", |s| s.bold = true),
            ("~~", |s| s.strike = true),
            ("*", |s| s.italic = true),
            ("_", |s| s.italic = true),
        ];
        let mut matched = false;
        for (marker, apply) in markers {
            if !rest.starts_with(marker) {
                continue;
            }
            let inner_start = marker.len();
            // The content must not start with a space, and `_` only opens
            // at a word start.
            if rest[inner_start..].starts_with(char::is_whitespace)
                || (marker.starts_with('_')
                    && text[..i].chars().last().is_some_and(char::is_alphanumeric))
            {
                continue;
            }
            if let Some(end) = rest[inner_start..].find(marker)
                && end > 0
                && !rest[inner_start..inner_start + end].ends_with(char::is_whitespace)
            {
                push(out, &text[plain_start..i], style, false, link);
                let mut inner = style;
                apply(&mut inner);
                inline_into(&rest[inner_start..inner_start + end], inner, link, out);
                i += inner_start + end + marker.len();
                plain_start = i;
                matched = true;
                break;
            }
        }
        if matched {
            continue;
        }
        i += rest.chars().next().map_or(1, char::len_utf8);
    }
    push(out, &text[plain_start..], style, false, link);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_headings_text_and_blocks() {
        let md = "# Deploy\n\nRun the **build** first.\n\n```bash\nmake build\n```\n\n#### Deep\n##### Deeper\n```\n\n```\ntail";
        let s = parse_markdown(md);
        assert_eq!(
            s,
            vec![
                MarkdownSection::Heading {
                    level: 1,
                    text: "Deploy".into()
                },
                MarkdownSection::Text("Run the **build** first.".into()),
                MarkdownSection::CodeBlock {
                    language: Some("bash".into()),
                    code: "make build".into()
                },
                MarkdownSection::Heading {
                    level: 4,
                    text: "Deep".into()
                },
                MarkdownSection::Heading {
                    level: 4,
                    text: "Deeper".into()
                },
                MarkdownSection::Text("tail".into()),
            ]
        );
    }

    #[test]
    fn unclosed_block_runs_to_the_end() {
        assert_eq!(code_blocks("```sh\necho a\necho b"), vec!["echo a\necho b"]);
        assert_eq!(
            code_blocks("```\na\n```\ntext\n```\nb\n```"),
            vec!["a", "b"]
        );
    }

    #[test]
    fn inline_styles() {
        let runs = parse_inline("Use **bold**, *it*, `code` and [docs](https://x.y) ~~old~~");
        let find = |t: &str| runs.iter().find(|r| r.text == t).unwrap().clone();
        assert!(find("bold").bold);
        assert!(find("it").italic);
        assert!(find("code").code);
        assert_eq!(find("docs").link.as_deref(), Some("https://x.y"));
        assert!(find("old").strike);
        assert_eq!(runs[0].text, "Use ");
    }

    #[test]
    fn unmatched_markers_stay() {
        let runs = parse_inline("a * b and snake_case_name");
        assert_eq!(runs.len(), 1);
        assert_eq!(runs[0].text, "a * b and snake_case_name");
        let runs = parse_inline("**bold *both* x**");
        assert!(runs.iter().any(|r| r.bold && r.italic && r.text == "both"));
    }
}
