//! Port of `MonitoringSchedule.swift`: pure scheduling helpers for monitoring
//! timers plus notification identity, coalescing and rate-limit keys.
//!
//! Timestamps are `f64` seconds on any shared clock (Swift `Date` is a
//! `Double` of seconds as well); only differences matter. Delays are seconds.

use std::collections::{HashMap, HashSet};

use crate::ai::event::AiEvent;

// MARK: - Claude Code idle check

/// Delay until the next idle check, or `None` if no sessions need monitoring.
///
/// `active_session_dates` are last-activity timestamps for sessions in the
/// active/responding state.
pub fn next_idle_check_delay(
    now: f64,
    minimum_interval: f64,
    idle_threshold: f64,
    active_session_dates: &[f64],
) -> Option<f64> {
    let threshold = minimum_interval.max(idle_threshold);
    let mut minimum_remaining = f64::INFINITY;

    for &last_activity in active_session_dates {
        let remaining = threshold - (now - last_activity);
        minimum_remaining = minimum_remaining.min(remaining);
    }

    if !minimum_remaining.is_finite() {
        return None;
    }
    Some(minimum_interval.max(minimum_remaining))
}

// MARK: - History idle check

/// Delay until the next history idle/stale check, or `None` if there are no
/// sessions. Sessions already notified as idle (`idle_notified`) only count
/// toward their stale deadline.
pub fn next_history_check_delay(
    now: f64,
    minimum_check_interval: f64,
    idle_seconds: f64,
    stale_seconds: f64,
    last_seen: &HashMap<String, f64>,
    idle_notified: &HashSet<String>,
) -> Option<f64> {
    let safe_idle_seconds = minimum_check_interval.max(idle_seconds);
    let safe_stale_seconds = (safe_idle_seconds + 1.0).max(stale_seconds);

    let mut next_deadline = f64::INFINITY;
    for (session_id, &last_seen_at) in last_seen {
        if idle_notified.contains(session_id) {
            let next_stale = last_seen_at + safe_stale_seconds;
            if next_stale < next_deadline {
                next_deadline = next_stale;
            }
            continue;
        }

        let next_idle = last_seen_at + safe_idle_seconds;
        if next_idle < next_deadline {
            next_deadline = next_idle;
        }

        let next_stale = last_seen_at + safe_stale_seconds;
        if next_stale < next_deadline {
            next_deadline = next_stale;
        }
    }

    if next_deadline == f64::INFINITY {
        return None;
    }

    let remaining = next_deadline - now;
    Some(minimum_check_interval.max(remaining))
}

// MARK: - Process resource polling

pub const DEFAULT_MINIMUM_POLL_INTERVAL: f64 = 0.75;
pub const DEFAULT_MAX_POLL_INTERVAL: f64 = 3.0;
pub const DEFAULT_BACKOFF_MULTIPLIER: f64 = 1.8;
pub const DEFAULT_MAX_CONSECUTIVE_NO_DATA_POLLS: i64 = 8;

/// Next poll interval with exponential backoff. Zero or negative
/// `consecutive_no_data_polls` yields the minimum.
pub fn next_poll_interval(
    consecutive_no_data_polls: i64,
    minimum_poll_interval: f64,
    max_poll_interval: f64,
    backoff_multiplier: f64,
    max_consecutive_no_data_polls: i64,
) -> f64 {
    if consecutive_no_data_polls <= 0 {
        return minimum_poll_interval;
    }
    let clamped = consecutive_no_data_polls.min(max_consecutive_no_data_polls);
    let backoff = backoff_multiplier.powf(clamped as f64);
    max_poll_interval.min(minimum_poll_interval * backoff)
}

/// [`next_poll_interval`] with the Swift default parameters.
pub fn next_poll_interval_default(consecutive_no_data_polls: i64) -> f64 {
    next_poll_interval(
        consecutive_no_data_polls,
        DEFAULT_MINIMUM_POLL_INTERVAL,
        DEFAULT_MAX_POLL_INTERVAL,
        DEFAULT_BACKOFF_MULTIPLIER,
        DEFAULT_MAX_CONSECUTIVE_NO_DATA_POLLS,
    )
}

