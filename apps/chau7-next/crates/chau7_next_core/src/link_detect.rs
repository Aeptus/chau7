//! Cmd-click targets in terminal text: URLs and file paths
//! (`RegexPatterns.url` and `.filePath`, `PathClickHandler.swift`).
//!
//! Positions are character indices into the text, so the caller can map a
//! clicked cell straight to a match.

use std::path::PathBuf;
use std::sync::OnceLock;

use regex::Regex;

use crate::shell_escaping::is_valid_path;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct UrlMatch {
    pub url: String,
    /// First character and one past the last.
    pub start: usize,
    pub end: usize,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PathMatch {
    pub path: String,
    pub line: Option<u32>,
    pub column: Option<u32>,
    /// The path only: `:line:column` is not part of the range.
    pub start: usize,
    pub end: usize,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum LinkTarget {
    Url(UrlMatch),
    Path(PathMatch),
}

fn url_regex() -> &'static Regex {
    static R: OnceLock<Regex> = OnceLock::new();
    R.get_or_init(|| {
        Regex::new(r#"(?i)(?:https?|file|ssh|ftp|sftp)://[^\s<>\[\]{}|\\^`"']+"#)
            .expect("valid regex")
    })
}

fn path_regex() -> &'static Regex {
    static R: OnceLock<Regex> = OnceLock::new();
    R.get_or_init(|| {
        Regex::new(r#"(?:^|[\s"'`({\[])((?:[/.])?(?:[\w.-]+/)*[\w.-]+\.\w+)(?::(\d+))?(?::(\d+))?"#)
            .expect("valid regex")
    })
}

/// Byte offset to character index.
fn char_index(text: &str, byte: usize) -> usize {
    text[..byte].chars().count()
}

/// Explicit boundaries let filenames contain spaces without consuming prose.
fn delimited_targets(text: &str) -> impl Iterator<Item = regex::Match<'_>> {
    static R: OnceLock<Regex> = OnceLock::new();
    R.get_or_init(|| {
        Regex::new(
            r#""([^"\r\n]+)"|'([^'\r\n]+)'|`([^`\r\n]+)`|<([^<>\r\n]+)>|\]\(([^()<>\r\n]+)\)"#,
        )
        .expect("valid regex")
    })
    .captures_iter(text)
    .filter_map(|caps| (1..=5).find_map(|i| caps.get(i)))
}

pub fn find_urls(text: &str) -> Vec<UrlMatch> {
    let mut matches: Vec<_> = delimited_targets(text)
        .filter(|m| {
            url_regex().find(m.as_str()).is_some_and(|u| u.start() == 0)
                && m.as_str()
                    .get(..7)
                    .is_some_and(|s| s.eq_ignore_ascii_case("file://"))
        })
        .collect();
    for m in url_regex().find_iter(text) {
        if !matches
            .iter()
            .any(|whole| whole.start() <= m.start() && m.start() < whole.end())
        {
            matches.push(m);
        }
    }
    matches.sort_by_key(|m| m.start());
    matches
        .into_iter()
        .map(|m| UrlMatch {
            url: m.as_str().to_string(),
            start: char_index(text, m.start()),
            end: char_index(text, m.end()),
        })
        .collect()
}

fn full_path_regex() -> &'static Regex {
    static FULL: OnceLock<Regex> = OnceLock::new();
    FULL.get_or_init(|| {
        Regex::new(r"^([^\r\n<>|\x00]+\.\w+)(?::(\d+))?(?::(\d+))?$").expect("valid regex")
    })
}

