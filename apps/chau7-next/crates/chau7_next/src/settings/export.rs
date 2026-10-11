//! Settings export and import as JSON (`FeatureSettings.exportSettings`,
//! `importSettings`, `ExportableSettings`).
//!
//! The file is the Swift `ExportableSettings` document, so a file exported by
//! Chau7 imports into Chau7 Next and the other way round. Swift decodes the
//! file strictly: every non-optional key must exist. The export therefore
//! starts from the full default template (`defaultExportableSettings`) and
//! overwrites the keys Chau7 Next has a setting for. Keys it has no setting
//! for keep their Swift defaults, and are ignored on import.

use chau7_next_core::color_schemes::ColorScheme;
use chau7_next_core::data_root::default_repo_snippet_path;
use chau7_next_core::tabs_state::NewTabPosition;
use serde_json::{Map, Value, json};

use super::{AppLanguage, AppTheme, CursorShape, HighlightScope, Settings};

/// File name proposed by the export dialog.
pub const EXPORT_FILE_NAME: &str = "chau7-settings.json";

/// Shells the Swift `ShellType` names by path.
const KNOWN_SHELLS: [&str; 4] = [
    "/bin/zsh",
    "/bin/bash",
    "/opt/homebrew/bin/fish",
    "/usr/local/bin/fish",
];

/// `defaultExportableSettings` with `home` as the start directory.
fn default_template(home: &str) -> Map<String, Value> {
    // Several small literals: one `json!` this long overflows the macro
    // recursion limit.
    let parts = [
        json!({
            "fontFamily": "SF Mono",
            "fontSize": 11,
            "defaultZoomPercent": 100,
            "colorSchemeName": "Default",
            "shellType": "system",
            "customShellPath": "",
            "startupCommand": "",
            "isLsColorsEnabled": true,
            "customShortcuts": [],
            "isShortcutHelperHintEnabled": true,
            "notificationFilters": {
                "taskFinished": true,
                "taskFailed": true,
                "needsValidation": false,
                "permissionRequest": true,
                "toolComplete": false,
                "sessionEnd": false,
                "commandIdle": false
            },
            "findCaseSensitiveDefault": false,
            "findRegexDefault": false,
            "lastTabCloseBehavior": "keepWindow",
            "newTabPosition": "end",
            "newTabsUseCurrentDirectory": true,
            "alwaysShowTabBar": true,
            "appTheme": "system",
            "launchAtLogin": false,
            "appLanguage": "system",
            "windowOpacity": 1.0,
            "cursorStyle": "block",
            "cursorBlink": true,
            "scrollbackLines": 10000,
            "restoredScrollbackLines": 500,
            "bellEnabled": true,
            "bellSound": "default",
            "defaultStartDirectory": home,
            "isAutoTabThemeEnabled": true
        }),
        json!({
            "showTabIcons": true,
            "showTabPath": true,
            "showTabGitIndicator": true,
            "showTabCTOIndicator": true,
            "allowTabCTOToggle": true,
            "showTabBroadcastIndicator": true,
            "hoverCardShowDirectory": true,
            "hoverCardShowGitBranch": true,
            "hoverCardShowShellIntegration": false,
            "hoverCardShowDevServer": true,
            "hoverCardShowLastCommand": true,
            "hoverCardShowAISession": true,
            "hoverCardShowRepoStats": true,
            "hoverCardShowProcesses": true,
            "hoverCardShowTokenOptimization": false,
            "hoverCardShowBroadcast": false,
            "hoverCardShowConflicts": true,
            "hoverCardShowNotificationState": true,
            "hoverCardShowFooter": true
        }),
        json!({
            "customTitleOnly": false,
            "isCopyOnSelectEnabled": false,
            "isLineTimestampsEnabled": false,
            "timestampFormat": "HH:mm:ss",
            "isLastCommandBadgeEnabled": true,
            "isCmdClickPathsEnabled": true,
            "cmdClickOpensInternalEditor": true,
            "isOptionClickCursorEnabled": true,
            "defaultEditor": "",
            "urlHandler": "system",
            "customAIDetectionRules": []
        }),
        json!({
            "isBroadcastEnabled": false,
            "isClipboardHistoryEnabled": true,
            "clipboardHistoryMaxItems": 50,
            "isBookmarksEnabled": true,
            "maxBookmarksPerTab": 20,
            "isSnippetsEnabled": true,
            "isRepoSnippetsEnabled": true,
            "allowProtectedFolderAccess": true,
            "repoSnippetPath": default_repo_snippet_path(),
            "snippetInsertMode": "expand",
            "snippetPlaceholdersEnabled": true,
            "isSyntaxHighlightEnabled": true,
            "isClickableURLsEnabled": true,
            "isInlineImagesEnabled": true,
            "isJSONPrettyPrintEnabled": false,
            "isSemanticSearchEnabled": false,
            "isSplitPanesEnabled": true,
            "keybindingPreset": "default"
        }),
        json!({
            "mcpEnabled": true,
            "mcpMaxTabs": 4,
            "mcpRequiresApproval": false,
            "mcpShowTabIndicator": true,
            "mcpPermissionMode": "allowAll",
            "mcpAllowedCommands": [],
            "mcpBlockedCommands": [],
            "mcpProfiles": [],
            "isRemoteEnabled": false,
            "remoteRelayURL": "wss://relay.example.com/connect",
            "isCTOEnabled": false,
            "ctoPrefix": "",
            "ctoTabOverrides": {},
            "exportVersion": 1
        }),
    ];
    let mut map = Map::new();
    for part in parts {
        if let Value::Object(entries) = part {
            map.extend(entries);
        }
    }
    map
}

