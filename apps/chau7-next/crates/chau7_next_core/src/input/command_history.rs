//! Up/Down at a shell prompt: per-tab and global (all tabs) command history.
//!
//! Ports `apps/chau7-macos/Sources/Chau7/Terminal/Session/CommandHistoryManager.swift`
//! ([`CommandHistory`]), the typed-input buffer of
//! `TerminalSessionModel+ShellIntegration.swift` (`handleInput`,
//! `sanitizeInputForBuffer`, `processInputBuffer`: [`InputLineBuffer`]) and the
//! key handling of `RustTerminalView.handleHistoryKeyDown` ([`recall_bytes`],
//! [`RepeatGuard`]).

use std::collections::HashMap;

use crate::sensitive_input;

const MAX_PER_TAB: usize = 500;
const MAX_GLOBAL: usize = 2000;

/// Commands entered in each tab and in all tabs, oldest first, with the
/// navigation cursors (`None`: not navigating, `Some(0)`: most recent).
#[derive(Debug, Default, Clone)]
pub struct CommandHistory {
    tabs: HashMap<u64, Vec<String>>,
    global: Vec<String>,
    tab_cursors: HashMap<u64, usize>,
    global_cursor: Option<usize>,
}

impl CommandHistory {
    pub fn new() -> Self {
        Self::default()
    }

    /// Record a command entered in `tab`. Commands typed while echo was off
    /// (a password prompt) or holding inline secrets are never stored; the
    /// cursors are reset either way.
    pub fn record(&mut self, command: &str, tab: u64, is_sensitive: bool) {
        let trimmed = command.trim();
        if trimmed.is_empty() {
            return;
        }
        self.tab_cursors.remove(&tab);
        self.global_cursor = None;
        if is_sensitive || sensitive_input::contains_inline_secrets(trimmed) {
            return;
        }
        let history = self.tabs.entry(tab).or_default();
        if history.last().map(String::as_str) != Some(trimmed) {
            history.push(trimmed.to_string());
            if history.len() > MAX_PER_TAB {
                history.remove(0);
            }
        }
        if self.global.last().map(String::as_str) != Some(trimmed) {
            self.global.push(trimmed.to_string());
            if self.global.len() > MAX_GLOBAL {
                self.global.remove(0);
            }
        }
    }

    /// Add older commands (oldest first) below the global history, for
    /// example from the history file written by the shell integration.
    pub fn seed_global<I: IntoIterator<Item = String>>(&mut self, older: I) {
        let mut seeded: Vec<String> = older
            .into_iter()
            .map(|c| c.trim().to_string())
            .filter(|c| !c.is_empty() && !sensitive_input::contains_inline_secrets(c))
            .collect();
        seeded.dedup();
        seeded.append(&mut self.global);
        let excess = seeded.len().saturating_sub(MAX_GLOBAL);
        seeded.drain(..excess);
        self.global = seeded;
        self.global_cursor = None;
    }

    pub fn previous_in_tab(&mut self, tab: u64) -> Option<String> {
        let history = self.tabs.get(&tab).filter(|h| !h.is_empty())?;
        let next = self.tab_cursors.get(&tab).map_or(0, |c| c + 1);
        if next >= history.len() {
            return None;
        }
        let command = history[history.len() - 1 - next].clone();
        self.tab_cursors.insert(tab, next);
        Some(command)
    }

    /// `Some("")` when moving past the most recent command (back to an empty
    /// prompt); `None` when not navigating.
    pub fn next_in_tab(&mut self, tab: u64) -> Option<String> {
        let cursor = *self.tab_cursors.get(&tab)?;
        if cursor == 0 {
            self.tab_cursors.remove(&tab);
            return Some(String::new());
        }
        let new_cursor = cursor - 1;
        self.tab_cursors.insert(tab, new_cursor);
        let history = self.tabs.get(&tab)?;
        Some(history[history.len() - 1 - new_cursor].clone())
    }

    pub fn previous_global(&mut self) -> Option<String> {
        if self.global.is_empty() {
            return None;
        }
        let next = self.global_cursor.map_or(0, |c| c + 1);
        if next >= self.global.len() {
            return None;
        }
        self.global_cursor = Some(next);
        Some(self.global[self.global.len() - 1 - next].clone())
    }

