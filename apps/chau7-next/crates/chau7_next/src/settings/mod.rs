//! App settings, read from `~/.chau7-next/config.toml` (same format as the
//! Swift app's `~/.chau7/config.toml`, parsed by `chau7_next_core::config`).
//!
//! Defaults follow `FeatureSettings.swift` in the Swift app: SF Mono 11 pt,
//! "Default" color scheme, new tabs at the end, idle tabs after 10 minutes.
//!
//! One file per domain, named after the Swift settings sections
//! (`Settings/Views/*SettingsView.swift`). Each domain owns its fields, their
//! defaults, and its part of load and save. Adding a setting touches only
//! its domain file (plus its row in `settings_window/`).

mod ai;
mod appearance;
mod cloud_freshness;
pub mod config_files;
pub mod dangerous_commands;
mod editor;
pub mod export;
mod general;
mod history;
mod hover_card;
mod input;
pub(crate) mod installation;
pub mod mcp;
mod minimal_mode;
pub mod notifications;
mod productivity;
mod proxy;
mod remote;
pub mod sync;
mod tabs;
mod terminal;
pub mod token_optimization;

use std::fmt::Display;

use chau7_next_core::config::{self, Chau7ConfigFile, RawConfig, RawValue};
use chau7_next_core::data_root::DataRoot;
use chau7_next_core::settings_search::SettingsSection;
use gpui::{App, Global};

pub use ai::{AiSettings, CustomAiRule};
pub use appearance::{
    ActivePollingRateCap, AppTheme, AppearanceSettings, CursorShape, fallback_fonts,
};
#[allow(unused_imports)]
pub use dangerous_commands::{DangerousCommandSettings, HighlightScope};
pub use editor::EditorSettings;
pub use general::{AppLanguage, GeneralSettings};
pub use history::HistorySettings;
pub use hover_card::HoverCardSettings;
pub use input::InputSettings;
pub use mcp::McpSettings;
pub use minimal_mode::MinimalModeSettings;
pub use notifications::NotificationsSettings;
#[allow(unused_imports)]
pub use productivity::{ProductivitySettings, SnippetInsertMode, UrlHandler};
pub use proxy::ProxySettings;
pub use remote::RemoteSettings;
pub use tabs::{LastTabClose, RepoGroupingMode, TabsSettings};
pub use terminal::{BellSound, TerminalSettings};
pub use token_optimization::TokenOptimizationSettings;

#[derive(Debug, Clone, Default, PartialEq)]
pub struct Settings {
    /// Installation-local factory policy, never exported into another profile.
    installation_retention_default: i64,
    pub general: GeneralSettings,
    pub appearance: AppearanceSettings,
    pub terminal: TerminalSettings,
    pub tabs: TabsSettings,
    pub hover_card: HoverCardSettings,
    pub minimal_mode: MinimalModeSettings,
    pub input: InputSettings,
    pub productivity: ProductivitySettings,
    pub dangerous_commands: DangerousCommandSettings,
    pub notifications: NotificationsSettings,
    pub ai: AiSettings,
    pub history: HistorySettings,
    pub mcp: McpSettings,
    pub remote: RemoteSettings,
    pub editor: EditorSettings,
    pub proxy: ProxySettings,
    pub cto: TokenOptimizationSettings,
}

impl Global for Settings {}

/// A settings domain: one group of fields with its own load and save.
pub trait SettingsDomain {
    /// Apply the values present in the config file; missing keys keep the current value.
    fn load(&mut self, src: &ConfigSource);
    /// Write the values the settings window edits.
    fn save(&self, out: &mut ConfigSink);
}

/// The parsed config file, as each domain reads it.
pub struct ConfigSource<'a> {
    /// Sections shared with the Swift app (`[general]`, `[appearance]`, ...).
    pub file: &'a Chau7ConfigFile,
    /// Every section, untyped (`[next]` holds keys only Chau7 Next reads).
    pub raw: &'a RawConfig,
}

impl ConfigSource<'_> {
    /// A key of the `[next]` section. The Swift parser ignores unknown sections.
    pub fn next(&self, key: &str) -> Option<&RawValue> {
        self.raw.get("next")?.get(key)
    }
}

/// The config file being written.
pub struct ConfigSink<'a> {
    /// Sections shared with the Swift app; values not set here are kept.
    pub file: &'a mut Chau7ConfigFile,
    next: Vec<(std::borrow::Cow<'static, str>, String)>,
}

