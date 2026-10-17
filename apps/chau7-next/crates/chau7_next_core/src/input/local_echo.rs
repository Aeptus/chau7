//! Local echo (`feature.localEchoEnabled`, off by default): typed printable
//! ASCII is drawn at once, before the shell echoes it.
//!
//! Ports `RustTerminalView.applyLocalEcho`: printable characters go at the
//! predicted cursor and advance it (wrapping at the last column), Backspace
//! takes the last one back, Return, Ctrl+C and Ctrl+U drop the prediction.
//! Swift removes a prediction when the same byte comes back in the PTY
//! output; here a prediction is dropped once the grid shows that character
//! at its cell ([`LocalEcho::confirm`]), which has the same visible effect.
//! Other escape sequences (arrows) drop the prediction too, since the cursor
//! moved.

/// Predicted characters: (column, screen row, character).
#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct LocalEcho {
    pending: Vec<(i32, i32, char)>,
    cursor: Option<(i32, i32)>,
}

impl LocalEcho {
    /// Bytes the user typed. `cursor` is the shell's cursor (column, screen
    /// row), used when nothing is pending; `cols`/`rows` bound the grid.
    pub fn typed(&mut self, bytes: &[u8], cursor: (i32, i32), cols: i32, rows: i32) {
        if cols <= 0 || rows <= 0 {
            return;
        }
        if bytes.first() == Some(&0x1b) {
            self.clear();
            return;
        }
        let mut at = self.cursor.unwrap_or(cursor);
        at.0 = at.0.clamp(0, cols - 1);
        at.1 = at.1.clamp(0, rows - 1);
        for &byte in bytes {
            match byte {
                0x20..=0x7e => {
                    self.pending.push((at.0, at.1, byte as char));
                    at.0 += 1;
                    if at.0 >= cols {
                        at.0 = 0;
                        at.1 = (at.1 + 1).min(rows - 1);
                    }
                }
                0x7f | 0x08 => {
                    if self.pending.pop().is_some() {
                        if at.0 > 0 {
                            at.0 -= 1;
                        } else if at.1 > 0 {
                            at.1 -= 1;
                            at.0 = cols - 1;
                        }
                    }
                }
                0x03 | 0x15 | 0x0a | 0x0d => {
                    self.clear();
                    return;
                }
                _ => {}
            }
        }
        self.cursor = (!self.pending.is_empty()).then_some(at);
    }

    /// Drop predictions the grid now shows. `cell` returns the character at
    /// (column, screen row).
    pub fn confirm(&mut self, cell: impl Fn(i32, i32) -> Option<char>) {
        self.pending
            .retain(|&(col, row, c)| cell(col, row) != Some(c));
        if self.pending.is_empty() {
            self.cursor = None;
        }
    }

    pub fn clear(&mut self) {
        self.pending.clear();
        self.cursor = None;
    }

    pub fn cells(&self) -> &[(i32, i32, char)] {
        &self.pending
    }

    pub fn is_empty(&self) -> bool {
        self.pending.is_empty()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn predicts_and_wraps() {
        let mut e = LocalEcho::default();
        e.typed(b"ab", (3, 0), 4, 2);
        assert_eq!(e.cells(), &[(3, 0, 'a'), (0, 1, 'b')]);
        e.typed(b"c", (0, 0), 4, 2);
        assert_eq!(e.cells()[2], (1, 1, 'c'));
    }

    #[test]
    fn backspace_and_line_end() {
        let mut e = LocalEcho::default();
        e.typed(b"ls", (2, 0), 80, 24);
        e.typed(&[0x7f], (2, 0), 80, 24);
        assert_eq!(e.cells(), &[(2, 0, 'l')]);
        e.typed(b"s", (2, 0), 80, 24);
        assert_eq!(e.cells()[1], (3, 0, 's'));
        e.typed(b"\r", (2, 0), 80, 24);
        assert!(e.is_empty());
        e.typed(b"x", (5, 1), 80, 24);
        e.typed(b"\x1b[D", (5, 1), 80, 24);
        assert!(e.is_empty());
    }

    #[test]
    fn confirmed_cells_are_dropped() {
        let mut e = LocalEcho::default();
        e.typed(b"ab", (0, 0), 80, 24);
        e.confirm(|col, _| (col == 0).then_some('a'));
        assert_eq!(e.cells(), &[(1, 0, 'b')]);
        e.confirm(|_, _| Some('b'));
        assert!(e.is_empty());
    }
}
