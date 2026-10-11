//! The Help window's content and its small Markdown renderer model (Views
//! module): `HelpDocumentation.swift` (`HelpTopic`, `HelpContent.topics`,
//! `HelpWindowView` search, `MarkdownContentView`, `TableView`).
//!
//! The 11 topics are the English texts of the Swift app, kept as Markdown
//! files in `help_topics/` (the Swift strings with `⌘`-style shortcuts
//! unchanged). The window turns a topic into [`Block`]s with
//! [`parse_blocks`] and each text into [`Span`]s with [`parse_inline`].

/// Id of the "Technology, Licenses & Acknowledgments" topic
/// (`HelpWindowController.show(topicID:)`).
pub const TECHNOLOGY_LICENSES: &str = "technology-licenses";

/// Title of the Help window (`help.window.title`).
pub const WINDOW_TITLE: &str = "Chau7 Next Help";

/// One entry of the topic list.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct HelpTopic {
    pub id: &'static str,
    pub title: &'static str,
    /// SF Symbol name in Swift.
    pub icon: &'static str,
    /// Markdown.
    pub content: &'static str,
    /// Topics of the "Related Topics" buttons.
    pub related: &'static [&'static str],
}

/// The topics in list order (`HelpContent.topics`).
pub const TOPICS: [HelpTopic; 11] = [
    HelpTopic {
        id: "getting-started",
        title: "Getting Started",
        icon: "play.circle",
        content: include_str!("help_topics/getting-started.md"),
        related: &["tabs-windows", "command-palette", "settings"],
    },
    HelpTopic {
        id: "tabs-windows",
        title: "Tabs & Windows",
        icon: "rectangle.stack",
        content: include_str!("help_topics/tabs-windows.md"),
        related: &["getting-started", "ai-integration"],
    },
    HelpTopic {
        id: "command-palette",
        title: "Command Palette",
        icon: "command",
        content: include_str!("help_topics/command-palette.md"),
        related: &["keyboard-shortcuts", "getting-started"],
    },
    HelpTopic {
        id: "ssh-manager",
        title: "SSH Manager",
        icon: "server.rack",
        content: include_str!("help_topics/ssh-manager.md"),
        related: &["tabs-windows", "terminal-features"],
    },
    HelpTopic {
        id: "ai-integration",
        title: "AI Integration",
        icon: "sparkles",
        content: include_str!("help_topics/ai-integration.md"),
        related: &["tabs-windows", "settings", "token-optimizer"],
    },
    HelpTopic {
        id: "keyboard-shortcuts",
        title: "Keyboard Shortcuts",
        icon: "keyboard",
        content: include_str!("help_topics/keyboard-shortcuts.md"),
        related: &["command-palette", "settings"],
    },
    HelpTopic {
        id: "terminal-features",
        title: "Terminal Features",
        icon: "terminal",
        content: include_str!("help_topics/terminal-features.md"),
        related: &["settings", "keyboard-shortcuts"],
    },
    HelpTopic {
        id: "snippets",
        title: "Snippets",
        icon: "text.badge.plus",
        content: include_str!("help_topics/snippets.md"),
        related: &["settings"],
    },
    HelpTopic {
        id: "token-optimizer",
        title: "Token Optimizer",
        icon: "bolt.shield",
        content: include_str!("help_topics/token-optimizer.md"),
        related: &["ai-integration", "settings"],
    },
    HelpTopic {
        id: "settings",
        title: "Settings",
        icon: "gear",
        content: include_str!("help_topics/settings.md"),
        related: &["getting-started", "token-optimizer"],
    },
    HelpTopic {
        id: TECHNOLOGY_LICENSES,
        title: "Technology, Licenses & Acknowledgments",
        icon: "doc.text.magnifyingglass",
        content: include_str!("help_topics/technology-licenses.md"),
        related: &["getting-started", "token-optimizer", "settings"],
    },
];

/// `HelpContent.topic(id:)`.
pub fn topic(id: &str) -> Option<&'static HelpTopic> {
    TOPICS.iter().find(|t| t.id == id)
}

/// The topic shown when the window opens: the given one when it exists, else
/// the first.
pub fn initial_topic(id: Option<&str>) -> &'static HelpTopic {
    id.and_then(topic).unwrap_or(&TOPICS[0])
}

/// The topics matching the search box: the query (case-insensitive) is in the
/// title or in the content; an empty query lists all (`filteredTopics`).
pub fn filter_topics(query: &str) -> Vec<&'static HelpTopic> {
    if query.is_empty() {
        return TOPICS.iter().collect();
    }
    let query = query.to_lowercase();
    TOPICS
        .iter()
        .filter(|t| {
            t.title.to_lowercase().contains(&query) || t.content.to_lowercase().contains(&query)
        })
        .collect()
}

// ----- Markdown ---------------------------------------------------------------

