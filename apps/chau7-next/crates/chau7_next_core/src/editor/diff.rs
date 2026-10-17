//! Diff viewer logic (`DiffViewerModel` in
//! `SplitPanes/SplitPaneController.swift`, `UnifiedDiffContent` in
//! `SplitPanes/DiffViewerPaneView.swift`): the unified diff parser, the git
//! arguments for each mode, and the numbered rows the pane shows.

use serde::{Deserialize, Serialize};

/// `DiffMode`: unstaged changes (`git diff`) or staged ones (`git diff --cached`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
pub enum DiffMode {
    #[default]
    #[serde(rename = "workingTree")]
    WorkingTree,
    #[serde(rename = "staged")]
    Staged,
}

impl DiffMode {
    /// Raw value saved in the layout (`workingTree`, `staged`).
    pub fn raw(self) -> &'static str {
        match self {
            DiffMode::WorkingTree => "workingTree",
            DiffMode::Staged => "staged",
        }
    }

    pub fn from_raw(raw: &str) -> Option<Self> {
        match raw {
            "workingTree" => Some(DiffMode::WorkingTree),
            "staged" => Some(DiffMode::Staged),
            _ => None,
        }
    }

    pub fn toggled(self) -> Self {
        match self {
            DiffMode::WorkingTree => DiffMode::Staged,
            DiffMode::Staged => DiffMode::WorkingTree,
        }
    }

    /// `git` arguments for `file` in this mode.
    pub fn git_args(self, file: &str) -> Vec<String> {
        let mut args = vec!["diff".to_string()];
        if self == DiffMode::Staged {
            args.push("--cached".into());
        }
        args.push("--".into());
        args.push(file.into());
        args
    }
}

/// One line of a hunk (`DiffLineType`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DiffLine {
    Context(String),
    Addition(String),
    Deletion(String),
    HunkHeader(String),
}

/// A parsed hunk (`DiffHunk`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DiffHunk {
    pub header: String,
    pub old_start: usize,
    pub old_count: usize,
    pub new_start: usize,
    pub new_count: usize,
    pub lines: Vec<DiffLine>,
}

/// `ParseResult`.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ParsedDiff {
    pub hunks: Vec<DiffHunk>,
    pub additions: usize,
    pub deletions: usize,
}

/// Leading unsigned integer of `s`, and the rest.
fn scan_int(s: &str) -> (Option<usize>, &str) {
    let end = s.find(|c: char| !c.is_ascii_digit()).unwrap_or(s.len());
    (s[..end].parse().ok(), &s[end..])
}

/// `@@ -oldStart[,oldCount] +newStart[,newCount] @@` (`parseHunkHeader`);
/// a missing count is 1.
fn parse_hunk_header(header: &str) -> (usize, usize, usize, usize) {
    let rest = header.trim_start_matches("@@").trim_start();
    let rest = rest.strip_prefix('-').unwrap_or(rest);
    let (old_start, rest) = scan_int(rest);
    let (old_count, rest) = match rest.strip_prefix(',') {
        Some(r) => {
            let (n, r) = scan_int(r);
            (n.unwrap_or(1), r)
        }
        None => (1, rest),
    };
    let rest = rest.trim_start();
    let rest = rest.strip_prefix('+').unwrap_or(rest);
    let (new_start, rest) = scan_int(rest);
    let new_count = match rest.strip_prefix(',') {
        Some(r) => scan_int(r).0.unwrap_or(1),
        None => 1,
    };
    (
        old_start.unwrap_or(0),
        old_count,
        new_start.unwrap_or(0),
        new_count,
    )
}

/// `parseUnifiedDiff`: hunks with their lines, and the totals. Lines before
/// the first hunk (`diff --git`, `index`, `---`, `+++`) and "\ No newline at
/// end of file" are skipped.
pub fn parse_unified_diff(raw: &str) -> ParsedDiff {
    let mut result = ParsedDiff::default();
    if raw.is_empty() {
        return result;
    }
    let mut current: Option<DiffHunk> = None;
    for line in raw.split('\n') {
        if line.starts_with("@@") {
            if let Some(hunk) = current.take() {
                result.hunks.push(hunk);
            }
            let (old_start, old_count, new_start, new_count) = parse_hunk_header(line);
            current = Some(DiffHunk {
                header: line.to_string(),
                old_start,
                old_count,
                new_start,
                new_count,
                lines: vec![DiffLine::HunkHeader(line.to_string())],
            });
        } else if let Some(hunk) = current.as_mut() {
            if let Some(text) = line.strip_prefix('+') {
                hunk.lines.push(DiffLine::Addition(text.to_string()));
                result.additions += 1;
            } else if let Some(text) = line.strip_prefix('-') {
                hunk.lines.push(DiffLine::Deletion(text.to_string()));
                result.deletions += 1;
            } else if let Some(text) = line.strip_prefix(' ') {
                hunk.lines.push(DiffLine::Context(text.to_string()));
            }
        }
    }
    if let Some(hunk) = current {
        result.hunks.push(hunk);
    }
    result
}

/// Kind of a displayed diff row.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DiffRowKind {
    HunkHeader,
    Context,
    Addition,
    Deletion,
    /// The blank line after each hunk.
    Blank,
}

