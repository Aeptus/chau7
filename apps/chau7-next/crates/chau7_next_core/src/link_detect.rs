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

pub fn find_urls(text: &str) -> Vec<UrlMatch> {
    url_regex()
        .find_iter(text)
        .map(|m| UrlMatch {
            url: m.as_str().to_string(),
            start: char_index(text, m.start()),
            end: char_index(text, m.end()),
        })
        .collect()
}

pub fn find_paths(text: &str) -> Vec<PathMatch> {
    path_regex()
        .captures_iter(text)
        .filter_map(|caps| {
            let path = caps.get(1)?;
            Some(PathMatch {
                path: path.as_str().to_string(),
                line: caps.get(2).and_then(|m| m.as_str().parse().ok()),
                column: caps.get(3).and_then(|m| m.as_str().parse().ok()),
                start: char_index(text, path.start()),
                end: char_index(text, path.end()),
            })
        })
        .collect()
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
