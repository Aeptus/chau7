//! JSON payloads exchanged with the `chau7-remote` agent over the IPC socket.
//!
//! Port of `Remote/RemoteControlModels.swift`. Keys are the Swift `CodingKeys`
//! (snake_case). Optional values the Swift side encodes with
//! `encodeIfPresent` are left out when `None`.

use serde::{Deserialize, Serialize};

/// `PAIRING_INFO` (0x40), sent by the agent when it connects and whenever the
/// pairing code is refreshed.
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RemotePairingInfo {
    pub device_id: String,
    pub mac_pub: String,
    pub pairing_code: String,
    pub expires_at: String,
    pub relay_url: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub relay_key_id: Option<String>,
    /// Only the derived iOS credential, received over owner-only IPC.
    /// Ordinary serialization and diagnostics must never disclose it.
    #[serde(default, skip_serializing)]
    pub relay_secret: Option<String>,
}

/// Explicit secure QR serialization; ordinary device details omit admission credentials.
#[derive(Serialize)]
pub struct RemoteQrPayload {
    pub relay_url: String,
    pub device_id: String,
    pub mac_pub: String,
    pub pairing_code: String,
    pub expires_at: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub relay_key_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub relay_secret: Option<String>,
}

impl std::fmt::Debug for RemotePairingInfo {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("RemotePairingInfo")
            .field("device_id", &self.device_id)
            .field("relay_url", &self.relay_url)
            .field("expires_at", &self.expires_at)
            .field("relay_key_id", &self.relay_key_id)
            .field(
                "relay_secret",
                &self.relay_secret.as_ref().map(|_| "[redacted]"),
            )
            .finish_non_exhaustive()
    }
}

impl RemotePairingInfo {
    /// Public device details for the clipboard; this is not a pairing credential.
    pub fn qr_payload_string(&self) -> String {
        let payload = RemoteQrPayload {
            relay_url: self.relay_url.clone(),
            device_id: self.device_id.clone(),
            mac_pub: self.mac_pub.clone(),
            pairing_code: self.pairing_code.clone(),
            expires_at: self.expires_at.clone(),
            relay_key_id: self.relay_key_id.clone(),
            relay_secret: None,
        };
        serde_json::to_string(&payload).unwrap_or_default()
    }

    /// The only serialization that includes admission material: a private on-screen QR.
    pub fn secure_qr_payload(
        &self,
        now: chrono::DateTime<chrono::Utc>,
    ) -> Result<String, &'static str> {
        use super::relay_credentials::{valid_identifier, valid_role_secret};
        let Some((secret, key_id)) = self
            .relay_secret
            .as_deref()
            .zip(self.relay_key_id.as_deref())
        else {
            return Err(
                "Pairing needs provisioned relay credentials. Configure Remote, then refresh the code.",
            );
        };
        if !valid_role_secret(secret) || !valid_identifier(key_id, 32) {
            return Err(
                "Pairing credentials are invalid. Reprovision Remote, then refresh the code.",
            );
        }
        let expiry = chrono::DateTime::parse_from_rfc3339(&self.expires_at)
            .map_err(|_| "The pairing expiry is invalid. Refresh the code.")?;
        if expiry <= now {
            return Err("This pairing code has expired. Refresh the code.");
        }
        if !self.relay_url.starts_with("wss://")
            || self.relay_url.len() <= 6
            || self.device_id.is_empty()
            || self.mac_pub.is_empty()
            || self.pairing_code.is_empty()
        {
            return Err(
                "Pairing information is incomplete. Check Remote settings and refresh the code.",
            );
        }
        let payload = RemoteQrPayload {
            relay_url: self.relay_url.clone(),
            device_id: self.device_id.clone(),
            mac_pub: self.mac_pub.clone(),
            pairing_code: self.pairing_code.clone(),
            expires_at: self.expires_at.clone(),
            relay_key_id: Some(key_id.to_owned()),
            relay_secret: Some(secret.to_owned()),
        };
        serde_json::to_string(&payload)
            .map_err(|_| "Cannot prepare the pairing code. Refresh the code.")
    }
}

/// One tab of `TAB_LIST` (0x10).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RemoteTabDescriptor {
    pub tab_id: u32,
    pub title: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub project_name: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub branch_name: Option<String>,
    pub is_active: bool,
    pub is_mcp_controlled: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RemoteTabListPayload {
    pub tabs: Vec<RemoteTabDescriptor>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub capabilities: Vec<String>,
}

/// `TAB_SWITCH` (0x11), from the phone.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct RemoteTabSwitchPayload {
    pub tab_id: u32,
}

/// `ERROR` (0x7F) sent by the Mac.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RemoteErrorPayload {
    pub code: String,
    pub message: String,
}

/// `SESSION_STATUS` (0x41): `connecting`, `ready` or `disconnected`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RemoteSessionStatus {
    pub status: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub paired_device_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub paired_device_name: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RemoteClientAppState {
    #[default]
    Foreground,
    Background,
}

/// What the phone wants to receive: everything, or only approvals and
/// interactive prompts (the app is in the background).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RemoteClientStreamMode {
    #[default]
    Full,
    ApprovalsOnly,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RemotePushEnvironment {
    Development,
    Production,
}

/// `CLIENT_STATE` (0x43), from the phone.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RemoteClientStatePayload {
    pub app_state: RemoteClientAppState,
    pub stream_mode: RemoteClientStreamMode,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub push_token: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub push_topic: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub push_environment: Option<RemotePushEnvironment>,
    #[serde(default)]
    pub notifications_authorized: bool,
}