impl ConfigSink<'_> {
    /// Set a `[next]` key. Strings must be passed already quoted.
    pub fn set_next(&mut self, key: &'static str, value: impl Display) {
        self.next
            .push((std::borrow::Cow::Borrowed(key), value.to_string()));
    }

    /// Set a `[next]` key built at run time (numbered lists).
    pub fn set_next_owned(&mut self, key: String, value: impl Display) {
        self.next
            .push((std::borrow::Cow::Owned(key), value.to_string()));
    }
}

impl Settings {
    fn domains_mut(&mut self) -> [&mut dyn SettingsDomain; 17] {
        [
            &mut self.general,
            &mut self.appearance,
            &mut self.terminal,
            &mut self.tabs,
            &mut self.hover_card,
            &mut self.minimal_mode,
            &mut self.input,
            &mut self.productivity,
            &mut self.dangerous_commands,
            &mut self.notifications,
            &mut self.ai,
            &mut self.history,
            &mut self.mcp,
            &mut self.remote,
            &mut self.editor,
            &mut self.proxy,
            &mut self.cto,
        ]
    }

    fn domains(&self) -> [&dyn SettingsDomain; 17] {
        [
            &self.general,
            &self.appearance,
            &self.terminal,
            &self.tabs,
            &self.hover_card,
            &self.minimal_mode,
            &self.input,
            &self.productivity,
            &self.dangerous_commands,
            &self.notifications,
            &self.ai,
            &self.history,
            &self.mcp,
            &self.remote,
            &self.editor,
            &self.proxy,
            &self.cto,
        ]
    }

