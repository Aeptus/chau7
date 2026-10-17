//! Clipboard history: newest first, repeated text moves to the top, pinned
//! items survive trimming and Clear.
//!
//! Ports `apps/chau7-macos/Sources/Chau7/Keyboard/ClipboardHistoryManager.swift`.
//! Items serialize like Swift's `Codable` `ClipboardItem` (`id`, `text`,
//! `timestamp` as seconds since 2001-01-01, `isPinned`); Swift keeps them in
//! UserDefaults (`clipboard.history`), Chau7 Next in a JSON file.

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

use crate::iso8601::reference_date;

/// Swift clamps the history size to 1...1000 (`clipboardHistoryMaxItems`).
pub const MAX_ITEMS_LIMIT: usize = 1000;
pub const DEFAULT_MAX_ITEMS: usize = 50;

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ClipboardItem {
    pub id: String,
    pub text: String,
    #[serde(with = "reference_date")]
    pub timestamp: DateTime<Utc>,
    #[serde(default)]
    pub is_pinned: bool,
}

impl ClipboardItem {
    pub fn new(text: impl Into<String>) -> Self {
        Self {
            id: uuid::Uuid::new_v4().to_string().to_uppercase(),
            text: text.into(),
            timestamp: Utc::now(),
            is_pinned: false,
        }
    }

    /// Seconds since the item was copied.
    pub fn age_seconds(&self) -> i64 {
        (Utc::now() - self.timestamp).num_seconds()
    }

    /// One-line preview: trimmed, newlines as spaces, 57 chars plus "..."
    /// past 60.
    pub fn preview(&self) -> String {
        let trimmed = self.text.trim();
        if trimmed.chars().count() <= 60 {
            return trimmed.replace('\n', " ");
        }
        let head: String = trimmed.chars().take(57).collect();
        head.replace('\n', " ") + "..."
    }
}

#[derive(Debug, Clone, Default, PartialEq)]
pub struct ClipboardHistory {
    pub items: Vec<ClipboardItem>,
}

impl ClipboardHistory {
    pub fn new() -> Self {
        Self::default()
    }

    /// Add copied text. Returns false when nothing changed (empty text, or
    /// the same as the newest item).
    pub fn add(&mut self, text: &str, max_items: usize) -> bool {
        if text.is_empty() || self.items.first().is_some_and(|i| i.text == text) {
            return false;
        }
        if let Some(index) = self
            .items
            .iter()
            .position(|i| i.text == text && !i.is_pinned)
        {
            self.items.remove(index);
        }
        self.items.insert(0, ClipboardItem::new(text));
        self.trim(max_items);
        true
    }

    /// Drop the oldest unpinned items beyond `max_items` (pinned ones count).
    pub fn trim(&mut self, max_items: usize) {
        if self.items.len() <= max_items {
            return;
        }
        let pinned = self.items.iter().filter(|i| i.is_pinned).count();
        let max_unpinned = max_items.saturating_sub(pinned);
        let mut kept_unpinned = 0;
        self.items.retain(|item| {
            if item.is_pinned {
                return true;
            }
            kept_unpinned += 1;
            kept_unpinned <= max_unpinned
        });
    }

    /// The item was pasted: an unpinned item moves to the top.
    pub fn mark_pasted(&mut self, id: &str) {
        if let Some(index) = self.items.iter().position(|i| i.id == id && !i.is_pinned) {
            let item = self.items.remove(index);
            self.items.insert(0, item);
        }
    }

    pub fn toggle_pin(&mut self, id: &str) {
        if let Some(item) = self.items.iter_mut().find(|i| i.id == id) {
            item.is_pinned = !item.is_pinned;
        }
    }

    pub fn remove(&mut self, id: &str) {
        self.items.retain(|i| i.id != id);
    }

    /// Remove every unpinned item.
    pub fn clear(&mut self) {
        self.items.retain(|i| i.is_pinned);
    }

    /// Items containing `query`, case-insensitively.
    pub fn search(&self, query: &str) -> Vec<&ClipboardItem> {
        let lowered = query.to_lowercase();
        self.items
            .iter()
            .filter(|i| i.text.to_lowercase().contains(&lowered))
            .collect()
    }

