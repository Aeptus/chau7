//! Persistent command history records.
//!
//! Ports `apps/chau7-macos/Sources/Chau7Core/HistoryRecord.swift`:
//! `HistoryRecord` (a completed command with directory, exit code, shell, tab,
//! session, time and duration) and `FrequentCommand` (count plus recency).
//! This is not the same type as `HistoryEntry` in `shell_integration.rs`,
//! which models the shell hook lines.
//!
//! JSON matches Swift's default `Codable` output: keys `tabID` and
//! `sessionID`, `Date` as seconds since 2001-01-01, nil optionals omitted.
//! Swift's history export uses the `.iso8601` date strategy instead; a caller
//! that writes that file uses [`crate::iso8601::iso8601_seconds`] on its own
//! wrapper type.

use crate::iso8601::{reference_date, seconds_between};
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct HistoryRecord {
    /// SQLite row id; `None` for records not yet inserted.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub id: Option<i64>,
    pub command: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub directory: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub exit_code: Option<i64>,
    /// Shell that ran the command ("zsh", "bash", "fish").
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub shell: Option<String>,
    #[serde(default, rename = "tabID", skip_serializing_if = "Option::is_none")]
    pub tab_id: Option<String>,
    /// Groups commands from a single app launch.
    #[serde(default, rename = "sessionID", skip_serializing_if = "Option::is_none")]
    pub session_id: Option<String>,
    #[serde(with = "reference_date")]
    pub timestamp: DateTime<Utc>,
    /// Seconds the command took.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub duration: Option<f64>,
}

impl HistoryRecord {
    /// A record for `command` stamped now, everything else unset.
    pub fn new(command: impl Into<String>) -> Self {
        Self {
            id: None,
            command: command.into(),
            directory: None,
            exit_code: None,
            shell: None,
            tab_id: None,
            session_id: None,
            timestamp: Utc::now(),
            duration: None,
        }
    }
}

/// Aggregated frequency data for a command.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FrequentCommand {
    pub command: String,
    pub count: i64,
    #[serde(with = "reference_date")]
    pub last_used: DateTime<Utc>,
}

impl FrequentCommand {
    pub fn new(command: impl Into<String>, count: i64, last_used: DateTime<Utc>) -> Self {
        Self {
            command: command.into(),
            count,
            last_used,
        }
    }

    /// `Identifiable.id`: the command text.
    pub fn id(&self) -> &str {
        &self.command
    }

    /// Frecency score at `now`: count divided by log2 of the age in hours
    /// (at least 0.1) plus one.
    pub fn frecency_score_at(&self, now: DateTime<Utc>) -> f64 {
        let age_hours = (seconds_between(now, self.last_used) / 3600.0).max(0.1);
        self.count as f64 / (age_hours + 1.0).log2()
    }