// MARK: - Notification coalescing

pub const DEFAULT_COALESCING_WINDOW: f64 = 0.25;

/// Best-available identity scope for an event: tab UUID, then AI session ID,
/// then working directory, then the event UUID (no coalescing).
pub fn notification_identity_key(event: &AiEvent) -> String {
    if let Some(tab_id) = event.tab_id {
        return format!("tab:{}", tab_id.hyphenated().to_string().to_lowercase());
    }

    if let Some(session_id) = normalized_identity_component(event.session_id.as_deref()) {
        return format!("session:{session_id}");
    }

    if let Some(directory) = normalized_directory(event.directory.as_deref()) {
        return format!("dir:{directory}");
    }

    format!("event:{}", event.id.hyphenated().to_string().to_lowercase())
}

/// Coalescing key for notification deduplication (events with the same key
/// inside the window are merged, last wins).
pub fn notification_coalescing_key(event: &AiEvent) -> String {
    let normalized_tool = event.tool.trim().to_lowercase();
    let normalized_type = event.event_type.trim().to_lowercase();
    let identity = notification_identity_key(event);
    let producer = event
        .producer
        .as_deref()
        .map(|p| p.trim().to_lowercase())
        .unwrap_or_else(|| "unknown".to_string());
    format!(
        "{}|{}|{}|{}|{}|{}",
        event.source.raw_value(),
        event.reliability.raw_value(),
        producer,
        normalized_type,
        normalized_tool,
        identity
    )
}

/// Rate-limit key scoped by trigger and event identity.
pub fn notification_rate_limit_key(trigger_id: &str, event: &AiEvent) -> String {
    format!(
        "{}|{}|{}",
        trigger_id,
        event.reliability.raw_value(),
        notification_identity_key(event)
    )
}

fn normalized_identity_component(raw: Option<&str>) -> Option<String> {
    let trimmed = raw?.trim();
    if trimmed.is_empty() {
        return None;
    }
    Some(trimmed.to_lowercase())
}

fn normalized_directory(raw: Option<&str>) -> Option<String> {
    let trimmed = raw?.trim();
    if trimmed.is_empty() {
        return None;
    }
    Some(standardize_path(trimmed).to_lowercase())
}

