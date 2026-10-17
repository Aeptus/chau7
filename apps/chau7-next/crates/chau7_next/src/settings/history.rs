//! History and log monitoring (`HistorySettingsView.swift`,
//! `LogsSettingsView.swift`, the monitor fields of `AppModel`).
//!
//! Swift keeps these in UserDefaults (`feature.persistentHistory`,
//! `history.maxRecords`, `isIdleMonitoring`, `idleSeconds`, ...), not in
//! `config.toml`, so every key lives under `[next]`.
//!
//! An empty terminal log path means the default file in Chau7 Next's AI logs
//! folder (`DataRoot::ai_logs_dir`); an empty history path means that history
//! file is not followed, as in Swift.

use chau7_next_core::config::RawValue;
use chau7_next_core::history_monitor::{
    DEFAULT_IDLE_SECONDS, DEFAULT_STALE_SECONDS, idle_seconds, stale_seconds,
};
use chau7_next_core::history_store::{DEFAULT_MAX_RECORDS, MAX_MAX_RECORDS, MIN_MAX_RECORDS};

use super::{ConfigSink, ConfigSource, SettingsDomain};

pub const DEFAULT_CODEX_HISTORY: &str = "~/.codex/history.jsonl";
pub const DEFAULT_CLAUDE_HISTORY: &str = "~/.claude/history.jsonl";

#[derive(Debug, Clone, PartialEq)]
pub struct HistorySettings {
    /// `feature.persistentHistory`: record commands to disk.
    pub persistent_history: bool,
    /// `history.maxRecords`, 10,000 to 100,000.
    pub max_records: usize,
    /// `isIdleMonitoring`: follow the Claude and Codex history files.
    pub monitor_history_logs: bool,
    /// `idleSeconds` (text, as typed).
    pub idle_seconds: String,
    /// `staleSeconds` (text, as typed).
    pub stale_seconds: String,
    /// `codexHistoryPath`.
    pub codex_history_path: String,
    /// `claudeHistoryPath`.
    pub claude_history_path: String,
    /// `isTerminalMonitoring`: follow the PTY wrapper logs.
    pub monitor_terminal_logs: bool,
    /// `isTerminalNormalize`: strip ANSI codes and control characters.
    pub terminal_normalize: bool,
    /// `isTerminalAnsi`: draw ANSI colors in the log viewer.
    pub terminal_ansi: bool,
    /// `codexTerminalPath`; empty means the default file.
    pub codex_terminal_log: String,
    /// `claudeTerminalPath`; empty means the default file.
    pub claude_terminal_log: String,
}

impl Default for HistorySettings {
    fn default() -> Self {
        Self {
            persistent_history: true,
            max_records: DEFAULT_MAX_RECORDS,
            monitor_history_logs: true,
            idle_seconds: "5".into(),
            stale_seconds: "180".into(),
            codex_history_path: DEFAULT_CODEX_HISTORY.into(),
            claude_history_path: DEFAULT_CLAUDE_HISTORY.into(),
            monitor_terminal_logs: true,
            terminal_normalize: true,
            terminal_ansi: true,
            codex_terminal_log: String::new(),
            claude_terminal_log: String::new(),
        }
    }
}

impl HistorySettings {
    /// Seconds of silence before a session counts as idle (`AppModel.idleSeconds`).
    pub fn idle_secs(&self) -> f64 {
        idle_seconds(&self.idle_seconds)
    }

    /// Seconds before a session counts as closed (`AppModel.staleSeconds`).
    pub fn stale_secs(&self) -> f64 {
        stale_seconds(&self.stale_seconds, self.idle_secs())
    }

    /// Typed seconds text brought into range and formatted like Swift
    /// (`normalizeSecondsText`): whole numbers without a decimal point.
    pub fn normalized_seconds(text: &str, default: f64, minimum: f64) -> String {
        let value = text.trim().parse::<f64>().unwrap_or(default).max(minimum);
        if value.fract() == 0.0 {
            format!("{}", value as i64)
        } else {
            value.to_string()
        }
    }

    /// Apply the idle text, then the stale text, as the Swift fields do:
    /// idle at least 1, stale at least idle plus 1.
    pub fn normalize_seconds(&mut self) {
        self.idle_seconds = Self::normalized_seconds(&self.idle_seconds, DEFAULT_IDLE_SECONDS, 1.0);
        let idle = self.idle_secs();
        self.stale_seconds =
            Self::normalized_seconds(&self.stale_seconds, DEFAULT_STALE_SECONDS, idle + 1.0);
    }
}

fn load_bool(src: &ConfigSource, key: &str, target: &mut bool) {
    if let Some(v) = src.next(key).and_then(RawValue::as_bool) {
        *target = v;
    }
}

fn load_string(src: &ConfigSource, key: &str) -> Option<String> {
    match src.next(key)? {
        RawValue::String(s) => Some(s.clone()),
        RawValue::Int(i) => Some(i.to_string()),
        RawValue::Double(d) => Some(d.to_string()),
        RawValue::Bool(b) => Some(b.to_string()),
    }
}

