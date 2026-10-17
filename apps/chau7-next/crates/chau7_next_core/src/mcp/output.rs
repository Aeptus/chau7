//! Tool results (`TerminalControlService.swift`): JSON encoding with sorted
//! keys, error payloads, and the text of `tab_output`.

use std::path::Path;
use std::time::Duration;

use serde_json::{Map, Value};
use sha2::{Digest, Sha256};

use crate::escape_sanitizer;

/// `tab_output` returns at most this many bytes (512 KB).
pub const MAX_OUTPUT_BYTES: usize = 512 * 1024;
/// `tab_output` line count: default and maximum.
pub const DEFAULT_OUTPUT_LINES: i64 = 50;
pub const MAX_OUTPUT_LINES: i64 = 10_000;
/// `wait_for_stable_ms` is capped at 30 s.
pub const MAX_STABLE_WAIT_MS: i64 = 30_000;
/// Content must stay unchanged this long (at most) to count as stable.
pub const STABILITY_THRESHOLD_MS: i64 = 500;
/// The buffer is sampled this often while waiting.
pub const STABLE_POLL_INTERVAL: Duration = Duration::from_millis(250);
/// `readPTYLogTail`: the last 1,024,000 bytes of the log.
pub const PTY_LOG_TAIL_BYTES: u64 = 1_024_000;

/// A tool error: `{"error":"..."}` (`jsonError`).
pub fn json_error(message: &str) -> String {
    let mut map = Map::new();
    map.insert("error".into(), Value::String(message.to_string()));
    Value::Object(map).to_string()
}

/// Compact JSON with object keys sorted at every level
/// (`JSONSerialization` with `.sortedKeys`).
pub fn encode_sorted(value: &Value) -> String {
    sorted(value).to_string()
}

fn sorted(value: &Value) -> Value {
    match value {
        Value::Object(map) => {
            let mut keys: Vec<&String> = map.keys().collect();
            keys.sort();
            let mut out = Map::new();
            for key in keys {
                out.insert(key.clone(), sorted(&map[key]));
            }
            Value::Object(out)
        }
        Value::Array(items) => Value::Array(items.iter().map(sorted).collect()),
        other => other.clone(),
    }
}

/// `tab_output` line count from the tool arguments: default 50, clamped
/// to 1..=10,000.
pub fn clamp_lines(requested: Option<i64>) -> usize {
    requested
        .unwrap_or(DEFAULT_OUTPUT_LINES)
        .clamp(1, MAX_OUTPUT_LINES) as usize
}

fn cap_size(mut lines: Vec<&str>, requested: usize) -> (String, usize) {
    let mut output = lines.join("\n");
    if output.len() > MAX_OUTPUT_BYTES {
        let keep = (requested / 2).max(1);
        if lines.len() > keep {
            lines = lines.split_off(lines.len() - keep);
        }
        output = lines.join("\n");
    }
    let count = lines.len();
    (output, count)
}

/// `formatBufferOutput`: the last `lines` lines of the terminal buffer,
/// without the blank lines below the cursor. Past 512 KB, half as many lines
/// are kept. Returns the text and its line count.
pub fn format_buffer_output(text: &str, lines: usize) -> (String, usize) {
    let mut all: Vec<&str> = text.split('\n').collect();
    while all.last().is_some_and(|l| l.trim().is_empty()) {
        all.pop();
    }
    if all.len() > lines {
        all = all.split_off(all.len() - lines);
    }
    cap_size(all, lines)
}

/// `ptyLogOutput`: the last `lines` lines of a cleaned PTY log.
pub fn format_pty_log_output(text: &str, lines: usize) -> (String, usize) {
    let mut all: Vec<&str> = text.split('\n').collect();
    if all.len() > lines {
        all = all.split_off(all.len() - lines);
    }
    cap_size(all, lines)
}

/// `readPTYLogTail` after reading: escape sequences removed, lines
/// trimmed, runs of blank lines cut to two, outer blank space trimmed.
/// `None` when nothing is left.
pub fn clean_pty_log(raw: &str) -> Option<String> {
    let stripped = escape_sanitizer::sanitize(raw);
    let mut result: Vec<&str> = Vec::new();
    let mut empty_run = 0;
    for line in stripped.split('\n') {
        let trimmed = line.trim_matches(|c: char| c.is_whitespace() && c != '\n');
        if trimmed.is_empty() {
            empty_run += 1;
            if empty_run <= 2 {
                result.push("");
            }
        } else {
            empty_run = 0;
            result.push(trimmed);
        }
    }
    let text = result.join("\n");
    let text = text.trim();
    (!text.is_empty()).then(|| text.to_string())
}

/// `readPTYLogTail`: the cleaned last [`PTY_LOG_TAIL_BYTES`] of a log file.
pub fn read_pty_log_tail(path: &Path) -> Option<String> {
    use std::io::{Read, Seek, SeekFrom};
    let mut file = std::fs::File::open(path).ok()?;
    let size = file.metadata().ok()?.len();
    let start = size.saturating_sub(PTY_LOG_TAIL_BYTES);
    file.seek(SeekFrom::Start(start)).ok()?;
    let mut data = Vec::new();
    file.read_to_end(&mut data).ok()?;
    if data.is_empty() {
        return None;
    }
    clean_pty_log(&String::from_utf8_lossy(&data))
}