    pub fn to_json(&self) -> String {
        serde_json::to_string(&self.items).unwrap_or_else(|_| "[]".into())
    }

    pub fn from_json(text: &str) -> Self {
        Self {
            items: serde_json::from_str(text).unwrap_or_default(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // Ports of `ClipboardHistoryManagerTests`.

    #[test]
    fn add_item() {
        let mut h = ClipboardHistory::new();
        h.add("hello", 50);
        assert_eq!(h.items.len(), 1);
        assert_eq!(h.items[0].text, "hello");
    }

    #[test]
    fn add_duplicate_moves_to_top() {
        let mut h = ClipboardHistory::new();
        h.add("first", 50);
        h.add("second", 50);
        h.add("first", 50);
        assert_eq!(h.items.len(), 2);
        assert_eq!(h.items[0].text, "first");
        assert_eq!(h.items[1].text, "second");
    }

    #[test]
    fn trim_to_max_items() {
        let mut h = ClipboardHistory::new();
        for i in 0..5 {
            h.add(&format!("item-{i}"), 3);
        }
        assert!(h.items.len() <= 3);
        assert_eq!(h.items[0].text, "item-4");
    }

    #[test]
    fn pinned_items_survive_trim() {
        let mut h = ClipboardHistory::new();
        h.add("pinned-item", 3);
        let id = h.items[0].id.clone();
        h.toggle_pin(&id);
        for i in 0..5 {
            h.add(&format!("filler-{i}"), 3);
        }
        let pinned: Vec<_> = h.items.iter().filter(|i| i.is_pinned).collect();
        assert_eq!(pinned.len(), 1);
        assert_eq!(pinned[0].text, "pinned-item");
        assert_eq!(h.items.len(), 3);
    }

    #[test]
    fn toggle_pin() {
        let mut h = ClipboardHistory::new();
        h.add("test", 50);
        let id = h.items[0].id.clone();
        assert!(!h.items[0].is_pinned);
        h.toggle_pin(&id);
        assert!(h.items[0].is_pinned);
        h.toggle_pin(&id);
        assert!(!h.items[0].is_pinned);
    }

    #[test]
    fn paste_moves_to_top() {
        let mut h = ClipboardHistory::new();
        h.add("first", 50);
        h.add("second", 50);
        h.add("third", 50);
        let id = h.items[2].id.clone();
        h.mark_pasted(&id);
        assert_eq!(h.items[0].text, "first");
    }

    #[test]
    fn remove() {
        let mut h = ClipboardHistory::new();
        h.add("keep", 50);
        h.add("remove-me", 50);
        let id = h.items[0].id.clone();
        h.remove(&id);
        assert_eq!(h.items.len(), 1);
        assert_eq!(h.items[0].text, "keep");
    }

    #[test]
    fn clear_keeps_pinned() {
        let mut h = ClipboardHistory::new();
        h.add("pinned", 50);
        let id = h.items[0].id.clone();
        h.toggle_pin(&id);
        h.add("unpinned-1", 50);
        h.add("unpinned-2", 50);
        h.clear();
        assert_eq!(h.items.len(), 1);
        assert_eq!(h.items[0].text, "pinned");
        assert!(h.items[0].is_pinned);
    }

    #[test]
    fn preview() {
        assert_eq!(ClipboardItem::new("short text").preview(), "short text");
        assert_eq!(ClipboardItem::new("line1\nline2").preview(), "line1 line2");
        let long = ClipboardItem::new("a".repeat(100)).preview();
        assert!(long.ends_with("..."));
        assert_eq!(long.chars().count(), 60);
    }

    #[test]
    fn json_round_trip_and_search() {
        let mut h = ClipboardHistory::new();
        h.add("Alpha", 50);
        h.add("beta", 50);
        let back = ClipboardHistory::from_json(&h.to_json());
        let texts = |h: &ClipboardHistory| {
            h.items
                .iter()
                .map(|i| (i.id.clone(), i.text.clone(), i.is_pinned))
                .collect::<Vec<_>>()
        };
        assert_eq!(texts(&back), texts(&h));
        assert!(h.to_json().contains("\"isPinned\":false"));
        assert_eq!(h.search("ALP").len(), 1);
        assert!(ClipboardHistory::from_json("not json").items.is_empty());
    }
}
