//! Prepared paint output per grid row. GPUI emits every primitive each
//! frame, but building a row's text runs, segmenting its graphemes and
//! shaping it cost about as much as submitting it. A row whose cells,
//! clusters and style are unchanged reuses that preparation; only rows the
//! terminal actually changed are prepared again.
//!
//! The key is the row's own cells and clusters, compared exactly, so a reused
//! row can never show stale text. Search matches, the dangerous-command tint,
//! the cursor, images and timestamps are painted on top and never cached.

use chau7_terminal::OwnedCell;
use gpui::{Font, Hsla, Pixels, ShapedLine, TextRun};

use super::Decoration;

/// Everything besides the row's cells that its preparation depends on.
#[derive(Clone, PartialEq)]
pub(super) struct RowStyle {
    pub font: Font,
    pub font_size: Pixels,
    pub cell_width: Pixels,
    pub link_color: Hsla,
    pub default_bg: (u8, u8, u8),
}

/// One row ready to paint: background runs, shaped text and hand-drawn
/// underlines, all positioned by column.
pub(super) struct PreparedRow {
    cells: Vec<OwnedCell>,
    clusters: Vec<(usize, String)>,
    /// (first column, columns, color) of each non-default background run.
    pub backgrounds: Vec<(usize, usize, (u8, u8, u8))>,
    /// (first column, line, runs) of each text chunk with visible content.
    pub lines: Vec<(usize, ShapedLine, Vec<TextRun>)>,
    pub decorations: Vec<Decoration>,
}

impl PreparedRow {
    pub(super) fn new(cells: &[OwnedCell], clusters: &[(usize, &String)]) -> Self {
        Self {
            cells: cells.to_vec(),
            clusters: clusters
                .iter()
                .map(|(col, text)| (*col, (*text).clone()))
                .collect(),
            backgrounds: Vec::new(),
            lines: Vec::new(),
            decorations: Vec::new(),
        }
    }

    fn matches(&self, cells: &[OwnedCell], clusters: &[(usize, &String)]) -> bool {
        self.cells == cells
            && self.clusters.len() == clusters.len()
            && self
                .clusters
                .iter()
                .zip(clusters)
                .all(|((a, text), (b, other))| a == b && text == *other)
    }

    fn bytes(&self) -> usize {
        self.cells.capacity() * std::mem::size_of::<OwnedCell>()
            + self
                .clusters
                .iter()
                .map(|(_, text)| text.capacity())
                .sum::<usize>()
            + self
                .lines
                .iter()
                .map(|(_, line, runs)| line.len() + runs.len() * std::mem::size_of::<TextRun>())
                .sum::<usize>()
    }
}

/// The prepared rows of one terminal view, with lifetime reuse counters.
#[derive(Default)]
pub(crate) struct RowCache {
    style: Option<RowStyle>,
    rows: Vec<Option<PreparedRow>>,
    reused: u64,
    prepared: u64,
}

impl RowCache {
    /// Size the cache to the viewport; a style change invalidates every row.
    pub(super) fn begin_frame(&mut self, style: &RowStyle, rows: usize) {
        if self.style.as_ref() != Some(style) {
            self.rows.clear();
            self.style = Some(style.clone());
        }
        self.rows.resize_with(rows, || None);
    }

    /// The cached row when it was prepared from exactly these cells.
    pub(super) fn reuse(
        &mut self,
        row: usize,
        cells: &[OwnedCell],
        clusters: &[(usize, &String)],
    ) -> bool {
        let hit = self
            .rows
            .get(row)
            .and_then(Option::as_ref)
            .is_some_and(|prepared| prepared.matches(cells, clusters));
        if hit {
            self.reused = self.reused.saturating_add(1);
        }
        hit
    }

    pub(super) fn store(&mut self, row: usize, prepared: PreparedRow) {
        if let Some(slot) = self.rows.get_mut(row) {
            *slot = Some(prepared);
            self.prepared = self.prepared.saturating_add(1);
        }
    }

    pub(super) fn get(&self, row: usize) -> Option<&PreparedRow> {
        self.rows.get(row).and_then(Option::as_ref)
    }

