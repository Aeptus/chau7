//! Notifications (`NotificationsSettingsView.swift`): trigger rules, actions,
//! conditions, rate limiting (`FeatureSettings.notificationSettings`), shell
//! and app event thresholds (`shellEventConfig`, `appEventConfig`) and AI
//! event monitoring (`AppModel.isMonitoring`, `logPath`).
//!
//! Swift keeps these in UserDefaults. Chau7 Next writes each structured part
//! as one JSON value in `[next]`: `notification_rules`,
//! `notification_shell_events`, `notification_app_events`; plus
//! `ai_events_monitoring` and `ai_events_log_path`.

use chau7_next_core::config::RawValue;
use chau7_next_core::notifications::settings::{
    AppEventConfig, NotificationSettings, ShellEventConfig, from_config_json, to_config_json,
};

use super::{ConfigSink, ConfigSource, SettingsDomain};

/// Default AI event log (`AppModel.logPath`), with `~` for the home folder.
pub const DEFAULT_AI_EVENTS_LOG: &str = "~/.ai-events.log";

#[derive(Debug, Clone, PartialEq)]
pub struct NotificationsSettings {
    pub rules: NotificationSettings,
    pub shell_events: ShellEventConfig,
    pub app_events: AppEventConfig,
    /// "Monitor AI Events" (`isMonitoring`, default on). Read by the AI
    /// event log monitor.
    pub monitor_ai_events: bool,
    /// "Event Log Path" (`logPath`).
    pub ai_events_log_path: String,
}

impl Default for NotificationsSettings {
    fn default() -> Self {
        Self {
            rules: NotificationSettings::default(),
            shell_events: ShellEventConfig::default(),
            app_events: AppEventConfig::default(),
            monitor_ai_events: true,
            ai_events_log_path: DEFAULT_AI_EVENTS_LOG.into(),
        }
    }
}

impl NotificationsSettings {
    /// "Reset to defaults" of the trigger conditions (per-trigger and
    /// per-group conditions back to the default condition).
    pub fn reset_conditions(&mut self) {
        self.rules.trigger_conditions.clear();
        self.rules.group_conditions.clear();
    }
}

fn json_value<T: for<'de> serde::Deserialize<'de>>(src: &ConfigSource, key: &str) -> Option<T> {
    src.next(key)
        .and_then(RawValue::as_str)
        .and_then(from_config_json)
}

impl SettingsDomain for NotificationsSettings {
    fn load(&mut self, src: &ConfigSource) {
        if let Some(mut rules) = json_value::<NotificationSettings>(src, "notification_rules") {
            rules.trigger_state.normalize();
            self.rules = rules;
        }
        if let Some(v) = json_value(src, "notification_shell_events") {
            self.shell_events = v;
        }
        if let Some(v) = json_value(src, "notification_app_events") {
            self.app_events = v;
        }
        if let Some(v) = src.next("ai_events_monitoring").and_then(RawValue::as_bool) {
            self.monitor_ai_events = v;
        }
        if let Some(v) = src
            .next("ai_events_log_path")
            .and_then(RawValue::as_str)
            .filter(|v| !v.trim().is_empty())
        {
            self.ai_events_log_path = v.to_string();
        }
    }

    fn save(&self, out: &mut ConfigSink) {
        out.set_next("notification_rules", to_config_json(&self.rules));
        out.set_next(
            "notification_shell_events",
            to_config_json(&self.shell_events),
        );
        out.set_next("notification_app_events", to_config_json(&self.app_events));
        out.set_next("ai_events_monitoring", self.monitor_ai_events);
        out.set_next(
            "ai_events_log_path",
            format!("\"{}\"", self.ai_events_log_path.replace('"', "")),
        );
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use chau7_next_core::notifications::actions::{
        NotificationActionConfig, NotificationActionType,
    };
    use chau7_next_core::notifications::triggers::TriggerCondition;

    #[test]
    fn round_trip() {
        let mut s = NotificationsSettings::default();
        s.rules.trigger_action_bindings.insert(
            "shell.command_failed".into(),
            vec![
                NotificationActionConfig::new(NotificationActionType::RunScript)
                    .with_config([("script", "say 'done' && echo \"x = 1\"")]),
            ],
        );
        s.rules.trigger_conditions.insert(
            "codex.finished".into(),
            TriggerCondition {
                only_when_unfocused: true,
                only_when_tab_inactive: false,
                respect_dnd: false,
            },
        );
        s.rules.rate_limit_config.max_per_minute = 9;
        s.shell_events.long_running_threshold_seconds = 120;
        s.app_events.notify_on_tab_open = true;
        s.monitor_ai_events = false;
        s.ai_events_log_path = "/tmp/events.log".into();
        assert_eq!(crate::settings::round_trip(&s), s);
    }

    #[test]
    fn defaults_survive_and_reset() {
        let s = NotificationsSettings::default();
        assert_eq!(crate::settings::round_trip(&s), s);
        let mut s = s;
        s.rules
            .group_conditions
            .insert("ai_coding.finished".into(), TriggerCondition::default());
        s.reset_conditions();
        assert!(s.rules.group_conditions.is_empty());
        let loaded: NotificationsSettings =
            crate::settings::load_text("[next]\nnotification_rules = 'not json'\n");
        assert_eq!(loaded, NotificationsSettings::default());
    }
}
