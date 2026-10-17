//! Hover card (`HoverCardSettingsView.swift`): one toggle per card row and
//! for the footer (`hoverCard.*` in Swift, `[next] hover_card_show_*` here).

use chau7_next_core::config::RawValue;

use super::{ConfigSink, ConfigSource, SettingsDomain};

#[derive(Debug, Clone, PartialEq)]
pub struct HoverCardSettings {
    pub show_directory: bool,
    pub show_git_branch: bool,
    pub show_shell_integration: bool,
    pub show_dev_server: bool,
    pub show_last_command: bool,
    pub show_ai_session: bool,
    pub show_repo_stats: bool,
    pub show_processes: bool,
    pub show_token_optimization: bool,
    pub show_broadcast: bool,
    pub show_conflicts: bool,
    pub show_notification_state: bool,
    pub show_footer: bool,
}

/// Swift defaults: everything on except shell integration, token
/// optimization and broadcast.
impl Default for HoverCardSettings {
    fn default() -> Self {
        Self {
            show_directory: true,
            show_git_branch: true,
            show_shell_integration: false,
            show_dev_server: true,
            show_last_command: true,
            show_ai_session: true,
            show_repo_stats: true,
            show_processes: true,
            show_token_optimization: false,
            show_broadcast: false,
            show_conflicts: true,
            show_notification_state: true,
            show_footer: true,
        }
    }
}

type Field = (
    &'static str,
    &'static str,
    fn(&HoverCardSettings) -> bool,
    fn(&mut HoverCardSettings, bool),
);

impl HoverCardSettings {
    /// `[next]` key, settings window label, getter and setter, in the
    /// order of the Swift settings page.
    pub const FIELDS: [Field; 13] = [
        (
            "hover_card_show_directory",
            "Working Directory",
            |s| s.show_directory,
            |s, v| s.show_directory = v,
        ),
        (
            "hover_card_show_git_branch",
            "Git Branch",
            |s| s.show_git_branch,
            |s, v| s.show_git_branch = v,
        ),
        (
            "hover_card_show_last_command",
            "Last Command",
            |s| s.show_last_command,
            |s, v| s.show_last_command = v,
        ),
        (
            "hover_card_show_ai_session",
            "AI Session Summary",
            |s| s.show_ai_session,
            |s, v| s.show_ai_session = v,
        ),
        (
            "hover_card_show_repo_stats",
            "Repository Stats",
            |s| s.show_repo_stats,
            |s, v| s.show_repo_stats = v,
        ),
        (
            "hover_card_show_conflicts",
            "File Conflicts",
            |s| s.show_conflicts,
            |s, v| s.show_conflicts = v,
        ),
        (
            "hover_card_show_processes",
            "Process Info",
            |s| s.show_processes,
            |s, v| s.show_processes = v,
        ),
        (
            "hover_card_show_dev_server",
            "Dev Server",
            |s| s.show_dev_server,
            |s, v| s.show_dev_server = v,
        ),
        (
            "hover_card_show_notification_state",
            "Notification State",
            |s| s.show_notification_state,
            |s, v| s.show_notification_state = v,
        ),
        (
            "hover_card_show_token_optimization",
            "Token Optimization",
            |s| s.show_token_optimization,
            |s, v| s.show_token_optimization = v,
        ),
        (
            "hover_card_show_shell_integration",
            "Shell Integration",
            |s| s.show_shell_integration,
            |s, v| s.show_shell_integration = v,
        ),
        (
            "hover_card_show_broadcast",
            "Broadcast Status",
            |s| s.show_broadcast,
            |s, v| s.show_broadcast = v,
        ),
        (
            "hover_card_show_footer",
            "Footer",
            |s| s.show_footer,
            |s, v| s.show_footer = v,
        ),
    ];
}

impl SettingsDomain for HoverCardSettings {
    fn load(&mut self, src: &ConfigSource) {
        for (key, _, _, set) in Self::FIELDS {
            if let Some(v) = src.next(key).and_then(RawValue::as_bool) {
                set(self, v);
            }
        }
    }

    fn save(&self, out: &mut ConfigSink) {
        for (key, _, get, _) in Self::FIELDS {
            out.set_next(key, get(self));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::settings::round_trip;

    #[test]
    fn round_trips_every_field() {
        let mut settings = HoverCardSettings::default();
        for (_, _, get, set) in HoverCardSettings::FIELDS {
            let v = !get(&settings);
            set(&mut settings, v);
        }
        assert_ne!(settings, HoverCardSettings::default());
        assert_eq!(round_trip(&settings), settings);
    }
}