/// `bufferFingerprint`: byte count and SHA-256 of the last 4 KB.
pub fn fingerprint(text: &str) -> (usize, [u8; 32]) {
    let bytes = text.as_bytes();
    let tail = &bytes[bytes.len().saturating_sub(4096)..];
    (bytes.len(), Sha256::digest(tail).into())
}

/// The wait of `wait_for_stable_ms`: feed a fingerprint at every poll; it
/// says when the content has not changed for the threshold.
#[derive(Debug, Clone)]
pub struct StabilityWait {
    threshold_ms: u64,
    previous: Option<(usize, [u8; 32])>,
    stable_since_ms: Option<u64>,
}

impl StabilityWait {
    /// `wait_ms` is the caller's total budget (already capped).
    pub fn new(wait_ms: u64) -> Self {
        Self {
            threshold_ms: wait_ms.min(STABILITY_THRESHOLD_MS as u64),
            previous: None,
            stable_since_ms: None,
        }
    }

    /// One sample taken at `now_ms` (any monotonic clock in ms). Returns
    /// true once the content has been unchanged for the threshold.
    pub fn observe(&mut self, fp: (usize, [u8; 32]), now_ms: u64) -> bool {
        if self.previous == Some(fp) {
            let since = *self.stable_since_ms.get_or_insert(now_ms);
            now_ms.saturating_sub(since) >= self.threshold_ms
        } else {
            self.stable_since_ms = None;
            self.previous = Some(fp);
            false
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn errors_are_valid_json() {
        assert_eq!(
            json_error("Tab not found: x"),
            r#"{"error":"Tab not found: x"}"#
        );
        let v: Value = serde_json::from_str(&json_error("a \"b\" \\ c\nd")).unwrap();
        assert_eq!(v["error"], "a \"b\" \\ c\nd");
    }

    #[test]
    fn keys_are_sorted_at_every_level() {
        let v = json!({"b": 1, "a": {"z": 1, "y": [{"d": 1, "c": 2}]}});
        assert_eq!(
            encode_sorted(&v),
            r#"{"a":{"y":[{"c":2,"d":1}],"z":1},"b":1}"#
        );
    }

    #[test]
    fn line_count_is_clamped() {
        assert_eq!(clamp_lines(None), 50);
        assert_eq!(clamp_lines(Some(0)), 1);
        assert_eq!(clamp_lines(Some(-5)), 1);
        assert_eq!(clamp_lines(Some(20_000)), 10_000);
    }

    #[test]
    fn buffer_output_drops_trailing_blank_lines_and_keeps_the_tail() {
        let (out, n) = format_buffer_output("a\nb\nc\n  \n\n", 2);
        assert_eq!((out.as_str(), n), ("b\nc", 2));
        let (out, n) = format_buffer_output("a\nb", 50);
        assert_eq!((out.as_str(), n), ("a\nb", 2));
        let (out, n) = format_buffer_output("\n\n", 5);
        assert_eq!((out.as_str(), n), ("", 0));
    }

    #[test]
    fn huge_output_keeps_half_the_lines() {
        let line = "x".repeat(1000);
        let text = vec![line.as_str(); 1000].join("\n");
        let (out, n) = format_buffer_output(&text, 1000);
        assert_eq!(n, 500);
        assert_eq!(out.len(), 500 * 1000 + 499);
    }

    #[test]
    fn pty_log_is_cleaned() {
        let raw = "\x1b[31mred\x1b[0m  \n\n\n\n\n  next\n\n";
        assert_eq!(clean_pty_log(raw).as_deref(), Some("red\n\n\nnext"));
        assert_eq!(clean_pty_log("\x1b[2J\n \n"), None);
        let (out, n) = format_pty_log_output("a\nb\nc", 2);
        assert_eq!((out.as_str(), n), ("b\nc", 2));
    }

    #[test]
    fn pty_log_tail_reads_the_end() {
        let dir = std::env::temp_dir().join(format!("chau7-next-ptylog-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("log.txt");
        let mut text = "old\n".repeat(400_000);
        text.push_str("last line\n");
        std::fs::write(&path, &text).unwrap();
        let tail = read_pty_log_tail(&path).unwrap();
        assert!(tail.ends_with("last line"));
        assert!(tail.len() <= PTY_LOG_TAIL_BYTES as usize);
        assert_eq!(read_pty_log_tail(&dir.join("missing")), None);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn fingerprint_looks_at_size_and_tail() {
        assert_eq!(fingerprint("abc"), fingerprint("abc"));
        assert_ne!(fingerprint("abc"), fingerprint("abd"));
        let a = format!("{}{}", "a", "z".repeat(5000));
        let b = format!("{}{}", "b", "z".repeat(5000));
        // Same size, same last 4 KB: same fingerprint.
        assert_eq!(fingerprint(&a), fingerprint(&b));
    }

    #[test]
    fn stability_needs_unchanged_content_for_the_threshold() {
        let mut wait = StabilityWait::new(2000);
        let a = fingerprint("a");
        let b = fingerprint("b");
        assert!(!wait.observe(a, 0));
        assert!(!wait.observe(a, 250));
        assert!(!wait.observe(b, 500));
        assert!(!wait.observe(b, 750));
        assert!(!wait.observe(b, 1000));
        assert!(wait.observe(b, 1250));
        // A short budget lowers the threshold.
        let mut short = StabilityWait::new(100);
        assert!(!short.observe(a, 0));
        assert!(!short.observe(a, 50));
        assert!(short.observe(a, 150));
    }
}
