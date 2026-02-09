//! C-compatible data types for FFI transfer between Rust and Swift.

use std::sync::atomic::AtomicU64;

use alacritty_terminal::term::cell::Flags as CellFlags;

// ============================================================================
// Cell attribute flags
// ============================================================================

/// Flags for cell attributes (bold, italic, underline, etc.)
pub const CELL_FLAG_BOLD: u8 = 1 << 0;
pub const CELL_FLAG_ITALIC: u8 = 1 << 1;
pub const CELL_FLAG_UNDERLINE: u8 = 1 << 2;
pub const CELL_FLAG_STRIKETHROUGH: u8 = 1 << 3;
pub const CELL_FLAG_INVERSE: u8 = 1 << 4;
pub const CELL_FLAG_DIM: u8 = 1 << 5;
pub const CELL_FLAG_HIDDEN: u8 = 1 << 6;

/// Underline style variants (stored in CellData._pad byte, formerly unused).
/// 0 = no underline (or simple single), 1 = single, 2 = double, 3 = curl, 4 = dotted, 5 = dashed.
pub const UNDERLINE_SINGLE: u8 = 1;
pub const UNDERLINE_DOUBLE: u8 = 2;
pub const UNDERLINE_CURL: u8 = 3;
pub const UNDERLINE_DOTTED: u8 = 4;
pub const UNDERLINE_DASHED: u8 = 5;

// ============================================================================
// Core cell data
// ============================================================================

/// C-compatible cell data for a single terminal cell
#[repr(C)]
pub struct CellData {
    /// Unicode codepoint of the character
    pub character: u32,
    /// Foreground color RGB
    pub fg_r: u8,
    pub fg_g: u8,
    pub fg_b: u8,
    /// Background color RGB
    pub bg_r: u8,
    pub bg_g: u8,
    pub bg_b: u8,
    /// Cell attribute flags (bold, italic, underline, etc.)
    pub flags: u8,
    /// Padding byte for natural alignment of link_id
    pub _pad: u8,
    /// Hyperlink ID (OSC 8). 0 = no link. Use chau7_terminal_get_link_url() to resolve.
    pub link_id: u16,
}

impl Default for CellData {
    fn default() -> Self {
        CellData {
            character: ' ' as u32,
            fg_r: 255,
            fg_g: 255,
            fg_b: 255,
            bg_r: 0,
            bg_g: 0,
            bg_b: 0,
            flags: 0,
            _pad: 0,
            link_id: 0,
        }
    }
}

// ============================================================================
// Grid snapshot
// ============================================================================

/// C-compatible grid snapshot containing all cell data
#[repr(C)]
pub struct GridSnapshot {
    /// Pointer to array of CellData (cols * rows elements)
    pub cells: *mut CellData,
    /// Number of columns
    pub cols: u16,
    /// Number of visible rows
    pub rows: u16,
    /// Number of scrollback rows available
    pub scrollback_rows: u32,
    /// Current display offset (scroll position)
    pub display_offset: u32,
    /// Capacity of cells array (for proper deallocation)
    pub capacity: usize,
}

// ============================================================================
// Debug state
// ============================================================================

/// Debug state snapshot for inspection
#[repr(C)]
pub struct DebugState {
    /// Terminal ID
    pub id: u64,
    /// Columns
    pub cols: u16,
    /// Rows
    pub rows: u16,
    /// History size (scrollback lines)
    pub history_size: u32,
    /// Current display offset
    pub display_offset: u32,
    /// Cursor column
    pub cursor_col: u16,
    /// Cursor row
    pub cursor_row: u16,
    /// Total bytes sent
    pub bytes_sent: u64,
    /// Total bytes received
    pub bytes_received: u64,
    /// Uptime in milliseconds
    pub uptime_ms: u64,
    /// Is grid dirty (u8 for FFI safety: 0 = false, 1 = true)
    pub grid_dirty: u8,
    /// Is running (u8 for FFI safety)
    pub running: u8,
    /// Has selection (u8 for FFI safety)
    pub has_selection: u8,
    /// Mouse mode bitmask
    pub mouse_mode: u32,
    /// Is bracketed paste mode (u8 for FFI safety)
    pub bracketed_paste: u8,
    /// Is application cursor mode (u8 for FFI safety)
    pub app_cursor: u8,
    /// Poll count
    pub poll_count: u64,
    /// Average poll time in microseconds
    pub avg_poll_time_us: u64,
    /// Max poll time in microseconds
    pub max_poll_time_us: u64,
    /// Average grid snapshot time in microseconds
    pub avg_grid_snapshot_time_us: u64,
    /// Max grid snapshot time in microseconds
    pub max_grid_snapshot_time_us: u64,
    /// Activity level percentage (0-100)
    pub activity_percent: u8,
    /// Number of idle polls
    pub idle_polls: u64,
    /// Average batch size in bytes
    pub avg_batch_size: u64,
    /// Dirty row count (for partial updates)
    pub dirty_row_count: u32,
}

// ============================================================================
// Pool statistics
// ============================================================================

/// Pool statistics for debugging
#[repr(C)]
pub struct PoolStats {
    pub acquired: u64,
    pub returned: u64,
    pub allocated: u64,
    pub pooled: u64,
}

