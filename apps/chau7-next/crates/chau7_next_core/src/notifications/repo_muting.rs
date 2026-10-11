//! Current per-repository notification mute/snooze gate. No filesystem probes.
use std::{
    collections::BTreeMap,
    path::{Component, Path, PathBuf},
};

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct RepoMute {
    /// Swift Codable Date seconds since 2001, nil means indefinite.
    #[serde(
        default,
        rename = "snoozeUntil",
        with = "crate::iso8601::reference_date_opt",
        skip_serializing_if = "Option::is_none"
    )]
    pub snooze_until: Option<DateTime<Utc>>,
}

impl RepoMute {
    pub fn is_active(&self, now: DateTime<Utc>) -> bool {
        self.snooze_until.is_none_or(|until| now < until)
    }
}

pub type MutedRepos = BTreeMap<String, RepoMute>;

/// Resolve lexical dot components with native separators, without touching a
/// potentially protected/offline repository. Empty paths never match.
pub fn normalized_root(raw: &str) -> Option<PathBuf> {
    let raw = raw.trim();
    if raw.is_empty() {
        return None;
    }
    let mut path = PathBuf::new();
    for component in Path::new(raw).components() {
        match component {
            Component::CurDir => {}
            Component::ParentDir => {
                path.pop();
            }
            value => path.push(value.as_os_str()),
        }
    }
    if path.as_os_str().is_empty() {
        return None;
    }
    #[cfg(windows)]
    {
        path = PathBuf::from(path.to_string_lossy().to_lowercase());
    }
    Some(path)
}

pub fn is_muted(
    repo_path: Option<&str>,
    directory: Option<&str>,
    muted: &MutedRepos,
    now: DateTime<Utc>,
) -> bool {
    let repo = repo_path.and_then(normalized_root);
    let directory = directory.and_then(normalized_root);
    muted.iter().any(|(root, mute)| {
        if !mute.is_active(now) {
            return false;
        }
        let Some(root) = normalized_root(root) else {
            return false;
        };
        repo.as_ref().is_some_and(|repo| *repo == root)
            || directory
                .as_ref()
                .is_some_and(|directory| directory.starts_with(&root))
    })
}

/// Return whether expiry pruning changed the durable dictionary.
pub fn prune(muted: &mut MutedRepos, now: DateTime<Utc>) -> bool {
    let old = muted.len();
    muted.retain(|_, mute| mute.is_active(now));
    old != muted.len()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn now() -> DateTime<Utc> {
        DateTime::from_timestamp(1_751_000_000, 0).unwrap()
    }

    #[test]
    fn indefinite_mute_matches_repo_or_directory_component_boundary() {
        let muted = MutedRepos::from([("/repo/mockup".into(), RepoMute::default())]);
        assert!(is_muted(Some("/repo/mockup"), None, &muted, now()));
        for directory in ["/repo/mockup", "/repo/mockup/src", "/repo/mockup/./src"] {
            assert!(is_muted(None, Some(directory), &muted, now()));
        }
        for directory in ["/repo/mockup-sibling", "/repo/mockup/../other", ""] {
            assert!(!is_muted(None, Some(directory), &muted, now()));
        }
        assert!(!is_muted(Some("/repo/mockup/src"), None, &muted, now()));
        assert!(!is_muted(None, None, &muted, now()));
    }

    #[test]
    fn snooze_boundary_and_prune_are_deterministic() {
        let deadline = now() + chrono::Duration::hours(1);
        let mut muted = MutedRepos::from([
            (
                "/expired".into(),
                RepoMute {
                    snooze_until: Some(now()),
                },
            ),
            (
                "/active".into(),
                RepoMute {
                    snooze_until: Some(deadline),
                },
            ),
            ("/indefinite".into(), RepoMute::default()),
        ]);
        assert!(is_muted(
            Some("/active"),
            None,
            &muted,
            deadline - chrono::Duration::milliseconds(1)
        ));
        assert!(!is_muted(Some("/active"), None, &muted, deadline));
        assert!(prune(&mut muted, now()));
        assert!(!prune(&mut muted, now()));
        assert_eq!(
            muted.keys().map(String::as_str).collect::<Vec<_>>(),
            ["/active", "/indefinite"]
        );
        assert!(prune(&mut muted, deadline));
        assert_eq!(
            muted.keys().map(String::as_str).collect::<Vec<_>>(),
            ["/indefinite"]
        );
    }

    #[test]
    fn swift_codable_dates_roundtrip_and_missing_snooze_is_indefinite() {
        let indefinite: RepoMute = serde_json::from_str("{}").unwrap();
        assert!(indefinite.is_active(now()));
        assert_eq!(serde_json::to_string(&indefinite).unwrap(), "{}");
        let timed = RepoMute {
            snooze_until: Some(now()),
        };
        let value = serde_json::to_value(&timed).unwrap();
        assert!(value["snoozeUntil"].is_number());
        assert_eq!(serde_json::from_value::<RepoMute>(value).unwrap(), timed);
    }

    #[cfg(windows)]
    #[test]
    fn native_windows_roots_match_case_and_component_boundaries() {
        let muted = MutedRepos::from([(r"C:\Repo\Project".into(), RepoMute::default())]);
        assert!(is_muted(None, Some(r"c:\repo\project\src"), &muted, now()));
        assert!(!is_muted(
            None,
            Some(r"c:\repo\project-neighbor"),
            &muted,
            now()
        ));
    }
}
