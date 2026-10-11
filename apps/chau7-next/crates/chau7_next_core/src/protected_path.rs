//! Folders macOS guards with a privacy prompt (`ProtectedPathPolicy.swift`).
//! Background repo detection must not touch them unless the user allows it,
//! or the prompt appears for no visible reason.

use std::collections::{HashMap, HashSet};

/// How long a folder that denied access is left alone (`denyCooldown`).
pub const DENY_COOLDOWN_SECONDS: f64 = 300.0;

/// The protected roots for a home folder.
pub fn protected_roots(home: &str) -> Vec<String> {
    let home = home.trim_end_matches('/');
    vec![
        format!("{home}/Downloads"),
        format!("{home}/Desktop"),
        format!("{home}/Documents"),
        format!("{home}/Library"),
        "/Applications".to_string(),
        "/System".to_string(),
        "/Library".to_string(),
    ]
}

/// Resolve `.` and `..` segments without touching the disk.
fn standardize(path: &str) -> String {
    let mut parts: Vec<&str> = Vec::new();
    for part in path.split('/') {
        match part {
            "" | "." => {}
            ".." => {
                parts.pop();
            }
            other => parts.push(other),
        }
    }
    format!("/{}", parts.join("/"))
}

/// The protected root that contains `path` (or is it), if any.
pub fn protected_root_for(path: &str, home: &str) -> Option<String> {
    let normalized = standardize(path);
    protected_roots(home)
        .into_iter()
        .find(|root| normalized == *root || normalized.starts_with(&format!("{root}/")))
}

/// What the policy remembers between checks (`stateQueue` state).
#[derive(Debug, Default)]
pub struct AccessPolicy {
    /// Roots that were probed, or granted, and are readable.
    allowed: HashSet<String>,
    /// Roots that refused access, and until when (seconds on any clock).
    denied_until: HashMap<String, f64>,
}

impl AccessPolicy {
    /// Whether background detection must skip `path` (`shouldSkipAutoAccess`).
    /// Outside the protected roots nothing is skipped. With
    /// `allow_protected` off every protected root is skipped. Otherwise a
    /// root is probed once with `can_access`; a denial is remembered for
    /// [`DENY_COOLDOWN_SECONDS`].
    pub fn should_skip(
        &mut self,
        path: &str,
        home: &str,
        allow_protected: bool,
        now: f64,
        can_access: impl FnOnce(&str) -> bool,
    ) -> bool {
        let Some(root) = protected_root_for(path, home) else {
            return false;
        };
        if !allow_protected {
            return true;
        }
        if self.allowed.contains(&root) {
            return false;
        }
        if self
            .denied_until
            .get(&root)
            .is_some_and(|until| now < *until)
        {
            return true;
        }
        if can_access(&root) {
            self.denied_until.remove(&root);
            self.allowed.insert(root);
            false
        } else {
            self.denied_until.insert(root, now + DENY_COOLDOWN_SECONDS);
            true
        }
    }

    /// The user granted `root`: it is used from now on.
    pub fn grant(&mut self, root: &str) {
        self.denied_until.remove(root);
        self.allowed.insert(root.to_string());
    }

    /// Forget every decision (`resetAccessChecks`).
    pub fn reset(&mut self) {
        self.allowed.clear();
        self.denied_until.clear();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const HOME: &str = "/Users/me";

    #[test]
    fn finds_the_protected_root() {
        assert_eq!(
            protected_root_for("/Users/me/Documents/code/app", HOME).as_deref(),
            Some("/Users/me/Documents")
        );
        assert_eq!(
            protected_root_for("/Users/me/Documents", HOME).as_deref(),
            Some("/Users/me/Documents")
        );
        assert_eq!(
            protected_root_for("/Library/Fonts", HOME).as_deref(),
            Some("/Library")
        );
        // Siblings and look-alikes are not protected.
        assert_eq!(protected_root_for("/Users/me/Documents2/x", HOME), None);
        assert_eq!(protected_root_for("/Users/me/code", HOME), None);
        assert_eq!(
            protected_root_for("/Users/me/Documents/../code", HOME),
            None
        );
        assert_eq!(
            protected_root_for("/Users/me/code/../Desktop/x", HOME).as_deref(),
            Some("/Users/me/Desktop")
        );
    }

    #[test]
    fn unprotected_paths_are_never_probed() {
        let mut policy = AccessPolicy::default();
        assert!(!policy.should_skip("/Users/me/code", HOME, false, 0.0, |_| panic!("probed")));
    }

    #[test]
    fn disabled_access_skips_without_probing() {
        let mut policy = AccessPolicy::default();
        assert!(
            policy.should_skip("/Users/me/Desktop/x", HOME, false, 0.0, |_| panic!(
                "probed"
            ))
        );
    }

    #[test]
    fn denial_is_retried_after_five_minutes() {
        let mut policy = AccessPolicy::default();
        let path = "/Users/me/Downloads/app";
        assert!(policy.should_skip(path, HOME, true, 0.0, |_| false));
        // Within the cooldown: skipped without a new probe.
        assert!(policy.should_skip(path, HOME, true, 299.0, |_| panic!("probed")));
        // After it: probed again, now readable.
        assert!(!policy.should_skip(path, HOME, true, 301.0, |_| true));
        // Allowed roots are not probed again.
        assert!(!policy.should_skip(path, HOME, true, 302.0, |_| panic!("probed")));
    }

    #[test]
    fn grant_and_reset() {
        let mut policy = AccessPolicy::default();
        let path = "/Users/me/Documents/x";
        assert!(policy.should_skip(path, HOME, true, 0.0, |_| false));
        policy.grant("/Users/me/Documents");
        assert!(!policy.should_skip(path, HOME, true, 1.0, |_| panic!("probed")));
        policy.reset();
        assert!(policy.should_skip(path, HOME, true, 2.0, |_| false));
    }
}