    pub fn next_global(&mut self) -> Option<String> {
        let cursor = self.global_cursor?;
        if cursor == 0 {
            self.global_cursor = None;
            return Some(String::new());
        }
        let new_cursor = cursor - 1;
        self.global_cursor = Some(new_cursor);
        Some(self.global[self.global.len() - 1 - new_cursor].clone())
    }

    pub fn reset_cursor(&mut self, tab: u64) {
        self.tab_cursors.remove(&tab);
    }

    pub fn reset_global_cursor(&mut self) {
        self.global_cursor = None;
    }

    pub fn remove_tab(&mut self, tab: u64) {
        self.tabs.remove(&tab);
        self.tab_cursors.remove(&tab);
    }

    pub fn tab_len(&self, tab: u64) -> usize {
        self.tabs.get(&tab).map_or(0, Vec::len)
    }

    pub fn global_len(&self) -> usize {
        self.global.len()
    }
}

/// Bytes that replace the shell's input line with `command`: Ctrl+A (start of
/// line), Ctrl+K (kill to end), then the command.
pub fn recall_bytes(command: &str) -> Vec<u8> {
    let mut bytes = vec![0x01, 0x0b];
    bytes.extend_from_slice(command.as_bytes());
    bytes
}

/// Key repeat must not re-insert the same command (Swift `lastHistoryCommand`).
#[derive(Debug, Default, Clone)]
pub struct RepeatGuard {
    last: Option<(String, bool)>,
}

impl RepeatGuard {
    /// True when this recall should be skipped: a key repeat that would
    /// insert the same command in the same direction as the last one.
    pub fn should_skip(&mut self, command: &str, up: bool, is_repeat: bool) -> bool {
        let same = self
            .last
            .as_ref()
            .is_some_and(|(c, u)| c == command && *u == up);
        if is_repeat && same {
            return true;
        }
        self.last = Some((command.to_string(), up));
        false
    }
}

/// What the user typed since the last Enter, from the bytes sent to the PTY.
/// Escape sequences (arrows, function keys, OSC) are dropped, as in Swift's
/// `sanitizeInputForBuffer`. Backspace, Ctrl+U and Ctrl+C edit the buffer
/// (Swift kept those bytes in the line).
#[derive(Debug, Default, Clone)]
pub struct InputLineBuffer {
    line: String,
}

impl InputLineBuffer {
    pub fn new() -> Self {
        Self::default()
    }

    /// Feed bytes sent to the PTY; returns the lines completed by CR or LF.
    pub fn feed(&mut self, bytes: &[u8]) -> Vec<String> {
        let clean = sanitize(bytes);
        let text = String::from_utf8_lossy(&clean);
        let mut lines = Vec::new();
        for c in text.chars() {
            match c {
                '\r' | '\n' => lines.push(std::mem::take(&mut self.line)),
                '\u{7f}' | '\u{8}' => {
                    self.line.pop();
                }
                '\u{15}' | '\u{3}' => self.line.clear(),
                c if (c as u32) < 0x20 => {}
                c => self.line.push(c),
            }
        }
        lines
    }

    /// The line typed so far.
    pub fn current(&self) -> &str {
        &self.line
    }

    pub fn clear(&mut self) {
        self.line.clear();
    }
}

