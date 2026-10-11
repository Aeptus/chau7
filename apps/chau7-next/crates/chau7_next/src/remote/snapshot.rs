//! Grid snapshot payload for the phone (`captureRemoteGridSnapshotPayload`,
//! RBK-055): the visible grid in the `CHG1` layout of
//! `chau7_next_core::remote::grid_snapshot`, cells laid out like the
//! emulator's C `CellData` (16 bytes each).

use chau7_next_core::remote::grid_snapshot::{
    RemoteTerminalGridSnapshot, RemoteTerminalGridSnapshotLayout,
};
use chau7_terminal::{GridCopy, OwnedCell};

/// One cell as `CellData`: `character u32 | fg rgb | bg rgb | flags |
/// underline variant (the `_pad` byte) | link_id u16 | 2 padding bytes`.
fn push_cell(out: &mut Vec<u8>, cell: &OwnedCell) {
    out.extend_from_slice(&(cell.character as u32).to_le_bytes());
    out.extend_from_slice(&[cell.fg.0, cell.fg.1, cell.fg.2]);
    out.extend_from_slice(&[cell.bg.0, cell.bg.1, cell.bg.2]);
    out.push(cell.flags);
    out.push(cell.underline);
    out.extend_from_slice(&cell.link_id.to_le_bytes());
    out.extend_from_slice(&[0, 0]);
}

/// The encoded snapshot, or `None` for an empty grid (as Swift).
/// `cursor` is (column, row).
pub fn encode_grid(grid: &GridCopy, cursor: (u16, u16)) -> Option<Vec<u8>> {
    let count = usize::from(grid.cols) * usize::from(grid.rows);
    if count == 0 || grid.cells.len() < count {
        return None;
    }
    let mut cells = Vec::with_capacity(count * RemoteTerminalGridSnapshotLayout::CELL_STRIDE);
    for cell in &grid.cells[..count] {
        push_cell(&mut cells, cell);
    }
    RemoteTerminalGridSnapshot {
        cols: grid.cols,
        rows: grid.rows,
        cursor_col: cursor.0,
        cursor_row: cursor.1,
        cursor_visible: grid.cursor_visible,
        scrollback_rows: grid.scrollback_rows,
        display_offset: grid.display_offset,
        cells,
    }
    .encode()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn encodes_cells_like_cell_data() {
        let mut cell = OwnedCell {
            character: 'é',
            fg: (1, 2, 3),
            bg: (4, 5, 6),
            flags: 0x11,
            link_id: 0x0203,
            underline: 3,
        };
        let grid = GridCopy {
            cols: 2,
            rows: 1,
            cursor_visible: true,
            scrollback_rows: 40,
            display_offset: 2,
            cells: vec![cell, {
                cell.character = 'x';
                cell
            }],
        };
        let data = encode_grid(&grid, (1, 0)).unwrap();
        let decoded = RemoteTerminalGridSnapshot::decode(&data).unwrap();
        assert_eq!((decoded.cols, decoded.rows), (2, 1));
        assert_eq!((decoded.cursor_col, decoded.cursor_row), (1, 0));
        assert!(decoded.cursor_visible);
        assert_eq!(decoded.scrollback_rows, 40);
        assert_eq!(decoded.display_offset, 2);
        assert_eq!(
            &decoded.cells[..16],
            &[0xE9, 0, 0, 0, 1, 2, 3, 4, 5, 6, 0x11, 3, 0x03, 0x02, 0, 0]
        );
        assert_eq!(decoded.cells[16], b'x');
    }

    #[test]
    fn empty_grid_gives_nothing() {
        let grid = GridCopy {
            cols: 0,
            rows: 0,
            cursor_visible: false,
            scrollback_rows: 0,
            display_offset: 0,
            cells: Vec::new(),
        };
        assert!(encode_grid(&grid, (0, 0)).is_none());
    }
}
