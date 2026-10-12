//! Current Swift per-page status summaries. Values are read from typed settings
//! and already-held service snapshots; rendering performs no filesystem work.
use super::{SectionContext, SettingsSection, anchors};
use chau7_next_core::l10n::{Arg, l, lf};
use gpui::{Role, SharedString, div, prelude::*, px};
use unicode_segmentation::UnicodeSegmentation;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Tone {
    Enabled,
    Disabled,
    Neutral,
    Warning,
}
struct Count {
    raw: usize,
    text: String,
}
impl std::fmt::Display for Count {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        self.text.fmt(f)
    }
}
struct Card {
    id: &'static str,
    label: String,
    value: String,
    detail: Option<String>,
    tone: Tone,
}
impl Card {
    fn value(id: &'static str, key: &str, fallback: &str, value: String) -> Self {
        #[cfg(test)]
        assert!(
            chau7_next_core::l10n::table(chau7_next_core::l10n::Lang::En).contains_key(key),
            "summary card label lacks declared English key: {key}"
        );
        Self {
            id,
            label: l(key, fallback),
            value,
            detail: None,
            tone: Tone::Neutral,
        }
    }
    fn quantity(id: &'static str, key: &str, fallback: &str, count: Count) -> Self {
        let mut card = Self::value(id, key, fallback, count.text);
        if count.raw == 0 {
            card.tone = Tone::Disabled;
        }
        card
    }
    fn observed_flag(id: &'static str, key: &str, fallback: &str, value: Option<bool>) -> Self {
        value
            .map(|enabled| Self::flag(id, key, fallback, enabled))
            .unwrap_or_else(|| Self::unknown(id, key, fallback))
    }
    fn observed_count(id: &'static str, key: &str, fallback: &str, value: Option<Count>) -> Self {
        value
            .map(|count| Self::quantity(id, key, fallback, count))
            .unwrap_or_else(|| Self::unknown(id, key, fallback))
    }
    fn unknown(id: &'static str, key: &str, fallback: &str) -> Self {
        let mut card = Self::value(id, key, fallback, l("status.unknown", "Unknown"));
        card.tone = Tone::Warning;
        card
    }
    fn flag(id: &'static str, key: &str, fallback: &str, enabled: bool) -> Self {
        let mut card = Self::value(
            id,
            key,
            fallback,
            if enabled {
                l("status.enabled", "Enabled")
            } else {
                l("status.disabled", "Disabled")
            },
        );
        card.tone = if enabled {
            Tone::Enabled
        } else {
            Tone::Disabled
        };
        card
    }
    fn configured(id: &'static str, key: &str, fallback: &str, configured: bool) -> Self {
        let mut card = Self::flag(id, key, fallback, configured);
        card.value = if configured {
            l("status.configured", "Configured")
        } else {
            l("status.unconfigured", "Unconfigured")
        };
        card
    }
    fn hidden(id: &'static str, key: &str, fallback: &str, hidden: bool) -> Self {
        let mut card = Self::flag(id, key, fallback, hidden);
        card.value = if hidden {
            l("status.hidden", "Hidden")
        } else {
            l("status.visible", "Visible")
        };
        card
    }
    fn observed_active(id: &'static str, key: &str, fallback: &str, value: Option<bool>) -> Self {
        value
            .map(|active| Self::active(id, key, fallback, active))
            .unwrap_or_else(|| Self::value(id, key, fallback, l("misc.loading", "Loading...")))
    }
    fn active(id: &'static str, key: &str, fallback: &str, active: bool) -> Self {
        let mut card = Self::flag(id, key, fallback, active);
        card.value = if active {
            l("status.active", "Active")
        } else {
            l("status.paused", "Paused")
        };
        card
    }
}
fn compact_path(path: &str, home: &str) -> String {
    let trimmed = path.trim();
    if trimmed.is_empty() {
        return l("status.unconfigured", "Unconfigured");
    }
    let abbreviated = trimmed.replace(home, "~");
    if abbreviated.graphemes(true).count() <= 42 {
        return abbreviated;
    }
    let tail: Vec<_> = abbreviated.graphemes(true).rev().take(39).collect();
    format!("...{}", tail.into_iter().rev().collect::<String>())
}
fn history_summary_budget(stored: usize) -> usize {
    use chau7_next_core::history_store::{DEFAULT_MAX_RECORDS, MAX_MAX_RECORDS, MIN_MAX_RECORDS};
    (if stored == 0 {
        DEFAULT_MAX_RECORDS
    } else {
        stored
    })
    .clamp(MIN_MAX_RECORDS, MAX_MAX_RECORDS)
}
fn shell_name(s: &crate::settings::Settings, compact: &impl Fn(&str) -> String) -> String {
    use chau7_next_core::shell_env::ShellType;
    let (shell, custom) = s.terminal.effective_shell_type();
    match shell {
        ShellType::Custom => compact(&custom),
        other => crate::l10n::tr(other.display_name()),
    }
}
fn ssh_sync(stamp: Option<chrono::NaiveDateTime>) -> String {
    stamp
        .map(|date| {
            chau7_next_core::l10n::formatters::date_time(chau7_next_core::l10n::current(), date)
        })
        .unwrap_or_else(|| l("status.never", "Never"))
}
fn items(section: SettingsSection, ctx: &SectionContext) -> Vec<Card> {
    let s = ctx.settings;
    let profiles = &ctx.view.mine.profiles.store;
    let profile = profiles
        .active_profile()
        .filter(|p| !(p.name == "Default" && p.icon == "house.fill"))
        .map(|p| p.name.clone())
        .unwrap_or_else(|| l("settings.profileBar.defaultSettings", "Default Settings"));
    let compact = |path: &str| compact_path(path, &ctx.home);
    let count = |value: usize| Count {
        raw: value,
        text: ctx.view.pane_inputs.format_summary_count(value),
    };
    let default_directory = compact(
        s.general
            .default_directory
            .as_deref()
            .filter(|p| !p.is_empty())
            .unwrap_or("~"),
    );
    let remote_running = ctx
        .remote
        .as_ref()
        .is_some_and(|remote| remote.agent_running);
    let remote_value = if !s.remote.enabled {
        l("status.disabled", "Disabled")
    } else if remote_running {
        l("status.running", "Running")
    } else {
        l("status.stopped", "Stopped")
    };
    let proxy_value = if !s.proxy.enabled {
        l("status.disabled", "Disabled")
    } else {
        match ctx.proxy_status.as_ref() {
            Some(crate::proxy::ProxyStatus::Running(_)) => l("status.running", "Running"),
            Some(crate::proxy::ProxyStatus::Error(_)) => l("status.error", "Error"),
            _ => l("status.starting", "Starting..."),
        }
    };
    let indicators = [
        s.tabs.show_icons,
        s.tabs.show_path,
        s.tabs.show_git_indicator,
        s.tabs.allow_cto_toggle,
        s.tabs.show_broadcast_indicator,
        s.tabs.last_command_badge,
    ]
    .into_iter()
    .filter(|v| *v)
    .count();
    let h = &s.hover_card;
    let hover_count = [
        h.show_directory,
        h.show_git_branch,
        h.show_last_command,
        h.show_dev_server,
        h.show_ai_session,
        h.show_repo_stats,
        h.show_conflicts,
        h.show_notification_state,
        h.show_processes,
        h.show_token_optimization,
        h.show_shell_integration,
        h.show_broadcast,
        h.show_footer,
    ]
    .into_iter()
    .filter(|v| *v)
    .count();
    let injection = ctx.view.injection.summary_counts();
    let mut cards = match section {
        SettingsSection::StartHere => vec![
            Card::value(
                "profile",
                "settings.startHere.activeProfile",
                "Active Profile",
                profile.clone(),
            ),
            Card::flag(
                "agentControl",
                "settings.mcpControl",
                "Agent Control",
                s.mcp.enabled,
            ),
            Card::value(
                "remote",
                "settings.remoteControl",
                "Remote Access",
                remote_value.clone(),
            ),
            Card::value(
                "alerts",
                "settings.notifications",
                "Alerts",
                ctx.monitoring.notifications.clone(),
            ),
        ],
        SettingsSection::General => vec![
            Card::flag(
                "startup",
                "settings.general.launchAtLogin",
                "Launch at Login",
                s.general.launch_at_login,
            ),
            Card::value(
                "language",
                "settings.general.language",
                "Language",
                crate::l10n::tr(s.general.app_language.display_name()),
            ),
            Card::flag(
                "configFile",
                "settings.configFile.title",
                "Config File",
                s.general.load_config_files,
            ),
            Card::value(
                "defaultDirectory",
                "settings.general.defaultDirectory",
                "Default Directory",
                default_directory.clone(),
            ),
        ],
        SettingsSection::ProfilesBackup => vec![
            Card::value(
                "profile",
                "settings.startHere.activeProfile",
                "Active Profile",
                profile.clone(),
            ),
            Card::quantity(
                "profiles",
                "settings.profileBar.profiles",
                "Profiles",
                count(profiles.profiles.len()),
            ),
            Card::flag(
                "icloud",
                "settings.general.icloudSync",
                "iCloud Sync",
                s.general.icloud_sync,
            ),
            Card::flag(
                "profileAutoSwitch",
                "Profile Auto-Switching",
                "Profile Auto-Switching",
                profiles.auto_switch,
            ),
        ],
        SettingsSection::About => vec![
            Card::value(
                "version",
                "settings.about.version",
                "Version",
                crate::platform::system::bundle_string("CFBundleShortVersionString")
                    .unwrap_or_else(|| l("settings.about.developmentVersion", "Development")),
            ),
            Card::value(
                "support",
                "settings.about.support",
                "Support",
                l("status.available", "Available"),
            ),
            Card::value(
                "logs",
                "settings.about.logPath",
                "Log Path",
                compact(&ctx.root.log_file().to_string_lossy()),
            ),
            Card::value(
                "diagnostics",
                "settings.logsHistory",
                "Diagnostics",
                l("status.available", "Available"),
            ),
        ],
        SettingsSection::FontColors => vec![
            Card::value(
                "font",
                "settings.appearance.fontFamily",
                "Font Family",
                s.appearance.font_family.clone(),
            ),
            Card::value(
                "size",
                "settings.appearance.fontSize",
                "Font Size",
                format!("{} pt", s.appearance.font_size),
            ),
            Card::value(
                "scheme",
                "settings.appearance.scheme",
                "Scheme",
                s.appearance.color_scheme.name.to_owned(),
            ),
            Card::value(
                "zoom",
                "settings.appearance.defaultZoom",
                "Default Zoom",
                format!("{}%", s.appearance.default_zoom_percent),
            ),
        ],
        SettingsSection::Display => vec![
            Card::flag(
                "syntax",
                "settings.appearance.syntaxHighlighting",
                "Syntax Highlighting",
                s.appearance.display.syntax_highlight,
            ),
            Card::flag(
                "urls",
                "settings.appearance.clickableURLs",
                "Clickable URLs",
                s.appearance.display.clickable_urls,
            ),
            Card::flag(
                "images",
                "settings.appearance.inlineImages",
                "Inline Images",
                s.appearance.display.inline_images,
            ),
            Card::flag(
                "json",
                "settings.appearance.prettyPrintJSON",
                "Pretty Print JSON",
                s.appearance.display.json_pretty_print,
            ),
        ],
        SettingsSection::Windows => vec![
            Card::value(
                "theme",
                "settings.appearance.appearance",
                "Appearance",
                crate::l10n::tr(s.appearance.app_theme.label()),
            ),
            Card::value(
                "opacity",
                "settings.appearance.windowOpacity",
                "Window Opacity",
                format!("{}%", (s.appearance.opacity * 100.0) as u32),
            ),
            Card::flag(
                "blur",
                "settings.windows.windowBlur",
                "Window Blur",
                s.appearance.window_blur_enabled,
            ),
            Card::flag(
                "floating",
                "settings.windows.floatingWindow",
                "Keep Windows Above Other Apps",
                s.appearance.window_floating,
            ),
            Card::flag(
                "splitPanes",
                "settings.windows.splitPanes",
                "Split Panes",
                s.terminal.split_panes_enabled,
            ),
        ],
        SettingsSection::Tabs => vec![
            Card::value(
                "newTabPosition",
                "settings.tabs.newTabPosition",
                "New Tab Position",
                crate::l10n::tr(
                    if s.tabs.new_tab_position
                        == chau7_next_core::tabs_state::NewTabPosition::AfterCurrent
                    {
                        "After Current"
                    } else {
                        "At End"
                    },
                ),
            ),
            Card::flag(
                "idleGrouping",
                "settings.tabs.groupIdleTabs",
                "Group Idle Tabs in Dropdown",
                s.tabs.group_idle_tabs,
            ),
            Card::value(
                "indicators",
                "settings.tabs.display",
                "Tab Display",
                lf(
                    "settings.tabs.indicators.count",
                    "%d visible",
                    &[Arg::from(indicators)],
                ),
            ),
            Card::flag(
                "closeWarnings",
                "settings.tabs.warnOnCloseWithProcess",
                "Warn When Closing Tab with Running Process",
                s.tabs.warn_on_close_running || s.tabs.confirm_close,
            ),
        ],
        SettingsSection::HoverCard => vec![
            Card::value(
                "visible",
                "settings.hoverCard.sections",
                "Visible Sections",
                format!("{}/13", count(hover_count)),
            ),
            Card::flag(
                "aiSession",
                "settings.hover.aiSession",
                "AI Session",
                s.hover_card.show_ai_session,
            ),
            Card::flag(
                "processes",
                "settings.hover.processes",
                "Processes",
                s.hover_card.show_processes,
            ),
            Card::flag(
                "footer",
                "settings.hover.footer",
                "Footer",
                s.hover_card.show_footer,
            ),
        ],
        SettingsSection::Repositories => vec![
            Card::value(
                "grouping",
                "settings.tabs.repoGrouping",
                "Repo Grouping",
                crate::l10n::tr(s.tabs.repo_grouping.label()),
            ),
            Card::flag(
                "search",
                "settings.repositories.semanticSearch",
                "Semantic Search",
                s.productivity.semantic_search,
            ),
            Card::observed_count(
                "recent",
                "settings.repositories.recent",
                "Recent Repos",
                ctx.recent_repo_roots
                    .as_ref()
                    .map(|roots| count(roots.len())),
            ),
            Card::value(
                "defaultDirectory",
                "settings.general.defaultDirectory",
                "Default Directory",
                default_directory.clone(),
            ),
        ],
        SettingsSection::Shell => vec![
            Card::value(
                "shell",
                "settings.terminal.shell",
                "Shell",
                shell_name(s, &compact),
            ),
            Card::configured(
                "startup",
                "settings.terminal.startupCommand",
                "Startup Command",
                !s.terminal.startup_command.trim().is_empty(),
            ),
            Card::flag(
                "lsColors",
                "settings.terminal.lsColors",
                "ls Colors",
                s.terminal.ls_colors,
            ),
            Card::flag(
                "bell",
                "settings.terminal.bell",
                "Bell",
                s.terminal.bell_enabled,
            ),
        ],
        SettingsSection::ScrollbackPerf => vec![
            Card::quantity(
                "scrollback",
                "settings.terminal.scrollback",
                "Scrollback",
                count(s.terminal.scrollback_lines),
            ),
            Card::quantity(
                "restored",
                "settings.performance.restoredScrollback",
                "Restored Lines",
                count(s.terminal.restored_scrollback_lines),
            ),
            Card::value(
                "renderer",
                "settings.performance.renderer",
                "Renderer",
                if s.appearance.rendering.gpu_renderer {
                    "Metal".to_owned()
                } else {
                    "CPU".to_owned()
                },
            ),
            Card::value(
                "refresh",
                "settings.performance.activeRefresh",
                "Active Refresh",
                crate::l10n::tr(&s.appearance.rendering.active_polling_rate_cap.label()),
            ),
        ],
        SettingsSection::DangerousCommands => vec![
            Card::flag(
                "protectChau7",
                "settings.dangerous.protectChau7",
                "Protect Chau7",
                s.dangerous_commands.protect_chau7_enabled,
            ),
            Card::value(
                "scope",
                "settings.dangerous.highlightScope",
                "Highlight Scope",
                crate::l10n::tr(s.dangerous_commands.scope.label()),
            ),
            Card::quantity(
                "patterns",
                "settings.dangerous.patterns",
                "Patterns",
                count(s.dangerous_commands.patterns.len()),
            ),
            Card::flag(
                "lowPower",
                "settings.dangerous.lowPower",
                "Low Power",
                s.dangerous_commands.highlight_low_power,
            ),
        ],
        SettingsSection::Graphics => vec![
            Card::flag(
                "sixel",
                "settings.graphics.sixel",
                "Sixel",
                s.appearance.graphics.sixel,
            ),
            Card::flag(
                "kitty",
                "settings.graphics.kitty",
                "Kitty Graphics",
                s.appearance.graphics.kitty,
            ),
            Card::flag(
                "inlineImages",
                "settings.appearance.inlineImages",
                "Inline Images",
                s.appearance.display.inline_images,
            ),
            Card::value(
                "cache",
                "settings.graphics.cache",
                "Cache",
                format!("{} MB", s.appearance.graphics.kitty_cache_limit_mb),
            ),
        ],
        SettingsSection::KeyboardMouse => vec![
            Card::flag(
                "shortcutHelper",
                "settings.shortcuts.helper",
                "Shortcut Helper",
                s.input.shortcut_helper_hint,
            ),
            Card::flag(
                "copyOnSelect",
                "settings.input.copyOnSelect",
                "Copy on Select",
                s.input.copy_on_select,
            ),
            Card::flag(
                "cmdClick",
                "settings.input.cmdClickPaths",
                "Cmd-Click Paths",
                s.productivity.cmd_click_paths,
            ),
            Card::flag(
                "mouseReporting",
                "settings.input.mouseReporting",
                "Mouse Reporting",
                s.input.mouse_reporting,
            ),
        ],
        SettingsSection::SnippetsTools => vec![
            Card::flag(
                "snippets",
                "settings.snippetsTools.snippets",
                "Snippets",
                s.productivity.snippets_enabled,
            ),
            Card::flag(
                "repoSnippets",
                "settings.snippetsTools.repoSnippets",
                "Repo Snippets",
                s.productivity.repo_snippets_enabled,
            ),
            Card::flag(
                "clipboard",
                "settings.snippetsTools.clipboardHistory",
                "Clipboard History",
                s.productivity.clipboard_history_enabled,
            ),
            Card::flag(
                "bookmarks",
                "settings.snippetsTools.bookmarks",
                "Bookmarks",
                s.productivity.bookmarks_enabled,
            ),
        ],
        SettingsSection::Editor => vec![
            Card::value(
                "editor",
                "settings.editor.defaultEditor",
                "Default Editor",
                s.productivity.default_editor.clone(),
            ),
            Card::flag(
                "internal",
                "settings.editor.internalEditor",
                "Internal Editor",
                s.productivity.cmd_click_internal_editor,
            ),
            Card::flag(
                "splitPanes",
                "settings.windows.splitPanes",
                "Split Panes",
                s.terminal.split_panes_enabled,
            ),
            Card::flag(
                "semanticSearch",
                "settings.repositories.semanticSearch",
                "Semantic Search",
                s.productivity.semantic_search,
            ),
        ],
        SettingsSection::MinimalMode => vec![
            Card::flag(
                "minimal",
                "settings.minimalMode",
                "Minimal Mode",
                s.minimal_mode.enabled,
            ),
            Card::hidden(
                "tabBar",
                "settings.minimal.hideTabBar",
                "Hide Tab Bar",
                s.minimal_mode.hide_tab_bar,
            ),
            Card::hidden(
                "titleBar",
                "settings.minimal.hideTitleBar",
                "Hide Title Bar",
                s.minimal_mode.hide_title_bar,
            ),
            Card::hidden(
                "statusBar",
                "settings.minimal.hideStatusBar",
                "Hide Status Bar",
                s.minimal_mode.hide_status_bar,
            ),
        ],
        SettingsSection::AiDetection => vec![
            Card::flag(
                "autoTheme",
                "settings.ai.autoTheme",
                "AI Tab Theme",
                s.tabs.auto_tab_theme,
            ),
            Card::quantity(
                "customRules",
                "settings.ai.customDetectionRules",
                "Custom Detection Rules",
                count(s.ai.custom_rules.len()),
            ),
            Card::flag(
                "errorExplain",
                "settings.ai.errorExplain",
                "Error Explanation",
                s.ai.error_explain_enabled,
            ),
            Card::flag(
                "usage",
                "settings.ai.usageMonitoring",
                "Usage Monitoring",
                s.general.usage_monitoring,
            ),
            Card::value(
                "numberFormat",
                "settings.ai.numberFormat",
                "Number Format",
                crate::l10n::tr(s.general.regional_number_format.display_name()),
            ),
        ],
        SettingsSection::TokenOptimization => vec![
            Card::value(
                "mode",
                "cto.settings.mode.label",
                "Mode",
                crate::l10n::tr(mode_label(s.cto.mode)),
            ),
            Card::flag(
                "prefix",
                "settings.ai.cto.enabled",
                "Enable Input Prefix",
                s.cto.prefix_enabled,
            ),
            Card::quantity(
                "overrides",
                "cto.settings.perTab",
                "Per-Tab Control",
                count(s.cto.tab_overrides.len()),
            ),
            Card::flag(
                "indicator",
                "settings.tabs.allowCTOToggle",
                "Allow Context Optimization Toggle in Hover Card",
                s.tabs.allow_cto_toggle,
            ),
        ],
        SettingsSection::McpControl => vec![
            Card::flag(
                "enabled",
                "settings.mcp.enable",
                "Enable Agent Control",
                s.mcp.enabled,
            ),
            Card::flag(
                "approval",
                "settings.mcp.approval",
                "Require Approval",
                s.mcp.requires_approval,
            ),
            Card::value(
                "mode",
                "settings.mcp.permissionMode",
                "Permission Mode",
                crate::l10n::tr(s.mcp.permission_mode.display_name()),
            ),
            Card::quantity(
                "profiles",
                "settings.mcp.profiles",
                "Agent Profiles",
                count(s.mcp.profiles.len()),
            ),
        ],
        SettingsSection::RemoteControl => vec![
            Card::flag(
                "enabled",
                "settings.remote.enable",
                "Enable Remote Access",
                s.remote.enabled,
            ),
            Card::value(
                "agent",
                "settings.remote.agent",
                "Remote Agent",
                if remote_running {
                    l("status.running", "Running")
                } else {
                    l("status.stopped", "Stopped")
                },
            ),
            Card::value(
                "relay",
                "settings.remote.relay",
                "Relay",
                compact(&s.remote.relay_url),
            ),
            Card::quantity(
                "devices",
                "settings.remote.devices",
                "Paired Devices",
                count(ctx.remote.as_ref().map_or(0, |remote| remote.devices.len())),
            ),
        ],
        SettingsSection::SshProfiles => vec![
            Card::observed_active(
                "watch",
                "settings.ssh.fileWatch",
                "File Watch",
                ctx.view.mine.profiles.ssh_watch_status(),
            ),
            Card::quantity(
                "configEntries",
                "settings.ssh.entries",
                "SSH Config Entries",
                count(ctx.view.mine.profiles.ssh_entries.len()),
            ),
            Card::quantity(
                "connections",
                "settings.ssh.connections",
                "Chau7 Connections",
                count(ctx.view.mine.profiles.ssh_saved),
            ),
            Card::value(
                "lastSync",
                "ssh.lastSync.short",
                "Last Sync",
                ssh_sync(ctx.view.mine.profiles.ssh_last_sync_local()),
            ),
        ],
        SettingsSection::ApiProxy => vec![
            Card::flag(
                "enabled",
                "settings.proxy.enable",
                "Enable API Analytics",
                s.proxy.enabled,
            ),
            Card::value(
                "status",
                "settings.proxy.status",
                "Status",
                proxy_value.clone(),
            ),
            Card::value(
                "port",
                "settings.proxy.port",
                "Port",
                s.proxy.port.to_string(),
            ),
            Card::flag(
                "privacy",
                "settings.proxy.logPrompts",
                "Log Prompt Previews",
                s.proxy.log_prompts,
            ),
        ],
        SettingsSection::PromptInjection => vec![
            Card::observed_flag(
                "global",
                "settings.injection.global",
                "All Repositories",
                injection.map(|value| value.0),
            ),
            Card::observed_count(
                "repoRules",
                "settings.injection.perRepo",
                "Per Repository",
                injection.map(|value| count(value.1)),
            ),
            Card::observed_count(
                "localRules",
                "settings.injection.localRules",
                "Repo-Local Rules",
                injection.map(|value| count(value.2)),
            ),
            Card::flag(
                "proxy",
                "settings.apiProxy",
                "API Tracking",
                s.proxy.enabled,
            ),
        ],
        SettingsSection::Notifications => vec![
            Card::value(
                "permission",
                "settings.productivity.permissions.notifications",
                "Notifications",
                ctx.monitoring.notifications.clone(),
            ),
            Card::quantity(
                "actions",
                "settings.notifications.actions",
                "Actions",
                count(
                    s.notifications
                        .rules
                        .trigger_action_bindings
                        .values()
                        .map(Vec::len)
                        .sum(),
                ),
            ),
            Card::quantity(
                "conditions",
                "settings.notifications.conditions",
                "Conditions",
                count(s.notifications.rules.trigger_conditions.len()),
            ),
            Card::value(
                "rateLimit",
                "settings.notifications.rateLimit",
                "Rate Limit",
                lf(
                    "settings.summary.rateLimit",
                    "%d/min, %ds cooldown",
                    &[
                        Arg::from(s.notifications.rules.rate_limit_config.max_per_minute),
                        Arg::from(s.notifications.rules.rate_limit_config.cooldown_seconds as i64),
                    ],
                ),
            ),
        ],
        SettingsSection::History => vec![
            Card::flag(
                "persistent",
                "settings.history.enable",
                "Enable Persistent History",
                s.history.persistent_history,
            ),
            Card::quantity(
                "maxRecords",
                "settings.history.maxRecords",
                "Maximum Records",
                count(history_summary_budget(s.history.max_records)),
            ),
            Card::value(
                "telemetry",
                "settings.logs.telemetry",
                "AI Telemetry & Transcripts",
                if s.general.telemetry_retention_days == 0 {
                    l("settings.logs.telemetryRetention.forever.short", "Forever")
                } else {
                    lf(
                        "settings.summary.days",
                        "%d days",
                        &[Arg::from(s.general.telemetry_retention_days)],
                    )
                },
            ),
            Card::value(
                "privacy",
                "settings.history.importExport",
                "Import / Export",
                l("status.available", "Available"),
            ),
        ],
        SettingsSection::LogsHistory => vec![
            Card::flag(
                "historyLogs",
                "settings.logs.monitorHistoryLogs",
                "Monitor History Logs",
                ctx.monitoring.history,
            ),
            Card::flag(
                "terminalLogs",
                "settings.logs.monitorTerminalLogs",
                "Monitor Terminal Logs",
                ctx.monitoring.terminal,
            ),
            Card::quantity(
                "sessions",
                "settings.logs.activeSessions",
                "Active Sessions",
                count(ctx.logs.sessions.len()),
            ),
            Card::value(
                "logPath",
                "settings.notifications.eventLogPath",
                "Event Log Path",
                compact(&ctx.root.ai_events_log().to_string_lossy()),
            ),
        ],
    };
    for card in &mut cards {
        match (section, card.id) {
            (SettingsSection::StartHere, "agentControl") if s.mcp.enabled => {
                card.detail = Some(lf(
                    "settings.startHere.mcp.detail",
                    "Max tabs: %d",
                    &[Arg::from(s.mcp.max_tabs)],
                ))
            }
            (SettingsSection::StartHere, "remote") => {
                card.tone = if !s.remote.enabled {
                    Tone::Disabled
                } else if remote_running {
                    Tone::Enabled
                } else {
                    Tone::Warning
                };
                if let Some(remote) = &ctx.remote {
                    card.detail = remote
                        .last_error
                        .clone()
                        .filter(|e| !e.is_empty())
                        .or_else(|| {
                            remote.devices.iter().find(|(_, connected)| *connected).map(
                                |(device, _)| {
                                    lf(
                                        "settings.remote.connectedDevice",
                                        "Connected device: %@",
                                        &[Arg::Str(device.name.clone())],
                                    )
                                },
                            )
                        })
                        .or_else(|| {
                            remote.session_status.clone().map(|status| {
                                lf("remote.sessionStatus", "Session: %@", &[Arg::Str(status)])
                            })
                        })
                        .or_else(|| s.remote.enabled.then(|| s.remote.relay_url.clone()));
                    if remote
                        .last_error
                        .as_ref()
                        .is_some_and(|error| !error.is_empty())
                    {
                        card.tone = Tone::Warning;
                    }
                }
            }
            (SettingsSection::StartHere, "alerts")
            | (SettingsSection::Notifications, "permission") => {
                card.detail = ctx.notification_warning.clone();
                card.tone = if card.detail.is_some() {
                    Tone::Warning
                } else {
                    Tone::Enabled
                };
            }
            (SettingsSection::ProfilesBackup, "profileAutoSwitch") => {
                card.detail = Some(lf(
                    "settings.profileAutoSwitch.rules.count",
                    "%d rules",
                    &[Arg::from(profiles.rules.len())],
                ))
            }
            (SettingsSection::About, "support") => {
                card.detail = Some(l(
                    "settings.about.support.detail",
                    "GitHub, issues, documentation",
                ))
            }
            (SettingsSection::Tabs, "idleGrouping") if s.tabs.group_idle_tabs => {
                card.detail = Some(format!("{} min", s.tabs.idle_threshold_minutes))
            }
            (SettingsSection::Shell, "bell") if s.terminal.bell_enabled => {
                card.detail = Some(crate::l10n::tr(s.terminal.bell_sound.label()))
            }
            (SettingsSection::DangerousCommands, "protectChau7") => {
                card.detail = Some(crate::l10n::tr(
                    s.dangerous_commands.protect_chau7_level.label(),
                ))
            }
            (SettingsSection::SnippetsTools, "clipboard")
                if s.productivity.clipboard_history_enabled =>
            {
                card.detail = Some(lf(
                    "settings.summary.items",
                    "%d items",
                    &[Arg::from(s.productivity.clipboard_history_max)],
                ))
            }
            (SettingsSection::AiDetection, "numberFormat") => {
                card.detail = Some(s.general.regional_number_format.example().to_owned())
            }
            (SettingsSection::TokenOptimization, "prefix") if s.cto.prefix_enabled => {
                card.detail = Some(s.cto.prefix.clone())
            }
            (SettingsSection::RemoteControl, "agent") => {
                card.detail = ctx
                    .remote
                    .as_ref()
                    .and_then(|remote| remote.last_error.clone());
                card.tone = if !s.remote.enabled {
                    Tone::Disabled
                } else if card.detail.as_ref().is_some_and(|error| !error.is_empty())
                    || !remote_running
                {
                    Tone::Warning
                } else {
                    Tone::Enabled
                };
            }
            (SettingsSection::RemoteControl, "relay") if s.remote.relay_url.trim().is_empty() => {
                card.tone = Tone::Warning
            }
            (SettingsSection::ApiProxy, "status") => {
                card.tone = if !s.proxy.enabled {
                    Tone::Disabled
                } else if matches!(
                    &ctx.proxy_status,
                    Some(crate::proxy::ProxyStatus::Running(_))
                ) {
                    Tone::Enabled
                } else {
                    Tone::Warning
                };
                if let Some(crate::proxy::ProxyStatus::Error(error)) = &ctx.proxy_status {
                    card.detail = Some(error.clone());
                }
            }
            (SettingsSection::ApiProxy, "privacy") => {
                card.tone = if s.proxy.log_prompts {
                    Tone::Warning
                } else {
                    Tone::Enabled
                }
            }
            (SettingsSection::PromptInjection, "proxy") => {
                card.detail = Some(l(
                    "settings.summary.proxyNeeded",
                    "Proxy applies AI context rules.",
                ))
            }
            (SettingsSection::SshProfiles, "lastSync")
                if ctx.view.mine.profiles.ssh_last_sync_local().is_none() =>
            {
                card.tone = Tone::Warning;
            }
            (SettingsSection::History, "telemetry") if s.general.telemetry_retention_days == 0 => {
                card.tone = Tone::Warning
            }
            _ => {}
        }
    }
    cards
}

