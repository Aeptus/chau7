//! The scripting API protocol (`Scripting/ScriptingAPI.swift`,
//! `ScriptingClientHandler.swift`): newline-delimited JSON requests
//! `{"method", "params", "id"}` on a Unix socket, one JSON line back per
//! request with sorted keys and the request `id` echoed.
//!
//! The Swift server is never started; Chau7 Next starts it from the
//! settings. Fixed Swift bugs: `list_tabs` returns the tabs (Swift always
//! answered `{"tabs":[]}`), `create_tab` runs its `command`, and
//! `list_snippets` lists the snippets.
//!
//! [`ScriptingHost`] is what the app provides; [`handle_request`] is the
//! whole dispatch, tested without a socket.

use serde_json::{Map, Value, json};

/// Longest accepted request line (1 MB).
pub const MAX_LINE_LENGTH: usize = 1_048_576;
/// Default `lines` of `get_output` and `limit` of `get_history`.
pub const DEFAULT_LINES: i64 = 50;
/// The settings `get_settings` and `set_setting` know.
pub const SETTING_KEYS: [&str; 3] = [
    "feature.scriptingAPI",
    "feature.persistentHistory",
    "history.maxRecords",
];

/// What the scripting methods need from the app. Tab methods return the
/// MCP tool JSON text, as Swift calls `TerminalControlService`.
pub trait ScriptingHost {
    fn list_tabs(&mut self) -> String;
    fn tab_status(&mut self, tab_id: &str) -> String;
    fn exec(&mut self, tab_id: &str, command: &str) -> String;
    fn output(&mut self, tab_id: &str, lines: i64) -> String;
    fn create_tab(&mut self, directory: Option<&str>) -> String;
    fn close_tab(&mut self, tab_id: &str) -> String;
    /// Recent commands (empty query) or matching ones, as `get_history`
    /// items.
    fn history(&mut self, query: &str, limit: usize) -> Vec<Value>;
    fn history_count(&mut self) -> i64;
    /// The value of one of [`SETTING_KEYS`].
    fn setting(&mut self, key: &str) -> Value;
    /// Store a setting; `Err` with the message when the value does not fit.
    fn set_setting(&mut self, key: &str, value: &Value) -> Result<(), String>;
    /// (title, body) of every snippet.
    fn snippets(&mut self) -> Vec<(String, String)>;
    fn version(&self) -> (String, String);
    fn uptime_seconds(&self) -> i64;
    fn connected_clients(&self) -> i64;
    fn server_running(&self) -> bool;
}

fn error(message: impl Into<String>) -> Map<String, Value> {
    let mut out = Map::new();
    out.insert("error".into(), Value::String(message.into()));
    out
}

fn result(value: Value) -> Map<String, Value> {
    let mut out = Map::new();
    out.insert("result".into(), value);
    out
}

/// An MCP tool's JSON object as is (`parseJSONResponse`), else `fallback`.
fn object_or(text: &str, fallback: &str) -> Map<String, Value> {
    match serde_json::from_str::<Value>(text) {
        Ok(Value::Object(obj)) => obj,
        _ => error(fallback),
    }
}

fn int_param(params: &Map<String, Value>, key: &str) -> Option<i64> {
    let value = params.get(key)?;
    value.as_i64().or_else(|| {
        value
            .as_f64()
            .filter(|f| f.fract() == 0.0 && f.abs() < 9.0e15)
            .map(|f| f as i64)
    })
}