/// Lexical equivalent of `URL(fileURLWithPath:).standardized.path`: relative
/// paths resolve against the current directory, `.` and `..` and repeated
/// slashes collapse, trailing slashes drop. Symlinks are not resolved.
pub(crate) fn standardize_path(path: &str) -> String {
    let absolute = if path.starts_with('/') {
        path.to_string()
    } else {
        let cwd = std::env::current_dir()
            .map(|p| p.to_string_lossy().into_owned())
            .unwrap_or_else(|_| "/".to_string());
        format!("{cwd}/{path}")
    };
    let mut parts: Vec<&str> = Vec::new();
    for component in absolute.split('/') {
        match component {
            "" | "." => {}
            ".." => {
                parts.pop();
            }
            other => parts.push(other),
        }
    }
    format!("/{}", parts.join("/"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ai::event::AiEventSource;
    use uuid::Uuid;

    const NOW: f64 = 1_000_000.0;

    // Claude Code idle check

    #[test]
    fn test_next_idle_check_delay_returns_nil_with_no_active_sessions() {
        assert_eq!(next_idle_check_delay(NOW, 1.0, 60.0, &[]), None);
    }

    #[test]
    fn test_next_idle_check_delay_uses_closest_session() {
        let delay = next_idle_check_delay(NOW, 1.0, 60.0, &[NOW - 10.0, NOW - 20.0]).unwrap();
        assert!((delay - 40.0).abs() < 0.001);
    }

    #[test]
    fn test_next_idle_check_delay_applies_minimum_floor_for_overdue_sessions() {
        let delay = next_idle_check_delay(NOW, 120.0, 60.0, &[NOW - 200.0]).unwrap();
        assert!((delay - 120.0).abs() < 0.001);
    }

    #[test]
    fn test_next_idle_check_delay_uses_threshold_not_minimum_for_non_overdue_sessions() {
        let delay = next_idle_check_delay(NOW, 1.0, 60.0, &[NOW - 10.0]).unwrap();
        assert!((delay - 50.0).abs() < 0.001);
    }

    // History idle check

    fn history(
        min: f64,
        idle: f64,
        stale: f64,
        seen: &[(&str, f64)],
        notified: &[&str],
    ) -> Option<f64> {
        let last_seen: HashMap<String, f64> =
            seen.iter().map(|(k, v)| (k.to_string(), *v)).collect();
        let idle_notified: HashSet<String> = notified.iter().map(|s| s.to_string()).collect();
        next_history_check_delay(NOW, min, idle, stale, &last_seen, &idle_notified)
    }

    #[test]
    fn test_next_history_check_delay_returns_nil_without_sessions() {
        assert_eq!(history(1.0, 60.0, 120.0, &[], &[]), None);
    }

    #[test]
    fn test_next_history_check_delay_uses_minimum_interval_floor() {
        let delay = history(1.0, 60.0, 120.0, &[("near-threshold", NOW - 59.3)], &[]).unwrap();
        assert!((delay - 1.0).abs() < 0.001);
    }

    #[test]
    fn test_next_history_check_delay_picks_soonest_deadline_across_sessions() {
        let delay = history(
            1.0,
            60.0,
            100.0,
            &[("recent", NOW - 10.0), ("older", NOW - 40.0)],
            &[],
        )
        .unwrap();
        assert!((delay - 20.0).abs() < 0.001);
    }

    #[test]
    fn test_next_history_check_delay_respects_minimum_when_session_is_stale_soon() {
        let delay = history(
            1.0,
            60.0,
            100.0,
            &[("staleSoon", NOW - 75.0), ("activeLong", NOW - 10.0)],
            &[],
        )
        .unwrap();
        assert!((delay - 1.0).abs() < 0.001);
    }

    #[test]
    fn test_next_history_check_delay_clamps_stale_to_idle_plus_one() {
        let delay = history(1.0, 60.0, 1.0, &[("session", NOW - 10.0)], &[]).unwrap();
        assert!((delay - 50.0).abs() < 0.001);
    }

    #[test]
    fn test_next_history_check_delay_for_overdue_state_falls_back_to_minimum() {
        let delay = history(1.0, 60.0, 100.0, &[("session", NOW - 400.0)], &[]).unwrap();
        assert!((delay - 1.0).abs() < 0.001);
    }

    #[test]
    fn test_next_history_check_delay_idle_notified_sessions_wait_for_stale_deadline() {
        // Not notified: idle deadline in 50s. Notified: only the stale deadline (90s).
        let seen = [("s", NOW - 10.0)];
        let plain = history(1.0, 60.0, 100.0, &seen, &[]).unwrap();
        let notified = history(1.0, 60.0, 100.0, &seen, &["s"]).unwrap();
        assert!((plain - 50.0).abs() < 0.001);
        assert!((notified - 90.0).abs() < 0.001);
    }

    // Process resource polling

    #[test]
    fn test_next_poll_interval_starts_at_minimum() {
        let interval = next_poll_interval_default(0);
        assert!((interval - DEFAULT_MINIMUM_POLL_INTERVAL).abs() < 0.001);
    }

    #[test]
    fn test_next_poll_interval_backs_off_exponentially() {
        assert!((next_poll_interval_default(1) - 1.35).abs() < 0.001);
        assert!((next_poll_interval_default(2) - 2.43).abs() < 0.001);
    }

    #[test]
    fn test_next_poll_interval_caps_at_maximum() {
        let capped = next_poll_interval_default(100);
        assert!((capped - DEFAULT_MAX_POLL_INTERVAL).abs() < 0.001);
    }

    #[test]
    fn test_next_poll_interval_treats_negative_as_no_data() {
        let interval = next_poll_interval_default(-3);
        assert!((interval - DEFAULT_MINIMUM_POLL_INTERVAL).abs() < 0.001);
    }

    // Notification keys (NotificationCoalescingTests in NotificationManagerTimingTests.swift)

    struct TestEvent;

    impl TestEvent {
        #[allow(clippy::new_ret_no_self)]
        fn new(source: &str, event_type: &str, tool: &str) -> AiEvent {
            AiEvent::new(AiEventSource::new(source), event_type, tool, "", "t")
        }
    }

    #[test]
    fn test_coalescing_key_normalizes_tool_and_type() {
        let event = TestEvent::new(AiEventSource::CLAUDE_CODE, "  FiNiShEd ", "  Claude ");
        assert_eq!(
            notification_coalescing_key(&event),
            format!(
                "claude_code|authoritative|unknown|finished|claude|event:{}",
                event.id
            )
        );
    }

    #[test]
    fn test_coalescing_key_varies_by_source() {
        let shell = TestEvent::new(AiEventSource::SHELL, "finished", "Claude");
        let history = TestEvent::new(AiEventSource::HISTORY_MONITOR, "finished", "Claude");
        assert_ne!(
            notification_coalescing_key(&shell),
            notification_coalescing_key(&history)
        );
    }

    #[test]
    fn test_coalescing_window_is_configured() {
        assert!((DEFAULT_COALESCING_WINDOW - 0.25).abs() < 0.001);
    }

    #[test]
    fn test_coalescing_key_handles_empty_fields() {
        let event = TestEvent::new(AiEventSource::HISTORY_MONITOR, "   ", "");
        assert_eq!(
            notification_coalescing_key(&event),
            format!("history_monitor|fallback|unknown|||event:{}", event.id)
        );
    }

    #[test]
    fn test_coalescing_key_scopes_by_session_when_tab_id_missing() {
        let mut event = TestEvent::new(AiEventSource::RUNTIME, "permission", "Claude");
        event.session_id = Some("SESSION-123".to_string());
        assert_eq!(
            notification_coalescing_key(&event),
            "runtime|authoritative|unknown|permission|claude|session:session-123"
        );
    }

    #[test]
    fn test_coalescing_key_scopes_by_directory_when_no_tab_or_session_exists() {
        let mut event = TestEvent::new(AiEventSource::SHELL, "finished", "Codex");
        event.directory = Some("/tmp/../tmp/chau7".to_string());
        assert_eq!(
            notification_coalescing_key(&event),
            "shell|authoritative|unknown|finished|codex|dir:/tmp/chau7"
        );
    }

    #[test]
    fn test_rate_limit_key_includes_identity_scope() {
        let mut first = TestEvent::new(AiEventSource::RUNTIME, "permission", "Claude");
        first.tab_id = Uuid::parse_str("AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE").ok();
        let mut second = TestEvent::new(AiEventSource::RUNTIME, "permission", "Claude");
        second.tab_id = Uuid::parse_str("FFFFFFFF-BBBB-CCCC-DDDD-EEEEEEEEEEEE").ok();
        let a = notification_rate_limit_key("runtime.permission", &first);
        let b = notification_rate_limit_key("runtime.permission", &second);
        assert_ne!(a, b);
        assert_eq!(
            a,
            "runtime.permission|authoritative|tab:aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        );
    }

    #[test]
    fn test_identity_key_prefers_tab_then_session_then_directory() {
        let mut event = TestEvent::new(AiEventSource::SHELL, "finished", "x");
        event.tab_id = Some(Uuid::nil());
        event.session_id = Some("S".to_string());
        event.directory = Some("/a".to_string());
        assert_eq!(
            notification_identity_key(&event),
            "tab:00000000-0000-0000-0000-000000000000"
        );
        event.tab_id = None;
        assert_eq!(notification_identity_key(&event), "session:s");
        event.session_id = Some("   ".to_string());
        assert_eq!(notification_identity_key(&event), "dir:/a");
        event.directory = Some("  ".to_string());
        assert_eq!(
            notification_identity_key(&event),
            format!("event:{}", event.id)
        );
    }

    #[test]
    fn test_producer_is_trimmed_and_lowercased() {
        let mut event = TestEvent::new(AiEventSource::RUNTIME, "x", "y");
        event.tab_id = Some(Uuid::nil());
        event.producer = Some("  HookProducer ".to_string());
        assert!(notification_coalescing_key(&event).contains("|hookproducer|"));
    }
}
