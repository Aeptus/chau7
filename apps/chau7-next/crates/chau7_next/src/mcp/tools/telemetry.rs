//! Telemetry tools and resources (`TelemetryQueryService.swift`): AI runs,
//! their tool calls and transcripts, sessions. Data comes from
//! [`crate::mcp::sources::telemetry`].
//!
//! Resource URIs keep the Swift `chau7://` scheme so agents use the same
//! URIs with both apps.

use std::collections::HashSet;

use chau7_next_core::mcp::output::{encode_sorted, json_error};
use chau7_next_core::telemetry::date_codec::parse_iso8601;
use chau7_next_core::telemetry::run::{TelemetryRun, TelemetryRunFilter};
use serde_json::{Map, Value, json};

use super::{arg_bool, arg_int, arg_str, arg_str_list, tool};
use crate::mcp::sources;

pub fn definitions() -> Vec<Value> {
    vec![
        tool(
            "run_get",
            "Get a single telemetry run by ID",
            json!({
                "type": "object",
                "properties": {"run_id": {"type": "string", "description": "Run UUID"}},
                "required": ["run_id"]
            }),
        ),
        tool(
            "run_list",
            "List telemetry runs with optional filters",
            json!({
                "type": "object",
                "properties": {
                    "session_id": {"type": "string"},
                    "repo_path": {"type": "string"},
                    "provider": {"type": "string"},
                    "after": {"type": "string", "description": "ISO 8601 datetime"},
                    "before": {"type": "string", "description": "ISO 8601 datetime"},
                    "tags": {"type": "array", "items": {"type": "string"}},
                    "limit": {"type": "integer"},
                    "offset": {"type": "integer"}
                }
            }),
        ),
        tool(
            "run_tool_calls",
            "Get all tool calls for a run",
            json!({
                "type": "object",
                "properties": {"run_id": {"type": "string"}},
                "required": ["run_id"]
            }),
        ),
        tool(
            "run_transcript",
            "Get the full conversation transcript (turns) for a run",
            json!({
                "type": "object",
                "properties": {"run_id": {"type": "string"}},
                "required": ["run_id"]
            }),
        ),
        tool(
            "run_tag",
            "Set tags on a run",
            json!({
                "type": "object",
                "properties": {
                    "run_id": {"type": "string"},
                    "tags": {"type": "array", "items": {"type": "string"}}
                },
                "required": ["run_id", "tags"]
            }),
        ),
        tool(
            "run_latest_for_repo",
            "Get the most recent run for a repository",
            json!({
                "type": "object",
                "properties": {
                    "repo_path": {"type": "string"},
                    "provider": {"type": "string"}
                },
                "required": ["repo_path"]
            }),
        ),
        tool(
            "session_list",
            "List AI sessions with run counts",
            json!({
                "type": "object",
                "properties": {
                    "repo_path": {"type": "string"},
                    "active_only": {"type": "boolean"}
                }
            }),
        ),
        tool(
            "session_current",
            "Get currently active AI sessions",
            json!({"type": "object", "properties": {}}),
        ),
    ]
}

fn encode<T: serde::Serialize>(value: &T) -> String {
    serde_json::to_value(value)
        .map(|v| encode_sorted(&v))
        .unwrap_or_else(|_| "{}".into())
}

pub fn call(name: &str, args: &Map<String, Value>) -> Option<String> {
    Some(match name {
        "run_get" => match arg_str(args, "run_id") {
            Some(id) => get_run(id),
            None => json_error("run_id is required"),
        },
        "run_list" => list_runs(args),
        "run_tool_calls" => match arg_str(args, "run_id") {
            Some(id) => encode(&sources::telemetry().tool_calls(id)),
            None => json_error("run_id is required"),
        },
        "run_transcript" => match arg_str(args, "run_id") {
            Some(id) => encode(&sources::telemetry().turns(id)),
            None => json_error("run_id is required"),
        },
        "run_tag" => match (arg_str(args, "run_id"), arg_str_list(args, "tags")) {
            (Some(id), Some(tags)) => {
                sources::telemetry().set_tags(id, &tags);
                "{\"ok\":true}".to_string()
            }
            _ => json_error("run_id and tags are required"),
        },
        "run_latest_for_repo" => match arg_str(args, "repo_path") {
            Some(repo) => {
                match sources::telemetry().latest_run_for_repo(repo, arg_str(args, "provider")) {
                    Some(run) => encode(&run),
                    None => json_error("No runs found for repo"),
                }
            }
            None => json_error("repo_path is required"),
        },
        "session_list" => list_sessions(
            arg_str(args, "repo_path"),
            arg_bool(args, "active_only").unwrap_or(false),
        ),
        "session_current" => encode(&sources::telemetry().active_runs()),
        _ => return None,
    })
}

/// `getRun`: runs in progress first, then the store.
fn get_run(run_id: &str) -> String {
    let source = sources::telemetry();
    if let Some(run) = source.active_runs().into_iter().find(|r| r.id == run_id) {
        return encode(&run);
    }
    match source.run(run_id) {
        Some(run) => encode(&run),
        None => json_error("Run not found"),
    }
}

