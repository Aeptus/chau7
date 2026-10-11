//! Repository tools (`TerminalControlService` repo metadata): description,
//! labels and favorite files in `<repo>/.chau7/metadata.json` (shared with
//! the Swift app on purpose: it belongs to the project), plus frequent
//! commands and stats from [`crate::mcp::sources::history`] and telemetry.

use std::path::Path;

use chau7_next_core::data_root::DataRoot;
use chau7_next_core::history_record::FrequentCommand;
use chau7_next_core::iso8601::now_iso8601;
use chau7_next_core::mcp::output::{encode_sorted, json_error};
use chau7_next_core::repo_metadata::{self, repo_name};
use serde_json::{Map, Value, json};

use super::{arg_int, arg_str, arg_str_list, tool};
use crate::mcp::sources;

pub fn definitions() -> Vec<Value> {
    vec![
        tool(
            "repo_get_metadata",
            "Get metadata for a repository including description, labels, favorite files, and frequent commands.",
            json!({
                "type": "object",
                "properties": {
                    "repo_path": {"type": "string", "description": "Absolute path to the repository root"}
                },
                "required": ["repo_path"]
            }),
        ),
        tool(
            "repo_set_metadata",
            "Set metadata for a repository (description, labels, favorite files). Only provided fields are updated.",
            json!({
                "type": "object",
                "properties": {
                    "repo_path": {"type": "string", "description": "Absolute path to the repository root"},
                    "description": {"type": "string", "description": "Repository description"},
                    "labels": {"type": "array", "items": {"type": "string"}, "description": "Tags/categories for the repo"},
                    "favorite_files": {"type": "array", "items": {"type": "string"}, "description": "Relative paths to important files"}
                },
                "required": ["repo_path"]
            }),
        ),
        tool(
            "repo_frequent_commands",
            "Get frequently used commands for a repository, sorted by frecency.",
            json!({
                "type": "object",
                "properties": {
                    "repo_path": {"type": "string", "description": "Absolute path to the repository root"},
                    "limit": {"type": "integer", "description": "Max commands to return (default 20)"}
                },
                "required": ["repo_path"]
            }),
        ),
    ]
}

pub fn call(name: &str, args: &Map<String, Value>) -> Option<String> {
    let repo = arg_str(args, "repo_path");
    Some(match (name, repo) {
        ("repo_get_metadata", Some(repo)) => get_metadata(repo),
        ("repo_set_metadata", Some(repo)) => set_metadata(
            repo,
            arg_str(args, "description"),
            arg_str_list(args, "labels"),
            arg_str_list(args, "favorite_files"),
        ),
        ("repo_frequent_commands", Some(repo)) => {
            let limit = arg_int(args, "limit").unwrap_or(20).max(0) as usize;
            encode_sorted(&Value::Array(
                sources::history()
                    .frequent_commands(repo, limit)
                    .iter()
                    .map(command_json)
                    .collect(),
            ))
        }
        ("repo_get_metadata" | "repo_set_metadata" | "repo_frequent_commands", None) => {
            json_error("repo_path is required")
        }
        _ => return None,
    })
}

fn command_json(cmd: &FrequentCommand) -> Value {
    json!({
        "command": cmd.command,
        "count": cmd.count,
        "last_used": format_iso8601_seconds(cmd.last_used),
        "frecency_score": cmd.frecency_score()
    })
}

/// `ISO8601DateFormatter` default: seconds, `Z`.
fn format_iso8601_seconds(date: chrono::DateTime<chrono::Utc>) -> String {
    date.to_rfc3339_opts(chrono::SecondsFormat::Secs, true)
}

