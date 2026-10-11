//! MCP (`MCPSettingsView.swift`): whether agents may open tabs, the tab
//! limit, the approval prompt, the tab indicator, and the command
//! permissions (mode, allowed and blocked commands, MCP profiles).
//!
//! Swift keeps these in UserDefaults (`mcp.enabled`, `mcp.maxTabs`,
//! `mcp.requiresApproval`, `mcp.showTabIndicator`, `mcp.permissionMode`,
//! `mcp.allowedCommands`, `mcp.blockedCommands`, `mcp.profiles`). Its
//! config.toml has no MCP section, so Chau7 Next stores them under `[next]`:
//! `mcp_enabled`, `mcp_max_tabs`, `mcp_requires_approval`,
//! `mcp_show_tab_indicator`, `mcp_permission_mode` (Swift raw values), and
//! `mcp_allowed_commands`, `mcp_blocked_commands`, `mcp_profiles` as JSON
//! text (profiles in the Swift `MCPProfile` JSON format).
//!
//! The scripting API switch (`feature.scriptingAPI` in Swift, which never
//! starts the server) is `scripting_api`.

use chau7_next_core::config::RawValue;
use chau7_next_core::mcp::command_filter::{ResolvedPermissions, add_allowed};
use chau7_next_core::mcp_profile::{MCPPermissionMode, MCPProfile};
use uuid::Uuid;

use super::{ConfigSink, ConfigSource, SettingsDomain};

/// The tab limit can never go above this (`absoluteMaxTabs`).
pub const ABSOLUTE_MAX_TABS: u32 = 50;

#[derive(Debug, Clone, PartialEq)]
pub struct McpSettings {
    /// `mcp.enabled` (default on): off refuses `tab_create`.
    pub enabled: bool,
    /// `mcp.maxTabs` (default 4, 1 to 50): MCP tabs per window.
    pub max_tabs: u32,
    /// `mcp.requiresApproval` (default off): ask before an agent opens a tab.
    pub requires_approval: bool,
    /// `mcp.showTabIndicator` (default on). Stored and shown; like Swift,
    /// nothing reads it (MCP-050).
    pub show_tab_indicator: bool,
    pub permission_mode: MCPPermissionMode,
    pub allowed_commands: Vec<String>,
    pub blocked_commands: Vec<String>,
    pub profiles: Vec<MCPProfile>,
    /// `feature.scriptingAPI` (default off): the scripting socket
    /// (`crate::scripting`).
    pub scripting_api: bool,
}

impl Default for McpSettings {
    fn default() -> Self {
        Self {
            enabled: true,
            max_tabs: 4,
            requires_approval: false,
            show_tab_indicator: true,
            permission_mode: MCPPermissionMode::AllowAll,
            allowed_commands: Vec::new(),
            blocked_commands: Vec::new(),
            profiles: Vec::new(),
            scripting_api: false,
        }
    }
}

impl McpSettings {
    /// The effective tab limit (`min(mcpMaxTabs, absoluteMaxTabs)`).
    pub fn tab_limit(&self) -> usize {
        self.max_tabs.clamp(1, ABSOLUTE_MAX_TABS) as usize
    }

    /// The global rules, for [`chau7_next_core::mcp::command_filter`].
    pub fn global_permissions(&self) -> ResolvedPermissions {
        ResolvedPermissions::global(
            self.permission_mode,
            &self.allowed_commands,
            &self.blocked_commands,
        )
    }

    /// `addToAllowedCommands(_:profileID:)`: "Always Allow" adds the command
    /// to the matched profile, or to the global list.
    pub fn add_allowed_command(&mut self, command: &str, profile: Option<Uuid>) {
        if let Some(id) = profile
            && let Some(p) = self.profiles.iter_mut().find(|p| p.id == id)
        {
            add_allowed(&mut p.allowed_commands, command);
            return;
        }
        add_allowed(&mut self.allowed_commands, command);
    }
}

pub fn mode_from_raw(raw: &str) -> Option<MCPPermissionMode> {
    MCPPermissionMode::ALL
        .into_iter()
        .find(|m| m.raw_value() == raw)
}

/// Quote text for a `[next]` value (the config parser does not unescape,
/// so [`unescape`] undoes this on load).
fn quote(text: &str) -> String {
    let escaped = text
        .replace('\\', "\\\\")
        .replace('"', "\\\"")
        .replace('\n', "\\n")
        .replace('\r', "\\r");
    format!("\"{escaped}\"")
}

fn unescape(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut chars = text.chars();
    while let Some(c) = chars.next() {
        if c != '\\' {
            out.push(c);
            continue;
        }
        match chars.next() {
            Some('n') => out.push('\n'),
            Some('r') => out.push('\r'),
            Some('t') => out.push('\t'),
            Some(other) => out.push(other),
            None => out.push('\\'),
        }
    }
    out
}

fn json_value<T: serde::de::DeserializeOwned>(value: Option<&RawValue>) -> Option<T> {
    let text = value?.as_str()?;
    serde_json::from_str(&unescape(text)).ok()
}

fn clean_list(list: Vec<String>) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    for item in list {
        let item = item.trim().to_lowercase();
        if !item.is_empty() && !out.contains(&item) {
            out.push(item);
        }
    }
    out
}

