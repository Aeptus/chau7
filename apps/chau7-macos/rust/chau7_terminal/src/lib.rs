//! chau7_terminal - Alacritty-based terminal emulator FFI bindings
//!
//! This crate provides C-compatible FFI bindings for terminal emulation
//! using the alacritty_terminal library and portable-pty for PTY management.

use std::ffi::{CStr, CString};
use std::io::{Read, Write};
use std::os::raw::c_char;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, OnceLock};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

use alacritty_terminal::event::{Event, EventListener};
use alacritty_terminal::grid::Dimensions;
use alacritty_terminal::index::{Column, Line, Point, Side};
use alacritty_terminal::selection::{Selection, SelectionType};
use alacritty_terminal::term::cell::Flags as CellFlags;
use alacritty_terminal::term::{Config as TermConfig, Term, TermMode};
use alacritty_terminal::vte::ansi::{Color as AnsiColor, NamedColor, Processor};

use crossbeam_channel::{bounded, Receiver, Sender, TryRecvError};
use log::{debug, error, info, trace, warn};
use parking_lot::{Mutex, RwLock};
use portable_pty::{native_pty_system, Child, CommandBuilder, PtySize};

// Static counter for terminal IDs (for logging)
static TERMINAL_COUNTER: AtomicU64 = AtomicU64::new(0);

// Global cell buffer pool for GridSnapshot memory reuse
// Using OnceLock for lazy thread-safe initialization
static CELL_BUFFER_POOL: OnceLock<CellBufferPool> = OnceLock::new();

fn get_cell_buffer_pool() -> &'static CellBufferPool {
    CELL_BUFFER_POOL.get_or_init(|| CellBufferPool::new(4))
}

// ============================================================================
// Custom SizeInfo for terminal dimensions
// ============================================================================

struct SizeInfo {
    cols: usize,
    rows: usize,
}

impl SizeInfo {
    fn new(cols: usize, rows: usize) -> Self {
        SizeInfo { cols, rows }
    }
}

impl Dimensions for SizeInfo {
    fn total_lines(&self) -> usize {
        self.rows
    }

    fn screen_lines(&self) -> usize {
        self.rows
    }

    fn columns(&self) -> usize {
        self.cols
    }
}

// ============================================================================
// C-compatible data structures
// ============================================================================

/// Flags for cell attributes (bold, italic, underline, etc.)
pub const CELL_FLAG_BOLD: u8 = 1 << 0;
pub const CELL_FLAG_ITALIC: u8 = 1 << 1;
pub const CELL_FLAG_UNDERLINE: u8 = 1 << 2;
pub const CELL_FLAG_STRIKETHROUGH: u8 = 1 << 3;
pub const CELL_FLAG_INVERSE: u8 = 1 << 4;
pub const CELL_FLAG_DIM: u8 = 1 << 5;
pub const CELL_FLAG_HIDDEN: u8 = 1 << 6;

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
        }
    }
}

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
    capacity: usize,
}

// ============================================================================
// Event listener for alacritty_terminal
// ============================================================================

/// Event listener that forwards events to a channel and tracks bell events
struct Chau7EventListener {
    sender: Sender<Event>,
    terminal_id: u64,
    /// Flag indicating if a bell occurred since last check
    bell_pending: Arc<AtomicBool>,
}

impl EventListener for Chau7EventListener {
    fn send_event(&self, event: Event) {
        trace!("[terminal-{}] Event received: {:?}", self.terminal_id, event);

        // Track bell events for Swift to poll
        if matches!(event, Event::Bell) {
            debug!("[terminal-{}] Bell event received", self.terminal_id);
            self.bell_pending.store(true, Ordering::SeqCst);
        }

        if self.sender.try_send(event).is_err() {
            trace!("[terminal-{}] Event channel full, dropping event", self.terminal_id);
        }
    }
}

// ============================================================================
// PTY reader thread message types
// ============================================================================

enum PtyMessage {
    Data(Vec<u8>),
    Closed,
}

// ============================================================================
// PTY writer wrapper
// ============================================================================

/// Wrapper that holds both the master PTY and its writer
struct PtyHandle {
    writer: Box<dyn Write + Send>,
    _master: Box<dyn portable_pty::MasterPty + Send>,
}

impl PtyHandle {
    fn write_all(&mut self, data: &[u8]) -> std::io::Result<()> {
        self.writer.write_all(data)
    }

    fn resize(&self, size: PtySize) -> Result<(), anyhow::Error> {
        self._master.resize(size)
    }
}

// ============================================================================
// Main terminal structure
// ============================================================================

/// Theme colors configuration
#[derive(Clone)]
pub struct ThemeColors {
    /// Foreground color RGB
    pub fg: (u8, u8, u8),
    /// Background color RGB
    pub bg: (u8, u8, u8),
    /// Cursor color RGB
    pub cursor: (u8, u8, u8),
    /// 16-color ANSI palette
    pub palette: [(u8, u8, u8); 16],
}

impl Default for ThemeColors {
    fn default() -> Self {
        ThemeColors {
            fg: (255, 255, 255),
            bg: (0, 0, 0),
            cursor: (255, 255, 255),
            palette: ANSI_COLORS,
        }
    }
}

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
// Performance Optimization Structures
// ============================================================================

/// Adaptive polling rate controller.
/// Adjusts polling behavior based on terminal activity to reduce CPU usage when idle.
pub struct AdaptivePoller {
    /// Last time data was received
    last_data_time: Mutex<Instant>,
    /// Current activity level (0.0 = idle, 1.0 = very active)
    activity_level: AtomicU64,  // Stored as fixed-point * 1000
    /// Consecutive idle polls
    idle_streak: AtomicU64,
    /// Consecutive active polls
    active_streak: AtomicU64,
}

impl AdaptivePoller {
    fn new() -> Self {
        Self {
            last_data_time: Mutex::new(Instant::now()),
            activity_level: AtomicU64::new(500),  // Start at 0.5
            idle_streak: AtomicU64::new(0),
            active_streak: AtomicU64::new(0),
        }
    }

    /// Record that data was received
    fn record_activity(&self, bytes: usize) {
        *self.last_data_time.lock() = Instant::now();
        self.idle_streak.store(0, Ordering::Relaxed);
        self.active_streak.fetch_add(1, Ordering::Relaxed);

        // Increase activity level based on data volume
        let current = self.activity_level.load(Ordering::Relaxed);
        let boost = (bytes as u64).min(100) * 5;  // More data = bigger boost
        let new_level = (current + boost).min(1000);
        self.activity_level.store(new_level, Ordering::Relaxed);
    }

    /// Record an idle poll (no data)
    fn record_idle(&self) {
        self.active_streak.store(0, Ordering::Relaxed);
        self.idle_streak.fetch_add(1, Ordering::Relaxed);

        // Decay activity level
        let current = self.activity_level.load(Ordering::Relaxed);
        let new_level = current.saturating_sub(10);  // Slow decay
        self.activity_level.store(new_level, Ordering::Relaxed);
    }

    /// Get suggested poll timeout in milliseconds.
    /// Returns shorter timeout when active, longer when idle.
    fn suggested_timeout_ms(&self) -> u32 {
        let idle_streak = self.idle_streak.load(Ordering::Relaxed);
        let activity = self.activity_level.load(Ordering::Relaxed);

        if activity > 800 {
            // Very active: poll immediately (0ms timeout for non-blocking)
            0
        } else if activity > 500 {
            // Moderately active: short timeout
            1
        } else if idle_streak > 100 {
            // Very idle: can wait longer
            16  // ~60fps
        } else if idle_streak > 10 {
            // Somewhat idle
            8
        } else {
            // Default
            2
        }
    }

    /// Check if we should skip this poll cycle entirely (aggressive power saving)
    fn should_skip_poll(&self) -> bool {
        let idle_streak = self.idle_streak.load(Ordering::Relaxed);
        // After 1000 idle polls (~16 seconds at 60fps), skip every other poll
        idle_streak > 1000 && idle_streak % 2 == 0
    }

    /// Get activity level as percentage (0-100)
    fn activity_percent(&self) -> u8 {
        (self.activity_level.load(Ordering::Relaxed) / 10) as u8
    }
}

impl Default for AdaptivePoller {
    fn default() -> Self {
        Self::new()
    }
}

/// Dirty row tracker for partial updates.
/// Uses a bitmap to track which rows have been modified since last sync.
pub struct DirtyRowTracker {
    /// Bitmap of dirty rows (each bit represents one row)
    /// Supports up to 512 rows (8 * 64 bits)
    dirty_bits: [AtomicU64; 8],
    /// Number of rows being tracked
    rows: AtomicU64,
    /// Whether all rows should be considered dirty
    full_dirty: AtomicBool,
}

impl DirtyRowTracker {
    fn new(rows: usize) -> Self {
        Self {
            dirty_bits: Default::default(),
            rows: AtomicU64::new(rows as u64),
            full_dirty: AtomicBool::new(true),  // Start fully dirty
        }
    }

    /// Mark a specific row as dirty
    fn mark_dirty(&self, row: usize) {
        if row >= 512 {
            self.full_dirty.store(true, Ordering::Relaxed);
            return;
        }
        let word = row / 64;
        let bit = row % 64;
        self.dirty_bits[word].fetch_or(1 << bit, Ordering::Relaxed);
    }

    /// Mark a range of rows as dirty
    fn mark_range_dirty(&self, start: usize, end: usize) {
        for row in start..=end.min(511) {
            self.mark_dirty(row);
        }
    }

    /// Mark all rows as dirty
    fn mark_all_dirty(&self) {
        self.full_dirty.store(true, Ordering::Relaxed);
    }

    /// Check if a row is dirty
    fn is_dirty(&self, row: usize) -> bool {
        if self.full_dirty.load(Ordering::Relaxed) {
            return true;
        }
        if row >= 512 {
            return true;
        }
        let word = row / 64;
        let bit = row % 64;
        (self.dirty_bits[word].load(Ordering::Relaxed) & (1 << bit)) != 0
    }

    /// Get list of dirty row indices (for partial updates)
    fn get_dirty_rows(&self) -> Vec<usize> {
        if self.full_dirty.load(Ordering::Relaxed) {
            return (0..self.rows.load(Ordering::Relaxed) as usize).collect();
        }

        let mut dirty = Vec::new();
        let rows = self.rows.load(Ordering::Relaxed) as usize;
        for row in 0..rows.min(512) {
            if self.is_dirty(row) {
                dirty.push(row);
            }
        }
        dirty
    }

    /// Clear all dirty flags
    fn clear(&self) {
        self.full_dirty.store(false, Ordering::Relaxed);
        for bits in &self.dirty_bits {
            bits.store(0, Ordering::Relaxed);
        }
    }

    /// Get count of dirty rows
    fn dirty_count(&self) -> usize {
        if self.full_dirty.load(Ordering::Relaxed) {
            return self.rows.load(Ordering::Relaxed) as usize;
        }
        self.dirty_bits.iter()
            .map(|bits| bits.load(Ordering::Relaxed).count_ones() as usize)
            .sum()
    }

    /// Update row count (e.g., on resize)
    fn set_rows(&self, rows: usize) {
        self.rows.store(rows as u64, Ordering::Relaxed);
        self.mark_all_dirty();  // Resize requires full redraw
    }
}

impl Default for DirtyRowTracker {
    fn default() -> Self {
        Self::new(24)  // Default terminal height
    }
}

/// Output buffer with batching support.
/// Accumulates small outputs into larger batches to reduce FFI overhead.
pub struct OutputBatcher {
    /// Accumulated output data
    buffer: Mutex<Vec<u8>>,
    /// Buffer capacity (pre-allocated)
    capacity: usize,
    /// Minimum batch size before flushing (unless timeout)
    min_batch_size: usize,
    /// Last flush time
    last_flush: Mutex<Instant>,
    /// Maximum time to hold data before flushing (microseconds)
    max_hold_us: u64,
}

impl OutputBatcher {
    fn new() -> Self {
        Self {
            buffer: Mutex::new(Vec::with_capacity(32 * 1024)),  // 32KB initial capacity
            capacity: 32 * 1024,
            min_batch_size: 256,  // Batch at least 256 bytes
            last_flush: Mutex::new(Instant::now()),
            max_hold_us: 2000,  // Max 2ms hold time
        }
    }

    /// Add data to the batch
    fn push(&self, data: &[u8]) {
        let mut buffer = self.buffer.lock();
        buffer.extend_from_slice(data);
    }

    /// Check if batch is ready to flush
    fn should_flush(&self) -> bool {
        let buffer = self.buffer.lock();
        if buffer.is_empty() {
            return false;
        }

        // Flush if buffer is large enough
        if buffer.len() >= self.min_batch_size {
            return true;
        }

        // Flush if held too long
        let last_flush = self.last_flush.lock();
        last_flush.elapsed().as_micros() as u64 >= self.max_hold_us
    }

