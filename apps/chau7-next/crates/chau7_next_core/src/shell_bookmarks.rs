//! Bookmarks of one terminal session (`BookmarkManager.swift`): a scroll
//! position with an 80-character line preview, an optional label and the
//! time it was added. Past the per-tab limit (`feature.maxBookmarks`,
//! default 20) the oldest unlabeled bookmark goes, or the newest one when all
//! have labels.
//!
//! Positions are absolute buffer lines (0 = oldest scrollback line), so
//! they stay put while output scrolls. Swift's model stores a placeholder
//! offset and preview (`OverlayTabsModel.addBookmark` has no view access);
//! this keeps the real ones.

/// Default `feature.maxBookmarks`.
pub const DEFAULT_MAX_BOOKMARKS: usize = 20;
/// Characters kept from the line.
pub const PREVIEW_CHARS: usize = 80;

#[derive(Debug, Clone, PartialEq)]
pub struct Bookmark {
    pub id: u64,
    /// Absolute buffer line of the top of the view when added.
    pub line: i64,
    pub preview: String,
    /// Seconds since the Unix epoch.
    pub created_at: f64,
    pub label: Option<String>,
}

#[derive(Debug, Clone, Default, PartialEq)]
pub struct BookmarkList {
    bookmarks: Vec<Bookmark>,
    next_id: u64,
}

impl BookmarkList {
    pub fn new() -> Self {
        Self::default()
    }

    /// Adds a bookmark (`addBookmark`); returns its id.
    pub fn add(
        &mut self,
        line: i64,
        preview: &str,
        label: Option<String>,
        max: usize,
        now: f64,
    ) -> u64 {
        let max = max.clamp(1, 200);
        if self.bookmarks.len() >= max {
            match self.bookmarks.iter().position(|b| b.label.is_none()) {
                Some(index) => {
                    self.bookmarks.remove(index);
                }
                None => {
                    self.bookmarks.pop();
                }
            }
        }
        self.next_id += 1;
        let label = label
            .map(|l| l.trim().to_string())
            .filter(|l| !l.is_empty());
        self.bookmarks.push(Bookmark {
            id: self.next_id,
            line,
            preview: preview.trim_end().chars().take(PREVIEW_CHARS).collect(),
            created_at: now,
            label,
        });
        self.next_id
    }

    pub fn remove(&mut self, id: u64) {
        self.bookmarks.retain(|b| b.id != id);
    }

    pub fn get(&self, id: u64) -> Option<&Bookmark> {
        self.bookmarks.iter().find(|b| b.id == id)
    }

    pub fn all(&self) -> &[Bookmark] {
        &self.bookmarks
    }

    pub fn clear(&mut self) {
        self.bookmarks.clear();
    }
}

/// Display offset (lines scrolled up from the bottom) that puts absolute
/// `line` at the top of the view, for a buffer with `history` scrollback
/// lines.
pub fn display_offset_for(line: i64, history: i64) -> i64 {
    (history - line).clamp(0, history.max(0))
}

/// Absolute line at the top of the view.
pub fn top_line(history: i64, display_offset: i64) -> i64 {
    (history - display_offset).max(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn add_trims_preview_and_label() {
        let mut list = BookmarkList::new();
        let long = "x".repeat(120);
        let id = list.add(5, &long, Some("  ".into()), 20, 1.0);
        let b = list.get(id).unwrap();
        assert_eq!(b.preview.len(), PREVIEW_CHARS);
        assert_eq!(b.label, None);
        list.remove(id);
        assert!(list.all().is_empty());
    }

    #[test]
    fn limit_drops_oldest_unlabeled_then_newest() {
        let mut list = BookmarkList::new();
        list.add(1, "a", Some("keep".into()), 2, 0.0);
        list.add(2, "b", None, 2, 0.0);
        list.add(3, "c", None, 2, 0.0);
        let lines: Vec<i64> = list.all().iter().map(|b| b.line).collect();
        assert_eq!(lines, vec![1, 3]);
        let mut labeled = BookmarkList::new();
        labeled.add(1, "a", Some("x".into()), 2, 0.0);
        labeled.add(2, "b", Some("y".into()), 2, 0.0);
        labeled.add(3, "c", Some("z".into()), 2, 0.0);
        let lines: Vec<i64> = labeled.all().iter().map(|b| b.line).collect();
        assert_eq!(lines, vec![1, 3]);
        labeled.clear();
        assert!(labeled.all().is_empty());
    }

    #[test]
    fn positions() {
        assert_eq!(top_line(100, 0), 100);
        assert_eq!(top_line(100, 30), 70);
        assert_eq!(display_offset_for(70, 100), 30);
        // Scrollback grew by 10 lines: the same line is 10 further up.
        assert_eq!(display_offset_for(70, 110), 40);
        assert_eq!(display_offset_for(-5, 100), 100);
        assert_eq!(display_offset_for(500, 100), 0);
    }
}
