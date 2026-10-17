//! A single command execution block in the terminal.
//!
//! Ports `apps/chau7-macos/Sources/Chau7Core/CommandBlock.swift`: command
//! text, line range, timing and exit status. The JSON form matches Swift's
//! default `Codable` output (camelCase keys, `Date` as seconds since
//! 2001-01-01, nil optionals omitted, uppercase UUID).

use crate::iso8601::{adding_seconds, reference_date, reference_date_opt, seconds_between};
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CommandBlock {
    #[serde(with = "crate::iso8601::uuid_upper")]
    pub id: Uuid,
    pub command: String,
    pub start_line: i64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub end_line: Option<i64>,
    #[serde(with = "reference_date")]
    pub start_time: DateTime<Utc>,
    #[serde(
        default,
        skip_serializing_if = "Option::is_none",
        with = "reference_date_opt"
    )]
    pub end_time: Option<DateTime<Utc>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub exit_code: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub directory: Option<String>,
    /// Files changed during this command (git diff snapshot). Empty if not a
    /// git repo or the command has not finished.
    #[serde(default)]
    pub changed_files: Vec<String>,
}

impl CommandBlock {
    /// A running block that starts now, with a fresh id.
    pub fn new(command: impl Into<String>, start_line: i64) -> Self {
        Self {
            id: Uuid::new_v4(),
            command: command.into(),
            start_line,
            end_line: None,
            start_time: Utc::now(),
            end_time: None,
            exit_code: None,
            directory: None,
            changed_files: Vec::new(),
        }
    }

    /// Still executing: neither end line nor end time recorded.
    pub fn is_running(&self) -> bool {
        self.end_line.is_none() && self.end_time.is_none()
    }

    /// Completed with exit code 0.
    pub fn is_success(&self) -> bool {
        self.exit_code == Some(0)
    }

    /// Completed with a non-zero exit code.
    pub fn is_failed(&self) -> bool {
        matches!(self.exit_code, Some(code) if code != 0)
    }

    /// Wall-clock duration in seconds, once finished.
    pub fn duration(&self) -> Option<f64> {
        self.end_time
            .map(|end| seconds_between(end, self.start_time))
    }

    /// Human-readable duration (`500ms`, `3.2s`, `2m 15s`, `1h 5m`); empty
    /// while running.
    pub fn duration_string(&self) -> String {
        let Some(d) = self.duration() else {
            return String::new();
        };
        if d < 1.0 {
            format!("{:.0}ms", d * 1000.0)
        } else if d < 60.0 {
            format!("{d:.1}s")
        } else if d < 3600.0 {
            let whole = d as i64;
            format!("{}m {}s", whole / 60, whole % 60)
        } else {
            let whole = d as i64;
            format!("{}h {}m", whole / 3600, (whole % 3600) / 60)
        }
    }

    /// Number of terminal lines the block spans (`None` while running).
    pub fn line_count(&self) -> Option<i64> {
        self.end_line.map(|end| end - self.start_line + 1)
    }

    /// Convenience for tests and callers: end time `seconds` after the start.
    pub fn finish_after(&mut self, seconds: f64) {
        self.end_time = Some(adding_seconds(self.start_time, seconds));
    }
}

/// Command blocks of one terminal session, oldest first
/// (`CommandBlockManager.swift`, one list per tab).
#[derive(Debug, Clone, Default, PartialEq)]
pub struct CommandBlockList {
    blocks: Vec<CommandBlock>,
}

impl CommandBlockList {
    /// Blocks kept per tab (`CommandBlockManager.maxBlocksPerTab`).
    pub const MAX_BLOCKS: usize = 200;

    pub fn new() -> Self {
        Self::default()
    }

    /// A command started (`commandStarted`): appends a running block and
    /// drops the oldest ones past [`Self::MAX_BLOCKS`].
    pub fn command_started(&mut self, command: &str, line: i64, directory: Option<String>) {
        self.command_started_with_id(command, line, directory);
    }

    /// Starts a command and returns the ID used to attach later async results.
    pub fn command_started_with_id(
        &mut self,
        command: &str,
        line: i64,
        directory: Option<String>,
    ) -> Uuid {
        let mut block = CommandBlock::new(command, line);
        block.directory = directory;
        let id = block.id;
        self.blocks.push(block);
        let excess = self.blocks.len().saturating_sub(Self::MAX_BLOCKS);
        if excess > 0 {
            self.blocks.drain(..excess);
        }
        id
    }