    /// Frecency score now.
    pub fn frecency_score(&self) -> f64 {
        self.frecency_score_at(Utc::now())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::iso8601::adding_seconds;

    fn date() -> DateTime<Utc> {
        DateTime::from_timestamp(1_700_000_000, 0).unwrap()
    }

    #[test]
    fn init_with_defaults() {
        let record = HistoryRecord::new("ls -la");
        assert_eq!(record.id, None);
        assert_eq!(record.command, "ls -la");
        assert_eq!(record.directory, None);
        assert_eq!(record.exit_code, None);
        assert_eq!(record.shell, None);
        assert_eq!(record.tab_id, None);
        assert_eq!(record.session_id, None);
        assert_eq!(record.duration, None);
    }

    #[test]
    fn init_with_all_fields() {
        let record = HistoryRecord {
            id: Some(42),
            command: "git push".into(),
            directory: Some("/home/user/project".into()),
            exit_code: Some(0),
            shell: Some("zsh".into()),
            tab_id: Some("tab-1".into()),
            session_id: Some("session-abc".into()),
            timestamp: date(),
            duration: Some(3.5),
        };
        assert_eq!(record.id, Some(42));
        assert_eq!(record.command, "git push");
        assert_eq!(record.directory.as_deref(), Some("/home/user/project"));
        assert_eq!(record.exit_code, Some(0));
        assert_eq!(record.shell.as_deref(), Some("zsh"));
        assert_eq!(record.tab_id.as_deref(), Some("tab-1"));
        assert_eq!(record.session_id.as_deref(), Some("session-abc"));
        assert_eq!(record.timestamp, date());
        assert_eq!(record.duration, Some(3.5));
    }

    #[test]
    fn equality() {
        let a = HistoryRecord {
            id: Some(1),
            timestamp: date(),
            ..HistoryRecord::new("ls")
        };
        let b = a.clone();
        assert_eq!(a, b);
    }

    #[test]
    fn inequality() {
        let a = HistoryRecord {
            id: Some(1),
            timestamp: date(),
            ..HistoryRecord::new("ls")
        };
        let b = HistoryRecord {
            id: Some(2),
            ..a.clone()
        };
        assert_ne!(a, b);
    }

    #[test]
    fn codable_round_trip() {
        let original = HistoryRecord {
            id: Some(7),
            command: "make build".into(),
            directory: Some("/tmp".into()),
            exit_code: Some(1),
            shell: Some("bash".into()),
            tab_id: Some("t1".into()),
            session_id: Some("s1".into()),
            timestamp: date(),
            duration: Some(12.3),
        };
        let json = serde_json::to_string(&original).unwrap();
        let decoded: HistoryRecord = serde_json::from_str(&json).unwrap();
        assert_eq!(decoded, original);
        assert!(json.contains("\"tabID\":\"t1\""));
        assert!(json.contains("\"sessionID\":\"s1\""));
    }

    #[test]
    fn codable_with_nils() {
        let original = HistoryRecord::new("echo hi");
        let json = serde_json::to_string(&original).unwrap();
        let decoded: HistoryRecord = serde_json::from_str(&json).unwrap();
        assert_eq!(decoded.command, "echo hi");
        assert_eq!(decoded.id, None);
        assert_eq!(decoded.directory, None);
        assert_eq!(decoded.exit_code, None);
        assert!(!json.contains("directory"));
    }

    // FrequentCommand

    #[test]
    fn frequent_identifiable() {
        let cmd = FrequentCommand::new("git status", 5, Utc::now());
        assert_eq!(cmd.id(), "git status");
    }

    #[test]
    fn frequent_equality() {
        let a = FrequentCommand::new("ls", 3, date());
        let b = FrequentCommand::new("ls", 3, date());
        assert_eq!(a, b);
    }

    #[test]
    fn frecency_score_positive() {
        let cmd = FrequentCommand::new("ls", 10, Utc::now());
        assert!(cmd.frecency_score() > 0.0);
    }

    #[test]
    fn frecency_score_recent_higher_than_old() {
        let now = Utc::now();
        let week_ago = adding_seconds(now, -7.0 * 24.0 * 3600.0);
        let recent = FrequentCommand::new("ls", 5, now);
        let old = FrequentCommand::new("ls", 5, week_ago);
        assert!(recent.frecency_score() > old.frecency_score());
    }

    #[test]
    fn frecency_score_high_count_higher() {
        let now = Utc::now();
        let frequent = FrequentCommand::new("ls", 100, now);
        let rare = FrequentCommand::new("ls", 1, now);
        assert!(frequent.frecency_score() > rare.frecency_score());
    }

    #[test]
    fn frequent_codable_round_trip() {
        let original = FrequentCommand::new("npm test", 42, date());
        let json = serde_json::to_string(&original).unwrap();
        let decoded: FrequentCommand = serde_json::from_str(&json).unwrap();
        assert_eq!(decoded, original);
    }

    // Branch without a Swift test.

    #[test]
    fn frecency_age_is_floored_at_a_tenth_of_an_hour() {
        let now = date();
        let cmd = FrequentCommand::new("ls", 1, now);
        let expected = 1.0 / 1.1_f64.log2();
        assert!((cmd.frecency_score_at(now) - expected).abs() < 1e-9);
    }
}
