//! Grid snapshot payload for the phone (`captureRemoteGridSnapshotPayload`,
//! RBK-055): the visible grid in the "CHG2" layout of
//! `chau7_next_core::remote::grid_snapshot`, cells laid out like the
//! emulator's C `CellData` (20 bytes each) with their grapheme clusters.

use chau7_next_core::remote::grid_snapshot::{
    RemoteTerminalGridSnapshot, RemoteTerminalGridSnapshotLayout,
};
use chau7_terminal::{GridCopy, OwnedCell};

/// One cell as `CellData`: `cluster_offset u32 | fg rgb | bg rgb |
/// cluster_len u16 | width u8 | continuation u8 | flags u8 |
/// underline_style u8 | link_id u16 | 2 padding bytes`, its grapheme
/// appended to `clusters`. Like the emulator, the right half of a wide
/// character and a NUL cell carry no cluster.
fn push_cell(out: &mut Vec<u8>, clusters: &mut Vec<u8>, cell: &OwnedCell, text: &str) {
    let (offset, len) = if cell.continuation || cell.character == '\0' {
        (0u32, 0u16)
    } else {
        let offset = clusters.len() as u32;
        clusters.extend_from_slice(text.as_bytes());
        (offset, text.len() as u16)
    };
    out.extend_from_slice(&offset.to_le_bytes());
    out.extend_from_slice(&[cell.fg.0, cell.fg.1, cell.fg.2]);
    out.extend_from_slice(&[cell.bg.0, cell.bg.1, cell.bg.2]);
    out.extend_from_slice(&len.to_le_bytes());
    out.push(if cell.continuation {
        0
    } else {
        cell.width.max(1)
    });
    out.push(u8::from(cell.continuation));
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
    let mut clusters = Vec::with_capacity(count);
    let mut buf = [0u8; 4];
    for (index, cell) in grid.cells[..count].iter().enumerate() {
        match grid.clusters.get(&index) {
            Some(text) => push_cell(&mut cells, &mut clusters, cell, text),
            None => push_cell(
                &mut cells,
                &mut clusters,
                cell,
                cell.character.encode_utf8(&mut buf),
            ),
        }
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
        clusters,
    }
    .encode()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn encodes_cells_like_cell_data() {
        let cell = OwnedCell {
            character: '\u{e9}',
            fg: (1, 2, 3),
            bg: (4, 5, 6),
            flags: 0x11,
            link_id: 0x0203,
            underline: 3,
            width: 1,
            continuation: false,
        };
        let wide = OwnedCell {
            character: '\u{2764}',
            width: 2,
            ..cell
        };
        let right_half = OwnedCell {
            character: ' ',
            width: 0,
            continuation: true,
            ..cell
        };
        let mut grid = GridCopy {
            cols: 3,
            rows: 1,
            cursor_visible: true,
            scrollback_rows: 40,
            display_offset: 2,
            cells: vec![cell, wide, right_half],
            ..GridCopy::default()
        };
        grid.clusters.insert(1, "\u{2764}\u{fe0f}".to_string());
        let data = encode_grid(&grid, (1, 0)).unwrap();
        let decoded = RemoteTerminalGridSnapshot::decode(&data).unwrap();
        assert_eq!((decoded.cols, decoded.rows), (3, 1));
        assert_eq!((decoded.cursor_col, decoded.cursor_row), (1, 0));
        assert!(decoded.cursor_visible);
        assert_eq!(decoded.scrollback_rows, 40);
        assert_eq!(decoded.display_offset, 2);
        assert_eq!(
            &decoded.cells[..20],
            &[
                0, 0, 0, 0, 1, 2, 3, 4, 5, 6, 2, 0, 1, 0, 0x11, 3, 0x03, 0x02, 0, 0
            ]
        );
        // The heart with VS16 starts after the two bytes of the first cell.
        assert_eq!(&decoded.cells[20..24], &[2, 0, 0, 0]);
        assert_eq!(&decoded.cells[30..34], &[6, 0, 2, 0]);
        // The right half has no cluster, width 0 and the continuation flag.
        assert_eq!(&decoded.cells[50..54], &[0, 0, 0, 1]);
        assert_eq!(decoded.clusters, "\u{e9}\u{2764}\u{fe0f}".as_bytes());
    }

    #[test]
    fn empty_grid_gives_nothing() {
        assert!(encode_grid(&GridCopy::default(), (0, 0)).is_none());
    }
}