/// A block of a topic.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Block {
    /// `#`, `##` or `###` (level 1 to 3).
    Heading {
        level: u8,
        text: String,
    },
    /// Plain lines of one paragraph, joined with `\n`.
    Paragraph(String),
    /// `- ` items; `indent` is the nesting (0 for none).
    Bullets(Vec<Bullet>),
    /// A fenced block, without the fences and the language tag.
    Code(String),
    Table(Table),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Bullet {
    pub indent: usize,
    pub text: String,
}

/// A pipe table. The second column is drawn in a monospaced font
/// (`TableView`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Table {
    pub header: Vec<String>,
    pub rows: Vec<Vec<String>>,
}

fn heading(line: &str) -> Option<(u8, &str)> {
    let t = line.trim();
    for (prefix, level) in [("### ", 3u8), ("## ", 2), ("# ", 1)] {
        if let Some(rest) = t.strip_prefix(prefix) {
            return Some((level, rest.trim()));
        }
    }
    None
}

fn bullet(line: &str) -> Option<Bullet> {
    let trimmed = line.trim_start_matches(' ');
    let text = trimmed.strip_prefix("- ")?;
    Some(Bullet {
        indent: (line.len() - trimmed.len()) / 2,
        text: text.trim().to_string(),
    })
}

/// Cells of a table line: split on `|`, trimmed, empty ones dropped.
fn table_cells(line: &str) -> Vec<String> {
    line.split('|')
        .map(|c| c.trim().to_string())
        .filter(|c| !c.is_empty())
        .collect()
}

/// Split a topic into blocks: headings, bullet lists, fenced code (blank
/// lines inside stay inside), pipe tables and paragraphs.
pub fn parse_blocks(markdown: &str) -> Vec<Block> {
    let lines: Vec<&str> = markdown.lines().collect();
    let mut blocks = Vec::new();
    let mut i = 0;
    while i < lines.len() {
        let line = lines[i];
        let trimmed = line.trim();
        if trimmed.is_empty() {
            i += 1;
        } else if trimmed.starts_with("```") {
            let mut code = Vec::new();
            i += 1;
            while i < lines.len() && !lines[i].trim().starts_with("```") {
                code.push(lines[i]);
                i += 1;
            }
            i += 1; // the closing fence
            blocks.push(Block::Code(code.join("\n")));
        } else if let Some((level, text)) = heading(line) {
            blocks.push(Block::Heading {
                level,
                text: text.to_string(),
            });
            i += 1;
        } else if trimmed.starts_with('|') {
            let mut rows: Vec<Vec<String>> = Vec::new();
            while i < lines.len() && lines[i].trim().starts_with('|') {
                // The separator row (`|---|---|`) is dropped, as in Swift.
                if !lines[i].contains("---") {
                    rows.push(table_cells(lines[i]));
                }
                i += 1;
            }
            if rows.len() > 1 {
                let header = rows.remove(0);
                blocks.push(Block::Table(Table { header, rows }));
            }
        } else if bullet(line).is_some() {
            let mut items = Vec::new();
            while i < lines.len() {
                match bullet(lines[i]) {
                    Some(b) => items.push(b),
                    None => break,
                }
                i += 1;
            }
            blocks.push(Block::Bullets(items));
        } else {
            let mut para = Vec::new();
            while i < lines.len() {
                let l = lines[i];
                let t = l.trim();
                if t.is_empty()
                    || t.starts_with("```")
                    || t.starts_with('|')
                    || heading(l).is_some()
                    || bullet(l).is_some()
                {
                    break;
                }
                para.push(t);
                i += 1;
            }
            blocks.push(Block::Paragraph(para.join("\n")));
        }
    }
    blocks
}

/// A run of text in a paragraph, bullet or table cell.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Span {
    Text(String),
    /// `**text**`.
    Bold(String),
    /// `` `text` ``.
    Code(String),
}

