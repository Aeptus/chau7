//! Worker-owned dirty rows with row-local Unicode pools and unchanged CHG2 wire bytes.
use super::grid_snapshot::{
    RemoteTerminalGridSnapshot, RemoteTerminalGridSnapshotLayout as Layout,
};

#[derive(Debug)]
pub struct RemoteGridUpdate {
    pub base_generation: u64,
    pub generation: u64,
    pub full_refresh: bool,
    pub row_indices: Vec<u16>,
    /// Cells are packed dirty rows, not a complete viewport yet.
    pub snapshot: RemoteTerminalGridSnapshot,
}

#[derive(Default)]
struct Row {
    cells: Vec<u8>,
    clusters: Vec<u8>,
}

pub struct RemoteGridSnapshotCache {
    maximum_bytes: usize,
    generation: u64,
    retained_bytes: usize,
    rows: Vec<Row>,
    previous: Option<RemoteTerminalGridSnapshot>,
}
impl Default for RemoteGridSnapshotCache {
    fn default() -> Self {
        Self::new(Self::DEFAULT_MAXIMUM_BYTES)
    }
}
impl RemoteGridSnapshotCache {
    pub const DEFAULT_MAXIMUM_BYTES: usize = 4 * 1024 * 1024;
    pub fn new(maximum_bytes: usize) -> Self {
        Self {
            maximum_bytes,
            generation: 0,
            retained_bytes: 0,
            rows: Vec::new(),
            previous: None,
        }
    }
    pub fn generation(&self) -> u64 {
        self.generation
    }
    pub fn retained_bytes(&self) -> usize {
        self.retained_bytes
    }
    pub fn reset(&mut self) {
        self.rows = Vec::new();
        self.previous = None;
        self.generation = 0;
        self.retained_bytes = 0;
    }
    /// Invalid bases and offsets reset the consumer so its next capture is full.
    /// Oversized frames are delivered, but no rows or assembly remain retained.
    pub fn encode(&mut self, update: &RemoteGridUpdate) -> Option<Vec<u8>> {
        match self.apply(update) {
            Ok(payload) => payload,
            Err(()) => {
                self.reset();
                None
            }
        }
    }
    fn apply(&mut self, update: &RemoteGridUpdate) -> Result<Option<Vec<u8>>, ()> {
        let snapshot = &update.snapshot;
        let cols = usize::from(snapshot.cols);
        let rows = usize::from(snapshot.rows);
        let row_bytes = cols.checked_mul(Layout::CELL_STRIDE).ok_or(())?;
        if cols == 0
            || rows == 0
            || snapshot.cells.len() != update.row_indices.len().checked_mul(row_bytes).ok_or(())?
        {
            return Err(());
        }
        let mut seen = vec![false; rows];
        for &index in &update.row_indices {
            let index = usize::from(index);
            if index >= rows || seen[index] {
                return Err(());
            }
            seen[index] = true;
        }
        if update.full_refresh {
            if update.row_indices.len() != rows {
                return Err(());
            }
        } else if update.base_generation != self.generation
            || self.rows.len() != rows
            || self
                .previous
                .as_ref()
                .is_none_or(|p| p.cols != snapshot.cols)
        {
            return Err(());
        }
        if !update.full_refresh
            && update.row_indices.is_empty()
            && self.previous.as_ref().is_some_and(|previous| {
                previous.cursor_col == snapshot.cursor_col
                    && previous.cursor_row == snapshot.cursor_row
                    && previous.cursor_visible == snapshot.cursor_visible
                    && previous.scrollback_rows == snapshot.scrollback_rows
                    && previous.display_offset == snapshot.display_offset
            })
        {
            self.generation = update.generation;
            return Ok(None);
        }
        // Move unchanged rows instead of cloning the entire viewport per delta.
        let mut next_rows = if update.full_refresh {
            (0..rows).map(|_| Row::default()).collect()
        } else {
            std::mem::take(&mut self.rows)
        };
        for (packed, &index) in update.row_indices.iter().enumerate() {
            let mut cells = snapshot.cells[packed * row_bytes..(packed + 1) * row_bytes].to_vec();
            let mut clusters = Vec::new();
            for col in 0..cols {
                let at = col * Layout::CELL_STRIDE;
                let offset =
                    u32::from_le_bytes(cells[at..at + 4].try_into().map_err(|_| ())?) as usize;
                let len = usize::from(u16::from_le_bytes(
                    cells[at + 10..at + 12].try_into().map_err(|_| ())?,
                ));
                let end = offset
                    .checked_add(len)
                    .filter(|&end| end <= snapshot.clusters.len())
                    .ok_or(())?;
                let local = u32::try_from(clusters.len()).map_err(|_| ())?;
                cells[at..at + 4].copy_from_slice(&local.to_le_bytes());
                clusters.extend_from_slice(&snapshot.clusters[offset..end]);
            }
            next_rows[usize::from(index)] = Row { cells, clusters };
        }
        let full_bytes = rows.checked_mul(row_bytes).ok_or(())?;
        let mut cells = Vec::with_capacity(full_bytes);
        let mut clusters = Vec::new();
        for row in &next_rows {
            if row.cells.len() != row_bytes {
                return Err(());
            }
            let start = cells.len();
            cells.extend_from_slice(&row.cells);
            let cluster_base = u32::try_from(clusters.len()).map_err(|_| ())?;
            for col in 0..cols {
                let at = start + col * Layout::CELL_STRIDE;
                let local = u32::from_le_bytes(cells[at..at + 4].try_into().map_err(|_| ())?);
                let global = local.checked_add(cluster_base).ok_or(())?;
                cells[at..at + 4].copy_from_slice(&global.to_le_bytes());
            }
            clusters.extend_from_slice(&row.clusters);
        }
        let assembled = RemoteTerminalGridSnapshot {
            cols: snapshot.cols,
            rows: snapshot.rows,
            cursor_col: snapshot.cursor_col,
            cursor_row: snapshot.cursor_row,
            cursor_visible: snapshot.cursor_visible,
            scrollback_rows: snapshot.scrollback_rows,
            display_offset: snapshot.display_offset,
            cells,
            clusters,
        };
        let payload = assembled.encode().ok_or(())?;
        let bytes = next_rows
            .iter()
            .try_fold(0usize, |sum, row| {
                sum.checked_add(row.cells.capacity())?
                    .checked_add(row.clusters.capacity())
            })
            .ok_or(())?
            .checked_add(assembled.cells.capacity())
            .and_then(|sum| sum.checked_add(assembled.clusters.capacity()))
            .and_then(|sum| {
                next_rows
                    .capacity()
                    .checked_mul(std::mem::size_of::<Row>())
                    .and_then(|metadata| sum.checked_add(metadata))
            })
            .ok_or(())?;
        if bytes <= self.maximum_bytes {
            self.rows = next_rows;
            self.previous = Some(assembled);
            self.generation = update.generation;
            self.retained_bytes = bytes;
        } else {
            self.reset();
        }
        Ok(Some(payload))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn update(
        text: &[&str],
        indices: &[u16],
        full: bool,
        generation: u64,
        base: u64,
    ) -> RemoteGridUpdate {
        let mut cells = Vec::new();
        let mut clusters = Vec::new();
        for grapheme in text {
            cells.extend_from_slice(&(clusters.len() as u32).to_le_bytes());
            cells.extend_from_slice(&[0; 6]);
            cells.extend_from_slice(&(grapheme.len() as u16).to_le_bytes());
            cells.extend_from_slice(&[1, 0, 0, 0, 0, 0, 0, 0]);
            clusters.extend_from_slice(grapheme.as_bytes());
        }
        RemoteGridUpdate {
            base_generation: base,
            generation,
            full_refresh: full,
            row_indices: indices.to_vec(),
            snapshot: RemoteTerminalGridSnapshot {
                cols: 1,
                rows: 2,
                cursor_col: 0,
                cursor_row: 0,
                cursor_visible: true,
                scrollback_rows: 0,
                display_offset: 0,
                cells,
                clusters,
            },
        }
    }
    #[test]
    fn dirty_rows_preserve_unicode_and_rebase_delta_local_offsets() {
        let mut cache = RemoteGridSnapshotCache::default();
        cache
            .encode(&update(&["é", "👩🏽‍💻"], &[0, 1], true, 1, 0))
            .unwrap();
        let payload = cache.encode(&update(&["界"], &[0], false, 2, 1)).unwrap();
        let decoded = RemoteTerminalGridSnapshot::decode(&payload).unwrap();
        assert_eq!(decoded.clusters, "界👩🏽‍💻".as_bytes());
        assert_eq!(
            u32::from_le_bytes(decoded.cells[20..24].try_into().unwrap()),
            "界".len() as u32
        );
        assert_eq!(cache.generation(), 2);
    }
    #[test]
    fn unchanged_is_suppressed_but_cursor_and_scrollback_changes_are_delivered() {
        let mut cache = RemoteGridSnapshotCache::default();
        cache
            .encode(&update(&["a", "b"], &[0, 1], true, 1, 0))
            .unwrap();
        let retained = cache.retained_bytes();
        assert!(cache.encode(&update(&[], &[], false, 2, 1)).is_none());
        assert_eq!(cache.retained_bytes(), retained);
        assert_eq!(cache.generation(), 2);
        let mut cursor = update(&[], &[], false, 3, 2);
        cursor.snapshot.cursor_row = 1;
        assert_eq!(
            RemoteTerminalGridSnapshot::decode(&cache.encode(&cursor).unwrap())
                .unwrap()
                .cursor_row,
            1
        );
        let mut scroll = update(&[], &[], false, 4, 3);
        scroll.snapshot.cursor_row = 1;
        scroll.snapshot.display_offset = 2;
        assert!(cache.encode(&scroll).is_some());
    }
    #[test]
    fn forced_full_and_resize_replace_the_consumer_cache() {
        let mut cache = RemoteGridSnapshotCache::default();
        let full = update(&["a", "b"], &[0, 1], true, 1, 0);
        assert!(cache.encode(&full).is_some());
        assert!(cache.encode(&full).is_some());
        let mut resize = update(&["c"], &[0], true, 2, 0);
        resize.snapshot.rows = 1;
        let payload = cache.encode(&resize).unwrap();
        assert_eq!(
            RemoteTerminalGridSnapshot::decode(&payload)
                .unwrap()
                .clusters,
            b"c"
        );
    }
    #[test]
    fn bad_bases_duplicate_or_missing_rows_and_bad_clusters_fail_closed() {
        for invalid in [
            update(&["a"], &[0], true, 1, 0),
            update(&["a", "b"], &[0, 0], true, 1, 0),
            update(&["x"], &[4], false, 2, 1),
        ] {
            let mut cache = RemoteGridSnapshotCache::default();
            cache.encode(&update(&["a", "b"], &[0, 1], true, 1, 0));
            assert!(cache.encode(&invalid).is_none());
            assert_eq!(cache.generation(), 0);
            assert_eq!(cache.retained_bytes(), 0);
        }
        let mut cache = RemoteGridSnapshotCache::default();
        cache.encode(&update(&["a", "b"], &[0, 1], true, 5, 0));
        assert!(cache.encode(&update(&["x"], &[1], false, 6, 4)).is_none());
        assert_eq!(cache.generation(), 0);
        let mut bad = update(&["a", "b"], &[0, 1], true, 1, 0);
        bad.snapshot.cells[0] = 255;
        assert!(cache.encode(&bad).is_none());
    }
    #[test]
    fn retained_bound_counts_allocated_capacity_and_row_metadata() {
        let frame = update(&["a", "b"], &[0, 1], true, 1, 0);
        let logical_bytes = 2 * (frame.snapshot.cells.len() + frame.snapshot.clusters.len());
        let mut cache = RemoteGridSnapshotCache::new(logical_bytes);
        assert!(cache.encode(&frame).is_some());
        assert_eq!(cache.retained_bytes(), 0);
        assert_eq!(cache.generation(), 0);
        let mut cache = RemoteGridSnapshotCache::default();
        cache.encode(&frame).unwrap();
        assert!(cache.retained_bytes() > logical_bytes);
        assert!(cache.retained_bytes() <= 4 * 1024 * 1024);
    }
    #[test]
    fn oversized_is_delivered_without_retaining_allocations() {
        let mut cache = RemoteGridSnapshotCache::new(1);
        assert!(
            cache
                .encode(&update(&["a", "b"], &[0, 1], true, 1, 0))
                .is_some()
        );
        assert_eq!(cache.generation(), 0);
        assert_eq!(cache.retained_bytes(), 0);
        assert_eq!(cache.rows.capacity(), 0);
        assert!(cache.encode(&update(&["x"], &[1], false, 2, 1)).is_none());
    }
}
