//! Styled selection snapshots for Rust clipboard and TUI drag selection.
//! These types are Rust-only and do not change the terminal's C ABI.

use alacritty_terminal::grid::Dimensions;
use alacritty_terminal::index::{Column, Line, Point};
use alacritty_terminal::selection::SelectionType;
use alacritty_terminal::term::cell::{Cell, Flags, LineLength};

use crate::{Chau7Terminal, ThemeColors, color_to_rgb_with_theme};

const MAX_SELECTION_RICH_BYTES: usize = 8 * 1024 * 1024;
const MAX_SELECTION_RUNS: usize = 100_000;
const MAX_SELECTION_LINK_BYTES: usize = 8 * 1024;

#[derive(Clone, Copy)]
struct SelectionLimits {
    rich_bytes: usize,
    runs: usize,
    link_bytes: usize,
}

impl SelectionLimits {
    const DEFAULT: Self = Self {
        rich_bytes: MAX_SELECTION_RICH_BYTES,
        runs: MAX_SELECTION_RUNS,
        link_bytes: MAX_SELECTION_LINK_BYTES,
    };
}

#[derive(Default)]
struct SelectionRichnessBudget {
    bytes: usize,
    cell_runs: usize,
}

impl SelectionRichnessBudget {
    fn reserve_text(&mut self, bytes: usize, limits: SelectionLimits) -> bool {
        self.bytes = self.bytes.saturating_add(bytes);
        self.bytes <= limits.rich_bytes
    }

    /// Charge each temporary cell run before `cell_run` clones its text/link.
    fn reserve_cell(&mut self, cell: &Cell, limits: SelectionLimits) -> bool {
        let link_bytes = cell.hyperlink().map_or(0, |link| link.uri().len());
        if link_bytes > limits.link_bytes {
            return false;
        }
        let text_bytes = cell.c.len_utf8().saturating_add(
            cell.zerowidth()
                .into_iter()
                .flatten()
                .map(|character| character.len_utf8())
                .sum::<usize>(),
        );
        let run_bytes = std::mem::size_of::<StyledRun>()
            .saturating_add(text_bytes)
            .saturating_add(link_bytes);
        self.bytes = self.bytes.saturating_add(run_bytes);
        self.cell_runs = self.cell_runs.saturating_add(1);
        self.bytes <= limits.rich_bytes && self.cell_runs <= limits.runs
    }

    fn reserve_output(&mut self, selection: &StyledSelection, limits: SelectionLimits) -> bool {
        let bytes = selection.plain_text.len().saturating_add(
            selection
                .runs
                .iter()
                .map(|run| {
                    std::mem::size_of::<StyledRun>()
                        .saturating_add(run.text.len())
                        .saturating_add(run.link.as_ref().map_or(0, String::len))
                })
                .fold(0usize, usize::saturating_add),
        );
        self.bytes = self.bytes.saturating_add(bytes);
        self.bytes <= limits.rich_bytes
    }

    fn reserve_output_run(&mut self, run: &StyledRun, limits: SelectionLimits) -> bool {
        self.bytes = self.bytes.saturating_add(
            std::mem::size_of::<StyledRun>()
                .saturating_add(run.text.len())
                .saturating_add(run.link.as_ref().map_or(0, String::len)),
        );
        self.bytes <= limits.rich_bytes
    }
}

