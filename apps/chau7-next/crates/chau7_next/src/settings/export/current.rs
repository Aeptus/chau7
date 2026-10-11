//! Current Swift JSON fields shared with Next's typed settings domains.
//! The versioned Next extension uses the existing config domain serializers,
//! so preferences absent from Swift's export schema are preserved as well.
use crate::settings::{HighlightScope, LastTabClose, Settings, SnippetInsertMode, UrlHandler};
use chau7_next_core::input::shortcuts::{self, KeyboardShortcut};
use chau7_next_core::notifications::triggers;
use serde_json::{Map, Value, json};

const NEXT_KEY: &str = "chau7Next";
const MAX_CONFIG_BYTES: usize = 1024 * 1024;

macro_rules! bool_fields {
    ($settings:ident, $visit:ident) => {
        $visit!(
            "isShortcutHelperHintEnabled",
            $settings.input.shortcut_helper_hint
        );
        $visit!(
            "findCaseSensitiveDefault",
            $settings.productivity.find_case_sensitive
        );
        $visit!("findRegexDefault", $settings.productivity.find_regex);
        $visit!(
            "newTabsUseCurrentDirectory",
            $settings.tabs.new_tabs_use_current_directory
        );
        $visit!("alwaysShowTabBar", $settings.tabs.always_show_tab_bar);
        $visit!(
            "alwaysShowToolbarInFullscreen",
            $settings.tabs.always_show_toolbar_in_fullscreen
        );
        $visit!("enableLigatures", $settings.appearance.ligatures);
        $visit!("isAutoTabThemeEnabled", $settings.tabs.auto_tab_theme);
        $visit!("showTabIcons", $settings.tabs.show_icons);
        $visit!("showTabPath", $settings.tabs.show_path);
        $visit!("showTabGitIndicator", $settings.tabs.show_git_indicator);
        $visit!("showTabCTOIndicator", $settings.tabs.show_cto_indicator);
        $visit!("allowTabCTOToggle", $settings.tabs.allow_cto_toggle);
        $visit!(
            "showTabBroadcastIndicator",
            $settings.tabs.show_broadcast_indicator
        );
        $visit!("customTitleOnly", $settings.tabs.custom_title_only);
        $visit!(
            "isLastCommandBadgeEnabled",
            $settings.tabs.last_command_badge
        );
        $visit!(
            "isLineTimestampsEnabled",
            $settings.appearance.display.line_timestamps
        );
        $visit!(
            "isSyntaxHighlightEnabled",
            $settings.appearance.display.syntax_highlight
        );
        $visit!(
            "isClickableURLsEnabled",
            $settings.appearance.display.clickable_urls
        );
        $visit!(
            "isInlineImagesEnabled",
            $settings.appearance.display.inline_images
        );
        $visit!(
            "isJSONPrettyPrintEnabled",
            $settings.appearance.display.json_pretty_print
        );
        $visit!(
            "isCmdClickPathsEnabled",
            $settings.productivity.cmd_click_paths
        );
        $visit!(
            "cmdClickOpensInternalEditor",
            $settings.productivity.cmd_click_internal_editor
        );
        $visit!(
            "isOptionClickCursorEnabled",
            $settings.input.option_click_cursor
        );
        $visit!("isBroadcastEnabled", $settings.input.broadcast_enabled);
        $visit!(
            "isClipboardHistoryEnabled",
            $settings.productivity.clipboard_history_enabled
        );
        $visit!(
            "isBookmarksEnabled",
            $settings.productivity.bookmarks_enabled
        );
        $visit!("isSnippetsEnabled", $settings.productivity.snippets_enabled);
        $visit!(
            "isRepoSnippetsEnabled",
            $settings.productivity.repo_snippets_enabled
        );
        $visit!(
            "allowProtectedFolderAccess",
            $settings.general.allow_protected_folder_access
        );
        $visit!(
            "snippetPlaceholdersEnabled",
            $settings.productivity.snippet_placeholders
        );
        $visit!(
            "isSemanticSearchEnabled",
            $settings.productivity.semantic_search
        );
        $visit!(
            "isSplitPanesEnabled",
            $settings.terminal.split_panes_enabled
        );
        $visit!(
            "dangerousOutputHighlightLowPowerEnabled",
            $settings.dangerous_commands.highlight_low_power
        );
        $visit!(
            "hoverCardShowDirectory",
            $settings.hover_card.show_directory
        );
        $visit!(
            "hoverCardShowGitBranch",
            $settings.hover_card.show_git_branch
        );
        $visit!(
            "hoverCardShowShellIntegration",
            $settings.hover_card.show_shell_integration
        );
        $visit!(
            "hoverCardShowDevServer",
            $settings.hover_card.show_dev_server
        );
        $visit!(
            "hoverCardShowLastCommand",
            $settings.hover_card.show_last_command
        );
        $visit!(
            "hoverCardShowAISession",
            $settings.hover_card.show_ai_session
        );
        $visit!(
            "hoverCardShowRepoStats",
            $settings.hover_card.show_repo_stats
        );
        $visit!(
            "hoverCardShowProcesses",
            $settings.hover_card.show_processes
        );
        $visit!(
            "hoverCardShowTokenOptimization",
            $settings.hover_card.show_token_optimization
        );
        $visit!(
            "hoverCardShowBroadcast",
            $settings.hover_card.show_broadcast
        );
        $visit!(
            "hoverCardShowConflicts",
            $settings.hover_card.show_conflicts
        );
        $visit!(
            "hoverCardShowNotificationState",
            $settings.hover_card.show_notification_state
        );
        $visit!("hoverCardShowFooter", $settings.hover_card.show_footer);
    };
}
macro_rules! string_fields {
    ($settings:ident, $visit:ident) => {
        $visit!(
            "timestampFormat",
            $settings.appearance.display.timestamp_format
        );
        $visit!("defaultEditor", $settings.productivity.default_editor);
        $visit!("repoSnippetPath", $settings.productivity.repo_snippet_path);
    };
}

