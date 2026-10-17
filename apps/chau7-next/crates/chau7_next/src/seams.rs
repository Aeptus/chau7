//! Wiring between modules that were ported separately: each one exposes a
//! hook, this module connects them once at launch ([`init`], after every
//! module started).
//!
//! | From | To | Swift |
//! |---|---|---|
//! | AI event feed (`ai::events_out`) | notification engine | `AppModel.recordEvent` -> `NotificationManager.notify` |
//! | notification ingress | Debug Console Events tab | `AppModel.recentEvents` |
//! | notification ledger | Debug Console Health tab (DBG-023) | "Notification Reliability" |
//! | AI hub | "Restart Monitor" (SET-125) | `AppModel.restartTailer` |
//! | Claude Code hook sessions | Debug Console State tab, bug reports | `claudeCodeSessions` |
//! | history database | MCP `repo_*` tools (MCP-028, MCP-030) | `PersistentHistoryStore`, `RepoStatsProvider` |
//! | telemetry store | MCP, repo stats, Data Explorer, Debug Console, remote (`telemetry::connect`) | `TelemetryStore.shared` |
//! | MCP command approval | Remote control, both ways (RMT-017, MCP-045) | `sendApprovalRequest`, `resolveApproval` |
//!
//! File conflicts need no wiring here: the AI hub's detector publishes
//! `file_conflict` events on the feed, and the hover card reads it.

use std::sync::Arc;

use chau7_next_core::ai::event::{AiEvent, AiEventSource};
use chau7_next_core::bug_report::ClaudeSessionState;
use chau7_next_core::debug_console::Tone;
use chau7_next_core::history_record::FrequentCommand;
use chau7_next_core::history_store::HistoryStore;
use chau7_next_core::iso8601;
use chau7_next_core::monitoring::claude_code::ClaudeSessionInfo;
use chau7_next_core::notifications::history::ReliabilitySummary;
use chau7_next_core::remote::models::ApprovalRequestPayload;
use chau7_next_core::repository::RepoStats;
use gpui::App;
use parking_lot::Mutex;

use crate::debug::{DebugEvent, HealthRow};
use crate::mcp::sources as mcp_sources;

/// Connect the modules. Call once, after the AI, history, notification,
/// remote and MCP modules started.
pub fn init(cx: &mut App) {
    // One path for AI events: the feed hands each event to the engine once,
    // with the feed's `notify` flag (timeline-only events stay silent).
    crate::ai::events_out::subscribe(cx, |event, notify, cx| {
        crate::notifications::record_feed_event(event.clone(), notify, cx);
    });
    crate::notifications::set_restart_monitor_hook(crate::ai::hub::restart_event_monitor, cx);
    crate::debug::register_health_section(
        cx,
        "notifications",
        "Notification Reliability",
        reliability_rows,
    );
    crate::debug::set_claude_sessions_source(cx, |cx| {
        cx.try_global::<crate::ai::hub::AiHub>()
            .map(|hub| {
                let mut sessions: Vec<_> = hub.claude.sessions.values().collect();
                sessions.sort_by(|a, b| b.last_activity.total_cmp(&a.last_activity));
                sessions.into_iter().map(claude_session_state).collect()
            })
            .unwrap_or_default()
    });
    if let Some(service) = crate::history::service(cx) {
        let telemetry = crate::telemetry::recorder(cx).map(|r| r.store().clone());
        mcp_sources::set_history(Arc::new(HistoryDb(service.store_handle(), telemetry)));
    }
    // AI run telemetry: MCP, repository stats, Data Explorer, Debug Console
    // Analytics, iOS client events.
    crate::telemetry::connect(cx);
    crate::remote::set_approval_resolver(
        Box::new(|request_id, approved, _cx| {
            crate::mcp::approval::resolve_remote(request_id, approved);
        }),
        cx,
    );
}

/// An event that entered the notification engine, for the Events tab.
pub fn record_debug_event(event: &AiEvent, cx: &mut App) {
    crate::debug::record_event(cx, debug_event(event));
}

/// `AIEvent` as the Debug Console shows it. Claude Code hook events
/// (source `claude_code`) carry their hook name.
fn debug_event(event: &AiEvent) -> DebugEvent {
    let from_hook = event.source.raw_value() == AiEventSource::CLAUDE_CODE
        && event.producer.as_deref() == Some("claude_code_monitor");
    DebugEvent {
        timestamp: parse_timestamp(&event.ts).unwrap_or_else(chrono::Utc::now),
        kind: event.event_type.clone(),
        tool: event.tool.clone(),
        message: event.message.clone(),
        source: event.source.raw_value().to_string(),
        hook: from_hook.then(|| {
            event
                .raw_type
                .clone()
                .unwrap_or_else(|| event.event_type.clone())
        }),
    }
}

