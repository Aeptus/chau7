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
    Checkbox {
        checked: bool,
        text: String,
        line: usize,
    },
    Bullet(String),
    Numbered {
        number: usize,
        text: String,
    },
    Rule,
    CodeBlock {
        language: Option<String>,
        code: String,
    },
    /// A terminal selection stored as literal text inside a special fenced
    /// block. Invalid style metadata falls back to a plain monospace run.
    TerminalSelection(Vec<InlineRun>),
}

/// `parseMarkdown`: not CommonMark, the cases runbooks use.
pub fn parse_markdown(input: &str) -> Vec<MarkdownSection> {
    let lines: Vec<&str> = input.split('\n').collect();
    let mut line_offsets = Vec::with_capacity(lines.len());
    let mut offset = 0;
    for line in &lines {
        line_offsets.push(offset);
        offset += line.len() + 1;
    }
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
        if let Some(block) = crate::terminal_clipboard::parse_markdown_block(input, line_offsets[i])
        {
            flush(&mut text, &mut sections);
            let body = &input[block.body_range.clone()];
            let runs = block
                .spans
                .iter()
                .map(|span| InlineRun {
                    text: body[span.start..span.end].to_string(),
                    bold: span.bold,
                    italic: span.italic,
                    code: false,
                    strike: span.strikethrough,
                    underline: span.underline,
                    foreground: span.foreground,
                    background: span.background,
                    monospace: true,
                    link: span.link.clone(),
                })
                .collect();
            sections.push(MarkdownSection::TerminalSelection(runs));
            i = line_offsets
                .partition_point(|line_offset| *line_offset <= block.closing_range.start);
            continue;
        }
        if let Some(block) =
            crate::terminal_clipboard::parse_reserved_terminal_fence(input, line_offsets[i])
        {
            flush(&mut text, &mut sections);
            let body = &input[block.body_range];
            let runs = if body.is_empty() {
                Vec::new()
            } else {
                vec![InlineRun {
                    text: body.to_string(),
                    monospace: true,
                    ..Default::default()
                }]
            };
            sections.push(MarkdownSection::TerminalSelection(runs));
            i = line_offsets
                .partition_point(|line_offset| *line_offset <= block.closing_range.start);
            continue;
        }
        if let Some((fence_char, fence_len, lang)) = parse_fence_open(line) {
            flush(&mut text, &mut sections);
            let lang = lang.trim();
            let mut code = Vec::new();
            i += 1;
            while i < lines.len() && !is_fence_close(lines[i], fence_char, fence_len) {
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
        let trimmed = line.trim();
        let special = if trimmed.len() >= 3 && trimmed.chars().all(|c| c == '-') {
            Some(MarkdownSection::Rule)
        } else if let Some((checked, label)) = checkbox_line(line) {
            Some(MarkdownSection::Checkbox {
                checked,
                text: label.to_string(),
                line: i,
            })
        } else if let Some(label) = trimmed
            .strip_prefix('-')
            .or_else(|| trimmed.strip_prefix('*'))
        {
            let label = label.trim();
            (!label.is_empty() && !label.starts_with('['))
                .then(|| MarkdownSection::Bullet(label.to_string()))
        } else if let Some((number, label)) = trimmed.split_once(". ") {
            number
                .parse::<usize>()
                .ok()
                .filter(|_| !label.trim().is_empty())
                .map(|number| MarkdownSection::Numbered {
                    number,
                    text: label.trim().to_string(),
                })
        } else {
            None
        };
        if let Some(section) = special {
            flush(&mut text, &mut sections);
            sections.push(section);
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

fn parse_fence_open(line: &str) -> Option<(char, usize, &str)> {
    let character = line.chars().next()?;
    if !matches!(character, '`' | '~') {
        return None;
    }
    let length = line.chars().take_while(|item| *item == character).count();
    (length >= 3).then_some((character, length, &line[length..]))
}

fn is_fence_close(line: &str, character: char, length: usize) -> bool {
    let count = line.chars().take_while(|item| *item == character).count();
    count >= length && line[count..].trim().is_empty()
}

fn checkbox_line(line: &str) -> Option<(bool, &str)> {
    let line = line.trim_start();
    let rest = line
        .strip_prefix("- [")
        .or_else(|| line.strip_prefix("* ["))?;
    let (marker, label) = rest.split_once("] ")?;
    let checked = match marker {
        " " => false,
        "x" | "X" => true,
        _ => return None,
    };
    let label = label.trim();
    (!label.is_empty()).then_some((checked, label))
}

/// Checked and total tasks; fenced sample checkboxes do not count.
pub fn plan_progress(input: &str) -> (usize, usize) {
    parse_markdown(input)
        .into_iter()
        .fold((0, 0), |(checked, total), section| match section {
            MarkdownSection::Checkbox { checked: value, .. } => {
                (checked + usize::from(value), total + 1)
            }
            _ => (checked, total),
        })
}

pub fn toggle_checkbox(input: &str, line: usize) -> Option<String> {
    let mut lines: Vec<String> = input.split('\n').map(str::to_string).collect();
    let text = lines.get_mut(line)?;
    let (checked, _) = checkbox_line(text)?;
    let position = text.find('[')? + 1;
    text.replace_range(position..position + 1, if checked { " " } else { "x" });
    Some(lines.join("\n"))
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

/// Only shell fences can be sent to a terminal. Untagged fences are shell.
pub fn is_shell_language(language: Option<&str>) -> bool {
    let token = language
        .unwrap_or("")
        .trim()
        .trim_matches(['{', '}'])
        .split(|c: char| c.is_whitespace() || c == ',')
        .next()
        .unwrap_or("")
        .trim_start_matches('.')
        .to_ascii_lowercase();
    matches!(token.as_str(), "" | "bash" | "sh" | "zsh" | "shell")
}

pub fn shell_blocks(input: &str) -> Vec<String> {
    parse_markdown(input)
        .into_iter()
        .filter_map(|section| match section {
            MarkdownSection::CodeBlock { language, code }
                if is_shell_language(language.as_deref()) =>
            {
                Some(code)
            }
            _ => None,
        })
        .collect()
}

/// A completed command must have appeared after this run started. Old
/// commands with identical text must never advance a runbook.
pub fn completed_command(
    blocks: &[crate::command_block::CommandBlock],
    previous: &std::collections::HashSet<uuid::Uuid>,
    command: &str,
) -> Option<bool> {
    let normalized = |s: &str| s.trim().to_string();
    let expected = normalized(command);
    blocks
        .iter()
        .rev()
        .find(|block| !previous.contains(&block.id) && normalized(&block.command) == expected)
        .filter(|block| !block.is_running())
        .map(|block| block.is_success())
}

#[cfg(test)]
mod current_runbook_tests {
    use super::*;
    #[test]
    fn tasks_toggle_source_and_ignore_fenced_examples() {
        let text = "- [ ] work\n* [X] done\n```\n- [x] sample\n```\n";
        assert_eq!(plan_progress(text), (1, 2));
        let changed = toggle_checkbox(text, 0).unwrap();
        assert_eq!(plan_progress(&changed), (2, 2));
        assert!(changed.ends_with('\n'));
        assert!(toggle_checkbox(text, 2).is_none());
        assert!(
            parse_markdown("- item\n2. next\n---")
                .iter()
                .any(|s| matches!(s, MarkdownSection::Rule))
        );
    }
    #[test]
    fn only_shell_fences_are_executable() {
        assert_eq!(
            shell_blocks("```python\nprint(1)\n```\n```BASH extra\necho ok\n```\n```\npwd\n```"),
            vec!["echo ok", "pwd"]
        );
        assert!(is_shell_language(Some("{.zsh}")));
        assert!(!is_shell_language(Some("rust")));
    }
    #[test]
    fn previous_and_running_commands_do_not_complete_next_run() {
        let mut old = crate::command_block::CommandBlock::new("echo ok", 0);
        old.end_line = Some(1);
        old.exit_code = Some(0);
        let previous = [old.id].into_iter().collect();
        let mut new = crate::command_block::CommandBlock::new(" echo ok ", 2);
        assert_eq!(
            completed_command(&[old.clone(), new.clone()], &previous, "echo ok"),
            None
        );
        new.end_line = Some(3);
        new.exit_code = Some(1);
        assert_eq!(
            completed_command(&[old, new], &previous, "echo ok"),
            Some(false)
        );
    }
}

/// A run of inline text with its style.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct InlineRun {
    pub text: String,
    pub bold: bool,
    pub italic: bool,
    pub code: bool,
    pub strike: bool,
    pub underline: bool,
    pub foreground: Option<[u8; 3]>,
    pub background: Option<[u8; 3]>,
    pub monospace: bool,
    pub link: Option<String>,
}

/// Turns a style flag on.
type Apply = fn(&mut Style);

#[derive(Clone, Copy, Default)]
struct Style {
    bold: bool,
    italic: bool,
    strike: bool,
    underline: bool,
    foreground: Option<[u8; 3]>,
    background: Option<[u8; 3]>,
    monospace: bool,
}

/// Inline markdown of a text block. Unmatched markers stay as text.
pub fn parse_inline(text: &str) -> Vec<InlineRun> {
    let mut out = Vec::new();
    inline_into(text, Style::default(), None, &mut out);
    merge_inline_runs(out)
}

fn merge_inline_runs(out: Vec<InlineRun>) -> Vec<InlineRun> {
    // Merge neighbours with the same style.
    let mut merged: Vec<InlineRun> = Vec::new();
    for run in out {
        if let Some(last) = merged.last_mut()
            && (
                last.bold,
                last.italic,
                last.code,
                last.strike,
                last.underline,
                last.foreground,
                last.background,
                last.monospace,
                &last.link,
            ) == (
                run.bold,
                run.italic,
                run.code,
                run.strike,
                run.underline,
                run.foreground,
                run.background,
                run.monospace,
                &run.link,
            )
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
        underline: style.underline,
        foreground: style.foreground,
        background: style.background,
        monospace: style.monospace,
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
    fn terminal_fences_are_never_runnable_when_styles_are_valid_or_invalid() {
        let selection = crate::terminal_clipboard::StyledClipboardSelection::new(
            "echo never-run".into(),
            vec![crate::terminal_clipboard::StyledClipboardRun {
                text: "echo never-run".into(),
                bold: true,
                ..Default::default()
            }],
        )
        .unwrap();
        let valid = selection.markdown_source().unwrap();
        assert!(code_blocks(&valid).is_empty());
        assert!(shell_blocks(&valid).is_empty());

        let invalid = valid.replace("echo never-run", "echo still-visible");
        assert!(code_blocks(&invalid).is_empty());
        assert!(shell_blocks(&invalid).is_empty());
        let parsed_invalid = parse_markdown(&invalid);
        let [MarkdownSection::TerminalSelection(runs)] = parsed_invalid.as_slice() else {
            panic!("invalid terminal metadata must remain a terminal text section")
        };
        assert_eq!(runs.len(), 1);
        assert_eq!(runs[0].text, "echo still-visible");
        assert!(runs[0].monospace);
        assert!(!runs[0].bold);
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
