//! Current macOS permission evidence; bookmarks and Full Disk Access are distinct.
use serde::{Deserialize, Serialize};
use std::{
    io,
    path::{Path, PathBuf},
};
pub const FDA_CANARIES: [&str; 3] = [
    "Library/Application Support/com.apple.TCC/TCC.db",
    "Library/Safari/Bookmarks.plist",
    "Library/Cookies/Cookies.binarycookies",
];
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum FullDiskAccess {
    Granted,
    Denied,
    #[default]
    Indeterminate,
}
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AccessResult {
    Ok,
    Denied,
    Missing,
    OtherError,
}
pub fn evaluate_full_disk_access(
    home: &Path,
    canaries: &[&str],
    mut accessor: impl FnMut(&Path) -> AccessResult,
) -> FullDiskAccess {
    let mut denied = false;
    for relative in canaries {
        match accessor(&home.join(relative)) {
            AccessResult::Ok => return FullDiskAccess::Granted,
            AccessResult::Denied => denied = true,
            AccessResult::Missing | AccessResult::OtherError => {}
        }
    }
    if denied {
        FullDiskAccess::Denied
    } else {
        FullDiskAccess::Indeterminate
    }
}
/// Open only; neither read canary contents nor infer permission from file existence.
pub fn open_canary(path: &Path) -> AccessResult {
    match std::fs::File::open(path) {
        Ok(_) => AccessResult::Ok,
        Err(error) => match error.kind() {
            io::ErrorKind::PermissionDenied => AccessResult::Denied,
            io::ErrorKind::NotFound | io::ErrorKind::NotADirectory => AccessResult::Missing,
            _ => AccessResult::OtherError,
        },
    }
}
pub fn probe_full_disk_access(home: &Path) -> FullDiskAccess {
    if cfg!(target_os = "macos") {
        evaluate_full_disk_access(home, &FDA_CANARIES, open_canary)
    } else {
        FullDiskAccess::Indeterminate
    }
}
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ProtectedState {
    Unprotected,
    AvailableActiveScope,
    AvailableBookmarkedScope,
    BlockedFeatureDisabled,
    BlockedNeedsExplicitGrant,
    BlockedCooldown,
    BlockedStaleBookmark,
}
impl ProtectedState {
    pub fn label(self) -> &'static str {
        match self {
            Self::Unprotected => "Not Protected",
            Self::AvailableActiveScope => "Granted",
            Self::AvailableBookmarkedScope => "Granted by Bookmark",
            Self::BlockedFeatureDisabled => "Disabled",
            Self::BlockedNeedsExplicitGrant => "Needs Access",
            Self::BlockedCooldown => "Retry Later",
            Self::BlockedStaleBookmark => "Needs Re-Grant",
        }
    }
}
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum RecommendedAction {
    None,
    EnableFeature,
    GrantAccess,
    WaitForCooldown,
    RegrantAccess,
}
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProtectedSnapshot {
    pub root: Option<PathBuf>,
    pub state: ProtectedState,
    pub can_probe_live: bool,
    pub can_use_known_identity: bool,
    pub has_known_identity: bool,
    pub recommended_action: RecommendedAction,
}
#[derive(Debug, Clone, Copy, Default)]
pub struct ProtectedEvidence {
    pub feature_enabled: bool,
    pub active_scope: bool,
    pub bookmark: bool,
    pub denied_by_cooldown: bool,
    pub known_identity: bool,
    pub bookmark_resolve_failed: bool,
}
pub fn protected_snapshot(root: Option<PathBuf>, evidence: ProtectedEvidence) -> ProtectedSnapshot {
    let (state, action) = if root.is_none() {
        (ProtectedState::Unprotected, RecommendedAction::None)
    } else if evidence.active_scope {
        (
            ProtectedState::AvailableActiveScope,
            RecommendedAction::None,
        )
    } else if !evidence.feature_enabled {
        (
            ProtectedState::BlockedFeatureDisabled,
            RecommendedAction::EnableFeature,
        )
    } else if evidence.bookmark_resolve_failed {
        (
            ProtectedState::BlockedStaleBookmark,
            RecommendedAction::RegrantAccess,
        )
    } else if evidence.denied_by_cooldown {
        (
            ProtectedState::BlockedCooldown,
            RecommendedAction::WaitForCooldown,
        )
    } else if evidence.bookmark {
        (
            ProtectedState::AvailableBookmarkedScope,
            RecommendedAction::None,
        )
    } else {
        (
            ProtectedState::BlockedNeedsExplicitGrant,
            RecommendedAction::GrantAccess,
        )
    };
    let has_known_identity = root.is_some() && evidence.known_identity;
    ProtectedSnapshot {
        root,
        state,
        can_probe_live: matches!(
            state,
            ProtectedState::Unprotected
                | ProtectedState::AvailableActiveScope
                | ProtectedState::AvailableBookmarkedScope
        ),
        can_use_known_identity: has_known_identity,
        has_known_identity,
        recommended_action: action,
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn readable_canary_wins_denial_and_missing_is_unknown() {
        let mut answers = [
            AccessResult::Denied,
            AccessResult::Missing,
            AccessResult::Ok,
        ]
        .into_iter();
        let mut seen = Vec::new();
        assert_eq!(
            evaluate_full_disk_access(Path::new("/home/me/"), &FDA_CANARIES, |path| {
                seen.push(path.to_path_buf());
                answers.next().unwrap()
            }),
            FullDiskAccess::Granted
        );
        assert_eq!(seen[0], Path::new("/home/me").join(FDA_CANARIES[0]));
        assert_eq!(
            evaluate_full_disk_access(Path::new("/home/me"), &FDA_CANARIES, |_| {
                AccessResult::Missing
            }),
            FullDiskAccess::Indeterminate
        );
        assert_eq!(
            evaluate_full_disk_access(Path::new("/home/me"), &FDA_CANARIES, |_| {
                AccessResult::OtherError
            }),
            FullDiskAccess::Indeterminate
        );
        assert_eq!(
            evaluate_full_disk_access(Path::new("/home/me"), &FDA_CANARIES, |_| {
                AccessResult::Denied
            }),
            FullDiskAccess::Denied
        );
    }
    #[test]
    fn snapshot_precedence_and_cached_identity_match_current_policy() {
        let root = Some(PathBuf::from("/home/me/Documents"));
        let mut e = ProtectedEvidence {
            feature_enabled: true,
            known_identity: true,
            ..Default::default()
        };
        assert_eq!(
            protected_snapshot(root.clone(), e).state,
            ProtectedState::BlockedNeedsExplicitGrant
        );
        e.bookmark = true;
        assert!(protected_snapshot(root.clone(), e).can_probe_live);
        e.denied_by_cooldown = true;
        assert_eq!(
            protected_snapshot(root.clone(), e).state,
            ProtectedState::BlockedCooldown
        );
        e.bookmark_resolve_failed = true;
        assert_eq!(
            protected_snapshot(root.clone(), e).state,
            ProtectedState::BlockedStaleBookmark
        );
        e.feature_enabled = false;
        assert_eq!(
            protected_snapshot(root.clone(), e).state,
            ProtectedState::BlockedFeatureDisabled
        );
        e.active_scope = true;
        assert_eq!(
            protected_snapshot(root.clone(), e).state,
            ProtectedState::AvailableActiveScope
        );
        e.active_scope = false;
        let blocked = protected_snapshot(root, e);
        assert!(blocked.can_use_known_identity);
        assert!(!blocked.can_probe_live);
        let unprotected = protected_snapshot(None, e);
        assert!(unprotected.can_probe_live);
        assert!(!unprotected.has_known_identity);
    }
    #[test]
    fn every_state_has_correct_action_and_stable_camel_case_json() {
        for (e, state, action) in [
            (
                ProtectedEvidence::default(),
                ProtectedState::BlockedFeatureDisabled,
                RecommendedAction::EnableFeature,
            ),
            (
                ProtectedEvidence {
                    feature_enabled: true,
                    ..Default::default()
                },
                ProtectedState::BlockedNeedsExplicitGrant,
                RecommendedAction::GrantAccess,
            ),
            (
                ProtectedEvidence {
                    feature_enabled: true,
                    denied_by_cooldown: true,
                    ..Default::default()
                },
                ProtectedState::BlockedCooldown,
                RecommendedAction::WaitForCooldown,
            ),
            (
                ProtectedEvidence {
                    feature_enabled: true,
                    bookmark_resolve_failed: true,
                    ..Default::default()
                },
                ProtectedState::BlockedStaleBookmark,
                RecommendedAction::RegrantAccess,
            ),
            (
                ProtectedEvidence {
                    feature_enabled: true,
                    bookmark: true,
                    ..Default::default()
                },
                ProtectedState::AvailableBookmarkedScope,
                RecommendedAction::None,
            ),
            (
                ProtectedEvidence {
                    active_scope: true,
                    ..Default::default()
                },
                ProtectedState::AvailableActiveScope,
                RecommendedAction::None,
            ),
        ] {
            let snapshot = protected_snapshot(Some(PathBuf::from("/root")), e);
            assert_eq!(snapshot.state, state);
            assert_eq!(snapshot.recommended_action, action);
            let value = serde_json::to_value(&snapshot).unwrap();
            assert!(value.get("canProbeLive").is_some());
            assert_eq!(
                serde_json::from_value::<ProtectedSnapshot>(value).unwrap(),
                snapshot
            );
        }
    }
}

#[cfg(test)]
mod cooldown_tests {
    #[test]
    fn denial_evidence_is_read_without_invoking_accessors_and_expires() {
        let mut policy = crate::protected_path::AccessPolicy::default();
        assert!(!policy.denied_by_cooldown("/root", 10.0));
        policy.mark_denied("/root", 10.0);
        assert!(policy.denied_by_cooldown("/root", 309.0));
        assert!(!policy.denied_by_cooldown("/root", 310.0));
        policy.grant("/root");
        assert!(!policy.denied_by_cooldown("/root", 20.0));
        policy.mark_denied("/root", 30.0);
        policy.reset();
        assert!(!policy.denied_by_cooldown("/root", 40.0));
    }
}

pub const FDA_ALERT_MIN_INTERVAL: f64 = 300.0;
pub const DENIAL_MARKERS: [&str; 4] = ["operation not permitted", "os error 1", "eperm", "errno 1"];
/// Both an EPERM-family marker and a component-matched protected cwd are required.
pub fn denial_root(output: &str, cwd: &str, protected_roots: &[String]) -> Option<String> {
    let cwd = cwd.trim().trim_end_matches('/');
    let root = protected_roots.iter().find(|root| {
        let base = root.trim().trim_end_matches('/');
        !base.is_empty()
            && (cwd == base
                || cwd
                    .strip_prefix(base)
                    .is_some_and(|tail| tail.starts_with('/')))
    })?;
    let lowered = output.to_lowercase();
    DENIAL_MARKERS
        .iter()
        .any(|marker| lowered.contains(marker))
        .then(|| root.to_owned())
}
#[derive(Debug, Default)]
pub struct FullDiskAccessGuard {
    pub status: FullDiskAccess,
    last_alert_at: Option<f64>,
}
impl FullDiskAccessGuard {
    /// Reactive ambiguity keeps the last known guard status, while the UI probe
    /// still reports its actual fresh result separately.
    pub fn reconcile(&mut self, status: FullDiskAccess, child_denial: bool) {
        if !child_denial || status != FullDiskAccess::Indeterminate {
            self.status = status;
        }
    }
    pub fn should_alert(&self, status: FullDiskAccess, child_denial: bool, now: f64) -> bool {
        let actionable = status == FullDiskAccess::Denied
            || (child_denial && status == FullDiskAccess::Indeterminate);
        actionable
            && self
                .last_alert_at
                .is_none_or(|last| now - last >= FDA_ALERT_MIN_INTERVAL)
    }
    /// Only record a successfully presented alert, not an attempt without a window.
    pub fn record_alert(&mut self, now: f64) {
        self.last_alert_at = Some(now);
    }
}
#[cfg(test)]
mod guard_tests {
    use super::*;
    #[test]
    fn denial_classifier_requires_two_signals_and_component_boundaries() {
        let roots = vec![
            "/Users/test/Downloads".into(),
            "/Users/test/Documents".into(),
        ];
        for marker in DENIAL_MARKERS {
            assert_eq!(
                denial_root(
                    &marker.to_uppercase(),
                    " /Users/test/Downloads/repo/ ",
                    &roots
                ),
                Some(roots[0].clone())
            );
            assert_eq!(
                denial_root(marker, "/Users/test/Downloads2/repo", &roots),
                None
            );
            assert_eq!(denial_root(marker, "/tmp/repo", &roots), None);
        }
        assert_eq!(
            denial_root("ordinary failure", "/Users/test/Downloads/repo", &roots),
            None
        );
        assert_eq!(
            denial_root("EPERM", "/Users/test/Documents", &roots),
            Some(roots[1].clone())
        );
        assert_eq!(denial_root("EPERM", "/root", &["".into()]), None);
    }
    #[test]
    fn proactive_unknown_never_alerts_and_reactive_granted_is_not_misattributed() {
        let mut guard = FullDiskAccessGuard::default();
        assert!(!guard.should_alert(FullDiskAccess::Indeterminate, false, 1.0));
        assert!(!guard.should_alert(FullDiskAccess::Granted, true, 1.0));
        assert!(guard.should_alert(FullDiskAccess::Indeterminate, true, 1.0));
        guard.reconcile(FullDiskAccess::Denied, false);
        guard.reconcile(FullDiskAccess::Indeterminate, true);
        assert_eq!(guard.status, FullDiskAccess::Denied);
        guard.reconcile(FullDiskAccess::Granted, true);
        assert_eq!(guard.status, FullDiskAccess::Granted);
    }
    #[test]
    fn throttle_covers_all_sources_and_includes_exact_five_minute_boundary() {
        let mut guard = FullDiskAccessGuard::default();
        assert!(guard.should_alert(FullDiskAccess::Denied, false, 10.0));
        guard.record_alert(10.0);
        assert!(!guard.should_alert(FullDiskAccess::Denied, true, 309.9));
        assert!(guard.should_alert(FullDiskAccess::Denied, true, 310.0));
        assert!(!guard.should_alert(FullDiskAccess::Denied, true, 0.0));
    }
}

pub const DENIAL_OUTPUT_TAIL_BYTES: usize = 16 * 1024;
#[derive(Default)]
pub struct PermissionOutputTail(std::collections::VecDeque<u8>);
impl PermissionOutputTail {
    pub fn push(&mut self, bytes: &[u8]) {
        if bytes.len() >= DENIAL_OUTPUT_TAIL_BYTES {
            self.0.clear();
            self.0
                .extend(&bytes[bytes.len() - DENIAL_OUTPUT_TAIL_BYTES..]);
            return;
        }
        let excess = (self.0.len() + bytes.len()).saturating_sub(DENIAL_OUTPUT_TAIL_BYTES);
        self.0.drain(..excess);
        self.0.extend(bytes);
    }
    pub fn text(&self) -> String {
        String::from_utf8_lossy(&self.0.iter().copied().collect::<Vec<_>>()).into_owned()
    }
}
#[cfg(test)]
mod tail_tests {
    use super::*;
    #[test]
    fn raw_pty_tail_is_bounded_and_retains_latest_split_marker() {
        let mut tail = PermissionOutputTail::default();
        tail.push(&vec![b'x'; DENIAL_OUTPUT_TAIL_BYTES + 100]);
        assert_eq!(tail.0.len(), DENIAL_OUTPUT_TAIL_BYTES);
        tail.push(b"\nOperation not ");
        tail.push(b"permitted\n");
        assert_eq!(tail.0.len(), DENIAL_OUTPUT_TAIL_BYTES);
        assert!(tail.text().ends_with("Operation not permitted\n"));
        tail.push(&vec![b'y'; DENIAL_OUTPUT_TAIL_BYTES]);
        assert!(!tail.text().contains("Operation not permitted"));
        tail.push(&[0xff]);
        assert!(tail.text().ends_with('\u{fffd}'));
    }
}