    pub(crate) fn bytes(&self) -> u64 {
        self.rows
            .iter()
            .flatten()
            .map(PreparedRow::bytes)
            .sum::<usize>() as u64
    }

    /// Memory pressure or a far-away tab: drop the rows, keep the counters.
    pub(crate) fn clear(&mut self) {
        self.rows.clear();
        self.style = None;
    }

    pub(crate) fn diagnostics(&self) -> serde_json::Value {
        let total = self.reused.saturating_add(self.prepared);
        serde_json::json!({
            "rows_cached": self.rows.iter().flatten().count(),
            "rows_reused": self.reused,
            "rows_prepared": self.prepared,
            "reuse_ratio": (total > 0).then(|| self.reused as f64 / total as f64),
            "estimated_bytes": self.bytes(),
        })
    }
}

/// The grapheme clusters of each row, sorted by column, from the grid's
/// cell-index map: one pass over the map instead of a lookup per cell.
pub(super) fn clusters_by_row(
    clusters: &std::collections::HashMap<usize, String>,
    cols: usize,
    rows: usize,
) -> Vec<Vec<(usize, &String)>> {
    let mut by_row: Vec<Vec<(usize, &String)>> = vec![Vec::new(); rows];
    if cols == 0 {
        return by_row;
    }
    for (index, text) in clusters {
        if let Some(row) = by_row.get_mut(index / cols) {
            row.push((index % cols, text));
        }
    }
    for row in &mut by_row {
        row.sort_unstable_by_key(|(col, _)| *col);
    }
    by_row
}

#[cfg(test)]
mod tests {
    use super::*;

    fn cell(c: char) -> OwnedCell {
        OwnedCell {
            character: c,
            ..OwnedCell::default()
        }
    }

    fn style() -> RowStyle {
        RowStyle {
            font: gpui::font("Menlo"),
            font_size: gpui::px(13.0),
            cell_width: gpui::px(8.0),
            link_color: gpui::hsla(0.6, 1.0, 0.5, 1.0),
            default_bg: (0, 0, 0),
        }
    }

    #[test]
    fn only_rows_with_identical_cells_and_clusters_are_reused() {
        let mut cache = RowCache::default();
        cache.begin_frame(&style(), 2);
        let row = [cell('a'), cell('b')];
        let flag = "🇫🇷".to_string();
        cache.store(0, PreparedRow::new(&row, &[(1, &flag)]));
        assert!(cache.reuse(0, &row, &[(1, &flag)]));
        // A changed cell, a changed cluster, or an empty slot is prepared again.
        assert!(!cache.reuse(0, &[cell('a'), cell('c')], &[(1, &flag)]));
        let other = "🇩🇪".to_string();
        assert!(!cache.reuse(0, &row, &[(1, &other)]));
        assert!(!cache.reuse(0, &row, &[]));
        assert!(!cache.reuse(1, &row, &[]));
        let diagnostics = cache.diagnostics();
        assert_eq!(diagnostics["rows_reused"], 1);
        assert_eq!(diagnostics["rows_prepared"], 1);
    }

    #[test]
    fn a_style_change_invalidates_rows_and_resizing_keeps_the_rest() {
        let mut cache = RowCache::default();
        cache.begin_frame(&style(), 3);
        let row = [cell('x')];
        cache.store(0, PreparedRow::new(&row, &[]));
        cache.store(2, PreparedRow::new(&row, &[]));
        cache.begin_frame(&style(), 1);
        assert!(cache.reuse(0, &row, &[]));
        assert!(cache.get(2).is_none());
        let mut bigger = style();
        bigger.font_size = gpui::px(14.0);
        cache.begin_frame(&bigger, 1);
        assert!(!cache.reuse(0, &row, &[]));
    }

    #[test]
    fn clusters_are_grouped_by_row_in_column_order() {
        let clusters = std::collections::HashMap::from([
            (5, "é".to_string()),
            (4, "ñ".to_string()),
            (1, "ü".to_string()),
            (99, "past the grid".to_string()),
        ]);
        let rows = clusters_by_row(&clusters, 3, 2);
        assert_eq!(rows[0], vec![(1, &"ü".to_string())]);
        assert_eq!(rows[1], vec![(1, &"ñ".to_string()), (2, &"é".to_string())]);
    }
}