/// `listRuns`: stored runs, with the matching runs in progress first unless
/// `after` excludes them.
fn list_runs(args: &Map<String, Value>) -> String {
    let filter = TelemetryRunFilter {
        session_id: arg_str(args, "session_id").map(str::to_string),
        repo_path: arg_str(args, "repo_path").map(str::to_string),
        provider: arg_str(args, "provider").map(str::to_string),
        after: parse_iso8601(arg_str(args, "after")),
        before: parse_iso8601(arg_str(args, "before")),
        tags: arg_str_list(args, "tags"),
        limit: Some(arg_int(args, "limit").unwrap_or(50)),
        offset: arg_int(args, "offset"),
    };
    let source = sources::telemetry();
    let stored = source.runs(&filter);
    let runs = merge_active(&filter, source.active_runs(), stored, chrono::Utc::now());
    encode(&runs)
}

fn merge_active(
    filter: &TelemetryRunFilter,
    active: Vec<TelemetryRun>,
    stored: Vec<TelemetryRun>,
    now: chrono::DateTime<chrono::Utc>,
) -> Vec<TelemetryRun> {
    if filter.after.is_some_and(|after| after >= now) {
        return stored;
    }
    let mut out: Vec<TelemetryRun> = active
        .into_iter()
        .filter(|run| {
            filter
                .session_id
                .as_ref()
                .is_none_or(|s| run.session_id.as_ref() == Some(s))
                && filter
                    .repo_path
                    .as_ref()
                    .is_none_or(|r| run.repo_path.as_ref() == Some(r))
                && filter.provider.as_ref().is_none_or(|p| &run.provider == p)
        })
        .collect();
    out.extend(stored);
    out
}

/// `listSessions(repoPath:activeOnly:)`.
fn list_sessions(repo_path: Option<&str>, active_only: bool) -> String {
    let source = sources::telemetry();
    let mut sessions = source.sessions(repo_path);
    if active_only {
        let active: HashSet<String> = source
            .active_runs()
            .into_iter()
            .filter_map(|r| r.session_id)
            .collect();
        sessions.retain(|row| {
            row.get("session_id")
                .and_then(Value::as_str)
                .is_some_and(|sid| active.contains(sid))
        });
    }
    encode_sorted(&Value::Array(
        sessions.into_iter().map(Value::Object).collect(),
    ))
}

pub fn resource_definitions() -> Vec<Value> {
    vec![
        json!({
            "uri": "chau7://telemetry/runs",
            "name": "Recent Runs",
            "description": "Latest telemetry run summaries",
            "mimeType": "application/json"
        }),
        json!({
            "uri": "chau7://telemetry/sessions",
            "name": "Sessions",
            "description": "AI session index",
            "mimeType": "application/json"
        }),
        json!({
            "uri": "chau7://telemetry/sessions/current",
            "name": "Current Sessions",
            "description": "Currently active AI sessions",
            "mimeType": "application/json"
        }),
    ]
}

pub fn read_resource(uri: &str) -> String {
    match uri {
        "chau7://telemetry/runs" => {
            let mut args = Map::new();
            args.insert("limit".into(), json!(20));
            list_runs(&args)
        }
        "chau7://telemetry/sessions" => list_sessions(None, false),
        "chau7://telemetry/sessions/current" => encode(&sources::telemetry().active_runs()),
        _ => match uri.strip_prefix("chau7://telemetry/runs/") {
            Some(run_id) => get_run(run_id),
            None => json_error(&format!("Unknown resource: {uri}")),
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn run(provider: &str, session: Option<&str>) -> TelemetryRun {
        let mut run = TelemetryRun::new(provider, "/tmp");
        run.session_id = session.map(str::to_string);
        run
    }

    #[test]
    fn active_runs_come_first_when_they_match() {
        let filter = TelemetryRunFilter {
            provider: Some("claude".into()),
            ..Default::default()
        };
        let active = vec![run("claude", None), run("codex", None)];
        let stored = vec![run("claude", Some("s"))];
        let merged = merge_active(&filter, active.clone(), stored.clone(), chrono::Utc::now());
        assert_eq!(merged.len(), 2);
        assert_eq!(merged[0].id, active[0].id);
        assert_eq!(merged[1].id, stored[0].id);
        let future = TelemetryRunFilter {
            after: Some(chrono::Utc::now() + chrono::Duration::hours(1)),
            ..Default::default()
        };
        assert_eq!(
            merge_active(&future, active, stored, chrono::Utc::now()).len(),
            1
        );
    }

    #[test]
    fn empty_store_answers() {
        assert_eq!(
            call("run_get", &Map::new()).unwrap(),
            r#"{"error":"run_id is required"}"#
        );
        let mut args = Map::new();
        args.insert("run_id".into(), json!("X"));
        assert_eq!(
            call("run_get", &args).unwrap(),
            r#"{"error":"Run not found"}"#
        );
        assert_eq!(call("run_list", &Map::new()).unwrap(), "[]");
        assert_eq!(call("session_current", &Map::new()).unwrap(), "[]");
        assert_eq!(call("session_list", &Map::new()).unwrap(), "[]");
        assert_eq!(
            call("run_tag", &args).unwrap(),
            r#"{"error":"run_id and tags are required"}"#
        );
        assert!(call("tab_list", &Map::new()).is_none());
        assert_eq!(
            read_resource("chau7://nope"),
            r#"{"error":"Unknown resource: chau7://nope"}"#
        );
        assert_eq!(
            read_resource("chau7://telemetry/runs/ABC"),
            r#"{"error":"Run not found"}"#
        );
    }
}
