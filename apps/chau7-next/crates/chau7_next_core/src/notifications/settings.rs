//! Notification settings (`NotificationSettings`, `ShellEventConfig`,
//! `AppEventConfig` and `ScheduledEvent` in Swift `FeatureSettings.swift`),
//! with the Swift defaults, including the default "All AI Sources" actions.
//!
//! Swift keeps these in UserDefaults; Chau7 Next stores each part as one
//! JSON value under `[next]` in `config.toml` (see the app's
//! `settings/notifications.rs`). The JSON keys follow the Swift `Codable`
//! names. The legacy `NotificationFilters` value is not kept: it only
//! mirrors the trigger state for older Swift versions.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};
use uuid::Uuid;

use super::actions::{NotificationActionConfig, NotificationActionType};
use super::pipeline::RateLimitConfig;
use super::triggers::{NotificationTriggerState, TriggerCondition};

/// Every notification rule (`NotificationSettings`).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct NotificationSettings {
    #[serde(rename = "triggerState")]
    pub trigger_state: NotificationTriggerState,
    #[serde(rename = "triggerActionBindings")]
    pub trigger_action_bindings: BTreeMap<String, Vec<NotificationActionConfig>>,
    #[serde(rename = "rateLimitConfig")]
    pub rate_limit_config: RateLimitConfig,
    #[serde(rename = "triggerConditions")]
    pub trigger_conditions: BTreeMap<String, TriggerCondition>,
    #[serde(rename = "groupActionBindings")]
    pub group_action_bindings: BTreeMap<String, Vec<NotificationActionConfig>>,
    #[serde(rename = "groupConditions")]
    pub group_conditions: BTreeMap<String, TriggerCondition>,
}

impl Default for NotificationSettings {
    fn default() -> Self {
        Self {
            trigger_state: NotificationTriggerState::default(),
            trigger_action_bindings: BTreeMap::new(),
            rate_limit_config: RateLimitConfig::default(),
            trigger_conditions: BTreeMap::new(),
            group_action_bindings: default_group_action_bindings(),
            group_conditions: BTreeMap::new(),
        }
    }
}

fn action(t: NotificationActionType, config: &[(&str, &str)]) -> NotificationActionConfig {
    NotificationActionConfig::new(t).with_config(config.iter().copied())
}

fn red_persistent_border() -> Vec<NotificationActionConfig> {
    vec![
        action(NotificationActionType::ShowNotification, &[]),
        action(
            NotificationActionType::StyleTab,
            &[
                ("style", "custom"),
                ("customColor", "red"),
                ("borderWidth", "2"),
                ("borderStyle", "solid"),
                ("persistent", "true"),
            ],
        ),
    ]
}

/// `NotificationSettings.defaultGroupActionBindings`. Action ids are stable
/// (derived from the group trigger id and position) so the defaults compare
/// equal from one launch to the next.
pub fn default_group_action_bindings() -> BTreeMap<String, Vec<NotificationActionConfig>> {
    let mut map = default_group_action_bindings_unstamped();
    for (trigger, actions) in map.iter_mut() {
        let hash = trigger.bytes().fold(0xcbf2_9ce4_8422_2325_u64, |h, b| {
            (h ^ b as u64).wrapping_mul(0x0000_0100_0000_01b3)
        });
        for (i, action) in actions.iter_mut().enumerate() {
            action.id = Uuid::from_u64_pair(hash, i as u64);
        }
    }
    map
}

fn default_group_action_bindings_unstamped() -> BTreeMap<String, Vec<NotificationActionConfig>> {
    use NotificationActionType as T;
    BTreeMap::from([
        (
            "ai_coding.finished".to_string(),
            vec![
                action(T::ShowNotification, &[]),
                action(
                    T::StyleTab,
                    &[
                        ("style", "custom"),
                        ("customColor", "green"),
                        ("borderWidth", "2"),
                        ("borderStyle", "solid"),
                    ],
                ),
            ],
        ),
        (
            "ai_coding.failed".to_string(),
            vec![
                action(T::ShowNotification, &[]),
                action(T::PlaySound, &[("sound", "Basso"), ("volume", "80")]),
                action(T::DockBounce, &[("critical", "false")]),
                action(
                    T::StyleTab,
                    &[("style", "error"), ("autoClearSeconds", "60")],
                ),
            ],
        ),
        ("ai_coding.permission".to_string(), red_persistent_border()),
        (
            "ai_coding.waiting_input".to_string(),
            red_persistent_border(),
        ),
        (
            "ai_coding.attention_required".to_string(),
            red_persistent_border(),
        ),
        (
            "ai_coding.idle".to_string(),
            vec![action(T::ShowNotification, &[])],
        ),
    ])
}

