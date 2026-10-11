//! MCP tools (`MCPSession.toolDefinitions` and `callTool`). One file per
//! family; each has `definitions()` (same names, descriptions and JSON
//! schemas as Swift, same order) and `call()`, which returns `None` for a
//! name it does not own.
//!
//! | File | Tools | Handled by |
//! |---|---|---|
//! | `telemetry.rs` | `run_*`, `session_*`, `chau7://` resources | [`super::sources`] (Telemetry port) |
//! | `tabs.rs` | `tab_*` | windows and tabs (`crate::workspace::mcp`) |
//! | `repo.rs` | `repo_*` | `chau7_next_core::repo_metadata`, [`super::sources`] (History port) |
//! | `runtime.rs` | `runtime_*` | the Runtime module (`RuntimeControlService`) |
//!
//! Results are JSON text with sorted keys; errors are `{"error":"..."}`.

pub mod observability;
pub mod repo;
pub mod runtime;
pub mod tabs;
pub mod telemetry;

use serde_json::{Map, Value};

use super::MainThread;
use chau7_next_core::mcp::output::json_error;

/// What a tool call can use.
pub struct ToolContext<'a> {
    pub main: &'a MainThread,
}

/// Every tool, in the Swift order.
pub fn definitions() -> Vec<Value> {
    let mut all = telemetry::definitions();
    all.extend(observability::definitions());
    all.extend(tabs::definitions());
    all.extend(repo::definitions());
    all.extend(runtime::definitions());
    all
}

/// Run a tool by name.
pub fn call(name: &str, args: &Map<String, Value>, ctx: &ToolContext) -> String {
    if let Some(result) = telemetry::call(name, args)
        .or_else(|| observability::call(name, args, ctx))
        .or_else(|| tabs::call(name, args, ctx))
        .or_else(|| repo::call(name, args))
    {
        return result;
    }
    if name.starts_with("runtime_") {
        return runtime::call(name, args, ctx);
    }
    json_error(&format!("Unknown tool: {name}"))
}

/// A string argument (`as? String`).
pub fn arg_str<'a>(args: &'a Map<String, Value>, key: &str) -> Option<&'a str> {
    args.get(key).and_then(Value::as_str)
}

/// An integer argument (`as? Int`; integral numbers only).
pub fn arg_int(args: &Map<String, Value>, key: &str) -> Option<i64> {
    let value = args.get(key)?;
    value.as_i64().or_else(|| {
        value
            .as_f64()
            .filter(|f| f.fract() == 0.0 && f.abs() < 9.0e15)
            .map(|f| f as i64)
    })
}

/// A boolean argument (`as? Bool`).
pub fn arg_bool(args: &Map<String, Value>, key: &str) -> Option<bool> {
    args.get(key).and_then(Value::as_bool)
}

/// A string array argument (`as? [String]`: every item a string).
pub fn arg_str_list(args: &Map<String, Value>, key: &str) -> Option<Vec<String>> {
    args.get(key)?
        .as_array()?
        .iter()
        .map(|v| v.as_str().map(str::to_string))
        .collect()
}

/// A tool schema entry.
pub(crate) fn tool(name: &str, description: &str, schema: Value) -> Value {
    serde_json::json!({"name": name, "description": description, "inputSchema": schema})
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn tool_names_follow_swift_order() {
        let names: Vec<String> = definitions()
            .iter()
            .map(|t| t["name"].as_str().unwrap().to_string())
            .collect();
        assert_eq!(
            names,
            [
                "run_get",
                "run_list",
                "run_tool_calls",
                "run_transcript",
                "run_tag",
                "run_latest_for_repo",
                "session_list",
                "session_current",
                "chau7_runtime_info",
                "chau7_performance_snapshot",
                "tab_list",
                "tab_create",
                "tab_exec",
                "tab_status",
                "tab_send_input",
                "tab_press_key",
                "tab_submit_prompt",
                "tab_close",
                "tab_output",
                "tab_set_cto",
                "tab_rename",
                "repo_get_metadata",
                "repo_set_metadata",
                "repo_frequent_commands",
                "runtime_session_create",
                "runtime_session_list",
                "runtime_session_get",
                "runtime_session_stop",
                "runtime_turn_send",
                "runtime_turn_status",
                "runtime_events_poll",
                "runtime_approval_respond",
            ]
        );
        for tool in definitions() {
            assert_eq!(tool["inputSchema"]["type"], "object", "{tool}");
            assert!(tool["description"].as_str().is_some_and(|d| !d.is_empty()));
        }
    }

    #[test]
    fn argument_helpers_follow_swift_casts() {
        let args = json!({"n": 5, "f": 5.0, "x": 5.5, "s": "5", "b": true, "l": ["a", "b"], "m": ["a", 1]});
        let args = args.as_object().unwrap();
        assert_eq!(arg_int(args, "n"), Some(5));
        assert_eq!(arg_int(args, "f"), Some(5));
        assert_eq!(arg_int(args, "x"), None);
        assert_eq!(arg_int(args, "s"), None);
        assert_eq!(arg_str(args, "s"), Some("5"));
        assert_eq!(arg_bool(args, "b"), Some(true));
        assert_eq!(arg_bool(args, "n"), None);
        assert_eq!(arg_str_list(args, "l"), Some(vec!["a".into(), "b".into()]));
        assert_eq!(arg_str_list(args, "m"), None);
        assert_eq!(arg_str_list(args, "zz"), None);
    }
}