/// A displayed row: old and new line numbers and the text.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DiffRow {
    pub kind: DiffRowKind,
    pub old: Option<usize>,
    pub new: Option<usize>,
    pub text: String,
}

impl DiffRow {
    /// The line as Swift lays it out: `%4d %4d  ` for context,
    /// `     %4d +` for additions, `%4d      -` for deletions and five
    /// spaces before a hunk header.
    pub fn display(&self) -> String {
        match self.kind {
            DiffRowKind::HunkHeader => format!("     {}", self.text),
            DiffRowKind::Context => format!(
                "{:4} {:4}  {}",
                self.old.unwrap_or(0),
                self.new.unwrap_or(0),
                self.text
            ),
            DiffRowKind::Addition => format!("     {:4} +{}", self.new.unwrap_or(0), self.text),
            DiffRowKind::Deletion => format!("{:4}      -{}", self.old.unwrap_or(0), self.text),
            DiffRowKind::Blank => String::new(),
        }
    }
}

/// Rows of the diff pane, numbered from each hunk's start lines.
pub fn diff_rows(hunks: &[DiffHunk]) -> Vec<DiffRow> {
    let mut rows = Vec::new();
    for hunk in hunks {
        let mut old = hunk.old_start;
        let mut new = hunk.new_start;
        for line in &hunk.lines {
            let row = match line {
                DiffLine::HunkHeader(text) => DiffRow {
                    kind: DiffRowKind::HunkHeader,
                    old: None,
                    new: None,
                    text: text.clone(),
                },
                DiffLine::Context(text) => {
                    let row = DiffRow {
                        kind: DiffRowKind::Context,
                        old: Some(old),
                        new: Some(new),
                        text: text.clone(),
                    };
                    old += 1;
                    new += 1;
                    row
                }
                DiffLine::Addition(text) => {
                    let row = DiffRow {
                        kind: DiffRowKind::Addition,
                        old: None,
                        new: Some(new),
                        text: text.clone(),
                    };
                    new += 1;
                    row
                }
                DiffLine::Deletion(text) => {
                    let row = DiffRow {
                        kind: DiffRowKind::Deletion,
                        old: Some(old),
                        new: None,
                        text: text.clone(),
                    };
                    old += 1;
                    row
                }
            };
            rows.push(row);
        }
        rows.push(DiffRow {
            kind: DiffRowKind::Blank,
            old: None,
            new: None,
            text: String::new(),
        });
    }
    rows
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn empty_diff() {
        let r = parse_unified_diff("");
        assert!(r.hunks.is_empty());
        assert_eq!((r.additions, r.deletions), (0, 0));
    }

    #[test]
    fn simple_diff() {
        let diff = "diff --git a/file.swift b/file.swift\nindex abc..def 100644\n--- a/file.swift\n+++ b/file.swift\n@@ -1,3 +1,4 @@\n unchanged line\n-removed line\n+added line\n+another added line\n context line";
        let r = parse_unified_diff(diff);
        assert_eq!(r.hunks.len(), 1);
        assert_eq!((r.additions, r.deletions), (2, 1));
        let h = &r.hunks[0];
        assert_eq!(
            (h.old_start, h.old_count, h.new_start, h.new_count),
            (1, 3, 1, 4)
        );
        assert_eq!(h.lines.len(), 6);
    }

    #[test]
    fn multi_hunk_diff() {
        let diff = "@@ -10,3 +10,4 @@\n context\n+addition\n context\n@@ -30,2 +31,3 @@\n-deleted\n+replaced\n+extra";
        let r = parse_unified_diff(diff);
        assert_eq!(r.hunks.len(), 2);
        assert_eq!((r.additions, r.deletions), (3, 1));
    }

    #[test]
    fn header_without_counts_and_no_newline_marker() {
        let r = parse_unified_diff("@@ -5 +7 @@ fn x()\n-a\n\\ No newline at end of file\n+b\n");
        let h = &r.hunks[0];
        assert_eq!(
            (h.old_start, h.old_count, h.new_start, h.new_count),
            (5, 1, 7, 1)
        );
        assert_eq!(h.lines.len(), 3);
    }

    #[test]
    fn rows_are_numbered_like_swift() {
        let r = parse_unified_diff("@@ -10,2 +20,2 @@\n ctx\n-old\n+new\n");
        let rows = diff_rows(&r.hunks);
        let shown: Vec<String> = rows.iter().map(DiffRow::display).collect();
        assert_eq!(
            shown,
            vec![
                "     @@ -10,2 +20,2 @@".to_string(),
                "  10   20  ctx".into(),
                "  11      -old".into(),
                "       21 +new".into(),
                String::new(),
            ]
        );
        assert_eq!(rows.last().unwrap().kind, DiffRowKind::Blank);
    }

    #[test]
    fn modes() {
        assert_eq!(
            DiffMode::WorkingTree.git_args("a.rs"),
            ["diff", "--", "a.rs"]
        );
        assert_eq!(
            DiffMode::Staged.git_args("a.rs"),
            ["diff", "--cached", "--", "a.rs"]
        );
        assert_eq!(DiffMode::from_raw("staged"), Some(DiffMode::Staged));
        assert_eq!(DiffMode::WorkingTree.toggled(), DiffMode::Staged);
        assert_eq!(DiffMode::Staged.raw(), "staged");
    }
}