/// Event timestamps come with or without fractional seconds.
fn parse_timestamp(text: &str) -> Option<chrono::DateTime<chrono::Utc>> {
    iso8601::parse_iso8601(text).or_else(|| {
        chrono::DateTime::parse_from_rfc3339(text)
            .ok()
            .map(|d| d.with_timezone(&chrono::Utc))
    })
}

/// Swift `ISO8601DateFormatter` (whole seconds), as the MCP tools and the
/// remote payloads use it.
fn iso_seconds(date: chrono::DateTime<chrono::Utc>) -> String {
    date.to_rfc3339_opts(chrono::SecondsFormat::Secs, true)
}

/// DBG-023: the last 100 ledger entries (`NotificationManager.history`).
fn reliability_rows(cx: &App) -> Vec<HealthRow> {
    let entries = cx
        .try_global::<crate::notifications::NotificationCenter>()
        .map(|nc| nc.history.recent(100))
        .unwrap_or_default();
    health_rows(ReliabilitySummary::of(&entries))
}

/// The rows of the reliability box, red where Swift warns.
fn health_rows(s: ReliabilitySummary) -> Vec<HealthRow> {
    let row = |label: &str, value: usize, warn: bool| {
        let row = HealthRow::new(label, value.to_string());
        if warn { row.tone(Tone::Bad) } else { row }
    };
    vec![
        row("Ledger entries", s.entries, false),
        row("Completed", s.completed, s.completed == 0 && s.entries > 0),
        row("Dropped", s.dropped, s.dropped > 0),
        row("Retry scheduled", s.retries, s.retries > 0),
        row("Rate limited", s.rate_limited, s.rate_limited > 0),
        row("Authoritative events", s.authoritative, false),
    ]
}

/// `ClaudeSessionState` of a hook session (`StateSnapshot.capture`).
fn claude_session_state(info: &ClaudeSessionInfo) -> ClaudeSessionState {
    ClaudeSessionState {
        id: info.id.clone(),
        project_name: info.project_name.clone(),
        state: info.state.raw_value().to_string(),
        last_activity: iso8601::adding_seconds(chrono::DateTime::UNIX_EPOCH, info.last_activity),
        last_tool_name: info.last_tool_name.clone(),
    }
}

/// The history database (and the telemetry store, for the AI half of the
/// repo stats) as the MCP tools read them, from their own thread.
struct HistoryDb(
    Arc<Mutex<HistoryStore>>,
    Option<Arc<chau7_next_core::telemetry::store::TelemetryStore>>,
);

impl mcp_sources::HistorySource for HistoryDb {
    fn frequent_commands(&self, repo_root: &str, limit: usize) -> Vec<FrequentCommand> {
        self.0.lock().frequent_commands_for_repo(repo_root, limit)
    }

    fn repo_stats(&self, repo_root: &str) -> mcp_sources::RepoStats {
        let (commands, last) = {
            let store = self.0.lock();
            (
                store.command_stats_for_repo(repo_root),
                store.last_command_timestamp_for_repo(repo_root),
            )
        };
        let ai = self
            .1
            .as_ref()
            .map(|store| crate::telemetry::ai_repo_stats(store, repo_root))
            .unwrap_or_default();
        mcp_repo_stats(&RepoStats::assemble(commands, last, ai))
    }
}

/// `RepoStats` in the shape the MCP tools serialize.
fn mcp_repo_stats(stats: &RepoStats) -> mcp_sources::RepoStats {
    let iso = |d: Option<chrono::DateTime<chrono::Utc>>| d.map(iso_seconds);
    mcp_sources::RepoStats {
        total_commands: stats.total_commands,
        successful_commands: stats.successful_commands,
        failed_commands: stats.failed_commands,
        success_rate: stats.success_rate(),
        average_command_duration: stats.average_command_duration,
        total_runs: stats.total_runs,
        total_tokens: stats.total_tokens,
        total_cost: stats.total_cost,
        total_turns: stats.total_turns,
        providers: stats.providers.clone(),
        top_tools: stats.top_tools.clone(),
        last_command_at: iso(stats.last_command_at),
        last_run_at: iso(stats.last_run_at),
    }
}

