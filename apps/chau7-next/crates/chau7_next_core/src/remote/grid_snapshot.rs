//! Binary terminal grid snapshot for remote clients (`TERMINAL_GRID_SNAPSHOT`, 0x23).
//!
//! Port of `RemoteTerminalGridSnapshot.swift` (`apps/chau7-macos/Sources/Chau7Core`),
//! the grapheme-cluster-aware "CHG2" format.
//!
//! Layout (little endian), 33 byte header, cells, then cluster bytes:
//! `"CHG2" | version u8 (2) | cols u16 | rows u16 | cursor_col u16 | cursor_row u16 |
//! cursor_visible u8 | 3 zero bytes | scrollback_rows u32 | display_offset u32 |
//! cells_byte_count u32 | clusters_byte_count u32 | cells (20 bytes each) | clusters`.
//! A cell is the emulator's C `CellData`: `cluster_offset u32 | fg rgb | bg rgb |
//! cluster_len u16 | width u8 | continuation u8 | flags u8 | underline_style u8 |
//! link_id u16 | 2 padding bytes`; `cluster_offset` points into the cluster
//! bytes (UTF-8). The Go relay client forwards this frame type untouched, so
//! only the apps and iOS interpret the layout.

use std::fmt;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RemoteTerminalGridSnapshotError {
    InvalidMagic,
    UnsupportedVersion(u8),
    InvalidLength,
}

impl fmt::Display for RemoteTerminalGridSnapshotError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::InvalidMagic => write!(f, "Invalid grid snapshot magic"),
            Self::UnsupportedVersion(v) => write!(f, "Unsupported grid snapshot version: {v}"),
            Self::InvalidLength => write!(f, "Invalid grid snapshot length"),
        }
    }
}

impl std::error::Error for RemoteTerminalGridSnapshotError {}

pub struct RemoteTerminalGridSnapshotLayout;

impl RemoteTerminalGridSnapshotLayout {
    pub const MAGIC: [u8; 4] = *b"CHG2";
    pub const VERSION: u8 = 2;
    pub const HEADER_SIZE: usize = 33;
    /// Stride of the emulator's C `CellData` (18 bytes padded to 20).
    pub const CELL_STRIDE: usize = 20;
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RemoteTerminalGridSnapshot {
    pub cols: u16,
    pub rows: u16,
    pub cursor_col: u16,
    pub cursor_row: u16,
    pub cursor_visible: bool,
    pub scrollback_rows: u32,
    pub display_offset: u32,
    pub cells: Vec<u8>,
    /// UTF-8 grapheme cluster bytes referenced by each cell's `cluster_offset`.
    pub clusters: Vec<u8>,
}

impl RemoteTerminalGridSnapshot {
    pub fn cell_count(&self) -> usize {
        usize::from(self.cols) * usize::from(self.rows)
    }

    pub fn is_valid(&self) -> bool {
        self.cells.len() == self.cell_count() * RemoteTerminalGridSnapshotLayout::CELL_STRIDE
    }

    /// `None` when the cell buffer does not match `cols * rows * 20`.
    pub fn encode(&self) -> Option<Vec<u8>> {
        if !self.is_valid() {
            return None;
        }
        let cells_len = u32::try_from(self.cells.len()).ok()?;
        let clusters_len = u32::try_from(self.clusters.len()).ok()?;
        let mut data = Vec::with_capacity(
            RemoteTerminalGridSnapshotLayout::HEADER_SIZE + self.cells.len() + self.clusters.len(),
        );
        data.extend_from_slice(&RemoteTerminalGridSnapshotLayout::MAGIC);
        data.push(RemoteTerminalGridSnapshotLayout::VERSION);
        data.extend_from_slice(&self.cols.to_le_bytes());
        data.extend_from_slice(&self.rows.to_le_bytes());
        data.extend_from_slice(&self.cursor_col.to_le_bytes());
        data.extend_from_slice(&self.cursor_row.to_le_bytes());
        data.push(u8::from(self.cursor_visible));
        data.extend_from_slice(&[0, 0, 0]);
        data.extend_from_slice(&self.scrollback_rows.to_le_bytes());
        data.extend_from_slice(&self.display_offset.to_le_bytes());
        data.extend_from_slice(&cells_len.to_le_bytes());
        data.extend_from_slice(&clusters_len.to_le_bytes());
        data.extend_from_slice(&self.cells);
        data.extend_from_slice(&self.clusters);
        Some(data)
    }

