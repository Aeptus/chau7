//! ISO-8601 CTO diagnostic mirror. Wrappers retain their flag-file hot path.
use crate::{
    cto_wrappers::CtoPaths,
    token_optimization::{CTOGainStats, TabTokenOptOverride},
};
use chrono::{DateTime, SecondsFormat, Utc};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ToolSessionInfo {
    #[serde(rename = "sessionID")]
    pub session_id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub provider: Option<String>,
    #[serde(
        rename = "toolSessionID",
        default,
        skip_serializing_if = "Option::is_none"
    )]
    pub tool_session_id: Option<String>,
}
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct DeferredSessionInfo {
    #[serde(rename = "sessionID")]
    pub session_id: String,
    pub reason: String,
    #[serde(with = "iso")]
    pub since: DateTime<Utc>,
}
/// Additive Next diagnostics: per-session overrides and observed flag state.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionOverrideInfo {
    #[serde(rename = "sessionID")]
    pub session_id: String,
    #[serde(rename = "override")]
    pub override_mode: TabTokenOptOverride,
    #[serde(rename = "isAIActive")]
    pub is_ai_active: bool,
    pub active: bool,
    pub deferred: bool,
}
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct StateSnapshot {
    pub mode: String,
    #[serde(with = "iso")]
    pub updated_at: DateTime<Utc>,
    #[serde(
        default,
        with = "optional_iso",
        skip_serializing_if = "Option::is_none"
    )]
    pub last_state_change_at: Option<DateTime<Utc>>,
    pub active_sessions: Vec<String>,
    pub tracked_sessions: Vec<String>,
    pub deferred_sessions: Vec<DeferredSessionInfo>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub gain_stats: Option<CTOGainStats>,
    #[serde(default)]
    pub tool_sessions: Vec<ToolSessionInfo>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub session_overrides: Vec<SessionOverrideInfo>,
}
mod iso {
    use super::*;
    pub fn serialize<S: serde::Serializer>(
        date: &DateTime<Utc>,
        serializer: S,
    ) -> Result<S::Ok, S::Error> {
        date.to_rfc3339_opts(SecondsFormat::Secs, true)
            .serialize(serializer)
    }
    pub fn deserialize<'de, D: serde::Deserializer<'de>>(
        deserializer: D,
    ) -> Result<DateTime<Utc>, D::Error> {
        DateTime::parse_from_rfc3339(&String::deserialize(deserializer)?)
            .map(|d| d.with_timezone(&Utc))
            .map_err(serde::de::Error::custom)
    }
}
mod optional_iso {
    use super::*;
    pub fn serialize<S: serde::Serializer>(
        date: &Option<DateTime<Utc>>,
        serializer: S,
    ) -> Result<S::Ok, S::Error> {
        date.map(|d| d.to_rfc3339_opts(SecondsFormat::Secs, true))
            .serialize(serializer)
    }
    pub fn deserialize<'de, D: serde::Deserializer<'de>>(
        deserializer: D,
    ) -> Result<Option<DateTime<Utc>>, D::Error> {
        Option::<String>::deserialize(deserializer)?
            .map(|s| {
                DateTime::parse_from_rfc3339(&s)
                    .map(|d| d.with_timezone(&Utc))
                    .map_err(serde::de::Error::custom)
            })
            .transpose()
    }
}
pub fn save(paths: &CtoPaths, state: &StateSnapshot) -> Result<(), String> {
    let path = paths.state_file();
    let anchor = paths
        .flag_dir
        .parent()
        .ok_or("Missing Next CTO storage directory")?;
    crate::injection_rules::atomic_json(&path, anchor, state)
}
pub fn remove(paths: &CtoPaths) -> Result<(), String> {
    let path = paths.state_file();
    let anchor = paths
        .flag_dir
        .parent()
        .ok_or("Missing Next CTO storage directory")?;
    crate::injection_rules::validate_owned_path(&path, anchor)?;
    match std::fs::remove_file(path) {
        Ok(()) => Ok(()),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(e) => Err(e.to_string()),
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn current_swift_iso_schema_and_older_optional_fields_decode() {
        let json = r#"{"mode":"allTabs","updatedAt":"2026-10-11T12:00:00Z","activeSessions":["A"],"trackedSessions":["A"],"deferredSessions":[{"sessionID":"B","reason":"pending_first_prompt","since":"2026-10-11T11:59:59Z"}]}"#;
        let state: StateSnapshot = serde_json::from_str(json).unwrap();
        assert!(state.last_state_change_at.is_none());
        assert!(state.gain_stats.is_none());
        assert!(state.tool_sessions.is_empty());
        let encoded = serde_json::to_value(&state).unwrap();
        assert_eq!(encoded["updatedAt"], "2026-10-11T12:00:00Z");
        assert!(encoded.get("lastStateChangeAt").is_none());
        assert_eq!(encoded["deferredSessions"][0]["sessionID"], "B");
    }
    #[test]
    fn atomic_private_next_file_never_touches_swift_state() {
        let home = std::env::temp_dir().join(format!("chau7-cto-state-{}", uuid::Uuid::new_v4()));
        let root = crate::data_root::DataRoot::with_home(home.clone(), true);
        let paths = CtoPaths::from_root(&root);
        let swift = root
            .swift_cto_bin_dir()
            .parent()
            .unwrap()
            .join("cto_state.json");
        std::fs::create_dir_all(swift.parent().unwrap()).unwrap();
        std::fs::write(&swift, b"preserve Swift").unwrap();
        let state:StateSnapshot=serde_json::from_str(r#"{"mode":"manual","updatedAt":"2026-10-11T12:00:00Z","activeSessions":[],"trackedSessions":[],"deferredSessions":[]}"#).unwrap();
        save(&paths, &state).unwrap();
        let bytes = std::fs::read(paths.state_file()).unwrap();
        assert_eq!(
            serde_json::from_slice::<StateSnapshot>(&bytes).unwrap(),
            state
        );
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            assert_eq!(
                std::fs::metadata(paths.state_file())
                    .unwrap()
                    .permissions()
                    .mode()
                    & 0o777,
                0o600
            );
        }
        remove(&paths).unwrap();
        remove(&paths).unwrap();
        assert!(!paths.state_file().exists());
        assert_eq!(std::fs::read(&swift).unwrap(), b"preserve Swift");
        std::fs::remove_dir_all(home).unwrap();
    }
    #[cfg(unix)]
    #[test]
    fn mirror_rejects_links_instead_of_overwriting_swift() {
        let home = std::env::temp_dir().join(format!("chau7-cto-link-{}", uuid::Uuid::new_v4()));
        let root = crate::data_root::DataRoot::with_home(home.clone(), true);
        let paths = CtoPaths::from_root(&root);
        std::fs::create_dir_all(root.config_dir()).unwrap();
        let other = home.join("preserved");
        std::fs::write(&other, b"keep").unwrap();
        std::os::unix::fs::symlink(&other, paths.state_file()).unwrap();
        let state:StateSnapshot=serde_json::from_str(r#"{"mode":"manual","updatedAt":"2026-10-11T12:00:00Z","activeSessions":[],"trackedSessions":[],"deferredSessions":[]}"#).unwrap();
        assert!(save(&paths, &state).is_err());
        assert!(remove(&paths).is_err());
        assert_eq!(std::fs::read(&other).unwrap(), b"keep");
        std::fs::remove_dir_all(home).unwrap();
    }
}
