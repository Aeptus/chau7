//! Log formats and policies (`Logging/Log.swift`, `Logging/LogEnhanced.swift`).
//!
//! Pure logic only: line formats, categories, structured entries, correlation
//! ids, the size policy of the log files and the filters of the Debug Console
//! log tab. The file writer, the live feed and the macOS unified log are in
//! `chau7_next/src/logging/`.
//!
//! Line formats (the Debug Console filters on the `[LEVEL]` and `[Category]`
//! substrings, or `"level":"X"` / `"category":"X"` in JSON lines):
//!
//! - plain: `[Chau7][INFO] 2026-01-15T10:30:45.123Z message`
//! - category: `2026-01-15T10:30:45.123Z [WARN][Tabs] [a1b2c3d4] message (12.34ms) [mem:123.4MB] {k=v} @File.rs:42 func`

use std::collections::{BTreeMap, BTreeSet};

use chrono::{DateTime, Utc};
use serde::Serialize;

use crate::iso8601::format_iso8601;

/// The five log levels, most verbose first (`Log.swift`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum LogLevel {
    Trace,
    Debug,
    Info,
    Warn,
    Error,
}

impl LogLevel {
    pub const ALL: [LogLevel; 5] = [
        LogLevel::Trace,
        LogLevel::Debug,
        LogLevel::Info,
        LogLevel::Warn,
        LogLevel::Error,
    ];

    /// The tag written in the line (`INFO`, `WARN`...).
    pub fn tag(self) -> &'static str {
        match self {
            LogLevel::Trace => "TRACE",
            LogLevel::Debug => "DEBUG",
            LogLevel::Info => "INFO",
            LogLevel::Warn => "WARN",
            LogLevel::Error => "ERROR",
        }
    }

    pub fn from_tag(tag: &str) -> Option<LogLevel> {
        Self::ALL
            .into_iter()
            .find(|l| l.tag().eq_ignore_ascii_case(tag))
    }
}

/// Categories for filtering logs by component (`LogCategory`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum LogCategory {
    App,
    Tabs,
    Terminal,
    Render,
    Input,
    Notifications,
    Snippets,
    Network,
    Performance,
    Memory,
    Recovery,
    Cto,
}

impl LogCategory {
    pub const ALL: [LogCategory; 12] = [
        LogCategory::App,
        LogCategory::Tabs,
        LogCategory::Terminal,
        LogCategory::Render,
        LogCategory::Input,
        LogCategory::Notifications,
        LogCategory::Snippets,
        LogCategory::Network,
        LogCategory::Performance,
        LogCategory::Memory,
        LogCategory::Recovery,
        LogCategory::Cto,
    ];

    /// Raw value, written between brackets in the line.
    pub fn label(self) -> &'static str {
        match self {
            LogCategory::App => "App",
            LogCategory::Tabs => "Tabs",
            LogCategory::Terminal => "Terminal",
            LogCategory::Render => "Render",
            LogCategory::Input => "Input",
            LogCategory::Notifications => "Notifications",
            LogCategory::Snippets => "Snippets",
            LogCategory::Network => "Network",
            LogCategory::Performance => "Perf",
            LogCategory::Memory => "Memory",
            LogCategory::Recovery => "Recovery",
            LogCategory::Cto => "CTO",
        }
    }

    pub fn emoji(self) -> &'static str {
        match self {
            LogCategory::App => "\u{1F4F1}",
            LogCategory::Tabs => "\u{1F4D1}",
            LogCategory::Terminal => "\u{1F4BB}",
            LogCategory::Render => "\u{1F3A8}",
            LogCategory::Input => "\u{2328}\u{FE0F}",
            LogCategory::Notifications => "\u{1F514}",
            LogCategory::Snippets => "\u{1F4DD}",
            LogCategory::Network => "\u{1F310}",
            LogCategory::Performance => "\u{26A1}",
            LogCategory::Memory => "\u{1F9E0}",
            LogCategory::Recovery => "\u{1F527}",
            LogCategory::Cto => "\u{1F9E9}",
        }
    }

    /// Category name in the macOS unified log (`osLogCategory`).
    pub fn os_log_category(self) -> String {
        self.label().to_lowercase()
    }

    pub fn from_label(label: &str) -> Option<LogCategory> {
        Self::ALL.into_iter().find(|c| c.label() == label)
    }
}

