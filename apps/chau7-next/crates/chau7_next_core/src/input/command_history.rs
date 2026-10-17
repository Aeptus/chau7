//! Bounded prompt history owned by one terminal; navigation belongs to its view.
use crate::sensitive_input;
use serde::{Deserialize, Deserializer, Serialize};

pub const MAX_PER_TAB: usize = 500;
const MAX_GLOBAL: usize = 2000;
/// Bound snapshot size as well as entry count. Recall must never contain controls.
const MAX_COMMAND_BYTES: usize = 16 * 1024;

#[derive(Debug, Default, Clone, PartialEq, Eq, Serialize)]
#[serde(transparent)]
pub struct CommandHistory(Vec<String>);

impl<'de> Deserialize<'de> for CommandHistory {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let entries = serde_json::Value::deserialize(deserializer)?;
        let mut history = Self::default();
        if let Some(entries) = entries.as_array() {
            for entry in entries.iter().filter_map(serde_json::Value::as_str) {
                history.record(entry, false);
            }
        }
        Ok(history)
    }
}

impl CommandHistory {
    pub fn new() -> Self {
        Self::default()
    }
    pub fn is_empty(&self) -> bool {
        self.0.is_empty()
    }
    pub fn entries(&self) -> &[String] {
        &self.0
    }
    pub fn record(&mut self, command: &str, sensitive: bool) {
        self.record_bounded(command, sensitive, MAX_PER_TAB);
    }
    /// Only explicit Option+Up/Down uses this app-wide history.
    pub fn record_global(&mut self, command: &str, sensitive: bool) {
        self.record_bounded(command, sensitive, MAX_GLOBAL);
    }
    fn record_bounded(&mut self, command: &str, sensitive: bool, limit: usize) {
        // Validate before trimming: embedded CR/LF or escape sequences must
        // never turn restored history into executable terminal input.
        if sensitive || command.len() > MAX_COMMAND_BYTES || command.chars().any(char::is_control) {
            return;
        }
        let command = command.trim();
        if command.is_empty()
            || sensitive_input::contains_inline_secrets(command)
            || self.0.last().is_some_and(|last| last == command)
        {
            return;
        }
        self.0.push(command.to_owned());
        let excess = self.0.len().saturating_sub(limit);
        self.0.drain(..excess);
    }
    pub fn seed_global(&mut self, older: impl IntoIterator<Item = String>) {
        let live = std::mem::take(&mut self.0);
        for command in older.into_iter().chain(live) {
            self.record_global(&command, false);
        }
    }
}

/// A snapshot prevents activity in other terminals from shifting navigation.
/// Draft and cursor are transient, independent even when browsing global entries.
#[derive(Debug, Default)]
pub struct HistoryNavigation {
    browsing: Option<Browse>,
}
#[derive(Debug)]
struct Browse {
    global: bool,
    entries: Vec<String>,
    index: usize,
    draft: String,
}
impl HistoryNavigation {
    pub fn reset(&mut self) {
        self.browsing = None;
    }
    pub fn step(
        &mut self,
        history: &CommandHistory,
        global: bool,
        up: bool,
        draft: &str,
    ) -> Option<String> {
        if self.browsing.as_ref().is_some_and(|b| b.global != global) {
            // Changing scope retains the original unfinished input.
            let original = self.browsing.take().unwrap().draft;
            if !up || history.is_empty() {
                return Some(original);
            }
            self.browsing = Some(Browse {
                global,
                entries: history.0.clone(),
                index: history.0.len(),
                draft: original,
            });
        }
        if self.browsing.is_none() {
            if !up || history.is_empty() {
                return None;
            }
            self.browsing = Some(Browse {
                global,
                entries: history.0.clone(),
                index: history.0.len(),
                draft: draft.to_owned(),
            });
        }
        let b = self.browsing.as_mut().unwrap();
        if up {
            if b.index == 0 {
                return None;
            }
            b.index -= 1;
            Some(b.entries[b.index].clone())
        } else if b.index + 1 < b.entries.len() {
            b.index += 1;
            Some(b.entries[b.index].clone())
        } else {
            Some(self.browsing.take().unwrap().draft)
        }
    }
}

/// End of line, then kill back to start. This also clears the command tracker's
/// pending line, unlike the old Ctrl+A/Ctrl+K sequence it did not understand.
pub fn recall_bytes(command: &str) -> Vec<u8> {
    let mut bytes = vec![0x05, 0x15];
    bytes.extend_from_slice(command.as_bytes());
    bytes
}

