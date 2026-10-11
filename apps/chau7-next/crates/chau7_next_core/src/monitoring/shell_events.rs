//! Port of `Monitoring/ShellEventDetector.swift` and `ShellEventConfig` /
//! `ShellOutputPattern` (`Settings/FeatureSettings.swift`): the shell events
//! of one tab for the notification pipeline, without timers (the caller
//! ticks [`ShellEventDetector::check_long_running`] every 5 s while a
//! command runs).
//!
//! Events (`source: shell`, `tool: Shell`): `process_started`,
//! `process_ended`, `command_failed` (non-zero exit), `command_finished`
//! (only with "notify on all completions"), `exit_code_match` for watched
//! codes, `long_running` at 30 s, 1 min and 5 min, output pattern matches
//! (each pattern at most once per 5 s), `directory_changed` and
//! `git_branch_changed` (both opt-in).

use std::collections::HashMap;

use regex::Regex;
use serde::{Deserialize, Serialize};

use crate::shell_session::standardize_path;

/// Tiers of the long-running event, in seconds.
pub const LONG_RUNNING_TIERS: [u64; 3] = [30, 60, 300];
/// How often the long-running check runs.
pub const LONG_RUNNING_CHECK_SECS: u64 = 5;
/// Minimum seconds between two matches of one pattern.
pub const PATTERN_COOLDOWN: f64 = 5.0;

/// `ShellOutputPattern`.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ShellOutputPattern {
    #[serde(default = "new_id")]
    pub id: String,
    pub name: String,
    pub pattern: String,
    #[serde(default = "yes")]
    pub is_enabled: bool,
    #[serde(default = "pattern_match")]
    pub notification_type: String,
}

fn new_id() -> String {
    uuid::Uuid::new_v4().to_string().to_uppercase()
}
fn yes() -> bool {
    true
}
fn pattern_match() -> String {
    "pattern_match".into()
}

impl ShellOutputPattern {
    pub fn new(name: &str, pattern: &str, enabled: bool) -> Self {
        Self {
            id: new_id(),
            name: name.into(),
            pattern: pattern.into(),
            is_enabled: enabled,
            notification_type: pattern_match(),
        }
    }

    /// `ShellOutputPattern.defaults` (all off).
    pub fn defaults() -> Vec<Self> {
        vec![
            Self::new("Error", r"(?i)\b(error|failed|failure)\b", false),
            Self::new("Warning", r"(?i)\bwarning\b", false),
            Self::new(
                "Build Success",
                r"(?i)\b(build succeeded|compilation successful)\b",
                false,
            ),
            Self::new(
                "Test Passed",
                r"(?i)\b(tests? passed|all tests pass)\b",
                false,
            ),
            Self::new(
                "Test Failed",
                r"(?i)\b(tests? failed|test failure)\b",
                false,
            ),
        ]
    }
}

/// `ShellEventConfig`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct ShellEventConfig {
    pub output_patterns: Vec<ShellOutputPattern>,
    pub watched_exit_codes: Vec<i32>,
    pub long_running_threshold_seconds: i64,
    pub notify_on_directory_change: bool,
    pub notify_on_git_branch_change: bool,
    pub notify_on_all_command_completion: bool,
}

impl Default for ShellEventConfig {
    fn default() -> Self {
        Self {
            output_patterns: Vec::new(),
            watched_exit_codes: vec![1, 2, 126, 127, 128, 130, 137, 139, 143],
            long_running_threshold_seconds: 60,
            notify_on_directory_change: false,
            notify_on_git_branch_change: false,
            notify_on_all_command_completion: false,
        }
    }
}

impl ShellEventConfig {
    /// The config the Notifications settings edit
    /// (`notifications::settings::ShellEventConfig`, same JSON shape as
    /// `shell.eventConfig`), as the detector uses it.
    pub fn from_notification_settings(
        config: &crate::notifications::settings::ShellEventConfig,
    ) -> Self {
        serde_json::to_value(config)
            .ok()
            .and_then(|v| serde_json::from_value(v).ok())
            .unwrap_or_default()
    }
}

