//! Remote interactive prompt payloads (JSON body of `INTERACTIVE_PROMPT_LIST`, 0x15).
//!
//! Port of `RemoteInteractivePrompt.swift` (`apps/chau7-macos/Sources/Chau7Core`).
//! JSON keys are the Swift `CodingKeys` raw values. `detected_at` is a number of
//! seconds since 2001-01-01 UTC (Swift's default `Date` encoding).

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct RemoteInteractivePromptOption {
    pub id: String,
    pub label: String,
    pub response: String,
    pub is_destructive: bool,
}

impl RemoteInteractivePromptOption {
    pub fn new(
        id: impl Into<String>,
        label: impl Into<String>,
        response: impl Into<String>,
        is_destructive: bool,
    ) -> Self {
        Self {
            id: id.into(),
            label: label.into(),
            response: response.into(),
            is_destructive,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct RemoteInteractivePrompt {
    pub id: String,
    pub tab_id: u32,
    pub tab_title: String,
    pub tool_name: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub project_name: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub branch_name: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub current_directory: Option<String>,
    pub prompt: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub detail: Option<String>,
    pub options: Vec<RemoteInteractivePromptOption>,
    #[serde(with = "super::apple_date")]
    pub detected_at: DateTime<Utc>,
}

#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct RemoteInteractivePromptListPayload {
    pub prompts: Vec<RemoteInteractivePrompt>,
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::TimeZone;

    fn sample() -> RemoteInteractivePrompt {
        RemoteInteractivePrompt {
            id: "prompt-1".into(),
            tab_id: 7,
            tab_title: "website".into(),
            tool_name: "Claude".into(),
            project_name: Some("Chau7".into()),
            branch_name: Some("main".into()),
            current_directory: Some("/Users/christophehenner/Downloads/Repositories/Chau7".into()),
            prompt: "Do you want to proceed?".into(),
            detail: Some("Will run a protected command".into()),
            options: vec![
                RemoteInteractivePromptOption::new("1", "Yes", "1\r", false),
                RemoteInteractivePromptOption::new("2", "No", "2\r", true),
            ],
            detected_at: Utc.timestamp_opt(1_742_000_000, 0).unwrap(),
        }
    }

    #[test]
    fn codable_round_trip_preserves_context_fields() {
        let prompt = sample();
        let json = serde_json::to_vec(&prompt).unwrap();
        let decoded: RemoteInteractivePrompt = serde_json::from_slice(&json).unwrap();
        assert_eq!(decoded, prompt);
        assert_eq!(decoded.project_name.as_deref(), Some("Chau7"));
        assert_eq!(decoded.branch_name.as_deref(), Some("main"));
        assert_eq!(
            decoded.current_directory.as_deref(),
            Some("/Users/christophehenner/Downloads/Repositories/Chau7")
        );
    }

    #[test]
    fn json_keys_and_date_format_match_swift() {
        let mut prompt = sample();
        prompt.project_name = None;
        prompt.branch_name = None;
        prompt.current_directory = None;
        prompt.detail = None;
        let value: serde_json::Value =
            serde_json::from_str(&serde_json::to_string(&prompt).unwrap()).unwrap();
        let obj = value.as_object().unwrap();
        let mut keys: Vec<&str> = obj.keys().map(String::as_str).collect();
        keys.sort_unstable();
        assert_eq!(
            keys,
            vec![
                "detected_at",
                "id",
                "options",
                "prompt",
                "tab_id",
                "tab_title",
                "tool_name"
            ]
        );
        // 1_742_000_000 unix seconds is 763_692_800 after 2001-01-01, written as an integer.
        assert_eq!(obj["detected_at"].to_string(), "763692800");
        let opt = obj["options"][1].as_object().unwrap();
        assert_eq!(opt["is_destructive"], serde_json::Value::Bool(true));
        assert_eq!(opt["response"], "2\r");
    }

    #[test]
    fn decodes_swift_json_with_fractional_date() {
        let json = r#"{"id":"p","tab_id":1,"tab_title":"t","tool_name":"Claude","prompt":"Q","options":[],"detected_at":763692800.5}"#;
        let p: RemoteInteractivePrompt = serde_json::from_str(json).unwrap();
        assert_eq!(p.detected_at.timestamp(), 1_742_000_000);
        assert_eq!(p.detected_at.timestamp_subsec_millis(), 500);
    }

    #[test]
    fn list_payload_round_trip() {
        let payload = RemoteInteractivePromptListPayload {
            prompts: vec![sample()],
        };
        let json = serde_json::to_string(&payload).unwrap();
        assert!(json.starts_with(r#"{"prompts":[{"#));
        let back: RemoteInteractivePromptListPayload = serde_json::from_str(&json).unwrap();
        assert_eq!(back, payload);
    }
}
