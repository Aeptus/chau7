//! Read-only remote viewing (`Remote/RemoteViewerMode.swift`).
//!
//! The owner shares a link, approves or denies each viewer that connects,
//! can trust a viewer (approved automatically next time when
//! "auto-approve known viewers" is on), revoke it, or disconnect it. Viewers
//! see output but never send input. The Swift app never wired this feature;
//! this follows its design and its tests (`RemoteViewerModeTests`): a viewer
//! arriving while the maximum is reached is turned away.

use std::collections::BTreeSet;

use chrono::{DateTime, Utc};

/// Allowed range of `remoteViewer.maxViewers`.
pub const MAX_VIEWERS_RANGE: std::ops::RangeInclusive<u32> = 1..=10;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ViewerStatus {
    Pending,
    Connected,
    Disconnected,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RemoteViewer {
    pub id: String,
    pub name: String,
    pub status: ViewerStatus,
    pub connected_at: Option<DateTime<Utc>>,
}

impl RemoteViewer {
    pub fn new(id: impl Into<String>, name: impl Into<String>) -> Self {
        Self {
            id: id.into(),
            name: name.into(),
            status: ViewerStatus::Pending,
            connected_at: None,
        }
    }

    /// `m:ss` since the viewer was approved; empty before that.
    pub fn connection_duration(&self, now: DateTime<Utc>) -> String {
        let Some(start) = self.connected_at else {
            return String::new();
        };
        let elapsed = (now - start).num_seconds().max(0);
        format!("{}:{:02}", elapsed / 60, elapsed % 60)
    }
}

/// What happened to an incoming viewer.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ViewerArrival {
    /// Known and trusted: connected at once.
    AutoApproved,
    /// Waits for the owner (approve or deny).
    Pending,
    /// The maximum number of viewers is reached.
    Rejected,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RemoteViewerMode {
    /// `feature.remoteViewer`.
    pub enabled: bool,
    pub is_sharing: bool,
    pub connected: Vec<RemoteViewer>,
    pub pending: Vec<RemoteViewer>,
    pub share_link: Option<String>,
    /// `remoteViewer.maxViewers`, kept in [`MAX_VIEWERS_RANGE`].
    max_viewers: u32,
    /// `remoteViewer.autoApproveKnown`.
    pub auto_approve_known: bool,
    /// `remoteViewer.knownIDs`.
    pub known_ids: BTreeSet<String>,
}

impl Default for RemoteViewerMode {
    fn default() -> Self {
        Self {
            enabled: false,
            is_sharing: false,
            connected: Vec::new(),
            pending: Vec::new(),
            share_link: None,
            // Swift reads an unset integer default (0) clamped to 1.
            max_viewers: 1,
            auto_approve_known: false,
            known_ids: BTreeSet::new(),
        }
    }
}

impl RemoteViewerMode {
    pub fn max_viewers(&self) -> u32 {
        self.max_viewers
    }

    pub fn set_max_viewers(&mut self, value: i64) {
        let (lo, hi) = (*MAX_VIEWERS_RANGE.start(), *MAX_VIEWERS_RANGE.end());
        self.max_viewers = value.clamp(i64::from(lo), i64::from(hi)) as u32;
    }

    /// Start sharing with a new link `<scheme>://view/<8 chars>`. Does
    /// nothing while the feature is off.
    pub fn start_sharing(&mut self, scheme: &str, token: &str) -> bool {
        if !self.enabled {
            log::warn!("RemoteViewerMode: cannot start sharing, not enabled");
            return false;
        }
        let token: String = token.chars().take(8).collect::<String>().to_lowercase();
        self.share_link = Some(format!("{scheme}://view/{token}"));
        self.is_sharing = true;
        true
    }

    /// The 8 characters at the end of the share link (what a viewer types).
    pub fn share_code(&self) -> Option<&str> {
        self.share_link
            .as_deref()
            .and_then(|link| link.rsplit_once("/view/"))
            .map(|(_, code)| code)
    }

    /// Stop sharing: every viewer is disconnected and pending ones dropped.
    pub fn stop_sharing(&mut self) {
        self.connected.clear();
        self.pending.clear();
        self.share_link = None;
        self.is_sharing = false;
    }

    pub fn approve(&mut self, id: &str, now: DateTime<Utc>) -> bool {
        let Some(index) = self.pending.iter().position(|v| v.id == id) else {
            return false;
        };
        if self.connected.len() >= self.max_viewers as usize {
            log::warn!(
                "RemoteViewerMode: cannot approve viewer {id}, max viewers ({}) reached",
                self.max_viewers
            );
            return false;
        }
        let mut viewer = self.pending.remove(index);
        viewer.status = ViewerStatus::Connected;
        viewer.connected_at = Some(now);
        self.connected.push(viewer);
        true
    }

    pub fn deny(&mut self, id: &str) {
        self.pending.retain(|v| v.id != id);
    }

    pub fn disconnect(&mut self, id: &str) {
        self.connected.retain(|v| v.id != id);
    }

    pub fn trust(&mut self, id: &str) {
        self.known_ids.insert(id.to_string());
    }

    pub fn revoke(&mut self, id: &str) {
        self.known_ids.remove(id);
        self.disconnect(id);
    }

    /// A viewer asks to watch.
    pub fn handle_connection(&mut self, id: &str, name: &str, now: DateTime<Utc>) -> ViewerArrival {
        if self.connected.len() >= self.max_viewers as usize {
            log::warn!("RemoteViewerMode: rejected viewer {id}, max viewers reached");
            return ViewerArrival::Rejected;
        }
        let mut viewer = RemoteViewer::new(id, name);
        if self.auto_approve_known && self.known_ids.contains(id) {
            viewer.status = ViewerStatus::Connected;
            viewer.connected_at = Some(now);
            self.connected.push(viewer);
            ViewerArrival::AutoApproved
        } else {
            self.pending.push(viewer);
            ViewerArrival::Pending
        }
    }

    /// Whether output should go to viewers (`broadcastToViewers` guard).
    pub fn should_broadcast(&self) -> bool {
        self.is_sharing && !self.connected.is_empty()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::TimeZone;

    fn now() -> DateTime<Utc> {
        Utc.timestamp_opt(1_700_000_000, 0).unwrap()
    }

    fn sharing() -> RemoteViewerMode {
        let mut mode = RemoteViewerMode {
            enabled: true,
            ..Default::default()
        };
        mode.set_max_viewers(10);
        assert!(mode.start_sharing("chau7-next", "ABCDEF12-3456"));
        mode
    }

    #[test]
    fn pending_then_approved() {
        let mut mode = sharing();
        assert_eq!(
            mode.handle_connection("viewer-1", "Alice", now()),
            ViewerArrival::Pending
        );
        assert_eq!(mode.pending.len(), 1);
        assert_eq!(mode.pending[0].status, ViewerStatus::Pending);
        assert!(mode.approve("viewer-1", now()));
        assert!(mode.pending.is_empty());
        assert_eq!(mode.connected[0].status, ViewerStatus::Connected);
        assert!(mode.connected[0].connected_at.is_some());
    }

    #[test]
    fn deny_and_disconnect_unknown_ids_are_noops() {
        let mut mode = sharing();
        mode.handle_connection("viewer-1", "Alice", now());
        mode.deny("viewer-nonexistent");
        assert_eq!(mode.pending.len(), 1);
        mode.deny("viewer-1");
        assert!(mode.pending.is_empty());
        mode.handle_connection("viewer-2", "Bob", now());
        mode.approve("viewer-2", now());
        mode.disconnect("viewer-nonexistent");
        assert_eq!(mode.connected.len(), 1);
        mode.disconnect("viewer-2");
        assert!(mode.connected.is_empty());
        assert!(!mode.approve("nonexistent", now()));
    }

    #[test]
    fn max_viewers_rejects_new_arrivals() {
        let mut mode = sharing();
        mode.set_max_viewers(2);
        for id in ["viewer-1", "viewer-2"] {
            mode.handle_connection(id, id, now());
            mode.approve(id, now());
        }
        assert_eq!(
            mode.handle_connection("viewer-3", "Charlie", now()),
            ViewerArrival::Rejected
        );
        assert_eq!(mode.connected.len(), 2);
        assert!(mode.pending.is_empty());
        mode.set_max_viewers(50);
        assert_eq!(mode.max_viewers(), 10);
        mode.set_max_viewers(0);
        assert_eq!(mode.max_viewers(), 1);
    }

    #[test]
    fn known_viewers_are_auto_approved_only_when_enabled() {
        let mut mode = sharing();
        mode.trust("viewer-1");
        assert_eq!(
            mode.handle_connection("viewer-1", "Alice", now()),
            ViewerArrival::Pending
        );
        mode.stop_sharing();
        mode.start_sharing("chau7-next", "token");
        mode.auto_approve_known = true;
        assert_eq!(
            mode.handle_connection("viewer-1", "Alice", now()),
            ViewerArrival::AutoApproved
        );
        assert_eq!(
            mode.handle_connection("viewer-unknown", "Unknown", now()),
            ViewerArrival::Pending
        );
    }

    #[test]
    fn revoke_forgets_and_disconnects() {
        let mut mode = sharing();
        mode.trust("viewer-1");
        mode.trust("viewer-2");
        assert_eq!(mode.known_ids.len(), 2);
        mode.handle_connection("viewer-1", "Alice", now());
        mode.approve("viewer-1", now());
        mode.revoke("viewer-1");
        assert!(!mode.known_ids.contains("viewer-1"));
        assert!(mode.connected.is_empty());
    }

    #[test]
    fn share_link_lifecycle() {
        let mut mode = sharing();
        assert_eq!(
            mode.share_link.as_deref(),
            Some("chau7-next://view/abcdef12")
        );
        mode.handle_connection("viewer-1", "Alice", now());
        mode.approve("viewer-1", now());
        assert!(mode.should_broadcast());
        mode.stop_sharing();
        assert!(mode.share_link.is_none());
        assert!(!mode.is_sharing);
        assert!(mode.connected.is_empty());

        let mut off = RemoteViewerMode::default();
        assert!(!off.start_sharing("chau7-next", "x"));
        assert!(off.share_link.is_none());
    }

    #[test]
    fn duration_is_minutes_and_seconds() {
        let mut viewer = RemoteViewer::new("v", "V");
        assert_eq!(viewer.connection_duration(now()), "");
        viewer.connected_at = Some(now());
        assert_eq!(
            viewer.connection_duration(now() + chrono::Duration::seconds(125)),
            "2:05"
        );
    }
}