impl SettingsDomain for McpSettings {
    fn load(&mut self, src: &ConfigSource) {
        if let Some(v) = src.next("mcp_enabled").and_then(RawValue::as_bool) {
            self.enabled = v;
        }
        if let Some(v) = src.next("mcp_max_tabs").and_then(RawValue::as_int) {
            self.max_tabs = v.clamp(1, ABSOLUTE_MAX_TABS as i64) as u32;
        }
        if let Some(v) = src
            .next("mcp_requires_approval")
            .and_then(RawValue::as_bool)
        {
            self.requires_approval = v;
        }
        if let Some(v) = src
            .next("mcp_show_tab_indicator")
            .and_then(RawValue::as_bool)
        {
            self.show_tab_indicator = v;
        }
        if let Some(mode) = src
            .next("mcp_permission_mode")
            .and_then(RawValue::as_str)
            .and_then(mode_from_raw)
        {
            self.permission_mode = mode;
        }
        if let Some(list) = json_value::<Vec<String>>(src.next("mcp_allowed_commands")) {
            self.allowed_commands = clean_list(list);
        }
        if let Some(list) = json_value::<Vec<String>>(src.next("mcp_blocked_commands")) {
            self.blocked_commands = clean_list(list);
        }
        if let Some(profiles) = json_value::<Vec<MCPProfile>>(src.next("mcp_profiles")) {
            self.profiles = profiles;
        }
        if let Some(v) = src.next("scripting_api").and_then(RawValue::as_bool) {
            self.scripting_api = v;
        }
    }

    fn save(&self, out: &mut ConfigSink) {
        out.set_next("mcp_enabled", self.enabled);
        out.set_next("mcp_max_tabs", self.max_tabs);
        out.set_next("mcp_requires_approval", self.requires_approval);
        out.set_next("mcp_show_tab_indicator", self.show_tab_indicator);
        out.set_next(
            "mcp_permission_mode",
            format!("\"{}\"", self.permission_mode.raw_value()),
        );
        out.set_next("mcp_allowed_commands", json(&self.allowed_commands));
        out.set_next("mcp_blocked_commands", json(&self.blocked_commands));
        out.set_next("mcp_profiles", json(&self.profiles));
        out.set_next("scripting_api", self.scripting_api);
    }
}

/// A value as quoted compact JSON.
fn json<T: serde::Serialize>(value: &T) -> String {
    quote(&serde_json::to_string(value).unwrap_or_else(|_| "[]".into()))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::settings::{load_text, round_trip};
    use chau7_next_core::profile_rules::ProfileSwitchTrigger;

    #[test]
    fn defaults_follow_swift() {
        let d = McpSettings::default();
        assert!(d.enabled && !d.requires_approval && d.show_tab_indicator);
        assert!(!d.scripting_api);
        assert_eq!(d.max_tabs, 4);
        assert_eq!(d.permission_mode, MCPPermissionMode::AllowAll);
    }

    #[test]
    fn round_trips_with_lists_and_profiles() {
        let mut profile = MCPProfile::new(
            "Prod \"main\" \\ x",
            ProfileSwitchTrigger::EnvironmentVariable {
                key: "ENV".into(),
                value: "prod".into(),
            },
        );
        profile.allowed_commands = vec!["git".into()];
        profile.priority = 7;
        let d = McpSettings {
            enabled: false,
            max_tabs: 12,
            requires_approval: true,
            show_tab_indicator: false,
            permission_mode: MCPPermissionMode::AskUnlisted,
            allowed_commands: vec!["ls".into(), "git".into()],
            blocked_commands: vec!["rm".into()],
            profiles: vec![profile],
            scripting_api: true,
        };
        assert_eq!(round_trip(&d), d);
        assert_eq!(round_trip(&McpSettings::default()), McpSettings::default());
    }

    #[test]
    fn values_are_clamped_and_cleaned() {
        let d: McpSettings = load_text(
            "[next]\nmcp_max_tabs = 900\nmcp_permission_mode = \"bogus\"\nmcp_allowed_commands = \"[\\\"Git\\\",\\\" \\\",\\\"git\\\"]\"\n",
        );
        assert_eq!(d.max_tabs, 50);
        assert_eq!(d.permission_mode, MCPPermissionMode::AllowAll);
        assert_eq!(d.allowed_commands, ["git"]);
        let d: McpSettings = load_text("[next]\nmcp_max_tabs = 0\n");
        assert_eq!(d.tab_limit(), 1);
    }

    #[test]
    fn always_allow_goes_to_the_profile_or_global_list() {
        let profile = MCPProfile::new(
            "P",
            ProfileSwitchTrigger::ProcessRunning {
                name: "node".into(),
            },
        );
        let id = profile.id;
        let mut d = McpSettings {
            profiles: vec![profile],
            ..Default::default()
        };
        d.add_allowed_command("Make", Some(id));
        d.add_allowed_command("make", Some(id));
        assert_eq!(d.profiles[0].allowed_commands, ["make"]);
        assert!(d.allowed_commands.is_empty());
        d.add_allowed_command("Cargo", None);
        d.add_allowed_command("cargo", Some(Uuid::new_v4()));
        assert_eq!(d.allowed_commands, ["cargo"]);
    }
}