impl SettingsDomain for HistorySettings {
    fn load(&mut self, src: &ConfigSource) {
        load_bool(src, "persistent_history", &mut self.persistent_history);
        if let Some(v) = src.next("history_max_records").and_then(RawValue::as_int) {
            self.max_records = (v.max(0) as usize).clamp(MIN_MAX_RECORDS, MAX_MAX_RECORDS);
        }
        load_bool(src, "monitor_history_logs", &mut self.monitor_history_logs);
        if let Some(v) = load_string(src, "history_idle_seconds") {
            self.idle_seconds = v.trim().to_string();
        }
        if let Some(v) = load_string(src, "history_stale_seconds") {
            self.stale_seconds = v.trim().to_string();
        }
        if let Some(v) = load_string(src, "codex_history_path") {
            self.codex_history_path = v.trim().to_string();
        }
        if let Some(v) = load_string(src, "claude_history_path") {
            self.claude_history_path = v.trim().to_string();
        }
        load_bool(
            src,
            "monitor_terminal_logs",
            &mut self.monitor_terminal_logs,
        );
        load_bool(src, "terminal_log_normalize", &mut self.terminal_normalize);
        load_bool(src, "terminal_log_ansi", &mut self.terminal_ansi);
        if let Some(v) = load_string(src, "codex_terminal_log") {
            self.codex_terminal_log = v.trim().to_string();
        }
        if let Some(v) = load_string(src, "claude_terminal_log") {
            self.claude_terminal_log = v.trim().to_string();
        }
    }

    fn save(&self, out: &mut ConfigSink) {
        out.set_next("persistent_history", self.persistent_history);
        out.set_next("history_max_records", self.max_records);
        out.set_next("monitor_history_logs", self.monitor_history_logs);
        out.set_next("history_idle_seconds", format!("\"{}\"", self.idle_seconds));
        out.set_next(
            "history_stale_seconds",
            format!("\"{}\"", self.stale_seconds),
        );
        out.set_next(
            "codex_history_path",
            format!("\"{}\"", self.codex_history_path),
        );
        out.set_next(
            "claude_history_path",
            format!("\"{}\"", self.claude_history_path),
        );
        out.set_next("monitor_terminal_logs", self.monitor_terminal_logs);
        out.set_next("terminal_log_normalize", self.terminal_normalize);
        out.set_next("terminal_log_ansi", self.terminal_ansi);
        out.set_next(
            "codex_terminal_log",
            format!("\"{}\"", self.codex_terminal_log),
        );
        out.set_next(
            "claude_terminal_log",
            format!("\"{}\"", self.claude_terminal_log),
        );
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::settings::{load_text, round_trip};

    #[test]
    fn defaults_follow_swift() {
        let h = HistorySettings::default();
        assert!(h.persistent_history && h.monitor_history_logs && h.monitor_terminal_logs);
        assert_eq!(h.max_records, 50_000);
        assert_eq!((h.idle_secs(), h.stale_secs()), (5.0, 180.0));
        assert!(h.terminal_normalize && h.terminal_ansi);
        assert_eq!(h.codex_history_path, "~/.codex/history.jsonl");
        assert_eq!(h.claude_history_path, "~/.claude/history.jsonl");
    }

    #[test]
    fn round_trips() {
        let h = HistorySettings {
            persistent_history: false,
            max_records: 25_000,
            monitor_history_logs: false,
            idle_seconds: "12".into(),
            stale_seconds: "400".into(),
            codex_history_path: "/tmp/codex.jsonl".into(),
            claude_history_path: String::new(),
            monitor_terminal_logs: false,
            terminal_normalize: false,
            terminal_ansi: false,
            codex_terminal_log: "/tmp/c.log".into(),
            claude_terminal_log: "/tmp/cl.log".into(),
        };
        assert_eq!(round_trip(&h), h);
    }

    #[test]
    fn max_records_is_clamped() {
        let low: HistorySettings = load_text("[next]\nhistory_max_records = 5\n");
        assert_eq!(low.max_records, 10_000);
        let high: HistorySettings = load_text("[next]\nhistory_max_records = 900000\n");
        assert_eq!(high.max_records, 100_000);
    }

    #[test]
    fn seconds_text_is_normalized_like_swift() {
        let mut h = HistorySettings {
            idle_seconds: "0.2".into(),
            stale_seconds: "1".into(),
            ..HistorySettings::default()
        };
        h.normalize_seconds();
        assert_eq!(h.idle_seconds, "1");
        assert_eq!(h.stale_seconds, "2");
        h.idle_seconds = "7.5".into();
        h.stale_seconds = "oops".into();
        h.normalize_seconds();
        assert_eq!(h.idle_seconds, "7.5");
        assert_eq!(h.stale_seconds, "180");
    }
}