pub(super) fn export(settings: &Settings, map: &mut Map<String, Value>) {
    macro_rules! write {
        ($key:literal, $value:expr) => {
            map.insert($key.into(), json!($value));
        };
    }
    bool_fields!(settings, write);
    string_fields!(settings, write);
    for (key, value) in [
        ("defaultZoomPercent", json!(settings.appearance.default_zoom_percent)),
        ("clipboardHistoryMaxItems", json!(settings.productivity.clipboard_history_max)),
        ("maxBookmarksPerTab", json!(settings.productivity.max_bookmarks_per_tab)),
        ("dangerousOutputHighlightIdleDelayMs", json!(settings.dangerous_commands.highlight_idle_delay_ms)),
        ("dangerousOutputHighlightMaxIntervalMs", json!(settings.dangerous_commands.highlight_max_interval_ms)),
        ("lastTabCloseBehavior", json!(settings.tabs.last_tab_close.raw())),
        ("snippetInsertMode", json!(settings.productivity.snippet_insert_mode.raw())),
        ("urlHandler", json!(settings.productivity.url_handler.raw())),
        ("keybindingPreset", json!(settings.input.keybinding_preset)),
        ("dangerousCommandHighlightScope", json!(settings.dangerous_commands.scope.raw())),
        ("customShortcuts", json!(settings.input.shortcuts())),
        ("customAIDetectionRules", Value::Array(settings.ai.custom_rules.iter().map(|r| json!({"id":r.id,"pattern":r.pattern,"displayName":r.display_name,"colorName":r.color_name})).collect())),
        ("customColorScheme", settings.appearance.custom_color_scheme.as_deref().and_then(|s| serde_json::from_str(s).ok()).unwrap_or(Value::Null)),
    ] { map.insert(key.into(), value); }
    let rules = &settings.notifications.rules;
    for (key, value) in [
        ("notificationTriggerState", json!(rules.trigger_state)),
        (
            "triggerActionBindings",
            json!(rules.trigger_action_bindings),
        ),
        (
            "notificationRateLimitConfig",
            json!(rules.rate_limit_config),
        ),
        ("triggerConditions", json!(rules.trigger_conditions)),
        ("groupActionBindings", json!(rules.group_action_bindings)),
        ("groupConditions", json!(rules.group_conditions)),
    ] {
        map.insert(key.into(), value);
    }
    let any = |types: &[&str]| {
        triggers::all()
            .iter()
            .filter(|t| !t.is_wildcard() && types.contains(&t.trigger_type.as_str()))
            .any(|t| rules.trigger_state.is_enabled(t))
    };
    map.insert(
        "notificationFilters".into(),
        json!({
            "taskFinished": any(&["finished"]), "taskFailed": any(&["failed"]),
            "needsValidation": any(&["needs_validation"]),
            "permissionRequest": any(&["permission", "waiting_input", "attention_required"]),
            "toolComplete": any(&["tool_complete"]), "sessionEnd": any(&["session_end"]),
            "commandIdle": any(&["idle"]),
        }),
    );
    // Only domain-owned preferences are serialized. Existing config text,
    // Keychain credentials, history, hooks and external files are not read.
    let mut portable = settings.clone();
    portable
        .general
        .restore_bug_report_fields(Default::default());
    map.insert(
        NEXT_KEY.into(),
        json!({"version":1,"config":portable.to_profile_text(), "legacyShell":settings.terminal.shell, "legacyClipboardDisabled":settings.productivity.clipboard_history_max==0}),
    );
}