/// One emitted event: its type and message.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ShellEvent {
    pub event_type: String,
    pub message: String,
    /// The tab's directory when the event was raised.
    pub directory: Option<String>,
}

/// `ShellEventDetector` of one tab.
#[derive(Debug)]
pub struct ShellEventDetector {
    config: ShellEventConfig,
    compiled: Vec<(ShellOutputPattern, Regex)>,
    last_directory: Option<String>,
    last_branch: Option<String>,
    command_started_at: Option<f64>,
    emitted_tiers: Vec<u64>,
    last_pattern_match: HashMap<String, f64>,
}

impl ShellEventDetector {
    pub fn new(config: ShellEventConfig) -> Self {
        let mut detector = Self {
            config: ShellEventConfig::default(),
            compiled: Vec::new(),
            last_directory: None,
            last_branch: None,
            command_started_at: None,
            emitted_tiers: Vec::new(),
            last_pattern_match: HashMap::new(),
        };
        detector.set_config(config);
        detector
    }

    /// New settings; patterns are compiled again (`recompilePatterns`).
    pub fn set_config(&mut self, config: ShellEventConfig) {
        if config == self.config && !self.compiled.is_empty() {
            return;
        }
        self.compiled = config
            .output_patterns
            .iter()
            .filter(|p| p.is_enabled)
            .filter_map(|p| match Regex::new(&p.pattern) {
                Ok(re) => Some((p.clone(), re)),
                Err(err) => {
                    log::warn!("Invalid shell pattern '{}': {err}", p.name);
                    None
                }
            })
            .collect();
        self.config = config;
    }

    fn event(&self, event_type: &str, message: String) -> ShellEvent {
        ShellEvent {
            event_type: event_type.into(),
            message,
            directory: self.last_directory.clone(),
        }
    }

    /// A command started (`commandStarted`).
    pub fn command_started(
        &mut self,
        command: Option<&str>,
        directory: &str,
        now: f64,
    ) -> Vec<ShellEvent> {
        if self.last_directory.is_none() && !directory.trim().is_empty() {
            self.last_directory = Some(directory.to_string());
        }
        self.command_started_at = Some(now);
        self.emitted_tiers.clear();
        vec![self.event(
            "process_started",
            command.unwrap_or("Command started").to_string(),
        )]
    }

    /// Whether the long-running timer should run.
    pub fn is_timing(&self) -> bool {
        self.command_started_at.is_some() && self.emitted_tiers.len() < LONG_RUNNING_TIERS.len()
    }

    /// A command finished (`commandFinished`).
    pub fn command_finished(
        &mut self,
        exit_code: Option<i32>,
        command: Option<&str>,
    ) -> Vec<ShellEvent> {
        let mut events = Vec::new();
        let code = exit_code.unwrap_or(0);
        let description: String = command
            .map(|c| c.chars().take(100).collect())
            .unwrap_or_else(|| "Command".to_string());
        if let Some(code) = exit_code
            && self.config.watched_exit_codes.contains(&code)
        {
            events.push(self.event(
                "exit_code_match",
                format!("Exit code {code}: {description}"),
            ));
        }
        if code != 0 {
            events.push(self.event("command_failed", format!("Exit {code}: {description}")));
        } else if self.config.notify_on_all_command_completion {
            events.push(self.event("command_finished", description));
        }
        events.push(self.event("process_ended", format!("Exit {code}")));
        self.command_started_at = None;
        events
    }

