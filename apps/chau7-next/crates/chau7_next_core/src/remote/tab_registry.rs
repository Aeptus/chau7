//! Stable remote tab IDs (`Remote/RemoteTabRegistry.swift`).
//!
//! The phone addresses tabs by `u32`. IDs start at 1, stay the same for a tab
//! as long as it lives, and are never reused for another tab during the app
//! session. The app's own tab key (`K`) stands for the Swift tab UUID.

use std::collections::HashMap;
use std::hash::Hash;

use super::models::RemoteTabDescriptor;

/// One tab as the app sees it, before an ID is given.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RemoteTabRegistryEntry<K> {
    pub key: K,
    /// The session whose output is forwarded for this tab.
    pub session: Option<u64>,
    pub title: String,
    pub project_name: Option<String>,
    pub branch_name: Option<String>,
    pub is_active: bool,
    pub is_mcp_controlled: bool,
}

#[derive(Debug, Clone)]
pub struct RemoteTabRegistry<K> {
    by_key: HashMap<K, u32>,
    by_id: HashMap<u32, K>,
    by_session: HashMap<u64, u32>,
    next_id: u32,
}

impl<K> Default for RemoteTabRegistry<K> {
    fn default() -> Self {
        Self {
            by_key: HashMap::new(),
            by_id: HashMap::new(),
            by_session: HashMap::new(),
            next_id: 1,
        }
    }
}

impl<K: Copy + Eq + Hash> RemoteTabRegistry<K> {
    pub fn new() -> Self {
        Self::default()
    }

    /// Assign IDs to `entries` (keeping known ones), forget tabs that are
    /// gone, and return the descriptors in the same order.
    pub fn rebuild(&mut self, entries: &[RemoteTabRegistryEntry<K>]) -> Vec<RemoteTabDescriptor> {
        let mut by_key = HashMap::new();
        let mut by_id = HashMap::new();
        let mut by_session = HashMap::new();
        let mut descriptors = Vec::with_capacity(entries.len());
        for entry in entries {
            let tab_id = match self.by_key.get(&entry.key) {
                Some(id) => *id,
                None => {
                    let id = self.next_id;
                    self.next_id = self.next_id.wrapping_add(1);
                    id
                }
            };
            by_key.insert(entry.key, tab_id);
            by_id.insert(tab_id, entry.key);
            if let Some(session) = entry.session {
                by_session.insert(session, tab_id);
            }
            descriptors.push(RemoteTabDescriptor {
                tab_id,
                title: entry.title.clone(),
                project_name: entry.project_name.clone(),
                branch_name: entry.branch_name.clone(),
                is_active: entry.is_active,
                is_mcp_controlled: entry.is_mcp_controlled,
            });
        }
        self.by_key = by_key;
        self.by_id = by_id;
        self.by_session = by_session;
        descriptors
    }

    pub fn tab_id(&self, key: K) -> Option<u32> {
        self.by_key.get(&key).copied()
    }

    pub fn key(&self, tab_id: u32) -> Option<K> {
        self.by_id.get(&tab_id).copied()
    }

    pub fn tab_id_for_session(&self, session: u64) -> Option<u32> {
        self.by_session.get(&session).copied()
    }

    /// IDs of `keys` other than the selected tab (`backgroundTabIDs`).
    pub fn background_tab_ids(&self, keys: &[K], selected: K) -> Vec<u32> {
        let selected_id = self.tab_id(selected);
        keys.iter()
            .filter_map(|k| self.tab_id(*k))
            .filter(|id| Some(*id) != selected_id)
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn entry(
        key: u64,
        session: Option<u64>,
        title: &str,
        active: bool,
    ) -> RemoteTabRegistryEntry<u64> {
        RemoteTabRegistryEntry {
            key,
            session,
            title: title.into(),
            project_name: Some("Chau7".into()),
            branch_name: None,
            is_active: active,
            is_mcp_controlled: false,
        }
    }

    #[test]
    fn rebuild_keeps_ids_stable_across_reordering() {
        let mut registry = RemoteTabRegistry::new();
        let first = registry.rebuild(&[
            entry(10, Some(1), "A", true),
            entry(20, Some(2), "B", false),
        ]);
        assert_eq!(first.iter().map(|d| d.tab_id).collect::<Vec<_>>(), [1, 2]);
        let second = registry.rebuild(&[
            entry(20, Some(2), "B", true),
            entry(10, Some(1), "A", false),
        ]);
        assert_eq!(second.iter().map(|d| d.tab_id).collect::<Vec<_>>(), [2, 1]);
        assert!(second[0].is_active);
        assert_eq!(registry.key(1), Some(10));
        assert_eq!(registry.tab_id_for_session(2), Some(2));
    }

    #[test]
    fn removed_tabs_drop_mappings_and_ids_are_not_reused() {
        let mut registry = RemoteTabRegistry::new();
        registry.rebuild(&[
            entry(10, Some(1), "A", true),
            entry(20, Some(2), "B", false),
        ]);
        let after = registry.rebuild(&[
            entry(20, Some(2), "B", true),
            entry(30, Some(3), "C", false),
        ]);
        assert_eq!(after.iter().map(|d| d.tab_id).collect::<Vec<_>>(), [2, 3]);
        assert_eq!(registry.key(1), None);
        assert_eq!(registry.tab_id(10), None);
        assert_eq!(registry.tab_id_for_session(1), None);
        // Tab 10 comes back: it gets a new ID, never an old one.
        let again = registry.rebuild(&[entry(10, Some(1), "A", true)]);
        assert_eq!(again[0].tab_id, 4);
    }

    #[test]
    fn background_ids_exclude_the_selected_tab() {
        let mut registry = RemoteTabRegistry::new();
        registry.rebuild(&[
            entry(10, Some(1), "A", true),
            entry(20, Some(2), "B", false),
            entry(30, None, "C", false),
        ]);
        assert_eq!(registry.background_tab_ids(&[10, 20, 30, 99], 10), [2, 3]);
    }
}
