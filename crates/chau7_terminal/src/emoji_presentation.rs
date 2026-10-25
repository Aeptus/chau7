//! Two-column emoji presentation sequences (issue #213).
//!
//! Alacritty sizes every cell from the width of its first code point alone.
//! An emoji presentation sequence such as `⚠️` (U+26A0 U+FE0F) therefore stays
//! one column wide: U+26A0 is narrow and the variation selector U+FE0F is
//! zero width. The programs that draw into the terminal disagree. Node's
//! `string-width` (Claude Code, Ink) and the `unicode-width` crate (Codex,
//! ratatui) both measure the sequence as two columns, as do most current
//! terminals. Those TUIs place the next glyph with absolute cursor moves
//! (CHA, CUP), so the column they reserved for the second half of the emoji
//! was left blank, shown as an extra space and copied as one.
//!
//! [`advance`] feeds bytes to the parser through [`PresentationHandler`],
//! which forwards every call to Alacritty unchanged and, right after a U+FE0F
//! lands on a narrow cell whose sequence `unicode-width` measures as two
//! columns, turns that cell into a wide cell with its spacer, exactly as
//! Alacritty would have written a wide glyph.

use alacritty_terminal::Term;
use alacritty_terminal::event::EventListener;
use alacritty_terminal::grid::Dimensions;
use alacritty_terminal::index::Column;
use alacritty_terminal::term::TermMode;
use alacritty_terminal::term::cell::{Cell, Flags};
use alacritty_terminal::vte::ansi::cursor_icon::CursorIcon;
use alacritty_terminal::vte::ansi::{
    Attr, CharsetIndex, ClearMode, CursorShape, CursorStyle, Handler, Hyperlink, KeyboardModes,
    KeyboardModesApplyBehavior, LineClearMode, Mode, ModifyOtherKeys, PrivateMode, Processor, Rgb,
    ScpCharPath, ScpUpdateMode, StandardCharset, TabulationClearMode,
};
use unicode_width::UnicodeWidthStr;

const VS16: char = '\u{FE0F}';

/// Feeds `bytes` to `processor`, widening emoji presentation sequences.
pub(crate) fn advance<L: EventListener>(
    processor: &mut Processor,
    term: &mut Term<L>,
    bytes: &[u8],
) {
    processor.advance(&mut PresentationHandler { term }, bytes);
}

/// A [`Handler`] that forwards to Alacritty's [`Term`] and widens a cell
/// once a U+FE0F turns it into a two-column emoji presentation sequence.
///
/// Every `Handler` method is forwarded explicitly: the trait gives each one
/// an empty default, so a method missing here would silently do nothing.
struct PresentationHandler<'a, L: EventListener> {
    term: &'a mut Term<L>,
}

impl<L: EventListener> PresentationHandler<'_, L> {
    /// Called after Alacritty attached a U+FE0F as a zero-width character.
    fn widen_presentation_sequence(&mut self) {
        let term = &mut *self.term;
        let insert_mode = term.mode().contains(TermMode::INSERT);
        let grid = term.grid_mut();
        let columns = grid.columns();
        let cursor = grid.cursor.point;

        // Alacritty attaches a zero-width character to the cell before the
        // cursor. With a pending wrap the base sits in the last column and
        // there is no room for a second cell, which a TUI that counts two
        // columns would not ask for. Leave that case narrow.
        if grid.cursor.input_needs_wrap || cursor.column.0 == 0 {
            return;
        }
        let base = Column(cursor.column.0 - 1);
        let spacer = cursor.column;

        let row = &mut grid[cursor.line];
        let cell = &row[base];
        if cell.flags.intersects(
            Flags::WIDE_CHAR | Flags::WIDE_CHAR_SPACER | Flags::LEADING_WIDE_CHAR_SPACER,
        ) {
            return;
        }
        let Some(zerowidth) = cell.zerowidth() else {
            return;
        };
        if zerowidth.last() != Some(&VS16) {
            return;
        }
        let mut sequence = String::with_capacity(8);
        sequence.push(cell.c);
        sequence.extend(zerowidth.iter());
        if UnicodeWidthStr::width(sequence.as_str()) != 2 {
            return;
        }

        if insert_mode {
            // Alacritty shifted the line right by one column for the base;
            // the second column needs one more.
            let cells = &mut row[..];
            for column in (spacer.0..columns - 1).rev() {
                cells.swap(column + 1, column);
            }
        }

        // Overwriting the first half of a wide glyph orphans its spacer, as
        // in Alacritty's `write_at_cursor`.
        if row[spacer].flags.contains(Flags::WIDE_CHAR) && spacer.0 + 1 < columns {
            row[spacer + 1].flags.remove(Flags::WIDE_CHAR_SPACER);
        }

        row[base].flags.insert(Flags::WIDE_CHAR);
        let template = row[base].clone();
        let mut spacer_cell = Cell {
            c: ' ',
            fg: template.fg,
            bg: template.bg,
            flags: (template.flags - Flags::WIDE_CHAR) | Flags::WIDE_CHAR_SPACER,
            extra: None,
        };
        spacer_cell.set_underline_color(template.underline_color());
        spacer_cell.set_hyperlink(template.hyperlink());
        row[spacer] = spacer_cell;

        // Same cursor advance as Alacritty after a wide glyph.
        if spacer.0 + 1 < columns {
            grid.cursor.point.column = spacer + 1;
        } else {
            grid.cursor.input_needs_wrap = true;
        }
    }
}