    /// Output text: enabled patterns, rate limited (`processOutput`).
    pub fn process_output(&mut self, text: &str, now: f64) -> Vec<ShellEvent> {
        let mut events = Vec::new();
        let mut fired = Vec::new();
        for (pattern, regex) in &self.compiled {
            if !regex.is_match(text) {
                continue;
            }
            if self
                .last_pattern_match
                .get(&pattern.id)
                .is_some_and(|at| now - at < PATTERN_COOLDOWN)
            {
                continue;
            }
            fired.push(pattern.id.clone());
            events.push(self.event(
                &pattern.notification_type,
                format!("Pattern '{}' matched", pattern.name),
            ));
        }
        for id in fired {
            self.last_pattern_match.insert(id, now);
        }
        events
    }

    /// The directory changed (`directoryChanged`).
    pub fn directory_changed(&mut self, directory: &str) -> Vec<ShellEvent> {
        let normalized = standardize_path(directory);
        let old = self.last_directory.replace(normalized.clone());
        match old {
            Some(old) if old != normalized && self.config.notify_on_directory_change => {
                vec![self.event("directory_changed", format!("Changed to {normalized}"))]
            }
            _ => Vec::new(),
        }
    }

    /// The git branch changed (`gitBranchChanged`).
    pub fn git_branch_changed(&mut self, branch: Option<&str>) -> Vec<ShellEvent> {
        let old = std::mem::replace(&mut self.last_branch, branch.map(str::to_string));
        if !self.config.notify_on_git_branch_change || old.as_deref() == branch {
            return Vec::new();
        }
        let message = match (branch, old) {
            (Some(new), Some(old)) => format!("Switched from {old} to {new}"),
            (Some(new), None) => format!("Entered git repo on branch {new}"),
            (None, Some(_)) => "Left git repository".to_string(),
            (None, None) => return Vec::new(),
        };
        vec![self.event("git_branch_changed", message)]
    }