/// `handleRequest`: one request object to its response object.
pub fn handle_request(
    request: &Map<String, Value>,
    host: &mut dyn ScriptingHost,
) -> Map<String, Value> {
    let Some(method) = request.get("method").and_then(Value::as_str) else {
        return error("missing method");
    };
    let empty = Map::new();
    let params = request
        .get("params")
        .and_then(Value::as_object)
        .unwrap_or(&empty);
    let string = |key: &str| params.get(key).and_then(Value::as_str);
    log::trace!("ScriptingAPI: handling method={method}");
    match method {
        "list_tabs" => match serde_json::from_str::<Value>(&host.list_tabs()) {
            Ok(Value::Array(tabs)) => result(Value::Array(tabs)),
            Ok(Value::Object(obj)) => obj,
            _ => result(json!([])),
        },
        "get_tab" => match string("id") {
            Some(id) => object_or(&host.tab_status(id), "tab not found"),
            None => error("missing param: id"),
        },
        "run_command" => {
            let Some(tab) = string("tab_id") else {
                return error("missing param: tab_id");
            };
            let Some(command) = string("command") else {
                return error("missing param: command");
            };
            object_or(&host.exec(tab, command), "exec failed")
        }
        "get_output" => {
            let Some(tab) = string("tab_id") else {
                return error("missing param: tab_id");
            };
            let lines = int_param(params, "lines").unwrap_or(DEFAULT_LINES);
            object_or(&host.output(tab, lines), "output failed")
        }
        "create_tab" => {
            let created = object_or(&host.create_tab(string("directory")), "create failed");
            // Swift documents `command` and ignores it: run it in the new tab.
            if let (Some(command), Some(tab)) = (
                string("command").filter(|c| !c.is_empty()),
                created.get("tab_id").and_then(Value::as_str),
            ) {
                let ran = object_or(&host.exec(tab, command), "exec failed");
                let mut out = created.clone();
                if let Some(err) = ran.get("error") {
                    out.insert("command_error".into(), err.clone());
                }
                return out;
            }
            created
        }
        "close_tab" => match string("id") {
            Some(id) => object_or(&host.close_tab(id), "close failed"),
            None => error("missing param: id"),
        },
        "get_history" => {
            let query = string("query").unwrap_or_default();
            let limit = int_param(params, "limit").unwrap_or(DEFAULT_LINES).max(0) as usize;
            result(Value::Array(host.history(query, limit)))
        }
        "get_settings" => {
            let mut snapshot = Map::new();
            for key in SETTING_KEYS {
                snapshot.insert(key.into(), host.setting(key));
            }
            result(Value::Object(snapshot))
        }
        "set_setting" => {
            let Some(key) = string("key") else {
                return error("missing param: key");
            };
            let Some(value) = params.get("value").filter(|v| !v.is_null()) else {
                return error("missing param: value");
            };
            if !SETTING_KEYS.contains(&key) {
                return error(format!("unknown or disallowed setting key: {key}"));
            }
            if !(value.is_boolean() || value.is_number() || value.is_string()) {
                return error("unsupported value type; expected Bool, Int, Double, or String");
            }
            match host.set_setting(key, value) {
                Ok(()) => result(json!("ok")),
                Err(err) => error(err),
            }
        }
        "list_snippets" => result(Value::Array(
            host.snippets()
                .into_iter()
                .map(|(title, body)| json!({"title": title, "body": body}))
                .collect(),
        )),
        "run_snippet" => {
            let Some(name) = string("name") else {
                return error("missing param: name");
            };
            match host.snippets().into_iter().find(|(title, _)| title == name) {
                Some((title, body)) => {
                    let mut out = Map::new();
                    out.insert("ok".into(), json!(true));
                    out.insert("snippet".into(), json!(title));
                    out.insert("body".into(), json!(body));
                    out
                }
                None => {
                    let mut out = error("snippet_not_found");
                    out.insert(
                        "message".into(),
                        json!(format!("No snippet named '{name}'")),
                    );
                    out
                }
            }
        }
        "get_status" => {
            let (version, build) = host.version();
            result(json!({
                "version": version,
                "build": build,
                "uptime_seconds": host.uptime_seconds(),
                "connected_clients": host.connected_clients(),
                "server_running": host.server_running(),
                "history_count": host.history_count(),
            }))
        }
        _ => error(format!("unknown method: {method}")),
    }
}

/// What one received line asks for.
#[derive(Debug, Clone, PartialEq)]
pub enum Incoming {
    /// A request; answer it with [`handle_request`] and [`finish_response`].
    Request(Map<String, Value>),
    /// Answer this at once (bad JSON, too long).
    Reply(Map<String, Value>),
}

/// Splits the byte stream of one client into lines (`processLines`).
#[derive(Debug, Default)]
pub struct LineBuffer {
    buffer: Vec<u8>,
}

impl LineBuffer {
    /// Add received bytes; returns the complete lines' requests or replies.
    pub fn push(&mut self, bytes: &[u8]) -> Vec<Incoming> {
        self.buffer.extend_from_slice(bytes);
        let mut out = Vec::new();
        while let Some(pos) = self.buffer.iter().position(|b| *b == b'\n') {
            let line: Vec<u8> = self.buffer.drain(..=pos).collect();
            let line = &line[..line.len() - 1];
            if line.len() > MAX_LINE_LENGTH {
                log::warn!(
                    "ScriptingClientHandler: line too long ({} bytes), dropping",
                    line.len()
                );
                out.push(Incoming::Reply(error("request too large")));
                continue;
            }
            if line.is_empty() {
                continue;
            }
            match serde_json::from_slice::<Value>(line) {
                Ok(Value::Object(obj)) => out.push(Incoming::Request(obj)),
                _ => {
                    log::warn!("ScriptingClientHandler: invalid JSON from client");
                    out.push(Incoming::Reply(error("invalid JSON")));
                }
            }
        }
        if self.buffer.len() > MAX_LINE_LENGTH {
            log::warn!("ScriptingClientHandler: buffer overflow, clearing");
            self.buffer.clear();
        }
        out
    }
}

