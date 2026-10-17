//! Remote control (`RemoteSettingsView.swift`, `FeatureSettings`
//! `isRemoteEnabled` / `remoteRelayURL`) and read-only viewer sharing
//! (`RemoteViewerMode.swift`). The Swift app keeps these in UserDefaults
//! (`remote.enabled`, `remote.relayURL`, `feature.remoteViewer`,
//! `remoteViewer.*`), not in its config file, so they live in `[next]`.

use chau7_next_core::config::RawValue;

use super::{ConfigSink, ConfigSource, SettingsDomain};

/// `remote.relayURL` default.
pub const DEFAULT_RELAY_URL: &str = "wss://relay.example.com/connect";

#[derive(Debug, Clone, PartialEq)]
pub struct RemoteSettings {
    /// `remote.enabled`: run the agent so the iOS app can connect.
    pub enabled: bool,
    /// `remote.relayURL`, trimmed.
    pub relay_url: String,
    /// `feature.remoteViewer`.
    pub viewer_enabled: bool,
    /// `remoteViewer.maxViewers` (1 to 10).
    pub viewer_max: u32,
    /// `remoteViewer.autoApproveKnown`.
    pub viewer_auto_approve_known: bool,
    /// `remoteViewer.knownIDs`.
    pub viewer_known_ids: Vec<String>,
}

impl Default for RemoteSettings {
    fn default() -> Self {
        Self {
            enabled: false,
            relay_url: DEFAULT_RELAY_URL.into(),
            viewer_enabled: false,
            viewer_max: 1,
            viewer_auto_approve_known: false,
            viewer_known_ids: Vec::new(),
        }
    }
}

fn quoted(text: &str) -> String {
    serde_json::to_string(text).unwrap_or_else(|_| "\"\"".into())
}

impl SettingsDomain for RemoteSettings {
    fn load(&mut self, src: &ConfigSource) {
        if let Some(v) = src.next("remote_enabled").and_then(RawValue::as_bool) {
            self.enabled = v;
        }
        if let Some(v) = src.next("remote_relay_url").and_then(RawValue::as_str) {
            self.relay_url = v.trim().to_string();
        }
        if let Some(v) = src
            .next("remote_viewer_enabled")
            .and_then(RawValue::as_bool)
        {
            self.viewer_enabled = v;
        }
        if let Some(v) = src
            .next("remote_viewer_max_viewers")
            .and_then(RawValue::as_int)
        {
            self.viewer_max = v.clamp(1, 10) as u32;
        }
        if let Some(v) = src
            .next("remote_viewer_auto_approve_known")
            .and_then(RawValue::as_bool)
        {
            self.viewer_auto_approve_known = v;
        }
        if let Some(v) = src
            .next("remote_viewer_known_ids")
            .and_then(RawValue::as_str)
        {
            self.viewer_known_ids = v
                .split(',')
                .map(str::trim)
                .filter(|s| !s.is_empty())
                .map(str::to_string)
                .collect();
        }
    }

    fn save(&self, out: &mut ConfigSink) {
        out.set_next("remote_enabled", self.enabled);
        out.set_next("remote_relay_url", quoted(self.relay_url.trim()));
        out.set_next("remote_viewer_enabled", self.viewer_enabled);
        out.set_next("remote_viewer_max_viewers", self.viewer_max.clamp(1, 10));
        out.set_next(
            "remote_viewer_auto_approve_known",
            self.viewer_auto_approve_known,
        );
        out.set_next(
            "remote_viewer_known_ids",
            quoted(&self.viewer_known_ids.join(",")),
        );
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::settings::{load_text, round_trip};

    #[test]
    fn round_trips() {
        let settings = RemoteSettings {
            enabled: true,
            relay_url: "wss://relay.test/connect".into(),
            viewer_enabled: true,
            viewer_max: 4,
            viewer_auto_approve_known: true,
            viewer_known_ids: vec!["a".into(), "b".into()],
        };
        assert_eq!(round_trip(&settings), settings);
        assert_eq!(
            round_trip(&RemoteSettings::default()),
            RemoteSettings::default()
        );
    }

    #[test]
    fn trims_the_relay_and_clamps_viewers() {
        let loaded: RemoteSettings = load_text(
            "[next]\nremote_relay_url = \"  wss://x/connect \"\nremote_viewer_max_viewers = 40\n",
        );
        assert_eq!(loaded.relay_url, "wss://x/connect");
        assert_eq!(loaded.viewer_max, 10);
        assert!(!loaded.enabled);
    }
}
