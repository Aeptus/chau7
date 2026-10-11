//! Per-connection negotiation and bounded diagnostics, matching current Swift.
use serde_json::{Map, Value, json};

pub const PREFERRED_VERSION: &str = "2025-11-25";
pub const SUPPORTED_VERSIONS: [&str; 3] = ["2025-11-25", "2025-06-18", "2024-11-05"];

#[derive(Debug, Clone)]
pub struct ProtocolError {
    pub code: i64,
    pub message: String,
    pub data: Option<Value>,
}
impl ProtocolError {
    pub fn new(code: i64, message: impl Into<String>) -> Self {
        Self {
            code,
            message: message.into(),
            data: None,
        }
    }
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
enum Lifecycle {
    #[default]
    AwaitingInitialize,
    AwaitingInitialized,
    Ready,
}
#[derive(Debug, Clone, Default)]
pub struct Handshake {
    lifecycle: Lifecycle,
    client_name: Option<String>,
    client_version: Option<String>,
    requested: Option<String>,
    negotiated: Option<String>,
    rejected: Option<&'static str>,
}
fn diagnostic(value: Option<&str>) -> Option<String> {
    let value: String = value?
        .chars()
        .map(|c| if c.is_control() { ' ' } else { c })
        .collect();
    let value: String = value.trim().chars().take(96).collect();
    (!value.is_empty()).then_some(value)
}
impl Handshake {
    pub fn initialize(&mut self, params: &Map<String, Value>) -> Result<String, ProtocolError> {
        if self.lifecycle != Lifecycle::AwaitingInitialize {
            return Err(ProtocolError::new(-32600, "Session is already initialized"));
        }
        self.client_name = diagnostic(
            params
                .get("clientInfo")
                .and_then(|info| info.get("name"))
                .and_then(Value::as_str),
        );
        self.client_version = diagnostic(
            params
                .get("clientInfo")
                .and_then(|info| info.get("version"))
                .and_then(Value::as_str),
        );
        let requested = params.get("protocolVersion").and_then(Value::as_str);
        self.requested = diagnostic(requested);
        self.negotiated = None;
        let Some(requested) = requested.filter(|v| !v.is_empty()) else {
            self.rejected = Some("invalid_parameters");
            return Err(ProtocolError::new(
                -32602,
                "Invalid params: protocolVersion is required",
            ));
        };
        if !SUPPORTED_VERSIONS.contains(&requested) {
            self.rejected = Some("unsupported_protocol_version");
            let mut error = ProtocolError::new(
                -32602,
                format!(
                    "Unsupported protocol version: {}",
                    self.requested.as_deref().unwrap_or("unknown")
                ),
            );
            error.data = Some(json!({"supported": SUPPORTED_VERSIONS}));
            return Err(error);
        }
        self.rejected = None;
        self.negotiated = Some(requested.into());
        self.lifecycle = Lifecycle::AwaitingInitialized;
        Ok(requested.into())
    }
    pub fn initialized(&mut self) {
        if self.lifecycle == Lifecycle::AwaitingInitialized {
            self.lifecycle = Lifecycle::Ready;
        }
    }
    pub fn is_ready(&self) -> bool {
        self.lifecycle == Lifecycle::Ready
    }
    pub fn require_ready(&self, method: &str) -> Result<(), ProtocolError> {
        if self.is_ready() {
            Ok(())
        } else {
            Err(ProtocolError::new(
                -32002,
                format!(
                    "Client must complete initialize and notifications/initialized before calling {method}"
                ),
            ))
        }
    }
    pub fn payload(
        &self,
        server_name: &str,
        server_version: &str,
        bridge: &str,
        socket: &str,
    ) -> Value {
        let status = if self.rejected.is_some() {
            "rejected"
        } else {
            match self.lifecycle {
                Lifecycle::AwaitingInitialize => "awaiting_initialize",
                Lifecycle::AwaitingInitialized => "accepted",
                Lifecycle::Ready => "ready",
            }
        };
        json!({"server_name":server_name,"server_version":server_version,
            "client_name":self.client_name.as_deref().unwrap_or("unknown"),
            "client_version":self.client_version.as_deref().unwrap_or("unknown"),
            "requested_protocol_version":self.requested.as_deref().unwrap_or("unknown"),
            "negotiated_protocol_version":self.negotiated.as_deref().unwrap_or("unknown"),
            "resolved_command_path":bridge,"transport":"unix_socket","socket_path":socket,
            "startup_status":status,"error_class":self.rejected.unwrap_or("none")})
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn params(version: &str) -> Map<String, Value> {
        json!({"protocolVersion":version,"clientInfo":{"name":"test","version":"1"}})
            .as_object()
            .unwrap()
            .clone()
    }
    #[test]
    fn supported_negotiation_requires_initialized_and_refuses_repeat() {
        for version in SUPPORTED_VERSIONS {
            let mut handshake = Handshake::default();
            assert_eq!(
                handshake.require_ready("tools/list").unwrap_err().code,
                -32002
            );
            handshake.initialized();
            assert!(!handshake.is_ready());
            assert_eq!(handshake.initialize(&params(version)).unwrap(), version);
            assert!(!handshake.is_ready());
            handshake.initialized();
            assert!(handshake.is_ready());
            assert_eq!(
                handshake.initialize(&params(version)).unwrap_err().code,
                -32600
            );
        }
    }
    #[test]
    fn rejected_attempt_can_retry_without_inventing_compatibility() {
        let mut handshake = Handshake::default();
        assert_eq!(handshake.initialize(&Map::new()).unwrap_err().code, -32602);
        let error = handshake.initialize(&params("2099-01-01")).unwrap_err();
        assert_eq!(error.data.unwrap()["supported"], json!(SUPPORTED_VERSIONS));
        let diagnostic = handshake.payload("chau7-next", "1", "/bridge", "/socket");
        assert_eq!(diagnostic["startup_status"], "rejected");
        assert_eq!(diagnostic["error_class"], "unsupported_protocol_version");
        handshake.initialize(&params(PREFERRED_VERSION)).unwrap();
        handshake.initialized();
        assert!(handshake.is_ready());
    }
    #[test]
    fn diagnostics_are_bounded_and_connection_specific() {
        let mut first = Handshake::default();
        let second = Handshake::default();
        let mut args = params(PREFERRED_VERSION);
        args.insert(
            "clientInfo".into(),
            json!({"name":format!("\n{}\0","é".repeat(150)),"version":"1\n2"}),
        );
        first.initialize(&args).unwrap();
        let payload = first.payload("chau7-next", "1", "/bridge", "/socket");
        assert_eq!(payload["client_name"].as_str().unwrap().chars().count(), 96);
        assert!(
            !payload["client_name"]
                .as_str()
                .unwrap()
                .chars()
                .any(char::is_control)
        );
        assert_eq!(payload["client_version"], "1 2");
        assert_eq!(
            second.payload("next", "1", "/b", "/s")["startup_status"],
            "awaiting_initialize"
        );
    }
}