fn mode_label(mode: chau7_next_core::token_optimization::TokenOptimizationMode) -> &'static str {
    use chau7_next_core::token_optimization::TokenOptimizationMode::*;
    match mode {
        Off => "Off",
        AllTabs => "All Commands",
        AiOnly => "AI Commands Only",
        Manual => "Manual (Per-Tab)",
    }
}

pub(super) fn section(ctx: &SectionContext) -> gpui::Div {
    let section = ctx.view.navigation.selection;
    let cards = items(section, ctx);
    #[cfg(any(test, feature = "native-parity-fixture"))]
    OBSERVED.with(|seen| {
        seen.borrow_mut().insert(
            section,
            cards
                .iter()
                .map(|card| (card.id, card.value.clone()))
                .collect(),
        );
    });
    let chrome = ctx.chrome;
    let grid = div()
        .id("settings-page-summary")
        .flex()
        .flex_wrap()
        .gap_3()
        .p_3()
        .rounded_md()
        .bg(chrome.tab_bg)
        .role(Role::Group)
        .aria_label(lf(
            "settings.summary.accessibility",
            "%@ summary",
            &[Arg::Str(crate::l10n::tr(section.title()))],
        ))
        .children(cards.into_iter().map(|card| {
            let color = match card.tone {
                Tone::Enabled => gpui::rgb(0x2ea043).into(),
                Tone::Disabled => chrome.text_muted,
                Tone::Neutral => chrome.accent,
                Tone::Warning => gpui::rgb(0xd97706).into(),
            };
            let icon = match card.id {
                "profile" | "profiles" => gpui_kit::assets::IconName::User,
                "shell" | "startup" | "terminalLogs" => gpui_kit::assets::IconName::Terminal,
                "defaultDirectory" | "recent" | "repoRules" => gpui_kit::assets::IconName::Folder,
                "alerts" | "permission" | "bell" => gpui_kit::assets::IconName::Bell,
                "language" | "global" | "remote" | "relay" => gpui_kit::assets::IconName::Globe,
                "privacy" | "protectChau7" | "approval" => gpui_kit::assets::IconName::Shield,
                "historyLogs" | "lastSync" | "persistent" | "restored" => {
                    gpui_kit::assets::IconName::Clock
                }
                _ => gpui_kit::assets::IconName::Settings,
            };
            let cell = div()
                .id(SharedString::from(format!(
                    "settings-summary-{}-{}",
                    section.id(),
                    card.id
                )))
                .flex()
                .items_start()
                .gap_2()
                .flex_1()
                .min_w(px(150.0))
                .role(Role::Group)
                .aria_label(lf(
                    "accessibility.labelValue",
                    "%@: %@",
                    &[Arg::Str(card.label.clone()), Arg::Str(card.value.clone())],
                ))
                .child(
                    gpui_kit::component::Icon::new(icon)
                        .size(px(14.))
                        .text_color(color),
                )
                .child(
                    div()
                        .flex()
                        .flex_col()
                        .gap_1()
                        .child(
                            div()
                                .text_xs()
                                .text_color(chrome.text_muted)
                                .child(card.label),
                        )
                        .child(
                            div()
                                .flex()
                                .items_center()
                                .gap_1()
                                .child(div().size(px(6.)).rounded_full().bg(color))
                                .child(
                                    div()
                                        .text_xs()
                                        .font_weight(gpui::FontWeight::SEMIBOLD)
                                        .text_color(color)
                                        .child(card.value),
                                ),
                        )
                        .when_some(card.detail, |cell, detail| {
                            cell.child(div().text_xs().text_color(chrome.text_muted).child(detail))
                        }),
                );
            #[cfg(any(test, feature = "native-parity-fixture"))]
            let cell = {
                use gpui_kit::test::TestSupportExt;
                cell.test_support()
            };
            cell
        }));
    anchors::target("pageSummary", grid).pb_3()
}
#[cfg(any(test, feature = "native-parity-fixture"))]
thread_local! {static OBSERVED:std::cell::RefCell<std::collections::HashMap<SettingsSection,Vec<(&'static str,String)>>> =std::cell::RefCell::new(Default::default());}
#[cfg(any(test, feature = "native-parity-fixture"))]
pub(super) fn observed(section: SettingsSection) -> Vec<(&'static str, String)> {
    OBSERVED.with(|seen| seen.borrow().get(&section).cloned().unwrap_or_default())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn source_compact_path_abbreviates_and_truncates_graphemes() {
        assert_eq!(compact_path(" /owned/home/repo ", "/owned/home"), "~/repo");
        assert_eq!(
            compact_path(" ", "/owned/home"),
            l("status.unconfigured", "Unconfigured")
        );
        assert_eq!(compact_path(&"é".repeat(42), "/owned/home"), "é".repeat(42));
        assert_eq!(
            compact_path(&"é".repeat(43), "/owned/home"),
            format!("...{}", "é".repeat(39))
        );
        let cluster = "👩🏽‍💻";
        assert_eq!(
            compact_path(&cluster.repeat(43), "/owned/home"),
            format!("...{}", cluster.repeat(39))
        );
        let swift = include_str!(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../../chau7-macos/Sources/Chau7/Settings/Views/SettingsPageSummaryView.swift"
        ));
        assert!(swift.contains("abbreviated.count > 42"));
        assert!(swift.contains("abbreviated.suffix(39)"));
    }
    #[test]
    fn summary_history_budget_keeps_current_swift_fallback_and_bounds() {
        assert_eq!(history_summary_budget(0), 50_000);
        assert_eq!(history_summary_budget(9_999), 10_000);
        assert_eq!(history_summary_budget(10_000), 10_000);
        assert_eq!(history_summary_budget(87_654), 87_654);
        assert_eq!(history_summary_budget(100_000), 100_000);
        assert_eq!(history_summary_budget(100_001), 100_000);
        assert_eq!(history_summary_budget(usize::MAX), 100_000);
        let swift = include_str!(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../../chau7-macos/Sources/Chau7/Settings/Views/SettingsPageSummaryView.swift"
        ));
        assert!(swift.contains("max(10000, min(stored > 0 ? stored : 50000, 100_000))"));
    }
}