    /// The most recent running block finished (`commandFinished`).
    /// Returns false when no block was running.
    pub fn command_finished(&mut self, line: i64, exit_code: i64) -> bool {
        let Some(block) = self.blocks.iter_mut().rev().find(|b| b.is_running()) else {
            return false;
        };
        block.end_line = Some(line);
        block.end_time = Some(Utc::now());
        block.exit_code = Some(exit_code);
        true
    }

    /// Files changed by the most recently finished block (`setChangedFiles`).
    pub fn set_changed_files(&mut self, files: Vec<String>) {
        if let Some(block) = self.blocks.iter_mut().rev().find(|b| !b.is_running()) {
            block.changed_files = files;
        }
    }

    /// Files changed by a specific completed command. Async Git scans must
    /// keep their result attached to the block that started them, even if a
    /// later command finishes first.
    pub fn set_changed_files_for(&mut self, id: Uuid, files: Vec<String>) -> bool {
        let Some(block) = self
            .blocks
            .iter_mut()
            .find(|block| block.id == id && !block.is_running())
        else {
            return false;
        };
        block.changed_files = files;
        true
    }

    /// Changed files of the latest finished block that has any (`lastChangedFiles`).
    pub fn last_changed_files(&self) -> &[String] {
        self.blocks
            .iter()
            .rev()
            .find(|b| !b.is_running() && !b.changed_files.is_empty())
            .map(|b| b.changed_files.as_slice())
            .unwrap_or(&[])
    }

    /// All blocks, oldest first (`blocksForTab`).
    pub fn blocks(&self) -> &[CommandBlock] {
        &self.blocks
    }

    /// The block spanning `line`; a running block spans every later line
    /// (`blockContaining`).
    pub fn block_containing(&self, line: i64) -> Option<&CommandBlock> {
        self.blocks
            .iter()
            .find(|b| line >= b.start_line && b.end_line.is_none_or(|end| line <= end))
    }

    pub fn clear(&mut self) {
        self.blocks.clear();
    }

    /// Drop the blocks whose command matches (the session restore line,
    /// which is not a command the user ran).
    pub fn remove_where(&mut self, matches: impl Fn(&str) -> bool) {
        self.blocks.retain(|b| !matches(&b.command));
    }
}

/// The pure parts of `GitDiffTracker.swift`: dirty files from
/// `git status --porcelain` and the files a command changed.
pub mod git_changes {
    use std::collections::BTreeSet;

    /// Path of one porcelain line (`XY path`, or `XY old -> new` for renames).
    pub fn changed_path_from_porcelain_line(line: &str) -> Option<String> {
        if line.chars().count() <= 3 {
            return None;
        }
        let path: String = line.chars().skip(3).collect();
        if let Some(index) = path.find(" -> ") {
            return Some(path[index + 4..].to_string());
        }
        if path.is_empty() { None } else { Some(path) }
    }

    /// First changed path of a porcelain output.
    pub fn first_changed_path(output: &str) -> Option<String> {
        output.lines().find_map(changed_path_from_porcelain_line)
    }

    /// Every dirty or untracked path of a porcelain output.
    pub fn dirty_files(output: &str) -> BTreeSet<String> {
        output
            .lines()
            .filter_map(changed_path_from_porcelain_line)
            .collect()
    }

