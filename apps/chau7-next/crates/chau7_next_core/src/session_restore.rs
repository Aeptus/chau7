//! Pure logic for window and tab restore: the saved split layout, scrollback
//! capture, the shell command that replays it, and the AI session resume
//! command.
//!
//! Ports the testable parts of `Overlay/OverlayTabsModel+SessionFinder.swift`
//! (`captureScrollback`, `shellSafeSingleQuote`, `normalizedResumeCommand`,
//! `isSafeResumeCommand`, `resolveAIResumeMetadataFromSavedState`,
//! `buildAIResumeCommand`, `findCodexSessionId`) and the layout export of
//! `SplitPanes/SplitPaneController.swift` (`SavedSplitNode`).

pub mod transaction;

use std::path::{Path, PathBuf};
use std::time::UNIX_EPOCH;

use serde::{Deserialize, Serialize};

use crate::ai::resume::{
    ResumeMetadata, SessionCandidate, best_session_match, extract_metadata, is_valid_session_id,
    normalize_provider_name,
};
use crate::ai::tool_registry::AI_TOOLS;
use crate::path_rank::bidirectional_prefix_rank;

// ----- saved split layout ------------------------------------------------

/// Direction of a split. `Horizontal` places children side by side (Swift
/// `SplitDirection.horizontal`, "Split Horizontally").
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum SavedAxis {
    Horizontal,
    Vertical,
}

/// One node of a saved split tree (`SavedSplitNode`): the tree shape, the
/// ratios, the pane ids, each terminal's directory, and the file shown by
/// each editor, preview and diff pane (`textEditorPath`, `previewFilePath`,
/// `diffFilePath`, `diffDirectory`, `diffMode`).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "lowercase")]
pub enum SavedSplitNode {
    Terminal {
        id: u64,
        directory: Option<String>,
    },
    /// Text editor pane; `None` for an untitled editor.
    Editor {
        id: u64,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        path: Option<String>,
    },
    /// File preview pane; `None` when no file is shown.
    Preview {
        id: u64,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        path: Option<String>,
    },
    /// Diff viewer pane: file relative to `directory`, and the mode
    /// (`workingTree` or `staged`).
    Diff {
        id: u64,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        file: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        directory: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        mode: Option<String>,
    },
    /// Repository-scoped agent dashboard; absent scope restores an empty dashboard.
    Dashboard {
        id: u64,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        directory: Option<String>,
    },
    Repository {
        id: u64,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        directory: Option<String>,
    },
    Split {
        id: u64,
        axis: SavedAxis,
        /// Fractions summing to 1, one per child.
        ratios: Vec<f32>,
        children: Vec<SavedSplitNode>,
    },
}

impl SavedSplitNode {
    /// Ids of every terminal pane, in visual order.
    pub fn terminal_ids(&self) -> Vec<u64> {
        let mut out = Vec::new();
        self.collect_terminal_ids(&mut out);
        out
    }

    fn collect_terminal_ids(&self, out: &mut Vec<u64>) {
        match self {
            SavedSplitNode::Terminal { id, .. } => out.push(*id),
            SavedSplitNode::Editor { .. }
            | SavedSplitNode::Preview { .. }
            | SavedSplitNode::Diff { .. }
            | SavedSplitNode::Dashboard { .. }
            | SavedSplitNode::Repository { .. } => {}
            SavedSplitNode::Split { children, .. } => {
                children.iter().for_each(|c| c.collect_terminal_ids(out));
            }
        }
    }

    /// Id of a leaf (any pane kind), `None` for a split.
    pub fn leaf_id(&self) -> Option<u64> {
        match self {
            SavedSplitNode::Terminal { id, .. }
            | SavedSplitNode::Editor { id, .. }
            | SavedSplitNode::Preview { id, .. }
            | SavedSplitNode::Diff { id, .. }
            | SavedSplitNode::Dashboard { id, .. }
            | SavedSplitNode::Repository { id, .. } => Some(*id),
            SavedSplitNode::Split { .. } => None,
        }
    }

    /// The same leaf with another id.
    fn with_leaf_id(self, new_id: u64) -> SavedSplitNode {
        match self {
            SavedSplitNode::Terminal { directory, .. } => SavedSplitNode::Terminal {
                id: new_id,
                directory,
            },
            SavedSplitNode::Editor { path, .. } => SavedSplitNode::Editor { id: new_id, path },
            SavedSplitNode::Preview { path, .. } => SavedSplitNode::Preview { id: new_id, path },
            SavedSplitNode::Diff {
                file,
                directory,
                mode,
                ..
            } => SavedSplitNode::Diff {
                id: new_id,
                file,
                directory,
                mode,
            },
            SavedSplitNode::Dashboard { directory, .. } => SavedSplitNode::Dashboard {
                id: new_id,
                directory,
            },
            SavedSplitNode::Repository { directory, .. } => SavedSplitNode::Repository {
                id: new_id,
                directory,
            },
            split @ SavedSplitNode::Split { .. } => split,
        }
    }

    /// Largest pane or split id in the tree (to continue numbering after a restore).
    pub fn max_id(&self) -> u64 {
        match self {
            SavedSplitNode::Terminal { id, .. }
            | SavedSplitNode::Editor { id, .. }
            | SavedSplitNode::Preview { id, .. }
            | SavedSplitNode::Diff { id, .. }
            | SavedSplitNode::Dashboard { id, .. }
            | SavedSplitNode::Repository { id, .. } => *id,
            SavedSplitNode::Split { id, children, .. } => children
                .iter()
                .map(SavedSplitNode::max_id)
                .max()
                .unwrap_or(0)
                .max(*id),
        }
    }

