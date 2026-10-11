//! Stateful MCP JSON-RPC session. Each transport connection owns its handshake.
use super::handshake::{Handshake, PREFERRED_VERSION, ProtocolError};
use serde_json::{Map, Value, json};
pub const PROTOCOL_VERSION: &str = PREFERRED_VERSION;
pub const SERVER_VERSION: &str = "1.1.0";

pub trait McpHost {
    fn handshake(&mut self) -> &mut Handshake;
    fn tool_definitions(&self) -> Vec<Value>;
    fn call_tool(&mut self, name: &str, arguments: &Map<String, Value>) -> String;
    fn call_tool_result(
        &mut self,
        name: &str,
        arguments: &Map<String, Value>,
    ) -> Result<String, ProtocolError> {
        Ok(self.call_tool(name, arguments))
    }
    fn resource_definitions(&self) -> Vec<Value>;
    fn read_resource(&mut self, uri: &str) -> String;
}
fn result(id: Value, result: Value) -> String {
    json!({"jsonrpc":"2.0","id":id,"result":result}).to_string()
}
fn error(id: Value, error: ProtocolError) -> String {
    let mut body = json!({"code":error.code,"message":error.message});
    if let Some(data) = error.data {
        body["data"] = data;
    }
    json!({"jsonrpc":"2.0","id":id,"error":body}).to_string()
}
pub fn parse_error() -> String {
    error(Value::Null, ProtocolError::new(-32700, "Parse error"))
}