/// The line sent back: the response with the request `id` (when given),
/// sorted keys, newline.
pub fn finish_response(
    mut response: Map<String, Value>,
    request: Option<&Map<String, Value>>,
) -> String {
    if let Some(id) = request.and_then(|r| r.get("id")) {
        response.insert("id".into(), id.clone());
    }
    let mut text = crate::mcp::output::encode_sorted(&Value::Object(response));
    text.push('\n');
    text
}

#[cfg(test)]
mod tests {
    use super::*;

    #[derive(Default)]
    struct FakeHost {
        settings: Map<String, Value>,
        execs: Vec<(String, String)>,
    }

    impl ScriptingHost for FakeHost {
        fn list_tabs(&mut self) -> String {
            r#"[{"tab_id":"A","window_id":0}]"#.into()
        }
        fn tab_status(&mut self, tab_id: &str) -> String {
            if tab_id == "A" {
                r#"{"tab_id":"A","status":"idle"}"#.into()
            } else {
                r#"{"error":"Tab not found: B"}"#.into()
            }
        }
        fn exec(&mut self, tab_id: &str, command: &str) -> String {
            self.execs.push((tab_id.into(), command.into()));
            r#"{"ok":true,"queued":true}"#.into()
        }
        fn output(&mut self, tab_id: &str, lines: i64) -> String {
            format!(r#"{{"tab_id":"{tab_id}","lines":{lines},"output":"x","source":"buffer"}}"#)
        }
        fn create_tab(&mut self, _: Option<&str>) -> String {
            r#"{"tab_id":"NEW","status":"created","window_id":0,"shell_loading":true}"#.into()
        }
        fn close_tab(&mut self, _: &str) -> String {
            "not json".into()
        }
        fn history(&mut self, query: &str, limit: usize) -> Vec<Value> {
            vec![json!({"command": format!("{query}:{limit}"), "timestamp": 1.5})]
        }
        fn history_count(&mut self) -> i64 {
            3
        }
        fn setting(&mut self, key: &str) -> Value {
            self.settings.get(key).cloned().unwrap_or(json!(false))
        }
        fn set_setting(&mut self, key: &str, value: &Value) -> Result<(), String> {
            if key == "history.maxRecords" && !value.is_number() {
                return Err("history.maxRecords needs a number".into());
            }
            self.settings.insert(key.into(), value.clone());
            Ok(())
        }
        fn snippets(&mut self) -> Vec<(String, String)> {
            vec![("Deploy".into(), "make deploy".into())]
        }
        fn version(&self) -> (String, String) {
            ("1.0".into(), "42".into())
        }
        fn uptime_seconds(&self) -> i64 {
            7
        }
        fn connected_clients(&self) -> i64 {
            1
        }
        fn server_running(&self) -> bool {
            true
        }
    }

    fn call(host: &mut FakeHost, request: Value) -> Map<String, Value> {
        handle_request(request.as_object().unwrap(), host)
    }

    // Ported from ScriptingAPITests.swift.

    #[test]
    fn missing_or_unknown_method() {
        let mut h = FakeHost::default();
        assert_eq!(
            call(&mut h, json!({"params": {"key": "value"}}))["error"],
            "missing method"
        );
        assert_eq!(call(&mut h, json!({}))["error"], "missing method");
        let unknown = call(&mut h, json!({"method": "nonexistent_method"}));
        assert_eq!(unknown["error"], "unknown method: nonexistent_method");
    }

    #[test]
    fn get_status_has_typed_keys() {
        let mut h = FakeHost::default();
        let r = call(&mut h, json!({"method": "get_status"}));
        assert!(r.get("error").is_none());
        let s = &r["result"];
        assert!(s["version"].is_string() && s["build"].is_string());
        assert!(s["uptime_seconds"].is_i64() && s["connected_clients"].is_i64());
        assert!(s["server_running"].is_boolean() && s["history_count"].is_i64());
    }

    #[test]
    fn list_tabs_returns_the_array() {
        let mut h = FakeHost::default();
        let r = call(&mut h, json!({"method": "list_tabs"}));
        assert_eq!(r["result"][0]["tab_id"], "A");
    }

