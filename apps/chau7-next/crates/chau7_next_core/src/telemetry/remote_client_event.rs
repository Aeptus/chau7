//! Port of `Telemetry/RemoteClientTelemetryEvent.swift`: the telemetry event
//! sent by remote (iOS) clients.
//!
//! Wire format: Swift's default `JSONEncoder`, so `timestamp` is a JSON number
//! of seconds since 2001-01-01 UTC and `nil` fields are omitted.

use std::collections::HashMap;

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

use super::date_codec;
use super::run::new_uuid_string;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum RemoteClientTelemetryEventType {
    #[serde(rename = "connect_requested")]
    ConnectRequested,
    #[serde(rename = "pair_request_sent")]
    PairRequestSent,
    #[serde(rename = "session_encrypted")]
    SessionEncrypted,
    #[serde(rename = "disconnected")]
    Disconnected,
    #[serde(rename = "reconnect_scheduled")]
    ReconnectScheduled,
    #[serde(rename = "tab_switched")]
    TabSwitched,
    #[serde(rename = "approval_received")]
    ApprovalReceived,
    #[serde(rename = "approval_responded")]
    ApprovalResponded,
    #[serde(rename = "notification_opened")]
    NotificationOpened,
    #[serde(rename = "protected_action_prompted")]
    ProtectedActionPrompted,
    #[serde(rename = "protected_action_submitted")]
    ProtectedActionSubmitted,
    #[serde(rename = "error_received")]
    ErrorReceived,
    #[serde(rename = "frame_decode_failed")]
    FrameDecodeFailed,
    #[serde(rename = "frame_decrypt_failed")]
    FrameDecryptFailed,
    #[serde(rename = "send_failed")]
    SendFailed,
}

impl RemoteClientTelemetryEventType {
    pub const ALL: [Self; 15] = [
        Self::ConnectRequested,
        Self::PairRequestSent,
        Self::SessionEncrypted,
        Self::Disconnected,
        Self::ReconnectScheduled,
        Self::TabSwitched,
        Self::ApprovalReceived,
        Self::ApprovalResponded,
        Self::NotificationOpened,
        Self::ProtectedActionPrompted,
        Self::ProtectedActionSubmitted,
        Self::ErrorReceived,
        Self::FrameDecodeFailed,
        Self::FrameDecryptFailed,
        Self::SendFailed,
    ];
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RemoteClientTelemetryEvent {
    pub id: String,
    pub source: String,
    #[serde(default, rename = "deviceID", skip_serializing_if = "Option::is_none")]
    pub device_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub device_name: Option<String>,
    pub app_version: String,
    #[serde(default, rename = "sessionID", skip_serializing_if = "Option::is_none")]
    pub session_id: Option<String>,
    pub event_type: RemoteClientTelemetryEventType,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub status: Option<String>,
    #[serde(default, rename = "tabID", skip_serializing_if = "Option::is_none")]
    pub tab_id: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tab_title: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub message: Option<String>,
    pub metadata: HashMap<String, String>,
    #[serde(with = "date_codec::swift_reference")]
    pub timestamp: DateTime<Utc>,
}

impl RemoteClientTelemetryEvent {
    /// Same defaults as the Swift initializer: fresh uppercase UUID id, source
    /// `"ios"`, empty metadata, timestamp now.
    pub fn new(app_version: impl Into<String>, event_type: RemoteClientTelemetryEventType) -> Self {
        Self {
            id: new_uuid_string(),
            source: "ios".to_string(),
            device_id: None,
            device_name: None,
            app_version: app_version.into(),
            session_id: None,
            event_type,
            status: None,
            tab_id: None,
            tab_title: None,
            message: None,
            metadata: HashMap::new(),
            timestamp: Utc::now(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn codable_round_trip_preserves_telemetry_fields() {
        let timestamp = date_codec::from_reference_seconds(794_770_102.125).unwrap();
        let event = RemoteClientTelemetryEvent {
            id: "event-123".into(),
            source: "ios".into(),
            device_id: Some("device-abc".into()),
            device_name: Some("Christophe's iPhone".into()),
            app_version: "1.1.0".into(),
            session_id: Some("session-xyz".into()),
            event_type: RemoteClientTelemetryEventType::TabSwitched,
            status: Some("ok".into()),
            tab_id: Some(7),
            tab_title: Some("Claude".into()),
            message: Some("Switched tabs".into()),
            metadata: HashMap::from([
                ("from_tab".to_string(), "5".to_string()),
                ("gesture".to_string(), "tap".to_string()),
            ]),
            timestamp,
        };

        let data = serde_json::to_vec(&event).unwrap();
        let decoded: RemoteClientTelemetryEvent = serde_json::from_slice(&data).unwrap();

        assert_eq!(decoded.id, event.id);
        assert_eq!(decoded.source, event.source);
        assert_eq!(decoded.device_id, event.device_id);
        assert_eq!(decoded.device_name, event.device_name);
        assert_eq!(decoded.app_version, event.app_version);
        assert_eq!(decoded.session_id, event.session_id);
        assert_eq!(decoded.event_type, event.event_type);
        assert_eq!(decoded.status, event.status);
        assert_eq!(decoded.tab_id, event.tab_id);
        assert_eq!(decoded.tab_title, event.tab_title);
        assert_eq!(decoded.message, event.message);
        assert_eq!(decoded.metadata, event.metadata);
        assert_eq!(decoded.timestamp, event.timestamp);
    }

    #[test]
    fn wire_keys_and_date_match_swift_default_encoder() {
        let mut event = RemoteClientTelemetryEvent::new(
            "1.1.0",
            RemoteClientTelemetryEventType::FrameDecryptFailed,
        );
        event.device_id = Some("d".into());
        event.session_id = Some("s".into());
        event.tab_id = Some(3);
        event.timestamp = date_codec::from_reference_seconds(794_770_102.125).unwrap();
        let json = serde_json::to_value(&event).unwrap();
        assert_eq!(json["deviceID"], "d");
        assert_eq!(json["sessionID"], "s");
        assert_eq!(json["tabID"], 3);
        assert_eq!(json["appVersion"], "1.1.0");
        assert_eq!(json["eventType"], "frame_decrypt_failed");
        assert_eq!(json["timestamp"], 794_770_102.125);
        assert!(json.get("status").is_none());
    }

    #[test]
    fn decodes_payload_with_missing_optionals() {
        let text = r#"{"id":"a","source":"ios","appVersion":"1","eventType":"disconnected","metadata":{},"timestamp":0}"#;
        let event: RemoteClientTelemetryEvent = serde_json::from_str(text).unwrap();
        assert_eq!(
            event.event_type,
            RemoteClientTelemetryEventType::Disconnected
        );
        assert_eq!(event.tab_id, None);
        assert_eq!(event.timestamp.timestamp(), 978_307_200);
    }
}
