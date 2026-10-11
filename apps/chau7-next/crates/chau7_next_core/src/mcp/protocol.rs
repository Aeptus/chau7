//! The MCP JSON-RPC 2.0 session (`MCP/MCPSession.swift`).
//!
//! Transport: newline-delimited JSON, one message per line both ways. Each
//! line read is trimmed, empty lines are skipped, and each answer is one
//! line. Methods: `initialize`, `notifications/initialized`, `tools/list`,
//! `tools/call`, `resources/list`, `resources/read`, `ping`.
//!
//! Tool calls always succeed at the JSON-RPC level: the tool's result (or
//! `{"error":"..."}`) is a JSON string in `content[0].text`.
//!
//! Differences with Swift, on purpose: `serverInfo.name` is `chau7-next`
//! (the name it is registered under), and no notification gets an answer
//! (Swift answered "Method not found" with `id: null` to every notification
//! but `notifications/initialized`, which JSON-RPC forbids).

use serde_json::{Map, Value, json};

/// `initialize` result.
pub const PROTOCOL_VERSION: &str = "2024-11-05";
pub const SERVER_VERSION: &str = "1.1.0";

/// What the session asks the app for.
pub trait McpHost {
    /// `tools/list` entries (`name`, `description`, `inputSchema`).
    fn tool_definitions(&self) -> Vec<Value>;
    /// Run a tool; returns its JSON text (a result or `{"error":...}`).
    fn call_tool(&mut self, name: &str, arguments: &Map<String, Value>) -> String;
    /// `resources/list` entries.
    fn resource_definitions(&self) -> Vec<Value>;
    /// `resources/read` text for a URI.
    fn read_resource(&mut self, uri: &str) -> String;
}

fn result(id: Value, result: Value) -> String {
    json!({"jsonrpc": "2.0", "id": id, "result": result}).to_string()
}

fn error(id: Value, code: i64, message: &str) -> String {
    json!({"jsonrpc": "2.0", "id": id, "error": {"code": code, "message": message}}).to_string()
}

/// The parse error line (`-32700`).
pub fn parse_error() -> String {
    error(Value::Null, -32700, "Parse error")
}