    /// Flush and return the batched data
    fn flush(&self) -> Vec<u8> {
        let mut buffer = self.buffer.lock();
        let mut last_flush = self.last_flush.lock();
        *last_flush = Instant::now();

        // Take the buffer and replace with a new one
        let mut new_buffer = Vec::with_capacity(self.capacity);
        std::mem::swap(&mut *buffer, &mut new_buffer);
        new_buffer
    }

    /// Get current buffer size
    fn len(&self) -> usize {
        self.buffer.lock().len()
    }

    /// Check if buffer is empty
    fn is_empty(&self) -> bool {
        self.buffer.lock().is_empty()
    }
}

/// Memory pool for CellData buffers to reduce allocation overhead.
/// GridSnapshot creation is frequent during rendering; pooling buffers
/// avoids repeated allocations and deallocations.
pub struct CellBufferPool {
    /// Pool of available buffers (Vec<CellData>)
    pool: Mutex<Vec<Vec<CellData>>>,
    /// Maximum number of buffers to keep in pool
    max_pooled: usize,
    /// Statistics: total buffers acquired
    acquired: AtomicU64,
    /// Statistics: buffers returned to pool
    returned: AtomicU64,
    /// Statistics: new allocations (pool miss)
    allocated: AtomicU64,
}

impl CellBufferPool {
    fn new(max_pooled: usize) -> Self {
        Self {
            pool: Mutex::new(Vec::with_capacity(max_pooled)),
            max_pooled,
            acquired: AtomicU64::new(0),
            returned: AtomicU64::new(0),
            allocated: AtomicU64::new(0),
        }
    }

    /// Acquire a buffer from the pool, or allocate a new one.
    /// The buffer is cleared and has at least the requested capacity.
    fn acquire(&self, min_capacity: usize) -> Vec<CellData> {
        self.acquired.fetch_add(1, Ordering::Relaxed);

        let mut pool = self.pool.lock();
        // Try to find a buffer with sufficient capacity
        if let Some(idx) = pool.iter().position(|b| b.capacity() >= min_capacity) {
            let mut buffer = pool.swap_remove(idx);
            buffer.clear();
            return buffer;
        }
        // No suitable buffer in pool, allocate new
        drop(pool);
        self.allocated.fetch_add(1, Ordering::Relaxed);
        Vec::with_capacity(min_capacity)
    }

    /// Return a buffer to the pool for reuse.
    fn release(&self, mut buffer: Vec<CellData>) {
        self.returned.fetch_add(1, Ordering::Relaxed);
        buffer.clear();

        let mut pool = self.pool.lock();
        if pool.len() < self.max_pooled {
            pool.push(buffer);
        }
        // If pool is full, buffer is dropped here
    }

    /// Get pool statistics for debugging
    fn stats(&self) -> (u64, u64, u64, usize) {
        let pool = self.pool.lock();
        (
            self.acquired.load(Ordering::Relaxed),
            self.returned.load(Ordering::Relaxed),
            self.allocated.load(Ordering::Relaxed),
            pool.len(),
        )
    }
}

impl Default for CellBufferPool {
    fn default() -> Self {
        Self::new(4)  // Keep up to 4 buffers pooled
    }
}

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

/// The main terminal emulator structure
pub struct Chau7Terminal {
    /// Unique identifier for this terminal (for logging)
    id: u64,
    /// The alacritty terminal state machine
    term: Mutex<Term<Chau7EventListener>>,
    /// VTE processor for parsing escape sequences
    processor: Mutex<Processor>,
    /// PTY handle for writing input
    pty_handle: Mutex<PtyHandle>,
    /// Child process handle (to avoid zombies)
    child: Mutex<Option<Box<dyn Child + Send + Sync>>>,
    /// Shell process ID (for dev server monitoring)
    shell_pid: AtomicU64,
    /// Channel receiver for PTY output data
    pty_rx: Receiver<PtyMessage>,
    /// Flag to signal the reader thread to stop
    running: Arc<AtomicBool>,
    /// Reader thread handle
    reader_thread: Option<JoinHandle<()>>,
    /// Event receiver for terminal events
    event_rx: Receiver<Event>,
    /// Flag indicating if grid has changed since last poll
    grid_dirty: AtomicBool,
    /// Terminal dimensions
    cols: u16,
    rows: u16,
    /// Creation timestamp for debugging
    created_at: Instant,
    /// Total bytes received from PTY
    bytes_received: AtomicU64,
    /// Total bytes sent to PTY
    bytes_sent: AtomicU64,
    /// Theme colors for rendering (RwLock for read-heavy access pattern)
    theme_colors: RwLock<ThemeColors>,
    /// Raw output bytes from the last poll (for Swift onOutput callback - Issue #3 fix)
    last_output: Mutex<Vec<u8>>,
    /// Flag indicating if a bell occurred since last check (shared with EventListener)
    bell_pending: Arc<AtomicBool>,
    /// Performance metrics for debugging
    metrics: PerformanceMetrics,
    /// Pending terminal title change (from OSC 0/1/2)
    pending_title: Mutex<Option<String>>,
    /// Pending child exit code (from Event::ChildExit)
    pending_exit_code: Mutex<Option<i32>>,
    /// Flag indicating PTY has closed
    pty_closed: AtomicBool,

    // Performance optimization structures
    /// Adaptive polling rate controller
    adaptive_poller: AdaptivePoller,
    /// Dirty row tracker for partial updates
    dirty_rows: DirtyRowTracker,
    /// Output batcher for reducing FFI overhead
    output_batcher: OutputBatcher,
}

// ============================================================================
// Color conversion helpers
// ============================================================================

/// Default 16-color ANSI palette (basic terminal colors)
const ANSI_COLORS: [(u8, u8, u8); 16] = [
    (0, 0, 0),       // Black
    (205, 49, 49),   // Red
    (13, 188, 121),  // Green
    (229, 229, 16),  // Yellow
    (36, 114, 200),  // Blue
    (188, 63, 188),  // Magenta
    (17, 168, 205),  // Cyan
    (229, 229, 229), // White
    (102, 102, 102), // Bright Black
    (241, 76, 76),   // Bright Red
    (35, 209, 139),  // Bright Green
    (245, 245, 67),  // Bright Yellow
    (59, 142, 234),  // Bright Blue
    (214, 112, 214), // Bright Magenta
    (41, 184, 219),  // Bright Cyan
    (255, 255, 255), // Bright White
];

/// Convert ANSI 256-color index to RGB
fn ansi256_to_rgb(idx: u8) -> (u8, u8, u8) {
    if idx < 16 {
        ANSI_COLORS[idx as usize]
    } else if idx < 232 {
        // 6x6x6 color cube
        let idx = idx - 16;
        let r = (idx / 36) % 6;
        let g = (idx / 6) % 6;
        let b = idx % 6;
        let to_val = |v: u8| if v == 0 { 0 } else { 55 + v * 40 };
        (to_val(r), to_val(g), to_val(b))
    } else {
        // Grayscale ramp
        let gray = 8 + (idx - 232) * 10;
        (gray, gray, gray)
    }
}

/// Convert alacritty Color to RGB tuple using theme colors
fn color_to_rgb_with_theme(color: AnsiColor, is_fg: bool, theme: &ThemeColors) -> (u8, u8, u8) {
    match color {
        AnsiColor::Named(named) => {
            match named {
                NamedColor::Black => theme.palette[0],
                NamedColor::Red => theme.palette[1],
                NamedColor::Green => theme.palette[2],
                NamedColor::Yellow => theme.palette[3],
                NamedColor::Blue => theme.palette[4],
                NamedColor::Magenta => theme.palette[5],
                NamedColor::Cyan => theme.palette[6],
                NamedColor::White => theme.palette[7],
                NamedColor::BrightBlack => theme.palette[8],
                NamedColor::BrightRed => theme.palette[9],
                NamedColor::BrightGreen => theme.palette[10],
                NamedColor::BrightYellow => theme.palette[11],
                NamedColor::BrightBlue => theme.palette[12],
                NamedColor::BrightMagenta => theme.palette[13],
                NamedColor::BrightCyan => theme.palette[14],
                NamedColor::BrightWhite => theme.palette[15],
                NamedColor::Foreground => {
                    if is_fg { theme.fg } else { theme.bg }
                }
                NamedColor::Background => {
                    // Background color should always return theme.bg regardless of context
                    theme.bg
                }
                NamedColor::Cursor => theme.cursor,
                // Dim colors: derive from palette with reduced brightness
                NamedColor::DimBlack => dim_color(theme.palette[0]),
                NamedColor::DimRed => dim_color(theme.palette[1]),
                NamedColor::DimGreen => dim_color(theme.palette[2]),
                NamedColor::DimYellow => dim_color(theme.palette[3]),
                NamedColor::DimBlue => dim_color(theme.palette[4]),
                NamedColor::DimMagenta => dim_color(theme.palette[5]),
                NamedColor::DimCyan => dim_color(theme.palette[6]),
                NamedColor::DimWhite => dim_color(theme.palette[7]),
                NamedColor::BrightForeground => brighten_color(theme.fg),
                NamedColor::DimForeground => dim_color(theme.fg),
            }
        }
        AnsiColor::Spec(rgb) => (rgb.r, rgb.g, rgb.b),
        AnsiColor::Indexed(idx) => {
            if idx < 16 {
                // Use theme palette for indexed colors 0-15
                theme.palette[idx as usize]
            } else {
                // Use standard 256-color calculation for indices 16-255
                ansi256_to_rgb(idx)
            }
        }
    }
}

/// Dim a color by reducing its brightness
fn dim_color(color: (u8, u8, u8)) -> (u8, u8, u8) {
    (
        (color.0 as u16 * 2 / 3) as u8,
        (color.1 as u16 * 2 / 3) as u8,
        (color.2 as u16 * 2 / 3) as u8,
    )
}

/// Brighten a color
fn brighten_color(color: (u8, u8, u8)) -> (u8, u8, u8) {
    (
        ((color.0 as u16 * 4 / 3).min(255)) as u8,
        ((color.1 as u16 * 4 / 3).min(255)) as u8,
        ((color.2 as u16 * 4 / 3).min(255)) as u8,
    )
}