/// Subsystem of the macOS unified log. Swift logs under `com.chau7`; Chau7 Next
/// uses its own bundle id so both apps filter apart in Console.app.
pub const OS_LOG_SUBSYSTEM: &str = "com.chau7.next";

/// `[Chau7][INFO] <ISO 8601 with ms> <message>` (`Log.emit`).
pub fn plain_line(level: LogLevel, timestamp: DateTime<Utc>, message: &str) -> String {
    format!(
        "[Chau7][{}] {} {message}",
        level.tag(),
        format_iso8601(timestamp)
    )
}

/// A structured log entry (`LogEntry`).
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LogEntry {
    #[serde(serialize_with = "serialize_seconds_date")]
    pub timestamp: DateTime<Utc>,
    pub level: String,
    pub category: String,
    pub message: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub correlation_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub metadata: Option<BTreeMap<String, String>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub file: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub function: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub line: Option<u32>,
    /// Seconds, for performance tracking.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub duration: Option<f64>,
    #[serde(rename = "memoryMB", skip_serializing_if = "Option::is_none")]
    pub memory_mb: Option<f64>,
}

/// Swift's `.iso8601` date strategy writes whole seconds.
fn serialize_seconds_date<S: serde::Serializer>(
    date: &DateTime<Utc>,
    s: S,
) -> Result<S::Ok, S::Error> {
    s.serialize_str(&date.to_rfc3339_opts(chrono::SecondsFormat::Secs, true))
}

impl LogEntry {
    pub fn new(
        timestamp: DateTime<Utc>,
        level: LogLevel,
        category: LogCategory,
        message: impl Into<String>,
    ) -> Self {
        Self {
            timestamp,
            level: level.tag().to_string(),
            category: category.label().to_string(),
            message: message.into(),
            correlation_id: None,
            metadata: None,
            file: None,
            function: None,
            line: None,
            duration: None,
            memory_mb: None,
        }
    }

    /// `formattedText`.
    pub fn formatted_text(&self) -> String {
        let mut parts = vec![
            format_iso8601(self.timestamp),
            format!("[{}][{}]", self.level, self.category),
        ];
        if let Some(cid) = &self.correlation_id {
            parts.push(format!("[{}]", cid.chars().take(8).collect::<String>()));
        }
        parts.push(self.message.clone());
        if let Some(duration) = self.duration {
            parts.push(format!("({:.2}ms)", duration * 1000.0));
        }
        if let Some(memory) = self.memory_mb {
            parts.push(format!("[mem:{memory:.1}MB]"));
        }
        if let Some(meta) = self.metadata.as_ref().filter(|m| !m.is_empty()) {
            let text = meta
                .iter()
                .map(|(k, v)| format!("{k}={v}"))
                .collect::<Vec<_>>()
                .join(" ");
            parts.push(format!("{{{text}}}"));
        }
        // Source location for trace and error lines.
        if (self.level == "TRACE" || self.level == "ERROR")
            && let (Some(file), Some(function), Some(line)) =
                (&self.file, &self.function, self.line)
        {
            let name = file.rsplit(['/', '\\']).next().unwrap_or(file);
            parts.push(format!("@{name}:{line} {function}"));
        }
        parts.join(" ")
    }

    /// One JSON line (`jsonString`).
    pub fn json_string(&self) -> Option<String> {
        serde_json::to_string(self).ok()
    }
}

/// `PerfTracker.end`: slower than 100 ms is a warning, else a trace line.
pub fn perf_level(duration_secs: f64) -> LogLevel {
    if duration_secs > 0.1 {
        LogLevel::Warn
    } else {
        LogLevel::Trace
    }
}

/// `memDelta` metadata: only a change over 1 MB is worth a note.
pub fn memory_delta_text(start_mb: f64, end_mb: f64) -> Option<String> {
    let delta = end_mb - start_mb;
    (delta.abs() > 1.0).then(|| format!("{delta:.1}MB"))
}

/// Correlation ids of nested scoped operations (`LogCorrelation`). The id of
/// the innermost running operation is the current one.
#[derive(Debug, Default, Clone)]
pub struct CorrelationStack {
    stack: Vec<(String, String)>,
}

