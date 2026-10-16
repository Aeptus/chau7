//! Tabs (`TabsSettingsView.swift`): behavior (new tab position and
//! directory, last tab close, close warnings, tab bar, idle tabs, repo
//! groups) and tab display (custom title only, icons, path, git, CTO and
//! broadcast indicators, last command badge).

use chau7_next_core::config::RawValue;
use chau7_next_core::tabs_state::NewTabPosition;

use super::{ConfigSink, ConfigSource, SettingsDomain};

/// `LastTabCloseBehavior` (`tabs.lastTabCloseBehavior`, default `keepWindow`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum LastTabClose {
    #[default]
    KeepWindow,
    CloseWindow,
}

impl LastTabClose {
    pub const ALL: [LastTabClose; 2] = [LastTabClose::KeepWindow, LastTabClose::CloseWindow];

    pub fn raw(self) -> &'static str {
        match self {
            LastTabClose::KeepWindow => "keepWindow",
            LastTabClose::CloseWindow => "closeWindow",
        }
    }

    pub fn label(self) -> &'static str {
        match self {
            LastTabClose::KeepWindow => "Keep Window Open (New Tab)",
            LastTabClose::CloseWindow => "Close Window",
        }
    }
}

/// `RepoGroupingMode` (`tabs.repoGroupingMode`, default `off`). Off and
/// Manual both keep existing groups and the manual menu items; Auto groups
/// every tab by its git root.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum RepoGroupingMode {
    #[default]
    Off,
    Auto,
    Manual,
}

impl RepoGroupingMode {
    pub const ALL: [RepoGroupingMode; 3] = [
        RepoGroupingMode::Off,
        RepoGroupingMode::Auto,
        RepoGroupingMode::Manual,
    ];

