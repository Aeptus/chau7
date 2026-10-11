//! Port of `AI/AITerminalLogSession.swift` (`AITerminalLogSession`,
//! `AIEventLogWriter`) and the AI log helpers of
//! `TerminalSessionModel+ShellIntegration.swift` (`processAILogOutput`,
//! `parseAIExitCode`, `sanitizeToolName`, the Started/Finished messages).
//!
//! While an AI tool runs in a tab, its output is appended to
//! `<logs>/<tool>-pty.log` and typed lines go in as `[INPUT] ...` (secrets
//! redacted). The file is trimmed to its newest half when it passes the cap
//! (10 MB, `CHAU7_PTY_LOG_MAX_BYTES`), checked every 200 writes or after a
//! failed write. Start, finish and failure lines go to the AI events log as
//! JSON lines.
//!
//! Chau7 Next writes both files in its own data root (`DataRoot::ai_logs_dir`,
//! `DataRoot::ai_events_log`), never in the Swift app's files.

use std::fs::OpenOptions;
use std::io::Write;
use std::path::{Path, PathBuf};

use serde_json::{Map, Value};

use crate::sensitive_input;

/// Default PTY log cap (`10 * 1024 * 1024`).
pub const DEFAULT_MAX_BYTES: u64 = 10 * 1024 * 1024;

/// Trim check interval, in writes.
const TRIM_EVERY_WRITES: u64 = 200;

/// `ESC ] 9 ; chau7 ; exit=` ... `BEL`: exit marker an AI wrapper prints.
pub const EXIT_MARKER_PREFIX: &[u8] = b"\x1b]9;chau7;exit=";
pub const EXIT_MARKER_SUFFIX: &[u8] = b"\x07";

/// The PTY log cap from `CHAU7_PTY_LOG_MAX_BYTES` (`CHAU7_NEXT_` first), else
/// 10 MB. Values that are not positive integers are ignored.
pub fn max_bytes_from_env(get: impl Fn(&str) -> Option<String>) -> u64 {
    let name = crate::env_vars::PTY_LOG_MAX_BYTES;
    get(&name.replacen("CHAU7_", "CHAU7_NEXT_", 1))
        .or_else(|| get(name))
        .and_then(|v| v.trim().parse::<u64>().ok())
        .filter(|v| *v > 0)
        .unwrap_or(DEFAULT_MAX_BYTES)
}

/// File name slug of a tool (`sanitizeToolName`): lowercase alphanumerics,
/// spaces, `-` and `_` become one `-`, other characters are dropped;
/// "ai-cli" when nothing is left.
pub fn tool_slug(tool: &str) -> String {
    let mut slug = String::new();
    for c in tool.trim().to_lowercase().chars() {
        if c.is_alphanumeric() {
            slug.push(c);
        } else if matches!(c, ' ' | '-' | '_') && !slug.ends_with('-') {
            slug.push('-');
        }
    }
    while slug.ends_with('-') {
        slug.pop();
    }
    if slug.is_empty() {
        "ai-cli".to_string()
    } else {
        slug
    }
}

/// `<dir>/<slug>-pty.log`.
pub fn pty_log_path(dir: &Path, tool: &str) -> PathBuf {
    dir.join(format!("{}-pty.log", tool_slug(tool)))
}

/// Appends `data` to `path`, creating the file and its folder.
fn append(path: &Path, data: &[u8]) -> bool {
    if let Some(parent) = path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    OpenOptions::new()
        .create(true)
        .append(true)
        .open(path)
        .and_then(|mut f| f.write_all(data))
        .is_ok()
}

/// One AI tool run's PTY log (`AITerminalLogSession`). Not thread-safe: the
/// caller owns it on one thread (the app gives it a writer thread).
#[derive(Debug)]
pub struct AiLogSession {
    tool: String,
    path: PathBuf,
    max_bytes: u64,
    input: Vec<u8>,
    writes: u64,
}

impl AiLogSession {
    pub fn new(tool: &str, path: PathBuf, max_bytes: u64) -> Self {
        Self {
            tool: tool.to_string(),
            path,
            max_bytes,
            input: Vec::new(),
            writes: 0,
        }
    }

