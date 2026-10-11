//! Terminal (`ShellSettingsView.swift`, `ScrollbackPerfSettingsView.swift`,
//! `FontColorsSettingsView.swift` default zoom): shell, startup command, ls
//! colors, scrollback, bell, smart scroll, local echo, mouse reporting.

use chau7_next_core::config::RawValue;
use chau7_next_core::session_restore::{
    DEFAULT_RESTORED_SCROLLBACK_LINES, MAX_RESTORED_SCROLLBACK_LINES,
};

use chau7_next_core::shell_env::ShellType;

use super::{ConfigSink, ConfigSource, SettingsDomain};

/// Bell sound (`terminal.bellSound`, `[terminal] bell_sound`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum BellSound {
    /// The system alert sound.
    #[default]
    Default,
    /// The "Pop" system sound.
    Subtle,
    /// No sound: the terminal flashes.
    Visual,
}

impl BellSound {
    pub const ALL: [BellSound; 3] = [Self::Default, Self::Subtle, Self::Visual];

    /// Swift raw value.
    pub fn raw_value(self) -> &'static str {
        match self {
            Self::Default => "default",
            Self::Subtle => "subtle",
            Self::Visual => "none",
        }
    }

    pub fn from_raw(raw: &str) -> Self {
        match raw.trim() {
            "subtle" => Self::Subtle,
            "none" => Self::Visual,
            _ => Self::Default,
        }
    }

    pub fn label(self) -> &'static str {
        match self {
            Self::Default => "Default",
            Self::Subtle => "Subtle",
            Self::Visual => "Visual Only",
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct TerminalSettings {
    /// `[general] shell`: a shell path from the Swift config file; used when
    /// `shell_type` was never chosen in Chau7 Next.
    pub shell: Option<String>,
    /// `[next] shell_type` (Swift `terminal.shellType` raw values).
    pub shell_type: Option<ShellType>,
    /// `[next] custom_shell_path` (`terminal.customShellPath`).
    pub custom_shell_path: String,
    /// `[general] startup_command` (`terminal.startupCommand`).
    pub startup_command: String,
    /// `[next] ls_colors_enabled` (`terminal.lsColorsEnabled`).
    pub ls_colors: bool,
    pub scrollback_lines: usize,
    /// Closed-tab shell history budget, distinct from SQLite history records.
    pub shell_history_max_lines: usize,
    /// `[next] restored_scrollback_lines` (`terminal.restoredScrollbackLines`):
    /// lines of scrollback replayed when tabs are recovered, 0 disables.
    pub restored_scrollback_lines: usize,
    pub bell_enabled: bool,
    pub bell_sound: BellSound,
    /// `[next] smart_scroll_enabled` (`feature.smartScrollEnabled`).
    pub smart_scroll: bool,
    /// `[next] split_panes` (Swift `feature.splitPanes`): off blocks new
    /// terminal splits.
    pub split_panes_enabled: bool,
}

impl Default for TerminalSettings {
    fn default() -> Self {
        Self {
            shell: None,
            shell_type: None,
            custom_shell_path: String::new(),
            startup_command: String::new(),
            ls_colors: true,
            scrollback_lines: 10_000,
            shell_history_max_lines: chau7_next_core::shell_histories::DEFAULT_MAX_LINES,
            restored_scrollback_lines: DEFAULT_RESTORED_SCROLLBACK_LINES,
            bell_enabled: true,
            bell_sound: BellSound::Default,
            smart_scroll: true,
            split_panes_enabled: true,
        }
    }
}

impl TerminalSettings {
    /// The shell choice shown in the settings window: the chosen type, else
    /// the `[general] shell` path as a matching type or a custom path.
    pub fn effective_shell_type(&self) -> (ShellType, String) {
        if let Some(t) = self.shell_type {
            return (t, self.custom_shell_path.clone());
        }
        match self.shell.as_deref() {
            None => (ShellType::System, self.custom_shell_path.clone()),
            Some(path) => match ShellType::from_raw(path) {
                Some(t) => (t, self.custom_shell_path.clone()),
                None => (ShellType::Custom, path.to_string()),
            },
        }
    }

    /// The shell to start (`defaultShell()`).
    pub fn resolved_shell(&self) -> String {
        let (shell_type, custom) = self.effective_shell_type();
        chau7_next_core::shell_env::resolve_shell(
            shell_type,
            &custom,
            |p| std::path::Path::new(p).exists(),
            crate::terminal::session::system_login_shell,
        )
    }
}

fn quoted(value: &str) -> String {
    format!("\"{}\"", value.replace(['"', '\n', '\r'], ""))
}

impl SettingsDomain for TerminalSettings {
    fn load(&mut self, src: &ConfigSource) {
        if let Some(general) = &src.file.general {
            self.shell = general.shell.clone().filter(|s| !s.is_empty());
            if let Some(cmd) = &general.startup_command {
                self.startup_command = cmd.clone();
            }
        }
        if let Some(terminal) = &src.file.terminal {
            if let Some(lines) = terminal.scrollback_lines.filter(|l| *l > 0) {
                self.scrollback_lines = lines.clamp(100, 100_000) as usize;
            }
            if let Some(bell) = terminal.bell_enabled {
                self.bell_enabled = bell;
            }
            if let Some(sound) = &terminal.bell_sound {
                self.bell_sound = BellSound::from_raw(sound);
            }
        }
        if let Some(v) = src
            .next("shell_history_max_lines")
            .and_then(RawValue::as_int)
        {
            self.shell_history_max_lines =
                v.clamp(0, chau7_next_core::shell_histories::MAX_LINES as i64) as usize;
        }
        if let Some(v) = src.next("shell_type").and_then(RawValue::as_str) {
            self.shell_type = ShellType::from_raw(v);
        }
        if let Some(v) = src.next("custom_shell_path").and_then(RawValue::as_str) {
            self.custom_shell_path = v.to_string();
        }
        if let Some(v) = src.next("ls_colors_enabled").and_then(RawValue::as_bool) {
            self.ls_colors = v;
        }
        if let Some(v) = src.next("smart_scroll_enabled").and_then(RawValue::as_bool) {
            self.smart_scroll = v;
        }
        if let Some(v) = src.next("split_panes").and_then(RawValue::as_bool) {
            self.split_panes_enabled = v;
        }
        if let Some(v) = src
            .next("restored_scrollback_lines")
            .and_then(RawValue::as_int)
        {
            self.restored_scrollback_lines =
                v.clamp(0, MAX_RESTORED_SCROLLBACK_LINES as i64) as usize;
        }
    }

    /// `[general] shell` is not edited by the settings window: kept from the
    /// existing file (the window writes `[next] shell_type`).
    fn save(&self, out: &mut ConfigSink) {
        let general = out.file.general.get_or_insert_with(Default::default);
        general.startup_command = Some(self.startup_command.clone());
        let terminal = out.file.terminal.get_or_insert_with(Default::default);
        terminal.scrollback_lines = Some(self.scrollback_lines as i64);
        terminal.bell_enabled = Some(self.bell_enabled);
        terminal.bell_sound = Some(self.bell_sound.raw_value().to_string());
        if let Some(t) = self.shell_type {
            out.set_next("shell_type", quoted(t.raw_value()));
        }
        out.set_next("custom_shell_path", quoted(&self.custom_shell_path));
        out.set_next("ls_colors_enabled", self.ls_colors);
        out.set_next("restored_scrollback_lines", self.restored_scrollback_lines);
        out.set_next("smart_scroll_enabled", self.smart_scroll);
        out.set_next("split_panes", self.split_panes_enabled);
        out.set_next(
            "shell_history_max_lines",
            self.shell_history_max_lines
                .min(chau7_next_core::shell_histories::MAX_LINES),
        );
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::settings::{load_text, round_trip};

    #[test]
    fn round_trips() {
        let terminal = TerminalSettings {
            shell: None,
            shell_type: Some(ShellType::Custom),
            custom_shell_path: "/opt/nu".into(),
            startup_command: "echo hi".into(),
            ls_colors: false,
            scrollback_lines: 2_000,
            shell_history_max_lines: 17,
            restored_scrollback_lines: 0,
            bell_enabled: false,
            bell_sound: BellSound::Visual,
            smart_scroll: false,
            split_panes_enabled: false,
        };
        assert_eq!(round_trip(&terminal), terminal);
        assert_eq!(
            round_trip(&TerminalSettings::default()),
            TerminalSettings::default()
        );
    }

    #[test]
    fn shell_history_budget_defaults_bounds_and_owned_round_trip() {
        assert_eq!(TerminalSettings::default().shell_history_max_lines, 1000);
        for (raw, expected) in [(-1, 0), (0, 0), (2345, 2345), (2_000_000, 1_000_000)] {
            let t: TerminalSettings =
                load_text(&format!("[next]\nshell_history_max_lines = {raw}\n"));
            assert_eq!(t.shell_history_max_lines, expected);
            assert_eq!(round_trip(&t).shell_history_max_lines, expected);
        }
    }

    #[test]
    fn loads_shell_and_ignores_zero_scrollback() {
        let t: TerminalSettings =
            load_text("[general]\nshell = \"/bin/fish\"\n\n[terminal]\nscrollback_lines = 0\n");
        assert_eq!(t.shell.as_deref(), Some("/bin/fish"));
        assert_eq!(t.scrollback_lines, 10_000);
        assert_eq!(
            t.effective_shell_type(),
            (ShellType::Custom, "/bin/fish".to_string())
        );
        let t: TerminalSettings = load_text("[general]\nshell = \"/bin/bash\"\n");
        assert_eq!(t.effective_shell_type().0, ShellType::Bash);
        let t: TerminalSettings =
            load_text("[general]\nshell = \"/bin/bash\"\n\n[next]\nshell_type = \"/bin/zsh\"\n");
        assert_eq!(t.effective_shell_type().0, ShellType::Zsh);
        assert_eq!(t.resolved_shell(), "/bin/zsh");
    }

    #[test]
    fn clamps_and_swift_keys() {
        let t: TerminalSettings = load_text(
            "[general]\nstartup_command = \"ls\"\n\n[terminal]\nscrollback_lines = 50\nbell_sound = \"subtle\"\n\n[next]\nrestored_scrollback_lines = 99999\n",
        );
        assert_eq!(t.startup_command, "ls");
        assert_eq!(t.scrollback_lines, 100);
        assert_eq!(t.bell_sound, BellSound::Subtle);
        assert_eq!(t.restored_scrollback_lines, 10_000);
        assert_eq!(BellSound::from_raw("none"), BellSound::Visual);
    }

    #[test]
    fn pane_defaults_follow_swift() {
        let t = TerminalSettings::default();
        assert!(t.split_panes_enabled);
        assert_eq!(t.restored_scrollback_lines, 500);
    }

    #[test]
    fn restored_scrollback_is_clamped_to_0_through_10000() {
        let t: TerminalSettings = load_text("[next]\nrestored_scrollback_lines = 50000\n");
        assert_eq!(t.restored_scrollback_lines, 10_000);
        let t: TerminalSettings = load_text("[next]\nrestored_scrollback_lines = -4\n");
        assert_eq!(t.restored_scrollback_lines, 0);
        let t: TerminalSettings =
            load_text("[next]\nrestored_scrollback_lines = 0\nsplit_panes = false\n");
        assert_eq!(t.restored_scrollback_lines, 0);
        assert!(!t.split_panes_enabled);
    }
}
