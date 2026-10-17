//! Port of `Monitoring/ConflictDetector.swift`: a file changed by commands
//! of two or more tabs within the last 5 minutes is a conflict. Each new
//! conflict raises a `file_conflict` event on every tab involved.

use std::collections::{BTreeMap, BTreeSet};

/// `lookbackWindow` (5 minutes).
pub const LOOKBACK_WINDOW: f64 = 300.0;

/// `FileConflict`. `repo_root` is always empty, as in Swift.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FileConflict<T: Ord + Clone> {
    pub id: u64,
    pub file_path: String,
    pub repo_root: String,
    pub tabs: BTreeSet<T>,
    pub detected_at: i64,
}

/// One finished command of a tab: when it ended (Unix seconds) and the
/// files it changed.
#[derive(Debug, Clone, PartialEq)]
pub struct FinishedBlock {
    pub end_time: f64,
    pub changed_files: Vec<String>,
}

/// `ConflictDetector`, generic over the tab id type.
#[derive(Debug, Clone)]
pub struct ConflictDetector<T: Ord + Clone> {
    pub lookback_window: f64,
    active: Vec<FileConflict<T>>,
    next_id: u64,
}

impl<T: Ord + Clone> Default for ConflictDetector<T> {
    fn default() -> Self {
        Self {
            lookback_window: LOOKBACK_WINDOW,
            active: Vec::new(),
            next_id: 1,
        }
    }
}

impl<T: Ord + Clone> ConflictDetector<T> {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn active(&self) -> &[FileConflict<T>] {
        &self.active
    }

    /// Recomputes the conflicts from every tab's finished commands and
    /// returns the new ones (`checkForConflicts`). Existing conflicts keep
    /// their id.
    pub fn check(
        &mut self,
        blocks_by_tab: &[(T, Vec<FinishedBlock>)],
        now: f64,
    ) -> Vec<FileConflict<T>> {
        let cutoff = now - self.lookback_window;
        let mut file_to_tabs: BTreeMap<String, BTreeSet<T>> = BTreeMap::new();
        for (tab, blocks) in blocks_by_tab {
            for block in blocks {
                if block.end_time <= cutoff {
                    continue;
                }
                for file in &block.changed_files {
                    file_to_tabs
                        .entry(file.clone())
                        .or_default()
                        .insert(tab.clone());
                }
            }
        }
        let mut conflicts = Vec::new();
        let mut new = Vec::new();
        for (file, tabs) in file_to_tabs {
            if tabs.len() < 2 {
                continue;
            }
            if let Some(existing) = self
                .active
                .iter()
                .find(|c| c.file_path == file && c.tabs == tabs)
            {
                conflicts.push(existing.clone());
            } else {
                let conflict = FileConflict {
                    id: self.next_id,
                    file_path: file,
                    repo_root: String::new(),
                    tabs,
                    detected_at: now as i64,
                };
                self.next_id += 1;
                conflicts.push(conflict.clone());
                new.push(conflict);
            }
        }
        self.active = conflicts;
        new
    }

    /// Conflicts involving one tab (`conflictsForTab`).
    pub fn for_tab(&self, tab: &T) -> Vec<&FileConflict<T>> {
        self.active
            .iter()
            .filter(|c| c.tabs.contains(tab))
            .collect()
    }

    /// Forgets a closed tab.
    pub fn remove_tab(&mut self, tab: &T) {
        for conflict in &mut self.active {
            conflict.tabs.remove(tab);
        }
        self.active.retain(|c| c.tabs.len() > 1);
    }
}

/// "Potential file conflict: <name> changed in N tabs" (`emitEvents`).
pub fn conflict_message<T: Ord + Clone>(conflict: &FileConflict<T>) -> String {
    let name = conflict
        .file_path
        .rsplit('/')
        .next()
        .filter(|n| !n.is_empty())
        .unwrap_or(&conflict.file_path);
    format!(
        "Potential file conflict: {name} changed in {} tabs",
        conflict.tabs.len()
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    fn block(at: f64, files: &[&str]) -> FinishedBlock {
        FinishedBlock {
            end_time: at,
            changed_files: files.iter().map(|f| f.to_string()).collect(),
        }
    }

    #[test]
    fn no_conflicts_by_default() {
        let detector: ConflictDetector<u64> = ConflictDetector::new();
        assert!(detector.for_tab(&1).is_empty());
        assert_eq!(detector.lookback_window, 300.0);
    }

    #[test]
    fn detects_shared_files_in_window() {
        let mut d: ConflictDetector<u64> = ConflictDetector::new();
        let tabs = vec![
            (1, vec![block(1000.0, &["src/a.rs", "b.rs"])]),
            (
                2,
                vec![block(1100.0, &["src/a.rs"]), block(500.0, &["b.rs"])],
            ),
        ];
        let new = d.check(&tabs, 1200.0);
        assert_eq!(new.len(), 1);
        assert_eq!(new[0].file_path, "src/a.rs");
        assert_eq!(
            conflict_message(&new[0]),
            "Potential file conflict: a.rs changed in 2 tabs"
        );
        assert_eq!(d.for_tab(&2).len(), 1);
        // Same conflict again: kept, not new.
        let again = d.check(&tabs, 1210.0);
        assert!(again.is_empty());
        assert_eq!(d.active()[0].id, new[0].id);
        // Out of the window.
        assert!(d.check(&tabs, 2000.0).is_empty());
        assert!(d.active().is_empty());
    }

    #[test]
    fn removing_a_tab_drops_its_conflicts() {
        let mut d: ConflictDetector<u64> = ConflictDetector::new();
        let tabs = vec![
            (1, vec![block(10.0, &["x"])]),
            (2, vec![block(10.0, &["x"])]),
        ];
        d.check(&tabs, 20.0);
        d.remove_tab(&1);
        assert!(d.active().is_empty());
    }
}