    pub fn tool(&self) -> &str {
        &self.tool
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    /// Output bytes, appended as is (`recordOutput`).
    pub fn record_output(&mut self, data: &[u8]) {
        if data.is_empty() {
            return;
        }
        let ok = append(&self.path, data);
        self.writes += 1;
        if !ok || self.writes.is_multiple_of(TRIM_EVERY_WRITES) {
            self.trim_if_needed();
        }
    }

    /// Typed text; complete lines are written as `[INPUT] ...` (`recordInput`).
    pub fn record_input(&mut self, text: &str) {
        if text.is_empty() {
            return;
        }
        self.input.extend_from_slice(text.as_bytes());
        if text.contains(['\n', '\r']) {
            self.flush_input();
        }
    }

    /// Writes pending input (`close`).
    pub fn close(&mut self) {
        self.flush_input();
    }

    fn flush_input(&mut self) {
        if self.input.is_empty() {
            return;
        }
        let text = String::from_utf8_lossy(&self.input).to_string();
        self.input.clear();
        if let Some(line) = sensitive_input::sanitized_input_line_for_persistence(&text, false) {
            append(&self.path, format!("[INPUT] {line}\n").as_bytes());
        }
    }

    /// Keeps the newest half when the file is over the cap (`trimLogIfNeeded`).
    pub fn trim_if_needed(&self) {
        trim_file(&self.path, self.max_bytes);
    }
}

/// Keeps the last `max / 2` bytes of `path` when it is larger than `max`,
/// written to a temporary file and renamed (atomic).
pub fn trim_file(path: &Path, max: u64) {
    if max == 0 {
        return;
    }
    let Ok(meta) = std::fs::metadata(path) else {
        return;
    };
    if meta.len() <= max {
        return;
    }
    let keep = (max / 2) as usize;
    let Ok(data) = std::fs::read(path) else {
        return;
    };
    let start = data.len().saturating_sub(keep);
    let tmp = path.with_extension("log.tmp");
    if std::fs::write(&tmp, &data[start..]).is_ok()
        && let Err(err) = std::fs::rename(&tmp, path)
    {
        log::error!("AI log trim failed: {err}");
    }
}

/// Splits PTY output into what goes to the log and an AI exit code
/// (`processAILogOutput`). A marker split across reads is held back:
/// output that could start a marker (up to `prefix.len() - 1` bytes) waits
/// for the next chunk.
#[derive(Debug, Default, Clone)]
pub struct ExitMarkerFilter {
    pending: Vec<u8>,
}

impl ExitMarkerFilter {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn clear(&mut self) {
        self.pending.clear();
    }

    pub fn is_empty(&self) -> bool {
        self.pending.is_empty()
    }