    /// Files dirty now but not at the start, or clean now but dirty at the
    /// start (committed or reverted), sorted. Without a baseline, every
    /// dirty file.
    pub fn changed_files(
        baseline: Option<&BTreeSet<String>>,
        current: &BTreeSet<String>,
    ) -> Vec<String> {
        match baseline {
            None => current.iter().cloned().collect(),
            Some(base) => current.symmetric_difference(base).cloned().collect(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn block(command: &str, start_line: i64) -> CommandBlock {
        CommandBlock::new(command, start_line)
    }

    fn timed(seconds: f64) -> CommandBlock {
        let mut b = CommandBlock {
            end_line: Some(1),
            ..block("t", 1)
        };
        b.finish_after(seconds);
        b
    }

    #[test]
    fn block_creation() {
        let b = CommandBlock {
            directory: Some("/tmp".into()),
            ..block("ls -la", 10)
        };
        assert_eq!(b.command, "ls -la");
        assert_eq!(b.start_line, 10);
        assert_eq!(b.end_line, None);
        assert_eq!(b.end_time, None);
        assert_eq!(b.exit_code, None);
        assert_eq!(b.directory.as_deref(), Some("/tmp"));
        assert!(b.is_running());
        assert!(!b.is_success());
        assert!(!b.is_failed());
    }

    #[test]
    fn block_with_all_fields() {
        let start = Utc::now();
        let id = Uuid::new_v4();
        let b = CommandBlock {
            id,
            command: "make build".into(),
            start_line: 100,
            end_line: Some(150),
            start_time: start,
            end_time: Some(adding_seconds(start, 5.0)),
            exit_code: Some(0),
            directory: Some("/Users/dev/project".into()),
            changed_files: Vec::new(),
        };
        assert_eq!(b.id, id);
        assert_eq!(b.command, "make build");
        assert_eq!(b.start_line, 100);
        assert_eq!(b.end_line, Some(150));
        assert_eq!(b.exit_code, Some(0));
        assert_eq!(b.directory.as_deref(), Some("/Users/dev/project"));
        assert!(!b.is_running());
        assert!(b.is_success());
        assert!(!b.is_failed());
    }

    #[test]
    fn running_block() {
        let b = block("sleep 60", 5);
        assert!(b.is_running());
        assert!(!b.is_success());
        assert!(!b.is_failed());
    }

    #[test]
    fn success_block() {
        let b = CommandBlock {
            end_line: Some(2),
            exit_code: Some(0),
            ..block("echo hello", 1)
        };
        assert!(!b.is_running());
        assert!(b.is_success());
        assert!(!b.is_failed());
    }

    #[test]
    fn failed_block() {
        let b = CommandBlock {
            end_line: Some(1),
            exit_code: Some(1),
            ..block("false", 1)
        };
        assert!(!b.is_running());
        assert!(!b.is_success());
        assert!(b.is_failed());
    }

    #[test]
    fn failed_block_non_one_exit_code() {
        let b = CommandBlock {
            end_line: Some(5),
            exit_code: Some(139),
            ..block("segfault_program", 1)
        };
        assert!(b.is_failed());
        assert!(!b.is_success());
    }

    #[test]
    fn duration_nil_when_running() {
        assert_eq!(block("running", 1).duration(), None);
    }

    #[test]
    fn duration_calculation() {
        let d = timed(3.5).duration().unwrap();
        assert!((d - 3.5).abs() < 0.001);
    }

    #[test]
    fn duration_string_milliseconds() {
        assert_eq!(timed(0.5).duration_string(), "500ms");
    }

    #[test]
    fn duration_string_seconds() {
        assert_eq!(timed(3.2).duration_string(), "3.2s");
    }

    #[test]
    fn duration_string_minutes() {
        assert_eq!(timed(135.0).duration_string(), "2m 15s");
    }

    #[test]
    fn duration_string_hours() {
        assert_eq!(timed(3900.0).duration_string(), "1h 5m");
    }

    #[test]
    fn duration_string_empty_when_running() {
        assert_eq!(block("running", 1).duration_string(), "");
    }

    #[test]
    fn line_count_nil_when_running() {
        assert_eq!(block("running", 10).line_count(), None);
    }

    #[test]
    fn line_count_single_line() {
        let b = CommandBlock {
            end_line: Some(10),
            ..block("echo hi", 10)
        };
        assert_eq!(b.line_count(), Some(1));
    }

    #[test]
    fn line_count_multiple_lines() {
        let b = CommandBlock {
            end_line: Some(25),
            ..block("ls -la", 10)
        };
        assert_eq!(b.line_count(), Some(16));
    }

    #[test]
    fn equatable() {
        let b1 = block("test", 1);
        let b2 = b1.clone();
        assert_eq!(b1, b2);
    }

    #[test]
    fn not_equal() {
        assert_ne!(block("cmd1", 1), block("cmd2", 1));
    }

    #[test]
    fn codable() {
        let mut original = CommandBlock {
            end_line: Some(50),
            exit_code: Some(0),
            directory: Some("/repo".into()),
            ..block("git status", 42)
        };
        original.finish_after(2.0);
        let json = serde_json::to_string(&original).unwrap();
        let decoded: CommandBlock = serde_json::from_str(&json).unwrap();
        assert_eq!(decoded.id, original.id);
        assert_eq!(decoded.command, original.command);
        assert_eq!(decoded.start_line, original.start_line);
        assert_eq!(decoded.end_line, original.end_line);
        assert_eq!(decoded.exit_code, original.exit_code);
        assert_eq!(decoded.directory, original.directory);
    }

    #[test]
    fn block_lifecycle() {
        let mut b = CommandBlock {
            directory: Some("/project".into()),
            ..block("make test", 100)
        };
        assert!(b.is_running());
        assert_eq!(b.duration(), None);
        assert_eq!(b.line_count(), None);

        b.end_line = Some(120);
        b.finish_after(10.0);
        b.exit_code = Some(0);

        assert!(!b.is_running());
        assert!(b.is_success());
        assert!(!b.is_failed());
        assert!(b.duration().is_some());
        assert_eq!(b.line_count(), Some(21));
    }

    #[test]
    fn block_lifecycle_failure() {
        let mut b = block("cargo build", 50);
        b.end_line = Some(80);
        b.finish_after(30.0);
        b.exit_code = Some(2);

        assert!(!b.is_running());
        assert!(!b.is_success());
        assert!(b.is_failed());
        assert_eq!(b.exit_code, Some(2));
    }

    // Branches without a Swift test.

    #[test]
    fn json_matches_swift_default_coding() {
        let b = CommandBlock {
            id: Uuid::parse_str("e621e1f8-c36c-495a-93fc-0c247a3e6e5f").unwrap(),
            command: "ls".into(),
            start_line: 1,
            end_line: None,
            start_time: DateTime::from_timestamp(1_700_000_000, 0).unwrap(),
            end_time: None,
            exit_code: None,
            directory: None,
            changed_files: vec!["a.txt".into()],
        };
        let value: serde_json::Value = serde_json::to_value(&b).unwrap();
        assert_eq!(value["id"], "E621E1F8-C36C-495A-93FC-0C247A3E6E5F");
        assert_eq!(value["startLine"], 1);
        assert_eq!(value["startTime"], 721_692_800.0);
        assert_eq!(value["changedFiles"][0], "a.txt");
        assert!(value.get("endLine").is_none());
        assert!(value.get("endTime").is_none());
        assert!(value.get("exitCode").is_none());
        assert!(value.get("directory").is_none());
    }
}

#[cfg(test)]
mod list_tests {
    use super::git_changes::*;
    use super::*;

    #[test]
    fn start_finish_and_lookup() {
        let mut list = CommandBlockList::new();
        list.command_started("ls", 1, Some("/tmp".into()));
        assert!(list.blocks()[0].is_running());
        assert_eq!(
            list.block_containing(50).map(|b| b.command.as_str()),
            Some("ls")
        );
        assert!(list.command_finished(4, 0));
        assert!(!list.command_finished(5, 0));
        assert_eq!(
            list.block_containing(4).map(|b| b.command.as_str()),
            Some("ls")
        );
        assert!(list.block_containing(5).is_none());
        assert!(list.block_containing(0).is_none());
        list.set_changed_files(vec!["a.rs".into()]);
        assert_eq!(list.last_changed_files(), ["a.rs"]);
        list.command_started("make", 6, None);
        assert_eq!(list.last_changed_files(), ["a.rs"]);
        list.clear();
        assert!(list.blocks().is_empty());
    }

    #[test]
    fn async_changed_files_attach_to_their_command_when_scans_finish_out_of_order() {
        let mut list = CommandBlockList::new();
        list.command_started("first", 1, None);
        let first = list.blocks().last().unwrap().id;
        assert!(list.command_finished(2, 0));
        list.command_started("second", 3, None);
        let second = list.blocks().last().unwrap().id;
        assert!(list.command_finished(4, 0));

        // The second scan completes first; the first must not overwrite it.
        assert!(list.set_changed_files_for(second, vec!["second.rs".into()]));
        assert!(list.set_changed_files_for(first, vec!["first.rs".into()]));

        assert_eq!(list.blocks()[0].changed_files, ["first.rs"]);
        assert_eq!(list.blocks()[1].changed_files, ["second.rs"]);
        assert_eq!(list.last_changed_files(), ["second.rs"]);
    }

    #[test]
    fn keeps_at_most_200_blocks() {
        let mut list = CommandBlockList::new();
        for i in 0..205 {
            list.command_started(&format!("c{i}"), i, None);
        }
        assert_eq!(list.blocks().len(), CommandBlockList::MAX_BLOCKS);
        assert_eq!(list.blocks()[0].command, "c5");
    }

    #[test]
    fn porcelain_parsing() {
        assert_eq!(
            changed_path_from_porcelain_line(" M src/a.rs").as_deref(),
            Some("src/a.rs")
        );
        assert_eq!(
            changed_path_from_porcelain_line("R  old -> new").as_deref(),
            Some("new")
        );
        assert_eq!(changed_path_from_porcelain_line("?? "), None);
        assert_eq!(first_changed_path("\n?? x\n M y").as_deref(), Some("x"));
        let base = dirty_files(" M a\n M b");
        let now = dirty_files(" M b\n?? c");
        assert_eq!(changed_files(Some(&base), &now), ["a", "c"]);
        assert_eq!(changed_files(None, &now), ["b", "c"]);
    }
}