impl CorrelationStack {
    /// Start an operation; returns its short id (8 lowercase hex digits).
    pub fn begin(&mut self, operation: &str, id: String) -> String {
        self.stack.push((operation.to_string(), id.clone()));
        id
    }

    pub fn end(&mut self) {
        self.stack.pop();
    }

    pub fn current(&self) -> Option<&str> {
        self.stack.last().map(|(_, id)| id.as_str())
    }

    pub fn depth(&self) -> usize {
        self.stack.len()
    }
}

/// A fresh correlation id: 8 lowercase hex digits of a UUID.
pub fn new_correlation_id() -> String {
    uuid::Uuid::new_v4().simple().to_string()[..8].to_string()
}

// ----- size policy ----------------------------------------------------------

/// Writes between size checks of the log file (`writeCount.isMultiple(of: 200)`).
pub const TRIM_CHECK_EVERY: u64 = 200;

/// Default cap of an AI PTY log (`CHAU7_PTY_LOG_MAX_BYTES`).
pub const DEFAULT_PTY_LOG_MAX_BYTES: u64 = 10 * 1024 * 1024;

/// Bytes kept from the end of a PTY log cut at launch (`purgeLargePTYLogs`).
pub const PTY_PURGE_KEEP_BYTES: u64 = 5 * 1024 * 1024;

/// Bytes to keep from the end of a file of `size` bytes with a cap of `max`:
/// half the cap once the file is over it (`trimLogFileIfNeeded`).
pub fn trim_keep(size: u64, max: u64) -> Option<u64> {
    if max == 0 || size <= max {
        None
    } else {
        Some(max / 2)
    }
}

/// Launch-time purge: a `*-pty.log` over 10 MB is cut to its last 5 MB.
pub fn purge_keep(size: u64) -> Option<u64> {
    (size > DEFAULT_PTY_LOG_MAX_BYTES).then_some(PTY_PURGE_KEEP_BYTES)
}

/// Whether a file name is a PTY log of an AI tool (`<tool>-pty.log`).
pub fn is_pty_log_name(name: &str) -> bool {
    name.ends_with("-pty.log")
}

/// `<tool>-pty.log` for a tool display name (`sanitizeToolName`): lowercase,
/// letters and digits kept, spaces, dashes and underscores become one dash,
/// anything else dropped; `ai-cli` when nothing is left.
pub fn pty_log_name(tool: &str) -> String {
    let mut slug = String::new();
    for c in tool.trim().to_lowercase().chars() {
        if c.is_alphanumeric() {
            slug.push(c);
        } else if (c == ' ' || c == '-' || c == '_') && !slug.ends_with('-') {
            slug.push('-');
        }
    }
    if slug.ends_with('-') {
        slug.pop();
    }
    if slug.is_empty() {
        slug = "ai-cli".to_string();
    }
    format!("{slug}-pty.log")
}

// ----- Debug Console log filter ---------------------------------------------

/// Whether `line` carries the level tag, in plain or JSON form.
pub fn line_has_level(level: &str, line: &str) -> bool {
    let upper = level.to_uppercase();
    line.contains(&format!("[{upper}]"))
        || line.contains(&format!("\"level\":\"{upper}\""))
        || line.contains(&format!("\"level\":\"{}\"", upper.to_lowercase()))
}

/// Whether `line` carries the category tag, in plain or JSON form.
pub fn line_has_category(category: &str, line: &str) -> bool {
    line.contains(&format!("[{category}]"))
        || line.contains(&format!("\"category\":\"{category}\""))
        || line.contains(&format!("\"category\":\"{}\"", category.to_lowercase()))
}

/// The filters of the Logs tab: levels, categories and a text filter.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LogFilter {
    pub levels: BTreeSet<LogLevel>,
    pub categories: BTreeSet<LogCategory>,
    pub text: String,
}

impl Default for LogFilter {
    fn default() -> Self {
        Self {
            levels: LogLevel::ALL.into_iter().collect(),
            categories: LogCategory::ALL.into_iter().collect(),
            text: String::new(),
        }
    }
}

impl LogFilter {
    /// The "Errors" preset: warnings and errors.
    pub fn errors_only(&mut self) {
        self.levels = [LogLevel::Warn, LogLevel::Error].into_iter().collect();
    }