    /// Returns (bytes to log, exit code when a full marker was seen).
    pub fn feed(&mut self, data: &[u8]) -> (Vec<u8>, Option<i32>) {
        let mut combined = std::mem::take(&mut self.pending);
        combined.extend_from_slice(data);
        if let Some(start) = find(&combined, EXIT_MARKER_PREFIX) {
            let loggable = combined[..start].to_vec();
            let after = start + EXIT_MARKER_PREFIX.len();
            if let Some(end) = find(&combined[after..], EXIT_MARKER_SUFFIX) {
                let code = parse_exit_code(&combined[after..after + end]);
                return (loggable, code);
            }
            self.pending = combined[start..].to_vec();
            return (loggable, None);
        }
        let keep = EXIT_MARKER_PREFIX.len() - 1;
        if combined.len() > keep {
            let cut = combined.len() - keep;
            self.pending = combined[cut..].to_vec();
            combined.truncate(cut);
            return (combined, None);
        }
        self.pending = combined;
        (Vec::new(), None)
    }
}

fn find(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    if needle.is_empty() || haystack.len() < needle.len() {
        return None;
    }
    haystack.windows(needle.len()).position(|w| w == needle)
}

/// `parseAIExitCode`: a plain integer, or the digits after `exit=`.
pub fn parse_exit_code(payload: &[u8]) -> Option<i32> {
    let raw = String::from_utf8_lossy(payload).trim().to_string();
    if let Ok(value) = raw.parse::<i32>() {
        return Some(value);
    }
    let idx = raw.find("exit=")?;
    let digits: String = raw[idx + 5..]
        .chars()
        .take_while(|c| c.is_ascii_digit())
        .collect();
    digits.parse().ok()
}

/// Message of the start line (`startAILoggingIfNeeded`).
pub fn started_message(command: Option<&str>) -> String {
    match command.filter(|c| !c.is_empty()) {
        Some(command) => format!("Started: {command}"),
        None => "Started (detected from output)".to_string(),
    }
}

/// Event type and message of the finish line (`finishAILogging`): "failed"
/// for a non-zero exit code, else "finished".
pub fn finished_event(exit_code: Option<i32>, command: Option<&str>) -> (&'static str, String) {
    let kind = match exit_code {
        Some(code) if code != 0 => "failed",
        _ => "finished",
    };
    let title = if kind == "failed" {
        "Failed"
    } else {
        "Finished"
    };
    let message = match (command.filter(|c| !c.is_empty()), exit_code) {
        (Some(command), Some(code)) => format!("{title} (exit {code}): {command}"),
        (Some(command), None) => format!("{title}: {command}"),
        (None, Some(code)) => format!("{title} (exit {code})"),
        (None, None) => title.to_string(),
    };
    (kind, message)
}

/// One AI events log line (`AIEventLogWriter.appendEvent`): `source`,
/// `type`, `tool`, `message`, `ts`.
pub fn event_line(kind: &str, tool: &str, message: &str, source: &str, ts: &str) -> String {
    let mut map = Map::new();
    map.insert("source".into(), Value::String(source.into()));
    map.insert("type".into(), Value::String(kind.into()));
    map.insert("tool".into(), Value::String(tool.into()));
    map.insert("message".into(), Value::String(message.into()));
    map.insert("ts".into(), Value::String(ts.into()));
    Value::Object(map).to_string()
}

/// Appends one event line to the AI events log. Returns false when the
/// write failed.
pub fn append_event(path: &Path, kind: &str, tool: &str, message: &str, source: &str) -> bool {
    let mut line = event_line(kind, tool, message, source, &super::event::now_iso8601());
    line.push('\n');
    let ok = append(path, line.as_bytes());
    if !ok {
        log::warn!("Failed to append AI events log at {}", path.display());
    }
    ok
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_dir(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "chau7-next-ai-log-{name}-{}-{}",
            std::process::id(),
            uuid::Uuid::new_v4()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn record_input_persists_normal_commands() {
        let dir = temp_dir("input");
        let path = dir.join("pty.log");
        let mut session = AiLogSession::new("Claude", path.clone(), DEFAULT_MAX_BYTES);
        session.record_input("echo hello\n");
        session.close();
        assert_eq!(
            std::fs::read_to_string(&path).unwrap(),
            "[INPUT] echo hello\n"
        );
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn record_input_redacts_inline_secrets() {
        let dir = temp_dir("redact");
        let path = dir.join("pty.log");
        let mut session = AiLogSession::new("Claude", path.clone(), DEFAULT_MAX_BYTES);
        session.record_input("curl -H 'Authorization: Bearer secret-token' https://example.com\n"); // gitleaks:allow - deliberately fake bearer token tests redaction
        session.close();
        assert_eq!(
            std::fs::read_to_string(&path).unwrap(),
            format!("[INPUT] curl {}\n", sensitive_input::REDACTED_PLACEHOLDER)
        );
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn partial_input_waits_for_newline_or_close() {
        let dir = temp_dir("partial");
        let path = dir.join("pty.log");
        let mut session = AiLogSession::new("Codex", path.clone(), DEFAULT_MAX_BYTES);
        session.record_output(b"hello ");
        session.record_input("ls");
        assert_eq!(std::fs::read_to_string(&path).unwrap(), "hello ");
        session.record_input(" -la\r");
        assert_eq!(
            std::fs::read_to_string(&path).unwrap(),
            "hello [INPUT] ls -la\n"
        );
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn trim_keeps_newest_half() {
        let dir = temp_dir("trim");
        let path = dir.join("pty.log");
        std::fs::write(&path, b"0123456789abcdef").unwrap();
        trim_file(&path, 10);
        assert_eq!(std::fs::read(&path).unwrap(), b"bcdef");
        trim_file(&path, 10);
        assert_eq!(std::fs::read(&path).unwrap(), b"bcdef");
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn slug_and_path() {
        assert_eq!(tool_slug("Claude"), "claude");
        assert_eq!(tool_slug("GitHub Copilot"), "github-copilot");
        assert_eq!(tool_slug("a _- b"), "a-b");
        assert_eq!(tool_slug("  !!  "), "ai-cli");
        assert_eq!(tool_slug("Amazon Q-"), "amazon-q");
        assert_eq!(
            pty_log_path(Path::new("/logs"), "Codex"),
            PathBuf::from("/logs/codex-pty.log")
        );
    }

    #[test]
    fn exit_marker_in_one_chunk() {
        let mut filter = ExitMarkerFilter::new();
        let (log, code) = filter.feed(b"done\x1b]9;chau7;exit=3\x07rest");
        assert_eq!(log, b"done");
        assert_eq!(code, Some(3));
        assert!(filter.is_empty());
    }

    #[test]
    fn exit_marker_split_across_chunks() {
        let mut filter = ExitMarkerFilter::new();
        // Shorter than the prefix: everything waits.
        let (log, code) = filter.feed(b"output\x1b]9;ch");
        assert_eq!((log.len(), code), (0, None));
        let (log, code) = filter.feed(b"au7;exit=0");
        assert_eq!((log.as_slice(), code), (&b"output"[..], None));
        let (log, code) = filter.feed(b"\x07");
        assert_eq!((log.len(), code), (0, Some(0)));
    }

    #[test]
    fn plain_output_holds_back_a_possible_prefix() {
        let mut filter = ExitMarkerFilter::new();
        let (log, code) = filter.feed(b"abcdefghijklmnopqrstuvwxyz");
        assert_eq!(code, None);
        let keep = EXIT_MARKER_PREFIX.len() - 1;
        assert_eq!(log.len(), 26 - keep);
        let (log2, _) = filter.feed(b"");
        assert!(log2.len() <= keep);
    }

    #[test]
    fn exit_code_payloads() {
        assert_eq!(parse_exit_code(b" 12 "), Some(12));
        assert_eq!(parse_exit_code(b"exit=7;x"), Some(7));
        assert_eq!(parse_exit_code(b"nope"), None);
    }

    #[test]
    fn messages() {
        assert_eq!(started_message(Some("claude")), "Started: claude");
        assert_eq!(started_message(None), "Started (detected from output)");
        assert_eq!(
            finished_event(Some(1), Some("codex")),
            ("failed", "Failed (exit 1): codex".to_string())
        );
        assert_eq!(
            finished_event(Some(0), None),
            ("finished", "Finished (exit 0)".to_string())
        );
        assert_eq!(
            finished_event(None, Some("x")),
            ("finished", "Finished: x".to_string())
        );
        assert_eq!(finished_event(None, None).1, "Finished");
    }

    #[test]
    fn event_lines_parse_back() {
        let line = event_line(
            "info",
            "Claude",
            "Started: claude",
            "terminal_session",
            "2026-01-01T00:00:00Z",
        );
        let event = crate::ai::event::parse_line(&line).unwrap();
        assert_eq!(event.event_type, "info");
        assert_eq!(event.tool, "Claude");
        assert_eq!(event.source.raw_value(), "terminal_session");
    }

    #[test]
    fn max_bytes_env() {
        assert_eq!(max_bytes_from_env(|_| None), DEFAULT_MAX_BYTES);
        assert_eq!(
            max_bytes_from_env(|k| (k == "CHAU7_PTY_LOG_MAX_BYTES").then(|| "100".into())),
            100
        );
        assert_eq!(
            max_bytes_from_env(|k| (k == "CHAU7_PTY_LOG_MAX_BYTES").then(|| "-1".into())),
            DEFAULT_MAX_BYTES
        );
    }
}
