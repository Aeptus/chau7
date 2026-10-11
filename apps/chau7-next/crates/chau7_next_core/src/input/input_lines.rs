//! Rows where commands were entered, for Cmd+Up / Cmd+Down (previous and
//! next input line).
//!
//! Ports `apps/chau7-macos/Sources/Chau7/Terminal/Session/InputLineTracker.swift`
//! and the navigation of `RustTerminalView.scrollToPreviousInputLine` /
//! `scrollToNextInputLine`. Rows are absolute: row 0 is the oldest line of
//! the scrollback (`scrollback rows - display offset + viewport row`).

use std::collections::BTreeSet;

#[derive(Debug, Clone)]
pub struct InputLineTracker {
    max_entries: usize,
    rows: BTreeSet<i64>,
}

impl InputLineTracker {
    pub fn new(max_entries: usize) -> Self {
        Self {
            max_entries: max_entries.max(1),
            rows: BTreeSet::new(),
        }
    }

    /// Record a row holding user input; the oldest rows go past `max_entries`.
    pub fn record(&mut self, row: i64) {
        self.rows.insert(row);
        while self.rows.len() > self.max_entries {
            self.rows.pop_first();
        }
    }

    /// Rows inside `top..=bottom`.
    pub fn visible_rows(&self, top: i64, bottom: i64) -> Vec<i64> {
        self.rows.range(top..=bottom).copied().collect()
    }

    pub fn sorted_rows(&self) -> Vec<i64> {
        self.rows.iter().copied().collect()
    }

    pub fn reset(&mut self) {
        self.rows.clear();
    }

    /// The last recorded row strictly above `current_top`.
    pub fn previous(&self, current_top: i64) -> Option<i64> {
        self.rows.range(..current_top).next_back().copied()
    }

    /// The first recorded row strictly below `current_top`; `None` means
    /// "go to the bottom".
    pub fn next(&self, current_top: i64) -> Option<i64> {
        self.rows
            .range((
                std::ops::Bound::Excluded(current_top),
                std::ops::Bound::Unbounded,
            ))
            .next()
            .copied()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn records_and_navigates() {
        let mut t = InputLineTracker::new(10);
        for row in [5, 20, 12] {
            t.record(row);
        }
        assert_eq!(t.sorted_rows(), vec![5, 12, 20]);
        assert_eq!(t.previous(12), Some(5));
        assert_eq!(t.previous(5), None);
        assert_eq!(t.next(12), Some(20));
        assert_eq!(t.next(20), None);
        assert_eq!(t.visible_rows(10, 20), vec![12, 20]);
    }

    #[test]
    fn prunes_oldest_rows() {
        let mut t = InputLineTracker::new(2);
        t.record(1);
        t.record(2);
        t.record(3);
        assert_eq!(t.sorted_rows(), vec![2, 3]);
        t.reset();
        assert!(t.sorted_rows().is_empty());
    }
}