pub fn find_paths(text: &str) -> Vec<PathMatch> {
    let mut paths = Vec::new();
    for m in delimited_targets(text) {
        // URI escapes belong to URLs; literal paths retain literal '%' and '+'.
        if m.as_str().contains("://") {
            continue;
        }
        if let Some(caps) = full_path_regex().captures(m.as_str()) {
            let path = caps.get(1).unwrap();
            paths.push(PathMatch {
                path: path.as_str().into(),
                line: caps.get(2).and_then(|m| m.as_str().parse().ok()),
                column: caps.get(3).and_then(|m| m.as_str().parse().ok()),
                start: char_index(text, m.start()),
                end: char_index(text, m.start() + path.end()),
            });
        }
    }
    // A directory prefix bounds an unquoted path's start. Stop at the first
    // extension followed by a delimiter, then let the caller check existence.
    static SPACED: OnceLock<Regex> = OnceLock::new();
    let spaced = SPACED.get_or_init(|| {
        Regex::new(r#"(?:^|[\s"'`({\[])((?:~?/|\.\.?/|[\w.-]+/)[^\r\n<>|`"'\[\]()]*?\.\w+)(?::(\d+))?(?::(\d+))?(?:$|[\s)\]},;])"#)
            .expect("valid regex")
    });
    let mut offset = 0;
    while let Some(caps) = spaced.captures_at(text, offset) {
        let path = caps.get(1).unwrap();
        offset = caps.get(3).or_else(|| caps.get(2)).unwrap_or(path).end();
        let start = char_index(text, path.start());
        if paths.iter().any(|p| (p.start..p.end).contains(&start)) {
            continue;
        }
        paths.push(PathMatch {
            path: path.as_str().into(),
            line: caps.get(2).and_then(|m| m.as_str().parse().ok()),
            column: caps.get(3).and_then(|m| m.as_str().parse().ok()),
            start,
            end: char_index(text, path.end()),
        });
    }
    for caps in path_regex().captures_iter(text) {
        let Some(path) = caps.get(1) else {
            continue;
        };
        let start = char_index(text, path.start());
        if paths.iter().any(|p| (p.start..p.end).contains(&start)) {
            continue;
        }
        paths.push(PathMatch {
            path: path.as_str().to_string(),
            line: caps.get(2).and_then(|m| m.as_str().parse().ok()),
            column: caps.get(3).and_then(|m| m.as_str().parse().ok()),
            start,
            end: char_index(text, path.end()),
        });
    }
    paths.sort_by_key(|p| p.start);
    paths
}

/// OSC 8 carries the entire destination, so an absolute path needs no quoting.
pub fn hyperlink_path(href: &str) -> Option<PathMatch> {
    if href.starts_with('/') && !href.starts_with("//") && !href.chars().any(char::is_control) {
        let caps = full_path_regex().captures(href)?;
        let path = caps.get(1)?;
        return Some(PathMatch {
            path: path.as_str().into(),
            line: caps.get(2).and_then(|m| m.as_str().parse().ok()),
            column: caps.get(3).and_then(|m| m.as_str().parse().ok()),
            start: 0,
            end: path.as_str().chars().count(),
        });
    }
    local_file_path(href)
}

/// Decode a local file URI exactly once. Remote authorities stay system URLs.
/// This also accepts raw spaces in OSC 8 targets, whose boundaries are explicit.
pub fn local_file_path(uri: &str) -> Option<PathMatch> {
    if !uri.get(..7)?.eq_ignore_ascii_case("file://") {
        return None;
    }
    let rest = &uri[7..];
    let slash = rest.find('/')?;
    let authority = &rest[..slash];
    if !authority.is_empty() && !authority.eq_ignore_ascii_case("localhost") {
        return None;
    }
    let path_and_query = &rest[slash..];
    let (path_and_query, fragment) = path_and_query
        .split_once('#')
        .map_or((path_and_query, None), |(p, f)| (p, Some(f)));
    let encoded = path_and_query.split('?').next()?;
    let mut bytes = Vec::with_capacity(encoded.len());
    let mut iter = encoded.bytes();
    while let Some(b) = iter.next() {
        bytes.push(if b == b'%' {
            let hi = (iter.next()? as char).to_digit(16)?;
            let lo = (iter.next()? as char).to_digit(16)?;
            ((hi << 4) | lo) as u8
        } else {
            b
        });
    }
    let path = String::from_utf8(bytes).ok()?;
    if path.chars().any(char::is_control) || path.starts_with("//") {
        return None;
    }
    let line = fragment
        .and_then(|f| f.strip_prefix('L'))
        .and_then(|n| n.parse::<u32>().ok())
        .filter(|n| *n > 0);
    Some(PathMatch {
        path,
        line,
        column: None,
        start: 0,
        end: uri.chars().count(),
    })
}

/// The URL, else the path, under character `index` (URLs win, like Swift).
pub fn target_at(text: &str, index: usize) -> Option<LinkTarget> {
    if let Some(url) = find_urls(text)
        .into_iter()
        .find(|u| (u.start..u.end).contains(&index))
    {
        return Some(LinkTarget::Url(url));
    }
    find_paths(text)
        .into_iter()
        .find(|p| (p.start..p.end).contains(&index))
        .map(LinkTarget::Path)
}

/// Absolute, `~`, or relative to `working_dir`.
pub fn resolve_path(path: &str, working_dir: &str, home: &str) -> PathBuf {
    if path.starts_with('/') {
        return PathBuf::from(path);
    }
    if let Some(rest) = path.strip_prefix('~') {
        let rest = rest.trim_start_matches('/');
        return PathBuf::from(home).join(rest);
    }
    PathBuf::from(working_dir).join(path)
}

/// How to open a clicked file.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum EditorLaunch {
    /// Run `program` with `args`.
    Run { program: String, args: Vec<String> },
    /// Hand the file to the system's default app.
    SystemOpen,
    /// The path is not safe to pass on (`..` components, `$(`, backticks).
    Refused,
}