/// Validate both versions before changing any settings. Future documents cannot
/// be partially applied and reexported with their unknown preferences lost.
pub(super) fn import_extension(
    settings: &mut Settings,
    map: &Map<String, Value>,
) -> Result<bool, String> {
    if let Some(version) = map.get("exportVersion")
        && version.as_u64().is_none_or(|v| v > 1)
    {
        return Err("unsupported settings export version".into());
    }
    if let Some(extension) = map.get(NEXT_KEY) {
        if extension.get("version").and_then(Value::as_u64) != Some(1) {
            return Err("unsupported Chau7 Next settings version".into());
        }
        let text = extension
            .get("config")
            .and_then(Value::as_str)
            .filter(|s| s.len() <= MAX_CONFIG_BYTES && s.contains("[next]"))
            .ok_or("invalid Chau7 Next settings payload")?;
        let mut restored = Settings::from_profile_text(text);
        match extension.get("legacyShell") {
            Some(Value::Null) => restored.terminal.shell = None,
            Some(Value::String(shell)) => restored.terminal.shell = Some(shell.clone()),
            _ => {}
        }
        if extension
            .get("legacyClipboardDisabled")
            .and_then(Value::as_bool)
            == Some(true)
        {
            restored.productivity.clipboard_history_enabled = false;
            restored.productivity.clipboard_history_max = 0;
        }
        // Remembered report details are local to this installation, as in Swift.
        restored
            .general
            .restore_bug_report_fields(settings.general.remembered_bug_report_fields());
        *settings = restored;
    }
    Ok(map.contains_key(NEXT_KEY))
}