    /// Long-running tiers reached (`checkLongRunning`).
    pub fn check_long_running(&mut self, now: f64) -> Vec<ShellEvent> {
        let Some(started) = self.command_started_at else {
            return Vec::new();
        };
        let elapsed = (now - started).max(0.0) as u64;
        let mut events = Vec::new();
        for tier in LONG_RUNNING_TIERS {
            if elapsed >= tier && !self.emitted_tiers.contains(&tier) {
                self.emitted_tiers.push(tier);
                let (minutes, seconds) = (tier / 60, tier % 60);
                let time = if minutes > 0 {
                    format!("{minutes}m {seconds}s")
                } else {
                    format!("{seconds}s")
                };
                events.push(self.event("long_running", format!("Command running for {time}")));
            }
        }
        events
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn types(events: &[ShellEvent]) -> Vec<&str> {
        events.iter().map(|e| e.event_type.as_str()).collect()
    }

    #[test]
    fn command_lifecycle() {
        let mut d = ShellEventDetector::new(ShellEventConfig::default());
        let started = d.command_started(Some("make"), "/repo", 0.0);
        assert_eq!(types(&started), vec!["process_started"]);
        assert_eq!(started[0].directory.as_deref(), Some("/repo"));
        assert!(d.is_timing());
        let done = d.command_finished(Some(127), Some("make"));
        assert_eq!(
            types(&done),
            vec!["exit_code_match", "command_failed", "process_ended"]
        );
        assert_eq!(done[0].message, "Exit code 127: make");
        assert_eq!(done[1].message, "Exit 127: make");
        assert!(!d.is_timing());
        assert_eq!(
            types(&d.command_finished(Some(0), None)),
            vec!["process_ended"]
        );
        assert_eq!(
            types(&d.command_finished(Some(3), None)),
            vec!["command_failed", "process_ended"]
        );
    }

    #[test]
    fn all_completions() {
        let config = ShellEventConfig {
            notify_on_all_command_completion: true,
            ..Default::default()
        };
        let mut d = ShellEventDetector::new(config);
        assert_eq!(
            types(&d.command_finished(None, Some("ls"))),
            vec!["command_finished", "process_ended"]
        );
    }

    #[test]
    fn long_running_tiers() {
        let mut d = ShellEventDetector::new(ShellEventConfig::default());
        d.command_started(None, "", 100.0);
        assert!(d.check_long_running(120.0).is_empty());
        let e = d.check_long_running(131.0);
        assert_eq!(e[0].message, "Command running for 30s");
        assert!(d.check_long_running(135.0).is_empty());
        let e = d.check_long_running(500.0);
        assert_eq!(
            e.iter().map(|e| e.message.as_str()).collect::<Vec<_>>(),
            vec!["Command running for 1m 0s", "Command running for 5m 0s"]
        );
        assert!(!d.is_timing());
    }

    #[test]
    fn patterns_with_cooldown() {
        let mut patterns = ShellOutputPattern::defaults();
        patterns[0].is_enabled = true;
        patterns.push(ShellOutputPattern::new("Bad", "(", true));
        let mut d = ShellEventDetector::new(ShellEventConfig {
            output_patterns: patterns,
            ..Default::default()
        });
        let e = d.process_output("Build FAILED", 0.0);
        assert_eq!(types(&e), vec!["pattern_match"]);
        assert_eq!(e[0].message, "Pattern 'Error' matched");
        assert!(d.process_output("error", 4.0).is_empty());
        assert_eq!(d.process_output("error", 5.0).len(), 1);
        assert!(d.process_output("warning", 20.0).is_empty());
    }

    #[test]
    fn directory_and_branch() {
        let mut d = ShellEventDetector::new(ShellEventConfig::default());
        assert!(d.directory_changed("/a").is_empty());
        assert!(d.directory_changed("/b").is_empty());
        let mut d = ShellEventDetector::new(ShellEventConfig {
            notify_on_directory_change: true,
            notify_on_git_branch_change: true,
            ..Default::default()
        });
        assert!(d.directory_changed("/a").is_empty());
        assert!(d.directory_changed("/a/./").is_empty());
        assert_eq!(d.directory_changed("/b/../c")[0].message, "Changed to /c");
        assert_eq!(
            d.git_branch_changed(Some("main"))[0].message,
            "Entered git repo on branch main"
        );
        assert!(d.git_branch_changed(Some("main")).is_empty());
        assert_eq!(
            d.git_branch_changed(Some("dev"))[0].message,
            "Switched from main to dev"
        );
        assert_eq!(d.git_branch_changed(None)[0].message, "Left git repository");
        assert!(d.git_branch_changed(None).is_empty());
    }

    #[test]
    fn notification_settings_config_carries_over() {
        let mut notif = crate::notifications::settings::ShellEventConfig {
            long_running_threshold_seconds: 120,
            notify_on_git_branch_change: true,
            watched_exit_codes: vec![2, 3],
            ..Default::default()
        };
        notif
            .output_patterns
            .push(crate::notifications::settings::ShellOutputPattern {
                id: uuid::Uuid::new_v4(),
                name: "Panic".into(),
                pattern: "panicked at".into(),
                is_enabled: true,
                notification_type: "pattern_match".into(),
            });
        let config = ShellEventConfig::from_notification_settings(&notif);
        assert_eq!(config.long_running_threshold_seconds, 120);
        assert!(config.notify_on_git_branch_change);
        assert_eq!(config.watched_exit_codes, vec![2, 3]);
        assert_eq!(config.output_patterns.len(), 1);
        assert_eq!(config.output_patterns[0].pattern, "panicked at");
        assert!(config.output_patterns[0].is_enabled);
    }

    #[test]
    fn config_json_round_trip() {
        let config = ShellEventConfig::default();
        let json = serde_json::to_string(&config).unwrap();
        assert!(json.contains("watchedExitCodes"));
        let back: ShellEventConfig = serde_json::from_str(&json).unwrap();
        assert_eq!(back, config);
        let partial: ShellEventConfig =
            serde_json::from_str(r#"{"notifyOnDirectoryChange":true}"#).unwrap();
        assert!(partial.notify_on_directory_change);
        assert_eq!(partial.watched_exit_codes.len(), 9);
    }
}