    #[test]
    fn history_settings_and_snippets() {
        let mut h = FakeHost::default();
        let r = call(
            &mut h,
            json!({"method": "get_history", "params": {"limit": 10}}),
        );
        assert_eq!(r["result"][0]["command"], ":10");
        let r = call(
            &mut h,
            json!({"method": "get_history", "params": {"query": "git"}}),
        );
        assert_eq!(r["result"][0]["command"], "git:50");
        let r = call(&mut h, json!({"method": "get_settings"}));
        assert_eq!(r["result"].as_object().unwrap().len(), 3);
        assert_eq!(
            call(
                &mut h,
                json!({"method": "set_setting", "params": {"value": true}})
            )["error"],
            "missing param: key"
        );
        assert_eq!(
            call(
                &mut h,
                json!({"method": "set_setting", "params": {"key": "feature.scriptingAPI"}})
            )["error"],
            "missing param: value"
        );
        let r = call(
            &mut h,
            json!({"method": "set_setting", "params": {"key": "some.private.setting", "value": true}}),
        );
        assert!(r["error"].as_str().unwrap().contains("disallowed"));
        let r = call(
            &mut h,
            json!({"method": "set_setting", "params": {"key": "history.maxRecords", "value": [1]}}),
        );
        assert!(
            r["error"]
                .as_str()
                .unwrap()
                .contains("unsupported value type")
        );
        let r = call(
            &mut h,
            json!({"method": "set_setting", "params": {"key": "history.maxRecords", "value": "x"}}),
        );
        assert_eq!(r["error"], "history.maxRecords needs a number");
        let r = call(
            &mut h,
            json!({"method": "set_setting", "params": {"key": "feature.persistentHistory", "value": false}}),
        );
        assert_eq!(r["result"], "ok");
        let r = call(&mut h, json!({"method": "list_snippets"}));
        assert_eq!(r["result"][0]["title"], "Deploy");
        let r = call(
            &mut h,
            json!({"method": "run_snippet", "params": {"name": "Deploy"}}),
        );
        assert_eq!(r["body"], "make deploy");
        assert_eq!(r["ok"], true);
        let r = call(
            &mut h,
            json!({"method": "run_snippet", "params": {"name": "Nope"}}),
        );
        assert_eq!(r["error"], "snippet_not_found");
        assert_eq!(r["message"], "No snippet named 'Nope'");
    }

    #[test]
    fn tab_methods_check_params_and_pass_mcp_json() {
        let mut h = FakeHost::default();
        let missing = |h: &mut FakeHost, method: &str, params: Value| {
            call(h, json!({"method": method, "params": params}))["error"].clone()
        };
        assert_eq!(
            missing(&mut h, "run_command", json!({"command": "ls"})),
            "missing param: tab_id"
        );
        assert_eq!(
            missing(&mut h, "run_command", json!({"tab_id": "t1"})),
            "missing param: command"
        );
        assert_eq!(
            missing(&mut h, "get_output", json!({})),
            "missing param: tab_id"
        );
        assert_eq!(missing(&mut h, "close_tab", json!({})), "missing param: id");
        assert_eq!(missing(&mut h, "get_tab", json!({})), "missing param: id");
        let r = call(&mut h, json!({"method": "get_tab", "params": {"id": "A"}}));
        assert_eq!(r["status"], "idle");
        let r = call(&mut h, json!({"method": "get_tab", "params": {"id": "B"}}));
        assert_eq!(r["error"], "Tab not found: B");
        let r = call(
            &mut h,
            json!({"method": "get_output", "params": {"tab_id": "A"}}),
        );
        assert_eq!(r["lines"], 50);
        let r = call(
            &mut h,
            json!({"method": "close_tab", "params": {"id": "A"}}),
        );
        assert_eq!(r["error"], "close failed");
        let r = call(
            &mut h,
            json!({"method": "create_tab", "params": {"directory": "/tmp", "command": "make"}}),
        );
        assert_eq!(r["tab_id"], "NEW");
        assert_eq!(h.execs, [("NEW".to_string(), "make".to_string())]);
    }

    #[test]
    fn lines_are_split_checked_and_answered_with_their_id() {
        let mut buffer = LineBuffer::default();
        let got = buffer.push(b"{\"method\":\"get_status\",\"id\":7}\n\nnot json\n{\"meth");
        assert_eq!(got.len(), 2);
        let Incoming::Request(req) = &got[0] else {
            panic!("expected a request");
        };
        assert_eq!(got[1], Incoming::Reply(error("invalid JSON")));
        assert!(buffer.push(b"od\":\"x\"}").is_empty());
        assert_eq!(buffer.push(b"\n").len(), 1);
        let line = finish_response(result(json!({"b": 1, "a": 2})), Some(req));
        assert_eq!(line, "{\"id\":7,\"result\":{\"a\":2,\"b\":1}}\n");
        assert_eq!(finish_response(error("x"), None), "{\"error\":\"x\"}\n");
        // Too long.
        let mut long = vec![b'a'; MAX_LINE_LENGTH + 1];
        long.push(b'\n');
        assert_eq!(
            buffer.push(&long),
            [Incoming::Reply(error("request too large"))]
        );
        // A partial line over the limit is dropped.
        assert!(buffer.push(&vec![b'a'; MAX_LINE_LENGTH + 1]).is_empty());
        assert_eq!(buffer.push(b"{}\n").len(), 1);
    }
}