macro_rules! forward {
    ($($name:ident($($arg:ident: $ty:ty),*);)*) => {
        $(
            #[inline]
            fn $name(&mut self, $($arg: $ty),*) {
                <Term<L> as Handler>::$name(self.term, $($arg),*)
            }
        )*
    };
}

impl<L: EventListener> Handler for PresentationHandler<'_, L> {
    #[inline]
    fn input(&mut self, c: char) {
        <Term<L> as Handler>::input(self.term, c);
        if c == VS16 {
            self.widen_presentation_sequence();
        }
    }

    forward! {
        set_title(title: Option<String>);
        set_cursor_style(style: Option<CursorStyle>);
        set_cursor_shape(shape: CursorShape);
        goto(line: i32, col: usize);
        goto_line(line: i32);
        goto_col(col: usize);
        insert_blank(count: usize);
        move_up(count: usize);
        move_down(count: usize);
        identify_terminal(intermediate: Option<char>);
        device_status(arg: usize);
        move_forward(col: usize);
        move_backward(col: usize);
        move_down_and_cr(row: usize);
        move_up_and_cr(row: usize);
        put_tab(count: u16);
        backspace();
        carriage_return();
        linefeed();
        bell();
        substitute();
        newline();
        set_horizontal_tabstop();
        scroll_up(count: usize);
        scroll_down(count: usize);
        insert_blank_lines(count: usize);
        delete_lines(count: usize);
        erase_chars(count: usize);
        delete_chars(count: usize);
        move_backward_tabs(count: u16);
        move_forward_tabs(count: u16);
        save_cursor_position();
        restore_cursor_position();
        clear_line(mode: LineClearMode);
        clear_screen(mode: ClearMode);
        clear_tabs(mode: TabulationClearMode);
        set_tabs(interval: u16);
        reset_state();
        reverse_index();
        terminal_attribute(attr: Attr);
        set_mode(mode: Mode);
        unset_mode(mode: Mode);
        report_mode(mode: Mode);
        set_private_mode(mode: PrivateMode);
        unset_private_mode(mode: PrivateMode);
        report_private_mode(mode: PrivateMode);
        set_scrolling_region(top: usize, bottom: Option<usize>);
        set_keypad_application_mode();
        unset_keypad_application_mode();
        set_active_charset(index: CharsetIndex);
        configure_charset(index: CharsetIndex, charset: StandardCharset);
        set_color(index: usize, color: Rgb);
        dynamic_color_sequence(prefix: String, index: usize, terminator: &str);
        reset_color(index: usize);
        clipboard_store(clipboard: u8, base64: &[u8]);
        clipboard_load(clipboard: u8, terminator: &str);
        decaln();
        push_title();
        pop_title();
        text_area_size_pixels();
        text_area_size_chars();
        set_hyperlink(hyperlink: Option<Hyperlink>);
        set_mouse_cursor_icon(icon: CursorIcon);
        report_keyboard_mode();
        push_keyboard_mode(mode: KeyboardModes);
        pop_keyboard_modes(to_pop: u16);
        set_keyboard_mode(mode: KeyboardModes, behavior: KeyboardModesApplyBehavior);
        set_modify_other_keys(mode: ModifyOtherKeys);
        report_modify_other_keys();
        set_scp(char_path: ScpCharPath, update_mode: ScpUpdateMode);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use alacritty_terminal::event::VoidListener;
    use alacritty_terminal::index::{Line, Point};
    use alacritty_terminal::term::Config;
    use alacritty_terminal::term::test::TermSize;

    fn term(columns: usize) -> Term<VoidListener> {
        Term::new(Config::default(), &TermSize::new(columns, 3), VoidListener)
    }

    fn feed(term: &mut Term<VoidListener>, bytes: &str) {
        let mut processor = Processor::new();
        advance(&mut processor, term, bytes.as_bytes());
    }

    fn flags(term: &Term<VoidListener>, column: usize) -> Flags {
        term.grid()[Line(0)][Column(column)].flags
    }

    fn cursor(term: &Term<VoidListener>) -> Point {
        term.grid().cursor.point
    }

    /// The width the TUIs assume. Claude Code's `string-width` agrees on
    /// every case below; these pin the `unicode-width` side of the contract.
    #[test]
    fn unicode_width_counts_emoji_presentation_sequences_as_two_columns() {
        for sequence in [
            "\u{26A0}\u{FE0F}",
            "\u{23F8}\u{FE0F}",
            "\u{2764}\u{FE0F}",
            "\u{2714}\u{FE0F}",
        ] {
            assert_eq!(UnicodeWidthStr::width(sequence), 2, "{sequence:?}");
        }
        // Text presentation (no selector) stays one column, as do the
        // Claude Code UI glyphs that are drawn without a selector.
        for text in [
            "\u{26A0}", "\u{23FA}", "\u{23BF}", "\u{273B}", "\u{25CF}", "\u{2022}",
        ] {
            assert_eq!(UnicodeWidthStr::width(text), 1, "{text:?}");
        }
    }

    #[test]
    fn vs16_widens_narrow_emoji_base() {
        let mut term = term(10);
        feed(&mut term, "\u{26A0}\u{FE0F}x");
        assert!(flags(&term, 0).contains(Flags::WIDE_CHAR));
        assert!(flags(&term, 1).contains(Flags::WIDE_CHAR_SPACER));
        assert_eq!(term.grid()[Line(0)][Column(2)].c, 'x');
        assert_eq!(cursor(&term).column, Column(3));
    }

    #[test]
    fn text_presentation_and_plain_text_stay_narrow() {
        let mut term = term(10);
        feed(&mut term, "\u{26A0}a\u{FE0F}\u{FE0E}");
        assert!(!flags(&term, 0).contains(Flags::WIDE_CHAR));
        assert!(!flags(&term, 1).contains(Flags::WIDE_CHAR));
        assert_eq!(cursor(&term).column, Column(2));
    }

    #[test]
    fn already_wide_emoji_is_left_alone() {
        let mut term = term(10);
        // U+26C5 is already two columns wide in Alacritty.
        feed(&mut term, "\u{26C5}\u{FE0F}x");
        assert!(flags(&term, 0).contains(Flags::WIDE_CHAR));
        assert!(flags(&term, 1).contains(Flags::WIDE_CHAR_SPACER));
        assert_eq!(term.grid()[Line(0)][Column(2)].c, 'x');
    }

    #[test]
    fn spacer_overwrites_following_wide_glyph_cleanly() {
        let mut term = term(10);
        // A wide glyph sits at columns 1-2; the emoji at column 0 widens over
        // column 1, so the orphaned spacer at column 2 must be cleared.
        feed(&mut term, " \u{4E2D}\r\u{2764}\u{FE0F}");
        assert!(flags(&term, 0).contains(Flags::WIDE_CHAR));
        assert!(flags(&term, 1).contains(Flags::WIDE_CHAR_SPACER));
        assert!(!flags(&term, 2).contains(Flags::WIDE_CHAR_SPACER));
    }

    #[test]
    fn sequence_ending_in_last_column_sets_pending_wrap() {
        let mut term = term(4);
        feed(&mut term, "ab\u{2764}\u{FE0F}");
        assert!(flags(&term, 2).contains(Flags::WIDE_CHAR));
        assert!(flags(&term, 3).contains(Flags::WIDE_CHAR_SPACER));
        assert_eq!(cursor(&term).column, Column(3));
        assert!(term.grid().cursor.input_needs_wrap);
        feed(&mut term, "c");
        assert_eq!(term.grid()[Line(1)][Column(0)].c, 'c');
    }

    #[test]
    fn base_in_last_column_stays_narrow() {
        let mut term = term(4);
        feed(&mut term, "abc\u{2764}\u{FE0F}");
        assert!(!flags(&term, 3).contains(Flags::WIDE_CHAR));
        assert!(term.grid().cursor.input_needs_wrap);
    }

    #[test]
    fn selector_inside_osc_title_is_ignored() {
        let mut term = term(10);
        feed(&mut term, "\u{2764}\x1b]0;\u{26A0}\u{FE0F}\x07x");
        assert!(!flags(&term, 0).contains(Flags::WIDE_CHAR));
        assert_eq!(term.grid()[Line(0)][Column(1)].c, 'x');
    }

    #[test]
    fn insert_mode_shifts_following_text_by_two() {
        let mut term = term(10);
        feed(&mut term, "xyz\r\x1b[4h\u{2764}\u{FE0F}");
        assert!(flags(&term, 0).contains(Flags::WIDE_CHAR));
        assert!(flags(&term, 1).contains(Flags::WIDE_CHAR_SPACER));
        assert_eq!(term.grid()[Line(0)][Column(2)].c, 'x');
        assert_eq!(term.grid()[Line(0)][Column(4)].c, 'z');
    }

    #[test]
    fn synchronized_update_still_widens() {
        let mut term = term(10);
        feed(&mut term, "\x1b[?2026h\u{26A0}\u{FE0F}x\x1b[?2026l");
        assert!(flags(&term, 0).contains(Flags::WIDE_CHAR));
        assert_eq!(term.grid()[Line(0)][Column(2)].c, 'x');
    }
}