fn get_metadata(repo: &str) -> String {
    let metadata = repo_metadata::load(&data_root(), Path::new(repo));
    let history = sources::history();
    let mut out = Map::new();
    out.insert("repo_path".into(), json!(repo));
    out.insert("repo_name".into(), json!(repo_name(repo)));
    if let Some(description) = &metadata.description {
        out.insert("description".into(), json!(description));
    }
    if !metadata.labels.is_empty() {
        out.insert("labels".into(), json!(metadata.labels));
    }
    if !metadata.favorite_files.is_empty() {
        out.insert("favorite_files".into(), json!(metadata.favorite_files));
    }
    if let Some(updated) = &metadata.updated_at {
        out.insert("updated_at".into(), json!(updated));
    }
    let frequent = history.frequent_commands(repo, 10);
    if !frequent.is_empty() {
        out.insert(
            "frequent_commands".into(),
            Value::Array(frequent.iter().map(command_json).collect()),
        );
    }
    let stats = history.repo_stats(repo);
    let mut s = Map::new();
    s.insert("total_commands".into(), json!(stats.total_commands));
    s.insert(
        "successful_commands".into(),
        json!(stats.successful_commands),
    );
    s.insert("failed_commands".into(), json!(stats.failed_commands));
    s.insert("success_rate".into(), json!(stats.success_rate));
    s.insert(
        "avg_command_duration".into(),
        json!(stats.average_command_duration),
    );
    s.insert("total_runs".into(), json!(stats.total_runs));
    s.insert("total_tokens".into(), json!(stats.total_tokens));
    s.insert("total_cost".into(), json!(stats.total_cost));
    s.insert("total_turns".into(), json!(stats.total_turns));
    s.insert("providers".into(), json!(stats.providers));
    if !stats.top_tools.is_empty() {
        s.insert(
            "top_tools".into(),
            Value::Array(
                stats
                    .top_tools
                    .iter()
                    .map(|(tool, count)| json!({"tool": tool, "count": count}))
                    .collect(),
            ),
        );
    }
    if let Some(at) = &stats.last_command_at {
        s.insert("last_command_at".into(), json!(at));
    }
    if let Some(at) = &stats.last_run_at {
        s.insert("last_run_at".into(), json!(at));
    }
    out.insert("stats".into(), Value::Object(s));
    encode_sorted(&Value::Object(out))
}

/// Only the given fields change; an empty description clears it.
fn set_metadata(
    repo: &str,
    description: Option<&str>,
    labels: Option<Vec<String>>,
    favorite_files: Option<Vec<String>>,
) -> String {
    let root = Path::new(repo);
    let data = data_root();
    let mut metadata = repo_metadata::load(&data, root);
    if let Some(description) = description {
        metadata.description = (!description.is_empty()).then(|| description.to_string());
    }
    if let Some(labels) = labels {
        metadata.labels = labels;
    }
    if let Some(files) = favorite_files {
        metadata.favorite_files = files;
    }
    metadata.updated_at = Some(now_iso8601());
    if let Err(err) = repo_metadata::save(&data, root, &metadata) {
        log::warn!("MCP: repo_set_metadata {repo}: {err}");
    }
    "{\"ok\":true}".to_string()
}

/// Where Chau7 Next keeps its overlay of repo metadata (a scratch home in
/// tests, so they never touch the real one).
fn data_root() -> DataRoot {
    if cfg!(test) {
        DataRoot::with_home(std::env::temp_dir().join("c7n-mcp-repo-home"), true)
    } else {
        DataRoot::from_env()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn metadata_round_trip_through_the_tools() {
        let dir = std::env::temp_dir().join(format!("c7n-mcp-repo-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let repo = dir.to_string_lossy().to_string();
        let mut args = Map::new();
        args.insert("repo_path".into(), json!(repo));
        args.insert("description".into(), json!("Terminal"));
        args.insert("labels".into(), json!(["rust", "gpui"]));
        assert_eq!(call("repo_set_metadata", &args).unwrap(), r#"{"ok":true}"#);

        let mut get = Map::new();
        get.insert("repo_path".into(), json!(repo));
        let v: Value = serde_json::from_str(&call("repo_get_metadata", &get).unwrap()).unwrap();
        assert_eq!(v["description"], "Terminal");
        assert_eq!(v["labels"], json!(["rust", "gpui"]));
        assert!(v.get("favorite_files").is_none());
        assert!(v["updated_at"].is_string());
        assert_eq!(v["stats"]["total_commands"], 0);
        assert_eq!(v["repo_name"], repo_name(&repo));

        // Only given fields change; an empty description clears it.
        let mut clear = Map::new();
        clear.insert("repo_path".into(), json!(repo));
        clear.insert("description".into(), json!(""));
        call("repo_set_metadata", &clear).unwrap();
        let v: Value = serde_json::from_str(&call("repo_get_metadata", &get).unwrap()).unwrap();
        assert!(v.get("description").is_none());
        assert_eq!(v["labels"], json!(["rust", "gpui"]));

        assert_eq!(call("repo_frequent_commands", &get).unwrap(), "[]");
        assert_eq!(
            call("repo_get_metadata", &Map::new()).unwrap(),
            r#"{"error":"repo_path is required"}"#
        );
        let _ = std::fs::remove_dir_all(&dir);
    }
}