/// Drop escape sequences from typed input (Swift `sanitizeInputForBuffer`).
fn sanitize(data: &[u8]) -> Vec<u8> {
    if !data.contains(&0x1b) {
        return data.to_vec();
    }
    let mut out = Vec::with_capacity(data.len());
    let mut i = 0;
    while i < data.len() {
        let byte = data[i];
        if byte != 0x1b {
            out.push(byte);
            i += 1;
            continue;
        }
        i += 1;
        let Some(&next) = data.get(i) else {
            break;
        };
        if next == b'[' {
            // CSI: ESC [ ... final byte in @..~
            i += 1;
            while i < data.len() {
                let current = data[i];
                i += 1;
                if (0x40..=0x7e).contains(&current) {
                    break;
                }
            }
            continue;
        }
        if next == b']' || next == b'P' {
            // OSC / DCS: until BEL or ESC \
            i += 1;
            while i < data.len() {
                if data[i] == 0x07 {
                    i += 1;
                    break;
                }
                if data[i] == 0x1b && data.get(i + 1) == Some(&b'\\') {
                    i += 2;
                    break;
                }
                i += 1;
            }
            continue;
        }
        if next == b'O' {
            // SS3 key: ESC O + final byte.
            i += 2;
            continue;
        }
        // ESC + one byte (Meta).
        i += 1;
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn per_tab_navigation_walks_back_and_forward() {
        let mut h = CommandHistory::new();
        h.record("ls", 1, false);
        h.record("pwd", 1, false);
        h.record("other", 2, false);
        assert_eq!(h.previous_in_tab(1).as_deref(), Some("pwd"));
        assert_eq!(h.previous_in_tab(1).as_deref(), Some("ls"));
        assert_eq!(h.previous_in_tab(1), None);
        assert_eq!(h.next_in_tab(1).as_deref(), Some("pwd"));
        assert_eq!(h.next_in_tab(1).as_deref(), Some(""));
        assert_eq!(h.next_in_tab(1), None);
    }

    #[test]
    fn global_history_spans_tabs() {
        let mut h = CommandHistory::new();
        h.record("a", 1, false);
        h.record("b", 2, false);
        assert_eq!(h.previous_global().as_deref(), Some("b"));
        assert_eq!(h.previous_global().as_deref(), Some("a"));
        assert_eq!(h.next_global().as_deref(), Some("b"));
        assert_eq!(h.next_global().as_deref(), Some(""));
        assert_eq!(h.next_global(), None);
    }

    #[test]
    fn consecutive_duplicates_and_secrets_are_skipped() {
        let mut h = CommandHistory::new();
        h.record("ls", 1, false);
        h.record("  ls  ", 1, false);
        h.record("secret", 1, true);
        h.record("", 1, false);
        assert_eq!(h.tab_len(1), 1);
        assert_eq!(h.global_len(), 1);
    }

    #[test]
    fn recording_resets_navigation() {
        let mut h = CommandHistory::new();
        h.record("a", 1, false);
        h.record("b", 1, false);
        assert_eq!(h.previous_in_tab(1).as_deref(), Some("b"));
        h.record("c", 1, false);
        assert_eq!(h.previous_in_tab(1).as_deref(), Some("c"));
    }

    #[test]
    fn seeding_goes_below_live_commands() {
        let mut h = CommandHistory::new();
        h.record("new", 1, false);
        h.seed_global(vec!["old1".to_string(), "old2".to_string()]);
        assert_eq!(h.previous_global().as_deref(), Some("new"));
        assert_eq!(h.previous_global().as_deref(), Some("old2"));
        assert_eq!(h.previous_global().as_deref(), Some("old1"));
    }

    #[test]
    fn per_tab_history_is_capped() {
        let mut h = CommandHistory::new();
        for i in 0..(MAX_PER_TAB + 5) {
            h.record(&format!("c{i}"), 1, false);
        }
        assert_eq!(h.tab_len(1), MAX_PER_TAB);
        h.remove_tab(1);
        assert_eq!(h.tab_len(1), 0);
    }

    #[test]
    fn recall_clears_the_line_first() {
        assert_eq!(recall_bytes("ls"), b"\x01\x0bls".to_vec());
        assert_eq!(recall_bytes(""), b"\x01\x0b".to_vec());
    }

    #[test]
    fn repeat_guard_skips_same_command_on_repeat_only() {
        let mut g = RepeatGuard::default();
        assert!(!g.should_skip("ls", true, false));
        assert!(g.should_skip("ls", true, true));
        assert!(!g.should_skip("ls", false, true));
        assert!(!g.should_skip("ls", true, false));
    }

    #[test]
    fn input_buffer_splits_lines_and_drops_escapes() {
        let mut b = InputLineBuffer::new();
        assert!(b.feed(b"ec").is_empty());
        assert!(b.feed(b"\x1b[Aho").is_empty());
        assert_eq!(b.current(), "echo");
        assert_eq!(b.feed(b" hi\r"), vec!["echo hi".to_string()]);
        assert_eq!(b.current(), "");
    }

    #[test]
    fn input_buffer_applies_edits() {
        let mut b = InputLineBuffer::new();
        b.feed(b"lsx\x7f -l");
        assert_eq!(b.current(), "ls -l");
        b.feed(b"\x15pwd");
        assert_eq!(b.current(), "pwd");
        b.feed(b"\x1b]0;t\x07\x1bOP");
        assert_eq!(b.current(), "pwd");
    }
}
