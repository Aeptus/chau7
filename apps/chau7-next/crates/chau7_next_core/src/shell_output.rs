//! Plain text from terminal output, and the (dev) PTY capture log format.
//!
//! [`normalize`] ports `Terminal/Rendering/TerminalNormalizer.swift`:
//! backspaces applied, CSI sequences removed, control characters other than
//! tab dropped. [`escape_for_capture`] and [`capture_line`] port the log
//! format of `Terminal/Rendering/TerminalOutputCapture.swift`
//! (`<ISO 8601> | PTY | <source> | bytes=<n> | <escaped>`).

use std::sync::LazyLock;

use regex::Regex;

static ANSI: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"\x1b\[[0-9;?]*[ -/]*[@-~]").expect("ANSI pattern"));

/// Backspaces applied, ANSI codes and control characters removed.
pub fn normalize(input: &str) -> String {
    let applied = apply_backspaces(input);
    let stripped = ANSI.replace_all(&applied, "");
    stripped
        .chars()
        .filter(|&c| c == '\t' || c as u32 >= 0x20)
        .collect()
}

/// Backspace (BS and DEL) removes the previous character; ANSI codes kept.
pub fn apply_backspaces(input: &str) -> String {
    let mut out: Vec<char> = Vec::with_capacity(input.len());
    for c in input.chars() {
        if c == '\u{8}' || c == '\u{7f}' {
            out.pop();
        } else {
            out.push(c);
        }
    }
    out.into_iter().collect()
}

/// Bytes as printable ASCII: `\x1b`, `\n`, `\r`, `\t`, `\xNN` for others.
pub fn escape_for_capture(data: &[u8]) -> String {
    let mut out = String::with_capacity(data.len() * 2);
    for &b in data {
        match b {
            0x1b => out.push_str("\\x1b"),
            b'\n' => out.push_str("\\n"),
            b'\r' => out.push_str("\\r"),
            b'\t' => out.push_str("\\t"),
            0x20..=0x7e => out.push(b as char),
            other => out.push_str(&format!("\\x{other:02X}")),
        }
    }
    out
}

/// One capture log line, with its newline.
pub fn capture_line(timestamp: &str, source: &str, data: &[u8]) -> String {
    format!(
        "{timestamp} | PTY | {source} | bytes={} | {}\n",
        data.len(),
        escape_for_capture(data)
    )
}

/// Default size cap of the capture log (20 MB, `CHAU7_PTY_DUMP_MAX_BYTES`).
pub const DEFAULT_CAPTURE_MAX_BYTES: u64 = 20 * 1024 * 1024;

/// Whether a `CHAU7_PTY_DUMP` / `CHAU7_TRACE_PTY` value turns capture on.
pub fn capture_enabled(value: Option<&str>) -> bool {
    matches!(value, Some(v) if v == "1" || v.eq_ignore_ascii_case("true"))
}

/// Bytes to keep from the end of a log of `size` bytes over `max` (half the
/// cap), or `None` when it is under the cap.
pub fn capture_trim_keep(size: u64, max: u64) -> Option<u64> {
    if max == 0 || size <= max {
        None
    } else {
        Some(max / 2)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn normalizes() {
        assert_eq!(normalize("abc\u{8}d"), "abd");
        assert_eq!(normalize("\x1b[31mred\x1b[0m\x07!"), "red!");
        assert_eq!(normalize("a\tb\r\n"), "a\tb");
        assert_eq!(apply_backspaces("\x1b[1mx\x7f"), "\x1b[1m");
        assert_eq!(normalize("\u{8}x"), "x");
    }

    #[test]
    fn capture_format() {
        assert_eq!(
            escape_for_capture(b"\x1b[31mhi\n\r\t\x00"),
            "\\x1b[31mhi\\n\\r\\t\\x00"
        );
        assert_eq!(
            capture_line("2024-01-15T10:30:45Z", "read", b"ok\n"),
            "2024-01-15T10:30:45Z | PTY | read | bytes=3 | ok\\n\n"
        );
        assert!(capture_enabled(Some("1")));
        assert!(capture_enabled(Some("TRUE")));
        assert!(!capture_enabled(Some("0")));
        assert!(!capture_enabled(None));
        assert_eq!(capture_trim_keep(10, 20), None);
        assert_eq!(capture_trim_keep(30, 20), Some(10));
    }
}
