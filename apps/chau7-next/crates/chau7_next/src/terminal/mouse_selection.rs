//! Safe text accumulation for dragging across a scrolling alternate-screen TUI.
//!
//! The native terminal selection only knows the current screen. During a local
//! drag we retain a bounded row timeline, but advance it only when a unique
//! content band can be matched between two complete screen snapshots.

use std::collections::{HashSet, VecDeque};

use chau7_terminal::{StyledRow, StyledRun, StyledScreen, StyledSelection};

/// Per-gesture ceiling for the retained timeline and live screen snapshots.
/// The backend separately refuses any individual screen snapshot above 8 MiB.
const MAX_RETAINED_BYTES: usize = 32 * 1024 * 1024;
const MAX_WHEEL_REPORTS: u16 = 256;
const MIN_MATCHED_ROWS: usize = 2;

#[derive(Clone, Debug, PartialEq, Eq)]
struct PlainRow {
    text: String,
    wrapped: bool,
}

impl PlainRow {
    fn from_row(row: &StyledRow) -> Self {
        Self {
            text: row.plain_text(),
            wrapped: row.wrapped,
        }
    }

    fn is_empty(&self) -> bool {
        self.text.is_empty()
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
struct ContentBand {
    start: usize,
    end: usize,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
struct BandShift {
    /// Positive means the viewport moved down through the content timeline.
    delta: isize,
    band: ContentBand,
}

/// Accumulates a selection only while the visible content can be matched
/// without guessing. On the first ambiguous redraw it freezes at the last
/// validated selection, so copied text cannot silently jump to another row.
pub(super) struct AltScreenSelection {
    screen: StyledScreen,
    plain_rows: Vec<PlainRow>,
    anchor_row: usize,
    anchor_column: usize,
    endpoint_row: usize,
    endpoint_column: usize,
    block: bool,
    band: Option<ContentBand>,
    timeline: VecDeque<StyledRow>,
    timeline_first: i64,
    visible_first: i64,
    anchor_line: i64,
    endpoint_line: i64,
    wheel_reports: u16,
    frozen: bool,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) struct VisibleSelection {
    pub anchor_column: usize,
    pub anchor_row: usize,
    pub endpoint_column: usize,
    pub endpoint_row: usize,
    pub block: bool,
}

impl AltScreenSelection {
    pub(super) fn start(
        screen: StyledScreen,
        column: usize,
        row: usize,
        block: bool,
    ) -> Option<Self> {
        if screen.columns == 0 || screen.rows.is_empty() || row >= screen.rows.len() {
            return None;
        }
        let plain_rows = plain_rows(&screen);
        if screen_bytes(&screen, &plain_rows) > MAX_RETAINED_BYTES {
            return None;
        }
        Some(Self {
            endpoint_row: row,
            endpoint_column: column.min(screen.columns.saturating_sub(1)),
            anchor_row: row,
            anchor_column: column.min(screen.columns.saturating_sub(1)),
            screen,
            plain_rows,
            block,
            band: None,
            timeline: VecDeque::new(),
            timeline_first: 0,
            visible_first: 0,
            anchor_line: 0,
            endpoint_line: 0,
            wheel_reports: 0,
            frozen: false,
        })
    }

    /// Observe a complete screen. `false` freezes the snapshot and tells the
    /// caller to stop sending further scroll input for this gesture.
    pub(super) fn observe(&mut self, screen: StyledScreen) -> bool {
        if self.frozen {
            return false;
        }
        if screen.columns != self.screen.columns
            || screen.rows.len() != self.screen.rows.len()
            || screen.rows.is_empty()
        {
            return self.freeze();
        }
        let next_plain = plain_rows(&screen);
        if screen_bytes(&screen, &next_plain) > MAX_RETAINED_BYTES {
            return self.freeze();
        }

        // A stationary frame, including a one-glyph pinned spinner update, is
        // safe to refresh without changing the logical line IDs.
        if stationary_frame(&self.plain_rows, &next_plain) {
            if let Some(band) = self.band {
                if (band.start..band.end)
                    .any(|index| !rows_equal(&self.plain_rows[index], &next_plain[index]))
                {
                    return self.freeze();
                }
                let live_bytes = screen_bytes(&self.screen, &self.plain_rows)
                    .saturating_add(timeline_bytes(&self.timeline))
                    .saturating_add(screen_bytes(&screen, &next_plain));
                if live_bytes > MAX_RETAINED_BYTES {
                    return self.freeze();
                }
                for (row_offset, row) in screen.rows[band.start..band.end].iter().enumerate() {
                    let id = self.visible_first + row_offset as i64;
                    if let Some(index) =
                        timeline_index(id, self.timeline_first, self.timeline.len())
                    {
                        self.timeline[index] = row.clone();
                    }
                }
            }
            self.screen = screen;
            self.plain_rows = next_plain;
            self.endpoint_row = self.clamp_screen_row(self.endpoint_row);
            self.endpoint_line = self.line_for_screen_row(self.endpoint_row);
            return true;
        }

        let Some(shift) = infer_band_shift(&self.plain_rows, &next_plain) else {
            return self.freeze();
        };
        if let Some(current_band) = self.band {
            if current_band != shift.band {
                return self.freeze();
            }
        } else {
            if !(shift.band.start..shift.band.end).contains(&self.anchor_row) {
                return self.freeze();
            }
            let initial_band = self.screen.rows[shift.band.start..shift.band.end].to_vec();
            self.timeline = initial_band.into();
            self.timeline_first = 0;
            self.visible_first = 0;
            self.anchor_line = (self.anchor_row - shift.band.start) as i64;
            self.endpoint_line = self.anchor_line;
            self.band = Some(shift.band);
        }

        if !self.apply_shift(shift, &screen, &next_plain) {
            return self.freeze();
        }
        self.screen = screen;
        self.plain_rows = next_plain;
        self.endpoint_row = self.clamp_screen_row(self.endpoint_row);
        self.endpoint_line = self.line_for_screen_row(self.endpoint_row);
        true
    }

    /// Set the endpoint and return its physical row after clamping it to the
    /// inferred moving band. Fixed headers, spinners, and footers stay out of
    /// the logical selection.
    pub(super) fn set_endpoint(&mut self, column: usize, row: usize) -> Option<usize> {
        if self.frozen || self.screen.rows.is_empty() {
            return None;
        }
        self.endpoint_row = self.clamp_screen_row(row);
        self.endpoint_column = column.min(self.screen.columns.saturating_sub(1));
        self.endpoint_line = self.line_for_screen_row(self.endpoint_row);
        Some(self.endpoint_row)
    }

    /// The native grid can draw only the visible part of a logical selection.
    /// Keep the logical anchor in the timeline, but pin its display endpoint
    /// to the corresponding screen edge after it scrolls out of view.
    pub(super) fn visible_selection(&self) -> Option<VisibleSelection> {
        if self.screen.rows.is_empty() {
            return None;
        }
        let (band_start, band_end, visible_first, anchor_line, endpoint_line) =
            if let Some(band) = self.band {
                (
                    band.start,
                    band.end,
                    self.visible_first,
                    self.anchor_line,
                    self.endpoint_line,
                )
            } else {
                (
                    0,
                    self.screen.rows.len(),
                    0,
                    self.anchor_row as i64,
                    self.endpoint_row as i64,
                )
            };
        if band_start >= band_end {
            return None;
        }
        let visible_last = visible_first + (band_end - band_start) as i64 - 1;
        let anchor_visible_line = anchor_line.clamp(visible_first, visible_last);
        let endpoint_visible_line = endpoint_line.clamp(visible_first, visible_last);
        let forward = (anchor_line, self.anchor_column) <= (endpoint_line, self.endpoint_column);
        let (anchor_column, endpoint_column) = if self.block {
            (self.anchor_column, self.endpoint_column)
        } else if forward {
            (
                if anchor_line < visible_first {
                    0
                } else {
                    self.anchor_column
                },
                if endpoint_line > visible_last {
                    self.screen.columns.saturating_sub(1)
                } else {
                    self.endpoint_column
                },
            )
        } else {
            (
                if anchor_line > visible_last {
                    self.screen.columns.saturating_sub(1)
                } else {
                    self.anchor_column
                },
                if endpoint_line < visible_first {
                    0
                } else {
                    self.endpoint_column
                },
            )
        };
        Some(VisibleSelection {
            anchor_column,
            anchor_row: band_start + (anchor_visible_line - visible_first) as usize,
            endpoint_column,
            endpoint_row: band_start + (endpoint_visible_line - visible_first) as usize,
            block: self.block,
        })
    }

    /// Report wheel input over selected content. Until a moving band has been
    /// inferred, the original anchor is the only known content coordinate.
    pub(super) fn wheel_target(&self) -> Option<(usize, usize)> {
        if self.frozen || self.screen.rows.is_empty() {
            return None;
        }
        if let Some(band) = self.band {
            let visible_last = self.visible_first + band.end.saturating_sub(band.start) as i64 - 1;
            let visible_line = self.endpoint_line.clamp(self.visible_first, visible_last);
            Some((
                self.endpoint_column,
                band.start + (visible_line - self.visible_first) as usize,
            ))
        } else {
            Some((self.anchor_column, self.anchor_row))
        }
    }

    pub(super) fn can_send_wheel(&self) -> bool {
        !self.frozen && self.wheel_reports < MAX_WHEEL_REPORTS
    }

    pub(super) fn note_wheel_sent(&mut self) {
        self.wheel_reports = self.wheel_reports.saturating_add(1);
    }

    pub(super) fn selection(&self) -> Option<StyledSelection> {
        if self.screen.rows.is_empty() {
            return None;
        }
        if self.band.is_none() {
            return Some(selection_from_rows(
                &self.screen.rows,
                self.anchor_row,
                self.anchor_column,
                self.endpoint_row,
                self.endpoint_column,
                self.block,
            ));
        }

        let first = self.timeline_first;
        let end = first + self.timeline.len() as i64;
        let anchor = self.anchor_line.clamp(first, end.saturating_sub(1));
        let endpoint = self.endpoint_line.clamp(first, end.saturating_sub(1));
        let start_line = anchor.min(endpoint);
        let end_line = anchor.max(endpoint);
        let range_start = (start_line - first) as usize;
        let range_end = (end_line - first) as usize;
        let rows: Vec<_> = self
            .timeline
            .iter()
            .skip(range_start)
            .take(range_end - range_start + 1)
            .cloned()
            .collect();
        let forward = (anchor, self.anchor_column) <= (endpoint, self.endpoint_column);
        let (start_column, end_column) = if self.block {
            (
                self.anchor_column.min(self.endpoint_column),
                self.anchor_column.max(self.endpoint_column),
            )
        } else if forward {
            (self.anchor_column, self.endpoint_column)
        } else {
            (self.endpoint_column, self.anchor_column)
        };
        Some(selection_from_ordered_rows(
            &rows,
            start_column,
            end_column,
            self.block,
        ))
    }

    fn apply_shift(&mut self, shift: BandShift, screen: &StyledScreen, plain: &[PlainRow]) -> bool {
        let band_len = shift.band.end.saturating_sub(shift.band.start);
        let amount = shift.delta.unsigned_abs();
        if amount == 0 || amount >= band_len || self.timeline.is_empty() {
            return false;
        }
        let next_visible = self.visible_first + shift.delta as i64;

        // Estimate the exact next timeline before cloning rows. Previously
        // visited IDs are refreshed in place; reversing direction must never
        // prepend or append duplicate copies of rows already retained.
        let timeline_end = self.timeline_first + self.timeline.len() as i64;
        let mut retained_timeline_bytes = timeline_bytes(&self.timeline);
        for (row_offset, row) in screen.rows[shift.band.start..shift.band.end]
            .iter()
            .enumerate()
        {
            let line = next_visible + row_offset as i64;
            if let Some(index) = timeline_index(line, self.timeline_first, self.timeline.len()) {
                retained_timeline_bytes = retained_timeline_bytes
                    .saturating_sub(row_bytes(&self.timeline[index]))
                    .saturating_add(row_bytes(row));
            } else if line < self.timeline_first || line >= timeline_end {
                retained_timeline_bytes = retained_timeline_bytes.saturating_add(row_bytes(row));
            } else {
                return false;
            }
        }
        let retained = screen_bytes(&self.screen, &self.plain_rows)
            .saturating_add(retained_timeline_bytes)
            .saturating_add(screen_bytes(screen, plain));
        if retained > MAX_RETAINED_BYTES {
            return false;
        }

        let mut prepend = Vec::new();
        let mut append = Vec::new();
        for (row_offset, row) in screen.rows[shift.band.start..shift.band.end]
            .iter()
            .enumerate()
        {
            let line = next_visible + row_offset as i64;
            if line < self.timeline_first {
                prepend.push(row.clone());
            } else if line >= timeline_end {
                append.push(row.clone());
            }
        }
        while let Some(row) = prepend.pop() {
            self.timeline.push_front(row);
        }
        self.timeline_first = self.timeline_first.min(next_visible);
        for row in append {
            self.timeline.push_back(row);
        }
        self.visible_first = next_visible;

        // Refresh styles and text for every row that overlaps the new visible
        // range. New rows outside the prior range were already added above.
        for (row_offset, row) in screen.rows[shift.band.start..shift.band.end]
            .iter()
            .enumerate()
        {
            let id = self.visible_first + row_offset as i64;
            if let Some(index) = timeline_index(id, self.timeline_first, self.timeline.len()) {
                self.timeline[index] = row.clone();
            }
        }
        true
    }

    fn clamp_screen_row(&self, row: usize) -> usize {
        if let Some(band) = self.band {
            row.clamp(band.start, band.end.saturating_sub(1))
        } else {
            row.min(self.screen.rows.len().saturating_sub(1))
        }
    }

    fn line_for_screen_row(&self, row: usize) -> i64 {
        if let Some(band) = self.band {
            self.visible_first + row.saturating_sub(band.start) as i64
        } else {
            row as i64
        }
    }

    fn freeze(&mut self) -> bool {
        self.frozen = true;
        false
    }
}

fn plain_rows(screen: &StyledScreen) -> Vec<PlainRow> {
    screen.rows.iter().map(PlainRow::from_row).collect()
}

fn row_bytes(row: &StyledRow) -> usize {
    std::mem::size_of::<StyledRow>()
        .saturating_add(
            row.cells
                .len()
                .saturating_mul(std::mem::size_of::<chau7_terminal::StyledCell>()),
        )
        .saturating_add(
            row.cells
                .iter()
                .map(|cell| {
                    cell.run
                        .text
                        .len()
                        .saturating_add(cell.run.link.as_ref().map_or(0, String::len))
                        .saturating_add(std::mem::size_of::<StyledRun>())
                })
                .sum::<usize>(),
        )
}

fn screen_bytes(screen: &StyledScreen, plain: &[PlainRow]) -> usize {
    std::mem::size_of::<StyledScreen>()
        .saturating_add(screen.rows.iter().map(row_bytes).sum::<usize>())
        .saturating_add(
            plain
                .iter()
                .map(|row| std::mem::size_of::<PlainRow>() + row.text.len())
                .sum::<usize>(),
        )
}

fn timeline_bytes(rows: &VecDeque<StyledRow>) -> usize {
    rows.iter().map(row_bytes).sum()
}

fn timeline_index(line: i64, first: i64, len: usize) -> Option<usize> {
    let index = line.checked_sub(first)?;
    (index >= 0 && index < len as i64).then_some(index as usize)
}

fn rows_equal(left: &PlainRow, right: &PlainRow) -> bool {
    left == right
}

/// Recognize a fixed row with an optional one-symbol animation, such as the
/// Braille spinner next to a pinned Codex status line.
fn stationary_boundary(left: &PlainRow, right: &PlainRow) -> bool {
    rows_equal(left, right) || one_symbol_changed(left, right)
}

fn one_symbol_changed(left: &PlainRow, right: &PlainRow) -> bool {
    if left.wrapped != right.wrapped {
        return false;
    }
    let a: Vec<char> = left.text.chars().collect();
    let b: Vec<char> = right.text.chars().collect();
    if a.len() != b.len() || a.is_empty() {
        return false;
    }
    let mut difference = None;
    for (index, (left, right)) in a.iter().zip(&b).enumerate() {
        if left != right
            && (difference.replace(index).is_some()
                || left.is_alphanumeric()
                || right.is_alphanumeric()
                || left.is_whitespace()
                || right.is_whitespace())
        {
            return false;
        }
    }
    difference.is_some()
}

/// Same-position frames can differ only by a single pinned spinner row.
fn stationary_frame(left: &[PlainRow], right: &[PlainRow]) -> bool {
    if left.len() != right.len() {
        return false;
    }
    let mut changed_spinner = false;
    for (left, right) in left.iter().zip(right) {
        if rows_equal(left, right) {
            continue;
        }
        if changed_spinner || !one_symbol_changed(left, right) {
            return false;
        }
        changed_spinner = true;
    }
    true
}

fn infer_band_shift(old: &[PlainRow], new: &[PlainRow]) -> Option<BandShift> {
    if old.len() != new.len() || old.len() < 4 {
        return None;
    }
    let count = old.len();
    let mut candidates = HashSet::new();
    for delta in -((count - 1) as isize)..=(count - 1) as isize {
        if delta == 0 {
            continue;
        }
        let aligned_start = if delta < 0 { (-delta) as usize } else { 0 };
        let aligned_end = if delta > 0 {
            count - delta as usize
        } else {
            count
        };
        if aligned_end.saturating_sub(aligned_start) < MIN_MATCHED_ROWS {
            continue;
        }
        let mut cursor = aligned_start;
        while cursor < aligned_end {
            if !rows_equal(&old[(cursor as isize + delta) as usize], &new[cursor]) {
                cursor += 1;
                continue;
            }
            let run_start = cursor;
            while cursor < aligned_end
                && rows_equal(&old[(cursor as isize + delta) as usize], &new[cursor])
            {
                cursor += 1;
            }
            if !has_distinct_nonempty_rows(&new[run_start..cursor]) {
                continue;
            }
            let Some(band) = infer_band_bounds(old, new, delta, run_start, cursor) else {
                continue;
            };
            if valid_band_shift(old, new, delta, band) {
                candidates.insert(BandShift { delta, band });
            }
        }
    }
    (candidates.len() == 1).then(|| *candidates.iter().next().unwrap())
}

fn has_distinct_nonempty_rows(rows: &[PlainRow]) -> bool {
    let mut distinct = HashSet::new();
    let mut nonempty = 0;
    for row in rows.iter().filter(|row| !row.is_empty()) {
        nonempty += 1;
        distinct.insert(row.text.as_str());
    }
    nonempty >= MIN_MATCHED_ROWS && distinct.len() >= MIN_MATCHED_ROWS
}

fn infer_band_bounds(
    old: &[PlainRow],
    new: &[PlainRow],
    delta: isize,
    run_start: usize,
    run_end: usize,
) -> Option<ContentBand> {
    let count = old.len();
    let mut start = 0;
    for index in (0..run_start).rev() {
        if is_fixed_row(old, new, index, delta) && !old[index].is_empty() {
            let mut boundary_end = index;
            while boundary_end + 1 < run_start
                && old[boundary_end + 1].is_empty()
                && rows_equal(&old[boundary_end + 1], &new[boundary_end + 1])
            {
                boundary_end += 1;
            }
            start = boundary_end + 1;
            break;
        }
    }

    let mut end = count;
    for index in run_end..count {
        if is_fixed_row(old, new, index, delta) && !old[index].is_empty() {
            let mut boundary_start = index;
            while boundary_start > run_end
                && old[boundary_start - 1].is_empty()
                && rows_equal(&old[boundary_start - 1], &new[boundary_start - 1])
            {
                boundary_start -= 1;
            }
            end = boundary_start;
            break;
        }
    }
    (start < end).then_some(ContentBand { start, end })
}

fn is_fixed_row(old: &[PlainRow], new: &[PlainRow], index: usize, delta: isize) -> bool {
    let left = &old[index];
    let right = &new[index];
    if left.is_empty() || !stationary_boundary(left, right) {
        return false;
    }
    let shifted = index as isize + delta;
    if (0..old.len() as isize).contains(&shifted) && rows_equal(&old[shifted as usize], right) {
        return false;
    }
    true
}

fn valid_band_shift(old: &[PlainRow], new: &[PlainRow], delta: isize, band: ContentBand) -> bool {
    let start = if delta < 0 {
        band.start.saturating_add(delta.unsigned_abs())
    } else {
        band.start
    };
    let end = if delta > 0 {
        band.end.saturating_sub(delta as usize)
    } else {
        band.end
    };
    if end.saturating_sub(start) < MIN_MATCHED_ROWS {
        return false;
    }
    let mut matched = Vec::new();
    for new_row in start..end {
        let old_row = (new_row as isize + delta) as usize;
        if !rows_equal(&old[old_row], &new[new_row]) {
            return false;
        }
        // Stable nonempty rows inside the shifted region are pinned content or
        // repeated-line ambiguity. Blank rows occur inside normal TUI buffers;
        // they can overlap without changing the line mapping.
        if !new[new_row].is_empty() && rows_equal(&old[new_row], &new[new_row]) {
            return false;
        }
        if !new[new_row].is_empty() {
            matched.push(&new[new_row]);
        }
    }
    if matched.len() < MIN_MATCHED_ROWS {
        return false;
    }
    let distinct: HashSet<_> = matched.iter().map(|row| row.text.as_str()).collect();
    distinct.len() >= MIN_MATCHED_ROWS
}

fn selection_from_rows(
    rows: &[StyledRow],
    anchor_row: usize,
    anchor_column: usize,
    endpoint_row: usize,
    endpoint_column: usize,
    block: bool,
) -> StyledSelection {
    let first = anchor_row.min(endpoint_row);
    let last = anchor_row.max(endpoint_row);
    let forward = (anchor_row, anchor_column) <= (endpoint_row, endpoint_column);
    selection_from_ordered_rows(
        &rows[first..=last],
        if block {
            anchor_column.min(endpoint_column)
        } else if forward {
            anchor_column
        } else {
            endpoint_column
        },
        if block {
            anchor_column.max(endpoint_column)
        } else if forward {
            endpoint_column
        } else {
            anchor_column
        },
        block,
    )
}

fn selection_from_ordered_rows(
    rows: &[StyledRow],
    start_column: usize,
    end_column: usize,
    block: bool,
) -> StyledSelection {
    let mut result = StyledSelection::default();
    for (index, row) in rows.iter().enumerate() {
        let start = if block || index == 0 { start_column } else { 0 };
        let end = if block || index + 1 == rows.len() {
            end_column
        } else {
            usize::MAX
        };
        result.append(row.selection(start, end));
        if index + 1 < rows.len() && (block || !row.wrapped) {
            result.push(StyledRun {
                text: "\n".into(),
                ..Default::default()
            });
        }
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;

    fn screen(lines: &[&str]) -> StyledScreen {
        let columns = lines
            .iter()
            .map(|line| line.chars().count())
            .max()
            .unwrap_or(0)
            .max(1);
        StyledScreen {
            columns,
            rows: lines
                .iter()
                .map(|line| StyledRow {
                    cells: line
                        .chars()
                        .enumerate()
                        .map(|(column, character)| chau7_terminal::StyledCell {
                            column,
                            width: 1,
                            run: StyledRun {
                                text: character.to_string(),
                                ..Default::default()
                            },
                        })
                        .collect(),
                    wrapped: false,
                })
                .collect(),
        }
    }

    fn text(selection: Option<StyledSelection>) -> String {
        selection.unwrap().plain_text
    }

    #[test]
    fn accumulates_unique_content_both_directions_without_duplicate_rows() {
        let mut down =
            AltScreenSelection::start(screen(&["one", "two", "three", "four"]), 0, 1, false)
                .unwrap();
        assert!(down.observe(screen(&["two", "three", "four", "five"])));
        down.set_endpoint(3, 3).unwrap();
        assert_eq!(text(down.selection()), "two\nthree\nfour\nfive");

        let mut up =
            AltScreenSelection::start(screen(&["two", "three", "four", "five"]), 3, 2, false)
                .unwrap();
        assert!(up.observe(screen(&["one", "two", "three", "four"])));
        up.set_endpoint(0, 0).unwrap();
        assert_eq!(text(up.selection()), "one\ntwo\nthree\nfour");
    }

    #[test]
    fn reversing_scroll_direction_reuses_retained_rows_without_duplicates() {
        let mut down_up_down =
            AltScreenSelection::start(screen(&["one", "two", "three", "four"]), 0, 1, false)
                .unwrap();
        assert!(down_up_down.observe(screen(&["two", "three", "four", "five"])));
        assert!(down_up_down.observe(screen(&["one", "two", "three", "four"])));
        down_up_down.set_endpoint(3, 3).unwrap();
        assert_eq!(text(down_up_down.selection()), "two\nthree\nfour");
        assert!(down_up_down.observe(screen(&["two", "three", "four", "five"])));
        down_up_down.set_endpoint(3, 3).unwrap();
        assert_eq!(text(down_up_down.selection()), "two\nthree\nfour\nfive");

        let mut up_down =
            AltScreenSelection::start(screen(&["two", "three", "four", "five"]), 0, 2, false)
                .unwrap();
        assert!(up_down.observe(screen(&["one", "two", "three", "four"])));
        assert!(up_down.observe(screen(&["two", "three", "four", "five"])));
        up_down.set_endpoint(3, 3).unwrap();
        assert_eq!(text(up_down.selection()), "four\nfive");
    }

    #[test]
    fn reversed_columns_on_one_row_produce_a_selection() {
        let mut selection = AltScreenSelection::start(screen(&["abcdefgh"]), 7, 0, false).unwrap();
        selection.set_endpoint(2, 0).unwrap();
        assert_eq!(text(selection.selection()), "cdefgh");
    }

    #[test]
    fn visible_selection_clamps_an_offscreen_anchor_to_the_content_edge() {
        let mut selection = AltScreenSelection::start(
            screen(&["header", "alpha", "beta", "gamma", "spinner ⠋", "footer"]),
            0,
            2,
            false,
        )
        .unwrap();
        assert!(selection.observe(screen(&[
            "header",
            "beta",
            "gamma",
            "delta",
            "spinner ⠙",
            "footer",
        ])));
        selection.set_endpoint(6, 3).unwrap();
        assert!(selection.observe(screen(&[
            "header",
            "gamma",
            "delta",
            "epsilon",
            "spinner ⠋",
            "footer",
        ])));
        selection.set_endpoint(6, 3).unwrap();

        let visible = selection.visible_selection().unwrap();
        assert_eq!(visible.anchor_row, 1);
        assert_eq!(visible.anchor_column, 0);
        assert_eq!(visible.endpoint_row, 3);
        assert_eq!(text(selection.selection()), "beta\ngamma\ndelta\nepsilon");
    }

    #[test]
    fn codex_style_band_excludes_fixed_header_spinner_and_footer() {
        let before = screen(&[
            "Codex session",
            "prompt alpha",
            "tool output one",
            "tool output two",
            "spinner ⠋ working",
            "Esc to interrupt",
        ]);
        let after = screen(&[
            "Codex session",
            "tool output one",
            "tool output two",
            "new response",
            "spinner ⠙ working",
            "Esc to interrupt",
        ]);
        let shift = infer_band_shift(&plain_rows(&before), &plain_rows(&after)).unwrap();
        assert_eq!(shift.delta, 1);
        assert_eq!(shift.band, ContentBand { start: 1, end: 4 });

        let mut selection = AltScreenSelection::start(before, 0, 2, false).unwrap();
        assert!(selection.observe(after));
        assert_eq!(selection.set_endpoint(20, 5), Some(3));
        assert!(selection.can_send_wheel());
        assert_eq!(
            text(selection.selection()),
            "tool output one\ntool output two\nnew response"
        );
    }

    #[test]
    fn repeated_or_blank_overlap_and_unpinned_redraw_freeze_last_valid_text() {
        let repeated_before = screen(&["header", "same", "same", "same", "same", "footer"]);
        let repeated_after = screen(&["header", "same", "same", "same", "other", "footer"]);
        assert!(
            infer_band_shift(&plain_rows(&repeated_before), &plain_rows(&repeated_after)).is_none()
        );

        let repeated = screen(&["same", "same", "same", "same", "same"]);
        let mut selection = AltScreenSelection::start(repeated.clone(), 0, 1, false).unwrap();
        let before = text(selection.selection());
        assert!(selection.observe(repeated));
        assert_eq!(text(selection.selection()), before);

        let blanks = screen(&["header", "", "", "footer"]);
        let mut selection = AltScreenSelection::start(blanks.clone(), 0, 0, false).unwrap();
        selection.set_endpoint(5, 0).unwrap();
        assert!(!selection.observe(screen(&["header", "", "changed", "footer"])));
        assert_eq!(text(selection.selection()), "header");

        let mut selection = AltScreenSelection::start(
            screen(&["header", "alpha", "busy 01", "beta", "footer"]),
            0,
            1,
            false,
        )
        .unwrap();
        selection.set_endpoint(4, 1).unwrap();
        assert!(!selection.observe(screen(&["header", "alpha", "busy 02", "beta", "footer"])));
        assert_eq!(text(selection.selection()), "alpha");
    }

    #[test]
    fn spinner_only_redraw_is_stationary_and_does_not_duplicate_content() {
        let mut selection = AltScreenSelection::start(
            screen(&["header", "alpha", "beta", "spinner ⠋", "footer"]),
            0,
            1,
            false,
        )
        .unwrap();
        selection.set_endpoint(4, 1).unwrap();
        assert!(selection.observe(screen(&["header", "alpha", "beta", "spinner ⠙", "footer"])));
        assert_eq!(text(selection.selection()), "alpha");
    }
}
