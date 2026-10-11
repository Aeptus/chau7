//! Viewer frames between Chau7 Next and the `chau7-remote` agent (RMT-027).
//! The wire format is described in `docs/remote-control/VIEWER-PROTOCOL.md`
//! and implemented on the agent side in
//! `services/chau7-remote/internal/agent/viewer.go`.
//!
//! The app tells the agent the share code ([`ViewerSharePayload`]); the
//! agent checks each viewer's code and passes valid joins on
//! ([`ViewerJoinPayload`]); the app answers with a decision
//! ([`ViewerDecisionPayload`]) or ends a viewing ([`ViewerLeavePayload`]).
//! The agent copies terminal output to approved viewers itself and never
//! takes input from them.

use serde::{Deserialize, Serialize};

use super::frame::RemoteFrameType;
use super::viewer::RemoteViewerMode;

/// `viewer_share` (app to agent): the code of the share link, or `None`
/// to stop sharing (every viewer is dropped).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ViewerSharePayload {
    pub share_code: Option<String>,
    pub max_viewers: u32,
}

/// `viewer_join` (agent to app): a viewer with a valid code asks to watch.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ViewerJoinPayload {
    pub viewer_id: String,
    #[serde(default)]
    pub name: String,
    #[serde(default)]
    pub share_code: String,
}

/// `viewer_decision` (app to agent): the owner approved or denied a viewer.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ViewerDecisionPayload {
    pub viewer_id: String,
    pub approved: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reason: Option<String>,
}

/// `viewer_leave` (both ways): a viewing ended.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ViewerLeavePayload {
    pub viewer_id: String,
}

/// A frame to send: its type and JSON payload.
pub type ViewerFrame = (RemoteFrameType, Vec<u8>);

fn json<T: Serialize>(kind: RemoteFrameType, payload: &T) -> ViewerFrame {
    (kind, serde_json::to_vec(payload).unwrap_or_default())
}

/// The `viewer_share` frame for the current state.
pub fn share_frame(mode: &RemoteViewerMode) -> ViewerFrame {
    json(
        RemoteFrameType::ViewerShare,
        &ViewerSharePayload {
            share_code: mode
                .is_sharing
                .then(|| mode.share_code().map(str::to_string))
                .flatten(),
            max_viewers: mode.max_viewers(),
        },
    )
}

/// A decision frame.
pub fn decision_frame(viewer_id: &str, approved: bool, reason: Option<&str>) -> ViewerFrame {
    json(
        RemoteFrameType::ViewerDecision,
        &ViewerDecisionPayload {
            viewer_id: viewer_id.to_string(),
            approved,
            reason: reason.map(str::to_string),
        },
    )
}

/// A leave frame.
pub fn leave_frame(viewer_id: &str) -> ViewerFrame {
    json(
        RemoteFrameType::ViewerLeave,
        &ViewerLeavePayload {
            viewer_id: viewer_id.to_string(),
        },
    )
}

/// What the agent must hear after the owner changed the viewer state
/// (start or stop sharing, approve, deny, disconnect, revoke).
pub fn sync_frames(before: &RemoteViewerMode, after: &RemoteViewerMode) -> Vec<ViewerFrame> {
    let mut frames = Vec::new();
    if before.is_sharing != after.is_sharing
        || before.share_link != after.share_link
        || before.max_viewers() != after.max_viewers()
    {
        frames.push(share_frame(after));
    }
    let connected_after = |id: &str| after.connected.iter().any(|v| v.id == id);
    let pending_after = |id: &str| after.pending.iter().any(|v| v.id == id);
    for viewer in &before.pending {
        if connected_after(&viewer.id) {
            frames.push(decision_frame(&viewer.id, true, None));
        } else if !pending_after(&viewer.id) {
            frames.push(decision_frame(&viewer.id, false, Some("denied")));
        }
    }
    // Stopping the share drops everyone at the agent already.
    if after.is_sharing {
        for viewer in &before.connected {
            if !connected_after(&viewer.id) {
                frames.push(leave_frame(&viewer.id));
            }
        }
    }
    frames
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::{TimeZone, Utc};

    fn sharing() -> RemoteViewerMode {
        let mut mode = RemoteViewerMode::default();
        mode.enabled = true;
        mode.set_max_viewers(3);
        assert!(mode.start_sharing("chau7-next", "ABCDEF12-3456"));
        mode
    }

    fn decode<T: serde::de::DeserializeOwned>(frame: &ViewerFrame) -> T {
        serde_json::from_slice(&frame.1).unwrap()
    }

    #[test]
    fn share_frame_carries_the_code_and_maximum() {
        let mode = sharing();
        let frame = share_frame(&mode);
        assert_eq!(frame.0, RemoteFrameType::ViewerShare);
        let payload: ViewerSharePayload = decode(&frame);
        assert_eq!(payload.share_code.as_deref(), Some("abcdef12"));
        assert_eq!(payload.max_viewers, 3);
        let stopped: ViewerSharePayload = decode(&share_frame(&RemoteViewerMode::default()));
        assert_eq!(stopped.share_code, None);
    }

    #[test]
    fn sync_reports_decisions_and_leaves() {
        let now = Utc.timestamp_opt(1_700_000_000, 0).unwrap();
        let mut before = sharing();
        before.handle_connection("a", "Ann", now);
        before.handle_connection("b", "Bob", now);
        before.handle_connection("c", "Cy", now);
        assert!(before.approve("c", now));
        let mut after = before.clone();
        assert!(after.approve("a", now));
        after.deny("b");
        after.disconnect("c");
        let frames = sync_frames(&before, &after);
        assert_eq!(frames.len(), 3);
        let a: ViewerDecisionPayload = decode(&frames[0]);
        assert!(a.approved && a.viewer_id == "a");
        let b: ViewerDecisionPayload = decode(&frames[1]);
        assert!(!b.approved && b.viewer_id == "b");
        assert_eq!(frames[2].0, RemoteFrameType::ViewerLeave);
    }

    #[test]
    fn stopping_sends_only_the_share_frame() {
        let now = Utc.timestamp_opt(1_700_000_000, 0).unwrap();
        let mut before = sharing();
        before.handle_connection("a", "Ann", now);
        before.approve("a", now);
        let mut after = before.clone();
        after.stop_sharing();
        let frames = sync_frames(&before, &after);
        assert_eq!(frames.len(), 1);
        assert_eq!(frames[0].0, RemoteFrameType::ViewerShare);
    }

    #[test]
    fn join_payload_tolerates_missing_fields() {
        let join: ViewerJoinPayload = serde_json::from_str(r#"{"viewer_id":"v1"}"#).unwrap();
        assert_eq!(join.viewer_id, "v1");
        assert!(join.name.is_empty());
    }
}