/// Convert CellFlags to our C-compatible flags byte
fn cell_flags_to_u8(flags: CellFlags) -> u8 {
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

// ============================================================================
// Terminal implementation
// ============================================================================

impl Chau7Terminal {
    /// Create a new terminal with the specified dimensions and shell
    fn new(cols: u16, rows: u16, shell: &str) -> Result<Self, String> {
        Self::new_with_env(cols, rows, shell, &[])
    }

    /// Create a new terminal with the specified dimensions, shell, and environment variables
    fn new_with_env(cols: u16, rows: u16, shell: &str, env_vars: &[(&str, &str)]) -> Result<Self, String> {
        let id = TERMINAL_COUNTER.fetch_add(1, Ordering::SeqCst);
        let created_at = Instant::now();

        info!("[terminal-{}] Creating new terminal: {}x{}, shell={:?}", id, cols, rows, shell);

        // Validate dimensions
        if cols == 0 || rows == 0 {
            error!("[terminal-{}] Invalid dimensions: {}x{}", id, cols, rows);
            return Err(format!("Invalid dimensions: {}x{}", cols, rows));
        }
        if cols > 1000 || rows > 1000 {
            warn!("[terminal-{}] Large dimensions requested: {}x{}", id, cols, rows);
        }

        // Create channels for events and PTY data
        let (event_tx, event_rx) = bounded(256);
        let (pty_tx, pty_rx) = bounded(4096);
        debug!("[terminal-{}] Created event channel (cap=256) and PTY channel (cap=4096)", id);

        // Create bell pending flag (shared between EventListener and Chau7Terminal)
        let bell_pending = Arc::new(AtomicBool::new(false));

        // Create the event listener
        let event_listener = Chau7EventListener {
            sender: event_tx,
            terminal_id: id,
            bell_pending: bell_pending.clone(),
        };

        // Create terminal configuration
        let term_config = TermConfig::default();

        // Create the terminal with proper dimensions
        let term_size = SizeInfo::new(cols as usize, rows as usize);
        let term = Term::new(term_config, &term_size, event_listener);
        debug!("[terminal-{}] Created alacritty Terminal instance", id);

        // Create PTY
        info!("[terminal-{}] Opening PTY...", id);
        let pty_system = native_pty_system();
        let pty_size = PtySize {
            rows,
            cols,
            pixel_width: 0,
            pixel_height: 0,
        };

        let pair = pty_system
            .openpty(pty_size)
            .map_err(|e| {
                error!("[terminal-{}] Failed to open PTY: {}", id, e);
                format!("Failed to open PTY: {}", e)
            })?;
        debug!("[terminal-{}] PTY opened successfully", id);

        // Determine shell to use
        let shell_path = if shell.is_empty() {
            let default_shell = std::env::var("SHELL").unwrap_or_else(|_| "/bin/bash".to_string());
            info!("[terminal-{}] Using default shell from $SHELL: {}", id, default_shell);
            default_shell
        } else {
            info!("[terminal-{}] Using specified shell: {}", id, shell);
            shell.to_string()
        };

        // Spawn the shell
        let mut cmd = CommandBuilder::new(&shell_path);
        // Disable macOS shell session save/restore (avoids "Restored session" message)
        cmd.env("SHELL_SESSIONS_DISABLE", "1");
        // Disable zsh's partial line marker (the % that appears at startup)
        cmd.env("PROMPT_EOL_MARK", "");
        // Add any additional environment variables passed from Swift
        for (key, value) in env_vars {
            debug!("[terminal-{}] Setting env: {}={}", id, key, value);
            cmd.env(key, value);
        }
        info!("[terminal-{}] Spawning shell process: {} (with {} extra env vars)", id, shell_path, env_vars.len());

        let child = pair
            .slave
            .spawn_command(cmd)
            .map_err(|e| {
                error!("[terminal-{}] Failed to spawn shell '{}': {}", id, shell_path, e);
                format!("Failed to spawn shell: {}", e)
            })?;

        // Capture shell PID for dev server monitoring
        let shell_pid = child.process_id().unwrap_or(0);
        info!("[terminal-{}] Shell process spawned successfully (PID: {})", id, shell_pid);

        // Get reader for PTY output
        let mut reader = pair
            .master
            .try_clone_reader()
            .map_err(|e| {
                error!("[terminal-{}] Failed to clone PTY reader: {}", id, e);
                format!("Failed to clone PTY reader: {}", e)
            })?;
        debug!("[terminal-{}] PTY reader cloned", id);

        // Get writer for PTY input
        let writer = pair
            .master
            .take_writer()
            .map_err(|e| {
                error!("[terminal-{}] Failed to get PTY writer: {}", id, e);
                format!("Failed to get PTY writer: {}", e)
            })?;
        debug!("[terminal-{}] PTY writer obtained", id);

        // Create running flag for the reader thread
        let running = Arc::new(AtomicBool::new(true));
        let running_clone = running.clone();
        let thread_terminal_id = id;

        // Spawn reader thread
        info!("[terminal-{}] Spawning PTY reader thread", id);
        let reader_thread = thread::Builder::new()
            .name(format!("pty-reader-{}", id))
            .spawn(move || {
                debug!("[terminal-{}] PTY reader thread started", thread_terminal_id);
                let mut buf = [0u8; 8192];
                let mut total_bytes = 0u64;

                while running_clone.load(Ordering::SeqCst) {
                    match reader.read(&mut buf) {
                        Ok(0) => {
                            info!("[terminal-{}] PTY EOF received (total bytes read: {})",
                                  thread_terminal_id, total_bytes);
                            let _ = pty_tx.send(PtyMessage::Closed);
                            break;
                        }
                        Ok(n) => {
                            total_bytes += n as u64;
                            // Log first few reads at info level to debug startup output
                            if total_bytes <= 4096 {
                                let preview: String = buf[..n].iter()
                                    .take(200)
                                    .map(|&b| if b >= 32 && b < 127 { b as char } else { '.' })
                                    .collect();
                                info!("[terminal-{}] PTY startup read {} bytes: {:?}",
                                      thread_terminal_id, n, preview);
                            } else {
                                trace!("[terminal-{}] PTY read {} bytes (total: {})",
                                       thread_terminal_id, n, total_bytes);
                            }
                            let data = buf[..n].to_vec();
                            if pty_tx.send(PtyMessage::Data(data)).is_err() {
                                warn!("[terminal-{}] PTY channel closed, exiting reader", thread_terminal_id);
                                break;
                            }
                        }
                        Err(e) => {
                            // Check if this is just because the PTY was closed
                            if running_clone.load(Ordering::SeqCst) {
                                error!("[terminal-{}] PTY read error: {} (total bytes read: {})",
                                       thread_terminal_id, e, total_bytes);
                            } else {
                                debug!("[terminal-{}] PTY read interrupted during shutdown", thread_terminal_id);
                            }
                            let _ = pty_tx.send(PtyMessage::Closed);
                            break;
                        }
                    }
                }
                info!("[terminal-{}] PTY reader thread exiting", thread_terminal_id);
            })
            .map_err(|e| {
                error!("[terminal-{}] Failed to spawn reader thread: {}", id, e);
                format!("Failed to spawn reader thread: {}", e)
            })?;

        // Create the PTY handle
        let pty_handle = PtyHandle {
            writer,
            _master: pair.master,
        };

        info!("[terminal-{}] Terminal created successfully in {:?}", id, created_at.elapsed());

        Ok(Chau7Terminal {
            id,
            term: Mutex::new(term),
            processor: Mutex::new(Processor::new()),
            pty_handle: Mutex::new(pty_handle),
            child: Mutex::new(Some(child)),
            shell_pid: AtomicU64::new(shell_pid as u64),
            pty_rx,
            running,
            reader_thread: Some(reader_thread),
            event_rx,
            grid_dirty: AtomicBool::new(true),
            cols,
            rows,
            created_at,
            bytes_received: AtomicU64::new(0),
            bytes_sent: AtomicU64::new(0),
            theme_colors: RwLock::new(ThemeColors::default()),
            last_output: Mutex::new(Vec::new()),
            bell_pending,
            metrics: PerformanceMetrics::default(),
            pending_title: Mutex::new(None),
            pending_exit_code: Mutex::new(None),
            pty_closed: AtomicBool::new(false),
            // Performance optimizations
            adaptive_poller: AdaptivePoller::new(),
            dirty_rows: DirtyRowTracker::new(rows as usize),
            output_batcher: OutputBatcher::new(),
        })
    }

    /// Set theme colors for rendering
    fn set_colors(
        &self,
        fg: (u8, u8, u8),
        bg: (u8, u8, u8),
        cursor: (u8, u8, u8),
        palette: [(u8, u8, u8); 16],
    ) {
        debug!("[terminal-{}] Setting theme colors: fg={:?}, bg={:?}, cursor={:?}",
               self.id, fg, bg, cursor);
        let mut theme = self.theme_colors.write();
        theme.fg = fg;
        theme.bg = bg;
        theme.cursor = cursor;
        theme.palette = palette;
        // Mark grid dirty so it gets re-rendered with new colors
        self.grid_dirty.store(true, Ordering::SeqCst);
    }

    /// Send bytes to the PTY (user input)
    fn send_bytes(&self, data: &[u8]) {
        trace!("[terminal-{}] Sending {} bytes to PTY", self.id, data.len());
        let mut handle = self.pty_handle.lock();
        match handle.write_all(data) {
            Ok(()) => {
                self.bytes_sent.fetch_add(data.len() as u64, Ordering::Relaxed);
                trace!("[terminal-{}] Successfully wrote {} bytes to PTY", self.id, data.len());
            }
            Err(e) => {
                error!("[terminal-{}] Failed to write {} bytes to PTY: {}", self.id, data.len(), e);
            }
        }
    }

    /// Resize the terminal
    fn resize(&mut self, cols: u16, rows: u16) {
        info!("[terminal-{}] Resizing terminal: {}x{} -> {}x{}",
              self.id, self.cols, self.rows, cols, rows);

        if cols == 0 || rows == 0 {
            warn!("[terminal-{}] Ignoring invalid resize dimensions: {}x{}", self.id, cols, rows);
            return;
        }

        self.cols = cols;
        self.rows = rows;

        // Resize PTY
        let pty_size = PtySize {
            rows,
            cols,
            pixel_width: 0,
            pixel_height: 0,
        };
        let handle = self.pty_handle.lock();
        if let Err(e) = handle.resize(pty_size) {
            error!("[terminal-{}] Failed to resize PTY: {}", self.id, e);
        } else {
            debug!("[terminal-{}] PTY resized successfully", self.id);
        }
        drop(handle);

        // Resize terminal
        let mut term = self.term.lock();
        let term_size = SizeInfo::new(cols as usize, rows as usize);
        term.resize(term_size);
        debug!("[terminal-{}] Terminal state resized", self.id);

        self.grid_dirty.store(true, Ordering::SeqCst);
    }

    /// Poll for new data from PTY, process it, and return whether grid changed.
    /// Raw output bytes are stored in `last_output` for retrieval via `get_last_output()`.
    ///
    /// Performance optimizations:
    /// - Adaptive polling adjusts timeout based on activity
    /// - Output batching reduces FFI overhead
    /// - Dirty row tracking enables partial updates
    fn poll(&self, timeout_ms: u32) -> bool {
        let poll_start = Instant::now();

        // Adaptive polling: use suggested timeout or caller's timeout (whichever is shorter)
        let adaptive_timeout = self.adaptive_poller.suggested_timeout_ms();
        let effective_timeout = timeout_ms.min(adaptive_timeout);
        trace!("[terminal-{}] poll(timeout_ms={}, adaptive={})", self.id, timeout_ms, effective_timeout);

        let timeout = Duration::from_millis(effective_timeout as u64);
        let mut had_data = false;
        let mut bytes_this_poll = 0usize;

        // Clear the last_output buffer at the start of each poll
        // This ensures we only return bytes from the current poll cycle
        {
            let mut last_output = self.last_output.lock();
            last_output.clear();
        }

        // Try to receive data with timeout for the first message
        match self.pty_rx.recv_timeout(timeout) {
            Ok(PtyMessage::Data(data)) => {
                bytes_this_poll += data.len();
                // Store raw bytes before processing (Issue #3 fix: enable onOutput callback)
                {
                    let mut last_output = self.last_output.lock();
                    last_output.extend_from_slice(&data);
                }
                self.process_pty_data(&data);
                had_data = true;
            }
            Ok(PtyMessage::Closed) => {
                info!("[terminal-{}] PTY closed message received in poll", self.id);
                self.pty_closed.store(true, Ordering::SeqCst);
                return false;
            }
            Err(crossbeam_channel::RecvTimeoutError::Timeout) => {
                trace!("[terminal-{}] poll timeout (no data)", self.id);
            }
            Err(crossbeam_channel::RecvTimeoutError::Disconnected) => {
                warn!("[terminal-{}] PTY channel disconnected", self.id);
                self.pty_closed.store(true, Ordering::SeqCst);
            }
        }

        // Drain any additional pending data without blocking
        // This batches multiple small reads into one poll cycle
        loop {
            match self.pty_rx.try_recv() {
                Ok(PtyMessage::Data(data)) => {
                    bytes_this_poll += data.len();
                    // Store raw bytes before processing (Issue #3 fix: enable onOutput callback)
                    {
                        let mut last_output = self.last_output.lock();
                        last_output.extend_from_slice(&data);
                    }
                    self.process_pty_data(&data);
                    had_data = true;
                }
                Ok(PtyMessage::Closed) => {
                    info!("[terminal-{}] PTY closed message received while draining", self.id);
                    self.pty_closed.store(true, Ordering::SeqCst);
                    break;
                }
                Err(TryRecvError::Empty) => break,
                Err(TryRecvError::Disconnected) => {
                    warn!("[terminal-{}] PTY channel disconnected while draining", self.id);
                    self.pty_closed.store(true, Ordering::SeqCst);
                    break;
                }
            }
        }

        // Process terminal events - importantly handle PtyWrite for cursor position reports (ESC[6n)
        let mut event_count = 0;
        let mut pty_write_count = 0;
        while let Ok(event) = self.event_rx.try_recv() {
            event_count += 1;
            match event {
                Event::PtyWrite(text) => {
                    // Write response back to PTY (e.g., cursor position report ESC[row;colR)
                    pty_write_count += 1;
                    let bytes = text.as_bytes();
                    trace!("[terminal-{}] PtyWrite event: {} bytes", self.id, bytes.len());
                    let mut handle = self.pty_handle.lock();
                    if let Err(e) = handle.writer.write_all(bytes) {
                        warn!("[terminal-{}] Failed to write PtyWrite response: {}", self.id, e);
                    } else if let Err(e) = handle.writer.flush() {
                        warn!("[terminal-{}] Failed to flush PtyWrite response: {}", self.id, e);
                    }
                }
                Event::Title(title) => {
                    trace!("[terminal-{}] Title change: {}", self.id, title);
                    *self.pending_title.lock() = Some(title);
                }
                Event::ChildExit(code) => {
                    debug!("[terminal-{}] Child exit with code: {}", self.id, code);
                    *self.pending_exit_code.lock() = Some(code);
                }
                _ => {
                    // Other events (Bell handled by EventListener, others ignored)
                }
            }
        }
        if event_count > 0 {
            trace!("[terminal-{}] Processed {} terminal events ({} PtyWrite)", self.id, event_count, pty_write_count);
        }

        // Update adaptive poller based on activity
        if had_data {
            self.bytes_received.fetch_add(bytes_this_poll as u64, Ordering::Relaxed);
            debug!("[terminal-{}] poll: processed {} bytes", self.id, bytes_this_poll);
            self.grid_dirty.store(true, Ordering::SeqCst);
            self.adaptive_poller.record_activity(bytes_this_poll);

            // Mark all rows dirty when new data arrives (for now)
            // TODO: Track specific dirty rows during VTE processing
            self.dirty_rows.mark_all_dirty();

            // Track batching metrics
            self.metrics.bytes_batched.fetch_add(bytes_this_poll as u64, Ordering::Relaxed);
            self.metrics.batch_count.fetch_add(1, Ordering::Relaxed);
        } else {
            self.adaptive_poller.record_idle();
            self.metrics.idle_polls.fetch_add(1, Ordering::Relaxed);
        }

        let was_dirty = self.grid_dirty.swap(false, Ordering::SeqCst);

        // Track performance metrics
        let poll_time_us = poll_start.elapsed().as_micros() as u64;
        self.metrics.poll_count.fetch_add(1, Ordering::Relaxed);
        self.metrics.poll_time_us.fetch_add(poll_time_us, Ordering::Relaxed);
        // Update max poll time (non-atomic but acceptable for metrics)
        let current_max = self.metrics.max_poll_time_us.load(Ordering::Relaxed);
        if poll_time_us > current_max {
            self.metrics.max_poll_time_us.store(poll_time_us, Ordering::Relaxed);
        }

        trace!("[terminal-{}] poll returning: {} (took {}µs, activity={}%)",
               self.id, was_dirty, poll_time_us, self.adaptive_poller.activity_percent());
        was_dirty
    }

    /// Get the raw output bytes from the last poll.
    /// Returns the bytes and clears the internal buffer.
    /// This enables Swift to forward raw PTY output to the onOutput callback.
    fn get_last_output(&self) -> Vec<u8> {
        let mut last_output = self.last_output.lock();
        std::mem::take(&mut *last_output)
    }

    /// Process PTY output data through the VTE processor
    fn process_pty_data(&self, data: &[u8]) {
        trace!("[terminal-{}] Processing {} bytes of PTY data", self.id, data.len());
        let mut term = self.term.lock();
        let mut processor = self.processor.lock();
        processor.advance(&mut *term, data);
    }

    /// Inject output bytes directly into the terminal (without sending to PTY).
    /// This is used for UI-only content like the power user tip header.
    fn inject_output(&self, data: &[u8]) {
        if data.is_empty() {
            return;
        }
        trace!("[terminal-{}] Injecting {} bytes of output", self.id, data.len());
        self.process_pty_data(data);
        self.grid_dirty.store(true, Ordering::SeqCst);
        self.dirty_rows.mark_all_dirty();
    }

    /// Create a snapshot of the current grid state
    fn get_grid_snapshot(&self) -> GridSnapshot {
        debug!("[terminal-{}] Creating grid snapshot", self.id);
        let start = Instant::now();

        let term = self.term.lock();
        let theme = self.theme_colors.read();  // RwLock: allow concurrent readers
        let grid = term.grid();

        let cols = grid.columns();
        let rows = grid.screen_lines();
        let display_offset = grid.display_offset();
        let history_size = grid.history_size();

        let total_cells = cols * rows;
        trace!("[terminal-{}] Grid snapshot: {}x{}, {} total cells, history={}, offset={}",
               self.id, cols, rows, total_cells, history_size, display_offset);

        // Get selection range if any (convert to absolute grid coordinates)
        let selection_range = term.selection.as_ref().map(|sel| {
            sel.to_range(&*term)
        }).flatten();

        // Acquire buffer from pool (reduces allocation overhead)
        let mut cells: Vec<CellData> = get_cell_buffer_pool().acquire(total_cells);

        // Iterate through visible cells
        for line_idx in 0..rows {
            let line = Line(line_idx as i32);
            for col_idx in 0..cols {
                let point = Point::new(line, Column(col_idx));
                let cell = &grid[point];

                let character = cell.c as u32;
                let (mut fg_r, mut fg_g, mut fg_b) = color_to_rgb_with_theme(cell.fg, true, &theme);
                let (mut bg_r, mut bg_g, mut bg_b) = color_to_rgb_with_theme(cell.bg, false, &theme);
                let flags = cell_flags_to_u8(cell.flags);

                // Apply selection highlighting by inverting fg/bg colors
                // Need to convert visible point to absolute grid coordinates for comparison
                let absolute_point = Point::new(
                    Line(line_idx as i32 - display_offset as i32),
                    Column(col_idx),
                );
                if let Some(ref range) = selection_range {
                    if range.contains(absolute_point) {
                        // Swap foreground and background for selected cells
                        std::mem::swap(&mut fg_r, &mut bg_r);
                        std::mem::swap(&mut fg_g, &mut bg_g);
                        std::mem::swap(&mut fg_b, &mut bg_b);
                    }
                }

                cells.push(CellData {
                    character,
                    fg_r,
                    fg_g,
                    fg_b,
                    bg_r,
                    bg_g,
                    bg_b,
                    flags,
                });
            }
        }

        // Convert to raw pointer - store capacity for proper deallocation
        let capacity = cells.capacity();
        let len = cells.len();
        let mut boxed = cells.into_boxed_slice();
        let cells_ptr = boxed.as_mut_ptr();
        std::mem::forget(boxed);

        // Track performance metrics
        let snapshot_time_us = start.elapsed().as_micros() as u64;
        self.metrics.grid_snapshot_count.fetch_add(1, Ordering::Relaxed);
        self.metrics.grid_snapshot_time_us.fetch_add(snapshot_time_us, Ordering::Relaxed);
        let current_max = self.metrics.max_grid_snapshot_time_us.load(Ordering::Relaxed);
        if snapshot_time_us > current_max {
            self.metrics.max_grid_snapshot_time_us.store(snapshot_time_us, Ordering::Relaxed);
        }

        debug!("[terminal-{}] Grid snapshot created in {}µs (len={}, cap={})",
               self.id, snapshot_time_us, len, capacity);

        GridSnapshot {
            cells: cells_ptr,
            cols: cols as u16,
            rows: rows as u16,
            scrollback_rows: history_size as u32,
            display_offset: display_offset as u32,
            capacity,
        }
    }

    /// Get current scroll position as a normalized value (0.0 = bottom, 1.0 = top of history)
    fn scroll_position(&self) -> f64 {
        let term = self.term.lock();
        let grid = term.grid();
        let history_size = grid.history_size();
        if history_size == 0 {
            return 0.0;
        }
        let display_offset = grid.display_offset();
        let pos = display_offset as f64 / history_size as f64;
        trace!("[terminal-{}] scroll_position: {} (offset={}, history={})",
               self.id, pos, display_offset, history_size);
        pos
    }

    /// Scroll to a normalized position (0.0 = bottom, 1.0 = top of history)
    fn scroll_to(&self, position: f64) {
        debug!("[terminal-{}] scroll_to({})", self.id, position);
        let mut term = self.term.lock();
        let history_size = term.grid().history_size();
        if history_size == 0 {
            trace!("[terminal-{}] scroll_to: no history, ignoring", self.id);
            return;
        }
        let target_offset = (position.clamp(0.0, 1.0) * history_size as f64) as usize;
        let current_offset = term.grid().display_offset();

        if target_offset > current_offset {
            term.scroll_display(alacritty_terminal::grid::Scroll::Delta(
                (target_offset - current_offset) as i32,
            ));
        } else if target_offset < current_offset {
            term.scroll_display(alacritty_terminal::grid::Scroll::Delta(
                -((current_offset - target_offset) as i32),
            ));
        }
        trace!("[terminal-{}] scroll_to: {} -> {} (target offset: {})",
               self.id, current_offset, target_offset, target_offset);
        self.grid_dirty.store(true, Ordering::SeqCst);
    }

    /// Scroll by a number of lines (positive = up/back, negative = down/forward)
    fn scroll_lines(&self, lines: i32) {
        debug!("[terminal-{}] scroll_lines({})", self.id, lines);
        let mut term = self.term.lock();
        term.scroll_display(alacritty_terminal::grid::Scroll::Delta(lines));
        self.grid_dirty.store(true, Ordering::SeqCst);
    }

    /// Get the currently selected text, if any
    fn selection_text(&self) -> Option<String> {
        let term = self.term.lock();
        let text = term.selection_to_string();
        if let Some(ref t) = text {
            debug!("[terminal-{}] selection_text: {} chars", self.id, t.len());
        } else {
            trace!("[terminal-{}] selection_text: no selection", self.id);
        }
        text
    }

    /// Clear any active selection
    fn selection_clear(&self) {
        debug!("[terminal-{}] selection_clear", self.id);
        let mut term = self.term.lock();
        term.selection = None;
        self.grid_dirty.store(true, Ordering::SeqCst);
    }

    /// Start a new selection at the given position
    /// selection_type: 0 = Simple (character), 1 = Block, 2 = Semantic (word), 3 = Lines
    fn selection_start(&self, col: i32, row: i32, selection_type: u8) {
        debug!("[terminal-{}] selection_start(col={}, row={}, type={})", self.id, col, row, selection_type);
        let mut term = self.term.lock();

        let ty = match selection_type {
            0 => SelectionType::Simple,
            1 => SelectionType::Block,
            2 => SelectionType::Semantic,
            3 => SelectionType::Lines,
            _ => SelectionType::Simple,
        };

        let point = Point::new(Line(row), Column(col as usize));
        let selection = Selection::new(ty, point, Side::Left);
        term.selection = Some(selection);
        self.grid_dirty.store(true, Ordering::SeqCst);
    }

    /// Update the current selection to extend to the given position
    /// Uses Side::Right for the endpoint, which is the standard behavior for terminal selection
    fn selection_update(&self, col: i32, row: i32) {
        debug!("[terminal-{}] selection_update(col={}, row={})", self.id, col, row);
        let mut term = self.term.lock();

        if let Some(ref mut selection) = term.selection {
            let point = Point::new(Line(row), Column(col as usize));
            // Side::Right is appropriate for the selection endpoint
            // The selection will include the full cell at this position
            selection.update(point, Side::Right);
            self.grid_dirty.store(true, Ordering::SeqCst);
        }
    }

    /// Select all content (screen + scrollback)
    fn selection_all(&self) {
        debug!("[terminal-{}] selection_all", self.id);
        let mut term = self.term.lock();
        let grid = term.grid();

        // Get the total range: from top of history to bottom of screen
        let history_size = grid.history_size();
        let screen_lines = grid.screen_lines();

        // Start point: top-left of scrollback (or screen if no scrollback)
        let start_line = -(history_size as i32);
        let start = Point::new(Line(start_line), Column(0));

        // Create selection starting at top-left
        let mut selection = Selection::new(SelectionType::Simple, start, Side::Left);

        // End point: bottom-right of screen
        let end_line = (screen_lines as i32) - 1;
        let end_col = grid.columns().saturating_sub(1);
        let end = Point::new(Line(end_line), Column(end_col));

        // Update selection to extend to bottom-right
        selection.update(end, Side::Right);

        term.selection = Some(selection);
        self.grid_dirty.store(true, Ordering::SeqCst);
        debug!("[terminal-{}] selection_all: selected from line {} to line {}",
               self.id, start_line, end_line);
    }

    /// Get cursor position
    fn cursor_position(&self) -> (u16, u16) {
        let term = self.term.lock();
        let cursor = term.grid().cursor.point;
        let pos = (cursor.column.0 as u16, cursor.line.0 as u16);
        trace!("[terminal-{}] cursor_position: ({}, {})", self.id, pos.0, pos.1);
        pos
    }

    /// Clear the scrollback history buffer
    fn clear_scrollback(&self) {
        info!("[terminal-{}] clear_scrollback: Clearing scrollback history", self.id);
        let mut term = self.term.lock();
        term.grid_mut().clear_history();
        self.grid_dirty.store(true, Ordering::SeqCst);
        debug!("[terminal-{}] clear_scrollback: History cleared", self.id);
    }

    /// Set the scrollback buffer size (number of lines)
    fn set_scrollback_size(&self, lines: usize) {
        info!("[terminal-{}] set_scrollback_size: Setting scrollback to {} lines", self.id, lines);
        let mut term = self.term.lock();
        term.grid_mut().update_history(lines);
        self.grid_dirty.store(true, Ordering::SeqCst);
        debug!("[terminal-{}] set_scrollback_size: Scrollback set to {} lines", self.id, lines);
    }

    /// Get the current display offset (0 = at bottom, >0 = scrolled up)
    fn display_offset(&self) -> usize {
        let term = self.term.lock();
        term.grid().display_offset()
    }

    /// Get terminal statistics for debugging
    fn stats(&self) -> (u64, u64, Duration) {
        (
            self.bytes_sent.load(Ordering::Relaxed),
            self.bytes_received.load(Ordering::Relaxed),
            self.created_at.elapsed(),
        )
    }

    /// Get text for a specific line in the grid (visible or scrollback).
    /// `row` is relative to the grid coordinate system (0 = top of viewport).
    /// Negative rows refer to scrollback when available.
    fn line_text(&self, row: i32) -> Option<String> {
        let term = self.term.lock();
        let grid = term.grid();
        let cols = grid.columns();
        let rows = grid.screen_lines() as i32;
        let history = grid.history_size() as i32;

        let min_row = -history;
        let max_row = rows - 1;
        if row < min_row || row > max_row {
            return None;
        }

        let line = Line(row);
        let mut text = String::with_capacity(cols);
        for col in 0..cols {
            let point = Point::new(line, Column(col));
            let cell = &grid[point];
            let ch = cell.c;
            if ch == '\u{0}' {
                text.push(' ');
            } else {
                text.push(ch);
            }
        }

        while text.ends_with(' ') {
            text.pop();
        }

        Some(text)
    }

    /// Check if bracketed paste mode is enabled
    /// This queries alacritty_terminal's TermMode::BRACKETED_PASTE flag
    fn is_bracketed_paste_mode(&self) -> bool {
        let term = self.term.lock();
        let mode = term.mode();
        let enabled = mode.contains(TermMode::BRACKETED_PASTE);
        trace!("[terminal-{}] is_bracketed_paste_mode: {}", self.id, enabled);
        enabled
    }

    /// Check if a bell event has occurred since the last check, and clear the flag
    /// Returns true if bell was triggered
    fn check_bell(&self) -> bool {
        let was_pending = self.bell_pending.swap(false, Ordering::SeqCst);
        if was_pending {
            debug!("[terminal-{}] check_bell: Bell was pending, now cleared", self.id);
        }
        was_pending
    }

    /// Get the current mouse mode as a bitmask.
    /// Returns a u32 representing which mouse modes are active:
    /// - Bit 0 (1): MOUSE_REPORT_CLICK - Basic mouse click reporting (mode 1000)
    /// - Bit 1 (2): MOUSE_DRAG - Mouse drag reporting (mode 1002)
    /// - Bit 2 (4): MOUSE_MOTION - All mouse motion reporting (mode 1003)
    /// - Bit 3 (8): FOCUS_IN_OUT - Focus in/out reporting (mode 1004)
    /// - Bit 4 (16): SGR_MOUSE - SGR extended coordinates (mode 1006)
    ///
    /// If any of the mouse tracking bits (bits 0-2) are set, mouse reporting is active.
    fn mouse_mode(&self) -> u32 {
        let term = self.term.lock();
        let mode = term.mode();
        let mut result: u32 = 0;

        // Map TermMode flags to our bitmask
        if mode.contains(TermMode::MOUSE_REPORT_CLICK) {
            result |= 1;  // Bit 0
        }
        if mode.contains(TermMode::MOUSE_DRAG) {
            result |= 2;  // Bit 1
        }
        if mode.contains(TermMode::MOUSE_MOTION) {
            result |= 4;  // Bit 2
        }
        if mode.contains(TermMode::FOCUS_IN_OUT) {
            result |= 8;  // Bit 3
        }
        if mode.contains(TermMode::SGR_MOUSE) {
            result |= 16; // Bit 4
        }

        trace!("[terminal-{}] mouse_mode: {:05b} ({})", self.id, result, result);
        result
    }

    /// Check if any mouse tracking is active (click, drag, or motion reporting)
    fn is_mouse_reporting_active(&self) -> bool {
        let mode = self.mouse_mode();
        // Bits 0-2 are the actual mouse tracking modes
        let mouse_tracking_mask: u32 = 0b111;
        (mode & mouse_tracking_mask) != 0
    }

    /// Check if application cursor mode (DECCKM) is enabled
    /// When enabled, arrow keys send SS3 sequences (ESC O A/B/C/D) instead of CSI sequences (ESC [ A/B/C/D)
    /// This is typically set by programs like vim, less, tmux via escape sequence ESC[?1h
    fn is_application_cursor_mode(&self) -> bool {
        let term = self.term.lock();
        let mode = term.mode();
        let enabled = mode.contains(TermMode::APP_CURSOR);
        trace!("[terminal-{}] is_application_cursor_mode: {}", self.id, enabled);
        enabled
    }

    /// Get the shell process ID (for dev server monitoring)
    fn shell_pid(&self) -> u64 {
        self.shell_pid.load(Ordering::Relaxed)
    }

    /// Get comprehensive debug state snapshot
    fn debug_state(&self) -> DebugState {
        let term = self.term.lock();
        let grid = term.grid();
        let cursor = grid.cursor.point;
        let mode = term.mode();
        let has_selection = term.selection.is_some();
        let history_size = grid.history_size() as u32;
        let display_offset = grid.display_offset() as u32;
        let cursor_col = cursor.column.0 as u16;
        let cursor_row = cursor.line.0 as u16;
        let bracketed_paste = mode.contains(TermMode::BRACKETED_PASTE);
        let app_cursor = mode.contains(TermMode::APP_CURSOR);
        drop(term);

        let poll_count = self.metrics.poll_count.load(Ordering::Relaxed);
        let poll_time = self.metrics.poll_time_us.load(Ordering::Relaxed);
        let grid_count = self.metrics.grid_snapshot_count.load(Ordering::Relaxed);
        let grid_time = self.metrics.grid_snapshot_time_us.load(Ordering::Relaxed);
        let batch_count = self.metrics.batch_count.load(Ordering::Relaxed);
        let bytes_batched = self.metrics.bytes_batched.load(Ordering::Relaxed);
        let idle_polls = self.metrics.idle_polls.load(Ordering::Relaxed);

        DebugState {
            id: self.id,
            cols: self.cols,
            rows: self.rows,
            history_size,
            display_offset,
            cursor_col,
            cursor_row,
            bytes_sent: self.bytes_sent.load(Ordering::Relaxed),
            bytes_received: self.bytes_received.load(Ordering::Relaxed),
            uptime_ms: self.created_at.elapsed().as_millis() as u64,
            grid_dirty: self.grid_dirty.load(Ordering::Relaxed) as u8,
            running: self.running.load(Ordering::Relaxed) as u8,
            has_selection: has_selection as u8,
            mouse_mode: self.mouse_mode(),
            bracketed_paste: bracketed_paste as u8,
            app_cursor: app_cursor as u8,
            poll_count,
            avg_poll_time_us: if poll_count > 0 { poll_time / poll_count } else { 0 },
            max_poll_time_us: self.metrics.max_poll_time_us.load(Ordering::Relaxed),
            avg_grid_snapshot_time_us: if grid_count > 0 { grid_time / grid_count } else { 0 },
            max_grid_snapshot_time_us: self.metrics.max_grid_snapshot_time_us.load(Ordering::Relaxed),
            // New performance metrics
            activity_percent: self.adaptive_poller.activity_percent(),
            idle_polls,
            avg_batch_size: if batch_count > 0 { bytes_batched / batch_count } else { 0 },
            dirty_row_count: self.dirty_rows.dirty_count() as u32,
        }
    }

    /// Get full buffer text (visible + scrollback) for debugging
    fn full_buffer_text(&self) -> String {
        let term = self.term.lock();
        let grid = term.grid();
        let cols = grid.columns();
        let screen_lines = grid.screen_lines() as i32;
        let history = grid.history_size() as i32;

        let mut result = String::new();
        for row in (-history)..screen_lines {
            let line = Line(row);
            let mut line_text = String::with_capacity(cols);
            for col in 0..cols {
                let point = Point::new(line, Column(col));
                let cell = &grid[point];
                let ch = cell.c;
                if ch == '\u{0}' {
                    line_text.push(' ');
                } else {
                    line_text.push(ch);
                }
            }
            // Trim trailing spaces
            while line_text.ends_with(' ') {
                line_text.pop();
            }
            result.push_str(&line_text);
            result.push('\n');
        }
        result
    }

    /// Reset performance metrics
    fn reset_metrics(&self) {
        self.metrics.poll_count.store(0, Ordering::Relaxed);
        self.metrics.poll_time_us.store(0, Ordering::Relaxed);
        self.metrics.grid_snapshot_count.store(0, Ordering::Relaxed);
        self.metrics.grid_snapshot_time_us.store(0, Ordering::Relaxed);
        self.metrics.vte_process_time_us.store(0, Ordering::Relaxed);
        self.metrics.max_poll_time_us.store(0, Ordering::Relaxed);
        self.metrics.max_grid_snapshot_time_us.store(0, Ordering::Relaxed);
        self.metrics.bytes_batched.store(0, Ordering::Relaxed);
        self.metrics.batch_count.store(0, Ordering::Relaxed);
        self.metrics.idle_polls.store(0, Ordering::Relaxed);
        self.dirty_rows.clear();
        info!("[terminal-{}] Performance metrics reset", self.id);
    }

    /// Get dirty rows for partial updates (returns row indices that need redrawing)
    fn get_dirty_rows(&self) -> Vec<usize> {
        self.dirty_rows.get_dirty_rows()
    }

    /// Clear dirty row tracking after sync
    fn clear_dirty_rows(&self) {
        self.dirty_rows.clear();
    }

    /// Get the current activity level (0-100)
    fn activity_level(&self) -> u8 {
        self.adaptive_poller.activity_percent()
    }

    /// Check if poll should be skipped (power saving when very idle)
    fn should_skip_poll(&self) -> bool {
        self.adaptive_poller.should_skip_poll()
    }
}

impl Drop for Chau7Terminal {
    fn drop(&mut self) {
        let (sent, received, uptime) = self.stats();
        info!("[terminal-{}] Destroying terminal (uptime: {:?}, sent: {} bytes, received: {} bytes)",
              self.id, uptime, sent, received);

        // Signal the reader thread to stop
        self.running.store(false, Ordering::SeqCst);
        debug!("[terminal-{}] Signaled reader thread to stop", self.id);

        // Kill the child process to unblock the reader thread
        if let Some(mut child) = self.child.lock().take() {
            debug!("[terminal-{}] Killing child process", self.id);
            if let Err(e) = child.kill() {
                // It's okay if the child already exited
                debug!("[terminal-{}] Child kill returned: {}", self.id, e);
            }
            // Wait for child to avoid zombie
            match child.wait() {
                Ok(status) => {
                    info!("[terminal-{}] Child process exited with status: {:?}", self.id, status);
                }
                Err(e) => {
                    warn!("[terminal-{}] Failed to wait for child: {}", self.id, e);
                }
            }
        }

        // Wait for reader thread to finish with timeout
        if let Some(handle) = self.reader_thread.take() {
            debug!("[terminal-{}] Waiting for reader thread to finish...", self.id);

            // Use a reasonable timeout
            let start = Instant::now();
            let timeout = Duration::from_secs(2);

            // We can't easily timeout a thread::join, so we rely on killing the child
            // to unblock the reader. The reader should exit quickly after that.
            match handle.join() {
                Ok(()) => {
                    debug!("[terminal-{}] Reader thread joined in {:?}", self.id, start.elapsed());
                }
                Err(e) => {
                    error!("[terminal-{}] Reader thread panicked: {:?}", self.id, e);
                }
            }

            if start.elapsed() > timeout {
                warn!("[terminal-{}] Reader thread took {:?} to join (expected < {:?})",
                      self.id, start.elapsed(), timeout);
            }
        }

        info!("[terminal-{}] Terminal destroyed", self.id);
    }
}

// ============================================================================
// FFI Functions
// ============================================================================

/// Initialize logging (call once at startup)
fn init_logging() {
    use std::sync::Once;
    static INIT: Once = Once::new();
    INIT.call_once(|| {
        // Try to initialize env_logger
        // Set RUST_LOG=trace for maximum verbosity
        if let Err(e) = env_logger::try_init() {
            eprintln!("chau7_terminal: Failed to initialize logger: {}", e);
        } else {
            info!("chau7_terminal: Logging initialized (set RUST_LOG=trace for verbose output)");
        }
    });
}

/// Create a new terminal with the specified dimensions and shell
///
/// # Safety
/// - `shell` must be a valid null-terminated C string, or null for default shell
/// - Returns null on failure
#[no_mangle]
pub unsafe extern "C" fn chau7_terminal_create(
    cols: u16,
    rows: u16,
    shell: *const c_char,
) -> *mut Chau7Terminal {
    init_logging();

    info!("chau7_terminal_create(cols={}, rows={}, shell={:?})", cols, rows, shell);

    let shell_str = if shell.is_null() {
        debug!("chau7_terminal_create: shell is null, will use default");
        ""
    } else {
        match CStr::from_ptr(shell).to_str() {
            Ok(s) => {
                debug!("chau7_terminal_create: shell string = {:?}", s);
                s
            }
            Err(e) => {
                error!("chau7_terminal_create: Invalid shell string (not UTF-8): {}", e);
                return std::ptr::null_mut();
            }
        }
    };

    match Chau7Terminal::new(cols, rows, shell_str) {
        Ok(terminal) => {
            let ptr = Box::into_raw(Box::new(terminal));
            info!("chau7_terminal_create: Success, returning {:p}", ptr);
            ptr
        }
        Err(e) => {
            error!("chau7_terminal_create: Failed: {}", e);
            std::ptr::null_mut()
        }
    }
}

/// Create a new terminal with environment variables
///
/// # Safety
/// - `shell` must be a valid null-terminated C string, or null for default shell
/// - `env_keys` and `env_values` must be arrays of valid null-terminated C strings
/// - `env_count` must be the length of both arrays
/// - Returns null on failure
#[no_mangle]
pub unsafe extern "C" fn chau7_terminal_create_with_env(
    cols: u16,
    rows: u16,
    shell: *const c_char,
    env_keys: *const *const c_char,
    env_values: *const *const c_char,
    env_count: usize,
) -> *mut Chau7Terminal {
    init_logging();

    info!("chau7_terminal_create_with_env(cols={}, rows={}, env_count={})", cols, rows, env_count);

    let shell_str = if shell.is_null() {
        ""
    } else {
        match CStr::from_ptr(shell).to_str() {
            Ok(s) => s,
            Err(e) => {
                error!("chau7_terminal_create_with_env: Invalid shell string: {}", e);
                return std::ptr::null_mut();
            }
        }
    };

    // Parse environment variables
    let mut env_vars: Vec<(String, String)> = Vec::with_capacity(env_count);
    if env_count > 0 && !env_keys.is_null() && !env_values.is_null() {
        for i in 0..env_count {
            let key_ptr = *env_keys.add(i);
            let value_ptr = *env_values.add(i);

            if key_ptr.is_null() || value_ptr.is_null() {
                warn!("chau7_terminal_create_with_env: Null env pointer at index {}", i);
                continue;
            }

            let key = match CStr::from_ptr(key_ptr).to_str() {
                Ok(s) => s.to_string(),
                Err(_) => continue,
            };
            let value = match CStr::from_ptr(value_ptr).to_str() {
                Ok(s) => s.to_string(),
                Err(_) => continue,
            };

            debug!("chau7_terminal_create_with_env: env[{}] = {}={}", i, key, value);
            env_vars.push((key, value));
        }
    }

    // Convert to &[(&str, &str)] for new_with_env
    let env_refs: Vec<(&str, &str)> = env_vars.iter().map(|(k, v)| (k.as_str(), v.as_str())).collect();

    match Chau7Terminal::new_with_env(cols, rows, shell_str, &env_refs) {
        Ok(terminal) => {
            let ptr = Box::into_raw(Box::new(terminal));
            info!("chau7_terminal_create_with_env: Success, returning {:p}", ptr);
            ptr
        }
        Err(e) => {
            error!("chau7_terminal_create_with_env: Failed: {}", e);
            std::ptr::null_mut()
        }
    }
}

/// Destroy a terminal instance
///
/// # Safety
/// - `term` must be a valid pointer returned by `chau7_terminal_create`
/// - The pointer must not be used after this call
#[no_mangle]
pub unsafe extern "C" fn chau7_terminal_destroy(term: *mut Chau7Terminal) {
    info!("chau7_terminal_destroy({:p})", term);
    if term.is_null() {
        warn!("chau7_terminal_destroy: Received null pointer, ignoring");
        return;
    }
    drop(Box::from_raw(term));
    debug!("chau7_terminal_destroy: Complete");
}

/// Send raw bytes to the PTY (user input)
///
/// # Safety
/// - `term` must be a valid pointer
/// - `data` must be a valid pointer to at least `len` bytes
#[no_mangle]
pub unsafe extern "C" fn chau7_terminal_send_bytes(
    term: *mut Chau7Terminal,
    data: *const u8,
    len: usize,
) {
    trace!("chau7_terminal_send_bytes({:p}, {:p}, {})", term, data, len);
    if term.is_null() {
        warn!("chau7_terminal_send_bytes: term is null");
        return;
    }
    if data.is_null() {
        warn!("chau7_terminal_send_bytes: data is null");
        return;
    }
    if len == 0 {
        trace!("chau7_terminal_send_bytes: len is 0, nothing to send");
        return;
    }
    let terminal = &*term;
    let bytes = std::slice::from_raw_parts(data, len);
    terminal.send_bytes(bytes);
}

/// Send a null-terminated string to the PTY
///
/// # Safety
/// - `term` must be a valid pointer
/// - `text` must be a valid null-terminated C string
#[no_mangle]
pub unsafe extern "C" fn chau7_terminal_send_text(term: *mut Chau7Terminal, text: *const c_char) {
    trace!("chau7_terminal_send_text({:p}, {:p})", term, text);
    if term.is_null() {
        warn!("chau7_terminal_send_text: term is null");
        return;
    }
    if text.is_null() {
        warn!("chau7_terminal_send_text: text is null");
        return;
    }
    let terminal = &*term;
    let cstr = CStr::from_ptr(text);
    let bytes = cstr.to_bytes();
    debug!("chau7_terminal_send_text: sending {} bytes", bytes.len());
    terminal.send_bytes(bytes);
}

/// Resize the terminal
///
/// # Safety
/// - `term` must be a valid pointer
#[no_mangle]
pub unsafe extern "C" fn chau7_terminal_resize(term: *mut Chau7Terminal, cols: u16, rows: u16) {
    info!("chau7_terminal_resize({:p}, {}, {})", term, cols, rows);
    if term.is_null() {
        warn!("chau7_terminal_resize: term is null");
        return;
    }
    let terminal = &mut *term;
    terminal.resize(cols, rows);
}

/// Get a snapshot of the current grid state
///
/// # Safety
/// - `term` must be a valid pointer
/// - Returns null on failure
/// - The returned GridSnapshot must be freed with `chau7_terminal_free_grid`
#[no_mangle]
pub unsafe extern "C" fn chau7_terminal_get_grid(term: *mut Chau7Terminal) -> *mut GridSnapshot {
    trace!("chau7_terminal_get_grid({:p})", term);
    if term.is_null() {
        warn!("chau7_terminal_get_grid: term is null");
        return std::ptr::null_mut();
    }
    let terminal = &*term;
    let snapshot = terminal.get_grid_snapshot();
    let ptr = Box::into_raw(Box::new(snapshot));
    trace!("chau7_terminal_get_grid: returning {:p}", ptr);
    ptr
}

/// Free a grid snapshot
///
/// # Safety
/// - `grid` must be a valid pointer returned by `chau7_terminal_get_grid`
/// - The pointer must not be used after this call
#[no_mangle]
pub unsafe extern "C" fn chau7_terminal_free_grid(grid: *mut GridSnapshot) {
    trace!("chau7_terminal_free_grid({:p})", grid);
    if grid.is_null() {
        warn!("chau7_terminal_free_grid: grid is null");
        return;
    }
    let snapshot = Box::from_raw(grid);

    // Return the cells buffer to the pool for reuse instead of deallocating
    if !snapshot.cells.is_null() {
        let total_cells = (snapshot.cols as usize) * (snapshot.rows as usize);
        let capacity = snapshot.capacity;
        trace!("chau7_terminal_free_grid: returning cells to pool (len={}, cap={})", total_cells, capacity);
        // Reconstruct the Vec with the original capacity
        let buffer = Vec::from_raw_parts(snapshot.cells, total_cells, capacity);
        // Return to pool for reuse
        get_cell_buffer_pool().release(buffer);
    }
    trace!("chau7_terminal_free_grid: complete");
}

/// Get cell buffer pool statistics for debugging/monitoring
/// Returns: (acquired, returned, allocated, pooled)
/// - acquired: total buffers acquired from pool
/// - returned: total buffers returned to pool
/// - allocated: new allocations (pool misses)
/// - pooled: current buffers in pool
#[no_mangle]
pub extern "C" fn chau7_terminal_pool_stats() -> PoolStats {
    let (acquired, returned, allocated, pooled) = get_cell_buffer_pool().stats();
    PoolStats {
        acquired,
        returned,
        allocated,
        pooled: pooled as u64,
    }
}

/// Pool statistics returned by chau7_terminal_pool_stats
#[repr(C)]
pub struct PoolStats {
    pub acquired: u64,
    pub returned: u64,
    pub allocated: u64,
    pub pooled: u64,
}

/// Get current scroll position (0.0 = bottom, 1.0 = top of history)
///
/// # Safety
/// - `term` must be a valid pointer
#[no_mangle]
pub unsafe extern "C" fn chau7_terminal_scroll_position(term: *mut Chau7Terminal) -> f64 {
    trace!("chau7_terminal_scroll_position({:p})", term);
    if term.is_null() {
        warn!("chau7_terminal_scroll_position: term is null");
        return 0.0;
    }
    let terminal = &*term;
    terminal.scroll_position()
}

/// Scroll to a normalized position (0.0 = bottom, 1.0 = top of history)
///
/// # Safety
/// - `term` must be a valid pointer
#[no_mangle]
pub unsafe extern "C" fn chau7_terminal_scroll_to(term: *mut Chau7Terminal, position: f64) {
    debug!("chau7_terminal_scroll_to({:p}, {})", term, position);
    if term.is_null() {
        warn!("chau7_terminal_scroll_to: term is null");
        return;
    }
    let terminal = &*term;
    terminal.scroll_to(position);
}

/// Scroll by a number of lines (positive = up/back, negative = down/forward)
///
/// # Safety
/// - `term` must be a valid pointer
#[no_mangle]
pub unsafe extern "C" fn chau7_terminal_scroll_lines(term: *mut Chau7Terminal, lines: i32) {
    debug!("chau7_terminal_scroll_lines({:p}, {})", term, lines);
    if term.is_null() {
        warn!("chau7_terminal_scroll_lines: term is null");
        return;
    }
    let terminal = &*term;
    terminal.scroll_lines(lines);
}

/// Get currently selected text
///
/// # Safety
/// - `term` must be a valid pointer
/// - Returns null if no selection or on failure
/// - The returned string must be freed with `chau7_terminal_free_string`
#[no_mangle]
pub unsafe extern "C" fn chau7_terminal_selection_text(term: *mut Chau7Terminal) -> *mut c_char {
    trace!("chau7_terminal_selection_text({:p})", term);
    if term.is_null() {
        warn!("chau7_terminal_selection_text: term is null");
        return std::ptr::null_mut();
    }
    let terminal = &*term;
    match terminal.selection_text() {
        Some(text) => match CString::new(text) {
            Ok(cstr) => {
                let ptr = cstr.into_raw();
                trace!("chau7_terminal_selection_text: returning {:p}", ptr);
                ptr
            }
            Err(e) => {
                error!("chau7_terminal_selection_text: CString::new failed: {}", e);
                std::ptr::null_mut()
            }
        },
        None => {
            trace!("chau7_terminal_selection_text: no selection");
            std::ptr::null_mut()
        }
    }
}

/// Clear any active selection
///
/// # Safety
/// - `term` must be a valid pointer
#[no_mangle]
pub unsafe extern "C" fn chau7_terminal_selection_clear(term: *mut Chau7Terminal) {
    debug!("chau7_terminal_selection_clear({:p})", term);
    if term.is_null() {
        warn!("chau7_terminal_selection_clear: term is null");
        return;
    }
    let terminal = &*term;
    terminal.selection_clear();
}

/// Start a new selection at the given position
///
/// # Arguments
/// - `col`: Column position (0-indexed)
/// - `row`: Row position (can be negative for scrollback)
/// - `selection_type`: 0 = Simple (character), 1 = Block, 2 = Semantic (word), 3 = Lines
///
/// # Safety
/// - `term` must be a valid pointer
#[no_mangle]
pub unsafe extern "C" fn chau7_terminal_selection_start(
    term: *mut Chau7Terminal,
    col: i32,
    row: i32,
    selection_type: u8,
) {
    debug!("chau7_terminal_selection_start({:p}, col={}, row={}, type={})", term, col, row, selection_type);
    if term.is_null() {
        warn!("chau7_terminal_selection_start: term is null");
        return;
    }
    let terminal = &*term;
    terminal.selection_start(col, row, selection_type);
}

/// Update the current selection to extend to the given position
///
/// # Safety
/// - `term` must be a valid pointer
#[no_mangle]
pub unsafe extern "C" fn chau7_terminal_selection_update(
    term: *mut Chau7Terminal,
    col: i32,
    row: i32,
) {
    trace!("chau7_terminal_selection_update({:p}, col={}, row={})", term, col, row);
    if term.is_null() {
        warn!("chau7_terminal_selection_update: term is null");
        return;
    }
    let terminal = &*term;
    terminal.selection_update(col, row);
}

/// Select all content (screen + scrollback)
///
/// # Safety
/// - `term` must be a valid pointer
#[no_mangle]
pub unsafe extern "C" fn chau7_terminal_selection_all(term: *mut Chau7Terminal) {
    debug!("chau7_terminal_selection_all({:p})", term);
    if term.is_null() {
        warn!("chau7_terminal_selection_all: term is null");
        return;
    }
    let terminal = &*term;
    terminal.selection_all();
}

/// Free a string returned by the library
///
/// # Safety
/// - `s` must be a valid pointer returned by `chau7_terminal_selection_text` or similar
/// - The pointer must not be used after this call
#[no_mangle]
pub unsafe extern "C" fn chau7_terminal_free_string(s: *mut c_char) {
    trace!("chau7_terminal_free_string({:p})", s);
    if s.is_null() {
        warn!("chau7_terminal_free_string: s is null");
        return;
    }
    drop(CString::from_raw(s));
    trace!("chau7_terminal_free_string: complete");
}

/// Get the text of a specific line in the terminal grid.
///
/// The `row` index is in grid coordinates where 0 is the top of the visible
/// viewport. Negative rows refer to scrollback when available.
///
/// Returns a null-terminated UTF-8 string. The caller must free it with
/// `chau7_terminal_free_string`.
///
/// # Safety
/// - `term` must be a valid pointer
#[no_mangle]
pub unsafe extern "C" fn chau7_terminal_get_line_text(
    term: *mut Chau7Terminal,
    row: i32,
) -> *mut c_char {
    trace!("chau7_terminal_get_line_text({:p}, row={})", term, row);
    if term.is_null() {
        warn!("chau7_terminal_get_line_text: term is null");
        return std::ptr::null_mut();
    }
    let terminal = &*term;
    match terminal.line_text(row) {
        Some(text) => match CString::new(text) {
            Ok(cstr) => cstr.into_raw(),
            Err(_) => {
                warn!("chau7_terminal_get_line_text: text contained null byte");
                std::ptr::null_mut()
            }
        },
        None => std::ptr::null_mut(),
    }
}

/// Get cursor position
///
/// # Safety
/// - `term` must be a valid pointer
/// - `col` and `row` must be valid pointers to u16, or null
#[no_mangle]
pub unsafe extern "C" fn chau7_terminal_cursor_position(
    term: *mut Chau7Terminal,
    col: *mut u16,
    row: *mut u16,
) {
    trace!("chau7_terminal_cursor_position({:p}, {:p}, {:p})", term, col, row);
    if term.is_null() {
        warn!("chau7_terminal_cursor_position: term is null");
        return;
    }
    let terminal = &*term;
    let (c, r) = terminal.cursor_position();
    if !col.is_null() {
        *col = c;
    }
    if !row.is_null() {
        *row = r;
    }
}

/// Poll for new data from PTY and process it
///
/// Returns true if the grid has changed and needs to be redrawn
///
/// # Safety
/// - `term` must be a valid pointer
#[no_mangle]
pub unsafe extern "C" fn chau7_terminal_poll(term: *mut Chau7Terminal, timeout_ms: u32) -> bool {
    trace!("chau7_terminal_poll({:p}, {})", term, timeout_ms);
    if term.is_null() {
        warn!("chau7_terminal_poll: term is null");
        return false;
    }
    let terminal = &*term;
    terminal.poll(timeout_ms)
}

/// Get raw output bytes from the last poll.
/// Returns a pointer to the byte data and the length.
/// Each call returns a new allocation that must be freed via chau7_terminal_free_output.
///
/// # Safety
/// - `term` must be a valid pointer
/// - `out_len` must be a valid pointer to a usize
/// - The returned pointer must be freed via chau7_terminal_free_output
/// - Returns null if no output is available
#[no_mangle]
pub unsafe extern "C" fn chau7_terminal_get_last_output(
    term: *mut Chau7Terminal,
    out_len: *mut usize,
) -> *mut u8 {
    trace!("chau7_terminal_get_last_output({:p}, {:p})", term, out_len);
    if term.is_null() {
        warn!("chau7_terminal_get_last_output: term is null");
        if !out_len.is_null() {
            *out_len = 0;
        }
        return std::ptr::null_mut();
    }
    if out_len.is_null() {
        warn!("chau7_terminal_get_last_output: out_len is null");
        return std::ptr::null_mut();
    }

    let terminal = &*term;
    let output = terminal.get_last_output();
    let len = output.len();

    if len == 0 {
        *out_len = 0;
        return std::ptr::null_mut();
    }

    // Convert Vec to boxed slice and leak it for the caller to free
    // into_boxed_slice() shrinks capacity to exact length, so len == capacity
    let mut boxed = output.into_boxed_slice();
    let ptr = boxed.as_mut_ptr();
    std::mem::forget(boxed);

    *out_len = len;
    trace!("chau7_terminal_get_last_output: returning {} bytes at {:p}", len, ptr);
    ptr
}

/// Inject output bytes directly into the terminal (without sending to PTY).
/// This is used for UI-only content like the power user tip header.
///
/// # Safety
/// - `term` must be a valid pointer returned by `chau7_terminal_create`
/// - `data` must be a valid pointer to at least `len` bytes (unless `len` is 0)
#[no_mangle]
pub unsafe extern "C" fn chau7_terminal_inject_output(
    term: *mut Chau7Terminal,
    data: *const u8,
    len: usize,
) {
    trace!("chau7_terminal_inject_output({:p}, {:p}, {})", term, data, len);
    if term.is_null() {
        warn!("chau7_terminal_inject_output: term is null");
        return;
    }
    if data.is_null() {
        if len == 0 {
            return;
        }
        warn!("chau7_terminal_inject_output: data is null with len > 0");
        return;
    }

    let slice = std::slice::from_raw_parts(data, len);
    let terminal = &*term;
    terminal.inject_output(slice);
}

/// Free output bytes returned by chau7_terminal_get_last_output
///
/// # Safety
/// - `data` must be a pointer returned by `chau7_terminal_get_last_output`
/// - `len` must be the length returned with that pointer
/// - The pointer must not be used after this call
#[no_mangle]
pub unsafe extern "C" fn chau7_terminal_free_output(data: *mut u8, len: usize) {
    trace!("chau7_terminal_free_output({:p}, {})", data, len);
    if data.is_null() || len == 0 {
        return;
    }
    // Reconstruct the boxed slice and drop it
    // into_boxed_slice() guarantees len == capacity, so this is safe
    let slice = std::slice::from_raw_parts_mut(data, len);
    drop(Box::from_raw(slice));
    trace!("chau7_terminal_free_output: complete");
}

/// Set theme colors for rendering
///
/// # Safety
/// - `term` must be a valid pointer
/// - `palette` must be a valid pointer to an array of 48 bytes (16 RGB triplets)
#[no_mangle]
pub unsafe extern "C" fn chau7_terminal_set_colors(
    term: *mut Chau7Terminal,
    fg_r: u8,
    fg_g: u8,
    fg_b: u8,
    bg_r: u8,
    bg_g: u8,
    bg_b: u8,
    cursor_r: u8,
    cursor_g: u8,
    cursor_b: u8,
    palette: *const u8,
) {
    debug!(
        "chau7_terminal_set_colors({:p}, fg=({},{},{}), bg=({},{},{}), cursor=({},{},{}))",
        term, fg_r, fg_g, fg_b, bg_r, bg_g, bg_b, cursor_r, cursor_g, cursor_b
    );
    if term.is_null() {
        warn!("chau7_terminal_set_colors: term is null");
        return;
    }
    if palette.is_null() {
        warn!("chau7_terminal_set_colors: palette is null");
        return;
    }

    let terminal = &*term;

    // Read the 16-color palette (48 bytes = 16 colors * 3 components)
    let palette_slice = std::slice::from_raw_parts(palette, 48);
    let mut palette_colors: [(u8, u8, u8); 16] = [(0, 0, 0); 16];
    for i in 0..16 {
        palette_colors[i] = (
            palette_slice[i * 3],
            palette_slice[i * 3 + 1],
            palette_slice[i * 3 + 2],
        );
    }

    terminal.set_colors(
        (fg_r, fg_g, fg_b),
        (bg_r, bg_g, bg_b),
        (cursor_r, cursor_g, cursor_b),
        palette_colors,
    );
}

/// Clear the scrollback history buffer
///
/// This removes all lines from the scrollback buffer, freeing memory.
/// The visible screen content is preserved.
///
/// # Safety
/// - `term` must be a valid pointer
#[no_mangle]
pub unsafe extern "C" fn chau7_terminal_clear_scrollback(term: *mut Chau7Terminal) {
    info!("chau7_terminal_clear_scrollback({:p})", term);
    if term.is_null() {
        warn!("chau7_terminal_clear_scrollback: term is null");
        return;
    }
    let terminal = &*term;
    terminal.clear_scrollback();
}

/// Set the scrollback buffer size (number of lines)
///
/// This updates the maximum number of lines that can be stored in the scrollback buffer.
/// If the new size is smaller than the current history, older lines will be discarded.
///
/// # Safety
/// - `term` must be a valid pointer
#[no_mangle]
pub unsafe extern "C" fn chau7_terminal_set_scrollback_size(term: *mut Chau7Terminal, lines: u32) {
    info!("chau7_terminal_set_scrollback_size({:p}, {})", term, lines);
    if term.is_null() {
        warn!("chau7_terminal_set_scrollback_size: term is null");
        return;
    }
    let terminal = &*term;
    terminal.set_scrollback_size(lines as usize);
}

/// Get the current display offset (scroll position in lines)
///
/// Returns:
/// - 0 if at the bottom (showing current output)
/// - >0 if scrolled up (viewing history)
///
/// This is useful for implementing smart scroll behavior: only auto-scroll
/// to bottom if display_offset is 0.
///
/// # Safety
/// - `term` must be a valid pointer
#[no_mangle]
pub unsafe extern "C" fn chau7_terminal_display_offset(term: *mut Chau7Terminal) -> u32 {
    trace!("chau7_terminal_display_offset({:p})", term);
    if term.is_null() {
        warn!("chau7_terminal_display_offset: term is null");
        return 0;
    }
    let terminal = &*term;
    terminal.display_offset() as u32
}

/// Get the current mouse mode as a bitfield.
///
/// Returns a u32 with the following bits:
/// - Bit 0 (0x01): MOUSE_REPORT_CLICK - Mouse mode 1000 (report button press/release)
/// - Bit 1 (0x02): MOUSE_DRAG - Mouse mode 1002 (also report motion while button down)
/// - Bit 2 (0x04): MOUSE_MOTION - Mouse mode 1003 (report all motion)
/// - Bit 3 (0x08): FOCUS_IN_OUT - Focus in/out reporting (mode 1004)
/// - Bit 4 (0x10): SGR_MOUSE - Mouse mode 1006 (use SGR encoding for coordinates >223)
///
/// To check if any mouse reporting is active, check if (result & 0x07) != 0.
/// To check if SGR mode should be used, check if (result & 0x10) != 0.
///
/// # Safety
/// - `term` must be a valid pointer
#[no_mangle]
pub unsafe extern "C" fn chau7_terminal_mouse_mode(term: *mut Chau7Terminal) -> u32 {
    trace!("chau7_terminal_mouse_mode({:p})", term);
    if term.is_null() {
        warn!("chau7_terminal_mouse_mode: term is null");
        return 0;
    }
    let terminal = &*term;
    terminal.mouse_mode()
}

/// Check if bracketed paste mode is enabled
///
/// Returns true if the terminal has bracketed paste mode enabled.
/// This is typically set by programs like vim, zsh, or any readline-based
/// application via the escape sequence ESC[?2004h.
///
/// When enabled, pasted text should be wrapped with ESC[200~ and ESC[201~
/// to distinguish it from typed input.
///
/// # Safety
/// - `term` must be a valid pointer
#[no_mangle]
pub unsafe extern "C" fn chau7_terminal_is_bracketed_paste_mode(term: *mut Chau7Terminal) -> bool {
    trace!("chau7_terminal_is_bracketed_paste_mode({:p})", term);
    if term.is_null() {
        warn!("chau7_terminal_is_bracketed_paste_mode: term is null");
        return false;
    }
    let terminal = &*term;
    terminal.is_bracketed_paste_mode()
}

/// Check if application cursor mode (DECCKM) is enabled
///
/// Returns true if the terminal has application cursor mode enabled.
/// This is typically set by programs like vim, less, tmux via the escape
/// sequence ESC[?1h (DECCKM - DEC Cursor Key Mode).
///
/// When enabled, arrow keys should send SS3 sequences (ESC O A/B/C/D)
/// instead of CSI sequences (ESC [ A/B/C/D).
///
/// # Safety
/// - `term` must be a valid pointer
#[no_mangle]
pub unsafe extern "C" fn chau7_terminal_is_application_cursor_mode(term: *mut Chau7Terminal) -> bool {
    trace!("chau7_terminal_is_application_cursor_mode({:p})", term);
    if term.is_null() {
        warn!("chau7_terminal_is_application_cursor_mode: term is null");
        return false;
    }
    let terminal = &*term;
    terminal.is_application_cursor_mode()
}

/// Check if a bell event has occurred since the last check
///
/// Returns true if a bell (BEL, 0x07) was received by the terminal since
/// the last call to this function. The flag is automatically cleared.
///
/// This allows Swift to poll for bell events and trigger audio/visual feedback.
///
/// # Safety
/// - `term` must be a valid pointer
#[no_mangle]
pub unsafe extern "C" fn chau7_terminal_check_bell(term: *mut Chau7Terminal) -> bool {
    trace!("chau7_terminal_check_bell({:p})", term);
    if term.is_null() {
        warn!("chau7_terminal_check_bell: term is null");
        return false;
    }
    let terminal = &*term;
    terminal.check_bell()
}

/// Get the current mouse mode as a bitmask
///
/// Returns a u32 representing which mouse modes are active:
/// - Bit 0 (1): MOUSE_REPORT_CLICK - Basic mouse click reporting (mode 1000)
/// - Bit 1 (2): MOUSE_DRAG - Mouse drag reporting (mode 1002)
/// - Bit 2 (4): MOUSE_MOTION - All mouse motion reporting (mode 1003)
/// - Bit 3 (8): FOCUS_IN_OUT - Focus in/out reporting (mode 1004)
/// - Bit 4 (16): SGR_MOUSE - SGR extended coordinates (mode 1006)
///
/// Returns 0 if no mouse modes are active or if term is null.
///
/// # Safety
/// - `term` must be a valid pointer
#[no_mangle]
pub unsafe extern "C" fn chau7_terminal_get_mouse_mode(term: *mut Chau7Terminal) -> u32 {
    trace!("chau7_terminal_get_mouse_mode({:p})", term);
    if term.is_null() {
        warn!("chau7_terminal_get_mouse_mode: term is null");
        return 0;
    }
    let terminal = &*term;
    terminal.mouse_mode()
}

/// Check if any mouse tracking mode is active (click, drag, or motion reporting)
///
/// This is a convenience function that returns true if any of the mouse
/// tracking modes (MOUSE_REPORT_CLICK, MOUSE_DRAG, or MOUSE_MOTION) are enabled.
/// These modes indicate that mouse events should be reported to the running
/// application (e.g., vim, tmux, htop) rather than handled by the terminal.
///
/// # Safety
/// - `term` must be a valid pointer
#[no_mangle]
pub unsafe extern "C" fn chau7_terminal_is_mouse_reporting_active(term: *mut Chau7Terminal) -> bool {
    trace!("chau7_terminal_is_mouse_reporting_active({:p})", term);
    if term.is_null() {
        warn!("chau7_terminal_is_mouse_reporting_active: term is null");
        return false;
    }
    let terminal = &*term;
    terminal.is_mouse_reporting_active()
}

// ============================================================================
// Debug and Performance FFI Functions
// ============================================================================

/// Get the shell process ID
///
/// Returns the PID of the shell process running in this terminal.
/// This is useful for dev server monitoring which needs to find child processes.
/// Returns 0 if the terminal is invalid or PID is not available.
///
/// # Safety
/// - `term` must be a valid pointer
#[no_mangle]
pub unsafe extern "C" fn chau7_terminal_get_shell_pid(term: *mut Chau7Terminal) -> u64 {
    trace!("chau7_terminal_get_shell_pid({:p})", term);
    if term.is_null() {
        warn!("chau7_terminal_get_shell_pid: term is null");
        return 0;
    }
    let terminal = &*term;
    let pid = terminal.shell_pid();
    debug!("chau7_terminal_get_shell_pid: returning {}", pid);
    pid
}

/// Get a comprehensive debug state snapshot
///
/// Returns a pointer to a DebugState struct containing terminal state and metrics.
/// The caller must free this with `chau7_terminal_free_debug_state`.
///
/// # Safety
/// - `term` must be a valid pointer
/// - The returned pointer must be freed with `chau7_terminal_free_debug_state`
#[no_mangle]
pub unsafe extern "C" fn chau7_terminal_get_debug_state(term: *mut Chau7Terminal) -> *mut DebugState {
    info!("chau7_terminal_get_debug_state({:p})", term);
    if term.is_null() {
        warn!("chau7_terminal_get_debug_state: term is null");
        return std::ptr::null_mut();
    }
    let terminal = &*term;
    let state = terminal.debug_state();
    let ptr = Box::into_raw(Box::new(state));
    debug!("chau7_terminal_get_debug_state: returning {:p}", ptr);
    ptr
}

/// Free a debug state returned by `chau7_terminal_get_debug_state`
///
/// # Safety
/// - `state` must be a valid pointer returned by `chau7_terminal_get_debug_state`
/// - The pointer must not be used after this call
#[no_mangle]
pub unsafe extern "C" fn chau7_terminal_free_debug_state(state: *mut DebugState) {
    trace!("chau7_terminal_free_debug_state({:p})", state);
    if state.is_null() {
        return;
    }
    drop(Box::from_raw(state));
}

/// Get the full buffer text (visible + scrollback) for debugging
///
/// Returns a null-terminated string containing the entire terminal buffer.
/// The caller must free this with `chau7_terminal_free_string`.
///
/// # Safety
/// - `term` must be a valid pointer
/// - The returned pointer must be freed with `chau7_terminal_free_string`
#[no_mangle]
pub unsafe extern "C" fn chau7_terminal_get_full_buffer_text(term: *mut Chau7Terminal) -> *mut c_char {
    info!("chau7_terminal_get_full_buffer_text({:p})", term);
    if term.is_null() {
        warn!("chau7_terminal_get_full_buffer_text: term is null");
        return std::ptr::null_mut();
    }
    let terminal = &*term;
    let text = terminal.full_buffer_text();
    match CString::new(text) {
        Ok(cstr) => cstr.into_raw(),
        Err(e) => {
            error!("chau7_terminal_get_full_buffer_text: CString::new failed: {}", e);
            std::ptr::null_mut()
        }
    }
}

/// Reset performance metrics
///
/// Clears all performance counters (poll count, timing, etc.)
///
/// # Safety
/// - `term` must be a valid pointer
#[no_mangle]
pub unsafe extern "C" fn chau7_terminal_reset_metrics(term: *mut Chau7Terminal) {
    info!("chau7_terminal_reset_metrics({:p})", term);
    if term.is_null() {
        warn!("chau7_terminal_reset_metrics: term is null");
        return;
    }
    let terminal = &*term;
    terminal.reset_metrics();
}

/// Get current activity level (0-100)
///
/// Returns the terminal's current activity level as a percentage.
/// 100 = very active (lots of output), 0 = completely idle
///
/// # Safety
/// - `term` must be a valid pointer
#[no_mangle]
pub unsafe extern "C" fn chau7_terminal_activity_level(term: *mut Chau7Terminal) -> u8 {
    if term.is_null() {
        return 0;
    }
    let terminal = &*term;
    terminal.activity_level()
}

/// Check if poll should be skipped (power saving)
///
/// Returns true if the terminal has been idle long enough that the next
/// poll cycle can be skipped to save power. Use this for adaptive polling.
///
/// # Safety
/// - `term` must be a valid pointer
#[no_mangle]
pub unsafe extern "C" fn chau7_terminal_should_skip_poll(term: *mut Chau7Terminal) -> bool {
    if term.is_null() {
        return false;
    }
    let terminal = &*term;
    terminal.should_skip_poll()
}

/// Get count of dirty rows (for partial update optimization)
///
/// Returns the number of rows that have changed since the last clear.
/// Use this to determine if a partial or full update is needed.
///
/// # Safety
/// - `term` must be a valid pointer
#[no_mangle]
pub unsafe extern "C" fn chau7_terminal_dirty_row_count(term: *mut Chau7Terminal) -> u32 {
    if term.is_null() {
        return 0;
    }
    let terminal = &*term;
    terminal.dirty_rows.dirty_count() as u32
}

/// Clear dirty row tracking
///
/// Call this after syncing the grid to Swift to reset the dirty state.
///
/// # Safety
/// - `term` must be a valid pointer
#[no_mangle]
pub unsafe extern "C" fn chau7_terminal_clear_dirty_rows(term: *mut Chau7Terminal) {
    if term.is_null() {
        return;
    }
    let terminal = &*term;
    terminal.clear_dirty_rows();
}

// ============================================================================
// Terminal Event FFI Functions
// ============================================================================

/// Get pending title change from OSC 0/1/2 escape sequences
///
/// Returns the pending title as a C string, or null if no title change pending.
/// The caller must free this string with `chau7_terminal_free_string`.
/// After this call, the pending title is cleared.
///
/// # Safety
/// - `term` must be a valid pointer
/// - The returned string must be freed with `chau7_terminal_free_string`
#[no_mangle]
pub unsafe extern "C" fn chau7_terminal_get_pending_title(term: *mut Chau7Terminal) -> *mut c_char {
    trace!("chau7_terminal_get_pending_title({:p})", term);
    if term.is_null() {
        warn!("chau7_terminal_get_pending_title: term is null");
        return std::ptr::null_mut();
    }
    let terminal = &*term;
    let mut pending = terminal.pending_title.lock();
    match pending.take() {
        Some(title) => {
            debug!("chau7_terminal_get_pending_title: returning title {:?}", title);
            match CString::new(title) {
                Ok(cstr) => cstr.into_raw(),
                Err(_) => std::ptr::null_mut(),
            }
        }
        None => std::ptr::null_mut(),
    }
}

/// Get pending child exit code
///
/// Returns the exit code if the child process has exited, or -1 if still running.
/// After this call, the pending exit code is cleared.
/// Note: Exit code is only set when alacritty_terminal fires the ChildExit event.
///
/// # Safety
/// - `term` must be a valid pointer
#[no_mangle]
pub unsafe extern "C" fn chau7_terminal_get_pending_exit_code(term: *mut Chau7Terminal) -> i32 {
    trace!("chau7_terminal_get_pending_exit_code({:p})", term);
    if term.is_null() {
        warn!("chau7_terminal_get_pending_exit_code: term is null");
        return -1;
    }
    let terminal = &*term;
    let mut pending = terminal.pending_exit_code.lock();
    match pending.take() {
        Some(code) => {
            info!("chau7_terminal_get_pending_exit_code: returning exit code {}", code);
            code
        }
        None => -1,
    }
}

/// Check if the PTY has closed (Exit event received)
///
/// Returns true if the PTY has closed. This can happen when:
/// - The shell exits naturally (exit command)
/// - The shell process crashes
/// - The terminal connection is terminated
///
/// # Safety
/// - `term` must be a valid pointer
#[no_mangle]
pub unsafe extern "C" fn chau7_terminal_is_pty_closed(term: *mut Chau7Terminal) -> bool {
    trace!("chau7_terminal_is_pty_closed({:p})", term);
    if term.is_null() {
        warn!("chau7_terminal_is_pty_closed: term is null");
        return false;
    }
    let terminal = &*term;
    terminal.pty_closed.load(Ordering::SeqCst)
}

// ============================================================================
// Tests
// ============================================================================

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_ansi256_to_rgb() {
        // Test basic colors
        assert_eq!(ansi256_to_rgb(0), (0, 0, 0)); // Black
        assert_eq!(ansi256_to_rgb(15), (255, 255, 255)); // Bright white

        // Test grayscale
        assert_eq!(ansi256_to_rgb(232), (8, 8, 8)); // Darkest gray
        assert_eq!(ansi256_to_rgb(255), (238, 238, 238)); // Lightest gray
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

    #[test]
    fn test_cell_data_default() {
        let cell = CellData::default();
        assert_eq!(cell.character, ' ' as u32);
        assert_eq!(cell.fg_r, 255);
        assert_eq!(cell.bg_r, 0);
        assert_eq!(cell.flags, 0);
    }
}