/// Same rules, ignoring the random action ids (to tell "still the
/// defaults" apart from edited rules).
pub fn same_actions(a: &[NotificationActionConfig], b: &[NotificationActionConfig]) -> bool {
    a.len() == b.len()
        && a.iter().zip(b).all(|(x, y)| {
            x.action_type == y.action_type && x.enabled == y.enabled && x.config == y.config
        })
}

/// A regex on command output (`ShellOutputPattern`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ShellOutputPattern {
    #[serde(with = "super::actions::uuid_upper")]
    pub id: Uuid,
    pub name: String,
    pub pattern: String,
    #[serde(rename = "isEnabled")]
    pub is_enabled: bool,
    #[serde(rename = "notificationType")]
    pub notification_type: String,
}

impl ShellOutputPattern {
    fn new(name: &str, pattern: &str) -> Self {
        Self {
            id: Uuid::new_v4(),
            name: name.into(),
            pattern: pattern.into(),
            is_enabled: false,
            notification_type: "pattern_match".into(),
        }
    }

    /// `ShellOutputPattern.defaults` (all off).
    pub fn defaults() -> Vec<Self> {
        vec![
            Self::new("Error", r"(?i)\b(error|failed|failure)\b"),
            Self::new("Warning", r"(?i)\bwarning\b"),
            Self::new(
                "Build Success",
                r"(?i)\b(build succeeded|compilation successful)\b",
            ),
            Self::new("Test Passed", r"(?i)\b(tests? passed|all tests pass)\b"),
            Self::new("Test Failed", r"(?i)\b(tests? failed|test failure)\b"),
        ]
    }
}

/// Shell event detection (`ShellEventConfig`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct ShellEventConfig {
    #[serde(rename = "outputPatterns")]
    pub output_patterns: Vec<ShellOutputPattern>,
    #[serde(rename = "watchedExitCodes")]
    pub watched_exit_codes: Vec<i32>,
    #[serde(rename = "longRunningThresholdSeconds")]
    pub long_running_threshold_seconds: i64,
    #[serde(rename = "notifyOnDirectoryChange")]
    pub notify_on_directory_change: bool,
    #[serde(rename = "notifyOnGitBranchChange")]
    pub notify_on_git_branch_change: bool,
    #[serde(rename = "notifyOnAllCommandCompletion")]
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

/// `ScheduledEvent.ScheduleType`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ScheduleType {
    #[default]
    Interval,
    Daily,
    Hourly,
}

/// A user-defined schedule (`ScheduledEvent`). `dailyTime` is the local
/// time of day as `HH:MM` (Swift stores a full `Date` and reads its hour
/// and minute).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct ScheduledEvent {
    #[serde(with = "super::actions::uuid_upper")]
    pub id: Uuid,
    pub name: String,
    #[serde(rename = "scheduleType")]
    pub schedule_type: ScheduleType,
    #[serde(rename = "intervalMinutes")]
    pub interval_minutes: i64,
    #[serde(rename = "dailyTime")]
    pub daily_time: String,
    #[serde(rename = "hourlyMinute")]
    pub hourly_minute: i64,
    #[serde(rename = "isEnabled")]
    pub is_enabled: bool,
}

impl Default for ScheduledEvent {
    fn default() -> Self {
        Self {
            id: Uuid::new_v4(),
            name: String::new(),
            schedule_type: ScheduleType::Interval,
            interval_minutes: 60,
            daily_time: "09:00".into(),
            hourly_minute: 0,
            is_enabled: true,
        }
    }
}

impl ScheduledEvent {
    /// Hour and minute of `daily_time` (`09:00` when unreadable).
    pub fn daily_hour_minute(&self) -> (u32, u32) {
        let mut parts = self.daily_time.trim().split(':');
        let h = parts.next().and_then(|h| h.trim().parse::<u32>().ok());
        let m = parts.next().and_then(|m| m.trim().parse::<u32>().ok());
        match (h, m) {
            (Some(h), Some(m)) if h < 24 && m < 60 => (h, m),
            _ => (9, 0),
        }
    }
}