    /// Load from the Chau7 Next config file. Missing or partial files keep defaults.
    pub fn load(root: &DataRoot) -> Self {
        let fallback = installation::retention_default(root);
        match std::fs::read_to_string(root.config_file()) {
            Ok(text) => {
                let mut settings = Self::from_text(&text);
                if !config::is_valid_config(&text) {
                    settings.general.telemetry_retention_days = 0;
                    return settings;
                }
                settings.installation_retention_default = fallback;
                let raw = config::parse_raw(&text);
                if !raw
                    .get("next")
                    .is_some_and(|keys| keys.contains_key("telemetry_retention_days"))
                {
                    settings.general.telemetry_retention_days = if raw
                        .values()
                        .any(|keys| keys.contains_key("telemetry_retention_days"))
                    {
                        0
                    } else {
                        fallback
                    };
                }
                settings
            }
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                let mut settings = Settings {
                    installation_retention_default: fallback,
                    ..Settings::default()
                };
                settings.general.telemetry_retention_days = fallback;
                settings
            }
            Err(_) => Settings::default(),
        }
    }

    fn from_text(text: &str) -> Self {
        let mut settings = Settings::default();
        let file = config::parse(text);
        let raw = config::parse_raw(text);
        let src = ConfigSource {
            file: &file,
            raw: &raw,
        };
        for domain in settings.domains_mut() {
            domain.load(&src);
        }
        settings
    }

    /// Write these settings to the Chau7 Next config file. Values the
    /// settings window does not edit (shell, profiles, keybindings, ...) are
    /// kept from the existing file.
    pub fn save(&self, root: &DataRoot) -> std::io::Result<()> {
        let existing = std::fs::read_to_string(root.config_file()).unwrap_or_default();
        let text = self.to_text(&existing);
        root.ensure_dirs()?;
        std::fs::write(root.config_file(), text)
    }

    fn to_text(&self, existing: &str) -> String {
        let mut file = config::parse(existing);
        let mut sink = ConfigSink {
            file: &mut file,
            next: Vec::new(),
        };
        for domain in self.domains() {
            domain.save(&mut sink);
        }
        let next = std::mem::take(&mut sink.next);
        let mut text = config::serialize(&file);
        text.push_str("\n[next]\n");
        for (key, value) in next {
            text.push_str(&format!("{key} = {value}\n"));
        }
        text
    }

    /// The settings as config text, for saving into a settings profile.
    pub fn to_profile_text(&self) -> String {
        self.to_text("")
    }

    /// Settings from profile text; keys missing from it keep their defaults.
    pub fn from_profile_text(text: &str) -> Self {
        Self::from_text(text)
    }

    /// Imported partial profiles retain the current local retention choice;
    /// explicit zero/custom values win. Factory resets use this installation's
    /// durable policy, which is intentionally absent from portable text.
    pub(crate) fn from_profile_text_local(text: &str, current: &Self) -> Self {
        let mut settings = Self::from_text(text);
        settings.installation_retention_default = current.installation_retention_default;
        if !config::is_valid_config(text) {
            settings.general.telemetry_retention_days = 0;
        } else {
            let raw = config::parse_raw(text);
            if !raw
                .get("next")
                .is_some_and(|keys| keys.contains_key("telemetry_retention_days"))
            {
                settings.general.telemetry_retention_days = if raw
                    .values()
                    .any(|keys| keys.contains_key("telemetry_retention_days"))
                {
                    0
                } else {
                    current.general.telemetry_retention_days
                };
            }
        }
        settings
    }

    pub fn get(cx: &App) -> &Settings {
        cx.global::<Settings>()
    }

    /// Put the settings of one window section back to their defaults
    /// (`resetToDefaults` of each Swift settings view). Sections whose
    /// settings live in other modules are left alone. Current appearance
    /// pages reset their own values without resetting unrelated domains.
    pub fn reset_section(&mut self, section: SettingsSection) {
        use SettingsSection as S;
        match section {
            S::General => {
                // The shared terminal reset owns the startup directory.
                let directory = self.general.default_directory.take();
                let contact = self.general.remembered_bug_report_fields();
                self.general = GeneralSettings::default();
                self.general.telemetry_retention_days = self.installation_retention_default;
                self.general.default_directory = directory;
                self.general.restore_bug_report_fields(contact);
            }
            S::Windows => {
                self.appearance.app_theme = AppTheme::System;
                self.appearance.menu_bar_only = false;
                self.appearance.window_floating = false;
                self.appearance.opacity = 1.0;
                self.appearance.window_blur_enabled = true;
                self.tabs.always_show_toolbar_in_fullscreen = false;
                self.terminal.split_panes_enabled = true;
            }
            S::FontColors => {
                let defaults = AppearanceSettings::default();
                self.appearance.font_family = defaults.font_family;
                self.appearance.font_weight = defaults.font_weight;
                self.appearance.font_size = defaults.font_size;
                self.appearance.custom_font_family = defaults.custom_font_family;
                self.appearance.default_zoom_percent = defaults.default_zoom_percent;
                self.appearance.color_scheme = defaults.color_scheme;
                self.appearance.custom_color_scheme = defaults.custom_color_scheme;
                self.appearance.ligatures = false;
            }
            S::Display => self.appearance.display = appearance::DisplayOptions::default(),
            S::Tabs => self.tabs = TabsSettings::default(),
            S::Shell | S::ScrollbackPerf => {
                // Both current Swift pages call resetTerminalToDefaults.
                // Split panes belongs to Windows; smart scroll and rendering
                // selection/suspension are outside TerminalBehaviorStore.
                let splits = self.terminal.split_panes_enabled;
                let smart_scroll = self.terminal.smart_scroll;
                self.terminal = TerminalSettings::default();
                self.terminal.split_panes_enabled = splits;
                self.terminal.smart_scroll = smart_scroll;
                let appearance = AppearanceSettings::default();
                self.appearance.cursor_shape = appearance.cursor_shape;
                self.appearance.cursor_blink = appearance.cursor_blink;
                self.appearance.cursor_blink_rate = appearance.cursor_blink_rate;
                self.appearance.cursor_color = appearance.cursor_color;
                self.appearance.rendering.active_polling_rate_cap =
                    appearance.rendering.active_polling_rate_cap;
                self.appearance.rendering.inactive_view_max_fps =
                    appearance.rendering.inactive_view_max_fps;
                let general = GeneralSettings::default();
                self.general.default_directory = general.default_directory;
                self.general.usage_monitoring = general.usage_monitoring;
                self.general.claude_quota_capture = general.claude_quota_capture;
                self.general.usage_quota_warnings = general.usage_quota_warnings;
                self.general.regional_number_format = general.regional_number_format;
                let guard_enabled = self.dangerous_commands.guard_enabled;
                self.dangerous_commands = DangerousCommandSettings::default();
                self.dangerous_commands.guard_enabled = guard_enabled;
            }
            S::DangerousCommands => {
                self.reset_section(S::Shell);
                self.dangerous_commands.guard_enabled = true;
            }
            S::KeyboardMouse => {
                self.input = InputSettings::default();
                let defaults = ProductivitySettings::default();
                self.productivity.cmd_click_paths = defaults.cmd_click_paths;
                self.productivity.cmd_click_internal_editor = defaults.cmd_click_internal_editor;
                self.productivity.default_editor = defaults.default_editor;
                self.productivity.url_handler = defaults.url_handler;
            }
            S::SnippetsTools => {
                // Link preferences belong to Input in current Swift.
                let previous = self.productivity.clone();
                self.productivity = ProductivitySettings::default();
                self.productivity.cmd_click_paths = previous.cmd_click_paths;
                self.productivity.cmd_click_internal_editor = previous.cmd_click_internal_editor;
                self.productivity.default_editor = previous.default_editor;
                self.productivity.url_handler = previous.url_handler;
                self.general.allow_protected_folder_access = false;
            }
            // Swift resets the trigger conditions (`ConditionRow` reset).
            S::Notifications => self.notifications.reset_conditions(),
            S::Editor => self.editor = EditorSettings::default(),
            _ => {}
        }
    }

    /// Whether [`Settings::reset_section`] resets something for `section`
    /// (the window shows a reset button for those; Sync & Backup has Reset All).
    pub fn can_reset_section(section: SettingsSection) -> bool {
        use SettingsSection as S;
        matches!(
            section,
            S::Windows
                | S::FontColors
                | S::Display
                | S::Tabs
                | S::Shell
                | S::ScrollbackPerf
                | S::DangerousCommands
                | S::KeyboardMouse
                | S::SnippetsTools
                | S::Notifications
        )
    }

    /// Every setting back to its default ("Reset All Settings").
    pub fn reset_all(&mut self) {
        let contact = self.general.remembered_bug_report_fields();
        let policy = self.installation_retention_default;
        *self = Settings {
            installation_retention_default: policy,
            ..Settings::default()
        };
        self.general.telemetry_retention_days = policy;
        self.general.restore_bug_report_fields(contact);
    }
}