    /// Repair a layout read from disk: splits with one child collapse to it,
    /// empty splits disappear, ratios are made to match the children and sum
    /// to 1, and a repeated pane id gets a fresh one. Returns `None` when no
    /// pane is left.
    pub fn normalized(self) -> Option<SavedSplitNode> {
        let mut next_id = self.max_id() + 1;
        let mut seen = std::collections::HashSet::new();
        self.normalize_inner(&mut seen, &mut next_id)
    }

    fn normalize_inner(
        self,
        seen: &mut std::collections::HashSet<u64>,
        next_id: &mut u64,
    ) -> Option<SavedSplitNode> {
        match self {
            leaf @ (SavedSplitNode::Terminal { .. }
            | SavedSplitNode::Editor { .. }
            | SavedSplitNode::Preview { .. }
            | SavedSplitNode::Diff { .. }
            | SavedSplitNode::Dashboard { .. }
            | SavedSplitNode::Repository { .. }) => {
                let id = leaf.leaf_id().unwrap_or_default();
                if seen.insert(id) {
                    Some(leaf)
                } else {
                    let fresh = *next_id;
                    *next_id += 1;
                    seen.insert(fresh);
                    Some(leaf.with_leaf_id(fresh))
                }
            }
            SavedSplitNode::Split {
                id,
                axis,
                ratios,
                children,
            } => {
                let mut kept = Vec::new();
                let mut kept_ratios = Vec::new();
                for (index, child) in children.into_iter().enumerate() {
                    if let Some(child) = child.normalize_inner(seen, next_id) {
                        kept.push(child);
                        let ratio = ratios.get(index).copied().unwrap_or(0.0);
                        kept_ratios.push(if ratio.is_finite() && ratio > 0.0 {
                            ratio
                        } else {
                            0.0
                        });
                    }
                }
                match kept.len() {
                    0 => None,
                    1 => kept.pop(),
                    count => {
                        let mut total: f32 = kept_ratios.iter().sum();
                        if total <= 0.0 {
                            kept_ratios = vec![1.0; count];
                            total = count as f32;
                        }
                        let ratios = kept_ratios.iter().map(|r| r / total).collect();
                        Some(SavedSplitNode::Split {
                            id,
                            axis,
                            ratios,
                            children: kept,
                        })
                    }
                }
            }
        }
    }
}

// ----- scrollback ------------------------------------------------------

/// Most bytes of scrollback kept for one pane.
pub const MAX_SCROLLBACK_BYTES: usize = 500_000;

/// Largest value of the "Restored Scrollback" setting.
pub const MAX_RESTORED_SCROLLBACK_LINES: usize = 10_000;

/// Default of the "Restored Scrollback" setting (`restoredScrollbackLines`).
pub const DEFAULT_RESTORED_SCROLLBACK_LINES: usize = 500;

/// The last `max_lines` lines of a terminal buffer, ready to be replayed
/// (`captureScrollback`). ANSI exports keep their styles and column spacing.
/// Plain fallback rows drop padding; restore artifacts and trailing empty rows
/// are removed, and the persisted UTF-8 buffer never exceeds the byte limit.
pub fn capture_scrollback(text: &str, max_lines: usize) -> Option<String> {
    if max_lines == 0 {
        return None;
    }
    let styled = text.contains('\u{1b}');
    let text = if styled {
        text.to_string()
    } else {
        text.replace('\t', " ")
    };
    let mut lines: Vec<&str> = text
        .split('\n')
        .map(|line| if styled { line } else { line.trim_end() })
        .filter(|line| !is_restore_artifact(&visible_for_restore(line)))
        .collect();
    while lines
        .last()
        .is_some_and(|line| visible_for_restore(line).is_empty())
    {
        lines.pop();
    }
    if lines.is_empty() {
        return None;
    }
    if lines.len() > max_lines {
        lines = lines.split_off(lines.len() - max_lines);
    }
    if visible_for_restore(&lines.join("\n")).trim().is_empty() {
        return None;
    }
    // Keep halving old rows until the strict byte bound is met. A single
    // oversized row cannot be persisted safely without splitting ANSI or UTF-8.
    loop {
        let restored = lines.join("\n");
        if restored.len() <= MAX_SCROLLBACK_BYTES {
            return Some(restored);
        }
        if lines.len() <= 1 {
            return None;
        }
        lines = lines.split_off(lines.len() - (lines.len() / 2).max(1));
    }
}

/// Prefer the ANSI export and only capture a plain fallback when it is empty.
pub fn capture_styled_scrollback(
    styled: Option<&str>,
    fallback: impl FnOnce() -> String,
    max_lines: usize,
) -> Option<String> {
    if max_lines == 0 {
        return None;
    }
    match styled.filter(|text| !text.is_empty()) {
        Some(text) => capture_scrollback(text, max_lines),
        None => capture_scrollback(&fallback(), max_lines),
    }
}

