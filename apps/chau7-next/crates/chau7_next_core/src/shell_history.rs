//! Per-tab and global command history for arrow-key navigation.
//!
//! Port of `apps/chau7-macos/Sources/Chau7/Terminal/Session/CommandHistoryManager.swift`:
//! 500 commands per tab and 2,000 globally, consecutive duplicates skipped,
//! commands typed with echo off (passwords) or holding inline secrets never
//! recorded. Navigation cursors: -1 = not navigating, 0 = most recent.

use std::collections::HashMap;

use crate::escape_sanitizer::trim_whitespaces_and_newlines;
use crate::sensitive_input::contains_inline_secrets;

pub const MAX_PER_TAB: usize = 500;
pub const MAX_GLOBAL: usize = 2000;

#[derive(Debug, Clone, Default)]
pub struct CommandHistory {
    /// Tab id to commands, oldest first.
    tabs: HashMap<String, Vec<String>>,
    /// Oldest first.
    global: Vec<String>,
    tab_cursors: HashMap<String, isize>,
    global_cursor: isize,
}

impl CommandHistory {
    pub fn new() -> Self {
        Self {
            global_cursor: -1,
            ..Default::default()
        }
    }

    /// Records a command. `is_sensitive`: typed while the PTY had echo off.
    pub fn record(&mut self, command: &str, tab_id: &str, is_sensitive: bool) {
        let trimmed = trim_whitespaces_and_newlines(command);
        if trimmed.is_empty() {
            return;
        }
        if is_sensitive || contains_inline_secrets(trimmed) {
            self.reset_all_cursors(tab_id);
            return;
        }
        let tab = self.tabs.entry(tab_id.to_string()).or_default();
        if tab.last().map(String::as_str) != Some(trimmed) {
            tab.push(trimmed.to_string());
            if tab.len() > MAX_PER_TAB {
                tab.remove(0);
            }
        }
        if self.global.last().map(String::as_str) != Some(trimmed) {
            self.global.push(trimmed.to_string());
            if self.global.len() > MAX_GLOBAL {
                self.global.remove(0);
            }
        }
        self.reset_all_cursors(tab_id);
    }

    /// Commands of one tab, oldest first.
    pub fn tab_commands(&self, tab_id: &str) -> &[String] {
        self.tabs.get(tab_id).map(Vec::as_slice).unwrap_or(&[])
    }

    /// Commands of every tab, oldest first.
    pub fn global_commands(&self) -> &[String] {
        &self.global
    }

    pub fn previous_in_tab(&mut self, tab_id: &str) -> Option<String> {
        let history = self.tabs.get(tab_id).filter(|h| !h.is_empty())?;
        let next = self.tab_cursors.get(tab_id).copied().unwrap_or(-1) + 1;
        if next as usize >= history.len() {
            return None;
        }
        let value = history[history.len() - 1 - next as usize].clone();
        self.tab_cursors.insert(tab_id.to_string(), next);
        Some(value)
    }

    pub fn next_in_tab(&mut self, tab_id: &str) -> Option<String> {
        let cursor = self.tab_cursors.get(tab_id).copied().unwrap_or(-1);
        if cursor < 0 {
            return None;
        }
        if cursor == 0 {
            self.tab_cursors.insert(tab_id.to_string(), -1);
            return Some(String::new());
        }
        let new_cursor = cursor - 1;
        self.tab_cursors.insert(tab_id.to_string(), new_cursor);
        let history = self.tabs.get(tab_id)?;
        history
            .len()
            .checked_sub(1 + new_cursor as usize)
            .map(|i| history[i].clone())
    }

    pub fn previous_global(&mut self) -> Option<String> {
        if self.global.is_empty() {
            return None;
        }
        let next = self.global_cursor + 1;
        if next as usize >= self.global.len() {
            return None;
        }
        self.global_cursor = next;
        Some(self.global[self.global.len() - 1 - next as usize].clone())
    }

    pub fn next_global(&mut self) -> Option<String> {
        if self.global_cursor < 0 {
            return None;
        }
        if self.global_cursor == 0 {
            self.global_cursor = -1;
            return Some(String::new());
        }
        self.global_cursor -= 1;
        self.global
            .len()
            .checked_sub(1 + self.global_cursor as usize)
            .map(|i| self.global[i].clone())
    }

    pub fn reset_cursor(&mut self, tab_id: &str) {
        self.tab_cursors.insert(tab_id.to_string(), -1);
    }

    pub fn reset_global_cursor(&mut self) {
        self.global_cursor = -1;
    }

    pub fn reset_all_cursors(&mut self, tab_id: &str) {
        self.reset_cursor(tab_id);
        self.reset_global_cursor();
    }

    pub fn remove_tab(&mut self, tab_id: &str) {
        self.tabs.remove(tab_id);
        self.tab_cursors.remove(tab_id);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn records_and_skips_consecutive_duplicates() {
        let mut h = CommandHistory::new();
        h.record("ls", "t", false);
        h.record("ls", "t", false);
        h.record(" git status ", "t", false);
        h.record("ls", "u", false);
        assert_eq!(h.tab_commands("t"), ["ls", "git status"]);
        assert_eq!(h.global_commands(), ["ls", "git status", "ls"]);
    }

    #[test]
    fn sensitive_and_secret_commands_are_not_recorded() {
        let mut h = CommandHistory::new();
        h.record("hunter2", "t", true);
        h.record("export API_KEY=abc", "t", false);
        h.record("   ", "t", false);
        assert!(h.tab_commands("t").is_empty());
        assert!(h.global_commands().is_empty());
    }

    #[test]
    fn tab_navigation() {
        let mut h = CommandHistory::new();
        h.record("a", "t", false);
        h.record("b", "t", false);
        assert_eq!(h.next_in_tab("t"), None);
        assert_eq!(h.previous_in_tab("t").as_deref(), Some("b"));
        assert_eq!(h.previous_in_tab("t").as_deref(), Some("a"));
        assert_eq!(h.previous_in_tab("t"), None);
        assert_eq!(h.next_in_tab("t").as_deref(), Some("b"));
        assert_eq!(h.next_in_tab("t").as_deref(), Some(""));
        assert_eq!(h.next_in_tab("t"), None);
    }

    #[test]
    fn global_navigation_and_limits() {
        let mut h = CommandHistory::new();
        for i in 0..(MAX_GLOBAL + 5) {
            h.record(&format!("c{i}"), &format!("t{}", i % 3), false);
        }
        assert_eq!(h.global_commands().len(), MAX_GLOBAL);
        assert!(h.tab_commands("t0").len() <= MAX_PER_TAB);
        assert_eq!(
            h.previous_global().as_deref(),
            Some(format!("c{}", MAX_GLOBAL + 4).as_str())
        );
        assert_eq!(h.next_global().as_deref(), Some(""));
        h.remove_tab("t0");
        assert!(h.tab_commands("t0").is_empty());
    }
}