/// The phone's copy of an MCP command approval (`requestCommandApproval`:
/// only the command, the flagged part and where the rules came from).
pub fn approval_request(
    request_id: &str,
    command: &str,
    flagged: &str,
    source_info: &str,
) -> ApprovalRequestPayload {
    ApprovalRequestPayload {
        request_id: request_id.to_string(),
        command: command.to_string(),
        flagged_command: flagged.to_string(),
        timestamp: iso_seconds(chrono::Utc::now()),
        tab_title: None,
        tool_name: None,
        project_name: None,
        branch_name: None,
        current_directory: None,
        recent_command: None,
        context_note: Some(source_info.to_string()),
        session_id: None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use chau7_next_core::ai::event::AiEventReliability;
    use chau7_next_core::history_store::CommandStats;
    use chau7_next_core::monitoring::claude_code::SessionState;
    use chau7_next_core::repository::AiRepoStats;

    #[test]
    fn hook_events_carry_their_hook_name() {
        let mut event = AiEvent::new(
            AiEventSource::claude_code(),
            "permission",
            "Claude",
            "Allow Bash?",
            "2026-10-10T12:00:00Z",
        );
        event.producer = Some("claude_code_monitor".into());
        event.raw_type = Some("permission_request".into());
        event.reliability = AiEventReliability::Authoritative;
        let debug = debug_event(&event);
        assert_eq!(debug.kind, "permission");
        assert_eq!(debug.source, "claude_code");
        assert_eq!(debug.hook.as_deref(), Some("permission_request"));
        assert_eq!(
            debug.timestamp,
            parse_timestamp("2026-10-10T12:00:00Z").unwrap()
        );

        let shell = AiEvent::new(
            AiEventSource::shell(),
            "command_failed",
            "Shell",
            "x",
            "bad",
        );
        let debug = debug_event(&shell);
        assert_eq!(debug.hook, None);
        assert_eq!(debug.source, "shell");
    }

    #[test]
    fn reliability_rows_warn_like_swift() {
        let rows = health_rows(ReliabilitySummary {
            entries: 3,
            completed: 0,
            dropped: 2,
            retries: 0,
            rate_limited: 1,
            authoritative: 1,
        });
        let labels: Vec<_> = rows.iter().map(|r| r.label.as_str()).collect();
        assert_eq!(
            labels,
            [
                "Ledger entries",
                "Completed",
                "Dropped",
                "Retry scheduled",
                "Rate limited",
                "Authoritative events"
            ]
        );
        let warned: Vec<_> = rows
            .iter()
            .filter(|r| r.tone.is_some())
            .map(|r| r.label.as_str())
            .collect();
        assert_eq!(warned, ["Completed", "Dropped", "Rate limited"]);
        assert_eq!(rows[2].value, "2");
        // An empty ledger warns about nothing.
        let empty = health_rows(ReliabilitySummary::default());
        assert!(empty.iter().all(|r| r.tone.is_none()));
    }

    #[test]
    fn claude_sessions_map_to_snapshot_state() {
        let info = ClaudeSessionInfo {
            id: "abc".into(),
            project_name: "proj".into(),
            cwd: "/p".into(),
            transcript_path: String::new(),
            last_activity: 1_700_000_000.0,
            state: SessionState::WaitingInput,
            last_tool_name: Some("Bash".into()),
        };
        let state = claude_session_state(&info);
        assert_eq!(state.state, "waitingInput");
        assert_eq!(state.last_activity.timestamp(), 1_700_000_000);
        assert_eq!(state.last_tool_name.as_deref(), Some("Bash"));
    }

    #[test]
    fn repo_stats_convert_for_mcp() {
        let stats = RepoStats::assemble(
            CommandStats {
                total: 4,
                successful: 3,
                failed: 1,
                avg_duration: 2.5,
            },
            parse_timestamp("2026-10-10T12:00:00.250Z"),
            AiRepoStats::default(),
        );
        let mcp = mcp_repo_stats(&stats);
        assert_eq!(mcp.total_commands, 4);
        assert_eq!(mcp.failed_commands, 1);
        assert!((mcp.success_rate - stats.success_rate()).abs() < 1e-9);
        assert_eq!(mcp.average_command_duration, 2.5);
        assert_eq!(mcp.last_command_at.as_deref(), Some("2026-10-10T12:00:00Z"));
        assert_eq!(mcp.last_run_at, None);
    }

    #[test]
    fn approval_payload_matches_swift() {
        let p = approval_request(
            "ID-1",
            "rm -rf build",
            "rm",
            "Permissions source: global settings",
        );
        assert_eq!(p.request_id, "ID-1");
        assert_eq!(p.command, "rm -rf build");
        assert_eq!(p.flagged_command, "rm");
        assert_eq!(
            p.context_note.as_deref(),
            Some("Permissions source: global settings")
        );
        assert!(p.tab_title.is_none() && p.session_id.is_none());
        assert!(parse_timestamp(&p.timestamp).is_some());
    }
}