/// Save one domain into an empty file and load it back (domain tests).
#[cfg(test)]
pub(crate) fn round_trip<D: SettingsDomain + Default>(domain: &D) -> D {
    let mut file = Chau7ConfigFile::default();
    let mut sink = ConfigSink {
        file: &mut file,
        next: Vec::new(),
    };
    domain.save(&mut sink);
    let mut text = config::serialize(sink.file);
    text.push_str("\n[next]\n");
    for (key, value) in &sink.next {
        text.push_str(&format!("{key} = {value}\n"));
    }
    load_text(&text)
}

/// Load one domain from config text, starting from its defaults (domain tests).
#[cfg(test)]
pub(crate) fn load_text<D: SettingsDomain + Default>(text: &str) -> D {
    let parsed = config::parse(text);
    let raw = config::parse_raw(text);
    let mut loaded = D::default();
    loaded.load(&ConfigSource {
        file: &parsed,
        raw: &raw,
    });
    loaded
}

#[cfg(test)]
mod tests {
    use super::*;
    use chau7_next_core::color_schemes::ColorScheme;
    use chau7_next_core::tabs_state::NewTabPosition;

    /// Each domain owns its `[next]` keys: a key written by two domains
    /// would make the file invalid TOML (and one domain's value would win).
    #[test]
    fn next_keys_are_written_once() {
        let settings = Settings::default();
        let mut file = config::parse("");
        let mut sink = ConfigSink {
            file: &mut file,
            next: Vec::new(),
        };
        for domain in settings.domains() {
            domain.save(&mut sink);
        }
        let mut seen = std::collections::HashSet::new();
        for (key, _) in &sink.next {
            assert!(seen.insert(key.clone()), "[next] {key} is written twice");
        }
    }