/// The settings as an `ExportableSettings` JSON document.
pub fn export_json(settings: &Settings, home: &str) -> String {
    let mut map = default_template(home);
    let mut set = |key: &str, value: Value| {
        map.insert(key.to_string(), value);
    };

    let a = &settings.appearance;
    set("fontFamily", json!(a.font_family));
    set("fontSize", json!(a.font_size.round() as i64));
    set("colorSchemeName", json!(a.color_scheme.name));
    set("windowOpacity", json!(f64::from(a.opacity)));
    set("cursorStyle", json!(cursor_id(&a.cursor_shape)));
    set("cursorBlink", json!(a.cursor_blink));

    let t = &settings.terminal;
    match t.shell.as_deref() {
        None => set("shellType", json!("system")),
        Some(path) if KNOWN_SHELLS.contains(&path) => set("shellType", json!(path)),
        Some(path) => {
            set("shellType", json!("custom"));
            set("customShellPath", json!(path));
        }
    }
    set("scrollbackLines", json!(t.scrollback_lines));
    set("bellEnabled", json!(t.bell_enabled));

    set(
        "newTabPosition",
        json!(match settings.tabs.new_tab_position {
            NewTabPosition::End => "end",
            NewTabPosition::AfterCurrent => "afterCurrent",
        }),
    );

    set("appTheme", json!(settings.appearance.app_theme.id()));
    let g = &settings.general;
    set("appLanguage", json!(g.app_language.id()));
    set("launchAtLogin", json!(g.launch_at_login));
    set(
        "defaultStartDirectory",
        json!(g.default_directory.as_deref().unwrap_or(home)),
    );

    set(
        "isCopyOnSelectEnabled",
        json!(settings.input.copy_on_select),
    );
    set(
        "customShortcuts",
        Value::Array(
            settings
                .input
                .keybindings
                .iter()
                .filter_map(|(combo, action)| shortcut_json(combo, action))
                .collect(),
        ),
    );

    let max = settings.productivity.clipboard_history_max;
    set("isClipboardHistoryEnabled", json!(max > 0));
    if max > 0 {
        set("clipboardHistoryMaxItems", json!(max));
    }

    set(
        "isDangerousCommandHighlightEnabled",
        json!(settings.dangerous_commands.scope != HighlightScope::Disabled),
    );
    set(
        "dangerousCommandPatterns",
        json!(settings.dangerous_commands.patterns),
    );

    let mcp = &settings.mcp;
    set("mcpEnabled", json!(mcp.enabled));
    set("mcpMaxTabs", json!(mcp.max_tabs));
    set("mcpRequiresApproval", json!(mcp.requires_approval));
    set("mcpShowTabIndicator", json!(mcp.show_tab_indicator));
    set("mcpPermissionMode", json!(mcp.permission_mode.raw_value()));
    set("mcpAllowedCommands", json!(mcp.allowed_commands));
    set("mcpBlockedCommands", json!(mcp.blocked_commands));
    set(
        "mcpProfiles",
        serde_json::to_value(&mcp.profiles).unwrap_or(json!([])),
    );
    set("isRemoteEnabled", json!(settings.remote.enabled));
    set("remoteRelayURL", json!(settings.remote.relay_url));

    // Token optimization: the input prefix switch, its text and the tab
    // overrides (`isCTOEnabled`, `ctoPrefix`, `ctoTabOverrides`).
    let cto = &settings.cto;
    set("isCTOEnabled", json!(cto.prefix_enabled));
    set("ctoPrefix", json!(cto.prefix));
    set("ctoTabOverrides", json!(cto.tab_overrides));

    serde_json::to_string_pretty(&Value::Object(map)).unwrap_or_default()
}