pub fn handle_line(line: &str, server_name: &str, host: &mut dyn McpHost) -> Option<String> {
    let line = line.trim();
    if line.is_empty() {
        return None;
    }
    let message = match serde_json::from_str::<Value>(line) {
        Ok(Value::Object(message)) => message,
        Ok(_) => {
            return Some(error(
                Value::Null,
                ProtocolError::new(-32600, "Invalid Request"),
            ));
        }
        Err(_) => return Some(parse_error()),
    };
    let notification = !message.contains_key("id");
    let id = message.get("id").cloned().unwrap_or(Value::Null);
    let method = message.get("method").and_then(Value::as_str);
    if message.get("jsonrpc") != Some(&json!("2.0"))
        || method.is_none()
        || !(id.is_null() || id.is_string() || id.is_number())
    {
        return (!notification)
            .then(|| error(Value::Null, ProtocolError::new(-32600, "Invalid Request")));
    }
    let method = method.unwrap();
    if method == "notifications/initialized" {
        host.handshake().initialized();
        return None;
    }
    if notification && method != "initialize" {
        return None;
    }
    let empty = Map::new();
    let params = match message.get("params") {
        None => &empty,
        Some(Value::Object(params)) => params,
        _ => {
            return (!notification).then(|| {
                error(
                    id,
                    ProtocolError::new(-32602, "Invalid params: expected an object"),
                )
            });
        }
    };
    let outcome: Result<Value, ProtocolError> = (|| match method {
        "initialize" => {
            let version = host.handshake().initialize(params)?;
            Ok(
                json!({"protocolVersion":version,"capabilities":{"tools":{"listChanged":false},"resources":{"subscribe":false,"listChanged":false}},"serverInfo":{"name":server_name,"version":SERVER_VERSION}}),
            )
        }
        "tools/list" => {
            host.handshake().require_ready(method)?;
            Ok(json!({"tools":host.tool_definitions()}))
        }
        "tools/call" => {
            host.handshake().require_ready(method)?;
            let name = params
                .get("name")
                .and_then(Value::as_str)
                .filter(|s| !s.is_empty())
                .ok_or_else(|| ProtocolError::new(-32602, "Invalid params: name is required"))?;
            let arguments = match params.get("arguments") {
                None => &empty,
                Some(Value::Object(arguments)) => arguments,
                _ => {
                    return Err(ProtocolError::new(
                        -32602,
                        "Invalid params: arguments must be an object",
                    ));
                }
            };
            let definitions = host.tool_definitions();
            let definition = definitions
                .iter()
                .find(|entry| entry["name"] == name)
                .ok_or_else(|| ProtocolError::new(-32602, format!("Unknown tool: {name}")))?;
            if let Some(schema) = definition.get("inputSchema") {
                let violations = crate::runtime::structured_result::validate(
                    &Value::Object(arguments.clone()),
                    schema,
                );
                if !violations.is_empty() {
                    return Err(ProtocolError::new(
                        -32602,
                        format!("Invalid params: {}", violations.join("; ")),
                    ));
                }
            }
            let text = host.call_tool_result(name, arguments)?;
            let is_error = serde_json::from_str::<Value>(&text)
                .ok()
                .is_some_and(|v| v.get("error").is_some());
            let mut result = json!({"content":[{"type":"text","text":text}],"isError":is_error});
            if let Ok(Value::Object(content)) = serde_json::from_str::<Value>(&text) {
                result["structuredContent"] = Value::Object(content);
            }
            Ok(result)
        }
        "resources/list" => {
            host.handshake().require_ready(method)?;
            Ok(json!({"resources":host.resource_definitions()}))
        }
        "resources/read" => {
            host.handshake().require_ready(method)?;
            let uri = params
                .get("uri")
                .and_then(Value::as_str)
                .filter(|s| !s.is_empty())
                .ok_or_else(|| ProtocolError::new(-32602, "Invalid params: uri is required"))?;
            let text = host.read_resource(uri);
            Ok(json!({"contents":[{"uri":uri,"mimeType":"application/json","text":text}]}))
        }
        "ping" => Ok(json!({})),
        other => Err(ProtocolError::new(
            -32601,
            format!("Method not found: {other}"),
        )),
    })();
    (!notification).then(|| match outcome {
        Ok(value) => result(id, value),
        Err(failure) => error(id, failure),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    #[derive(Default)]
    struct Host {
        handshake: Handshake,
        calls: Vec<String>,
    }
    impl McpHost for Host {
        fn handshake(&mut self) -> &mut Handshake {
            &mut self.handshake
        }
        fn tool_definitions(&self) -> Vec<Value> {
            vec![
                json!({"name":"tab_list","inputSchema":{"type":"object","additionalProperties":false}}),
                json!({"name":"tab_exec","inputSchema":{"type":"object","required":["tab_id","command"],"properties":{"tab_id":{"type":"string"},"command":{"type":"string"}},"additionalProperties":false}}),
            ]
        }
        fn call_tool(&mut self, name: &str, _: &Map<String, Value>) -> String {
            self.calls.push(name.into());
            if name == "tab_exec" {
                r#"{"error":"denied"}"#.into()
            } else {
                r#"{"ok":true}"#.into()
            }
        }
        fn resource_definitions(&self) -> Vec<Value> {
            vec![json!({"uri":"chau7://telemetry/runs"})]
        }
        fn read_resource(&mut self, uri: &str) -> String {
            json!([uri]).to_string()
        }
    }
    fn request(host: &mut Host, method: &str, params: Value) -> Value {
        serde_json::from_str(
            &handle_line(
                &json!({"jsonrpc":"2.0","id":1,"method":method,"params":params}).to_string(),
                "chau7-next",
                host,
            )
            .unwrap(),
        )
        .unwrap()
    }
    fn ready() -> Host {
        let mut host = Host::default();
        let result = request(
            &mut host,
            "initialize",
            json!({"protocolVersion":PROTOCOL_VERSION}),
        );
        assert_eq!(result["result"]["protocolVersion"], PROTOCOL_VERSION);
        handle_line(
            r#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
            "chau7-next",
            &mut host,
        );
        host
    }
    #[test]
    fn lifecycle_gate_and_supported_protocol_are_connection_specific() {
        let mut host = Host::default();
        assert_eq!(
            request(&mut host, "tools/list", json!({}))["error"]["code"],
            -32002
        );
        let result = request(
            &mut host,
            "initialize",
            json!({"protocolVersion":"2024-11-05"}),
        );
        assert_eq!(result["result"]["protocolVersion"], "2024-11-05");
        assert_eq!(
            request(&mut host, "tools/list", json!({}))["error"]["code"],
            -32002
        );
        handle_line(
            r#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
            "chau7-next",
            &mut host,
        );
        assert!(request(&mut host, "tools/list", json!({}))["result"]["tools"].is_array());
        assert_eq!(
            request(
                &mut host,
                "initialize",
                json!({"protocolVersion":PROTOCOL_VERSION})
            )["error"]["code"],
            -32600
        );
        assert!(!Host::default().handshake.is_ready());
    }
    #[test]
    fn malformed_and_missing_initialization_do_not_enable_tools() {
        let mut host = Host::default();
        for params in [
            json!({}),
            json!({"protocolVersion":42}),
            json!({"protocolVersion":"2099-01-01"}),
            json!([]),
        ] {
            assert_eq!(
                request(&mut host, "initialize", params)["error"]["code"],
                -32602
            );
            assert!(!host.handshake.is_ready());
        }
        assert_eq!(request(&mut host, "ping", json!({}))["result"], json!({}));
        assert_eq!(
            request(&mut host, "foo/bar", json!({}))["error"]["code"],
            -32601
        );
    }
    #[test]
    fn tool_schema_validates_before_dispatch_and_tool_errors_are_flagged() {
        let mut host = ready();
        for params in [
            json!({"name":"tab_exec","arguments":{"tab_id":"A"}}),
            json!({"name":"tab_exec","arguments":{"tab_id":"A","command":42}}),
            json!({"name":"tab_list","arguments":{"extra":true}}),
            json!({"name":"tab_list","arguments":[]}),
            json!({"name":"missing"}),
        ] {
            assert_eq!(
                request(&mut host, "tools/call", params)["error"]["code"],
                -32602
            );
        }
        assert!(host.calls.is_empty());
        let result = request(
            &mut host,
            "tools/call",
            json!({"name":"tab_exec","arguments":{"tab_id":"A","command":"ls"}}),
        );
        assert_eq!(result["result"]["isError"], true);
        assert_eq!(
            request(&mut host, "tools/call", json!({"name":"tab_list"}))["result"]["isError"],
            false
        );
        assert_eq!(host.calls, vec!["tab_exec", "tab_list"]);
    }
    #[test]
    fn notifications_are_silent_and_resources_require_ready() {
        let mut host = ready();
        for line in [
            " ",
            r#"{"jsonrpc":"2.0","method":"notifications/cancelled"}"#,
            r#"{"jsonrpc":"2.0","method":"unknown"}"#,
        ] {
            assert!(handle_line(line, "chau7-next", &mut host).is_none());
        }
        assert_eq!(
            request(&mut host, "resources/list", json!({}))["result"]["resources"][0]["uri"],
            "chau7://telemetry/runs"
        );
        let result = request(
            &mut host,
            "resources/read",
            json!({"uri":"chau7://telemetry/runs"}),
        );
        assert_eq!(
            result["result"]["contents"][0]["mimeType"],
            "application/json"
        );
    }
    #[test]
    fn invalid_frames_are_not_tool_calls() {
        let mut host = ready();
        for (line, code) in [
            ("{nope", -32700),
            ("[1,2]", -32600),
            (r#"{"id":1,"method":"tools/list"}"#, -32600),
            (r#"{"jsonrpc":"2.0","id":true,"method":"ping"}"#, -32600),
        ] {
            let value: Value =
                serde_json::from_str(&handle_line(line, "next", &mut host).unwrap()).unwrap();
            assert_eq!(value["error"]["code"], code);
        }
        assert!(host.calls.is_empty());
    }
}
