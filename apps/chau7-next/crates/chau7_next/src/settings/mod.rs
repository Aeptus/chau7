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
pub mod config_files;
pub mod dangerous_commands;
mod editor;
pub mod export;
mod general;
mod history;
mod hover_card;
mod input;
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
pub use appearance::{AppTheme, AppearanceSettings, CursorShape, fallback_fonts};
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
        let Ok(text) = std::fs::read_to_string(root.config_file()) else {
            return Settings::default();
        };
        Self::from_text(&text)
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

    pub fn get(cx: &App) -> &Settings {
        cx.global::<Settings>()
    }

    /// Put the settings of one window section back to their defaults
    /// (`resetToDefaults` of each Swift settings view). Sections whose
    /// settings live in other modules are left alone. Font & Colors and
    /// Display share the appearance domain, so they reset it together.
    pub fn reset_section(&mut self, section: SettingsSection) {
        use SettingsSection as S;
        match section {
            S::General => {
                // The startup directory is not edited here: kept.
                let directory = self.general.default_directory.take();
                let contact = self.general.remembered_bug_report_fields();
                self.general = GeneralSettings::default();
                self.general.default_directory = directory;
                self.general.restore_bug_report_fields(contact);
            }
            S::FontColors | S::Display => self.appearance = AppearanceSettings::default(),
            S::Tabs => self.tabs = TabsSettings::default(),
            S::Shell | S::ScrollbackPerf => self.terminal = TerminalSettings::default(),
            S::DangerousCommands => self.dangerous_commands = DangerousCommandSettings::default(),
            S::KeyboardMouse => self.input = InputSettings::default(),
            S::SnippetsTools => self.productivity = ProductivitySettings::default(),
            // Swift resets the trigger conditions (`ConditionRow` reset).
            S::Notifications => self.notifications.reset_conditions(),
            S::Editor => self.editor = EditorSettings::default(),
            _ => {}
        }
    }

    /// Whether [`Settings::reset_section`] resets something for `section`
    /// (the window shows a reset button for those; General has Reset All).
    pub fn can_reset_section(section: SettingsSection) -> bool {
        use SettingsSection as S;
        matches!(
            section,
            S::FontColors
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
        let directory = self.general.default_directory.take();
        let contact = self.general.remembered_bug_report_fields();
        *self = Settings::default();
        self.general.default_directory = directory;
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
}
