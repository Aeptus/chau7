//! Settings export and import as JSON (`FeatureSettings.exportSettings`,
//! `importSettings`, `ExportableSettings`).
//!
//! The file is the Swift `ExportableSettings` document, so a file exported by
//! Chau7 imports into Chau7 Next and the other way round. Swift decodes the
//! file strictly: every non-optional key must exist. The export therefore
//! starts from the full default template (`defaultExportableSettings`) and
//! overwrites the shared keys from their typed domains. A versioned Next
//! extension also preserves all preferences saved by those domains, including
//! editor, proxy, history, usage and optimizer options absent from Swift JSON.
//! Next uses its own extension when present; Swift ignores that unknown key.

mod current;

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
    set("bellSound", json!(t.bell_sound.raw_value()));
    set(
        "restoredScrollbackLines",
        json!(t.restored_scrollback_lines),
    );
    set("startupCommand", json!(t.startup_command));
    set("isLsColorsEnabled", json!(t.ls_colors));
    set("isSmartScrollEnabled", json!(t.smart_scroll));
    set(
        "activePollingRateCap",
        json!(a.rendering.active_polling_rate_cap.raw()),
    );
    set(
        "inactiveViewMaxFPS",
        json!(a.rendering.inactive_view_max_fps.clamp(1, 120)),
    );
    set("useMetalRenderer", json!(a.rendering.gpu_renderer));
    if let Some(kind) = t.shell_type {
        set("shellType", json!(kind.raw_value()));
        set("customShellPath", json!(t.custom_shell_path));
    }

    set(
        "newTabPosition",
        json!(match settings.tabs.new_tab_position {
            NewTabPosition::End => "end",
            NewTabPosition::AfterCurrent => "afterCurrent",
        }),
    );

    set("appTheme", json!(settings.appearance.app_theme.id()));
    set("menuBarOnlyMode", json!(settings.appearance.menu_bar_only));
    set(
        "windowBlurEnabled",
        json!(settings.appearance.window_blur_enabled),
    );
    set("windowFloating", json!(settings.appearance.window_floating));
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

    current::export(settings, &mut map);
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
    if current::import_extension(settings, &map)? {
        return Ok(());
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

    if let Some(v) = str_of("bellSound") {
        t.bell_sound = super::BellSound::from_raw(v);
    }
    if let Some(v) = str_of("startupCommand") {
        t.startup_command = v.to_string();
    }
    if let Some(v) = bool_of("isLsColorsEnabled") {
        t.ls_colors = v;
    }
    if let Some(v) = bool_of("isSmartScrollEnabled") {
        t.smart_scroll = v;
    }
    if let Some(v) = map.get("restoredScrollbackLines").and_then(Value::as_u64) {
        t.restored_scrollback_lines =
            v.min(chau7_next_core::session_restore::MAX_RESTORED_SCROLLBACK_LINES as u64) as usize;
    }
    if let Some(v) = str_of("shellType").and_then(chau7_next_core::shell_env::ShellType::from_raw) {
        t.shell_type = Some(v);
        if let Some(path) = str_of("customShellPath") {
            t.custom_shell_path = path.to_string();
        }
    }
    if let Some(v) =
        str_of("activePollingRateCap").and_then(super::appearance::ActivePollingRateCap::from_raw)
    {
        settings.appearance.rendering.active_polling_rate_cap = v;
    }
    if let Some(v) = map.get("inactiveViewMaxFPS").and_then(Value::as_i64) {
        settings.appearance.rendering.inactive_view_max_fps = v.clamp(1, 120) as u32;
    }
    if let Some(v) = bool_of("useMetalRenderer") {
        settings.appearance.rendering.gpu_renderer = v;
    }

    match str_of("newTabPosition") {
        Some("end") => settings.tabs.new_tab_position = NewTabPosition::End,
        Some("afterCurrent") => settings.tabs.new_tab_position = NewTabPosition::AfterCurrent,
        _ => {}
    }

    if let Some(v) = str_of("appTheme").and_then(AppTheme::from_id) {
        settings.appearance.app_theme = v;
    }
    if let Some(v) = bool_of("menuBarOnlyMode") {
        settings.appearance.menu_bar_only = v;
    }
    if let Some(v) = bool_of("windowBlurEnabled") {
        settings.appearance.window_blur_enabled = v;
    }
    if let Some(v) = bool_of("windowFloating") {
        settings.appearance.window_floating = v;
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
    current::import(settings, &map);
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
    fn current_windows_values_survive_both_owned_formats() {
        let mut settings = Settings::default();
        settings.appearance.menu_bar_only = true;
        settings.appearance.window_blur_enabled = false;
        settings.appearance.window_floating = true;
        let restored = Settings::from_text(&settings.to_text(""));
        assert!(restored.appearance.menu_bar_only);
        assert!(!restored.appearance.window_blur_enabled);
        assert!(restored.appearance.window_floating);
        let mut imported = Settings::default();
        import_json(&mut imported, &export_json(&settings, HOME), HOME).unwrap();
        assert!(imported.appearance.menu_bar_only);
        assert!(!imported.appearance.window_blur_enabled);
        assert!(imported.appearance.window_floating);
    }

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
    fn current_terminal_and_refresh_values_survive_owned_formats() {
        let mut source = Settings::default();
        source.terminal.shell_type = Some(chau7_next_core::shell_env::ShellType::Custom);
        source.terminal.custom_shell_path = "/custom/fish".into();
        source.terminal.startup_command = "echo hello".into();
        source.terminal.bell_sound = super::super::BellSound::Subtle;
        source.terminal.restored_scrollback_lines = 2100;
        source.terminal.ls_colors = false;
        source.terminal.smart_scroll = false;
        source.appearance.rendering.active_polling_rate_cap =
            super::super::appearance::ActivePollingRateCap::Hz30;
        source.appearance.rendering.inactive_view_max_fps = 17;
        source.appearance.rendering.gpu_renderer = false;
        let config = Settings::from_text(&source.to_text(""));
        let mut imported = Settings::default();
        import_json(&mut imported, &export_json(&source, "/owned"), "/owned").unwrap();
        for actual in [config, imported.clone()] {
            // Swift's legacy shell path and Next's explicit shell enum can
            // represent the same shell without identical storage fields.
            assert_eq!(
                actual.terminal.effective_shell_type(),
                source.terminal.effective_shell_type()
            );
            assert_eq!(
                actual.terminal.resolved_shell(),
                source.terminal.resolved_shell()
            );
            assert_eq!(
                actual.terminal.startup_command,
                source.terminal.startup_command
            );
            assert_eq!(actual.terminal.bell_sound, source.terminal.bell_sound);
            assert_eq!(
                actual.terminal.restored_scrollback_lines,
                source.terminal.restored_scrollback_lines
            );
            assert_eq!(actual.terminal.ls_colors, source.terminal.ls_colors);
            assert_eq!(actual.terminal.smart_scroll, source.terminal.smart_scroll);
            assert_eq!(actual.appearance.rendering, source.appearance.rendering);
        }
        import_json(
            &mut imported,
            r#"{"fontFamily":"Menlo","activePollingRateCap":"unknown","inactiveViewMaxFPS":999}"#,
            "/owned",
        )
        .unwrap();
        assert_eq!(
            imported.appearance.rendering.active_polling_rate_cap,
            super::super::appearance::ActivePollingRateCap::Hz30
        );
        assert_eq!(imported.appearance.rendering.inactive_view_max_fps, 120);
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
        assert_eq!(settings.general.default_directory, None);
    }
}
