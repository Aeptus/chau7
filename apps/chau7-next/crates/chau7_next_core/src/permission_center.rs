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