    pub fn raw(self) -> &'static str {
        match self {
            RepoGroupingMode::Off => "off",
            RepoGroupingMode::Auto => "auto",
            RepoGroupingMode::Manual => "manual",
        }
    }

    pub fn label(self) -> &'static str {
        match self {
            RepoGroupingMode::Off => "Off",
            RepoGroupingMode::Auto => "Automatic",
            RepoGroupingMode::Manual => "Manual",
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct TabsSettings {
    pub new_tab_position: NewTabPosition,
    /// `tabs.newTabsUseCurrentDirectory`, default on.
    pub new_tabs_use_current_directory: bool,
    /// `tabs.lastTabCloseBehavior`. Swift shows it but closing the last tab
    /// always asks "Close Window" or "New Tab"; Chau7 Next does the same.
    pub last_tab_close: LastTabClose,
    pub idle_threshold_minutes: u32,
    pub group_idle_tabs: bool,
    /// Cmd+number and other numbered shortcuts select only tabs in the tab bar row.
    /// Off preserves the existing all-tabs order.
    pub numbered_shortcuts_visible_only: bool,
    pub repo_grouping: RepoGroupingMode,
    /// `[general] confirm_close`: always warn before closing a tab
    /// (`tabs.alwaysWarnOnTabClose`, default off).
    pub confirm_close: bool,
    /// `[general] close_on_exit`: close the tab when its shell exits.
    pub close_on_exit: bool,
    pub warn_on_close_running: bool,
    /// `tabs.alwaysShowTabBar`, default on: off hides the tabs while the
    /// window has a single tab.
    pub always_show_tab_bar: bool,
    /// `tabs.alwaysShowToolbarInFullscreen`, default off. Swift never reads
    /// it (its tab bar always stays visible in fullscreen); same here.
    pub always_show_toolbar_in_fullscreen: bool,
    /// `tabs.display.customTitleOnly`, default off.
    pub custom_title_only: bool,
    /// `tabs.display.showIcons`, default on.
    pub show_icons: bool,
    /// `feature.autoTabTheme` ("AI Product Logos", automatic tab color), default on.
    pub auto_tab_theme: bool,
    /// `tabs.display.showPath`, default on.
    pub show_path: bool,
    /// `tabs.display.showGitIndicator`, default on.
    pub show_git_indicator: bool,
    /// `tabs.display.showCTOIndicator`, default on (no UI in Swift).
    pub show_cto_indicator: bool,
    /// `tabs.display.allowCTOToggle`, default on.
    pub allow_cto_toggle: bool,
    /// `tabs.display.showBroadcastIndicator`, default on.
    pub show_broadcast_indicator: bool,
    /// `tabs.display.showProviderHealthBorder`, default on.
    pub show_provider_health_border: bool,
    /// `feature.lastCommandBadge`, default on.
    pub last_command_badge: bool,
}

impl Default for TabsSettings {
    fn default() -> Self {
        Self {
            new_tab_position: NewTabPosition::End,
            new_tabs_use_current_directory: true,
            last_tab_close: LastTabClose::KeepWindow,
            idle_threshold_minutes: 10,
            group_idle_tabs: true,
            numbered_shortcuts_visible_only: false,
            repo_grouping: RepoGroupingMode::Off,
            confirm_close: false,
            close_on_exit: true,
            warn_on_close_running: true,
            always_show_tab_bar: true,
            always_show_toolbar_in_fullscreen: false,
            custom_title_only: false,
            show_icons: true,
            auto_tab_theme: true,
            show_path: true,
            show_git_indicator: true,
            show_cto_indicator: true,
            allow_cto_toggle: true,
            show_broadcast_indicator: true,
            show_provider_health_border: true,
            last_command_badge: true,
        }
    }
}

/// A boolean `[next]` key: name, getter, setter.
type BoolField = (
    &'static str,
    fn(&TabsSettings) -> bool,
    fn(&mut TabsSettings, bool),
);

impl TabsSettings {
    /// `repoGroupingMode == .auto`.
    pub fn auto_repo_grouping(&self) -> bool {
        self.repo_grouping == RepoGroupingMode::Auto
    }

    /// The boolean `[next]` keys, with a getter and a setter each.
    fn bools() -> [BoolField; 15] {
        [
            (
                "new_tabs_use_current_directory",
                |s| s.new_tabs_use_current_directory,
                |s, v| s.new_tabs_use_current_directory = v,
            ),
            (
                "group_idle_tabs",
                |s| s.group_idle_tabs,
                |s, v| s.group_idle_tabs = v,
            ),
            (
                "numbered_shortcuts_visible_only",
                |s| s.numbered_shortcuts_visible_only,
                |s, v| s.numbered_shortcuts_visible_only = v,
            ),
            (
                "warn_on_close_running",
                |s| s.warn_on_close_running,
                |s, v| s.warn_on_close_running = v,
            ),
            (
                "always_show_tab_bar",
                |s| s.always_show_tab_bar,
                |s, v| s.always_show_tab_bar = v,
            ),
            (
                "always_show_toolbar_in_fullscreen",
                |s| s.always_show_toolbar_in_fullscreen,
                |s, v| s.always_show_toolbar_in_fullscreen = v,
            ),
            (
                "custom_title_only",
                |s| s.custom_title_only,
                |s, v| s.custom_title_only = v,
            ),
            ("show_tab_icons", |s| s.show_icons, |s, v| s.show_icons = v),
            (
                "auto_tab_theme",
                |s| s.auto_tab_theme,
                |s, v| s.auto_tab_theme = v,
            ),
            ("show_tab_path", |s| s.show_path, |s, v| s.show_path = v),
            (
                "show_tab_git_indicator",
                |s| s.show_git_indicator,
                |s, v| s.show_git_indicator = v,
            ),
            (
                "show_tab_cto_indicator",
                |s| s.show_cto_indicator,
                |s, v| s.show_cto_indicator = v,
            ),
            (
                "allow_tab_cto_toggle",
                |s| s.allow_cto_toggle,
                |s, v| s.allow_cto_toggle = v,
            ),
            (
                "show_tab_broadcast_indicator",
                |s| s.show_broadcast_indicator,
                |s, v| s.show_broadcast_indicator = v,
            ),
            (
                "show_provider_health_border",
                |s| s.show_provider_health_border,
                |s, v| s.show_provider_health_border = v,
            ),
        ]
    }
}

impl SettingsDomain for TabsSettings {
    fn load(&mut self, src: &ConfigSource) {
        if let Some(general) = &src.file.general {
            if let Some(confirm) = general.confirm_close {
                self.confirm_close = confirm;
            }
            if let Some(close) = general.close_on_exit {
                self.close_on_exit = close;
            }
        }
        if let Some(v) = src.next("new_tab_position").and_then(RawValue::as_str) {
            self.new_tab_position = if v == "after" {
                NewTabPosition::AfterCurrent
            } else {
                NewTabPosition::End
            };
        }
        if let Some(v) = src.next("idle_tab_minutes").and_then(RawValue::as_int) {
            self.idle_threshold_minutes = v.clamp(1, 24 * 60) as u32;
        }
        // Older Chau7 Next files: `auto_repo_grouping = true|false`.
        if let Some(v) = src.next("auto_repo_grouping").and_then(RawValue::as_bool) {
            self.repo_grouping = if v {
                RepoGroupingMode::Auto
            } else {
                RepoGroupingMode::Off
            };
        }
        if let Some(v) = src.next("repo_grouping_mode").and_then(RawValue::as_str)
            && let Some(mode) = RepoGroupingMode::ALL.into_iter().find(|m| m.raw() == v)
        {
            self.repo_grouping = mode;
        }
        if let Some(v) = src
            .next("last_tab_close_behavior")
            .and_then(RawValue::as_str)
            && let Some(b) = LastTabClose::ALL.into_iter().find(|b| b.raw() == v)
        {
            self.last_tab_close = b;
        }
        if let Some(v) = src.next("last_command_badge").and_then(RawValue::as_bool) {
            self.last_command_badge = v;
        }
        for (key, _, set) in Self::bools() {
            if let Some(v) = src.next(key).and_then(RawValue::as_bool) {
                set(self, v);
            }
        }
    }

    fn save(&self, out: &mut ConfigSink) {
        let general = out.file.general.get_or_insert_with(Default::default);
        general.close_on_exit = Some(self.close_on_exit);
        general.confirm_close = Some(self.confirm_close);
        out.set_next(
            "new_tab_position",
            if self.new_tab_position == NewTabPosition::AfterCurrent {
                "\"after\""
            } else {
                "\"end\""
            },
        );
        out.set_next("idle_tab_minutes", self.idle_threshold_minutes);
        out.set_next(
            "repo_grouping_mode",
            format!("\"{}\"", self.repo_grouping.raw()),
        );
        out.set_next(
            "last_tab_close_behavior",
            format!("\"{}\"", self.last_tab_close.raw()),
        );
        out.set_next("last_command_badge", self.last_command_badge);
        for (key, get, _) in Self::bools() {
            out.set_next(key, get(self));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::settings::{load_text, round_trip};

    #[test]
    fn round_trips() {
        let tabs = TabsSettings {
            new_tab_position: NewTabPosition::AfterCurrent,
            new_tabs_use_current_directory: false,
            last_tab_close: LastTabClose::CloseWindow,
            idle_threshold_minutes: 25,
            group_idle_tabs: false,
            numbered_shortcuts_visible_only: true,
            repo_grouping: RepoGroupingMode::Manual,
            confirm_close: true,
            close_on_exit: false,
            warn_on_close_running: false,
            always_show_tab_bar: false,
            always_show_toolbar_in_fullscreen: true,
            custom_title_only: true,
            show_icons: false,
            auto_tab_theme: false,
            show_path: false,
            show_git_indicator: false,
            show_cto_indicator: false,
            allow_cto_toggle: false,
            show_broadcast_indicator: false,
            show_provider_health_border: false,
            last_command_badge: false,
        };
        assert_eq!(round_trip(&tabs), tabs);
    }

    #[test]
    fn clamps_idle_minutes() {
        let tabs: TabsSettings = load_text("[next]\nidle_tab_minutes = 0\n");
        assert_eq!(tabs.idle_threshold_minutes, 1);
    }

    /// `FeatureSettingsTests.testDefaultLastTabCloseBehavior`,
    /// `testDefaultAlwaysShowTabBar`.
    #[test]
    fn swift_defaults() {
        let tabs = TabsSettings::default();
        assert_eq!(tabs.last_tab_close, LastTabClose::KeepWindow);
        assert!(tabs.always_show_tab_bar);
        assert!(!tabs.always_show_toolbar_in_fullscreen);
        assert!(tabs.new_tabs_use_current_directory);
        assert!(tabs.show_provider_health_border);
        assert!(!tabs.confirm_close);
        assert!(!tabs.numbered_shortcuts_visible_only);
        assert_eq!(tabs.repo_grouping, RepoGroupingMode::Off);
    }

    #[test]
    fn legacy_auto_repo_grouping_key() {
        let tabs: TabsSettings = load_text("[next]\nauto_repo_grouping = true\n");
        assert_eq!(tabs.repo_grouping, RepoGroupingMode::Auto);
        let tabs: TabsSettings = load_text("[next]\nrepo_grouping_mode = \"manual\"\n");
        assert_eq!(tabs.repo_grouping, RepoGroupingMode::Manual);
    }
}