/// Apply an `ExportableSettings` document. Keys without a Chau7 Next setting
/// are ignored; values of the wrong type or unknown names keep the current
/// setting. An error means the text is not a settings document at all.
pub fn import_json(settings: &mut Settings, text: &str, home: &str) -> Result<(), String> {
    let value: Value = serde_json::from_str(text).map_err(|e| format!("not valid JSON: {e}"))?;
    let Value::Object(map) = value else {
        return Err("not a settings document".into());
    };
    // A document with none of the core keys is something else.
    if !map.contains_key("fontFamily") && !map.contains_key("colorSchemeName") {
        return Err("not a Chau7 settings document".into());
    }
    let str_of = |key: &str| map.get(key).and_then(Value::as_str);
    let bool_of = |key: &str| map.get(key).and_then(Value::as_bool);
    let f64_of = |key: &str| map.get(key).and_then(Value::as_f64);

    let a = &mut settings.appearance;
    if let Some(v) = str_of("fontFamily").filter(|s| !s.is_empty()) {
        a.font_family = v.to_string();
    }
    if let Some(v) = f64_of("fontSize").filter(|v| *v > 0.0) {
        a.font_size = v as f32;
    }
    if let Some(v) = str_of("colorSchemeName") {
        a.color_scheme = ColorScheme::named(v);
    }
    if let Some(v) = f64_of("windowOpacity") {
        a.opacity = (v as f32).clamp(0.3, 1.0);
    }
    if let Some(v) = str_of("cursorStyle") {
        a.cursor_shape = match v {
            "bar" | "beam" | "line" => CursorShape::Bar,
            "underline" => CursorShape::Underline,
            _ => CursorShape::Block,
        };
    }
    if let Some(v) = bool_of("cursorBlink") {
        a.cursor_blink = v;
    }

    let t = &mut settings.terminal;
    if let Some(kind) = str_of("shellType") {
        match kind {
            "system" => t.shell = None,
            "custom" => {
                t.shell = str_of("customShellPath")
                    .filter(|s| !s.is_empty())
                    .map(str::to_string)
            }
            path if path.starts_with('/') => t.shell = Some(path.to_string()),
            _ => {}
        }
    }
    if let Some(v) = map
        .get("scrollbackLines")
        .and_then(Value::as_u64)
        .filter(|v| *v > 0)
    {
        t.scrollback_lines = v as usize;
    }
    if let Some(v) = bool_of("bellEnabled") {
        t.bell_enabled = v;
    }

    match str_of("newTabPosition") {
        Some("end") => settings.tabs.new_tab_position = NewTabPosition::End,
        Some("afterCurrent") => settings.tabs.new_tab_position = NewTabPosition::AfterCurrent,
        _ => {}
    }

    if let Some(v) = str_of("appTheme").and_then(AppTheme::from_id) {
        settings.appearance.app_theme = v;
    }
    let g = &mut settings.general;
    if let Some(v) = str_of("appLanguage").and_then(AppLanguage::from_id) {
        g.app_language = v;
    }
    if let Some(v) = bool_of("launchAtLogin") {
        g.launch_at_login = v;
    }
    if let Some(dir) = str_of("defaultStartDirectory") {
        g.default_directory = (!dir.is_empty() && dir != home).then(|| dir.to_string());
    }

    if let Some(v) = bool_of("isCopyOnSelectEnabled") {
        settings.input.copy_on_select = v;
    }

    match (
        bool_of("isClipboardHistoryEnabled"),
        map.get("clipboardHistoryMaxItems").and_then(Value::as_u64),
    ) {
        (Some(false), _) => settings.productivity.clipboard_history_max = 0,
        (Some(true), Some(n)) if n > 0 => settings.productivity.clipboard_history_max = n as usize,
        _ => {}
    }

    if let Some(v) = bool_of("isDangerousCommandHighlightEnabled") {
        let scope = &mut settings.dangerous_commands.scope;
        if !v {
            *scope = HighlightScope::Disabled;
        } else if *scope == HighlightScope::Disabled {
            *scope = HighlightScope::AllOutputs;
        }
    }
    if let Some(patterns) = map
        .get("dangerousCommandPatterns")
        .and_then(Value::as_array)
    {
        settings.dangerous_commands.patterns = patterns
            .iter()
            .filter_map(|p| p.as_str().map(str::to_string))
            .collect();
    }

    let mcp = &mut settings.mcp;
    if let Some(v) = bool_of("mcpEnabled") {
        mcp.enabled = v;
    }
    if let Some(v) = map.get("mcpMaxTabs").and_then(Value::as_i64) {
        mcp.max_tabs = v.clamp(1, super::mcp::ABSOLUTE_MAX_TABS as i64) as u32;
    }
    if let Some(v) = bool_of("mcpRequiresApproval") {
        mcp.requires_approval = v;
    }
    if let Some(v) = bool_of("mcpShowTabIndicator") {
        mcp.show_tab_indicator = v;
    }
    if let Some(mode) = str_of("mcpPermissionMode").and_then(super::mcp::mode_from_raw) {
        mcp.permission_mode = mode;
    }
    let list = |key: &str| -> Option<Vec<String>> {
        Some(
            map.get(key)?
                .as_array()?
                .iter()
                .filter_map(|v| v.as_str().map(str::to_string))
                .collect(),
        )
    };
    if let Some(v) = list("mcpAllowedCommands") {
        mcp.allowed_commands = v;
    }
    if let Some(v) = list("mcpBlockedCommands") {
        mcp.blocked_commands = v;
    }
    if let Some(profiles) = map
        .get("mcpProfiles")
        .cloned()
        .and_then(|v| serde_json::from_value(v).ok())
    {
        mcp.profiles = profiles;
    }
    if let Some(v) = bool_of("isRemoteEnabled") {
        settings.remote.enabled = v;
    }
    if let Some(v) = str_of("remoteRelayURL") {
        settings.remote.relay_url = v.trim().to_string();
    }
    if let Some(v) = bool_of("isCTOEnabled") {
        settings.cto.prefix_enabled = v;
    }
    if let Some(v) = str_of("ctoPrefix") {
        settings.cto.prefix = super::token_optimization::clean_prefix(v);
    }
    if let Some(Value::Object(overrides)) = map.get("ctoTabOverrides") {
        settings.cto.tab_overrides = overrides
            .iter()
            .filter_map(|(tab, on)| Some((tab.clone(), on.as_bool()?)))
            .collect();
    }
    Ok(())
}