    pub fn all_levels(&mut self) {
        self.levels = LogLevel::ALL.into_iter().collect();
    }

    pub fn toggle_level(&mut self, level: LogLevel) {
        if !self.levels.remove(&level) {
            self.levels.insert(level);
        }
    }

    pub fn toggle_category(&mut self, category: LogCategory) {
        if !self.categories.remove(&category) {
            self.categories.insert(category);
        }
    }

    /// `filteredLogs` for one line. A line with no category tag (the plain
    /// `Log.info` format) always passes the category filter.
    pub fn matches(&self, line: &str) -> bool {
        if !self.levels.iter().any(|l| line_has_level(l.tag(), line)) {
            return false;
        }
        let tagged = LogCategory::ALL
            .iter()
            .any(|c| line_has_category(c.label(), line));
        if tagged
            && !self
                .categories
                .iter()
                .any(|c| line_has_category(c.label(), line))
        {
            return false;
        }
        self.text.is_empty() || line.to_lowercase().contains(&self.text.to_lowercase())
    }

    pub fn apply<'a>(&self, lines: &'a [String]) -> Vec<&'a String> {
        lines.iter().filter(|l| self.matches(l)).collect()
    }
}

/// The last `count` lines of `text`, newest first (`loadLogs`).
pub fn newest_lines(text: &str, count: usize) -> Vec<String> {
    let lines: Vec<&str> = text.split('\n').collect();
    let start = lines.len().saturating_sub(count);
    lines[start..].iter().rev().map(|l| l.to_string()).collect()
}

