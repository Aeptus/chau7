//! Read-only runtime and numeric performance diagnostics.
use super::{ToolContext, tool};
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
            schema,
        ),
    ]
}

pub fn call(name: &str, _args: &Map<String, Value>, ctx: &ToolContext) -> Option<String> {
    match name {
        "chau7_runtime_info" => Some(encode_sorted(&crate::performance::runtime_info())),
        "chau7_performance_snapshot" => Some(
            ctx.main
                .call(|cx| crate::performance::capture(cx))
                .map(|value| encode_sorted(&value))
                .unwrap_or_else(|| json_error("App is shutting down")),
        ),
        _ => None,
    }
}