    #[test]
    fn save_then_load_round_trips() {
        let home = std::env::temp_dir().join(format!("chau7-next-settings-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&home);
        let root = DataRoot::with_home(home.clone(), true);
        root.ensure_dirs().unwrap();
        // Existing values the window does not edit must survive.
        std::fs::write(
            root.config_file(),
            "[general]\nshell = \"/bin/zsh\"\n\n[keybindings]\ncmd+b = \"toggleBroadcast\"\n",
        )
        .unwrap();
        let mut settings = Settings::default();
        settings.appearance.font_family = "Menlo".into();
        settings.appearance.font_size = 14.0;
        settings.appearance.color_scheme = ColorScheme::named("Nord");
        settings.appearance.cursor_shape = CursorShape::Bar;
        settings.appearance.padding = 8.0;
        settings.input.copy_on_select = false;
        // Key bindings are edited by the Keyboard Shortcuts window, so they
        // are written from memory like any other edited value.
        settings.input.keybindings = vec![("cmd+b".into(), "toggleBroadcast".into())];
        settings.tabs.new_tab_position = NewTabPosition::AfterCurrent;
        settings.save(&root).unwrap();

        let loaded = Settings::load(&root);
        assert_eq!(loaded.appearance.font_family, "Menlo");
        assert_eq!(loaded.appearance.font_size, 14.0);
        assert_eq!(loaded.appearance.color_scheme.name, "Nord");
        assert_eq!(loaded.appearance.cursor_shape, CursorShape::Bar);
        assert!(!loaded.input.copy_on_select);
        assert_eq!(loaded.tabs.new_tab_position, NewTabPosition::AfterCurrent);
        assert_eq!(loaded.appearance.padding, 8.0);
        assert_eq!(loaded.terminal.shell.as_deref(), Some("/bin/zsh"));
        assert_eq!(
            loaded.input.keybindings,
            vec![("cmd+b".to_string(), "toggleBroadcast".to_string())]
        );
        let _ = std::fs::remove_dir_all(&home);
    }

    #[test]
    fn missing_file_gives_defaults() {
        assert_eq!(Settings::from_text(""), Settings::default());
    }

    #[test]
    fn defaults_survive_a_save() {
        let text = Settings::default().to_text("");
        assert_eq!(Settings::from_text(&text), Settings::default());
    }
    #[test]
    fn shell_and_performance_reset_the_current_shared_terminal_domain() {
        for section in [SettingsSection::Shell, SettingsSection::ScrollbackPerf] {
            let mut s = Settings::default();
            s.terminal.scrollback_lines = 333;
            s.terminal.startup_command = "echo custom".into();
            s.terminal.split_panes_enabled = false;
            s.terminal.smart_scroll = false;
            s.appearance.font_size = 25.;
            s.appearance.menu_bar_only = true;
            s.appearance.cursor_shape = CursorShape::Bar;
            s.appearance.cursor_blink = false;
            s.appearance.cursor_color = "#abcdef".into();
            s.appearance.rendering.gpu_renderer = false;
            s.appearance.rendering.suspend_background = true;
            s.appearance.rendering.active_polling_rate_cap = appearance::ActivePollingRateCap::Hz30;
            s.appearance.rendering.inactive_view_max_fps = 10;
            s.general.default_directory = Some("/custom".into());
            s.general.usage_monitoring = true;
            s.general.claude_quota_capture = true;
            s.general.usage_quota_warnings = true;
            s.general.launch_at_login = true;
            s.dangerous_commands.guard_enabled = false;
            s.dangerous_commands.patterns.clear();
            s.reset_section(section);
            let defaults = Settings::default();
            assert_eq!(
                s.terminal.scrollback_lines,
                defaults.terminal.scrollback_lines
            );
            assert!(s.terminal.startup_command.is_empty());
            assert_eq!(s.appearance.cursor_shape, defaults.appearance.cursor_shape);
            assert_eq!(s.appearance.cursor_blink, defaults.appearance.cursor_blink);
            assert_eq!(s.appearance.cursor_color, defaults.appearance.cursor_color);
            assert_eq!(
                s.appearance.rendering.active_polling_rate_cap,
                defaults.appearance.rendering.active_polling_rate_cap
            );
            assert_eq!(s.appearance.rendering.inactive_view_max_fps, 42);
            assert_eq!(s.general.default_directory, None);
            assert_eq!(
                s.general.usage_monitoring,
                defaults.general.usage_monitoring
            );
            assert_eq!(
                s.general.claude_quota_capture,
                defaults.general.claude_quota_capture
            );
            assert_eq!(
                s.general.usage_quota_warnings,
                defaults.general.usage_quota_warnings
            );
            assert_eq!(
                s.dangerous_commands.patterns,
                defaults.dangerous_commands.patterns
            );
            assert!(!s.terminal.split_panes_enabled);
            assert!(!s.terminal.smart_scroll);
            assert!(!s.appearance.rendering.gpu_renderer);
            assert!(s.appearance.rendering.suspend_background);
            assert_eq!(s.appearance.font_size, 25.);
            assert!(s.appearance.menu_bar_only);
            assert!(s.general.launch_at_login);
            assert!(!s.dangerous_commands.guard_enabled);
        }
    }

    #[test]
    fn current_appearance_pages_reset_only_their_own_values() {
        assert!(Settings::can_reset_section(SettingsSection::Windows));
        let mut settings = Settings::default();
        settings.appearance.font_size = 22.;
        settings.appearance.menu_bar_only = true;
        settings.appearance.window_blur_enabled = false;
        settings.appearance.window_floating = true;
        settings.appearance.opacity = 0.65;
        settings.appearance.rendering.gpu_renderer = false;
        settings.appearance.display.syntax_highlight = false;
        settings.reset_section(SettingsSection::FontColors);
        assert_eq!(
            settings.appearance.font_size,
            Settings::default().appearance.font_size
        );
        assert!(settings.appearance.menu_bar_only);
        assert!(!settings.appearance.window_blur_enabled);
        assert!(!settings.appearance.rendering.gpu_renderer);
        assert!(!settings.appearance.display.syntax_highlight);
        settings.reset_section(SettingsSection::Display);
        assert!(settings.appearance.display.syntax_highlight);
        assert!(settings.appearance.menu_bar_only);
        assert!(settings.appearance.window_floating);
        settings.appearance.font_size = 19.;
        settings.tabs.always_show_toolbar_in_fullscreen = true;
        settings.terminal.split_panes_enabled = false;
        settings.reset_section(SettingsSection::Windows);
        assert!(!settings.appearance.menu_bar_only);
        assert!(settings.appearance.window_blur_enabled);
        assert!(!settings.appearance.window_floating);
        assert_eq!(settings.appearance.opacity, 1.);
        assert_eq!(settings.appearance.font_size, 19.);
        assert!(!settings.appearance.rendering.gpu_renderer);
        assert!(!settings.tabs.always_show_toolbar_in_fullscreen);
        assert!(settings.terminal.split_panes_enabled);
    }
    #[test]
    fn input_and_productivity_resets_follow_current_domain_ownership() {
        let mut settings = Settings::default();
        settings.productivity.cmd_click_paths = false;
        settings.productivity.cmd_click_internal_editor = false;
        settings.productivity.default_editor = "code --wait".into();
        settings.productivity.url_handler = productivity::UrlHandler::Firefox;
        settings.productivity.clipboard_history_max = 73;
        settings.general.allow_protected_folder_access = true;
        settings.input.copy_on_select = false;
        settings.reset_section(SettingsSection::KeyboardMouse);
        let defaults = Settings::default();
        assert_eq!(settings.input, defaults.input);
        assert_eq!(
            settings.productivity.cmd_click_paths,
            defaults.productivity.cmd_click_paths
        );
        assert_eq!(
            settings.productivity.cmd_click_internal_editor,
            defaults.productivity.cmd_click_internal_editor
        );
        assert_eq!(
            settings.productivity.default_editor,
            defaults.productivity.default_editor
        );
        assert_eq!(
            settings.productivity.url_handler,
            defaults.productivity.url_handler
        );
        assert_eq!(settings.productivity.clipboard_history_max, 73);
        assert!(settings.general.allow_protected_folder_access);
        settings.productivity.cmd_click_paths = false;
        settings.productivity.default_editor = "vim".into();
        settings.productivity.url_handler = productivity::UrlHandler::Brave;
        settings.reset_section(SettingsSection::SnippetsTools);
        assert!(!settings.productivity.cmd_click_paths);
        assert_eq!(settings.productivity.default_editor, "vim");
        assert_eq!(
            settings.productivity.url_handler,
            productivity::UrlHandler::Brave
        );
        assert_eq!(
            settings.productivity.clipboard_history_max,
            defaults.productivity.clipboard_history_max
        );
        assert!(!settings.general.allow_protected_folder_access);
    }

    #[test]
    fn dangerous_commands_reset_also_restores_shared_terminal_preferences() {
        let mut settings = Settings::default();
        settings.terminal.scrollback_lines = 333;
        settings.terminal.startup_command = "echo custom".into();
        settings.dangerous_commands.guard_enabled = false;
        settings.dangerous_commands.patterns.clear();
        settings.appearance.font_size = 22.0;
        settings.reset_section(SettingsSection::DangerousCommands);
        let defaults = Settings::default();
        assert_eq!(
            settings.terminal.scrollback_lines,
            defaults.terminal.scrollback_lines
        );
        assert_eq!(
            settings.terminal.startup_command,
            defaults.terminal.startup_command
        );
        assert_eq!(settings.dangerous_commands, defaults.dangerous_commands);
        assert_eq!(settings.appearance.font_size, 22.0);
    }
}