    pub fn decode(data: &[u8]) -> Result<Self, RemoteTerminalGridSnapshotError> {
        use RemoteTerminalGridSnapshotError as E;
        use RemoteTerminalGridSnapshotLayout as L;

        if data.len() < L::HEADER_SIZE {
            return Err(E::InvalidLength);
        }
        if data[..4] != L::MAGIC {
            return Err(E::InvalidMagic);
        }
        let version = data[4];
        if version != L::VERSION {
            return Err(E::UnsupportedVersion(version));
        }

        let u16_at = |o: usize| u16::from_le_bytes([data[o], data[o + 1]]);
        let u32_at =
            |o: usize| u32::from_le_bytes([data[o], data[o + 1], data[o + 2], data[o + 3]]);

        let cols = u16_at(5);
        let rows = u16_at(7);
        let cells_byte_count = u32_at(25) as usize;
        let clusters_byte_count = u32_at(29) as usize;
        let expected = usize::from(cols) * usize::from(rows) * L::CELL_STRIDE;
        if cells_byte_count != expected {
            return Err(E::InvalidLength);
        }
        let cells_end = L::HEADER_SIZE + cells_byte_count;
        let total = cells_end + clusters_byte_count;
        if data.len() < total {
            return Err(E::InvalidLength);
        }
        Ok(Self {
            cols,
            rows,
            cursor_col: u16_at(9),
            cursor_row: u16_at(11),
            cursor_visible: data[13] != 0,
            scrollback_rows: u32_at(17),
            display_offset: u32_at(21),
            cells: data[L::HEADER_SIZE..cells_end].to_vec(),
            clusters: data[cells_end..total].to_vec(),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn snapshot(
        cols: u16,
        rows: u16,
        cells: Vec<u8>,
        clusters: Vec<u8>,
    ) -> RemoteTerminalGridSnapshot {
        RemoteTerminalGridSnapshot {
            cols,
            rows,
            cursor_col: 0,
            cursor_row: 0,
            cursor_visible: false,
            scrollback_rows: 0,
            display_offset: 0,
            cells,
            clusters,
        }
    }

    #[test]
    fn round_trip_preserves_metadata_cells_and_clusters() {
        let mut original = snapshot(2, 1, (0u8..40).collect(), b"ab".to_vec());
        original.cursor_col = 1;
        original.cursor_visible = true;
        original.scrollback_rows = 42;
        original.display_offset = 3;
        let encoded = original.encode().unwrap();
        assert_eq!(
            RemoteTerminalGridSnapshot::decode(&encoded).unwrap(),
            original
        );
    }

    #[test]
    fn decode_rejects_wrong_cell_length() {
        let mut invalid = Vec::new();
        invalid.extend_from_slice(&RemoteTerminalGridSnapshotLayout::MAGIC);
        invalid.push(RemoteTerminalGridSnapshotLayout::VERSION);
        invalid.extend_from_slice(&2u16.to_le_bytes());
        invalid.extend_from_slice(&1u16.to_le_bytes());
        invalid.extend_from_slice(&0u16.to_le_bytes());
        invalid.extend_from_slice(&0u16.to_le_bytes());
        invalid.push(1);
        invalid.extend_from_slice(&[0, 0, 0]);
        invalid.extend_from_slice(&0u32.to_le_bytes());
        invalid.extend_from_slice(&0u32.to_le_bytes());
        invalid.extend_from_slice(&1u32.to_le_bytes());
        invalid.extend_from_slice(&0u32.to_le_bytes());
        invalid.push(0);

        assert_eq!(
            RemoteTerminalGridSnapshot::decode(&invalid),
            Err(RemoteTerminalGridSnapshotError::InvalidLength)
        );
    }

    #[test]
    fn golden_bytes_one_cell_snapshot() {
        let snapshot = RemoteTerminalGridSnapshot {
            cols: 1,
            rows: 1,
            cursor_col: 0x0102,
            cursor_row: 0x0304,
            cursor_visible: true,
            scrollback_rows: 0x0A0B_0C0D,
            display_offset: 0x0000_0005,
            cells: (0xA0u8..0xB4).collect(),
            clusters: vec![b'x'],
        };
        let mut expected: Vec<u8> = vec![
            b'C', b'H', b'G', b'2', // magic
            0x02, // version
            0x01, 0x00, // cols
            0x01, 0x00, // rows
            0x02, 0x01, // cursor col
            0x04, 0x03, // cursor row
            0x01, // cursor visible
            0x00, 0x00, 0x00, // reserved
            0x0D, 0x0C, 0x0B, 0x0A, // scrollback rows
            0x05, 0x00, 0x00, 0x00, // display offset
            0x14, 0x00, 0x00, 0x00, // cells byte count
            0x01, 0x00, 0x00, 0x00, // clusters byte count
        ];
        assert_eq!(
            expected.len(),
            RemoteTerminalGridSnapshotLayout::HEADER_SIZE
        );
        expected.extend(0xA0u8..0xB4);
        expected.push(b'x');
        assert_eq!(snapshot.encode().unwrap(), expected);
        assert_eq!(
            RemoteTerminalGridSnapshot::decode(&expected).unwrap(),
            snapshot
        );
    }

    #[test]
    fn encode_returns_none_for_invalid_cell_buffer() {
        let invalid = snapshot(2, 2, vec![0; 10], Vec::new());
        assert!(!invalid.is_valid());
        assert!(invalid.encode().is_none());
    }

    #[test]
    fn decode_rejects_bad_magic_version_and_short_data() {
        let good = snapshot(0, 0, vec![], vec![]).encode().unwrap();
        assert_eq!(good.len(), RemoteTerminalGridSnapshotLayout::HEADER_SIZE);
        assert!(RemoteTerminalGridSnapshot::decode(&good).is_ok());

        let mut bad_magic = good.clone();
        bad_magic[0] = b'X';
        assert_eq!(
            RemoteTerminalGridSnapshot::decode(&bad_magic),
            Err(RemoteTerminalGridSnapshotError::InvalidMagic)
        );
        let mut bad_version = good.clone();
        bad_version[4] = 1;
        assert_eq!(
            RemoteTerminalGridSnapshot::decode(&bad_version),
            Err(RemoteTerminalGridSnapshotError::UnsupportedVersion(1))
        );
        assert_eq!(
            RemoteTerminalGridSnapshot::decode(&good[..32]),
            Err(RemoteTerminalGridSnapshotError::InvalidLength)
        );
    }

    #[test]
    fn decode_rejects_truncated_cells_or_clusters() {
        let encoded = snapshot(1, 1, vec![7; 20], b"xy".to_vec())
            .encode()
            .unwrap();
        assert_eq!(
            RemoteTerminalGridSnapshot::decode(&encoded[..encoded.len() - 1]),
            Err(RemoteTerminalGridSnapshotError::InvalidLength)
        );
    }
}
