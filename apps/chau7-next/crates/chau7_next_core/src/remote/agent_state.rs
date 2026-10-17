//! The `chau7-remote` agent's state file (`state.json`): the paired devices
//! the settings list shows, and revoking one.
//!
//! Port of `RemoteAgentStateSnapshot` (`Remote/RemoteControlModels.swift`).
//! The file is owned by the agent (`internal/agent/state.go`); the app only
//! reads it and removes devices. Edits go through `serde_json::Value`, so
//! fields the app does not know (wrapped private key, push tokens) are kept
//! as they are.

use base64::Engine as _;
use base64::engine::general_purpose::STANDARD;
use serde_json::{Map, Value};
use sha2::{Digest, Sha256};

/// A paired device as the agent stores it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AgentPairedDevice {
    pub id: String,
    pub name: String,
    pub public_key_fingerprint: String,
    pub paired_at: Option<String>,
    pub last_connected_at: Option<String>,
}

impl AgentPairedDevice {
    /// Name shown in settings ("Unnamed iPhone" when the phone sent none).
    pub fn display_name(&self) -> String {
        if self.name.is_empty() {
            "Unnamed iPhone".into()
        } else {
            self.name.clone()
        }
    }

    /// Fingerprint shown in settings (the ID when the file has none).
    pub fn display_fingerprint(&self) -> String {
        if self.public_key_fingerprint.is_empty() {
            self.id.clone()
        } else {
            self.public_key_fingerprint.clone()
        }
    }
}

/// `base64(SHA256(raw key)[..8])`, the agent's device ID and fingerprint.
pub fn fingerprint(raw_key: &[u8]) -> String {
    let digest = Sha256::digest(raw_key);
    STANDARD.encode(&digest[..8])
}

fn string_field(map: &Map<String, Value>, key: &str) -> Option<String> {
    map.get(key).and_then(Value::as_str).map(str::to_string)
}

fn non_empty(value: Option<String>) -> Option<String> {
    value.filter(|v| !v.is_empty())
}

/// The paired devices in `text`. A file from before multi-device support
/// (only `ios_public_key`) gives one device, as in Swift and Go.
pub fn paired_devices(text: &str) -> Result<Vec<AgentPairedDevice>, String> {
    let value: Value = serde_json::from_str(text).map_err(|e| e.to_string())?;
    let Value::Object(map) = value else {
        return Err("state file is not a JSON object".into());
    };
    let mut devices: Vec<AgentPairedDevice> = map
        .get("paired_devices")
        .and_then(Value::as_array)
        .map(|list| {
            list.iter()
                .filter_map(Value::as_object)
                .map(|d| AgentPairedDevice {
                    id: string_field(d, "id").unwrap_or_default(),
                    name: string_field(d, "name").unwrap_or_default(),
                    public_key_fingerprint: string_field(d, "public_key_fingerprint")
                        .unwrap_or_default(),
                    paired_at: non_empty(string_field(d, "paired_at")),
                    last_connected_at: non_empty(string_field(d, "last_connected_at")),
                })
                .collect()
        })
        .unwrap_or_default();
    if devices.is_empty()
        && let Some(raw) = string_field(&map, "ios_public_key")
            .and_then(|k| STANDARD.decode(k).ok())
            .filter(|raw| !raw.is_empty())
    {
        let fp = fingerprint(&raw);
        devices.push(AgentPairedDevice {
            id: fp.clone(),
            name: string_field(&map, "ios_name").unwrap_or_default(),
            public_key_fingerprint: fp,
            paired_at: None,
            last_connected_at: None,
        });
    }
    Ok(devices)
}