fn cursor_id(shape: &CursorShape) -> &'static str {
    match shape {
        CursorShape::Block => "block",
        CursorShape::Bar => "bar",
        CursorShape::Underline => "underline",
    }
}

/// A `[keybindings]` entry ("cmd+shift+t" = "newTab") as a Swift
/// `KeyboardShortcut` (`{action, key, modifiers}`).
fn shortcut_json(combo: &str, action: &str) -> Option<Value> {
    let (modifiers, key) = combo.rsplit_once('+').unwrap_or(("", combo));
    if key.is_empty() {
        return None;
    }
    let modifiers: Vec<&str> = modifiers
        .split('+')
        .filter(|m| !m.is_empty())
        .map(|m| match m {
            "alt" | "option" => "opt",
            "control" => "ctrl",
            "command" | "super" => "cmd",
            other => other,
        })
        .collect();
    Some(json!({ "action": action, "key": key, "modifiers": modifiers }))
}

#[cfg(test)]
mod tests {
    use super::*;

    const HOME: &str = "/Users/me";

    #[test]
    fn export_has_every_required_swift_key() {
        let text = export_json(&Settings::default(), HOME);
        let map: Map<String, Value> = serde_json::from_str(&text).unwrap();
        for key in [
            "fontFamily",
            "fontSize",
            "colorSchemeName",
            "shellType",
            "customShellPath",
            "startupCommand",
            "customShortcuts",
            "notificationFilters",
            "windowOpacity",
            "cursorStyle",
            "cursorBlink",
            "scrollbackLines",
            "restoredScrollbackLines",
            "bellEnabled",
            "bellSound",
            "defaultStartDirectory",
            "isAutoTabThemeEnabled",
            "isCopyOnSelectEnabled",
            "isLineTimestampsEnabled",
            "timestampFormat",
            "isLastCommandBadgeEnabled",
            "isCmdClickPathsEnabled",
            "isOptionClickCursorEnabled",
            "defaultEditor",
            "isBroadcastEnabled",
            "isClipboardHistoryEnabled",
            "clipboardHistoryMaxItems",
            "isBookmarksEnabled",
            "maxBookmarksPerTab",
            "isSnippetsEnabled",
            "isRepoSnippetsEnabled",
            "repoSnippetPath",
            "snippetInsertMode",
            "snippetPlaceholdersEnabled",
            "isSyntaxHighlightEnabled",
            "isClickableURLsEnabled",
            "isInlineImagesEnabled",
            "isJSONPrettyPrintEnabled",
            "isSemanticSearchEnabled",
            "isSplitPanesEnabled",
            "keybindingPreset",
            "isCTOEnabled",
            "ctoPrefix",
            "ctoTabOverrides",
            "exportVersion",
        ] {
            assert!(map.contains_key(key), "missing {key}");
        }
    }