/// `APPROVAL_REQUEST` (0x50). `timestamp` is ISO 8601.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ApprovalRequestPayload {
    pub request_id: String,
    pub command: String,
    pub flagged_command: String,
    pub timestamp: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tab_title: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tool_name: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub project_name: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub branch_name: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub current_directory: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub recent_command: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub context_note: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub session_id: Option<String>,
}

impl ApprovalRequestPayload {
    /// A request with only the required fields set.
    pub fn new(
        request_id: impl Into<String>,
        command: impl Into<String>,
        flagged_command: impl Into<String>,
        timestamp: impl Into<String>,
    ) -> Self {
        Self {
            request_id: request_id.into(),
            command: command.into(),
            flagged_command: flagged_command.into(),
            timestamp: timestamp.into(),
            tab_title: None,
            tool_name: None,
            project_name: None,
            branch_name: None,
            current_directory: None,
            recent_command: None,
            context_note: None,
            session_id: None,
        }
    }
}

/// `APPROVAL_RESPONSE` (0x51), from the phone.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ApprovalResponsePayload {
    pub request_id: String,
    pub approved: bool,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn qr_payload_keeps_swift_key_order() {
        let info = RemotePairingInfo {
            device_id: "dev".into(),
            mac_pub: "pub".into(),
            pairing_code: "123456".into(),
            expires_at: "2026-01-01T00:00:00Z".into(),
            relay_url: "wss://relay.example.com/connect".into(),
            relay_key_id: None,
            relay_secret: None,
        };
        assert_eq!(
            info.qr_payload_string(),
            r#"{"relay_url":"wss://relay.example.com/connect","device_id":"dev","mac_pub":"pub","pairing_code":"123456","expires_at":"2026-01-01T00:00:00Z"}"#
        );
        let decoded: RemotePairingInfo = serde_json::from_str(&info.qr_payload_string()).unwrap();
        assert_eq!(decoded, info);
    }

    fn provisioned_pairing() -> RemotePairingInfo {
        serde_json::from_str(include_str!(
            "../../../../../../services/chau7-remote/docs/fixtures/pairing_info.json"
        ))
        .unwrap()
    }

    #[test]
    fn agent_credentials_survive_into_the_secure_qr_but_not_details_or_debug() {
        let info = provisioned_pairing();
        let now = chrono::DateTime::parse_from_rfc3339("2026-07-01T12:00:00Z")
            .unwrap()
            .to_utc();
        let qr = info.secure_qr_payload(now).unwrap();
        let decoded: RemotePairingInfo = serde_json::from_str(&qr).unwrap();
        assert_eq!(decoded, info);
        let secret = info.relay_secret.as_deref().unwrap();
        assert!(qr.contains(secret));
        for public in [
            info.qr_payload_string(),
            serde_json::to_string(&info).unwrap(),
            format!("{info:?}"),
        ] {
            assert!(!public.contains(secret));
        }
    }

    #[test]
    fn secure_qr_refuses_expired_unprovisioned_and_invalid_credentials() {
        let mut info = provisioned_pairing();
        let expiry = chrono::DateTime::parse_from_rfc3339(&info.expires_at)
            .unwrap()
            .to_utc();
        assert!(info.secure_qr_payload(expiry).is_err());
        let before = expiry - chrono::Duration::seconds(1);
        info.relay_secret = Some("short".into());
        assert!(info.secure_qr_payload(before).is_err());
        info.relay_secret = None;
        assert!(info.secure_qr_payload(before).is_err());
    }

    #[test]
    fn tab_list_omits_missing_optionals() {
        let payload = RemoteTabListPayload {
            capabilities: Vec::new(),
            tabs: vec![RemoteTabDescriptor {
                tab_id: 1,
                title: "Shell".into(),
                project_name: None,
                branch_name: Some("main".into()),
                is_active: true,
                is_mcp_controlled: false,
            }],
        };
        assert_eq!(
            serde_json::to_string(&payload).unwrap(),
            r#"{"tabs":[{"tab_id":1,"title":"Shell","branch_name":"main","is_active":true,"is_mcp_controlled":false}]}"#
        );
    }

    #[test]
    fn client_state_decodes_snake_case_values() {
        let state: RemoteClientStatePayload = serde_json::from_str(
            r#"{"app_state":"background","stream_mode":"approvals_only","push_environment":"production","notifications_authorized":true}"#,
        )
        .unwrap();
        assert_eq!(state.app_state, RemoteClientAppState::Background);
        assert_eq!(state.stream_mode, RemoteClientStreamMode::ApprovalsOnly);
        assert_eq!(
            state.push_environment,
            Some(RemotePushEnvironment::Production)
        );
        assert!(state.notifications_authorized);
    }

    #[test]
    fn approval_payloads_round_trip() {
        let mut request = ApprovalRequestPayload::new("id-1", "rm -rf /", "rm -rf", "2026");
        request.context_note = Some("Waiting at prompt".into());
        let json = serde_json::to_string(&request).unwrap();
        assert!(json.contains(r#""context_note":"Waiting at prompt""#));
        assert!(!json.contains("tab_title"));
        assert_eq!(
            serde_json::from_str::<ApprovalRequestPayload>(&json).unwrap(),
            request
        );
        let response: ApprovalResponsePayload =
            serde_json::from_str(r#"{"request_id":"id-1","approved":true}"#).unwrap();
        assert!(response.approved);
    }

    #[test]
    fn session_status_decodes_without_device() {
        let status: RemoteSessionStatus =
            serde_json::from_str(r#"{"status":"connecting","paired_device_id":""}"#).unwrap();
        assert_eq!(status.status, "connecting");
        assert_eq!(status.paired_device_name, None);
    }
}