// ============================================================================
// Performance metrics
// ============================================================================

/// Performance metrics for FFI operations
#[derive(Default)]
pub struct PerformanceMetrics {
    /// Total poll calls
    pub poll_count: AtomicU64,
    /// Total poll time in microseconds
    pub poll_time_us: AtomicU64,
    /// Total grid snapshot calls
    pub grid_snapshot_count: AtomicU64,
    /// Total grid snapshot time in microseconds
    pub grid_snapshot_time_us: AtomicU64,
    /// Total VTE processing time in microseconds
    pub vte_process_time_us: AtomicU64,
    /// Maximum single poll time in microseconds
    pub max_poll_time_us: AtomicU64,
    /// Maximum single grid snapshot time in microseconds
    pub max_grid_snapshot_time_us: AtomicU64,
    /// Total bytes batched (for batching efficiency tracking)
    pub bytes_batched: AtomicU64,
    /// Number of batches processed
    pub batch_count: AtomicU64,
    /// Idle polls (polls with no data)
    pub idle_polls: AtomicU64,
}

// ============================================================================
// Graphics FFI types
// ============================================================================

/// C-compatible image data for FFI transfer to Swift.
/// Fields ordered by descending alignment to minimize padding.
#[repr(C)]
pub struct FFIImageData {
    /// Image ID (unique per terminal instance).
    pub id: u64,
    /// Pointer to raw image data (base64 for iTerm2, raw bytes for Sixel/Kitty).
    pub data: *mut u8,
    /// Length of the data buffer.
    pub data_len: usize,
    /// Capacity of the data buffer (must match original Vec allocation for safe free).
    pub data_capacity: usize,
    /// Cursor row when image was received (grid-relative).
    pub anchor_row: i32,
    /// Cursor column when image was received.
    pub anchor_col: u16,
    /// Protocol that produced this image (0=iTerm2, 1=Sixel, 2=Kitty).
    pub protocol: u8,
}

/// C-compatible array of pending images.
#[repr(C)]
pub struct FFIImageArray {
    /// Pointer to array of FFIImageData structs.
    pub images: *mut FFIImageData,
    /// Number of images in the array.
    pub count: usize,
    /// Capacity of the images array (must match original Vec allocation for safe free).
    pub capacity: usize,
}

// ============================================================================
// Helper function
// ============================================================================

/// Convert CellFlags to our C-compatible flags byte
pub fn cell_flags_to_u8(flags: CellFlags) -> u8 {
    let mut result = 0u8;
    if flags.contains(CellFlags::BOLD) {
        result |= CELL_FLAG_BOLD;
    }
    if flags.contains(CellFlags::ITALIC) {
        result |= CELL_FLAG_ITALIC;
    }
    if flags.contains(CellFlags::UNDERLINE)
        || flags.contains(CellFlags::DOUBLE_UNDERLINE)
        || flags.contains(CellFlags::UNDERCURL)
        || flags.contains(CellFlags::DOTTED_UNDERLINE)
        || flags.contains(CellFlags::DASHED_UNDERLINE)
    {
        result |= CELL_FLAG_UNDERLINE;
    }
    if flags.contains(CellFlags::STRIKEOUT) {
        result |= CELL_FLAG_STRIKETHROUGH;
    }
    if flags.contains(CellFlags::INVERSE) {
        result |= CELL_FLAG_INVERSE;
    }
    if flags.contains(CellFlags::DIM) {
        result |= CELL_FLAG_DIM;
    }
    if flags.contains(CellFlags::HIDDEN) {
        result |= CELL_FLAG_HIDDEN;
    }
    result
}

/// Extract the specific underline variant from CellFlags.
/// Returns 0 if no underline is present.
pub fn underline_style(flags: CellFlags) -> u8 {
    if flags.contains(CellFlags::UNDERCURL) {
        UNDERLINE_CURL
    } else if flags.contains(CellFlags::DOUBLE_UNDERLINE) {
        UNDERLINE_DOUBLE
    } else if flags.contains(CellFlags::DOTTED_UNDERLINE) {
        UNDERLINE_DOTTED
    } else if flags.contains(CellFlags::DASHED_UNDERLINE) {
        UNDERLINE_DASHED
    } else if flags.contains(CellFlags::UNDERLINE) {
        UNDERLINE_SINGLE
    } else {
        0
    }
}

// ============================================================================
// Tests
// ============================================================================

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_cell_data_default() {
        let cell = CellData::default();
        assert_eq!(cell.character, ' ' as u32);
        assert_eq!(cell.fg_r, 255);
        assert_eq!(cell.bg_r, 0);
        assert_eq!(cell.flags, 0);
    }

    #[test]
    fn test_cell_flags_conversion() {
        let mut flags = CellFlags::empty();
        assert_eq!(cell_flags_to_u8(flags), 0);

        flags.insert(CellFlags::BOLD);
        assert_eq!(cell_flags_to_u8(flags), CELL_FLAG_BOLD);

        flags.insert(CellFlags::ITALIC);
        assert_eq!(cell_flags_to_u8(flags), CELL_FLAG_BOLD | CELL_FLAG_ITALIC);
    }
}