/// Bold (`**text**`) and inline code (backticks); everything else is text.
pub fn parse_inline(text: &str) -> Vec<Span> {
    let mut spans = Vec::new();
    let mut plain = String::new();
    let mut rest = text;
    let flush = |plain: &mut String, spans: &mut Vec<Span>| {
        if !plain.is_empty() {
            spans.push(Span::Text(std::mem::take(plain)));
        }
    };
    while !rest.is_empty() {
        if let Some(after) = rest.strip_prefix("**")
            && let Some(end) = after.find("**")
            && end > 0
            && !after[..end].contains('*')
        {
            flush(&mut plain, &mut spans);
            spans.push(Span::Bold(after[..end].to_string()));
            rest = &after[end + 2..];
            continue;
        }
        if let Some(after) = rest.strip_prefix('`')
            && let Some(end) = after.find('`')
            && end > 0
        {
            flush(&mut plain, &mut spans);
            spans.push(Span::Code(after[..end].to_string()));
            rest = &after[end + 1..];
            continue;
        }
        let c = rest.chars().next().unwrap_or(' ');
        plain.push(c);
        rest = &rest[c.len_utf8()..];
    }
    flush(&mut plain, &mut spans);
    spans
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn eleven_topics_in_swift_order() {
        let ids: Vec<_> = TOPICS.iter().map(|t| t.id).collect();
        assert_eq!(
            ids,
            [
                "getting-started",
                "tabs-windows",
                "command-palette",
                "ssh-manager",
                "ai-integration",
                "keyboard-shortcuts",
                "terminal-features",
                "snippets",
                "token-optimizer",
                "settings",
                "technology-licenses"
            ]
        );
        assert_eq!(TOPICS[10].title, "Technology, Licenses & Acknowledgments");
    }

    #[test]
    fn related_topics_all_exist() {
        for t in TOPICS {
            assert!(!t.related.is_empty(), "{}", t.id);
            for r in t.related {
                assert!(topic(r).is_some(), "{} -> {r}", t.id);
                assert_ne!(*r, t.id);
            }
        }
    }

    #[test]
    fn every_topic_starts_with_its_heading() {
        for t in TOPICS {
            assert!(t.content.starts_with("# "), "{}", t.id);
            assert!(!t.content.contains('\u{2014}'), "{} has an em dash", t.id);
        }
    }

    #[test]
    fn initial_topic_falls_back_to_the_first() {
        assert_eq!(initial_topic(None).id, "getting-started");
        assert_eq!(initial_topic(Some("nope")).id, "getting-started");
        assert_eq!(
            initial_topic(Some(TECHNOLOGY_LICENSES)).id,
            TECHNOLOGY_LICENSES
        );
    }

    #[test]
    fn search_matches_titles_and_content() {
        assert_eq!(filter_topics("").len(), 11);
        let by_title = filter_topics("ssh manager");
        assert!(by_title.iter().any(|t| t.id == "ssh-manager"));
        // Only the license page mentions swift-atomics.
        let by_content = filter_topics("SWIFT-ATOMICS");
        assert_eq!(by_content.len(), 1);
        assert_eq!(by_content[0].id, TECHNOLOGY_LICENSES);
        assert!(filter_topics("zzzzqqq").is_empty());
    }

    #[test]
    fn parses_headings_bullets_and_paragraphs() {
        let blocks = parse_blocks(
            "# Title\n\nSome **bold** text\nsecond line\n\n## Sub\n\n- one\n- two\n  - nested\n\n### Third\n",
        );
        assert_eq!(
            blocks,
            vec![
                Block::Heading {
                    level: 1,
                    text: "Title".into()
                },
                Block::Paragraph("Some **bold** text\nsecond line".into()),
                Block::Heading {
                    level: 2,
                    text: "Sub".into()
                },
                Block::Bullets(vec![
                    Bullet {
                        indent: 0,
                        text: "one".into()
                    },
                    Bullet {
                        indent: 0,
                        text: "two".into()
                    },
                    Bullet {
                        indent: 1,
                        text: "nested".into()
                    },
                ]),
                Block::Heading {
                    level: 3,
                    text: "Third".into()
                },
            ]
        );
    }

    #[test]
    fn code_blocks_keep_blank_lines() {
        let blocks = parse_blocks("```bash\nimgcat a.png\n\ncat a.png | imgcat\n```\n\nafter");
        assert_eq!(
            blocks,
            vec![
                Block::Code("imgcat a.png\n\ncat a.png | imgcat".into()),
                Block::Paragraph("after".into())
            ]
        );
    }

    #[test]
    fn tables_drop_the_separator_row() {
        let blocks = parse_blocks(
            "| Action | Shortcut |\n|--------|----------|\n| New Tab | ⌘T |\n| Close | ⌘W |\n",
        );
        assert_eq!(
            blocks,
            vec![Block::Table(Table {
                header: vec!["Action".into(), "Shortcut".into()],
                rows: vec![
                    vec!["New Tab".into(), "⌘T".into()],
                    vec!["Close".into(), "⌘W".into()]
                ]
            })]
        );
    }

    #[test]
    fn inline_bold_and_code() {
        assert_eq!(
            parse_inline("Press **⌘T** or run `ls` now"),
            vec![
                Span::Text("Press ".into()),
                Span::Bold("⌘T".into()),
                Span::Text(" or run ".into()),
                Span::Code("ls".into()),
                Span::Text(" now".into()),
            ]
        );
        // Unclosed markers stay text.
        assert_eq!(parse_inline("a ** b"), vec![Span::Text("a ** b".into())]);
        assert_eq!(parse_inline("plain"), vec![Span::Text("plain".into())]);
    }

    #[test]
    fn real_topics_parse_into_blocks() {
        for t in TOPICS {
            let blocks = parse_blocks(t.content);
            assert!(
                matches!(blocks.first(), Some(Block::Heading { level: 1, .. })),
                "{}",
                t.id
            );
            // No fence is left open and no raw fence ends up in a paragraph.
            for block in &blocks {
                if let Block::Paragraph(p) = block {
                    assert!(!p.contains("```"), "{}: {p}", t.id);
                }
            }
        }
        let tech = parse_blocks(topic(TECHNOLOGY_LICENSES).unwrap().content);
        assert!(tech.iter().any(|b| matches!(b, Block::Table(_))));
        assert!(tech.iter().any(|b| matches!(b, Block::Code(_))));
    }
}