/// App event detection (`AppEventConfig`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct AppEventConfig {
    #[serde(rename = "scheduledEvents")]
    pub scheduled_events: Vec<ScheduledEvent>,
    /// 0 turns it off.
    #[serde(rename = "inactivityThresholdMinutes")]
    pub inactivity_threshold_minutes: i64,
    /// 0 turns it off.
    #[serde(rename = "memoryThresholdMB")]
    pub memory_threshold_mb: i64,
    #[serde(rename = "memoryHysteresisMB")]
    pub memory_hysteresis_mb: i64,
    #[serde(rename = "notifyOnTabOpen")]
    pub notify_on_tab_open: bool,
    #[serde(rename = "notifyOnTabClose")]
    pub notify_on_tab_close: bool,
}

impl Default for AppEventConfig {
    fn default() -> Self {
        Self {
            scheduled_events: Vec::new(),
            inactivity_threshold_minutes: 0,
            memory_threshold_mb: 0,
            memory_hysteresis_mb: 50,
            notify_on_tab_open: false,
            notify_on_tab_close: false,
        }
    }
}

/// Encode a value for a single-quoted `config.toml` string: compact JSON
/// with `'` escaped (the config parser does not unescape).
pub fn to_config_json<T: Serialize>(value: &T) -> String {
    let json = serde_json::to_string(value).unwrap_or_else(|_| "null".into());
    format!("'{}'", json.replace('\'', "\\u0027"))
}

/// Decode a value written by [`to_config_json`].
pub fn from_config_json<T: for<'de> Deserialize<'de>>(raw: &str) -> Option<T> {
    serde_json::from_str(raw).ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn defaults_match_swift() {
        let s = NotificationSettings::default();
        assert_eq!(s.group_action_bindings.len(), 6);
        let failed = &s.group_action_bindings["ai_coding.failed"];
        assert_eq!(failed.len(), 4);
        assert_eq!(failed[1].config_value("sound"), Some("Basso"));
        assert_eq!(failed[3].config_value("autoClearSeconds"), Some("60"));
        assert!(s.trigger_action_bindings.is_empty());
        assert_eq!(s.rate_limit_config, RateLimitConfig::default());
        let shell = ShellEventConfig::default();
        assert_eq!(shell.long_running_threshold_seconds, 60);
        assert_eq!(shell.watched_exit_codes.len(), 9);
        let app = AppEventConfig::default();
        assert_eq!(app.memory_hysteresis_mb, 50);
        assert_eq!(ShellOutputPattern::defaults().len(), 5);
        assert!(ShellOutputPattern::defaults().iter().all(|p| !p.is_enabled));
    }

    #[test]
    fn config_json_round_trips_with_quotes() {
        let mut s = NotificationSettings::default();
        s.trigger_action_bindings.insert(
            "shell.command_failed".into(),
            vec![action(
                NotificationActionType::RunScript,
                &[("script", "echo 'it''s' \"x\"\nnext")],
            )],
        );
        let text = to_config_json(&s);
        assert!(text.starts_with('\'') && text.ends_with('\''));
        assert!(!text[1..text.len() - 1].contains('\''));
        assert!(!text.contains('\n'));
        let back: NotificationSettings = from_config_json(&text[1..text.len() - 1]).unwrap();
        assert_eq!(back, s);
        let partial: AppEventConfig = from_config_json(r#"{"notifyOnTabOpen":true}"#).unwrap();
        assert!(partial.notify_on_tab_open);
        assert_eq!(partial.memory_hysteresis_mb, 50);
    }

    #[test]
    fn defaults_are_stable() {
        assert_eq!(
            NotificationSettings::default(),
            NotificationSettings::default()
        );
        let a = &default_group_action_bindings()["ai_coding.failed"];
        assert_ne!(a[0].id, a[1].id);
    }

    #[test]
    fn daily_time_parsing() {
        let mut e = ScheduledEvent::default();
        assert_eq!(e.daily_hour_minute(), (9, 0));
        e.daily_time = "17:45".into();
        assert_eq!(e.daily_hour_minute(), (17, 45));
        e.daily_time = "99:99".into();
        assert_eq!(e.daily_hour_minute(), (9, 0));
    }

    #[test]
    fn same_actions_ignores_ids() {
        assert!(same_actions(
            &default_group_action_bindings()["ai_coding.finished"],
            &default_group_action_bindings()["ai_coding.finished"]
        ));
        assert!(!same_actions(
            &default_group_action_bindings()["ai_coding.finished"],
            &default_group_action_bindings()["ai_coding.idle"]
        ));
    }
}