/// Streaming, cursor-aware input tracking. Unsupported shell-side edits (such
/// as completion/search) invalidate capture until Enter instead of saving a
/// guessed command. Shell history remains authoritative for those edits.
#[derive(Debug, Clone)]
pub struct InputLineBuffer {
    line: String,
    cursor: usize,
    pending: Vec<u8>,
    reliable: bool,
}
impl Default for InputLineBuffer {
    fn default() -> Self {
        Self {
            line: String::new(),
            cursor: 0,
            pending: Vec::new(),
            reliable: true,
        }
    }
}
impl InputLineBuffer {
    pub fn new() -> Self {
        Self::default()
    }
    pub fn current(&self) -> &str {
        &self.line
    }
    /// Shell-side completion/search can change text without sending it through
    /// the PTY input stream. Never replace a draft we cannot reconstruct.
    pub fn draft(&self) -> Option<&str> {
        (self.reliable && self.pending.is_empty()).then_some(self.line.as_str())
    }
    pub fn clear(&mut self) {
        *self = Self::default();
    }
    pub fn feed(&mut self, bytes: &[u8]) -> Vec<String> {
        self.pending.extend_from_slice(bytes);
        let mut lines = Vec::new();
        let mut consumed = 0;
        while consumed < self.pending.len() {
            let byte = self.pending[consumed];
            if byte == 0x1b {
                let remaining = &self.pending[consumed..];
                let Some(end) = escape_end(remaining) else {
                    break;
                };
                let sequence = remaining[..end].to_vec();
                match sequence.as_slice() {
                    b"\x1b[D" | b"\x1bOD" => self.left(),
                    b"\x1b[C" | b"\x1bOC" => self.right(),
                    b"\x1b[H" | b"\x1bOH" | b"\x1b[1~" => self.cursor = 0,
                    b"\x1b[F" | b"\x1bOF" | b"\x1b[4~" => self.cursor = self.line.len(),
                    b"\x1b[3~" => self.delete(),
                    b"\x1b[200~" | b"\x1b[201~" => {}
                    _ => self.reliable = false,
                }
                consumed += end;
                continue;
            }
            if byte < 0x80 {
                consumed += 1;
                match byte {
                    b'\r' | b'\n' => {
                        // An empty submission must still reset navigation and
                        // sensitivity, even after unsupported shell editing.
                        lines.push(if self.reliable {
                            std::mem::take(&mut self.line)
                        } else {
                            self.line.clear();
                            String::new()
                        });
                        self.cursor = 0;
                        self.reliable = true;
                    }
                    0x01 => self.cursor = 0,
                    0x05 => self.cursor = self.line.len(),
                    0x02 => self.left(),
                    0x06 => self.right(),
                    0x08 | 0x7f => {
                        let end = self.cursor;
                        self.left();
                        self.line.drain(self.cursor..end);
                    }
                    0x04 => self.delete(),
                    0x0b => {
                        self.line.truncate(self.cursor);
                    }
                    0x15 => {
                        self.line.drain(..self.cursor);
                        self.cursor = 0;
                        // Only a complete replacement makes an unknown line
                        // reliable again; Ctrl+U can leave a suffix intact.
                        self.reliable |= self.line.is_empty();
                    }
                    0x03 => {
                        self.line.clear();
                        self.cursor = 0;
                        self.reliable = true;
                    }
                    0x17 => {
                        let end = self.cursor;
                        while self.cursor > 0
                            && self.line[..self.cursor].ends_with(char::is_whitespace)
                        {
                            self.left();
                        }
                        while self.cursor > 0
                            && !self.line[..self.cursor].ends_with(char::is_whitespace)
                        {
                            self.left();
                        }
                        self.line.drain(self.cursor..end);
                    }
                    0..=0x1f => self.reliable = false,
                    _ => {
                        self.line.insert(self.cursor, byte as char);
                        self.cursor += 1;
                    }
                }
                continue;
            }
            let remaining = &self.pending[consumed..];
            let width = match byte {
                0xc2..=0xdf => 2,
                0xe0..=0xef => 3,
                0xf0..=0xf4 => 4,
                _ => 1,
            };
            if remaining.len() < width {
                break;
            }
            if let Ok(text) = std::str::from_utf8(&remaining[..width]) {
                self.line.insert_str(self.cursor, text);
                self.cursor += width;
            } else {
                self.reliable = false;
            }
            consumed += width;
        }
        self.pending.drain(..consumed);
        // Broken/incomplete control sequences cannot grow the buffer forever.
        if self.pending.len() > MAX_COMMAND_BYTES {
            self.pending.clear();
            self.reliable = false;
        }
        if self.line.len() > MAX_COMMAND_BYTES {
            self.line.clear();
            self.cursor = 0;
            self.reliable = false;
        }
        lines
    }
    fn left(&mut self) {
        self.cursor = self.line[..self.cursor]
            .char_indices()
            .next_back()
            .map_or(0, |(i, _)| i);
    }
    fn right(&mut self) {
        self.cursor += self.line[self.cursor..]
            .chars()
            .next()
            .map_or(0, char::len_utf8);
    }
    fn delete(&mut self) {
        let end = self.cursor
            + self.line[self.cursor..]
                .chars()
                .next()
                .map_or(0, char::len_utf8);
        self.line.drain(self.cursor..end);
    }
}
fn escape_end(bytes: &[u8]) -> Option<usize> {
    match *bytes.get(1)? {
        b'[' => bytes
            .iter()
            .enumerate()
            .skip(2)
            .find(|(_, b)| (0x40..=0x7e).contains(*b))
            .map(|(i, _)| i + 1),
        b'O' => (bytes.len() >= 3).then_some(3),
        b']' | b'P' => {
            for i in 2..bytes.len() {
                if bytes[i] == 7 {
                    return Some(i + 1);
                }
                if bytes[i] == b'\\' && bytes[i - 1] == 0x1b {
                    return Some(i + 1);
                }
            }
            None
        }
        _ => Some(2),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn independent_histories_and_navigation_preserve_drafts() {
        let mut a = CommandHistory::new();
        let mut b = CommandHistory::new();
        a.record("a1", false);
        a.record("a2", false);
        b.record("b1", false);
        let mut na = HistoryNavigation::default();
        let mut nb = HistoryNavigation::default();
        assert_eq!(na.step(&a, false, true, "draft a").as_deref(), Some("a2"));
        assert_eq!(nb.step(&b, false, true, "draft b").as_deref(), Some("b1"));
        assert_eq!(na.step(&a, false, true, "a2").as_deref(), Some("a1"));
        assert_eq!(na.step(&a, false, true, "a1"), None);
        assert_eq!(nb.step(&b, false, false, "b1").as_deref(), Some("draft b"));
        assert_eq!(na.step(&a, false, false, "a1").as_deref(), Some("a2"));
        assert_eq!(na.step(&a, false, false, "a2").as_deref(), Some("draft a"));
        assert_eq!(na.step(&a, false, false, "draft a"), None);
    }
    #[test]
    fn global_browsing_is_view_local_and_stable_while_other_tabs_record() {
        let mut h = CommandHistory::new();
        h.seed_global(["old".into(), "new".into()]);
        let mut a = HistoryNavigation::default();
        let mut b = HistoryNavigation::default();
        assert_eq!(a.step(&h, true, true, "draft").as_deref(), Some("new"));
        h.record_global("another tab", false);
        assert_eq!(b.step(&h, true, true, "").as_deref(), Some("another tab"));
        assert_eq!(a.step(&h, true, true, "new").as_deref(), Some("old"));
        a.reset();
        assert_eq!(
            a.step(&h, true, true, "edited").as_deref(),
            Some("another tab")
        );
        assert_eq!(
            a.step(&h, true, false, "another tab").as_deref(),
            Some("edited")
        );
    }
    #[test]
    fn switching_scope_keeps_original_draft_and_empty_local_never_uses_global() {
        let mut local = CommandHistory::new();
        local.record("local", false);
        let mut global = CommandHistory::new();
        global.record_global("global", false);
        let mut n = HistoryNavigation::default();
        assert_eq!(
            n.step(&local, false, true, "draft").as_deref(),
            Some("local")
        );
        assert_eq!(
            n.step(&global, true, true, "local").as_deref(),
            Some("global")
        );
        assert_eq!(
            n.step(&global, true, false, "global").as_deref(),
            Some("draft")
        );
        assert_eq!(n.step(&CommandHistory::new(), false, true, "draft"), None);
    }
    #[test]
    fn restored_history_is_bounded_deduplicated_and_validated() {
        let entries: Vec<String> = (0..MAX_PER_TAB + 5)
            .map(|i| format!("command {i}"))
            .chain([
                format!("command {}", MAX_PER_TAB + 4),
                "password".into(),
                "export API_KEY=abc".into(),
                "bad\rcommand".into(),
                "bad\x1b[A".into(),
                "x".repeat(MAX_COMMAND_BYTES + 1),
                "  ".into(),
            ])
            .collect();
        let mut original = CommandHistory::new();
        original.record("private", true);
        assert!(original.is_empty());
        let restored: CommandHistory =
            serde_json::from_str(&serde_json::to_string(&entries).unwrap()).unwrap();
        assert_eq!(restored.entries().len(), MAX_PER_TAB);
        // The ordinary command 'password' is not a password prompt; only the
        // explicit sensitive flag or inline secret detector suppresses it.
        assert_eq!(restored.entries().last().unwrap(), "password");
        assert_eq!(restored.entries().first().unwrap(), "command 6");
        let again: CommandHistory =
            serde_json::from_str(&serde_json::to_string(&restored).unwrap()).unwrap();
        assert_eq!(again, restored);
    }
    #[test]
    fn damaged_optional_history_does_not_discard_other_restore_data() {
        for json in ["null", "{}", "42"] {
            let history: CommandHistory = serde_json::from_str(json).unwrap();
            assert!(history.is_empty());
        }
        let history: CommandHistory =
            serde_json::from_str(r#"["pwd", null, 3, {}, "ls"]"#).unwrap();
        assert_eq!(history.entries(), ["pwd", "ls"]);
    }
    #[test]
    fn recall_replaces_pending_input_before_enter() {
        let mut b = InputLineBuffer::new();
        b.feed(b"unfinished");
        b.feed(&recall_bytes("pwd"));
        assert_eq!(b.feed(b"\r"), ["pwd"]);
    }

    #[test]
    fn edited_recall_and_split_unicode_sequences_capture_the_actual_line() {
        let mut b = InputLineBuffer::new();
        b.feed(&recall_bytes("echo caf"));
        b.feed(&[0xc3]);
        b.feed(&[0xa9]);
        b.feed(b"\x1b[");
        b.feed(b"Dx");
        assert_eq!(b.feed(b"\r"), ["echo cafxé"]);
        b.feed(b"abc\x01\x1b[3~Z\x05\x7f");
        assert_eq!(b.feed(b"\r"), ["Zb"]);
    }
    #[test]
    fn unsupported_shell_edits_are_not_saved_as_guessed_commands() {
        let mut b = InputLineBuffer::new();
        assert_eq!(b.feed(b"git che\t\r"), [""]);
        assert_eq!(b.feed(b"pwd\r"), ["pwd"]);
        b.feed(b"abc\t\x01\x15");
        assert_eq!(b.draft(), None);
        assert_eq!(b.feed(b"\r"), [""]);
        assert_eq!(b.draft(), Some(""));
        b.feed(b"old\x12");
        b.feed(&recall_bytes("new"));
        assert_eq!(b.feed(b"\r"), ["new"]);
    }
    #[test]
    fn recall_replaces_the_shell_tracker_prefix_without_submitting() {
        use crate::shell_session::{ShellContext, ShellSession, ShellSessionConfig};
        struct Ctx;
        impl ShellContext for Ctx {
            fn is_dir(&self, _: &str) -> bool {
                false
            }
            fn search_path(&self) -> Option<String> {
                Some(String::new())
            }
            fn home(&self) -> String {
                "/fixture".into()
            }
        }
        let mut shell = ShellSession::new(ShellSessionConfig::default(), "/fixture", 0.0);
        shell.handle_input("unfinished", false, &Ctx, 0.0);
        shell.handle_input(
            std::str::from_utf8(&recall_bytes("pwd")).unwrap(),
            false,
            &Ctx,
            0.1,
        );
        assert_eq!(shell.pending_input_text(), "pwd");
        shell.handle_input("\r", false, &Ctx, 0.2);
        assert_eq!(shell.pending_command(), Some("pwd"));
    }
    #[test]
    fn input_buffer_splits_lines_and_drops_escapes() {
        let mut b = InputLineBuffer::new();
        assert!(b.feed(b"ec").is_empty());
        assert!(b.feed(b"ho").is_empty());
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
