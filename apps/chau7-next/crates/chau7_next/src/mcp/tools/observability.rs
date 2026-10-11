//! Read-only runtime and numeric performance diagnostics.
use super::{ToolContext, arg_int, arg_str, tool};
use chau7_next_core::mcp::output::{encode_sorted, json_error};
use serde_json::{Map, Value, json};

pub fn definitions() -> Vec<Value> {
    let schema = json!({"type": "object", "properties": {}, "additionalProperties": false});
    vec![
        tool(
            "chau7_runtime_info",
            "Get the running app identity, build revision and component status.",
            schema.clone(),
        ),
        tool(
            "chau7_performance_snapshot",
            "Get numeric process CPU/RSS, all-pane latency percentiles and feature timings. Excludes terminal content and command text.",
            schema.clone(),
        ),
        tool(
            "chau7_runtime_events",
            "Get ordered lifecycle and AI event evidence through the owner-only local MCP socket.",
            json!({"type":"object","properties":{"since_millis":{"type":"integer"},"limit":{"type":"integer","default":200,"maximum":500}}}),
        ),
        tool(
            "chau7_timer_inventory",
            "Get actual registered task timer lifetimes and cadence.",
            schema,
        ),
        tool(
            "repo_get_events",
            "Get retained AI events attributed to a repository, matching the current Chau7 local MCP tool.",
            json!({"type":"object","properties":{"repo_path":{"type":"string"},"limit":{"type":"integer","default":20,"maximum":50},"tab_id":{"type":"string"},"event_types":{"type":"array","items":{"type":"string"}},"tool":{"type":"string"},"producer":{"type":"string"},"session_id":{"type":"string"},"truncate_messages":{"type":"boolean","default":true}},"required":["repo_path"]}),
        ),
    ]
}

pub fn call(name: &str, args: &Map<String, Value>, ctx: &ToolContext) -> Option<String> {
    match name {
        "chau7_runtime_info" => Some(
            ctx.main
                .call(|cx| {
                    let mut info = crate::performance::runtime_info();
                    info["event_journal"] = crate::observability::journal(cx)
                        .map(|journal| journal.status())
                        .unwrap_or(Value::Null);
                    encode_sorted(&info)
                })
                .unwrap_or_else(|| json_error("App is shutting down")),
        ),
        "chau7_performance_snapshot" => Some(
            ctx.main
                .call(|cx| crate::performance::capture(cx))
                .map(|value| encode_sorted(&value))
                .unwrap_or_else(|| json_error("App is shutting down")),
        ),
        "chau7_runtime_events" => {
            let since = arg_int(args, "since_millis").unwrap_or(i64::MIN);
            let limit = arg_int(args, "limit").unwrap_or(200).clamp(1, 500) as usize;
            Some(
                ctx.main
                    .call(move |cx| {
                        encode_sorted(&crate::observability::runtime_events(since, limit, cx))
                    })
                    .unwrap_or_else(|| json_error("App is shutting down")),
            )
        }
        "chau7_timer_inventory" => Some(
            ctx.main
                .call(|cx| encode_sorted(&crate::observability::timer_inventory(cx)))
                .unwrap_or_else(|| json_error("App is shutting down")),
        ),
        "repo_get_events" => {
            if arg_str(args, "repo_path").is_none() {
                return Some(json_error("repo_path is required"));
            }
            let state = ctx.main.call(|cx| {
                let journal = crate::observability::journal(cx);
                let mut aliases = std::collections::HashMap::new();
                for window in crate::mcp::windows::windows(cx) {
                    let workspace = window.workspace.read(cx);
                    for uuid in workspace.mcp_tab_uuids() {
                        if let Some(tab) = workspace.mcp_find(uuid) {
                            aliases.insert(crate::ai::events_out::tab_uuid(tab), uuid.to_string());
                        }
                    }
                }
                (journal, aliases)
            });
            Some(match state {
                Some((Some(journal), aliases)) => match journal.persisted_events(0, 50_000) {
                    Ok(events) => {
                        encode_sorted(&crate::observability::repo_events(&events, args, &aliases))
                    }
                    Err(error) => json_error(&error),
                },
                _ => json_error("Event journal is unavailable"),
            })
        }
        _ => None,
    }
}