    #[test]
    fn round_trips_the_settings_chau7_next_has() {
        let mut settings = Settings::default();
        settings.appearance.font_family = "Menlo".into();
        settings.appearance.font_size = 14.0;
        settings.appearance.color_scheme = ColorScheme::named("Default");
        settings.appearance.cursor_shape = CursorShape::Underline;
        settings.appearance.opacity = 0.8;
        settings.terminal.shell = Some("/bin/fish-custom".into());
        settings.terminal.scrollback_lines = 5000;
        settings.tabs.new_tab_position = NewTabPosition::AfterCurrent;
        settings.appearance.app_theme = AppTheme::Dark;
        settings.general.app_language = AppLanguage::French;
        settings.general.default_directory = Some("/work".into());
        settings.input.copy_on_select = true;
        settings.productivity.clipboard_history_max = 0;
        settings.dangerous_commands.patterns = vec!["rm -rf".into()];
        settings.remote.enabled = true;
        settings.remote.relay_url = "wss://relay.test/connect".into();

        let text = export_json(&settings, HOME);
        let mut imported = Settings::default();
        import_json(&mut imported, &text, HOME).unwrap();
        assert_eq!(imported.appearance.font_family, "Menlo");
        assert_eq!(imported.appearance.font_size, 14.0);
        assert_eq!(imported.appearance.cursor_shape, CursorShape::Underline);
        assert!((imported.appearance.opacity - 0.8).abs() < 1e-6);
        assert_eq!(imported.terminal.shell.as_deref(), Some("/bin/fish-custom"));
        assert_eq!(imported.terminal.scrollback_lines, 5000);
        assert_eq!(imported.tabs.new_tab_position, NewTabPosition::AfterCurrent);
        assert_eq!(imported.appearance.app_theme, AppTheme::Dark);
        assert_eq!(imported.general.app_language, AppLanguage::French);
        assert_eq!(imported.general.default_directory.as_deref(), Some("/work"));
        assert!(imported.input.copy_on_select);
        assert_eq!(imported.productivity.clipboard_history_max, 0);
        assert_eq!(imported.dangerous_commands.patterns, vec!["rm -rf"]);
        assert!(imported.remote.enabled);
        assert_eq!(imported.remote.relay_url, "wss://relay.test/connect");
    }