fn plain_styled_selection(native: String) -> StyledSelection {
    StyledSelection {
        plain_text: native.clone(),
        runs: vec![StyledRun {
            text: native,
            ..Default::default()
        }],
    }
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct StyledRun {
    pub text: String,
    pub bold: bool,
    pub italic: bool,
    pub underline: bool,
    pub strikethrough: bool,
    pub foreground: Option<[u8; 3]>,
    pub background: Option<[u8; 3]>,
    pub link: Option<String>,
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct StyledSelection {
    pub plain_text: String,
    pub runs: Vec<StyledRun>,
}

impl StyledSelection {
    /// Append text while coalescing adjacent runs with identical attributes.
    pub fn push(&mut self, run: StyledRun) {
        if run.text.is_empty() {
            return;
        }
        self.plain_text.push_str(&run.text);
        if let Some(last) = self.runs.last_mut()
            && last.bold == run.bold
            && last.italic == run.italic
            && last.underline == run.underline
            && last.strikethrough == run.strikethrough
            && last.foreground == run.foreground
            && last.background == run.background
            && last.link == run.link
        {
            last.text.push_str(&run.text);
        } else {
            self.runs.push(run);
        }
    }

    /// Append another snapshot, retaining its exact text and styles.
    pub fn append(&mut self, other: Self) {
        for run in other.runs {
            self.push(run);
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct StyledCell {
    pub column: usize,
    pub width: usize,
    pub run: StyledRun,
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct StyledRow {
    /// Grapheme cells only; wide-character spacer cells are omitted.
    pub cells: Vec<StyledCell>,
    /// The next row continues this logical line.
    pub wrapped: bool,
}

impl StyledRow {
    /// Inclusive cell-column bounds; a partial wide cell keeps its grapheme.
    pub fn selection(&self, start_column: usize, end_column: usize) -> StyledSelection {
        if start_column > end_column {
            return StyledSelection::default();
        }
        let mut result = StyledSelection::default();
        for cell in &self.cells {
            if cell.column <= end_column && cell.column.saturating_add(cell.width) > start_column {
                result.push(cell.run.clone());
            }
        }
        result
    }

    pub fn plain_text(&self) -> String {
        self.cells
            .iter()
            .map(|cell| cell.run.text.as_str())
            .collect()
    }
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct StyledScreen {
    pub columns: usize,
    pub rows: Vec<StyledRow>,
}

fn cell_run(cell: &Cell, theme: &ThemeColors) -> StyledRun {
    let mut fg = color_to_rgb_with_theme(Chau7Terminal::effective_cell_fg(cell), true, theme);
    let mut bg = color_to_rgb_with_theme(cell.bg, false, theme);
    if cell.flags.contains(Flags::INVERSE) {
        std::mem::swap(&mut fg, &mut bg);
    }
    if cell.flags.contains(Flags::DIM) {
        // GPUI paints dim text at 60% opacity over the cell background.
        // Flatten that appearance for clipboard targets with opaque colors.
        let blend = |foreground: u8, background: u8| {
            ((u16::from(foreground) * 3 + u16::from(background) * 2 + 2) / 5) as u8
        };
        fg = (blend(fg.0, bg.0), blend(fg.1, bg.1), blend(fg.2, bg.2));
    }
    if cell.flags.contains(Flags::HIDDEN) {
        fg = bg;
    }
    let mut text = String::from(cell.c);
    text.extend(cell.zerowidth().into_iter().flatten().copied());
    StyledRun {
        text,
        bold: cell.flags.contains(Flags::BOLD),
        italic: cell.flags.contains(Flags::ITALIC),
        underline: cell.flags.intersects(Flags::ALL_UNDERLINES),
        strikethrough: cell.flags.contains(Flags::STRIKEOUT),
        foreground: Some([fg.0, fg.1, fg.2]),
        background: Some([bg.0, bg.1, bg.2]),
        link: cell.hyperlink().map(|link| link.uri().to_owned()),
    }
}

impl Chau7Terminal {
    /// Immutable visible cells, without the selection highlight's color swap.
    /// Allocated only on explicit copy/drag requests, never by the frame loop.
    pub fn visible_styled_screen(&self) -> StyledScreen {
        let terminal = self.term.lock();
        let theme = self.theme_colors.read();
        let grid = terminal.grid();
        let columns = terminal.columns();
        let offset = grid.display_offset() as i32;
        let mut rows = Vec::new();
        let mut bytes = 0usize;
        for row in 0..terminal.screen_lines() {
            let line = &grid[Line(row as i32 - offset)];
            let length = line.line_length().0.min(columns);
            let mut cells = Vec::new();
            for column in 0..length {
                let cell = &line[Column(column)];
                if cell
                    .flags
                    .intersects(Flags::WIDE_CHAR_SPACER | Flags::LEADING_WIDE_CHAR_SPACER)
                {
                    continue;
                }
                bytes = bytes
                    .saturating_add(std::mem::size_of::<StyledCell>())
                    .saturating_add(cell.c.len_utf8())
                    .saturating_add(
                        cell.zerowidth()
                            .into_iter()
                            .flatten()
                            .map(|c| c.len_utf8())
                            .sum::<usize>(),
                    )
                    .saturating_add(cell.hyperlink().map_or(0, |link| link.uri().len()));
                if bytes > 8 * 1024 * 1024 {
                    // Refuse a partial screen: overlap matching must never
                    // mistake truncated rows for the application's viewport.
                    return StyledScreen {
                        columns,
                        rows: Vec::new(),
                    };
                }
                let mut run = cell_run(cell, &theme);
                // Expand tab markers to visual spaces in the column-addressed
                // snapshot. Native clipboard export still preserves tabs.
                if cell.c == '\t' {
                    run.text = " ".into();
                }
                cells.push(StyledCell {
                    column,
                    width: if cell.flags.contains(Flags::WIDE_CHAR) {
                        2
                    } else {
                        1
                    },
                    run,
                });
            }
            rows.push(StyledRow {
                cells,
                wrapped: columns > 0 && line[Column(columns - 1)].flags.contains(Flags::WRAPLINE),
            });
        }
        StyledScreen { columns, rows }
    }

    /// Export the selected text and attributes from one locked grid snapshot.
    /// Alacritty remains the authority for tabs, hard breaks and soft wraps.
    pub fn selection_styled_text(&self) -> Option<StyledSelection> {
        self.selection_styled_text_with_limits(SelectionLimits::DEFAULT)
    }

    fn selection_styled_text_with_limits(
        &self,
        limits: SelectionLimits,
    ) -> Option<StyledSelection> {
        let terminal = self.term.lock();
        let native = terminal.selection_to_string()?;
        let selection = terminal.selection.as_ref()?;
        let range = selection.to_range(&terminal)?;
        let columns = terminal.columns();
        if native.len() > limits.rich_bytes || columns > limits.rich_bytes {
            return Some(plain_styled_selection(native));
        }
        let theme = self.theme_colors.read();
        let block = selection.ty == SelectionType::Block;
        let mut result = StyledSelection::default();
        let mut budget = SelectionRichnessBudget::default();
        for row in range.start.line.0..=range.end.line.0 {
            let line = Line(row);
            let start = if block || line == range.start.line {
                range.start.column.0
            } else {
                0
            };
            let end = if block || line == range.end.line {
                range.end.column.0
            } else {
                columns - 1
            };
            let grid_line = &terminal.grid()[line];
            let length = grid_line.line_length().0.min(end + 1);
            let mut text = terminal.bounds_to_string(
                Point::new(line, Column(start)),
                Point::new(line, Column(end)),
            );
            if !budget.reserve_text(text.len(), limits) {
                return Some(plain_styled_selection(native));
            }
            // bounds_to_string includes a selected leading wide spacer's
            // partner at the final boundary, as native selection does.
            let wrapped_wide = length == columns
                && length >= 2
                && grid_line[Column(length - 1)]
                    .flags
                    .contains(Flags::LEADING_WIDE_CHAR_SPACER);
            let include_wide = if block {
                start != 0 || line == range.end.line
            } else {
                line == range.end.line
            };
            if wrapped_wide && !include_wide {
                text.pop();
            }
            if block {
                text.truncate(text.trim_end().len());
            }
            let first = if grid_line[Column(start)]
                .flags
                .contains(Flags::WIDE_CHAR_SPACER)
            {
                start.saturating_sub(1)
            } else {
                start
            };
            let mut cells = Vec::new();
            for column in first..length {
                let cell = &grid_line[Column(column)];
                if cell
                    .flags
                    .intersects(Flags::WIDE_CHAR_SPACER | Flags::LEADING_WIDE_CHAR_SPACER)
                {
                    continue;
                }
                if !budget.reserve_cell(cell, limits) {
                    return Some(plain_styled_selection(native));
                }
                cells.push(cell_run(cell, &theme));
            }
            if wrapped_wide && include_wide {
                let cell = &terminal.grid()[line - 1i32][Column(0)];
                if !budget.reserve_cell(cell, limits) {
                    return Some(plain_styled_selection(native));
                }
                let mut run = cell_run(cell, &theme);
                run.text = cell.c.to_string();
                cells.push(run);
            }
            // Match from the right so padding expanded by a tab is omitted
            // before real spaces at its next tab stop. This also respects
            // custom stops, which Alacritty keeps private.
            let mut remaining = text.as_str();
            let mut reverse_runs = Vec::new();
            for run in cells.into_iter().rev() {
                if let Some(prefix) = remaining.strip_suffix(&run.text) {
                    remaining = prefix;
                    reverse_runs.push(run);
                } else if !run.text.chars().all(char::is_whitespace) {
                    break;
                }
            }
            if remaining.is_empty() {
                let mut styled = StyledSelection::default();
                for run in reverse_runs.into_iter().rev() {
                    styled.push(run);
                }
                if !budget.reserve_output(&styled, limits) {
                    return Some(plain_styled_selection(native));
                }
                result.append(styled);
            } else {
                // Preserve the exact native bytes on an unfamiliar cell layout.
                let run = StyledRun {
                    text,
                    ..Default::default()
                };
                if !budget.reserve_output_run(&run, limits) {
                    return Some(plain_styled_selection(native));
                }
                result.push(run);
            }
            let hard_break = end + 1 == columns
                && (length == 0
                    || !grid_line[Column(length - 1)]
                        .flags
                        .contains(Flags::WRAPLINE));
            if line != range.end.line && (block || hard_break) {
                let newline = StyledRun {
                    text: "\n".into(),
                    ..Default::default()
                };
                if !budget.reserve_output_run(&newline, limits) {
                    return Some(plain_styled_selection(native));
                }
                result.push(newline);
            }
            if result.runs.len() > limits.runs {
                return Some(plain_styled_selection(native));
            }
        }
        if selection.ty == SelectionType::Lines {
            let newline = StyledRun {
                text: "\n".into(),
                ..Default::default()
            };
            if !budget.reserve_output_run(&newline, limits) {
                return Some(plain_styled_selection(native));
            }
            result.push(newline);
        }
        if result.runs.len() > limits.runs {
            return Some(plain_styled_selection(native));
        }
        if result.plain_text != native {
            // Do not alter a copy if terminal serialization gains new behavior.
            return Some(plain_styled_selection(native));
        }
        Some(result)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn selected(
        bytes: &[u8],
        columns: u16,
        rows: u16,
        start: (i32, i32),
        end: (i32, i32),
        kind: u8,
    ) -> StyledSelection {
        let terminal = Chau7Terminal::new_headless(columns, rows).unwrap();
        terminal.inject_output(bytes);
        terminal.selection_start(start.0, start.1, kind);
        terminal.selection_update(end.0, end.1);
        let snapshot = terminal.selection_styled_text().unwrap();
        assert_eq!(snapshot.plain_text, terminal.selection_text().unwrap());
        assert_eq!(
            snapshot
                .runs
                .iter()
                .map(|run| run.text.as_str())
                .collect::<String>(),
            snapshot.plain_text
        );
        snapshot
    }

    fn selected_with_limits(
        bytes: &[u8],
        columns: u16,
        start: (i32, i32),
        end: (i32, i32),
        limits: SelectionLimits,
    ) -> StyledSelection {
        let terminal = Chau7Terminal::new_headless(columns, 2).unwrap();
        terminal.inject_output(bytes);
        terminal.selection_start(start.0, start.1, 0);
        terminal.selection_update(end.0, end.1);
        let snapshot = terminal.selection_styled_text_with_limits(limits).unwrap();
        let native = terminal.selection_text().unwrap();
        assert_eq!(snapshot.plain_text, native);
        assert_eq!(
            snapshot
                .runs
                .iter()
                .map(|run| run.text.as_str())
                .collect::<String>(),
            native
        );
        snapshot
    }

    fn assert_plain_fallback(snapshot: &StyledSelection, expected: &str) {
        assert_eq!(snapshot.plain_text, expected);
        assert_eq!(snapshot.runs.len(), 1);
        assert_eq!(snapshot.runs[0].text, expected);
        assert_eq!(
            snapshot.runs[0],
            StyledRun {
                text: expected.to_owned(),
                ..Default::default()
            }
        );
    }

    #[test]
    fn richness_byte_and_run_limits_fall_back_without_losing_text() {
        let bytes_limited = selected_with_limits(
            b"\x1b[1mhello",
            12,
            (0, 0),
            (4, 0),
            SelectionLimits {
                rich_bytes: 200,
                runs: 100,
                link_bytes: MAX_SELECTION_LINK_BYTES,
            },
        );
        assert_plain_fallback(&bytes_limited, "hello");

        let runs_limited = selected_with_limits(
            b"\x1b[1mA\x1b[0mB\x1b[1mC\x1b[0mD",
            12,
            (0, 0),
            (3, 0),
            SelectionLimits {
                rich_bytes: MAX_SELECTION_RICH_BYTES,
                runs: 1,
                link_bytes: MAX_SELECTION_LINK_BYTES,
            },
        );
        assert_plain_fallback(&runs_limited, "ABCD");
    }

    #[test]
    fn oversized_hyperlink_falls_back_before_rich_clone_and_keeps_text() {
        let uri = format!(
            "https://example.com/{}",
            "x".repeat(MAX_SELECTION_LINK_BYTES)
        );
        let bytes = format!("\x1b]8;;{uri}\x1b\\linked\x1b]8;;\x1b\\");
        let snapshot = selected_with_limits(
            bytes.as_bytes(),
            20,
            (0, 0),
            (5, 0),
            SelectionLimits::DEFAULT,
        );
        assert_plain_fallback(&snapshot, "linked");
    }

    #[test]
    fn rich_selection_is_kept_under_injected_limits() {
        let snapshot = selected_with_limits(
            b"\x1b[1mstyled",
            20,
            (0, 0),
            (5, 0),
            SelectionLimits {
                rich_bytes: 10_000,
                runs: 100,
                link_bytes: 64,
            },
        );
        assert!(snapshot.runs.iter().any(|run| run.bold));
        assert!(snapshot.runs.iter().any(|run| run.text == "styled"));
    }

    #[test]
    fn preserves_sgr_links_indentation_and_hard_breaks() {
        let result = selected(b"\x1b[1;3;4;9;38;2;10;20;30;48;2;40;50;60mHi\x1b[0m\r\n  \x1b]8;;https://example.com\x1b\\link\x1b]8;;\x1b\\", 20, 3, (0, 0), (5, 1), 0);
        assert_eq!(result.plain_text, "Hi\n  link");
        let first = &result.runs[0];
        assert_eq!(first.text, "Hi");
        assert!(first.bold && first.italic && first.underline && first.strikethrough);
        assert_eq!(first.foreground, Some([10, 20, 30]));
        assert_eq!(first.background, Some([40, 50, 60]));
        assert!(result.runs.iter().any(|run| run.text == "link" && run.link.as_deref() == Some("https://example.com")));
    }

    #[test]
    fn soft_wrap_unicode_tabs_block_and_reversed_selections_match_native() {
        for (bytes, columns, rows, start, end, kind) in [
            (&b"\x1b[1mecho hello"[..], 5, 3, (0, 0), (4, 1), 0),
            ("\x1b[1mé👩🏽‍💻漢e\u{301}".as_bytes(), 20, 2, (0, 0), (10, 0), 0),
            (
                &b"\x1b[1mab\t  xyz\r\n    tail"[..],
                20,
                3,
                (0, 0),
                (7, 1),
                0,
            ),
            (
                &b"\x1b[1mone two\r\nthree four\r\nfive six"[..],
                20,
                4,
                (1, 0),
                (5, 2),
                1,
            ),
            (&b"\x1b[1mfirst\r\nsecond"[..], 20, 3, (5, 1), (0, 0), 0),
            (&b"\x1b[1mfirst\r\nsecond"[..], 20, 3, (0, 0), (5, 1), 3),
        ] {
            let result = selected(bytes, columns, rows, start, end, kind);
            assert!(
                result.runs.iter().any(|run| run.bold),
                "style lost: {:?}",
                result.plain_text
            );
            assert!(
                result
                    .runs
                    .iter()
                    .filter(|run| !run.text.trim().is_empty())
                    .all(|run| run.bold),
                "nonblank text lost style: {:?}",
                result.runs
            );
        }
    }

    #[test]
    fn screen_snapshots_keep_cell_columns_and_ignore_selection_highlight() {
        let terminal = Chau7Terminal::new_headless(12, 3).unwrap();
        terminal.inject_output("\x1b[38;2;20;30;40mA漢e\u{301}\r\nlast".as_bytes());
        let before = terminal.visible_styled_screen();
        terminal.selection_start(0, 0, 0);
        terminal.selection_update(4, 1);
        assert_eq!(before, terminal.visible_styled_screen());
        let row = &before.rows[0];
        assert_eq!(row.plain_text(), "A漢e\u{301}");
        assert_eq!(row.cells[1].column, 1);
        assert_eq!(row.cells[1].width, 2);
        assert_eq!(row.selection(2, 2).plain_text, "漢");
        assert_eq!(row.selection(3, 3).plain_text, "e\u{301}");
    }

    #[test]
    fn inverse_dim_and_hidden_colors_match_the_visible_attributes() {
        let result = selected(
            b"\x1b[38;2;30;60;90;48;2;40;50;60;2;7mX",
            10,
            2,
            (0, 0),
            (0, 0),
            0,
        );
        assert_eq!(result.runs[0].foreground, Some([36, 54, 72]));
        assert_eq!(result.runs[0].background, Some([30, 60, 90]));
        let result = selected(
            b"\x1b[38;2;30;60;90;48;2;40;50;60;8mX",
            10,
            2,
            (0, 0),
            (0, 0),
            0,
        );
        assert_eq!(result.runs[0].foreground, result.runs[0].background);
    }

    #[test]
    fn alternate_screen_and_history_are_exported_without_mutation() {
        let terminal = Chau7Terminal::new_headless(10, 2).unwrap();
        terminal.inject_output(b"old\r\nnew\r\nlast");
        terminal.scroll_lines(1);
        assert_eq!(terminal.visible_styled_screen().rows[0].plain_text(), "old");
        terminal.inject_output(b"\x1b[?1049h\x1b[H\x1b[1malt");
        assert!(terminal.is_alternate_screen_active());
        let before_selection = terminal.visible_styled_screen();
        assert_eq!(before_selection.rows[0].plain_text(), "alt");
        terminal.selection_start(0, 0, 0);
        terminal.selection_update(2, 0);
        let result = terminal.selection_styled_text().unwrap();
        assert_eq!(result.plain_text, "alt");
        assert!(result.runs[0].bold);
        assert_eq!(terminal.visible_styled_screen(), before_selection);
    }
}