pub(super) fn import(settings: &mut Settings, map: &Map<String, Value>) {
    macro_rules! flag {
        ($key:literal, $field:expr) => {
            if let Some(value) = map.get($key).and_then(Value::as_bool) {
                $field = value;
            }
        };
    }
    macro_rules! string {
        ($key:literal, $field:expr) => {
            if let Some(value) = map.get($key).and_then(Value::as_str) {
                $field = value.into();
            }
        };
    }
    bool_fields!(settings, flag);
    string_fields!(settings, string);
    if let Some(n) = map.get("defaultZoomPercent").and_then(Value::as_u64) {
        settings.appearance.default_zoom_percent = n.clamp(50, 200) as u32;
    }
    if let Some(n) = map.get("clipboardHistoryMaxItems").and_then(Value::as_u64) {
        settings.productivity.clipboard_history_max = n.clamp(1, 1000) as usize;
    }
    if let Some(n) = map.get("maxBookmarksPerTab").and_then(Value::as_u64) {
        settings.productivity.max_bookmarks_per_tab = n.clamp(1, 200) as usize;
    }
    if let Some(n) = map
        .get("dangerousOutputHighlightIdleDelayMs")
        .and_then(Value::as_u64)
    {
        settings.dangerous_commands.highlight_idle_delay_ms = n.min(5000) as u32;
    }
    if let Some(n) = map
        .get("dangerousOutputHighlightMaxIntervalMs")
        .and_then(Value::as_u64)
    {
        settings.dangerous_commands.highlight_max_interval_ms = n.clamp(250, 10000) as u32;
    }
    if let Some(value) = map
        .get("lastTabCloseBehavior")
        .and_then(Value::as_str)
        .and_then(|v| LastTabClose::ALL.into_iter().find(|b| b.raw() == v))
    {
        settings.tabs.last_tab_close = value;
    }
    if let Some(value) = map.get("snippetInsertMode").and_then(Value::as_str) {
        match value {
            "expand" => settings.productivity.snippet_insert_mode = SnippetInsertMode::Expand,
            "paste" => settings.productivity.snippet_insert_mode = SnippetInsertMode::Paste,
            _ => {}
        }
    }
    if let Some(value) = map
        .get("urlHandler")
        .and_then(Value::as_str)
        .and_then(UrlHandler::from_raw)
    {
        settings.productivity.url_handler = value;
    }
    if let Some(value) = map
        .get("keybindingPreset")
        .and_then(Value::as_str)
        .filter(|v| shortcuts::PRESETS.contains(v))
    {
        settings.input.keybinding_preset = value.into();
    }
    if let Some(value) = map
        .get("dangerousCommandHighlightScope")
        .and_then(Value::as_str)
        .and_then(HighlightScope::from_raw)
    {
        settings.dangerous_commands.scope = value;
    }
    if let Some(Value::Array(values)) = map.get("customShortcuts")
        && let Ok(shortcuts) =
            serde_json::from_value::<Vec<KeyboardShortcut>>(Value::Array(values.clone()))
        && shortcuts.iter().all(|s| {
            !s.key.is_empty()
                && !s.action.is_empty()
                && s.modifiers
                    .iter()
                    .all(|m| ["cmd", "ctrl", "opt", "shift"].contains(&m.as_str()))
        })
    {
        settings.input.keybindings.clear();
        settings.input.set_shortcuts(&shortcuts);
    }
    if let Some(Value::Array(values)) = map.get("customAIDetectionRules") {
        let parsed: Option<Vec<_>> = values
            .iter()
            .map(|v| {
                Some(crate::settings::CustomAiRule {
                    id: v.get("id")?.as_str()?.into(),
                    pattern: v.get("pattern")?.as_str()?.into(),
                    display_name: v.get("displayName")?.as_str()?.into(),
                    color_name: v.get("colorName")?.as_str()?.into(),
                })
            })
            .collect();
        if let Some(rules) = parsed {
            settings.ai.custom_rules = rules;
        }
    }
    if let Some(value) = map.get("customColorScheme") {
        if value.is_null() {
            settings.appearance.custom_color_scheme = None;
        } else if value.is_object() {
            settings.appearance.custom_color_scheme = Some(value.to_string());
        }
        settings.appearance.color_scheme = chau7_next_core::color_schemes::ColorScheme::resolve(
            settings.appearance.color_scheme.name,
            settings.appearance.custom_color_scheme.as_deref(),
        );
    }
    let rules = &mut settings.notifications.rules;
    if let Some(state) = map
        .get("notificationTriggerState")
        .cloned()
        .and_then(|v| serde_json::from_value(v).ok())
    {
        rules.trigger_state = state;
        rules.trigger_state.normalize();
    } else if let Some(filters) = map.get("notificationFilters").and_then(Value::as_object) {
        for trigger in triggers::all() {
            let key = match trigger.trigger_type.as_str() {
                "finished" => "taskFinished",
                "failed" => "taskFailed",
                "waiting_input" | "attention_required" | "permission" => "permissionRequest",
                "needs_validation" => "needsValidation",
                "tool_complete" => "toolComplete",
                "session_end" => "sessionEnd",
                "idle" => "commandIdle",
                _ => continue,
            };
            if let Some(enabled) = filters.get(key).and_then(Value::as_bool) {
                rules.trigger_state.set_enabled(enabled, trigger);
            }
        }
    }
    macro_rules! rule_field {
        ($key:literal, $field:ident) => {
            if let Some(value) = map
                .get($key)
                .cloned()
                .and_then(|v| serde_json::from_value(v).ok())
            {
                rules.$field = value;
            }
        };
    }
    rule_field!("triggerActionBindings", trigger_action_bindings);
    rule_field!("notificationRateLimitConfig", rate_limit_config);
    rule_field!("triggerConditions", trigger_conditions);
    rule_field!("groupActionBindings", group_action_bindings);
    rule_field!("groupConditions", group_conditions);
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::settings::export::{export_json, import_json};
    const HOME: &str = "/owned/home";
    fn document(settings: &Settings) -> Map<String, Value> {
        serde_json::from_str(&export_json(settings, HOME)).unwrap()
    }

    #[test]
    fn every_shared_boolean_exports_actual_value_and_imports_without_next_extension() {
        let mut source = Settings::default();
        macro_rules! flip {
            ($key:literal, $field:expr) => {
                $field = !$field;
            };
        }
        bool_fields!(source, flip);
        source.productivity.default_editor = "code --wait".into();
        source.productivity.repo_snippet_path = ".project/snippets".into();
        source.appearance.display.timestamp_format = "HH:mm".into();
        let mut map = document(&source);
        macro_rules! check_export {
            ($key:literal, $field:expr) => {
                assert_eq!(map[$key], json!($field), "{}", $key);
            };
        }
        bool_fields!(source, check_export);
        string_fields!(source, check_export);
        map.remove(NEXT_KEY);
        let mut restored = Settings::default();
        import_json(&mut restored, &serde_json::to_string(&map).unwrap(), HOME).unwrap();
        macro_rules! check_import {
            ($key:literal, $field:expr) => {
                assert_eq!(json!($field), map[$key], "{}", $key);
            };
        }
        bool_fields!(restored, check_import);
        string_fields!(restored, check_import);
    }

    #[test]
    fn next_extension_preserves_all_domain_preferences_absent_from_swift() {
        let mut source = Settings::default();
        source.general.usage_monitoring = false;
        source.general.telemetry_retention_days = 91;
        source.appearance.graphics.kitty_cache_limit_mb = 256;
        source.appearance.rendering.suspend_delay_secs = 12.0;
        source.tabs.repo_grouping = crate::settings::RepoGroupingMode::Auto;
        source.hover_card.show_footer = false;
        source.minimal_mode = crate::settings::MinimalModeSettings::default();
        source.input.local_echo = true;
        source.input.keybindings = vec![("cmd+shift+q".into(), "newTab".into())];
        source.productivity.clipboard_history_enabled = false;
        source.productivity.clipboard_history_max = 71;
        source.dangerous_commands.guard_enabled = false;
        source.notifications.monitor_ai_events = false;
        source.ai.llm_endpoint = "http://localhost:1234".into();
        source.history.max_records = 30000;
        source.mcp.max_tabs = 9;
        source.remote.relay_url = "wss://owned.invalid/connect".into();
        source.proxy.port = 18092;
        source.cto.mode = chau7_next_core::token_optimization::TokenOptimizationMode::AiOnly;
        // Use the same canonical domain loader as disk/profile persistence.
        let source = Settings::from_profile_text(&source.to_profile_text());
        let mut actual = Settings::default();
        import_json(&mut actual, &export_json(&source, HOME), HOME).unwrap();
        assert_eq!(actual, source);
        assert_eq!(actual.to_profile_text(), source.to_profile_text());
    }

    #[test]
    fn portable_settings_exclude_contact_and_preserve_local_report_details() {
        let mut source = Settings::default();
        source.general.restore_bug_report_fields((
            "Export contact".into(),
            "export-contact@example.invalid".into(),
            "https://export-contact.invalid/private".into(),
        ));
        source.appearance.font_size = 21.0;
        let encoded = export_json(&source, HOME);
        assert!(!encoded.contains("Export contact"));
        assert!(!encoded.contains("export-contact"));
        let mut actual = Settings::default();
        let local = (
            "Local contact".into(),
            "local-contact@example.invalid".into(),
            "https://local-contact.invalid/private".into(),
        );
        actual.general.restore_bug_report_fields(local.clone());
        import_json(&mut actual, &encoded, HOME).unwrap();
        assert_eq!(actual.general.remembered_bug_report_fields(), local);
        assert_eq!(actual.appearance.font_size, 21.0);
        // Older version-one documents may still contain contact fields.
        let mut old = document(&source);
        old[NEXT_KEY]["config"] = json!(source.to_profile_text());
        import_json(&mut actual, &serde_json::to_string(&old).unwrap(), HOME).unwrap();
        assert_eq!(actual.general.remembered_bug_report_fields(), local);
    }

    #[test]
    fn version_and_extension_failures_leave_settings_unchanged() {
        let mut actual = Settings::default();
        actual.appearance.font_size = 19.0;
        let before = actual.clone();
        for patch in [
            json!({"exportVersion":2}),
            json!({"exportVersion":"1"}),
            json!({"chau7Next":{"version":2,"config":"[next]"}}),
            json!({"chau7Next":{"version":1,"config":false}}),
        ] {
            let mut map = document(&Settings::default());
            map.extend(patch.as_object().unwrap().clone());
            assert!(import_json(&mut actual, &serde_json::to_string(&map).unwrap(), HOME).is_err());
            assert_eq!(actual, before);
        }
    }

    #[test]
    fn current_notification_state_actions_conditions_and_legacy_filters_round_trip() {
        let mut source = Settings::default();
        let finished = triggers::all()
            .iter()
            .find(|t| t.id == "claude_code.finished")
            .unwrap();
        source
            .notifications
            .rules
            .trigger_state
            .set_enabled(false, finished);
        source.notifications.rules.trigger_conditions.insert(
            finished.id.clone(),
            triggers::TriggerCondition {
                only_when_unfocused: true,
                only_when_tab_inactive: true,
                respect_dnd: false,
            },
        );
        source.notifications.rules.rate_limit_config.max_per_minute = 7;
        let mut map = document(&source);
        map.remove(NEXT_KEY);
        let mut actual = Settings::default();
        import_json(&mut actual, &serde_json::to_string(&map).unwrap(), HOME).unwrap();
        assert_eq!(actual.notifications.rules, source.notifications.rules);
        let legacy = json!({"fontFamily":"SF Mono","notificationFilters":{"taskFinished":false,"permissionRequest":false}});
        import_json(&mut actual, &legacy.to_string(), HOME).unwrap();
        assert!(
            !actual
                .notifications
                .rules
                .trigger_state
                .is_enabled(finished)
        );
        assert!(
            triggers::all()
                .iter()
                .filter(|t| ["waiting_input", "attention_required", "permission"]
                    .contains(&t.trigger_type.as_str()))
                .all(|t| !actual.notifications.rules.trigger_state.is_enabled(t))
        );
    }

    #[test]
    fn custom_shortcuts_and_ai_rules_import_actual_current_swift_shape() {
        let mut source = Settings::default();
        source.input.keybindings = vec![("cmd+shift+q".into(), "newTab".into())];
        source.ai.custom_rules.push(crate::settings::CustomAiRule {
            id: "owned-rule".into(),
            pattern: "my-agent".into(),
            display_name: "Agent".into(),
            color_name: "blue".into(),
        });
        let mut map = document(&source);
        map.remove(NEXT_KEY);
        let mut actual = Settings::default();
        import_json(&mut actual, &serde_json::to_string(&map).unwrap(), HOME).unwrap();
        let expected = source.input.shortcuts();
        let actual_shortcuts = actual.input.shortcuts();
        assert_eq!(actual_shortcuts.len(), expected.len());
        for (actual, expected) in actual_shortcuts.iter().zip(&expected) {
            assert_eq!(actual.action, expected.action);
            assert!(actual.same_keys(expected));
        }
        assert_eq!(actual.ai.custom_rules, source.ai.custom_rules);
        let before = actual.input.clone();
        import_json(&mut actual, &json!({"fontFamily":"SF Mono","customShortcuts":[{"action":"newTab","key":"q","modifiers":["bogus"]}]}).to_string(), HOME).unwrap();
        assert_eq!(actual.input, before);
    }
}