    #[test]
    fn mcp_settings_round_trip() {
        use chau7_next_core::mcp_profile::{MCPPermissionMode, MCPProfile};
        use chau7_next_core::profile_rules::ProfileSwitchTrigger;
        let mut settings = Settings::default();
        settings.mcp.enabled = false;
        settings.mcp.max_tabs = 9;
        settings.mcp.permission_mode = MCPPermissionMode::AuditOnly;
        settings.mcp.blocked_commands = vec!["rm".into()];
        settings.mcp.profiles = vec![MCPProfile::new(
            "P",
            ProfileSwitchTrigger::GitRepository { name: "r".into() },
        )];
        let text = export_json(&settings, HOME);
        let v: Value = serde_json::from_str(&text).unwrap();
        assert_eq!(v["mcpPermissionMode"], "audit_only");
        assert_eq!(v["mcpProfiles"][0]["trigger"]["gitRepository"]["name"], "r");
        let mut imported = Settings::default();
        import_json(&mut imported, &text, HOME).unwrap();
        assert_eq!(imported.mcp, settings.mcp);
    }

    #[test]
    fn token_optimization_settings_round_trip() {
        let mut settings = Settings::default();
        settings.cto.prefix_enabled = true;
        settings.cto.prefix = "use cto".into();
        settings.cto.tab_overrides.insert("TAB-1".into(), false);
        let text = export_json(&settings, HOME);
        let v: Value = serde_json::from_str(&text).unwrap();
        assert_eq!(v["isCTOEnabled"], true);
        assert_eq!(v["ctoPrefix"], "use cto");
        assert_eq!(v["ctoTabOverrides"]["TAB-1"], false);
        let mut imported = Settings::default();
        import_json(&mut imported, &text, HOME).unwrap();
        assert_eq!(imported.cto, settings.cto);
    }

    #[test]
    fn home_start_directory_means_unset() {
        let mut settings = Settings::default();
        settings.general.default_directory = Some("/old".into());
        let text = export_json(&Settings::default(), HOME);
        import_json(&mut settings, &text, HOME).unwrap();
        assert_eq!(settings.general.default_directory, None);
    }

    #[test]
    fn known_shell_paths_keep_swift_raw_values() {
        let mut settings = Settings::default();
        settings.terminal.shell = Some("/bin/zsh".into());
        let text = export_json(&settings, HOME);
        let map: Map<String, Value> = serde_json::from_str(&text).unwrap();
        assert_eq!(map["shellType"], "/bin/zsh");
    }

    #[test]
    fn swift_file_imports_and_bad_files_are_rejected() {
        let mut settings = Settings::default();
        let swift = r#"{"fontFamily":"Menlo","fontSize":13,"colorSchemeName":"Default",
            "shellType":"/bin/bash","windowOpacity":0.9,"cursorStyle":"bar","unknownKey":1}"#;
        import_json(&mut settings, swift, HOME).unwrap();
        assert_eq!(settings.appearance.font_size, 13.0);
        assert_eq!(settings.terminal.shell.as_deref(), Some("/bin/bash"));
        assert_eq!(settings.appearance.cursor_shape, CursorShape::Bar);

        assert!(import_json(&mut settings, "nope", HOME).is_err());
        assert!(import_json(&mut settings, "[1]", HOME).is_err());
        assert!(import_json(&mut settings, "{\"x\":1}", HOME).is_err());
    }

    #[test]
    fn shortcuts_convert_to_swift_shape() {
        let v = shortcut_json("cmd+shift+t", "newTab").unwrap();
        assert_eq!(v["key"], "t");
        assert_eq!(v["modifiers"], json!(["cmd", "shift"]));
        assert_eq!(
            shortcut_json("alt+x", "a").unwrap()["modifiers"],
            json!(["opt"])
        );
        assert!(shortcut_json("cmd+", "a").is_none());
    }

    #[test]
    fn reset_section_restores_defaults() {
        let mut settings = Settings::default();
        settings.tabs.confirm_close = !settings.tabs.confirm_close;
        settings.general.default_directory = Some("/keep".into());
        settings.general.launch_at_login = true;
        settings.reset_section(chau7_next_core::settings_search::SettingsSection::Tabs);
        assert_eq!(settings.tabs, Settings::default().tabs);
        settings.reset_all();
        assert!(!settings.general.launch_at_login);
        assert_eq!(settings.general.default_directory.as_deref(), Some("/keep"));
    }
}
