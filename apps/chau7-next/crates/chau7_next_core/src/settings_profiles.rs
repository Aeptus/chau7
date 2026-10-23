//! Settings profiles and automatic switching (`SettingsProfile`,
//! `FeatureSettings` profile management and `ProfileAutoSwitcher.swift`).
//!
//! A profile is a name, an icon and a full copy of the settings, kept here
//! as config text so this module does not depend on the app's settings
//! types. The store is one JSON file of Chau7 Next's own.

use std::collections::HashMap;
use std::path::Path;

use serde::{Deserialize, Serialize};
pub use uuid::Uuid;

use crate::profile_rules::{ProfileSwitchRule, sorted_by_priority};

/// The 16 icons of `SettingsProfile.availableIcons` (SF Symbol names).
pub const AVAILABLE_ICONS: [&str; 16] = [
    "house.fill",
    "person.fill",
    "briefcase.fill",
    "building.2.fill",
    "laptopcomputer",
    "desktopcomputer",
    "display",
    "tv.fill",
    "moon.fill",
    "sun.max.fill",
    "leaf.fill",
    "bolt.fill",
    "sparkles",
    "flame.fill",
    "paintbrush.fill",
    "hammer.fill",
];

pub const DEFAULT_ICON: &str = "person.fill";

/// A plain character standing in for an SF Symbol where none is available.
pub fn icon_glyph(icon: &str) -> &'static str {
    match icon {
        "house.fill" => "\u{2302}",
        "person.fill" => "\u{263A}",
        "briefcase.fill" => "\u{25A3}",
        "building.2.fill" => "\u{25A4}",
        "laptopcomputer" => "\u{25AD}",
        "desktopcomputer" => "\u{25A2}",
        "display" => "\u{25A5}",
        "tv.fill" => "\u{25A6}",
        "moon.fill" => "\u{263E}",
        "sun.max.fill" => "\u{2600}",
        "leaf.fill" => "\u{2766}",
        "bolt.fill" => "\u{03DF}",
        "sparkles" => "\u{2726}",
        "flame.fill" => "\u{2668}",
        "paintbrush.fill" => "\u{270E}",
        "hammer.fill" => "\u{2692}",
        _ => "\u{25CF}",
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SettingsProfile {
    pub id: String,
    pub name: String,
    pub icon: String,
    /// Unix seconds.
    pub created_at: i64,
    /// The settings as config text.
    pub config: String,
}

impl SettingsProfile {
    pub fn new(name: &str, icon: &str, config: String, now: i64) -> Self {
        Self {
            id: Uuid::new_v4().to_string(),
            name: name.to_string(),
            icon: icon.to_string(),
            created_at: now,
            config,
        }
    }
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProfileStore {
    pub profiles: Vec<SettingsProfile>,
    /// Id of the profile whose settings were loaded last (`settings.activeProfile`).
    pub active: Option<String>,
    /// `feature.profileAutoSwitch`.
    pub auto_switch: bool,
    /// `feature.profileSwitchRules`.
    pub rules: Vec<ProfileSwitchRule>,
}

impl ProfileStore {
    /// The saved store, or an empty one. A file that exists but cannot be
    /// read or decoded is moved to `<path>.corrupt.<unix millis>` first, so
    /// the save that follows (the default profile) does not destroy it.
    pub fn load(path: &Path) -> Self {
        let error = match std::fs::read_to_string(path) {
            Ok(text) => match serde_json::from_str(&text) {
                Ok(store) => return store,
                Err(err) => err.to_string(),
            },
            Err(err) if err.kind() == std::io::ErrorKind::NotFound => return Self::default(),
            Err(err) => err.to_string(),
        };
        let aside = std::path::PathBuf::from(format!(
            "{}.corrupt.{}",
            path.display(),
            chrono::Utc::now().timestamp_millis()
        ));
        match std::fs::rename(path, &aside) {
            Ok(()) => log::warn!(
                "profiles: {} is unreadable ({error}); kept as {}",
                path.display(),
                aside.display()
            ),
            Err(err) => log::warn!(
                "profiles: {} is unreadable ({error}) and could not be kept: {err}",
                path.display()
            ),
        }
        Self::default()
    }

    /// Replace the file atomically, so a crash never leaves it half written.
    pub fn save(&self, path: &Path) -> std::io::Result<()> {
        let text = serde_json::to_string_pretty(self).map_err(std::io::Error::other)?;
        crate::atomic_file::write(path, text.as_bytes())
    }

    /// Make sure the "Default" profile exists when none were saved
    /// (`SettingsProfile.defaultProfiles`).
    pub fn ensure_default(&mut self, default_config: &str, now: i64) {
        if self.profiles.is_empty() {
            self.profiles.push(SettingsProfile::new(
                "Default",
                "house.fill",
                default_config.to_string(),
                now,
            ));
        }
    }

    pub fn by_id(&self, id: &str) -> Option<&SettingsProfile> {
        self.profiles.iter().find(|p| p.id == id)
    }

    pub fn by_name(&self, name: &str) -> Option<&SettingsProfile> {
        self.profiles.iter().find(|p| p.name == name)
    }

    pub fn active_profile(&self) -> Option<&SettingsProfile> {
        self.active.as_deref().and_then(|id| self.by_id(id))
    }

    /// Save the current settings as a new profile and return its id.
    pub fn create(&mut self, name: &str, icon: &str, config: String, now: i64) -> String {
        let profile = SettingsProfile::new(name.trim(), icon, config, now);
        let id = profile.id.clone();
        self.profiles.push(profile);
        id
    }

    /// Replace a profile's settings with the current ones.
    pub fn save_current(&mut self, id: &str, config: String) {
        if let Some(profile) = self.profiles.iter_mut().find(|p| p.id == id) {
            profile.config = config;
        }
    }

    pub fn delete(&mut self, id: &str) {
        self.profiles.retain(|p| p.id != id);
        if self.active.as_deref() == Some(id) {
            self.active = None;
        }
    }

    /// Rule list changes keep `rules` in the saved order.
    pub fn add_rule(&mut self, rule: ProfileSwitchRule) {
        self.rules.push(rule);
    }

    pub fn update_rule(&mut self, rule: ProfileSwitchRule) {
        if let Some(slot) = self.rules.iter_mut().find(|r| r.id == rule.id) {
            *slot = rule;
        }
    }

    pub fn delete_rule(&mut self, id: Uuid) {
        self.rules.retain(|r| r.id != id);
    }
}

/// What a tab looks like to the rules.
#[derive(Debug, Clone, Default)]
pub struct RuleContext {
    pub directory: Option<String>,
    pub ssh_host: Option<String>,
    pub processes: Option<Vec<String>>,
    pub environment: Option<HashMap<String, String>>,
    pub home: Option<String>,
}

/// What the app should do after an evaluation.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SwitchAction {
    Nothing,
    /// Load the profile with this name.
    Load(String),
    /// Load the profile that was active before switching.
    Restore(String),
}

/// `ProfileAutoSwitcher`: the rule that is applied now and the profile to
/// go back to.
#[derive(Debug, Clone, Default)]
pub struct AutoSwitcher {
    pub current_rule: Option<ProfileSwitchRule>,
    previous_profile: Option<String>,
}

impl AutoSwitcher {
    pub fn is_active(&self) -> bool {
        self.current_rule.is_some()
    }

    /// Check the rules, by priority then name, and report what to load.
    /// `active_profile` is the name of the profile in use now.
    pub fn evaluate(
        &mut self,
        store: &ProfileStore,
        context: &RuleContext,
        active_profile: Option<&str>,
    ) -> SwitchAction {
        if !store.auto_switch {
            return SwitchAction::Nothing;
        }
        for rule in sorted_by_priority(&store.rules) {
            let matched = rule.matches(
                context.directory.as_deref(),
                None,
                context.ssh_host.as_deref(),
                context.processes.as_deref(),
                context.environment.as_ref(),
                context.home.as_deref(),
            );
            if !matched {
                continue;
            }
            if self.current_rule.as_ref().map(|r| r.id) == Some(rule.id) {
                return SwitchAction::Nothing;
            }
            if store.by_name(&rule.profile_name).is_none() {
                // The target profile is gone: the first matching rule wins
                // even so, and nothing changes (as in Swift).
                return SwitchAction::Nothing;
            }
            if self.current_rule.is_none() {
                self.previous_profile = active_profile.map(str::to_string);
            }
            let target = rule.profile_name.clone();
            self.current_rule = Some(rule);
            return SwitchAction::Load(target);
        }
        if self.current_rule.is_some() {
            return self.restore(store);
        }
        SwitchAction::Nothing
    }

    /// Go back to the profile used before switching.
    pub fn restore(&mut self, store: &ProfileStore) -> SwitchAction {
        self.current_rule = None;
        match self.previous_profile.take() {
            Some(name) if store.by_name(&name).is_some() => SwitchAction::Restore(name),
            _ => SwitchAction::Nothing,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::profile_rules::ProfileSwitchTrigger;

    fn store() -> ProfileStore {
        let mut s = ProfileStore::default();
        s.ensure_default("a = 1", 0);
        s.create("Work", "briefcase.fill", "a = 2".into(), 0);
        s.auto_switch = true;
        let mut rule = ProfileSwitchRule::new(
            "Work repos",
            ProfileSwitchTrigger::Directory {
                path: "/work/**".into(),
            },
            "Work",
        );
        rule.priority = 1;
        s.add_rule(rule);
        s
    }

    fn ctx(dir: &str) -> RuleContext {
        RuleContext {
            directory: Some(dir.to_string()),
            ..Default::default()
        }
    }

    #[test]
    fn default_profile_appears_once() {
        let mut s = ProfileStore::default();
        s.ensure_default("x", 0);
        s.ensure_default("x", 0);
        assert_eq!(s.profiles.len(), 1);
        assert_eq!(s.profiles[0].name, "Default");
    }

    #[test]
    fn switching_remembers_and_restores_the_previous_profile() {
        let s = store();
        let mut sw = AutoSwitcher::default();
        assert_eq!(
            sw.evaluate(&s, &ctx("/work/app"), Some("Default")),
            SwitchAction::Load("Work".into())
        );
        assert!(sw.is_active());
        // Same rule again: nothing to do.
        assert_eq!(
            sw.evaluate(&s, &ctx("/work/app/src"), Some("Work")),
            SwitchAction::Nothing
        );
        assert_eq!(
            sw.evaluate(&s, &ctx("/home/me"), Some("Work")),
            SwitchAction::Restore("Default".into())
        );
        assert!(!sw.is_active());
    }

    #[test]
    fn disabled_auto_switch_does_nothing() {
        let mut s = store();
        s.auto_switch = false;
        let mut sw = AutoSwitcher::default();
        assert_eq!(
            sw.evaluate(&s, &ctx("/work/app"), None),
            SwitchAction::Nothing
        );
    }

    #[test]
    fn rule_for_a_missing_profile_changes_nothing() {
        let mut s = store();
        s.rules[0].profile_name = "Gone".into();
        let mut sw = AutoSwitcher::default();
        assert_eq!(
            sw.evaluate(&s, &ctx("/work/app"), None),
            SwitchAction::Nothing
        );
    }

    #[test]
    fn delete_clears_the_active_profile() {
        let mut s = store();
        let id = s.by_name("Work").unwrap().id.clone();
        s.active = Some(id.clone());
        s.delete(&id);
        assert_eq!(s.active, None);
        assert!(s.by_name("Work").is_none());
    }

    #[test]
    fn store_round_trips_through_a_file() {
        let dir = std::env::temp_dir().join(format!("chau7-prof-{}", std::process::id()));
        let path = dir.join("profiles.json");
        let s = store();
        s.save(&path).unwrap();
        assert_eq!(ProfileStore::load(&path), s);
        let _ = std::fs::remove_dir_all(&dir);
        assert_eq!(ProfileStore::load(&path), ProfileStore::default());
    }

    #[test]
    fn save_replaces_the_file_atomically() {
        let dir = std::env::temp_dir().join(format!("chau7-prof-{}", uuid::Uuid::new_v4()));
        let path = dir.join("profiles.json");
        ProfileStore::default().save(&path).unwrap();
        let before = std::fs::read(&path).unwrap();
        // The old inode keeps its bytes: renamed over, never truncated.
        let snapshot = dir.join("snapshot.json");
        std::fs::hard_link(&path, &snapshot).unwrap();
        let saved = store();
        saved.save(&path).unwrap();
        assert_eq!(std::fs::read(&snapshot).unwrap(), before);
        assert_eq!(ProfileStore::load(&path), saved);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn an_unreadable_file_is_kept_aside() {
        let dir = std::env::temp_dir().join(format!("chau7-prof-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("profiles.json");
        std::fs::write(&path, b"{\"profiles\": [{\"id\"").unwrap();
        assert_eq!(ProfileStore::load(&path), ProfileStore::default());
        assert!(!path.exists());
        let kept: Vec<_> = std::fs::read_dir(&dir)
            .unwrap()
            .flatten()
            .map(|e| e.path())
            .filter(|p| p.to_string_lossy().contains("profiles.json.corrupt."))
            .collect();
        assert_eq!(kept.len(), 1);
        assert_eq!(std::fs::read(&kept[0]).unwrap(), b"{\"profiles\": [{\"id\"");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn every_icon_has_a_glyph() {
        for icon in AVAILABLE_ICONS {
            assert_ne!(icon_glyph(icon), "\u{25CF}", "{icon}");
        }
    }
}