/// Handle one line from the client. Returns the line to send back (without
/// the newline), or `None` for blank lines and notifications.
pub fn handle_line(line: &str, server_name: &str, host: &mut dyn McpHost) -> Option<String> {
    let line = line.trim();
    if line.is_empty() {
        return None;
    }
    let Ok(Value::Object(message)) = serde_json::from_str::<Value>(line) else {
        return Some(parse_error());
    };
    let method = message
        .get("method")
        .and_then(Value::as_str)
        .unwrap_or_default();
    let is_notification = !message.contains_key("id");
    let id = message.get("id").cloned().unwrap_or(Value::Null);
    let empty = Map::new();
    let params = message
        .get("params")
        .and_then(Value::as_object)
        .unwrap_or(&empty);
    if method.starts_with("notifications/") || (is_notification && !method.is_empty()) {
        return None;
    }
    Some(match method {
        "initialize" => result(
            id,
            json!({
                "protocolVersion": PROTOCOL_VERSION,
                "capabilities": {
                    "tools": {"listChanged": false},
                    "resources": {"subscribe": false, "listChanged": false}
                },
                "serverInfo": {"name": server_name, "version": SERVER_VERSION}
            }),
        ),
        "tools/list" => result(id, json!({"tools": host.tool_definitions()})),
        "tools/call" => {
            let name = params
                .get("name")
                .and_then(Value::as_str)
                .unwrap_or_default();
            let arguments = params
                .get("arguments")
                .and_then(Value::as_object)
                .unwrap_or(&empty);
            let text = host.call_tool(name, arguments);
            result(id, json!({"content": [{"type": "text", "text": text}]}))
        }
        "resources/list" => result(id, json!({"resources": host.resource_definitions()})),
        "resources/read" => {
            let uri = params
                .get("uri")
                .and_then(Value::as_str)
                .unwrap_or_default();
            let text = host.read_resource(uri);
            result(
                id,
                json!({"contents": [{"uri": uri, "mimeType": "application/json", "text": text}]}),
            )
        }
        "ping" => result(id, json!({})),
        other => error(id, -32601, &format!("Method not found: {other}")),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    struct Host {
        calls: Vec<(String, Map<String, Value>)>,
    }

    impl McpHost for Host {
        fn tool_definitions(&self) -> Vec<Value> {
            vec![json!({"name": "tab_list"})]
        }
        fn call_tool(&mut self, name: &str, arguments: &Map<String, Value>) -> String {
            self.calls.push((name.to_string(), arguments.clone()));
            r#"{"ok":true}"#.to_string()
        }
        fn resource_definitions(&self) -> Vec<Value> {
            vec![json!({"uri": "chau7://telemetry/runs"})]
        }
        fn read_resource(&mut self, uri: &str) -> String {
            format!("[\"{uri}\"]")
        }
    }

    fn run(line: &str) -> (Option<Value>, Host) {
        let mut host = Host { calls: Vec::new() };
        let out = handle_line(line, "chau7-next", &mut host);
        (out.map(|s| serde_json::from_str(&s).unwrap()), host)
    }

    #[test]
    fn initialize() {
        let (v, _) = run(r#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#);
        let v = v.unwrap();
        assert_eq!(v["id"], 1);
        assert_eq!(v["result"]["protocolVersion"], "2024-11-05");
        assert_eq!(v["result"]["serverInfo"]["name"], "chau7-next");
        assert_eq!(v["result"]["serverInfo"]["version"], "1.1.0");
        assert_eq!(v["result"]["capabilities"]["tools"]["listChanged"], false);
        assert_eq!(v["result"]["capabilities"]["resources"]["subscribe"], false);
    }

    #[test]
    fn notifications_and_blank_lines_get_no_answer() {
        assert!(
            run(r#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
                .0
                .is_none()
        );
        assert!(
            run(r#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{}}"#)
                .0
                .is_none()
        );
        assert!(run("   ").0.is_none());
    }

    #[test]
    fn parse_errors() {
        let (v, _) = run("{nope");
        assert_eq!(
            v.unwrap(),
            json!({"jsonrpc":"2.0","id":null,"error":{"code":-32700,"message":"Parse error"}})
        );
        let (v, _) = run("[1,2]");
        assert_eq!(v.unwrap()["error"]["code"], -32700);
    }

    #[test]
    fn unknown_method() {
        let (v, _) = run(r#"{"jsonrpc":"2.0","id":"x","method":"foo/bar"}"#);
        let v = v.unwrap();
        assert_eq!(v["id"], "x");
        assert_eq!(v["error"]["code"], -32601);
        assert_eq!(v["error"]["message"], "Method not found: foo/bar");
    }

    #[test]
    fn tools_list_and_call() {
        let (v, _) = run(r#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#);
        assert_eq!(v.unwrap()["result"]["tools"][0]["name"], "tab_list");
        let (v, host) = run(
            r#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"tab_exec","arguments":{"tab_id":"A","command":"ls"}}}"#,
        );
        let v = v.unwrap();
        assert_eq!(v["result"]["content"][0]["type"], "text");
        assert_eq!(v["result"]["content"][0]["text"], r#"{"ok":true}"#);
        assert_eq!(host.calls[0].0, "tab_exec");
        assert_eq!(host.calls[0].1["command"], "ls");
        // Missing arguments: an empty object.
        let (_, host) =
            run(r#"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"tab_list"}}"#);
        assert!(host.calls[0].1.is_empty());
    }

    #[test]
    fn resources_and_ping() {
        let (v, _) = run(r#"{"jsonrpc":"2.0","id":5,"method":"resources/list"}"#);
        assert_eq!(
            v.unwrap()["result"]["resources"][0]["uri"],
            "chau7://telemetry/runs"
        );
        let (v, _) = run(
            r#"{"jsonrpc":"2.0","id":6,"method":"resources/read","params":{"uri":"chau7://telemetry/sessions"}}"#,
        );
        let v = v.unwrap();
        let content = &v["result"]["contents"][0];
        assert_eq!(content["uri"], "chau7://telemetry/sessions");
        assert_eq!(content["mimeType"], "application/json");
        assert_eq!(content["text"], "[\"chau7://telemetry/sessions\"]");
        let (v, _) = run(r#"{"jsonrpc":"2.0","id":7,"method":"ping"}"#);
        assert_eq!(v.unwrap()["result"], json!({}));
    }
}