/// Strip terminal control sequences without collapsing spaces. Matching restore
/// artifacts must not rewrite actual styled output or column alignment.
pub fn visible_for_restore(text: &str) -> String {
    let mut chars = text.chars().peekable();
    let mut result = String::with_capacity(text.len());
    while let Some(c) = chars.next() {
        if c != '\u{1b}' {
            if matches!(c, '\n' | '\r' | '\t') || (c >= ' ' && c != '\u{7f}') {
                result.push(c);
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
    result
}
fn is_restore_artifact(line: &str) -> bool {
    let line = line.trim_matches(crate::escape_sanitizer::is_foundation_whitespace);
    (line.contains("stty -echo") && line.contains("stty echo"))
        || (line.contains(" cd '") && line.ends_with("&& clear"))
        || (line.contains("%  cd '/") && line.ends_with('\''))
        || (line.contains("stty -echo; cd '") && line.contains("; stty echo"))
}

/// Name of the temporary replay files (`restore-<token>-<pane>.txt`); the
/// restore line that `cat`s one shows up in the terminal text.
pub const REPLAY_FILE_PREFIX: &str = "restore-";

/// Remove the echoed restore lines (see [`restore_input`]) from terminal
/// text, so they do not pile up in the scrollback across launches. A line
/// holding a replay file name is dropped together with the rows that follow
/// it up to the end of the command (the screen wipe), at most 8 rows.
pub fn strip_restore_commands(text: &str) -> String {
    let marker = format!("/{REPLAY_FILE_PREFIX}");
    let lines: Vec<&str> = text.split('\n').collect();
    let mut out: Vec<&str> = Vec::with_capacity(lines.len());
    let mut i = 0;
    while i < lines.len() {
        if lines[i].contains(&marker) && lines[i].contains(" cat ") {
            let end = (i..lines.len().min(i + 8)).find(|j| lines[*j].contains("[2J'"));
            if let Some(end) = end {
                i = end + 1;
                continue;
            }
        }
        if !is_restore_artifact(&visible_for_restore(lines[i])) {
            out.push(lines[i]);
        }
        i += 1;
    }
    out.join("\n")
}

/// True for the command line [`restore_input`] types (seen without its
/// leading space and newline), so the session can keep it out of the
/// command results: a restored tab must not look like it ran a command.
pub fn is_restore_line(command: &str) -> bool {
    let command = command.trim();
    (command.starts_with("cat '") || command.starts_with("cd '")) && command.ends_with(CLEAR_SCREEN)
}

/// `'...'` with embedded single quotes escaped (`shellSafeSingleQuote`).
pub fn shell_safe_single_quote(value: &str) -> String {
    format!("'{}'", value.replace('\'', "'\\''"))
}

/// Home the cursor and erase the screen, keeping the scrollback (macOS `clear`).
const CLEAR_SCREEN: &str = "printf '\\033[H\\033[2J'";

/// The line typed into a restored shell: replay the saved scrollback through
/// `cat` (so it reflows to the current width), delete the temporary copy,
/// `cd` to the saved directory and clear the screen. The leading space keeps
/// it out of the shell history (zsh `HIST_IGNORE_SPACE`, bash `ignorespace`).
/// `None` when there is nothing to replay.
///
/// Swift types `clear`, which on macOS only wipes the visible screen and keeps
/// the replayed text in the scrollback. `clear` on Linux also wipes the
/// scrollback (terminfo `E3`), so the same screen wipe is sent directly.
pub fn restore_input(replay_file: Option<&Path>, directory: Option<&str>) -> Option<String> {
    let mut commands: Vec<String> = Vec::new();
    if let Some(file) = replay_file {
        let quoted = shell_safe_single_quote(&file.to_string_lossy());
        commands.push(format!("cat {quoted} && rm -f {quoted}"));
    }
    if let Some(dir) = directory.filter(|d| !d.is_empty()) {
        commands.push(format!("cd {}", shell_safe_single_quote(dir)));
    }
    if commands.is_empty() {
        return None;
    }
    Some(format!(" {} && {CLEAR_SCREEN}\n", commands.join(" && ")))
}

// ----- AI session resume -----------------------------------------------

/// `claude --resume <id>` or `codex resume <id>` (`buildAIResumeCommand`).
pub fn build_ai_resume_command(provider: Option<&str>, session_id: Option<&str>) -> Option<String> {
    let provider = normalize_provider_name(provider?)?;
    let session_id = session_id?.trim();
    if !is_valid_session_id(session_id) {
        return None;
    }
    let tool = AI_TOOLS
        .iter()
        .find(|t| t.resume_provider_key == Some(provider.as_str()))?;
    Some(tool.resume_format?.build_command(session_id))
}

/// A resume command that is exactly one of the known forms with a valid id
/// (`isSafeResumeCommand`).
pub fn is_safe_resume_command(command: &str) -> bool {
    for prefix in ["claude --resume ", "codex resume "] {
        if let Some(rest) = command.strip_prefix(prefix) {
            return !rest.trim().is_empty() && is_valid_session_id(rest);
        }
    }
    false
}

/// The trimmed command when it is a safe resume command
/// (`normalizedResumeCommand`).
pub fn normalized_resume_command(value: Option<&str>) -> Option<String> {
    let trimmed = value?.trim();
    if trimmed.is_empty() || !is_safe_resume_command(trimmed) {
        return None;
    }
    Some(trimmed.to_string())
}

/// Provider and session id from what was saved for a pane: the explicit
/// fields first, then the saved command (`resolveAIResumeMetadataFromSavedState`).
pub fn resolve_resume_metadata_from_saved(
    provider: Option<&str>,
    session_id: Option<&str>,
    command: Option<&str>,
) -> Option<ResumeMetadata> {
    let from_command = extract_metadata(command.unwrap_or(""));
    let provider = provider
        .and_then(normalize_provider_name)
        .or_else(|| from_command.as_ref().map(|m| m.provider.clone()))?;
    let session_id = session_id
        .map(str::trim)
        .filter(|s| is_valid_session_id(s))
        .map(str::to_string)
        .or_else(|| from_command.map(|m| m.session_id))?;
    Some(ResumeMetadata {
        provider,
        session_id,
    })
}

pub(crate) fn modified_secs(path: &Path) -> f64 {
    std::fs::metadata(path)
        .and_then(|m| m.modified())
        .ok()
        .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
        .map(|d| d.as_secs_f64())
        .unwrap_or(crate::ai::resume::DISTANT_PAST)
}

/// Directory name Claude Code uses under `~/.claude/projects` for a working
/// directory: every character other than letters and digits becomes `-`.
pub fn claude_project_dir_name(directory: &str) -> String {
    directory
        .chars()
        .map(|c| if c.is_ascii_alphanumeric() { c } else { '-' })
        .collect()
}

/// Claude Code sessions recorded for `directory` (or the nearest ancestor
/// that has any), most recently touched first.
///
/// Swift reads the live hook events of `ClaudeCodeMonitor`; without that
/// monitor this reads the transcripts Claude Code writes itself
/// (`~/.claude/projects/<directory>/<session id>.jsonl`).
pub fn claude_session_candidates(home: &Path, directory: &str) -> Vec<SessionCandidate> {
    let mut dir = Path::new(directory.trim_end_matches('/'));
    loop {
        if dir.as_os_str().is_empty() || dir == Path::new("/") || dir == home {
            return Vec::new();
        }
        let found =
            crate::monitoring::claude_resolver::session_candidates(home, &dir.to_string_lossy());
        if !found.is_empty() {
            return found;
        }
        match dir.parent() {
            Some(parent) => dir = parent,
            None => return Vec::new(),
        }
    }
}

/// `session_meta` first line of a Codex session file: working directory and
/// session id (`parseCodexSessionMeta`).
pub fn parse_codex_session_meta(line: &str) -> Option<(String, String)> {
    let json: serde_json::Value = serde_json::from_str(line).ok()?;
    if json.get("type")?.as_str()? != "session_meta" {
        return None;
    }
    let payload = json.get("payload")?;
    let cwd = payload.get("cwd")?.as_str()?.trim().to_string();
    let id = payload.get("id")?.as_str()?.trim().to_string();
    if cwd.is_empty() || !is_valid_session_id(&id) {
        return None;
    }
    Some((cwd, id))
}

/// First line of a file, reading at most 256 KiB (`readFirstLine`).
pub(crate) fn read_first_line(path: &Path) -> Option<String> {
    use std::io::Read;
    const CAP: usize = 262_144;
    let file = std::fs::File::open(path).ok()?;
    let mut buffer = Vec::new();
    file.take(CAP as u64 + 1).read_to_end(&mut buffer).ok()?;
    if let Some(end) = buffer.iter().position(|b| *b == b'\n') {
        buffer.truncate(end);
    } else if buffer.len() > CAP {
        return None;
    }
    if buffer.is_empty() {
        return None;
    }
    Some(String::from_utf8_lossy(&buffer).into_owned())
}

pub(crate) fn numeric_children(dir: &Path) -> Vec<PathBuf> {
    let mut names: Vec<String> = std::fs::read_dir(dir)
        .map(|rd| {
            rd.flatten()
                .filter_map(|e| e.file_name().into_string().ok())
                .filter(|n| !n.is_empty() && n.chars().all(|c| c.is_ascii_digit()))
                .collect()
        })
        .unwrap_or_default();
    names.sort();
    names.reverse();
    names.into_iter().map(|n| dir.join(n)).collect()
}

/// Codex sessions started in `directory` (or inside it, or above it): scans
/// the 7 most recent day folders of `~/.codex/sessions`, at most 30 files
/// (`findCodexSessionId`). Only the closest directory match is kept.
pub fn codex_session_candidates(home: &Path, directory: &str) -> Vec<SessionCandidate> {
    let sessions = home.join(".codex").join("sessions");
    let mut day_dirs = Vec::new();
    for year in numeric_children(&sessions) {
        for month in numeric_children(&year) {
            day_dirs.extend(numeric_children(&month));
        }
    }
    let mut reads = 0;
    let mut matches: Vec<(SessionCandidate, u8)> = Vec::new();
    'days: for day in day_dirs.into_iter().take(7) {
        let mut files: Vec<String> = std::fs::read_dir(&day)
            .map(|rd| {
                rd.flatten()
                    .filter_map(|e| e.file_name().into_string().ok())
                    .filter(|n| n.ends_with(".jsonl"))
                    .collect()
            })
            .unwrap_or_default();
        files.sort();
        files.reverse();
        for file in files {
            if reads >= 30 {
                break 'days;
            }
            reads += 1;
            let path = day.join(&file);
            let Some(line) = read_first_line(&path) else {
                continue;
            };
            let Some((cwd, id)) = parse_codex_session_meta(&line) else {
                continue;
            };
            let Some(rank) = bidirectional_prefix_rank(directory, &cwd) else {
                continue;
            };
            matches.push((
                SessionCandidate {
                    session_id: id,
                    touched_at: modified_secs(&path),
                },
                rank,
            ));
        }
    }
    let Some(best) = matches.iter().map(|(_, r)| *r).min() else {
        return Vec::new();
    };
    let mut out: Vec<SessionCandidate> = matches
        .into_iter()
        .filter(|(_, r)| *r == best)
        .map(|(c, _)| c)
        .collect();
    out.sort_by(|a, b| b.touched_at.total_cmp(&a.touched_at));
    out
}

/// Session id of the AI tool `provider` ("claude" or "codex") that ran in
/// `directory`, skipping ids already given to another pane. When several
/// sessions match, the one touched closest to `reference_date` (the pane's
/// last output, Unix seconds) wins; with no usable reference nothing is
/// guessed (`findAIResumeSessionId`).
pub fn find_ai_resume_session_id(
    home: &Path,
    provider: &str,
    directory: &str,
    reference_date: Option<f64>,
    claimed: &std::collections::HashSet<String>,
) -> Option<String> {
    let candidates = match provider {
        "claude" => claude_session_candidates(home, directory),
        "codex" => codex_session_candidates(home, directory),
        _ => return None,
    };
    let candidates: Vec<SessionCandidate> = candidates
        .into_iter()
        .filter(|c| !claimed.contains(&c.session_id))
        .collect();
    best_session_match(&candidates, reference_date)
}

/// Provider and session id for a pane running an AI tool (`resolveResumeMetadata`
/// reduced to the part that does not need Swift's monitors): `app_name` is the
/// tool detected in the pane, `directory` its working directory.
pub fn resolve_ai_resume_metadata(
    home: &Path,
    app_name: Option<&str>,
    directory: &str,
    reference_date: Option<f64>,
    claimed: &std::collections::HashSet<String>,
) -> Option<ResumeMetadata> {
    let provider = normalize_provider_name(app_name?)?;
    let session_id =
        find_ai_resume_session_id(home, &provider, directory, reference_date, claimed)?;
    Some(ResumeMetadata {
        provider,
        session_id,
    })
}

#[cfg(test)]
mod tests {
    #[test]
    fn styled_restore_prefers_ansi_and_removes_only_visible_restore_artifacts() {
        let red = "\x1b[31mred output\x1b[0m";
        let green = "\x1b[32mgreen output\x1b[0m";
        let artifact =
            "\x1b[2m stty -echo && cat '/tmp/chau7_restore.txt' && clear && stty echo\x1b[0m";
        let bare_cd = "\x1b[2m%  cd '/some/repository'\x1b[0m";
        let source = [red, artifact, bare_cd, green].join("\n");
        let expected = [red, green].join("\n");
        assert_eq!(super::strip_restore_commands(&source), expected);
        assert_eq!(
            super::capture_styled_scrollback(
                Some(&source),
                || panic!("styled snapshot must not request fallback"),
                10
            ),
            Some(expected)
        );
        assert_eq!(
            super::capture_styled_scrollback(Some(""), || "plain output".into(), 10),
            Some("plain output".into())
        );
        assert_eq!(super::capture_scrollback("\x1b[0m", 10), None);
    }
    #[test]
    fn persisted_scrollback_has_a_strict_utf8_byte_cap() {
        let rows = (0..8)
            .map(|i| format!("line-{i}-{}", "界".repeat(100_000)))
            .collect::<Vec<_>>();
        let retained = super::capture_scrollback(&rows.join("\n"), 8).unwrap();
        assert!(retained.len() <= super::MAX_SCROLLBACK_BYTES);
        assert_eq!(retained, rows[7]);
        assert!(
            super::capture_scrollback(&"x".repeat(super::MAX_SCROLLBACK_BYTES + 1), 10).is_none()
        );
        assert_eq!(
            super::visible_for_restore("\x1b]8;;https://example.invalid\x1b\\a   b\x1b]8;;\x07"),
            "a   b"
        );
    }

    use super::*;

    #[test]
    fn dashboard_layout_roundtrips_scopes_and_missing_scope() {
        for directory in [None, Some(String::new()), Some("/tmp/project".into())] {
            let node = SavedSplitNode::Dashboard { id: 17, directory };
            let encoded = serde_json::to_string(&node).unwrap();
            assert_eq!(
                serde_json::from_str::<SavedSplitNode>(&encoded).unwrap(),
                node
            );
            assert!(node.terminal_ids().is_empty());
            assert_eq!(node.leaf_id(), Some(17));
        }
        assert_eq!(
            serde_json::from_str::<SavedSplitNode>(r#"{"type":"dashboard","id":42}"#).unwrap(),
            SavedSplitNode::Dashboard {
                id: 42,
                directory: None
            }
        );
    }
    #[test]
    fn dashboard_normalization_preserves_scope_repository_editor_and_terminal() {
        let dashboard = SavedSplitNode::Dashboard {
            id: 2,
            directory: Some("/tmp/project".into()),
        };
        let node = SavedSplitNode::Split {
            id: 1,
            axis: SavedAxis::Horizontal,
            ratios: vec![0.25; 4],
            children: vec![
                dashboard,
                SavedSplitNode::Repository {
                    id: 2,
                    directory: Some("/tmp/other".into()),
                },
                SavedSplitNode::Editor {
                    id: 2,
                    path: Some("/tmp/plan.md".into()),
                },
                SavedSplitNode::Terminal {
                    id: 2,
                    directory: Some("/tmp/shell".into()),
                },
            ],
        }
        .normalized()
        .unwrap();
        assert_eq!(node.terminal_ids().len(), 1);
        let SavedSplitNode::Split { children, .. } = node else {
            panic!("expected split")
        };
        let ids: HashSet<_> = children
            .iter()
            .filter_map(SavedSplitNode::leaf_id)
            .collect();
        assert_eq!(ids.len(), 4);
        assert!(
            matches!(&children[0],SavedSplitNode::Dashboard{directory:Some(root),..} if root=="/tmp/project")
        );
        assert!(
            matches!(&children[1],SavedSplitNode::Repository{directory:Some(root),..} if root=="/tmp/other")
        );
        assert!(
            matches!(&children[2],SavedSplitNode::Editor{path:Some(path),..} if path=="/tmp/plan.md")
        );
    }
    #[test]
    fn repository_layout_roundtrips_and_normalizes_duplicate_ids() {
        let node = SavedSplitNode::Repository {
            id: 17,
            directory: Some("/tmp/repository".into()),
        };
        let encoded = serde_json::to_string(&node).unwrap();
        assert_eq!(
            serde_json::from_str::<SavedSplitNode>(&encoded).unwrap(),
            node
        );
        assert!(node.terminal_ids().is_empty());
        let normalized = SavedSplitNode::Split {
            id: 1,
            axis: SavedAxis::Horizontal,
            ratios: vec![0.5, 0.5],
            children: vec![node.clone(), node],
        }
        .normalized()
        .unwrap();
        if let SavedSplitNode::Split { children, .. } = normalized {
            assert_ne!(children[0].leaf_id(), children[1].leaf_id());
        } else {
            panic!("expected split");
        }
    }
    #[test]
    fn captured_scrollback_has_no_tabs() {
        let text = "alpha  delta.json\t epsilon\n$ ";
        assert_eq!(
            capture_scrollback(text, 10).as_deref(),
            Some("alpha  delta.json  epsilon\n$")
        );
    }
    use std::collections::HashSet;

    fn leaf(id: u64) -> SavedSplitNode {
        SavedSplitNode::Terminal {
            id,
            directory: Some(format!("/tmp/{id}")),
        }
    }

    #[test]
    fn capture_strips_padding_and_trailing_blank_lines() {
        let text = "one   \ntwo\t \n\n   \n";
        assert_eq!(capture_scrollback(text, 10).as_deref(), Some("one\ntwo"));
    }

    #[test]
    fn capture_keeps_only_the_last_lines() {
        let text = "a\nb\nc\nd\n";
        assert_eq!(capture_scrollback(text, 2).as_deref(), Some("c\nd"));
    }

    #[test]
    fn capture_zero_lines_or_blank_buffer_is_none() {
        assert_eq!(capture_scrollback("a\nb", 0), None);
        assert_eq!(capture_scrollback("  \n \n\n", 10), None);
        assert_eq!(capture_scrollback("", 10), None);
    }

    #[test]
    fn capture_halves_oversized_buffers() {
        let line = "x".repeat(1000);
        let text = vec![line.as_str(); 700].join("\n");
        let captured = capture_scrollback(&text, 700).unwrap();
        assert_eq!(captured.split('\n').count(), 350);
    }

    #[test]
    fn restore_lines_are_stripped_from_captured_text() {
        let line = restore_input(
            Some(Path::new("/state/scrollback/restore-ab-12.txt")),
            Some("/tmp"),
        )
        .unwrap();
        // The terminal wraps the typed line over two rows.
        let (a, b) = line.trim_end().split_at(40);
        let text = format!("old output\nuser@host:~# {a}\n{b}\nrestored 1\nuser@host:~#\n");
        assert_eq!(
            strip_restore_commands(&text),
            "old output\nrestored 1\nuser@host:~#\n"
        );
        assert_eq!(strip_restore_commands("a\nb"), "a\nb");
        // Not followed by the end of the command: kept.
        let kept = "user@host:~# cat '/s/restore-1-2.txt'\nnothing else";
        assert_eq!(strip_restore_commands(kept), kept);
    }

    #[test]
    fn single_quote_escaping() {
        assert_eq!(shell_safe_single_quote("a b"), "'a b'");
        assert_eq!(shell_safe_single_quote("it's"), "'it'\\''s'");
    }

    #[test]
    fn restore_input_replays_then_cds_then_clears() {
        let line = restore_input(Some(Path::new("/tmp/a b.txt")), Some("/home/me/x y")).unwrap();
        assert_eq!(
            line,
            " cat '/tmp/a b.txt' && rm -f '/tmp/a b.txt' && cd '/home/me/x y' && printf '\\033[H\\033[2J'\n"
        );
        assert_eq!(
            restore_input(None, Some("/tmp")).unwrap(),
            " cd '/tmp' && printf '\\033[H\\033[2J'\n"
        );
        assert_eq!(restore_input(None, None), None);
        assert_eq!(restore_input(None, Some("")), None);
    }

    #[test]
    fn restore_line_is_recognized() {
        let line = restore_input(Some(Path::new("/tmp/a b.txt")), Some("/home/me")).unwrap();
        assert!(is_restore_line(&line));
        assert!(is_restore_line(line.trim()));
        assert!(is_restore_line(&restore_input(None, Some("/tmp")).unwrap()));
        assert!(!is_restore_line("cd /tmp"));
        assert!(!is_restore_line("ls"));
        assert!(!is_restore_line("cat '/x' && echo hi"));
    }

    #[test]
    fn resume_commands() {
        assert_eq!(
            build_ai_resume_command(Some("claude"), Some("abc-123")).as_deref(),
            Some("claude --resume abc-123")
        );
        assert_eq!(
            build_ai_resume_command(Some("Codex"), Some("xyz")).as_deref(),
            Some("codex resume xyz")
        );
        assert_eq!(build_ai_resume_command(Some("claude"), Some("a b")), None);
        assert_eq!(build_ai_resume_command(Some("gemini"), Some("abc")), None);
        assert_eq!(build_ai_resume_command(None, Some("abc")), None);
    }

    #[test]
    fn safe_resume_commands() {
        assert!(is_safe_resume_command("claude --resume abc-123"));
        assert!(is_safe_resume_command("codex resume abc_1"));
        assert!(!is_safe_resume_command("claude --resume abc; rm -rf /"));
        assert!(!is_safe_resume_command("claude --resume "));
        assert!(!is_safe_resume_command("echo claude --resume abc"));
        assert_eq!(
            normalized_resume_command(Some("  codex resume abc \n")).as_deref(),
            Some("codex resume abc")
        );
        assert_eq!(normalized_resume_command(Some("rm -rf /")), None);
        assert_eq!(normalized_resume_command(None), None);
    }

    #[test]
    fn saved_metadata_prefers_fields_over_command() {
        let m = resolve_resume_metadata_from_saved(
            Some("codex"),
            Some("fields-id"),
            Some("claude --resume cmd-id"),
        )
        .unwrap();
        assert_eq!(
            (m.provider.as_str(), m.session_id.as_str()),
            ("codex", "fields-id")
        );
        let m =
            resolve_resume_metadata_from_saved(None, None, Some("claude --resume cmd-id")).unwrap();
        assert_eq!(
            (m.provider.as_str(), m.session_id.as_str()),
            ("claude", "cmd-id")
        );
        assert!(resolve_resume_metadata_from_saved(Some("claude"), None, None).is_none());
    }

    #[test]
    fn layout_round_trips_and_lists_terminals() {
        let layout = SavedSplitNode::Split {
            id: 9,
            axis: SavedAxis::Horizontal,
            ratios: vec![0.3, 0.7],
            children: vec![leaf(1), leaf(2)],
        };
        let json = serde_json::to_string(&layout).unwrap();
        let back: SavedSplitNode = serde_json::from_str(&json).unwrap();
        assert_eq!(back, layout);
        assert_eq!(back.terminal_ids(), vec![1, 2]);
        assert_eq!(back.max_id(), 9);
    }

    #[test]
    fn normalize_collapses_and_fixes_ratios() {
        let layout = SavedSplitNode::Split {
            id: 5,
            axis: SavedAxis::Vertical,
            ratios: vec![2.0, 6.0, 1.0],
            children: vec![
                leaf(1),
                SavedSplitNode::Split {
                    id: 6,
                    axis: SavedAxis::Horizontal,
                    ratios: vec![1.0],
                    children: vec![leaf(2)],
                },
                SavedSplitNode::Split {
                    id: 7,
                    axis: SavedAxis::Horizontal,
                    ratios: vec![],
                    children: vec![],
                },
            ],
        };
        let SavedSplitNode::Split {
            ratios, children, ..
        } = layout.normalized().unwrap()
        else {
            panic!("expected a split");
        };
        assert_eq!(children, vec![leaf(1), leaf(2)]);
        assert!((ratios[0] - 0.25).abs() < 1e-6 && (ratios[1] - 0.75).abs() < 1e-6);
    }

    #[test]
    fn normalize_renumbers_duplicate_pane_ids() {
        let layout = SavedSplitNode::Split {
            id: 3,
            axis: SavedAxis::Horizontal,
            ratios: vec![0.5, 0.5],
            children: vec![leaf(1), leaf(1)],
        };
        let ids = layout.normalized().unwrap().terminal_ids();
        assert_eq!(ids.len(), 2);
        assert_ne!(ids[0], ids[1]);
    }

    #[test]
    fn other_pane_kinds_round_trip_and_old_layouts_load() {
        let layout = SavedSplitNode::Split {
            id: 10,
            axis: SavedAxis::Horizontal,
            ratios: vec![0.25, 0.25, 0.25, 0.25],
            children: vec![
                leaf(1),
                SavedSplitNode::Editor {
                    id: 2,
                    path: Some("/test.swift".into()),
                },
                SavedSplitNode::Preview {
                    id: 3,
                    path: Some("/test/image.png".into()),
                },
                SavedSplitNode::Diff {
                    id: 4,
                    file: Some("src/main.swift".into()),
                    directory: Some("/Users/test/project".into()),
                    mode: Some("staged".into()),
                },
            ],
        };
        let json = serde_json::to_string(&layout).unwrap();
        assert!(json.contains(r#""type":"diff""#) && json.contains(r#""mode":"staged""#));
        let back: SavedSplitNode = serde_json::from_str(&json).unwrap();
        assert_eq!(back, layout);
        assert_eq!(back.terminal_ids(), vec![1]);
        // An editor saved without a path (untitled) still loads.
        let untitled: SavedSplitNode = serde_json::from_str(r#"{"type":"editor","id":5}"#).unwrap();
        assert_eq!(untitled, SavedSplitNode::Editor { id: 5, path: None });
        let diff: SavedSplitNode = serde_json::from_str(r#"{"type":"diff","id":6}"#).unwrap();
        assert_eq!(diff.leaf_id(), Some(6));
        // Duplicate ids are renumbered whatever the kind.
        let dup = SavedSplitNode::Split {
            id: 7,
            axis: SavedAxis::Vertical,
            ratios: vec![0.5, 0.5],
            children: vec![leaf(1), SavedSplitNode::Editor { id: 1, path: None }],
        };
        let SavedSplitNode::Split { children, .. } = dup.normalized().unwrap() else {
            panic!("expected a split");
        };
        assert_ne!(children[0].leaf_id(), children[1].leaf_id());
        assert!(matches!(children[1], SavedSplitNode::Editor { .. }));
    }

    #[test]
    fn normalize_of_empty_split_is_none() {
        let layout = SavedSplitNode::Split {
            id: 1,
            axis: SavedAxis::Horizontal,
            ratios: vec![],
            children: vec![],
        };
        assert!(layout.normalized().is_none());
    }

    #[test]
    fn claude_dir_name() {
        assert_eq!(
            claude_project_dir_name("/home/me/my.proj"),
            "-home-me-my-proj"
        );
    }

    fn temp_home(name: &str) -> PathBuf {
        let dir =
            std::env::temp_dir().join(format!("chau7-next-restore-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn finds_claude_session_in_project_folder() {
        let home = temp_home("claude");
        let folder = home.join(".claude/projects/-work-app");
        std::fs::create_dir_all(&folder).unwrap();
        std::fs::write(folder.join("sess-1.jsonl"), "{}\n").unwrap();
        let found = find_ai_resume_session_id(&home, "claude", "/work/app", None, &HashSet::new());
        assert_eq!(found.as_deref(), Some("sess-1"));
        // A sub directory finds the session started above it.
        let found =
            find_ai_resume_session_id(&home, "claude", "/work/app/src", None, &HashSet::new());
        assert_eq!(found.as_deref(), Some("sess-1"));
        // Claimed by another pane: nothing is guessed.
        let claimed: HashSet<String> = ["sess-1".to_string()].into();
        assert_eq!(
            find_ai_resume_session_id(&home, "claude", "/work/app", None, &claimed),
            None
        );
        let _ = std::fs::remove_dir_all(&home);
    }

    #[test]
    fn two_claude_sessions_without_reference_are_not_guessed() {
        let home = temp_home("claude2");
        let folder = home.join(".claude/projects/-work-app");
        std::fs::create_dir_all(&folder).unwrap();
        std::fs::write(folder.join("a.jsonl"), "{}\n").unwrap();
        std::fs::write(folder.join("b.jsonl"), "{}\n").unwrap();
        assert_eq!(
            find_ai_resume_session_id(&home, "claude", "/work/app", None, &HashSet::new()),
            None
        );
        let _ = std::fs::remove_dir_all(&home);
    }

    #[test]
    fn finds_codex_session_by_cwd() {
        let home = temp_home("codex");
        let day = home.join(".codex/sessions/2026/10/10");
        std::fs::create_dir_all(&day).unwrap();
        std::fs::write(
            day.join("rollout-1.jsonl"),
            "{\"type\":\"session_meta\",\"payload\":{\"id\":\"cdx-1\",\"cwd\":\"/work/app\"}}\n{}\n",
        )
        .unwrap();
        std::fs::write(
            day.join("rollout-0.jsonl"),
            "{\"type\":\"session_meta\",\"payload\":{\"id\":\"other\",\"cwd\":\"/elsewhere\"}}\n",
        )
        .unwrap();
        let found = find_ai_resume_session_id(&home, "codex", "/work/app", None, &HashSet::new());
        assert_eq!(found.as_deref(), Some("cdx-1"));
        assert_eq!(
            find_ai_resume_session_id(&home, "codex", "/nowhere", None, &HashSet::new()),
            None
        );
        let _ = std::fs::remove_dir_all(&home);
    }

    #[test]
    fn parses_codex_session_meta() {
        let line = "{\"type\":\"session_meta\",\"payload\":{\"id\":\"abc\",\"cwd\":\"/x\"}}";
        assert_eq!(
            parse_codex_session_meta(line),
            Some(("/x".to_string(), "abc".to_string()))
        );
        assert_eq!(parse_codex_session_meta("{\"type\":\"other\"}"), None);
        assert_eq!(parse_codex_session_meta("nope"), None);
    }

    #[test]
    fn resolve_metadata_needs_a_known_tool() {
        let home = temp_home("resolve");
        let folder = home.join(".claude/projects/-work-app");
        std::fs::create_dir_all(&folder).unwrap();
        std::fs::write(folder.join("s1.jsonl"), "{}\n").unwrap();
        let m =
            resolve_ai_resume_metadata(&home, Some("Claude"), "/work/app", None, &HashSet::new())
                .unwrap();
        assert_eq!(
            (m.provider.as_str(), m.session_id.as_str()),
            ("claude", "s1")
        );
        assert!(
            resolve_ai_resume_metadata(&home, Some("Gemini"), "/work/app", None, &HashSet::new())
                .is_none()
        );
        assert!(
            resolve_ai_resume_metadata(&home, None, "/work/app", None, &HashSet::new()).is_none()
        );
        let _ = std::fs::remove_dir_all(&home);
    }
}
