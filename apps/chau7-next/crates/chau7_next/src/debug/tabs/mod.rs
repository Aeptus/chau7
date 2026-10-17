//! The built-in tabs of the Debug Console, one file each. Every tab is a
//! method of `DebugConsole` that returns the page.

mod analytics;
mod cto;
mod events;
mod health;
mod lag;
mod logs;
mod perf;
mod report;
mod state;

use chau7_next_core::debug_console::composed_tab_label;
use chrono::{DateTime, Local, TimeZone, Utc};

use crate::workspace::TabDebugInfo;

/// `HH:mm:ss.SSS` of a UTC time in local time (`formatTime`).
pub(super) fn clock_text(time: DateTime<Utc>) -> String {
    time.with_timezone(&Local)
        .format("%H:%M:%S%.3f")
        .to_string()
}

/// `HH:mm:ss` of Unix seconds (`compactDateFormatter`).
pub(super) fn compact_time(unix_seconds: f64) -> String {
    Local
        .timestamp_opt(unix_seconds as i64, 0)
        .single()
        .map(|t| t.format("%H:%M:%S").to_string())
        .unwrap_or_default()
}

/// Last component of a path (`locationDisplayName`).
fn location_name(path: &str) -> Option<String> {
    let trimmed = path.trim_end_matches('/');
    trimmed
        .rsplit('/')
        .next()
        .filter(|name| !name.is_empty())
        .map(str::to_string)
}

/// Capitalized provider name (`providerDisplayName`).
fn provider_name(provider: &str) -> Option<String> {
    let trimmed = provider.trim();
    let mut chars = trimmed.chars();
    let first = chars.next()?;
    Some(first.to_uppercase().collect::<String>() + chars.as_str())
}

/// The label of a session id in a table (`debugTabDescriptor`): the live tab
/// when there is one, else the provider and the location of its last run.
pub(super) fn tab_label(
    session_id: &str,
    tabs: &[TabDebugInfo],
    fallback_provider: Option<&str>,
    fallback_location: Option<&str>,
) -> String {
    if let Some(tab) = tabs.iter().find(|t| t.id.to_string() == session_id) {
        let custom = tab
            .custom_title
            .as_deref()
            .map(str::trim)
            .filter(|t| !t.is_empty());
        let base = custom
            .map(str::to_string)
            .or_else(|| tab.ai_app.clone())
            .unwrap_or_else(|| tab.title.clone());
        let repo = tab.is_git_repo.then(|| location_name(&tab.cwd)).flatten();
        return composed_tab_label(&base, repo.as_deref(), None);
    }
    let base = fallback_provider
        .and_then(provider_name)
        .unwrap_or_else(|| session_id.chars().take(8).collect());
    let location = fallback_location.and_then(location_name);
    composed_tab_label(&base, location.as_deref(), None)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn names_from_paths_and_providers() {
        assert_eq!(location_name("/a/b/chau7/").as_deref(), Some("chau7"));
        assert_eq!(location_name("/"), None);
        assert_eq!(provider_name(" claude").as_deref(), Some("Claude"));
        assert_eq!(provider_name("  "), None);
    }

    #[test]
    fn labels_of_unknown_tabs() {
        assert_eq!(
            tab_label("abcdef123456", &[], Some("claude"), Some("/x/repo")),
            composed_tab_label("Claude", Some("repo"), None)
        );
        assert_eq!(
            tab_label("abcdef123456", &[], None, None),
            composed_tab_label("abcdef12", None, None)
        );
    }
}