/// The last `count` lines of `text`, oldest first (snapshot `recentLogs`).
pub fn last_lines(text: &str, count: usize) -> Vec<String> {
    let lines: Vec<&str> = text.split('\n').collect();
    let start = lines.len().saturating_sub(count);
    lines[start..].iter().map(|l| l.to_string()).collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::TimeZone;

    fn at() -> DateTime<Utc> {
        Utc.with_ymd_and_hms(2026, 1, 15, 10, 30, 45).unwrap() + chrono::Duration::milliseconds(123)
    }

    #[test]
    fn plain_line_format() {
        assert_eq!(
            plain_line(LogLevel::Info, at(), "message"),
            "[Chau7][INFO] 2026-01-15T10:30:45.123Z message"
        );
    }

    #[test]
    fn categories_match_swift() {
        assert_eq!(LogCategory::ALL.len(), 12);
        assert_eq!(LogCategory::Performance.label(), "Perf");
        assert_eq!(LogCategory::Cto.os_log_category(), "cto");
        assert_eq!(LogCategory::from_label("Tabs"), Some(LogCategory::Tabs));
        assert_eq!(LogCategory::from_label("tabs"), None);
    }

    #[test]
    fn entry_text_has_every_part() {
        let mut entry = LogEntry::new(at(), LogLevel::Error, LogCategory::Tabs, "boom");
        entry.correlation_id = Some("a1b2c3d4e5f6".into());
        entry.duration = Some(0.01234);
        entry.memory_mb = Some(123.45);
        entry.metadata = Some(
            [("k".to_string(), "v".to_string()), ("a".into(), "b".into())]
                .into_iter()
                .collect(),
        );
        entry.file = Some("/src/tabs/File.rs".into());
        entry.function = Some("close()".into());
        entry.line = Some(42);
        assert_eq!(
            entry.formatted_text(),
            "2026-01-15T10:30:45.123Z [ERROR][Tabs] [a1b2c3d4] boom (12.34ms) [mem:123.5MB] {a=b k=v} @File.rs:42 close()"
        );
    }

    #[test]
    fn source_location_only_on_trace_and_error() {
        let mut entry = LogEntry::new(at(), LogLevel::Info, LogCategory::App, "hi");
        entry.file = Some("a.rs".into());
        entry.function = Some("f".into());
        entry.line = Some(1);
        assert_eq!(
            entry.formatted_text(),
            "2026-01-15T10:30:45.123Z [INFO][App] hi"
        );
        entry.level = "TRACE".into();
        assert!(entry.formatted_text().ends_with("@a.rs:1 f"));
    }

    #[test]
    fn json_line_uses_swift_keys() {
        let mut entry = LogEntry::new(at(), LogLevel::Warn, LogCategory::Memory, "m");
        entry.memory_mb = Some(2.0);
        entry.correlation_id = Some("abc".into());
        let json = entry.json_string().unwrap();
        assert!(json.contains("\"level\":\"WARN\""));
        assert!(json.contains("\"category\":\"Memory\""));
        assert!(json.contains("\"memoryMB\":2.0"));
        assert!(json.contains("\"correlationId\":\"abc\""));
        assert!(json.contains("\"timestamp\":\"2026-01-15T10:30:45Z\""));
        assert!(!json.contains("duration"));
    }

    #[test]
    fn perf_policy() {
        assert_eq!(perf_level(0.05), LogLevel::Trace);
        assert_eq!(perf_level(0.1), LogLevel::Trace);
        assert_eq!(perf_level(0.2), LogLevel::Warn);
        assert_eq!(memory_delta_text(10.0, 10.5), None);
        assert_eq!(memory_delta_text(10.0, 13.04).as_deref(), Some("3.0MB"));
        assert_eq!(memory_delta_text(10.0, 7.0).as_deref(), Some("-3.0MB"));
    }

    #[test]
    fn correlation_ids_nest() {
        let mut stack = CorrelationStack::default();
        assert_eq!(stack.current(), None);
        stack.begin("outer", "11111111".into());
        stack.begin("inner", "22222222".into());
        assert_eq!(stack.current(), Some("22222222"));
        stack.end();
        assert_eq!(stack.current(), Some("11111111"));
        stack.end();
        assert_eq!(stack.current(), None);
        assert_eq!(new_correlation_id().len(), 8);
    }

    #[test]
    fn size_policy() {
        assert_eq!(trim_keep(10, 20), None);
        assert_eq!(trim_keep(20, 20), None);
        assert_eq!(trim_keep(21, 20), Some(10));
        assert_eq!(trim_keep(100, 0), None);
        assert_eq!(purge_keep(10 * 1024 * 1024), None);
        assert_eq!(purge_keep(10 * 1024 * 1024 + 1), Some(5 * 1024 * 1024));
    }

    #[test]
    fn pty_log_names() {
        assert!(is_pty_log_name("claude-pty.log"));
        assert!(!is_pty_log_name("chau7-next.log"));
        assert_eq!(pty_log_name("Claude"), "claude-pty.log");
        assert_eq!(pty_log_name("Continue AI"), "continue-ai-pty.log");
        assert_eq!(pty_log_name("a  b_c-d"), "a-b-c-d-pty.log");
        assert_eq!(pty_log_name("  "), "ai-cli-pty.log");
        assert_eq!(pty_log_name("Co(pilot)"), "copilot-pty.log");
    }

    #[test]
    fn filter_levels_categories_and_text() {
        let plain = "[Chau7][INFO] 2026-01-15T10:30:45.123Z started".to_string();
        let tabs = "2026-01-15T10:30:45.123Z [WARN][Tabs] closed tab".to_string();
        let json = "{\"category\":\"render\",\"level\":\"ERROR\",\"message\":\"x\"}".to_string();
        let lines = vec![plain.clone(), tabs.clone(), json.clone()];
        let mut filter = LogFilter::default();
        assert_eq!(filter.apply(&lines).len(), 3);

        filter.errors_only();
        assert_eq!(filter.apply(&lines), vec![&tabs, &json]);

        filter.all_levels();
        filter.toggle_category(LogCategory::Tabs);
        // The plain line has no category tag and always passes.
        assert_eq!(filter.apply(&lines), vec![&plain, &json]);

        filter.toggle_category(LogCategory::Tabs);
        filter.text = "CLOSED".into();
        assert_eq!(filter.apply(&lines), vec![&tabs]);

        filter.text.clear();
        filter.toggle_level(LogLevel::Info);
        assert_eq!(filter.apply(&lines), vec![&tabs, &json]);
    }

    #[test]
    fn newest_and_last_lines() {
        assert_eq!(newest_lines("a\nb\nc", 2), vec!["c", "b"]);
        assert_eq!(last_lines("a\nb\nc", 2), vec!["b", "c"]);
        assert_eq!(last_lines("a", 5), vec!["a"]);
    }
}
