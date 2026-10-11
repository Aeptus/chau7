//! Port of `apps/chau7-macos/Sources/Chau7Core/AIToolRegistry.swift`.
//!
//! The tool table itself ([`AI_TOOLS`], one [`AiToolEntry`] per Swift
//! `AIToolDefinition`) lives in `command_detection.rs` so there is a single
//! table; this module adds the derived lookup tables and queries of
//! `AIToolRegistry`. The command name map and the output pattern list are
//! `command_detection::APP_NAME_MAP` and
//! `command_detection::OUTPUT_DETECTION_PATTERNS`.

use std::collections::HashMap;
use std::sync::LazyLock;

pub use crate::command_detection::{AI_TOOLS, AiToolEntry, ResumeFormat};
pub use crate::command_detection::{
    APP_NAME_MAP as COMMAND_NAME_MAP, OUTPUT_DETECTION_PATTERNS as OUTPUT_PATTERN_LIST,
};

/// All name variants to tab color name, for auto-theming. Keys include the
/// display name (lowercased), command names and provider keys
/// (`AIToolRegistry.tabColorMap`).
pub static TAB_COLOR_MAP: LazyLock<HashMap<String, &'static str>> = LazyLock::new(|| {
    let mut map = HashMap::new();
    for tool in AI_TOOLS {
        let Some(color) = tool.tab_color_name else {
            continue;
        };
        map.insert(tool.display_name.to_lowercase(), color);
        for cmd in tool.command_names {
            map.insert((*cmd).to_string(), color);
        }
        if let Some(key) = tool.resume_provider_key {
            map.insert(key.to_string(), color);
        }
    }
    map
});

/// Returns the resume provider key for a display name or provider string.
/// Uses substring matching to mirror the original `normalizeProviderName`
/// semantics (for example "Claude Code" contains "claude" and returns
/// "claude") (`AIToolRegistry.resumeProviderKey(for:)`).
pub fn resume_provider_key_for(name: &str) -> Option<&'static str> {
    let lowered = name.to_lowercase();
    for tool in AI_TOOLS {
        let Some(key) = tool.resume_provider_key else {
            continue;
        };
        if lowered.contains(&tool.display_name.to_lowercase()) || lowered == key {
            return Some(key);
        }
    }
    None
}

/// Finds the tool definition by display name, case-insensitive
/// (`AIToolRegistry.tool(named:)`).
pub fn tool_named(display_name: &str) -> Option<&'static AiToolEntry> {
    let lowered = display_name.to_lowercase();
    AI_TOOLS
        .iter()
        .find(|tool| tool.display_name.to_lowercase() == lowered)
}

/// Returns the logo asset name for an app name, or `None` if no logo exists
/// (`AIToolRegistry.logoAssetName(forAppName:)`).
pub fn logo_asset_name_for_app_name(app_name: &str) -> Option<&'static str> {
    tool_named(app_name)?.logo_asset_name
}

/// Returns the `AIEventSource` raw value for a tool name, checking display
/// name, command names and provider key
/// (`AIToolRegistry.eventSourceRawValue(for:)`).
pub fn event_source_raw_value_for(name: &str) -> Option<&'static str> {
    let lowered = name.to_lowercase();
    for tool in AI_TOOLS {
        let Some(source) = tool.event_source_raw_value else {
            continue;
        };
        if tool.display_name.to_lowercase() == lowered {
            return Some(source);
        }
        if tool.command_names.contains(&lowered.as_str()) {
            return Some(source);
        }
        if tool.resume_provider_key == Some(lowered.as_str()) {
            return Some(source);
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn resume_provider_key_uses_substring_matching() {
        assert_eq!(resume_provider_key_for("Claude Code"), Some("claude"));
        assert_eq!(resume_provider_key_for("codex"), Some("codex"));
        assert_eq!(resume_provider_key_for("Gemini"), None);
        assert_eq!(resume_provider_key_for("vim"), None);
    }

    #[test]
    fn tool_named_is_case_insensitive() {
        assert_eq!(tool_named("cLaUdE").map(|t| t.display_name), Some("Claude"));
        assert_eq!(
            tool_named("amazon q").map(|t| t.display_name),
            Some("Amazon Q")
        );
        assert!(tool_named("nonexistent").is_none());
    }

    #[test]
    fn logo_asset_names() {
        assert_eq!(logo_asset_name_for_app_name("Claude"), Some("claude-logo"));
        assert_eq!(logo_asset_name_for_app_name("Windsurf"), None);
        assert_eq!(logo_asset_name_for_app_name("nope"), None);
    }

    #[test]
    fn event_source_matches_display_name_command_and_provider_key() {
        assert_eq!(event_source_raw_value_for("Claude"), Some("claude_code"));
        assert_eq!(
            event_source_raw_value_for("claude-code"),
            Some("claude_code")
        );
        assert_eq!(event_source_raw_value_for("codex"), Some("codex"));
        assert_eq!(event_source_raw_value_for("continue"), Some("continue_ai"));
        assert_eq!(event_source_raw_value_for("gemini"), None);
        assert_eq!(event_source_raw_value_for("unknown"), None);
    }

    #[test]
    fn tab_color_map_includes_names_commands_and_provider_keys() {
        assert_eq!(TAB_COLOR_MAP.get("claude"), Some(&"purple"));
        assert_eq!(TAB_COLOR_MAP.get("claude-code"), Some(&"purple"));
        assert_eq!(TAB_COLOR_MAP.get("amazon q"), None);
        assert_eq!(TAB_COLOR_MAP.get("cursor"), Some(&"teal"));
        // Tools without a color are absent.
        assert_eq!(TAB_COLOR_MAP.get("cline"), None);
    }

    #[test]
    fn resume_format_builds_commands() {
        let claude = tool_named("Claude").unwrap().resume_format.unwrap();
        assert_eq!(claude.build_command("abc"), "claude --resume abc");
        let codex = tool_named("Codex").unwrap().resume_format.unwrap();
        assert_eq!(codex.build_command("abc"), "codex resume abc");
        assert!(tool_named("Gemini").unwrap().resume_format.is_none());
    }

    #[test]
    fn derived_tables_match_registry() {
        assert_eq!(COMMAND_NAME_MAP.get("claude-code").copied(), Some("Claude"));
        assert_eq!(OUTPUT_PATTERN_LIST.first().map(|(_, n)| *n), Some("Claude"));
    }
}