/// `text` without the device `id` (`removePairedDevice` then save). The
/// legacy single-device fields follow the first remaining device, or are
/// removed when none is left, as the agent does. Returns `None` when the
/// device is not in the file.
pub fn remove_paired_device(text: &str, id: &str) -> Result<Option<String>, String> {
    let known = paired_devices(text)?;
    if !known.iter().any(|d| d.id == id) {
        return Ok(None);
    }
    let mut value: Value = serde_json::from_str(text).map_err(|e| e.to_string())?;
    let Value::Object(map) = &mut value else {
        return Err("state file is not a JSON object".into());
    };
    let mut remaining: Vec<Value> = map
        .get("paired_devices")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    remaining.retain(|d| d.get("id").and_then(Value::as_str) != Some(id));
    let first = remaining.first().and_then(Value::as_object).map(|d| {
        (
            string_field(d, "ios_public_key").unwrap_or_default(),
            string_field(d, "name").unwrap_or_default(),
        )
    });
    match first {
        Some((key, name)) => {
            map.insert("ios_public_key".into(), Value::String(key));
            if name.is_empty() {
                map.remove("ios_name");
            } else {
                map.insert("ios_name".into(), Value::String(name));
            }
        }
        None => {
            map.remove("ios_public_key");
            map.remove("ios_name");
        }
    }
    if remaining.is_empty() {
        map.remove("paired_devices");
    } else {
        map.insert("paired_devices".into(), Value::Array(remaining));
    }
    serde_json::to_string_pretty(&value)
        .map(Some)
        .map_err(|e| e.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    const TWO_DEVICES: &str = r#"{
      "device_id": "mac-1",
      "mac_private_key": "wrapped",
      "mac_public_key": "pub",
      "ios_public_key": "AQID",
      "ios_name": "Phone A",
      "paired_devices": [
        {"id": "fp-a", "name": "Phone A", "ios_public_key": "AQID", "public_key_fingerprint": "fp-a",
         "paired_at": "2026-01-01T00:00:00Z", "push_token": "tok"},
        {"id": "fp-b", "name": "", "ios_public_key": "BAUG", "public_key_fingerprint": "",
         "last_connected_at": "2026-02-01T00:00:00Z"}
      ],
      "key_encrypted": true
    }"#;

    #[test]
    fn lists_devices_with_display_fallbacks() {
        let devices = paired_devices(TWO_DEVICES).unwrap();
        assert_eq!(devices.len(), 2);
        assert_eq!(devices[0].display_name(), "Phone A");
        assert_eq!(
            devices[0].paired_at.as_deref(),
            Some("2026-01-01T00:00:00Z")
        );
        assert_eq!(devices[1].display_name(), "Unnamed iPhone");
        assert_eq!(devices[1].display_fingerprint(), "fp-b");
        assert_eq!(
            devices[1].last_connected_at.as_deref(),
            Some("2026-02-01T00:00:00Z")
        );
    }

    #[test]
    fn legacy_single_device_file_gives_one_device() {
        let text = r#"{"device_id":"mac","ios_public_key":"AQID","ios_name":"Old"}"#;
        let devices = paired_devices(text).unwrap();
        assert_eq!(devices.len(), 1);
        assert_eq!(devices[0].id, fingerprint(&[1, 2, 3]));
        assert_eq!(devices[0].name, "Old");
    }

    #[test]
    fn removing_a_device_keeps_unknown_fields_and_syncs_legacy_keys() {
        let updated = remove_paired_device(TWO_DEVICES, "fp-a").unwrap().unwrap();
        let value: Value = serde_json::from_str(&updated).unwrap();
        assert_eq!(value["mac_private_key"], "wrapped");
        assert_eq!(value["key_encrypted"], true);
        assert_eq!(value["ios_public_key"], "BAUG");
        assert!(value.get("ios_name").is_none());
        let devices = paired_devices(&updated).unwrap();
        assert_eq!(devices.len(), 1);
        assert_eq!(devices[0].id, "fp-b");

        let empty = remove_paired_device(&updated, "fp-b").unwrap().unwrap();
        let value: Value = serde_json::from_str(&empty).unwrap();
        assert!(value.get("ios_public_key").is_none());
        assert!(value.get("paired_devices").is_none());
        assert!(paired_devices(&empty).unwrap().is_empty());
    }

    #[test]
    fn removing_the_legacy_device_clears_it() {
        let text = r#"{"device_id":"mac","ios_public_key":"AQID","ios_name":"Old"}"#;
        let id = fingerprint(&[1, 2, 3]);
        let updated = remove_paired_device(text, &id).unwrap().unwrap();
        assert!(paired_devices(&updated).unwrap().is_empty());
        assert_eq!(remove_paired_device(text, "nope").unwrap(), None);
    }

    #[test]
    fn bad_files_are_errors() {
        assert!(paired_devices("not json").is_err());
        assert!(paired_devices("[]").is_err());
    }
}
