//! Moving the shell's cursor with arrow keys after a click.
//!
//! Ports `RustTerminalView.handleClickToPosition` (plain click within 5 rows
//! of the cursor, `feature.clickToPosition`) and `handleOptionClick`
//! (Option-click anywhere, `feature.optionClickCursor`).

/// Click to position refuses rows further than this from the cursor, so a
/// click meant to start a selection in the scrollback does not move it.
pub const CLICK_TO_POSITION_MAX_ROWS: i32 = 5;

/// Arrow sequences (`CSI A/B/C/D`, one per cell) that move the cursor from
/// `cursor` to `target` (both `(col, row)`). Empty when they are equal.
pub fn arrow_sequence(cursor: (i32, i32), target: (i32, i32)) -> Vec<u8> {
    let row_diff = target.1 - cursor.1;
    let col_diff = target.0 - cursor.0;
    let mut out = Vec::new();
    let vertical: &[u8] = if row_diff > 0 { b"\x1b[B" } else { b"\x1b[A" };
    for _ in 0..row_diff.unsigned_abs() {
        out.extend_from_slice(vertical);
    }
    let horizontal: &[u8] = if col_diff > 0 { b"\x1b[C" } else { b"\x1b[D" };
    for _ in 0..col_diff.unsigned_abs() {
        out.extend_from_slice(horizontal);
    }
    out
}

/// Click to position: `None` when the click is too far from the cursor or
/// already on it.
pub fn click_to_position(cursor: (i32, i32), target: (i32, i32)) -> Option<Vec<u8>> {
    if (target.1 - cursor.1).abs() > CLICK_TO_POSITION_MAX_ROWS {
        return None;
    }
    Some(arrow_sequence(cursor, target)).filter(|b| !b.is_empty())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn builds_arrow_runs() {
        assert_eq!(
            arrow_sequence((2, 1), (4, 0)),
            b"\x1b[A\x1b[C\x1b[C".to_vec()
        );
        assert_eq!(
            arrow_sequence((3, 3), (1, 4)),
            b"\x1b[B\x1b[D\x1b[D".to_vec()
        );
        assert!(arrow_sequence((1, 1), (1, 1)).is_empty());
    }

    #[test]
    fn click_to_position_stays_near_the_cursor() {
        assert!(click_to_position((0, 10), (0, 3)).is_none());
        assert!(click_to_position((0, 10), (0, 10)).is_none());
        assert_eq!(
            click_to_position((0, 10), (2, 5)).unwrap().len(),
            5 * 3 + 2 * 3
        );
    }
}