/// Directories searched for `code`, `subl` and `atom` when no editor is set.
pub const EDITOR_SEARCH_DIRS: [&str; 3] = ["/usr/local/bin", "/opt/homebrew/bin", "/usr/bin"];

/// Choose the program and arguments for `PathClickHandler.openPath`.
/// `default_editor` is the setting, `env_editor` is `$EDITOR`, and
/// `find_executable` finds a bare editor name in [`EDITOR_SEARCH_DIRS`].
pub fn editor_launch(
    full_path: &str,
    line: Option<u32>,
    column: Option<u32>,
    default_editor: &str,
    env_editor: &str,
    find_executable: &dyn Fn(&str) -> Option<String>,
) -> EditorLaunch {
    if !is_valid_path(full_path) {
        return EditorLaunch::Refused;
    }
    let editor = if default_editor.is_empty() {
        env_editor
    } else {
        default_editor
    };
    let col = column.unwrap_or(1);
    if editor.is_empty() {
        if let Some(line) = line {
            let candidates: [(&str, Vec<String>); 3] = [
                (
                    "code",
                    vec!["--goto".into(), format!("{full_path}:{line}:{col}")],
                ),
                ("subl", vec![format!("{full_path}:{line}:{col}")]),
                ("atom", vec![format!("{full_path}:{line}:{col}")]),
            ];
            for (name, args) in candidates {
                if let Some(program) = find_executable(name) {
                    return EditorLaunch::Run { program, args };
                }
            }
        }
        return EditorLaunch::SystemOpen;
    }
    let args = match line {
        Some(line) if editor.contains("code") || editor.contains("subl") => {
            vec!["--goto".into(), format!("{full_path}:{line}:{col}")]
        }
        Some(line) if editor.contains("vim") || editor.contains("nvim") => {
            vec![format!("+{line}"), full_path.to_string()]
        }
        Some(line) if editor.contains("emacs") => {
            vec![format!("+{line}:{col}"), full_path.to_string()]
        }
        _ => vec![full_path.to_string()],
    };
    EditorLaunch::Run {
        program: editor.to_string(),
        args,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn spaced_paths_preserve_the_whole_target_at_every_character() {
        for (text, expected, line) in [
            (
                "See /fixture/Project Notes/design.md next",
                "/fixture/Project Notes/design.md",
                None,
            ),
            (
                "See docs/Release Notes.md next",
                "docs/Release Notes.md",
                None,
            ),
            (
                "See `Project Notes/design.md:12:4` next",
                "Project Notes/design.md",
                Some(12),
            ),
            (
                "See \"Project Notes/design.md\" next",
                "Project Notes/design.md",
                None,
            ),
            (
                "See [notes](</fixture/Project Notes/design.md>)",
                "/fixture/Project Notes/design.md",
                None,
            ),
            (
                "See [notes](/fixture/Project Notes/design.md)",
                "/fixture/Project Notes/design.md",
                None,
            ),
            (
                "é /fixture/Café Notes/é.md",
                "/fixture/Café Notes/é.md",
                None,
            ),
        ] {
            let start = char_index(text, text.find(expected).unwrap());
            for i in start..start + expected.chars().count() {
                let Some(LinkTarget::Path(p)) = target_at(text, i) else {
                    panic!("missing {text} at {i}");
                };
                assert_eq!(p.path, expected, "{text} at {i}");
                assert_eq!(p.line, line);
            }
        }
    }

    #[test]
    fn separate_spaced_paths_do_not_consume_each_other_or_prose() {
        let text = "/fixture/One Note.md /fixture/Two Notes.md and prose";
        let paths = find_paths(text);
        assert_eq!(
            paths.iter().map(|p| p.path.as_str()).collect::<Vec<_>>(),
            ["/fixture/One Note.md", "/fixture/Two Notes.md"]
        );
        assert_eq!(target_at(text, text.find("and prose").unwrap()), None);
        assert_eq!(target_at("ordinary words without a file", 10), None);
    }

    #[test]
    fn delimited_file_urls_keep_spaces_and_character_ranges() {
        let text = "é [notes](<file:///fixture/Café Notes/a.md#L12>) next";
        let urls = find_urls(text);
        assert_eq!(urls.len(), 1);
        assert_eq!(urls[0].url, "file:///fixture/Café Notes/a.md#L12");
        let p = local_file_path(&urls[0].url).unwrap();
        assert_eq!(p.path, "/fixture/Café Notes/a.md");
        assert_eq!(p.line, Some(12));
        assert!(matches!(
            target_at(text, urls[0].end - 1),
            Some(LinkTarget::Url(_))
        ));
    }

    #[test]
    fn osc8_absolute_paths_preserve_spaces_and_source_positions() {
        let p = hyperlink_path("/fixture/Project Notes/Café.md:12:4").unwrap();
        assert_eq!(p.path, "/fixture/Project Notes/Café.md");
        assert_eq!((p.line, p.column), (Some(12), Some(4)));
        assert_eq!(hyperlink_path("https://example.test/a.md"), None);
        assert_eq!(hyperlink_path("//remote/fixture/a.md"), None);
        assert_eq!(hyperlink_path("/fixture/a\n.md"), None);
        assert_eq!(
            hyperlink_path("file:///fixture/Project%20Notes/a.md")
                .unwrap()
                .path,
            "/fixture/Project Notes/a.md"
        );
    }

    #[test]
    fn local_file_uris_decode_once_and_preserve_literal_paths() {
        for (uri, expected) in [
            ("file:///fixture/My%20Notes.md", "/fixture/My Notes.md"),
            (
                "FILE://LOCALHOST/fixture/Caf%C3%A9%20Notes.md",
                "/fixture/Café Notes.md",
            ),
            ("file:///fixture/My Notes.md", "/fixture/My Notes.md"),
            (
                "file:///fixture/a%2520b+%23.md?download=1#L9",
                "/fixture/a%20b+#.md",
            ),
        ] {
            assert_eq!(local_file_path(uri).unwrap().path, expected);
        }
        assert_eq!(
            local_file_path("file:///fixture/a.md#L9").unwrap().line,
            Some(9)
        );
        let p = find_paths("`docs/a%20b+.md`");
        assert_eq!(p[0].path, "docs/a%20b+.md");
    }

    #[test]
    fn remote_and_malformed_file_uris_are_not_local_paths() {
        for uri in [
            "https://example.test/a.md",
            "file://remote/fixture/a.md",
            "file://user@localhost/a.md",
            "file:///fixture/a%00.md",
            "file:///fixture/a%0A.md",
            "file:///fixture/%FF.md",
            "file:///fixture/a%.md",
            "file:///fixture/a%zz.md",
            "file:////remote/a.md",
        ] {
            assert_eq!(local_file_path(uri), None, "{uri}");
        }
        assert_eq!(
            find_urls("https://example.test/a.md more words")[0].url,
            "https://example.test/a.md"
        );
    }

    // Ported from PathClickHandlerTests.swift.
    #[test]
    fn path_containing_the_clicked_index() {
        let text = "See docs/alpha.md and docs/beta.md for details";
        let alpha = text.find("docs/alpha.md").unwrap() + 2;
        let beta = text.find("docs/beta.md").unwrap() + 2;
        let target = |i| match target_at(text, i) {
            Some(LinkTarget::Path(p)) => Some(p.path),
            _ => None,
        };
        assert_eq!(target(alpha).as_deref(), Some("docs/alpha.md"));
        assert_eq!(target(beta).as_deref(), Some("docs/beta.md"));
    }

    #[test]
    fn no_match_outside_a_path() {
        let text = "See docs/alpha.md and docs/beta.md for details";
        assert_eq!(target_at(text, text.find(" and ").unwrap() + 1), None);
    }

    #[test]
    fn leading_delimiter_is_not_part_of_the_path() {
        let text = "(docs/readme.md)";
        assert_eq!(target_at(text, 0), None);
        assert!(target_at(text, 1).is_some());
    }

    #[test]
    fn line_and_column_are_kept() {
        let text = "Open docs/readme.md:12:4 next";
        let i = text.find("docs/readme.md:12:4").unwrap() + 5;
        let Some(LinkTarget::Path(p)) = target_at(text, i) else {
            panic!("no path");
        };
        assert_eq!(
            (p.path.as_str(), p.line, p.column),
            ("docs/readme.md", Some(12), Some(4))
        );
        // The position suffix is not part of the clickable range.
        assert_eq!(&text[p.start..p.end], "docs/readme.md");
    }

    #[test]
    fn urls_win_over_paths_and_use_char_positions() {
        let text = "héllo see https://example.com/a/b.html?x=1 now";
        let i = text.chars().position(|c| c == 'e').unwrap();
        assert_eq!(target_at(text, i), None);
        let at = text.chars().position(|c| c == 'x').unwrap();
        let Some(LinkTarget::Url(u)) = target_at(text, at) else {
            panic!("no url");
        };
        assert_eq!(u.url, "https://example.com/a/b.html?x=1");
        assert_eq!(u.start, 10);
    }

    #[test]
    fn url_schemes() {
        for url in [
            "ftp://h/f",
            "sftp://h/f",
            "ssh://u@h",
            "file:///tmp/a",
            "HTTP://X.COM",
        ] {
            assert_eq!(find_urls(url).len(), 1, "{url}");
        }
        assert!(find_urls("mailto:a@b.c javascript:alert(1)").is_empty());
        // Stops at quotes and brackets.
        assert_eq!(find_urls("\"http://a.b/c\"")[0].url, "http://a.b/c");
    }

    #[test]
    fn resolves_relative_tilde_and_absolute() {
        assert_eq!(resolve_path("/a/b", "/w", "/h"), PathBuf::from("/a/b"));
        assert_eq!(resolve_path("~/x.rs", "/w", "/h"), PathBuf::from("/h/x.rs"));
        assert_eq!(
            resolve_path("src/x.rs", "/w", "/h"),
            PathBuf::from("/w/src/x.rs")
        );
    }

    fn none(_: &str) -> Option<String> {
        None
    }

    fn found(name: &str) -> Option<String> {
        (name == "subl").then(|| "/usr/local/bin/subl".to_string())
    }

    #[test]
    fn no_editor_prefers_a_known_editor_for_a_line() {
        assert_eq!(
            editor_launch("/w/a.rs", Some(3), None, "", "", &found),
            EditorLaunch::Run {
                program: "/usr/local/bin/subl".into(),
                args: vec!["/w/a.rs:3:1".into()]
            }
        );
        assert_eq!(
            editor_launch("/w/a.rs", Some(3), None, "", "", &none),
            EditorLaunch::SystemOpen
        );
        // No line: always the system default.
        assert_eq!(
            editor_launch("/w/a.rs", None, None, "", "", &found),
            EditorLaunch::SystemOpen
        );
    }

    #[test]
    fn configured_editor_gets_its_line_syntax() {
        let run = |editor: &str, line: Option<u32>| match editor_launch(
            "/w/a.rs",
            line,
            Some(7),
            editor,
            "",
            &none,
        ) {
            EditorLaunch::Run { program, args } => (program, args),
            other => panic!("{other:?}"),
        };
        assert_eq!(run("code", Some(5)).1, ["--goto", "/w/a.rs:5:7"]);
        assert_eq!(run("nvim", Some(5)).1, ["+5", "/w/a.rs"]);
        assert_eq!(run("emacs", Some(5)).1, ["+5:7", "/w/a.rs"]);
        assert_eq!(run("nano", Some(5)).1, ["/w/a.rs"]);
        assert_eq!(run("code", None).1, ["/w/a.rs"]);
    }

    #[test]
    fn env_editor_is_used_when_the_setting_is_empty() {
        assert_eq!(
            editor_launch("/w/a.rs", None, None, "", "vim", &none),
            EditorLaunch::Run {
                program: "vim".into(),
                args: vec!["/w/a.rs".into()]
            }
        );
    }

    #[test]
    fn unsafe_paths_are_refused() {
        assert_eq!(
            editor_launch("/w/../etc/passwd", None, None, "vim", "", &none),
            EditorLaunch::Refused
        );
        assert_eq!(
            editor_launch("/w/$(rm)", None, None, "vim", "", &none),
            EditorLaunch::Refused
        );
    }
}
