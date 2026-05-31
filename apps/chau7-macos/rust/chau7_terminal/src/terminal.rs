//! Core terminal emulator: Chau7Terminal struct, PTY management, and terminal operations.

use std::borrow::Cow;
use std::collections::{HashMap, VecDeque};
use std::io::Write;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicI32, AtomicU64, Ordering};
use std::time::{Duration, Instant};

use alacritty_terminal::event::Event;
use alacritty_terminal::grid::Dimensions;
use alacritty_terminal::index::{Column, Line, Point, Side};
use alacritty_terminal::selection::{Selection, SelectionType};
use alacritty_terminal::term::cell::{Cell, Flags as CellFlags, LineLength};
use alacritty_terminal::term::{Config as TermConfig, Term, TermMode};
use alacritty_terminal::vte::ansi::{Color as AnsiColor, NamedColor, Processor};
use crossbeam_channel::{Receiver, TryRecvError, bounded};
use log::{debug, error, info, trace, warn};
use parking_lot::{Mutex, RwLock};
use portable_pty::{CommandBuilder, PtySize, native_pty_system};
use unicode_normalization::UnicodeNormalization;

use crate::color::{ThemeColors, color_to_rgb_with_theme};
use crate::graphics;
use crate::metrics::{AdaptivePoller, DirtyRowTracker};
use crate::pool::get_cell_buffer_pool;
use crate::pty::{Chau7EventListener, PtyHandle, PtyMessage, SizeInfo};
use crate::types::{
    CELL_FLAG_BOLD, CELL_FLAG_DIM, CELL_FLAG_HIDDEN, CELL_FLAG_INVERSE, CELL_FLAG_ITALIC,
    CELL_FLAG_STRIKETHROUGH, CELL_FLAG_UNDERLINE, CellData, DebugState, GridSnapshot,
    PerformanceMetrics, cell_flags_to_u8, underline_style,
};

/// Static counter for terminal IDs (for logging)
static TERMINAL_COUNTER: AtomicU64 = AtomicU64::new(0);

/// Type alias for the clipboard load formatter function.
type ClipboardLoadFormatter = Arc<dyn Fn(&str) -> String + Sync + Send>;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct AnsiCellStyle {
    fg: (u8, u8, u8),
    bg: (u8, u8, u8),
    flags: u8,
}

/// Period of the post-advance grid invariant check. Set to 16 so the cost
/// is amortized across PTY chunks while still catching corruption near
/// the moment it happens. A power-of-two so `is_multiple_of` is a single
/// AND in release builds.
const INVARIANT_CHECK_PERIOD: u64 = 16;
const MALLOC_STACK_LOGGING_WARNING: &[u8] =
    b" MallocStackLogging: can't turn off malloc stack logging because it was not enabled.";

fn filter_terminal_output_noise<'a>(data: &'a [u8]) -> Cow<'a, [u8]> {
    if !data
        .windows(b"MallocStackLogging".len())
        .any(|window| window == b"MallocStackLogging")
    {
        return Cow::Borrowed(data);
    }

    let mut filtered = Vec::with_capacity(data.len());
    let mut line_start = 0usize;
    for (index, byte) in data.iter().enumerate() {
        if *byte != b'\n' {
            continue;
        }
        let line = &data[line_start..=index];
        if !is_suppressed_terminal_noise_line(line) {
            filtered.extend_from_slice(line);
        }
        line_start = index + 1;
    }

    if line_start < data.len() {
        let tail = &data[line_start..];
        if !is_suppressed_terminal_noise_line(tail) {
            filtered.extend_from_slice(tail);
        }
    }

    if filtered.len() == data.len() {
        Cow::Borrowed(data)
    } else {
        Cow::Owned(filtered)
    }
}

fn is_suppressed_terminal_noise_line(line: &[u8]) -> bool {
    let mut start = 0usize;
    while start < line.len() && matches!(line[start], b' ' | b'\t') {
        start += 1;
    }
    let mut end = line.len();
    while end > start && matches!(line[end - 1], b'\r' | b'\n' | b' ' | b'\t') {
        end -= 1;
    }
    let trimmed = &line[start..end];
    if !trimmed.starts_with(b"codex(") || !trimmed.ends_with(MALLOC_STACK_LOGGING_WARNING) {
        return false;
    }

    let process_end = trimmed.len() - MALLOC_STACK_LOGGING_WARNING.len();
    let pid_with_close_paren = &trimmed[b"codex(".len()..process_end];
    if let Some(pid) = pid_with_close_paren.strip_suffix(b")") {
        !pid.is_empty() && pid.iter().all(u8::is_ascii_digit)
    } else {
        false
    }
}

// ============================================================================
// Error types
// ============================================================================

#[derive(Debug, thiserror::Error)]
pub enum TerminalError {
    #[error("Invalid dimensions: {cols}x{rows}")]
    InvalidDimensions { cols: u16, rows: u16 },
    #[error("Failed to open PTY: {0}")]
    PtyOpen(#[source] Box<dyn std::error::Error + Send + Sync>),
    #[error("Failed to spawn shell '{shell}': {source}")]
    SpawnShell {
        shell: String,
        #[source]
        source: Box<dyn std::error::Error + Send + Sync>,
    },
    #[error("Failed to clone PTY reader: {0}")]
    PtyCloneReader(#[source] Box<dyn std::error::Error + Send + Sync>),
    #[error("Failed to get PTY writer: {0}")]
    PtyWriter(#[source] Box<dyn std::error::Error + Send + Sync>),
    #[error("Failed to spawn reader thread: {0}")]
    ReaderThread(#[source] std::io::Error),
    #[error("PTY resize failed: {0}")]
    PtyResize(String),
}

// ============================================================================
// Main terminal structure
// ============================================================================

/// The main terminal emulator structure.
///
/// # Lock Ordering
///
/// Acquire locks in ascending order to prevent deadlocks:
///
/// 1. `pty_handle`           (Mutex)  — PTY writer for input/resize
/// 2. `term`                 (Mutex)  — alacritty terminal state
/// 3. `processor`            (Mutex)  — VTE processor (always acquired with #2)
/// 4. `theme_colors`         (RwLock) — theme for rendering (read-heavy)
/// 5. `last_output`          (Mutex)  — raw output buffer
/// 6. `pending_title`        (Mutex)  — title change
/// 7. `pending_exit_code`    (Mutex)  — exit code
/// 8. `graphics_interceptor` (Mutex)  — image pre-filter
/// 9. `image_store`          (Mutex)  — decoded images
/// 10. `child`               (Mutex)  — child process (Drop only)
pub struct Chau7Terminal {
    /// Unique identifier for this terminal (for logging)
    pub(crate) id: u64,
    /// The alacritty terminal state machine
    pub(crate) term: Mutex<Term<Chau7EventListener>>,
    /// VTE processor for parsing escape sequences
    pub(crate) processor: Mutex<Processor>,
    /// PTY handle for writing input when backed by a live shell.
    pub(crate) pty_handle: Mutex<Option<PtyHandle>>,
    /// Duplicated master PTY fd used only for echo detection.
    ///
    /// Keep this separate from `pty_handle`: PTY writes can block under
    /// backpressure while holding that mutex, and echo detection runs from
    /// Swift input bookkeeping on the main thread.
    pub(crate) echo_fd: AtomicI32,
    /// Child process handle (to avoid zombies)
    pub(crate) child: Mutex<Option<Box<dyn portable_pty::Child + Send + Sync>>>,
    /// Shell process ID (for dev server monitoring)
    pub(crate) shell_pid: AtomicU64,
    /// Channel receiver for PTY output data when backed by a live shell.
    pub(crate) pty_rx: Option<Receiver<PtyMessage>>,
    /// Flag to signal the reader pool to stop monitoring this terminal
    pub(crate) running: Arc<AtomicBool>,
    /// Raw fd registered with the shared reader pool (for unregistration on drop)
    pub(crate) reader_pool_fd: Option<i32>,
    /// Event receiver for terminal events
    pub(crate) event_rx: Receiver<Event>,
    /// Flag indicating if grid has changed since last poll
    pub(crate) grid_dirty: AtomicBool,
    /// Terminal dimensions
    pub(crate) cols: u16,
    pub(crate) rows: u16,
    /// Creation timestamp for debugging
    pub(crate) created_at: Instant,
    /// Total bytes received from PTY
    pub(crate) bytes_received: AtomicU64,
    /// Total bytes sent to PTY
    pub(crate) bytes_sent: AtomicU64,
    /// Total PTY write errors
    pub(crate) write_errors: AtomicU64,
    /// Theme colors for rendering (RwLock for read-heavy access pattern)
    pub(crate) theme_colors: RwLock<ThemeColors>,
    /// Raw output bytes from the last poll (for Swift onOutput callback - Issue #3 fix)
    pub(crate) last_output: Mutex<Vec<u8>>,
    /// Flag indicating if a bell occurred since last check (shared with EventListener)
    pub(crate) bell_pending: Arc<AtomicBool>,
    /// Performance metrics for debugging
    pub(crate) metrics: PerformanceMetrics,
    /// Pending terminal title change (from OSC 0/1/2)
    pub(crate) pending_title: Mutex<Option<String>>,
    /// Fast check flag — avoids locking pending_title Mutex on every poll (99% empty).
    pub(crate) has_pending_title: AtomicBool,
    /// Pending current working directory (from OSC 7).
    /// Captured by `process_pty_data` so attribution is race-free w.r.t. the
    /// `last_output` drain (which is consumed by `std::mem::take` and is thus
    /// vulnerable to whichever Swift view polls first).
    pub(crate) pending_cwd: Mutex<Option<String>>,
    /// Fast check flag — avoids locking pending_cwd Mutex on every poll.
    pub(crate) has_pending_cwd: AtomicBool,
    /// Pending child exit code (from Event::ChildExit)
    pub(crate) pending_exit_code: Mutex<Option<i32>>,
    /// Flag indicating PTY has closed
    pub(crate) pty_closed: AtomicBool,

    // Hyperlink support (OSC 8)
    /// Map of link_id → URL for the most recent grid snapshot.
    /// Index 0 is unused (link_id 0 = no link). Rebuilt each grid snapshot.
    pub(crate) link_urls: Mutex<Vec<String>>,

    // Clipboard support (OSC 52)
    /// Pending clipboard store request from the terminal (OSC 52 write)
    pub(crate) pending_clipboard_store: Mutex<Option<String>>,
    /// Fast check flag — avoids locking pending_clipboard_store Mutex on every poll.
    pub(crate) has_pending_clipboard_store: AtomicBool,
    /// Pending clipboard load formatter — terminal wants us to read clipboard and
    /// send the response back via PTY. The Arc<dyn Fn> wraps the text in OSC 52 response.
    pub(crate) pending_clipboard_load: Mutex<Option<ClipboardLoadFormatter>>,
    /// Fast check flag — avoids locking pending_clipboard_load Mutex on every poll.
    pub(crate) has_pending_clipboard_load: AtomicBool,

    // Shell integration (OSC 133)
    /// Pending shell integration events (prompt start, command start/end, etc.)
    pub(crate) pending_shell_events: Mutex<Vec<graphics::ShellIntegrationEvent>>,
    /// Fast check flag — avoids locking on every poll.
    pub(crate) has_pending_shell_events: AtomicBool,

    // Performance optimization structures
    /// Adaptive polling rate controller
    pub(crate) adaptive_poller: AdaptivePoller,
    /// Dirty row tracker for partial updates
    pub(crate) dirty_rows: DirtyRowTracker,

    /// Unicode ambiguous-width treatment: 1 = single-width (Western default),
    /// 2 = double-width (East Asian). Stored for future grid layout integration.
    pub(crate) ambiguous_width: AtomicU64,

    /// Counter incremented on every `processor.advance` call. Sampled every
    /// `INVARIANT_CHECK_PERIOD` calls to run a grid-state invariant check
    /// (cursor in bounds, no orphan wide-char spacers). Rate-limited to
    /// keep the per-PTY-chunk cost bounded under heavy streaming.
    pub(crate) advance_counter: AtomicU64,

    // Graphics protocol support
    /// Pre-filter that intercepts image escape sequences before VTE processing
    pub(crate) graphics_interceptor: Mutex<graphics::GraphicsInterceptor>,
    /// Store for decoded images pending pickup by Swift
    pub(crate) image_store: Mutex<graphics::ImageStore>,
    /// Kitty multi-chunk accumulator
    pub(crate) kitty_accumulator: Mutex<graphics::KittyAccumulator>,
}

// ============================================================================
// Terminal implementation
// ============================================================================

impl Chau7Terminal {
    /// Create a new terminal with the specified dimensions and shell
    pub fn new(cols: u16, rows: u16, shell: &str) -> Result<Self, TerminalError> {
        Self::new_with_env(cols, rows, shell, &[])
    }

    /// Create a headless terminal suitable for remote playback.
    ///
    /// This does not spawn a PTY or child process. Callers are expected to feed
    /// output through `inject_output()` and query state through the existing grid
    /// snapshot APIs.
    pub fn new_headless(cols: u16, rows: u16) -> Result<Self, TerminalError> {
        let id = TERMINAL_COUNTER.fetch_add(1, Ordering::Relaxed);
        let created_at = Instant::now();

        info!(
            "[terminal-{}] Creating new headless terminal: {}x{}",
            id, cols, rows
        );

        if cols == 0 || rows == 0 {
            error!("[terminal-{}] Invalid dimensions: {}x{}", id, cols, rows);
            return Err(TerminalError::InvalidDimensions { cols, rows });
        }

        let (event_tx, event_rx) = bounded::<Event>(100);
        let bell_pending = Arc::new(AtomicBool::new(false));
        let listener = Chau7EventListener {
            sender: event_tx,
            terminal_id: id,
            bell_pending: bell_pending.clone(),
        };

        let size = SizeInfo::new(cols as usize, rows as usize);
        let config = TermConfig::default();
        let term = Term::new(config, &size, listener);

        Ok(Chau7Terminal {
            id,
            term: Mutex::new(term),
            processor: Mutex::new(Processor::new()),
            pty_handle: Mutex::new(None),
            echo_fd: AtomicI32::new(-1),
            child: Mutex::new(None),
            shell_pid: AtomicU64::new(0),
            pty_rx: None,
            running: Arc::new(AtomicBool::new(false)),
            reader_pool_fd: None,
            event_rx,
            grid_dirty: AtomicBool::new(true),
            cols,
            rows,
            created_at,
            bytes_received: AtomicU64::new(0),
            bytes_sent: AtomicU64::new(0),
            write_errors: AtomicU64::new(0),
            theme_colors: RwLock::new(ThemeColors::default()),
            last_output: Mutex::new(Vec::new()),
            bell_pending,
            metrics: PerformanceMetrics::default(),
            pending_title: Mutex::new(None),
            has_pending_title: AtomicBool::new(false),
            pending_cwd: Mutex::new(None),
            has_pending_cwd: AtomicBool::new(false),
            pending_exit_code: Mutex::new(None),
            pty_closed: AtomicBool::new(true),
            link_urls: Mutex::new(vec![String::new()]),
            pending_clipboard_store: Mutex::new(None),
            has_pending_clipboard_store: AtomicBool::new(false),
            pending_clipboard_load: Mutex::new(None),
            has_pending_clipboard_load: AtomicBool::new(false),
            pending_shell_events: Mutex::new(Vec::new()),
            has_pending_shell_events: AtomicBool::new(false),
            adaptive_poller: AdaptivePoller::new(),
            dirty_rows: DirtyRowTracker::new(rows as usize),
            ambiguous_width: AtomicU64::new(1),
            advance_counter: AtomicU64::new(0),
            graphics_interceptor: Mutex::new(graphics::GraphicsInterceptor::new()),
            image_store: Mutex::new(graphics::ImageStore::new()),
            kitty_accumulator: Mutex::new(graphics::KittyAccumulator::new()),
        })
    }

    /// Create a new terminal with the specified dimensions, shell, and environment variables
    pub fn new_with_env(
        cols: u16,
        rows: u16,
        shell: &str,
        env_vars: &[(&str, &str)],
    ) -> Result<Self, TerminalError> {
        let id = TERMINAL_COUNTER.fetch_add(1, Ordering::Relaxed);
        let created_at = Instant::now();

        info!(
            "[terminal-{}] Creating new terminal: {}x{}, shell={:?}",
            id, cols, rows, shell
        );

        // Validate dimensions
        if cols == 0 || rows == 0 {
            error!("[terminal-{}] Invalid dimensions: {}x{}", id, cols, rows);
            return Err(TerminalError::InvalidDimensions { cols, rows });
        }
        if cols > 1000 || rows > 1000 {
            warn!(
                "[terminal-{}] Large dimensions requested: {}x{}",
                id, cols, rows
            );
        }

        // Determine shell path
        let shell_path = if shell.is_empty() {
            std::env::var("SHELL").unwrap_or_else(|_| "/bin/zsh".to_string())
        } else {
            shell.to_string()
        };
        info!("[terminal-{}] Using shell: {}", id, shell_path);

        // Create PTY
        let pty_system = native_pty_system();
        let pty_size = PtySize {
            rows,
            cols,
            pixel_width: 0,
            pixel_height: 0,
        };

        let pair = pty_system.openpty(pty_size).map_err(|e| {
            error!("[terminal-{}] Failed to open PTY: {}", id, e);
            TerminalError::PtyOpen(e.into())
        })?;
        debug!("[terminal-{}] PTY opened successfully", id);

        // Create event channel for terminal events
        let (event_tx, event_rx) = bounded::<Event>(100);
        let bell_pending = Arc::new(AtomicBool::new(false));
        let listener = Chau7EventListener {
            sender: event_tx,
            terminal_id: id,
            bell_pending: bell_pending.clone(),
        };

        // Create alacritty terminal
        let size = SizeInfo::new(cols as usize, rows as usize);
        let config = TermConfig::default();
        let term = Term::new(config, &size, listener);
        debug!(
            "[terminal-{}] Terminal state initialized (history: 10000 lines)",
            id
        );

        // Prepare shell command
        let mut cmd = CommandBuilder::new(&shell_path);
        cmd.env("TERM", "xterm-256color");
        cmd.env("COLORTERM", "truecolor");

        // Set environment variables
        for (key, value) in env_vars {
            debug!("[terminal-{}] Setting env: {}={}", id, key, value);
            cmd.env(key, value);
        }
        info!(
            "[terminal-{}] Spawning shell process: {} (with {} extra env vars)",
            id,
            shell_path,
            env_vars.len()
        );

        let child = pair.slave.spawn_command(cmd).map_err(|e| {
            error!(
                "[terminal-{}] Failed to spawn shell '{}': {}",
                id, shell_path, e
            );
            TerminalError::SpawnShell {
                shell: shell_path.clone(),
                source: e.into(),
            }
        })?;

        // Capture shell PID for dev server monitoring
        let shell_pid = child.process_id().unwrap_or(0);
        info!(
            "[terminal-{}] Shell process spawned successfully (PID: {})",
            id, shell_pid
        );

        // Capture the master PTY fd for tcgetattr echo detection.
        // Use the MasterPty trait's as_raw_fd() method directly — no unsafe casts needed.
        let master_fd = match pair.master.as_raw_fd() {
            Some(raw_fd) => {
                let duped = unsafe { libc::dup(raw_fd) };
                if duped < 0 {
                    warn!(
                        "[terminal-{}] Failed to dup master fd for echo detection",
                        id
                    );
                    -1
                } else {
                    debug!(
                        "[terminal-{}] Captured master PTY fd (duped to {}) for echo detection",
                        id, duped
                    );
                    duped
                }
            }
            None => {
                warn!("[terminal-{}] MasterPty::as_raw_fd() returned None", id);
                -1
            }
        };

        // Get a raw fd for the shared reader pool by dup'ing the master PTY.
        // The pool thread will use poll()+read() on this fd.
        let reader_fd = match pair.master.as_raw_fd() {
            Some(raw_fd) => {
                let duped = unsafe { libc::dup(raw_fd) };
                if duped < 0 {
                    error!("[terminal-{}] Failed to dup master fd for reader pool", id);
                    -1
                } else {
                    debug!(
                        "[terminal-{}] Dup'd master PTY fd {} → {} for reader pool",
                        id, raw_fd, duped
                    );
                    duped
                }
            }
            None => {
                error!(
                    "[terminal-{}] MasterPty::as_raw_fd() returned None — no reader pool",
                    id
                );
                -1
            }
        };

        // Get writer for PTY input
        let writer = pair.master.take_writer().map_err(|e| {
            error!("[terminal-{}] Failed to get PTY writer: {}", id, e);
            TerminalError::PtyWriter(e.into())
        })?;
        debug!("[terminal-{}] PTY writer obtained", id);

        // Create running flag
        let running = Arc::new(AtomicBool::new(true));

        // Create channel for PTY data (same API as before — poll() still
        // receives from this channel)
        let (pty_tx, pty_rx) = bounded::<PtyMessage>(256);

        // Register with the shared reader pool instead of spawning a per-terminal thread.
        // The pool's single thread uses poll() to monitor all PTY fds and dispatches
        // PtyMessage::Data to the appropriate channel.
        if reader_fd >= 0 {
            crate::reader_pool::shared_reader_pool().register(
                reader_fd,
                id,
                pty_tx,
                running.clone(),
            );
            info!(
                "[terminal-{}] Registered with shared PTY reader pool (fd={})",
                id, reader_fd
            );
        } else {
            warn!(
                "[terminal-{}] No reader fd — PTY output will not be monitored",
                id
            );
        }

        // Create the PTY handle
        let pty_handle = PtyHandle {
            writer,
            _master: pair.master,
        };

        info!(
            "[terminal-{}] Terminal created successfully in {:?}",
            id,
            created_at.elapsed()
        );

        Ok(Chau7Terminal {
            id,
            term: Mutex::new(term),
            processor: Mutex::new(Processor::new()),
            pty_handle: Mutex::new(Some(pty_handle)),
            echo_fd: AtomicI32::new(master_fd),
            child: Mutex::new(Some(child)),
            shell_pid: AtomicU64::new(shell_pid as u64),
            pty_rx: Some(pty_rx),
            running,
            reader_pool_fd: if reader_fd >= 0 {
                Some(reader_fd)
            } else {
                None
            },
            event_rx,
            grid_dirty: AtomicBool::new(true),
            cols,
            rows,
            created_at,
            bytes_received: AtomicU64::new(0),
            bytes_sent: AtomicU64::new(0),
            write_errors: AtomicU64::new(0),
            theme_colors: RwLock::new(ThemeColors::default()),
            last_output: Mutex::new(Vec::new()),
            bell_pending,
            metrics: PerformanceMetrics::default(),
            pending_title: Mutex::new(None),
            has_pending_title: AtomicBool::new(false),
            pending_cwd: Mutex::new(None),
            has_pending_cwd: AtomicBool::new(false),
            pending_exit_code: Mutex::new(None),
            pty_closed: AtomicBool::new(false),
            // Hyperlinks (OSC 8) — index 0 reserved for "no link"
            link_urls: Mutex::new(vec![String::new()]),
            // Clipboard (OSC 52)
            pending_clipboard_store: Mutex::new(None),
            has_pending_clipboard_store: AtomicBool::new(false),
            pending_clipboard_load: Mutex::new(None),
            has_pending_clipboard_load: AtomicBool::new(false),
            // Shell integration (OSC 133)
            pending_shell_events: Mutex::new(Vec::new()),
            has_pending_shell_events: AtomicBool::new(false),
            // Performance optimizations
            adaptive_poller: AdaptivePoller::new(),
            dirty_rows: DirtyRowTracker::new(rows as usize),
            // Unicode width config
            ambiguous_width: AtomicU64::new(1),
            advance_counter: AtomicU64::new(0),
            // Graphics protocol support
            graphics_interceptor: Mutex::new(graphics::GraphicsInterceptor::new()),
            image_store: Mutex::new(graphics::ImageStore::new()),
            kitty_accumulator: Mutex::new(graphics::KittyAccumulator::new()),
        })
    }

    /// Set theme colors for rendering
    pub fn set_colors(
        &self,
        fg: (u8, u8, u8),
        bg: (u8, u8, u8),
        cursor: (u8, u8, u8),
        palette: [(u8, u8, u8); 16],
    ) {
        debug!(
            "[terminal-{}] Setting theme colors: fg={:?}, bg={:?}, cursor={:?}",
            self.id, fg, bg, cursor
        );
        let mut theme = self.theme_colors.write();
        theme.fg = fg;
        theme.bg = bg;
        theme.cursor = cursor;
        theme.palette = palette;
        theme.rebuild_lut();
        // Mark grid dirty so it gets re-rendered with new colors
        self.grid_dirty.store(true, Ordering::Release);
    }

    /// Check if PTY has echo disabled (e.g., during password prompts).
    /// Uses tcgetattr on the duplicated master fd to check the ECHO flag.
    /// Returns true if ECHO is disabled (password/secret input mode).
    pub fn is_echo_disabled(&self) -> bool {
        let echo_fd = self.echo_fd.load(Ordering::Acquire);
        if echo_fd < 0 {
            // fd capture failed at creation time, can't check
            return false;
        }
        unsafe {
            let mut termios: libc::termios = std::mem::zeroed();
            if libc::tcgetattr(echo_fd, &mut termios) == 0 {
                let echo_off = (termios.c_lflag & (libc::ECHO as libc::tcflag_t)) == 0;
                trace!(
                    "[terminal-{}] tcgetattr: ECHO={}, echo_disabled={}",
                    self.id,
                    if echo_off { "off" } else { "on" },
                    echo_off
                );
                echo_off
            } else {
                // tcgetattr failed (PTY might be closed)
                trace!(
                    "[terminal-{}] tcgetattr failed, assuming echo enabled",
                    self.id
                );
                false
            }
        }
    }

    /// Get the URL for a hyperlink ID from the most recent grid snapshot.
    /// Returns None if the ID is invalid or 0 (no link).
    pub fn get_link_url(&self, link_id: u16) -> Option<String> {
        if link_id == 0 {
            return None;
        }
        let urls = self.link_urls.lock();
        urls.get(link_id as usize).cloned()
    }

    /// Takes pending clipboard store text (OSC 52 write).
    /// Returns the text to place on the system clipboard, or None.
    pub fn take_pending_clipboard_store(&self) -> Option<String> {
        // Fast path: skip Mutex lock when no clipboard event pending
        if !self.has_pending_clipboard_store.load(Ordering::Acquire) {
            return None;
        }
        let value = self.pending_clipboard_store.lock().take();
        // Clear flag *after* lock to avoid TOCTOU: a producer setting a new
        // value between flag-clear and lock-acquire would be invisible to polls.
        if value.is_some() {
            self.has_pending_clipboard_store
                .store(false, Ordering::Release);
        }
        value
    }

    /// Takes pending clipboard load request (OSC 52 read).
    /// Returns true if a clipboard read was requested.
    /// Caller must then provide the clipboard text via `respond_clipboard_load()`.
    pub fn has_pending_clipboard_load(&self) -> bool {
        // Fast path: skip Mutex lock when no clipboard load pending
        if !self.has_pending_clipboard_load.load(Ordering::Acquire) {
            return false;
        }
        self.pending_clipboard_load.lock().is_some()
    }

    /// Respond to a pending clipboard load request.
    /// The formatter closure wraps the text in the proper OSC 52 response sequence
    /// and we write it to the PTY.
    pub fn respond_clipboard_load(&self, clipboard_text: &str) {
        let formatter = self.pending_clipboard_load.lock().take();
        // Clear flag *after* lock to avoid TOCTOU race with producer
        self.has_pending_clipboard_load
            .store(false, Ordering::Release);
        if let Some(fmt) = formatter {
            let response = fmt(clipboard_text);
            trace!(
                "[terminal-{}] OSC 52 clipboard load response: {} bytes",
                self.id,
                response.len()
            );
            let mut handle = self.pty_handle.lock();
            let Some(handle) = handle.as_mut() else {
                trace!(
                    "[terminal-{}] Ignoring clipboard load response for headless terminal",
                    self.id
                );
                return;
            };
            if let Err(e) = handle.writer.write_all(response.as_bytes()) {
                warn!(
                    "[terminal-{}] Failed to write OSC 52 response: {}",
                    self.id, e
                );
            } else if let Err(e) = handle.writer.flush() {
                warn!(
                    "[terminal-{}] Failed to flush OSC 52 response: {}",
                    self.id, e
                );
            }
        }
    }

    /// Send bytes to the PTY (user input)
    pub fn send_bytes(&self, data: &[u8]) {
        trace!("[terminal-{}] Sending {} bytes to PTY", self.id, data.len());
        let mut handle = self.pty_handle.lock();
        let Some(handle) = handle.as_mut() else {
            trace!(
                "[terminal-{}] Ignoring send_bytes on headless terminal",
                self.id
            );
            return;
        };
        match handle.write_all(data) {
            Ok(()) => {
                self.bytes_sent
                    .fetch_add(data.len() as u64, Ordering::Relaxed);
                trace!(
                    "[terminal-{}] Successfully wrote {} bytes to PTY",
                    self.id,
                    data.len()
                );
            }
            Err(e) => {
                self.write_errors.fetch_add(1, Ordering::Relaxed);
                error!(
                    "[terminal-{}] Failed to write {} bytes to PTY: {}",
                    self.id,
                    data.len(),
                    e
                );
            }
        }
    }

    /// Resize the terminal
    pub fn resize(&mut self, cols: u16, rows: u16) {
        info!(
            "[terminal-{}] Resizing terminal: {}x{} -> {}x{}",
            self.id, self.cols, self.rows, cols, rows
        );

        if cols == 0 || rows == 0 {
            warn!(
                "[terminal-{}] Ignoring invalid resize dimensions: {}x{}",
                self.id, cols, rows
            );
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
        if let Some(handle) = self.pty_handle.lock().as_ref() {
            if let Err(e) = handle.resize(pty_size) {
                error!("[terminal-{}] Failed to resize PTY: {}", self.id, e);
            } else {
                debug!("[terminal-{}] PTY resized successfully", self.id);
            }
        }

        // Resize terminal
        let mut term = self.term.lock();
        let term_size = SizeInfo::new(cols as usize, rows as usize);
        term.resize(term_size);
        debug!("[terminal-{}] Terminal state resized", self.id);

        self.grid_dirty.store(true, Ordering::Release);
    }

    /// Poll for new data from PTY, process it, and return whether grid changed.
    /// Raw output bytes are stored in `last_output` for retrieval via `get_last_output()`.
    #[must_use]
    pub fn poll(&self, timeout_ms: u32) -> bool {
        let poll_start = Instant::now();

        // Adaptive polling: use suggested timeout or caller's timeout (whichever is shorter)
        let adaptive_timeout = self.adaptive_poller.suggested_timeout_ms();
        let effective_timeout = timeout_ms.min(adaptive_timeout);
        trace!(
            "[terminal-{}] poll(timeout_ms={}, adaptive={})",
            self.id, timeout_ms, effective_timeout
        );

        let timeout = Duration::from_millis(effective_timeout as u64);
        let mut had_data = false;
        let mut bytes_this_poll = 0usize;

        // Accumulate all data locally, then lock last_output once at the end
        let mut local_output = Vec::new();

        if let Some(pty_rx) = self.pty_rx.as_ref() {
            // Try to receive data with timeout for the first message
            match pty_rx.recv_timeout(timeout) {
                Ok(PtyMessage::Data(data)) => {
                    bytes_this_poll += data.len();
                    let visible_data = filter_terminal_output_noise(&data);
                    if !visible_data.is_empty() {
                        local_output.extend_from_slice(visible_data.as_ref());
                        self.process_pty_data(visible_data.as_ref());
                        had_data = true;
                    }
                }
                Ok(PtyMessage::Closed) => {
                    info!("[terminal-{}] PTY closed message received in poll", self.id);
                    self.pty_closed.store(true, Ordering::Release);
                    return false;
                }
                Err(crossbeam_channel::RecvTimeoutError::Timeout) => {
                    trace!("[terminal-{}] poll timeout (no data)", self.id);
                }
                Err(crossbeam_channel::RecvTimeoutError::Disconnected) => {
                    warn!("[terminal-{}] PTY channel disconnected", self.id);
                    self.pty_closed.store(true, Ordering::Release);
                }
            }

            // Drain any additional pending data without blocking
            loop {
                match pty_rx.try_recv() {
                    Ok(PtyMessage::Data(data)) => {
                        bytes_this_poll += data.len();
                        let visible_data = filter_terminal_output_noise(&data);
                        if !visible_data.is_empty() {
                            local_output.extend_from_slice(visible_data.as_ref());
                            self.process_pty_data(visible_data.as_ref());
                            had_data = true;
                        }
                    }
                    Ok(PtyMessage::Closed) => {
                        info!(
                            "[terminal-{}] PTY closed message received while draining",
                            self.id
                        );
                        self.pty_closed.store(true, Ordering::Release);
                        break;
                    }
                    Err(TryRecvError::Empty) => break,
                    Err(TryRecvError::Disconnected) => {
                        warn!(
                            "[terminal-{}] PTY channel disconnected while draining",
                            self.id
                        );
                        self.pty_closed.store(true, Ordering::Release);
                        break;
                    }
                }
            }
        }

        // Single lock: replace last_output with accumulated data
        {
            let mut last_output = self.last_output.lock();
            last_output.clear();
            last_output.extend_from_slice(&local_output);
        }

        // Process terminal events
        let mut event_count = 0;
        let mut pty_write_count = 0;
        while let Ok(event) = self.event_rx.try_recv() {
            event_count += 1;
            match event {
                Event::PtyWrite(text) => {
                    pty_write_count += 1;
                    let bytes = text.as_bytes();
                    trace!(
                        "[terminal-{}] PtyWrite event: {} bytes",
                        self.id,
                        bytes.len()
                    );
                    let mut handle = self.pty_handle.lock();
                    let Some(handle) = handle.as_mut() else {
                        trace!(
                            "[terminal-{}] Dropping PtyWrite event for headless terminal",
                            self.id
                        );
                        continue;
                    };
                    if let Err(e) = handle.writer.write_all(bytes) {
                        warn!(
                            "[terminal-{}] Failed to write PtyWrite response: {}",
                            self.id, e
                        );
                    } else if let Err(e) = handle.writer.flush() {
                        warn!(
                            "[terminal-{}] Failed to flush PtyWrite response: {}",
                            self.id, e
                        );
                    }
                }
                Event::Title(title) => {
                    trace!("[terminal-{}] Title change: {}", self.id, title);
                    *self.pending_title.lock() = Some(title);
                    self.has_pending_title.store(true, Ordering::Release);
                }
                Event::ChildExit(code) => {
                    debug!("[terminal-{}] Child exit with code: {}", self.id, code);
                    *self.pending_exit_code.lock() = Some(code);
                }
                Event::ClipboardStore(_clipboard_type, text) => {
                    debug!(
                        "[terminal-{}] OSC 52 clipboard store: {} chars",
                        self.id,
                        text.len()
                    );
                    *self.pending_clipboard_store.lock() = Some(text);
                    self.has_pending_clipboard_store
                        .store(true, Ordering::Release);
                }
                Event::ClipboardLoad(_clipboard_type, formatter) => {
                    debug!("[terminal-{}] OSC 52 clipboard load request", self.id);
                    *self.pending_clipboard_load.lock() = Some(formatter);
                    self.has_pending_clipboard_load
                        .store(true, Ordering::Release);
                }
                _ => {}
            }
        }
        if event_count > 0 {
            trace!(
                "[terminal-{}] Processed {} terminal events ({} PtyWrite)",
                self.id, event_count, pty_write_count
            );
        }

        // Update adaptive poller based on activity
        if had_data {
            self.bytes_received
                .fetch_add(bytes_this_poll as u64, Ordering::Relaxed);
            debug!(
                "[terminal-{}] poll: processed {} bytes",
                self.id, bytes_this_poll
            );
            self.grid_dirty.store(true, Ordering::Release);
            self.adaptive_poller.record_activity(bytes_this_poll);
            self.dirty_rows.mark_all_dirty();
            self.metrics
                .bytes_batched
                .fetch_add(bytes_this_poll as u64, Ordering::Relaxed);
            self.metrics.batch_count.fetch_add(1, Ordering::Relaxed);
        } else {
            self.adaptive_poller.record_idle();
            self.metrics.idle_polls.fetch_add(1, Ordering::Relaxed);
        }

        let was_dirty = self.grid_dirty.swap(false, Ordering::AcqRel);

        // Track performance metrics
        let poll_time_us = poll_start.elapsed().as_micros() as u64;
        self.metrics.poll_count.fetch_add(1, Ordering::Relaxed);
        self.metrics
            .poll_time_us
            .fetch_add(poll_time_us, Ordering::Relaxed);
        let current_max = self.metrics.max_poll_time_us.load(Ordering::Relaxed);
        if poll_time_us > current_max {
            self.metrics
                .max_poll_time_us
                .store(poll_time_us, Ordering::Relaxed);
        }

        trace!(
            "[terminal-{}] poll returning: {} (took {}µs, activity={}%)",
            self.id,
            was_dirty,
            poll_time_us,
            self.adaptive_poller.activity_percent()
        );
        was_dirty
    }

    /// Scan a chunk of PTY bytes for OSC 7 (current working directory) and
    /// store the most recent payload in `pending_cwd`. Terminators are BEL
    /// (0x07) or ST (ESC \). Non-UTF8 payloads are dropped silently — Swift
    /// would only re-emit the warning and we keep this hot path quiet.
    fn scan_osc7(&self, data: &[u8]) {
        if data.len() < 6 {
            return;
        }
        let mut i = 0usize;
        let mut latest: Option<String> = None;
        while i + 4 < data.len() {
            if data[i] == 0x1B && data[i + 1] == 0x5D && data[i + 2] == b'7' && data[i + 3] == b';'
            {
                let start = i + 4;
                let mut end = start;
                while end < data.len() {
                    if data[end] == 0x07 {
                        break;
                    }
                    if data[end] == 0x1B && end + 1 < data.len() && data[end + 1] == 0x5C {
                        break;
                    }
                    end += 1;
                }
                if end > start && end < data.len() {
                    if let Ok(payload) = std::str::from_utf8(&data[start..end]) {
                        latest = Some(payload.to_owned());
                    }
                    i = end + 1;
                    continue;
                }
            }
            i += 1;
        }
        if let Some(payload) = latest {
            let mut pending = self.pending_cwd.lock();
            *pending = Some(payload);
            self.has_pending_cwd
                .store(true, std::sync::atomic::Ordering::Release);
        }
    }

    /// Take the pending OSC 7 cwd payload, if any. Format is the raw URL the
    /// shell emitted (typically `file://host/path` — Swift handles parsing).
    pub fn get_pending_cwd(&self) -> Option<String> {
        if !self
            .has_pending_cwd
            .load(std::sync::atomic::Ordering::Acquire)
        {
            return None;
        }
        let mut pending = self.pending_cwd.lock();
        let value = pending.take();
        if value.is_some() {
            self.has_pending_cwd
                .store(false, std::sync::atomic::Ordering::Release);
        }
        value
    }

    /// Get the raw output bytes from the last poll.
    pub fn get_last_output(&self) -> Vec<u8> {
        let mut last_output = self.last_output.lock();
        std::mem::take(&mut *last_output)
    }

    /// Process PTY output data through the VTE processor.
    /// The graphics interceptor pre-filters image escape sequences before VTE.
    pub fn process_pty_data(&self, data: &[u8]) {
        trace!(
            "[terminal-{}] Processing {} bytes of PTY data",
            self.id,
            data.len()
        );

        // Scan for OSC 7 (current working directory report) before any
        // downstream consumer can drain or filter the bytes. Alacritty's VTE
        // processor doesn't emit a Cwd event for OSC 7, and the prior
        // Swift-side scan on `last_output` was vulnerable to a race when
        // multiple Swift views shared the same Rust terminal: whichever view
        // polled first drained the buffer via `std::mem::take`, leaving the
        // others to re-parse empty data. Capturing here gives a single
        // race-free pickup point queried via `get_pending_cwd`.
        self.scan_osc7(data);

        let (passthrough_owned, events, shell_events) = {
            let mut interceptor = self.graphics_interceptor.lock();
            interceptor.feed_owned(data)
            // Lock dropped here — passthrough_owned is an owned Vec, no borrow.
        };

        // Store shell integration events (OSC 133) for Swift to poll
        if !shell_events.is_empty() {
            debug!(
                "[terminal-{}] OSC 133: {} shell integration events",
                self.id,
                shell_events.len()
            );
            let mut pending = self.pending_shell_events.lock();
            pending.extend(shell_events);
            self.has_pending_shell_events
                .store(true, std::sync::atomic::Ordering::Release);
        }

        if !passthrough_owned.is_empty() {
            let mut term = self.term.lock();
            let mut processor = self.processor.lock();
            processor.advance(&mut *term, &passthrough_owned);
            // Sample the grid for invariant violations every
            // INVARIANT_CHECK_PERIOD calls. Catches the moment of state
            // corruption (orphan wide-char spacers, cursor outside
            // viewport) without paying the per-byte cost on every chunk.
            let n = self
                .advance_counter
                .fetch_add(1, std::sync::atomic::Ordering::Relaxed);
            if n.is_multiple_of(INVARIANT_CHECK_PERIOD) {
                Self::check_grid_invariants(self.id, &term, passthrough_owned.len());
            }
        }

        if !events.is_empty() {
            debug!(
                "[terminal-{}] Graphics interceptor produced {} events",
                self.id,
                events.len()
            );

            let (cursor_row, cursor_col) = {
                let term = self.term.lock();
                let cursor = term.grid().cursor.point;
                (cursor.line.0, cursor.column.0 as u16)
            };

            let mut store = self.image_store.lock();
            for event in events {
                let image = match event {
                    graphics::GraphicsEvent::ITerm2 {
                        args: _,
                        base64_data,
                    } => graphics::DecodedImage {
                        id: 0,
                        width: 0,
                        height: 0,
                        rgba: base64_data,
                        anchor_row: cursor_row,
                        anchor_col: cursor_col,
                        protocol: graphics::ImageProtocol::ITerm2,
                    },
                    graphics::GraphicsEvent::Sixel { params: _, data } => {
                        match graphics::decode_sixel(&data) {
                            Some((rgba, width, height)) => {
                                debug!(
                                    "[terminal-{}] Sixel decoded: {}x{} ({} bytes RGBA)",
                                    self.id,
                                    width,
                                    height,
                                    rgba.len()
                                );
                                graphics::DecodedImage {
                                    id: 0,
                                    width,
                                    height,
                                    rgba,
                                    anchor_row: cursor_row,
                                    anchor_col: cursor_col,
                                    protocol: graphics::ImageProtocol::Sixel,
                                }
                            }
                            None => {
                                warn!("[terminal-{}] Sixel decode failed, skipping image", self.id);
                                continue;
                            }
                        }
                    }
                    graphics::GraphicsEvent::Kitty { control, payload } => {
                        let mut accum = self.kitty_accumulator.lock();
                        match accum.feed(&control, &payload) {
                            graphics::KittyAction::Display {
                                rgba,
                                width,
                                height,
                            } => {
                                debug!(
                                    "[terminal-{}] Kitty decoded: {}x{} ({} bytes)",
                                    self.id,
                                    width,
                                    height,
                                    rgba.len()
                                );
                                graphics::DecodedImage {
                                    id: 0,
                                    width,
                                    height,
                                    rgba,
                                    anchor_row: cursor_row,
                                    anchor_col: cursor_col,
                                    protocol: graphics::ImageProtocol::Kitty,
                                }
                            }
                            graphics::KittyAction::Continue => {
                                trace!("[terminal-{}] Kitty: accumulating chunk", self.id);
                                continue;
                            }
                            graphics::KittyAction::Delete { id } => {
                                debug!("[terminal-{}] Kitty delete image id={}", self.id, id);
                                // TODO: Implement image deletion from store
                                continue;
                            }
                            graphics::KittyAction::Noop => {
                                continue;
                            }
                        }
                    }
                };
                store.push(image);
            }
        }
    }

    /// Inject output bytes directly into the terminal (without sending to PTY).
    pub fn inject_output(&self, data: &[u8]) {
        if data.is_empty() {
            return;
        }
        trace!(
            "[terminal-{}] Injecting {} bytes of output",
            self.id,
            data.len()
        );
        self.process_pty_data(data);
        self.grid_dirty.store(true, Ordering::Release);
        self.dirty_rows.mark_all_dirty();
    }

    /// Create a snapshot of the current grid state
    #[must_use]
    pub fn get_grid_snapshot(&self) -> GridSnapshot {
        debug!("[terminal-{}] Creating grid snapshot", self.id);
        let start = Instant::now();

        // Clone theme to release the RwLock before the cell loop.
        // ThemeColors is ~2KB — cloning is negligible vs. holding the lock
        // for 3000+ cell iterations.
        let theme = self.theme_colors.read().clone();

        // ── Phase 1: Extract cell data under term lock ──────────────
        // We hold the term lock only for grid iteration. Color conversion
        // uses the cloned theme (no lock). Hyperlink URI extraction must
        // happen here since it references grid cell data.
        let (
            mut cells,
            mut clusters,
            cols,
            rows,
            display_offset,
            history_size,
            link_url_vec,
            cursor_visible,
        ) = {
            let term = self.term.lock();
            let grid = term.grid();

            // DECTCEM: whether the cursor should be drawn (ESC[?25l hides, ESC[?25h shows)
            let cursor_visible = term.mode().contains(TermMode::SHOW_CURSOR);

            let cols = grid.columns();
            let rows = grid.screen_lines();
            let display_offset = grid.display_offset();
            let history_size = grid.history_size();
            let total_cells = cols * rows;

            trace!(
                "[terminal-{}] Grid snapshot: {}x{}, {} total cells, history={}, offset={}",
                self.id, cols, rows, total_cells, history_size, display_offset
            );

            let selection_range = term.selection.as_ref().and_then(|sel| sel.to_range(&*term));

            let mut cells: Vec<CellData> = get_cell_buffer_pool().acquire(total_cells);
            // UTF-8 cluster buffer. Pre-size for ASCII-dense grids (1 byte/cell).
            // Emoji-heavy grids will grow this, which is fine — the Vec doubles.
            let mut clusters: Vec<u8> = Vec::with_capacity(total_cells);
            // Scratch buffer reused across cells to avoid per-cell allocation.
            let mut cluster_scratch = String::with_capacity(16);

            // Hyperlink tracking: map URI → link_id for deduplication.
            // Index 0 is reserved (no link). IDs start at 1.
            let mut uri_to_id: HashMap<String, u16> = HashMap::new();
            let mut link_url_vec: Vec<String> = vec![String::new()]; // index 0 = no link

            // Iterate over the VIEWPORT, not the active screen.
            // Like Alacritty's display_iter(), we offset by -display_offset so that
            // when the user scrolls up, we read scrollback history lines (negative
            // Line values) instead of the active screen.
            //
            // Coordinate mapping:
            //   viewport row 0 → grid Line(-display_offset)     (top of what user sees)
            //   viewport row N → grid Line(N - display_offset)
            //   When display_offset == 0, this simplifies to Line(0)..Line(rows-1).
            for line_idx in 0..rows {
                let line = Line(line_idx as i32 - display_offset as i32);
                for col_idx in 0..cols {
                    let point = Point::new(line, Column(col_idx));
                    let cell = &grid[point];

                    let is_spacer = cell.flags.contains(CellFlags::WIDE_CHAR_SPACER);
                    let is_wide = cell.flags.contains(CellFlags::WIDE_CHAR);

                    // Build the cluster from the primary char + zero-width extras
                    // (combining marks, VS16, ZWJ), then NFC-normalize so that NFD
                    // input ("e\u{0301}") and NFC ("é") hash to the same atlas key.
                    //
                    // Spacer cells own no glyph — they're the right half of a wide
                    // grapheme. Empty cluster (len=0) signals "paint background only".
                    // NUL is also treated as blank.
                    let (cluster_offset, cluster_len, width, continuation) = if is_spacer {
                        (0u32, 0u16, 0u8, 1u8)
                    } else if cell.c == '\u{0}' {
                        (0u32, 0u16, 1u8, 0u8)
                    } else {
                        cluster_scratch.clear();
                        cluster_scratch.push(cell.c);
                        if let Some(extras) = cell.zerowidth() {
                            for &ch in extras {
                                cluster_scratch.push(ch);
                            }
                        }
                        // `cluster_offset` is u32 in the FFI struct, so the cluster
                        // buffer must stay below 4 GiB. A terminal grid producing
                        // that much grapheme data in a single snapshot is unheard
                        // of; the debug_assert catches a runaway producer in tests
                        // without paying a release-build branch.
                        debug_assert!(
                            clusters.len() <= u32::MAX as usize,
                            "clusters buffer exceeded u32::MAX bytes; cluster_offset would truncate"
                        );
                        let offset = clusters.len() as u32;
                        // NFC normalization: streams the iterator straight into the buffer.
                        for ch in cluster_scratch.chars().nfc() {
                            let mut buf = [0u8; 4];
                            clusters.extend_from_slice(ch.encode_utf8(&mut buf).as_bytes());
                        }
                        let written = clusters.len() as u32 - offset;
                        // cluster_len is u16; a single grapheme above 65 KiB is
                        // pathological but should still fail loudly in debug.
                        debug_assert!(
                            written <= u16::MAX as u32,
                            "single grapheme cluster exceeded u16::MAX bytes"
                        );
                        let len = written as u16;
                        let w = if is_wide { 2u8 } else { 1u8 };
                        (offset, len, w, 0u8)
                    };

                    let fg_color = Self::effective_cell_fg(cell);

                    let (mut fg_r, mut fg_g, mut fg_b) =
                        color_to_rgb_with_theme(fg_color, true, &theme);
                    let (mut bg_r, mut bg_g, mut bg_b) =
                        color_to_rgb_with_theme(cell.bg, false, &theme);
                    let flags = cell_flags_to_u8(cell.flags);

                    // Extract hyperlink URL (OSC 8)
                    let link_id = if let Some(hyperlink) = cell.hyperlink() {
                        let uri = hyperlink.uri().to_string();
                        *uri_to_id.entry(uri.clone()).or_insert_with(|| {
                            let id = link_url_vec.len() as u16;
                            link_url_vec.push(uri);
                            id
                        })
                    } else {
                        0
                    };

                    // Selection uses grid-absolute coordinates (Line value already
                    // accounts for display_offset via the subtraction above).
                    if let Some(ref range) = selection_range
                        && range.contains(point)
                    {
                        std::mem::swap(&mut fg_r, &mut bg_r);
                        std::mem::swap(&mut fg_g, &mut bg_g);
                        std::mem::swap(&mut fg_b, &mut bg_b);
                    }

                    cells.push(CellData {
                        cluster_offset,
                        fg_r,
                        fg_g,
                        fg_b,
                        bg_r,
                        bg_g,
                        bg_b,
                        cluster_len,
                        width,
                        continuation,
                        flags,
                        underline_style: underline_style(cell.flags),
                        link_id,
                    });
                }
            }

            // term lock is dropped at the end of this block
            (
                cells,
                clusters,
                cols,
                rows,
                display_offset,
                history_size,
                link_url_vec,
                cursor_visible,
            )
        };
        // ── Phase 2: Post-processing without any lock ───────────────

        // Store link URLs for FFI retrieval
        if link_url_vec.len() > 1 {
            debug!(
                "[terminal-{}] Grid snapshot has {} unique hyperlinks",
                self.id,
                link_url_vec.len() - 1
            );
        }
        *self.link_urls.lock() = link_url_vec;

        // Convert to raw pointer - preserve Vec capacity for proper deallocation.
        // Do NOT use into_boxed_slice() — it shrinks the allocation, making
        // the previously recorded capacity invalid for Vec::from_raw_parts.
        let len = cells.len();
        let capacity = cells.capacity();
        let cells_ptr = cells.as_mut_ptr();
        std::mem::forget(cells);

        // Same forget-dance for the cluster byte buffer. Freed alongside cells
        // in `chau7_terminal_free_grid`.
        let clusters_len = clusters.len();
        let clusters_capacity = clusters.capacity();
        let clusters_ptr = if clusters_capacity == 0 {
            std::ptr::null_mut()
        } else {
            let p = clusters.as_mut_ptr();
            std::mem::forget(clusters);
            p
        };

        // Track performance metrics
        let snapshot_time_us = start.elapsed().as_micros() as u64;
        self.metrics
            .grid_snapshot_count
            .fetch_add(1, Ordering::Relaxed);
        self.metrics
            .grid_snapshot_time_us
            .fetch_add(snapshot_time_us, Ordering::Relaxed);
        let current_max = self
            .metrics
            .max_grid_snapshot_time_us
            .load(Ordering::Relaxed);
        if snapshot_time_us > current_max {
            self.metrics
                .max_grid_snapshot_time_us
                .store(snapshot_time_us, Ordering::Relaxed);
        }

        debug!(
            "[terminal-{}] Grid snapshot created in {}µs (len={}, cap={})",
            self.id, snapshot_time_us, len, capacity
        );

        GridSnapshot {
            cells: cells_ptr,
            clusters_utf8: clusters_ptr,
            clusters_len,
            clusters_capacity,
            cols: cols as u16,
            rows: rows as u16,
            cursor_visible: if cursor_visible { 1 } else { 0 },
            _pad: [0; 3],
            scrollback_rows: history_size as u32,
            display_offset: display_offset as u32,
            capacity,
        }
    }

    /// Get current scroll position as a normalized value (0.0 = bottom, 1.0 = top of history)
    pub fn scroll_position(&self) -> f64 {
        let term = self.term.lock();
        let grid = term.grid();
        let history_size = grid.history_size();
        if history_size == 0 {
            return 0.0;
        }
        let display_offset = grid.display_offset();
        let pos = display_offset as f64 / history_size as f64;
        trace!(
            "[terminal-{}] scroll_position: {} (offset={}, history={})",
            self.id, pos, display_offset, history_size
        );
        pos
    }

    /// Scroll to a normalized position (0.0 = bottom, 1.0 = top of history)
    pub fn scroll_to(&self, position: f64) {
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
        trace!(
            "[terminal-{}] scroll_to: {} -> {} (target offset: {})",
            self.id, current_offset, target_offset, target_offset
        );
        self.grid_dirty.store(true, Ordering::Release);
    }

    /// Scroll by a number of lines (positive = up/back, negative = down/forward)
    pub fn scroll_lines(&self, lines: i32) {
        debug!("[terminal-{}] scroll_lines({})", self.id, lines);
        let mut term = self.term.lock();
        term.scroll_display(alacritty_terminal::grid::Scroll::Delta(lines));
        self.grid_dirty.store(true, Ordering::Release);
    }

    /// Get the currently selected text, if any
    pub fn selection_text(&self) -> Option<String> {
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
    pub fn selection_clear(&self) {
        debug!("[terminal-{}] selection_clear", self.id);
        let mut term = self.term.lock();
        term.selection = None;
        self.grid_dirty.store(true, Ordering::Release);
    }

    /// Start a new selection at the given position
    pub fn selection_start(&self, col: i32, row: i32, selection_type: u8) {
        debug!(
            "[terminal-{}] selection_start(col={}, row={}, type={})",
            self.id, col, row, selection_type
        );
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
        self.grid_dirty.store(true, Ordering::Release);
    }

    /// Update the current selection to extend to the given position
    pub fn selection_update(&self, col: i32, row: i32) {
        debug!(
            "[terminal-{}] selection_update(col={}, row={})",
            self.id, col, row
        );
        let mut term = self.term.lock();

        if let Some(ref mut selection) = term.selection {
            let point = Point::new(Line(row), Column(col as usize));
            selection.update(point, Side::Right);
            self.grid_dirty.store(true, Ordering::Release);
        }
    }

    /// Select all content (screen + scrollback)
    pub fn selection_all(&self) {
        debug!("[terminal-{}] selection_all", self.id);
        let mut term = self.term.lock();
        let grid = term.grid();

        let history_size = grid.history_size();
        let screen_lines = grid.screen_lines();

        let start_line = -(history_size as i32);
        let start = Point::new(Line(start_line), Column(0));

        let mut selection = Selection::new(SelectionType::Simple, start, Side::Left);

        let end_line = (screen_lines as i32) - 1;
        let end_col = grid.columns().saturating_sub(1);
        let end = Point::new(Line(end_line), Column(end_col));

        selection.update(end, Side::Right);

        term.selection = Some(selection);
        self.grid_dirty.store(true, Ordering::Release);
        debug!(
            "[terminal-{}] selection_all: selected from line {} to line {}",
            self.id, start_line, end_line
        );
    }

    /// Get cursor position
    pub fn cursor_position(&self) -> (u16, u16) {
        let term = self.term.lock();
        let grid = term.grid();
        let cursor = grid.cursor.point;
        let display_offset = grid.display_offset();

        // Convert cursor from grid coordinates to viewport coordinates.
        // Grid: Line(0) = top of active screen.
        // Viewport: row 0 = top of what the user sees.
        // viewport_row = cursor.line + display_offset
        // When display_offset == 0, this is a no-op.
        let viewport_row = cursor.line.0 + display_offset as i32;
        let pos = (cursor.column.0 as u16, viewport_row as u16);
        trace!(
            "[terminal-{}] cursor_position: ({}, {}) [display_offset={}]",
            self.id, pos.0, pos.1, display_offset
        );
        pos
    }

    /// Clear the scrollback history buffer
    pub fn clear_scrollback(&self) {
        info!(
            "[terminal-{}] clear_scrollback: Clearing scrollback history",
            self.id
        );
        let mut term = self.term.lock();
        term.grid_mut().clear_history();
        self.grid_dirty.store(true, Ordering::Release);
        debug!("[terminal-{}] clear_scrollback: History cleared", self.id);
    }

    /// Set the scrollback buffer size (number of lines)
    pub fn set_scrollback_size(&self, lines: usize) {
        info!(
            "[terminal-{}] set_scrollback_size: Setting scrollback to {} lines",
            self.id, lines
        );
        let mut term = self.term.lock();
        term.grid_mut().update_history(lines);
        self.grid_dirty.store(true, Ordering::Release);
        debug!(
            "[terminal-{}] set_scrollback_size: Scrollback set to {} lines",
            self.id, lines
        );
    }

    /// Replay a historical buffer into an empty terminal.
    ///
    /// Clears both scrollback history and the visible viewport, then feeds `data`
    /// through the VTE processor. The processor naturally fills the viewport and
    /// scrolls older content into history as new rows arrive. After replay, the
    /// viewport shows the tail of `data` (typically the last shell prompt) and
    /// the scrollback contains everything above it.
    ///
    /// Intended for tier promotion: when a previously `.hidden` tab becomes
    /// active, we call `set_scrollback_size(cap)` to allocate the history ring
    /// and then this method to populate it from the on-disk cache.
    pub fn replay_buffer(&self, data: &[u8]) {
        info!(
            "[terminal-{}] replay_buffer: Replaying {} bytes into cleared terminal",
            self.id,
            data.len()
        );

        let mut term = self.term.lock();
        let mut processor = self.processor.lock();

        // Clear history ring and reset viewport (ANSI ESC[2J clears screen,
        // ESC[H homes cursor). Using the processor ensures Alacritty's internal
        // state stays consistent rather than poking the grid directly.
        term.grid_mut().clear_history();
        processor.advance(&mut *term, b"\x1b[2J\x1b[H");

        if !data.is_empty() {
            processor.advance(&mut *term, data);
        }

        self.grid_dirty.store(true, Ordering::Release);
        self.dirty_rows.mark_all_dirty();
        debug!("[terminal-{}] replay_buffer: Replay complete", self.id);
    }

    /// Set Unicode ambiguous-width treatment.
    /// - `width = 1`: single-width (Western default)
    /// - `width = 2`: double-width (East Asian)
    pub fn set_ambiguous_width(&self, width: u8) {
        let w = if width == 2 { 2u64 } else { 1u64 };
        self.ambiguous_width.store(w, Ordering::Release);
        info!("[terminal-{}] set_ambiguous_width: {}", self.id, w);
    }

    /// Get the current display offset
    pub fn display_offset(&self) -> usize {
        let term = self.term.lock();
        term.grid().display_offset()
    }

    /// Get terminal statistics for debugging
    pub fn stats(&self) -> (u64, u64, Duration) {
        (
            self.bytes_sent.load(Ordering::Relaxed),
            self.bytes_received.load(Ordering::Relaxed),
            self.created_at.elapsed(),
        )
    }

    /// Get text for a specific line in the grid
    pub fn line_text(&self, row: i32) -> Option<String> {
        let term = self.term.lock();
        let grid = term.grid();
        let rows = grid.screen_lines() as i32;
        let history = grid.history_size() as i32;

        let min_row = -history;
        let max_row = rows - 1;
        if row < min_row || row > max_row {
            return None;
        }

        let line = Line(row);
        let (text, _) = Self::grid_line_text(grid, line);
        Some(text.trim_end_matches('\n').to_string())
    }

    /// Get the full logical wrapped line containing the specified physical row.
    ///
    /// Returns the flattened text, the starting physical row, and the UTF-16
    /// offset within that flattened text for the specified physical column.
    pub fn logical_line_text(&self, row: i32, column: usize) -> Option<(String, i32, usize)> {
        let term = self.term.lock();
        let grid = term.grid();
        let rows = grid.screen_lines() as i32;
        let history = grid.history_size() as i32;

        let min_row = -history;
        let max_row = rows - 1;
        if row < min_row || row > max_row {
            return None;
        }

        let mut start_row = row;
        while start_row > min_row && Self::grid_line_wraps(grid, Line(start_row - 1)) {
            start_row -= 1;
        }

        let mut end_row = row;
        while end_row < max_row && Self::grid_line_wraps(grid, Line(end_row)) {
            end_row += 1;
        }

        let mut text = String::new();
        let mut clicked_utf16_offset = 0usize;
        for physical_row in start_row..=end_row {
            let line = Line(physical_row);
            let (line_text, _) = Self::grid_line_text(grid, line);
            if physical_row < row {
                clicked_utf16_offset += line_text.encode_utf16().count();
            } else if physical_row == row {
                clicked_utf16_offset += Self::grid_column_utf16_offset(grid, line, column);
            }
            text.push_str(&line_text);
        }

        let text = text.trim_end_matches('\n').to_string();
        let clicked_utf16_offset = clicked_utf16_offset.min(text.encode_utf16().count());
        Some((text, start_row, clicked_utf16_offset))
    }

    /// Check if bracketed paste mode is enabled
    pub fn is_bracketed_paste_mode(&self) -> bool {
        let term = self.term.lock();
        let mode = term.mode();
        let enabled = mode.contains(TermMode::BRACKETED_PASTE);
        trace!(
            "[terminal-{}] is_bracketed_paste_mode: {}",
            self.id, enabled
        );
        enabled
    }

    /// Check if the terminal is currently rendering the alternate screen.
    ///
    /// Full-screen TUI programs (vim, less, Claude/Codex/Gemini-style agents,
    /// etc.) usually draw here instead of the normal scrollback-producing
    /// screen. Exposing this as a terminal fact lets higher layers decide how
    /// to route scroll input without hardcoding provider names.
    pub fn is_alternate_screen_active(&self) -> bool {
        let term = self.term.lock();
        let active = term.mode().contains(TermMode::ALT_SCREEN);
        trace!(
            "[terminal-{}] is_alternate_screen_active: {}",
            self.id, active
        );
        active
    }

    /// Check if a bell event has occurred since the last check, and clear the flag
    #[must_use]
    pub fn check_bell(&self) -> bool {
        let was_pending = self.bell_pending.swap(false, Ordering::AcqRel);
        if was_pending {
            debug!(
                "[terminal-{}] check_bell: Bell was pending, now cleared",
                self.id
            );
        }
        was_pending
    }

    /// Get the current mouse mode as a bitmask
    pub fn mouse_mode(&self) -> u32 {
        let term = self.term.lock();
        let mode = term.mode();
        let mut result: u32 = 0;

        if mode.contains(TermMode::MOUSE_REPORT_CLICK) {
            result |= 1;
        }
        if mode.contains(TermMode::MOUSE_DRAG) {
            result |= 2;
        }
        if mode.contains(TermMode::MOUSE_MOTION) {
            result |= 4;
        }
        if mode.contains(TermMode::FOCUS_IN_OUT) {
            result |= 8;
        }
        if mode.contains(TermMode::SGR_MOUSE) {
            result |= 16;
        }

        trace!(
            "[terminal-{}] mouse_mode: {:05b} ({})",
            self.id, result, result
        );
        result
    }

    /// Check if any mouse tracking is active
    pub fn is_mouse_reporting_active(&self) -> bool {
        let mode = self.mouse_mode();
        let mouse_tracking_mask: u32 = 0b111;
        (mode & mouse_tracking_mask) != 0
    }

    /// Check if application cursor mode (DECCKM) is enabled
    pub fn is_application_cursor_mode(&self) -> bool {
        let term = self.term.lock();
        let mode = term.mode();
        let enabled = mode.contains(TermMode::APP_CURSOR);
        trace!(
            "[terminal-{}] is_application_cursor_mode: {}",
            self.id, enabled
        );
        enabled
    }

    /// Get the shell process ID
    pub fn shell_pid(&self) -> u64 {
        self.shell_pid.load(Ordering::Relaxed)
    }

    /// Get comprehensive debug state snapshot
    pub fn debug_state(&self) -> DebugState {
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
        let alternate_screen = mode.contains(TermMode::ALT_SCREEN);
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
            alternate_screen: alternate_screen as u8,
            app_cursor: app_cursor as u8,
            poll_count,
            avg_poll_time_us: poll_time.checked_div(poll_count).unwrap_or(0),
            max_poll_time_us: self.metrics.max_poll_time_us.load(Ordering::Relaxed),
            avg_grid_snapshot_time_us: grid_time.checked_div(grid_count).unwrap_or(0),
            max_grid_snapshot_time_us: self
                .metrics
                .max_grid_snapshot_time_us
                .load(Ordering::Relaxed),
            activity_percent: self.adaptive_poller.activity_percent(),
            idle_polls,
            avg_batch_size: bytes_batched.checked_div(batch_count).unwrap_or(0),
            dirty_row_count: self.dirty_rows.dirty_count() as u32,
        }
    }

    /// Get full buffer text (visible + scrollback) for debugging
    pub fn full_buffer_text(&self) -> String {
        let term = self.term.lock();
        let grid = term.grid();
        let screen_lines = grid.screen_lines() as i32;
        let history = grid.history_size() as i32;

        let mut result = String::new();
        let mut wrapped_rows = 0usize;
        for row in (-history)..screen_lines {
            let line = Line(row);
            let (line_text, wraps) = Self::grid_line_text(grid, line);
            if wraps {
                wrapped_rows += 1;
            }
            result.push_str(&line_text);
        }
        debug!(
            "[terminal-{}] full_buffer_text exported {} chars from {} physical rows ({} wrapped rows)",
            self.id,
            result.len(),
            history + screen_lines,
            wrapped_rows
        );
        result
    }

    /// Get full buffer text (visible + scrollback) with ANSI SGR styling.
    ///
    /// This is used for Chau7 tab restoration: plain text loses the original
    /// foreground/background/style attributes, so replaying it through `cat`
    /// produces monochrome transcripts. The terminal grid still owns resolved
    /// cell attributes, so export a compact ANSI reconstruction of the same
    /// logical lines that `full_buffer_text` returns.
    pub fn full_buffer_ansi_text(&self) -> String {
        let theme = self.theme_colors.read().clone();
        let term = self.term.lock();
        let grid = term.grid();
        let screen_lines = grid.screen_lines() as i32;
        let history = grid.history_size() as i32;

        let mut result = String::new();
        let mut current_style: Option<AnsiCellStyle> = None;
        let mut wrapped_rows = 0usize;
        for row in (-history)..screen_lines {
            let line = Line(row);
            let wraps =
                Self::grid_line_ansi_text(grid, line, &theme, &mut current_style, &mut result);
            if wraps {
                wrapped_rows += 1;
            }
        }
        if current_style.is_some() {
            result.push_str("\x1b[0m");
        }
        debug!(
            "[terminal-{}] full_buffer_ansi_text exported {} chars from {} physical rows ({} wrapped rows)",
            self.id,
            result.len(),
            history + screen_lines,
            wrapped_rows
        );
        result
    }

    /// Get the tail of the terminal buffer with ANSI SGR styling.
    ///
    /// Restoration autosave only needs the last N logical lines, so this keeps
    /// the exported string bounded at the Rust source instead of constructing a
    /// multi-megabyte full-buffer string and trimming it later in Swift.
    pub fn tail_buffer_ansi_text(&self, max_lines: usize, max_bytes: usize) -> String {
        if max_lines == 0 || max_bytes == 0 {
            return String::new();
        }

        let theme = self.theme_colors.read().clone();
        let term = self.term.lock();
        let grid = term.grid();
        let screen_lines = grid.screen_lines() as i32;
        let history = grid.history_size() as i32;

        let mut tail: VecDeque<String> = VecDeque::new();
        let mut tail_bytes = 0usize;
        let first_row = -history;
        let mut end_row = screen_lines - 1;
        let mut wrapped_rows = 0usize;
        let mut scanned_rows = 0usize;

        while end_row >= first_row {
            let mut start_row = end_row;
            while start_row > first_row && Self::grid_line_wraps(grid, Line(start_row - 1)) {
                start_row -= 1;
            }

            let mut current_line = String::new();
            let mut current_style: Option<AnsiCellStyle> = None;
            for row in start_row..=end_row {
                let wraps = Self::grid_line_ansi_text(
                    grid,
                    Line(row),
                    &theme,
                    &mut current_style,
                    &mut current_line,
                );
                if wraps {
                    wrapped_rows += 1;
                }
            }
            if current_style.is_some() {
                current_line.push_str("\x1b[0m");
            }

            scanned_rows += (end_row - start_row + 1) as usize;
            Self::push_front_bounded_tail_line(
                &mut tail,
                &mut tail_bytes,
                current_line,
                max_lines,
                max_bytes,
            );

            if tail.len() >= max_lines || tail_bytes >= max_bytes {
                break;
            }
            if start_row <= first_row {
                break;
            }
            end_row = start_row - 1;
        }

        let result: String = tail.into_iter().collect();
        debug!(
            "[terminal-{}] tail_buffer_ansi_text exported {} chars / {} bytes after scanning {} of {} physical rows ({} wrapped rows, max_lines={}, max_bytes={})",
            self.id,
            result.chars().count(),
            result.len(),
            scanned_rows,
            history + screen_lines,
            wrapped_rows,
            max_lines,
            max_bytes
        );
        result
    }

    fn push_front_bounded_tail_line(
        tail: &mut VecDeque<String>,
        tail_bytes: &mut usize,
        mut line: String,
        max_lines: usize,
        max_bytes: usize,
    ) {
        if !Self::ansi_line_has_visible_content(&line) {
            return;
        }

        if line.len() > max_bytes {
            line = Self::utf8_suffix_within_bytes(&line, max_bytes);
        }

        *tail_bytes += line.len();
        tail.push_front(line);

        while tail.len() > max_lines || *tail_bytes > max_bytes {
            if let Some(removed) = tail.pop_front() {
                *tail_bytes = tail_bytes.saturating_sub(removed.len());
            } else {
                break;
            }
        }
    }

    fn utf8_suffix_within_bytes(text: &str, max_bytes: usize) -> String {
        if text.len() <= max_bytes {
            return text.to_string();
        }
        if max_bytes == 0 {
            return String::new();
        }

        let mut start = text.len().saturating_sub(max_bytes);
        while start < text.len() && !text.is_char_boundary(start) {
            start += 1;
        }
        text[start..].to_string()
    }

    fn ansi_line_has_visible_content(line: &str) -> bool {
        let mut chars = line.chars().peekable();
        while let Some(ch) = chars.next() {
            if ch == '\u{1b}' {
                match chars.peek().copied() {
                    Some('[') => {
                        chars.next();
                        for csi_ch in chars.by_ref() {
                            if ('@'..='~').contains(&csi_ch) {
                                break;
                            }
                        }
                    }
                    Some(']') => {
                        chars.next();
                        let mut previous_was_escape = false;
                        for osc_ch in chars.by_ref() {
                            if osc_ch == '\u{7}' || (previous_was_escape && osc_ch == '\\') {
                                break;
                            }
                            previous_was_escape = osc_ch == '\u{1b}';
                        }
                    }
                    _ => {}
                }
                continue;
            }

            if !ch.is_whitespace() {
                return true;
            }
        }
        false
    }

    /// Sample-rate grid invariant check, called every
    /// `INVARIANT_CHECK_PERIOD` `processor.advance` calls. Walks the
    /// visible viewport (not full scrollback — too expensive at this
    /// rate) and surfaces violations that indicate cursor / wide-char
    /// state corruption. Each violation logs at most once per terminal
    /// (via the `advance_counter` value as a coarse rate-limit) so heavy
    /// streams don't flood the log.
    ///
    /// Invariants checked:
    ///   1. Cursor `line × column` within `[0, screen_lines) × [0, cols)`.
    ///   2. No `WIDE_CHAR_SPACER` cell at column 0 of any row (orphan —
    ///      the leading half it pairs with would have to be on the
    ///      previous row, which alacritty doesn't model).
    ///   3. Every `LEADING_WIDE_CHAR_SPACER` cell is immediately followed
    ///      by a `WIDE_CHAR_SPACER` cell (the second half of the wide
    ///      char's display).
    ///
    /// Designed to surface bugs in our pipeline (graphics interceptor,
    /// reader pool, replay paths) rather than alacritty's parser, which
    /// is well-tested.
    fn check_grid_invariants(
        terminal_id: u64,
        term: &Term<Chau7EventListener>,
        last_chunk_bytes: usize,
    ) {
        let grid = term.grid();
        let cols = grid.columns();
        let screen_lines = grid.screen_lines();
        let cursor = grid.cursor.point;
        let cursor_line = cursor.line.0;
        let cursor_col = cursor.column.0;

        if cursor_line < 0 || (cursor_line as usize) >= screen_lines {
            warn!(
                "[terminal-{}] grid_invariant: cursor line {} outside [0, {}) (cols={}, last_chunk={}B)",
                terminal_id, cursor_line, screen_lines, cols, last_chunk_bytes
            );
            return; // skip cell-flag walk if cursor is off — likely cascade follows
        }
        if cursor_col >= cols {
            warn!(
                "[terminal-{}] grid_invariant: cursor col {} outside [0, {}) (line={}, last_chunk={}B)",
                terminal_id, cursor_col, cols, cursor_line, last_chunk_bytes
            );
            return;
        }

        for row in 0..(screen_lines as i32) {
            let line = Line(row);
            let grid_line = &grid[line];
            for col in 0..cols {
                let cell = &grid_line[Column(col)];
                if cell.flags.contains(CellFlags::WIDE_CHAR_SPACER) && col == 0 {
                    warn!(
                        "[terminal-{}] grid_invariant: orphan WIDE_CHAR_SPACER at row {} col 0 (last_chunk={}B)",
                        terminal_id, row, last_chunk_bytes
                    );
                    return; // first violation is enough — return to keep log volume bounded
                }
                if cell.flags.contains(CellFlags::LEADING_WIDE_CHAR_SPACER) {
                    if col + 1 >= cols {
                        warn!(
                            "[terminal-{}] grid_invariant: LEADING_WIDE_CHAR_SPACER at row {} col {} but no successor cell (cols={}, last_chunk={}B)",
                            terminal_id, row, col, cols, last_chunk_bytes
                        );
                        return;
                    }
                    let next = &grid_line[Column(col + 1)];
                    if !next.flags.contains(CellFlags::WIDE_CHAR_SPACER) {
                        warn!(
                            "[terminal-{}] grid_invariant: LEADING_WIDE_CHAR_SPACER at row {} col {} not followed by WIDE_CHAR_SPACER (next flags={:?}, last_chunk={}B)",
                            terminal_id, row, col, next.flags, last_chunk_bytes
                        );
                        return;
                    }
                }
            }
        }
    }

    fn grid_line_text(grid: &alacritty_terminal::grid::Grid<Cell>, line: Line) -> (String, bool) {
        let grid_line = &grid[line];
        let line_length = grid_line.line_length();
        let wraps = Self::grid_line_wraps(grid, line);

        let mut text = String::with_capacity(line_length.0);
        for col in 0..line_length.0 {
            let cell = &grid_line[Column(col)];
            if cell
                .flags
                .intersects(CellFlags::WIDE_CHAR_SPACER | CellFlags::LEADING_WIDE_CHAR_SPACER)
            {
                continue;
            }

            text.push(if cell.c == '\u{0}' { ' ' } else { cell.c });
            for ch in cell.zerowidth().into_iter().flatten() {
                text.push(*ch);
            }
        }

        if !wraps {
            while text.ends_with(' ') {
                text.pop();
            }
            text.push('\n');
        }

        (text, wraps)
    }

    fn grid_line_ansi_text(
        grid: &alacritty_terminal::grid::Grid<Cell>,
        line: Line,
        theme: &ThemeColors,
        current_style: &mut Option<AnsiCellStyle>,
        output: &mut String,
    ) -> bool {
        let grid_line = &grid[line];
        let line_length = grid_line.line_length();
        let wraps = Self::grid_line_wraps(grid, line);

        for col in 0..line_length.0 {
            let cell = &grid_line[Column(col)];
            if cell
                .flags
                .intersects(CellFlags::WIDE_CHAR_SPACER | CellFlags::LEADING_WIDE_CHAR_SPACER)
            {
                continue;
            }

            let style = Self::ansi_cell_style(cell, theme);
            if *current_style != Some(style) {
                output.push_str(&Self::ansi_sgr_sequence(style));
                *current_style = Some(style);
            }

            output.push(if cell.c == '\u{0}' { ' ' } else { cell.c });
            for ch in cell.zerowidth().into_iter().flatten() {
                output.push(*ch);
            }
        }

        if !wraps {
            if current_style.is_some() {
                output.push_str("\x1b[0m");
                *current_style = None;
            }
            output.push('\n');
        }

        wraps
    }

    fn ansi_cell_style(cell: &Cell, theme: &ThemeColors) -> AnsiCellStyle {
        let fg_color = Self::effective_cell_fg(cell);
        AnsiCellStyle {
            fg: color_to_rgb_with_theme(fg_color, true, theme),
            bg: color_to_rgb_with_theme(cell.bg, false, theme),
            flags: cell_flags_to_u8(cell.flags),
        }
    }

    fn effective_cell_fg(cell: &Cell) -> AnsiColor {
        if cell.flags.contains(CellFlags::BOLD) {
            match cell.fg {
                AnsiColor::Indexed(idx) if idx < 8 => AnsiColor::Indexed(idx + 8),
                AnsiColor::Named(named) => match named {
                    NamedColor::Black => AnsiColor::Named(NamedColor::BrightBlack),
                    NamedColor::Red => AnsiColor::Named(NamedColor::BrightRed),
                    NamedColor::Green => AnsiColor::Named(NamedColor::BrightGreen),
                    NamedColor::Yellow => AnsiColor::Named(NamedColor::BrightYellow),
                    NamedColor::Blue => AnsiColor::Named(NamedColor::BrightBlue),
                    NamedColor::Magenta => AnsiColor::Named(NamedColor::BrightMagenta),
                    NamedColor::Cyan => AnsiColor::Named(NamedColor::BrightCyan),
                    NamedColor::White => AnsiColor::Named(NamedColor::BrightWhite),
                    _ => cell.fg,
                },
                _ => cell.fg,
            }
        } else {
            cell.fg
        }
    }

    fn ansi_sgr_sequence(style: AnsiCellStyle) -> String {
        let mut codes = vec!["0".to_string()];
        if style.flags & CELL_FLAG_BOLD != 0 {
            codes.push("1".to_string());
        }
        if style.flags & CELL_FLAG_DIM != 0 {
            codes.push("2".to_string());
        }
        if style.flags & CELL_FLAG_ITALIC != 0 {
            codes.push("3".to_string());
        }
        if style.flags & CELL_FLAG_UNDERLINE != 0 {
            codes.push("4".to_string());
        }
        if style.flags & CELL_FLAG_INVERSE != 0 {
            codes.push("7".to_string());
        }
        if style.flags & CELL_FLAG_HIDDEN != 0 {
            codes.push("8".to_string());
        }
        if style.flags & CELL_FLAG_STRIKETHROUGH != 0 {
            codes.push("9".to_string());
        }
        codes.push(format!("38;2;{};{};{}", style.fg.0, style.fg.1, style.fg.2));
        codes.push(format!("48;2;{};{};{}", style.bg.0, style.bg.1, style.bg.2));
        format!("\x1b[{}m", codes.join(";"))
    }

    fn grid_line_wraps(grid: &alacritty_terminal::grid::Grid<Cell>, line: Line) -> bool {
        let grid_line = &grid[line];
        let line_length = grid_line.line_length();
        line_length.0 > 0
            && grid_line[line_length - 1]
                .flags
                .contains(CellFlags::WRAPLINE)
    }

    fn grid_column_utf16_offset(
        grid: &alacritty_terminal::grid::Grid<Cell>,
        line: Line,
        column: usize,
    ) -> usize {
        let grid_line = &grid[line];
        let line_length = grid_line.line_length();
        let upper_bound = column.min(line_length.0);
        let mut count = 0usize;

        for col in 0..upper_bound {
            let cell = &grid_line[Column(col)];
            if cell
                .flags
                .intersects(CellFlags::WIDE_CHAR_SPACER | CellFlags::LEADING_WIDE_CHAR_SPACER)
            {
                continue;
            }

            count += cell.c.len_utf16();
            count += cell.zerowidth().into_iter().flatten().count();
        }

        count
    }

    /// Reset performance metrics
    pub fn reset_metrics(&self) {
        self.metrics.poll_count.store(0, Ordering::Relaxed);
        self.metrics.poll_time_us.store(0, Ordering::Relaxed);
        self.metrics.grid_snapshot_count.store(0, Ordering::Relaxed);
        self.metrics
            .grid_snapshot_time_us
            .store(0, Ordering::Relaxed);
        self.metrics.vte_process_time_us.store(0, Ordering::Relaxed);
        self.metrics.max_poll_time_us.store(0, Ordering::Relaxed);
        self.metrics
            .max_grid_snapshot_time_us
            .store(0, Ordering::Relaxed);
        self.metrics.bytes_batched.store(0, Ordering::Relaxed);
        self.metrics.batch_count.store(0, Ordering::Relaxed);
        self.metrics.idle_polls.store(0, Ordering::Relaxed);
        self.dirty_rows.clear();
        info!("[terminal-{}] Performance metrics reset", self.id);
    }

    /// Get dirty rows for partial updates
    pub fn get_dirty_rows(&self) -> Vec<usize> {
        self.dirty_rows.get_dirty_rows()
    }

    /// Clear dirty row tracking after sync
    pub fn clear_dirty_rows(&self) {
        self.dirty_rows.clear();
    }

    /// Get the current activity level (0-100)
    pub fn activity_level(&self) -> u8 {
        self.adaptive_poller.activity_percent()
    }

    /// Check if poll should be skipped (power saving when very idle)
    pub fn should_skip_poll(&self) -> bool {
        self.adaptive_poller.should_skip_poll()
    }
}

// ============================================================================
// Drop implementation
// ============================================================================

impl Drop for Chau7Terminal {
    fn drop(&mut self) {
        let (sent, received, uptime) = self.stats();
        info!(
            "[terminal-{}] Destroying terminal (uptime: {:?}, sent: {} bytes, received: {} bytes)",
            self.id, uptime, sent, received
        );

        // Close the duplicated master fd used for echo detection without taking
        // the PTY writer lock. Drop can run while a write is backpressured.
        let echo_fd = self.echo_fd.swap(-1, Ordering::AcqRel);
        if echo_fd >= 0 {
            unsafe {
                libc::close(echo_fd);
            }
            debug!(
                "[terminal-{}] Closed echo detection fd {}",
                self.id, echo_fd
            );
        }

        // Signal the shared reader pool to stop monitoring this terminal
        self.running.store(false, Ordering::Release);
        if let Some(fd) = self.reader_pool_fd.take() {
            crate::reader_pool::shared_reader_pool().unregister(fd, self.id);
            debug!(
                "[terminal-{}] Unregistered from reader pool (fd={})",
                self.id, fd
            );
        }

        // Kill the child process to unblock the reader thread.
        // CRITICAL: Do NOT block indefinitely on child.wait() — this runs on
        // whatever thread triggers deallocation (often the main thread via
        // SwiftUI view responder cleanup). A blocking wait here freezes the UI.
        if let Some(mut child) = self.child.lock().take() {
            debug!("[terminal-{}] Killing child process", self.id);
            if let Err(e) = child.kill() {
                debug!("[terminal-{}] Child kill returned: {}", self.id, e);
            }

            // Try a non-blocking check first (try_wait returns immediately)
            match child.try_wait() {
                Ok(Some(status)) => {
                    info!(
                        "[terminal-{}] Child process already exited: {:?}",
                        self.id, status
                    );
                }
                Ok(None) => {
                    // Child hasn't exited yet after kill — wait on a background thread
                    // with a timeout so we never block the caller indefinitely.
                    let id = self.id;
                    std::thread::Builder::new()
                        .name(format!("term-{}-reap", id))
                        .spawn(move || {
                            let start = Instant::now();
                            let timeout = Duration::from_secs(3);
                            loop {
                                match child.try_wait() {
                                    Ok(Some(status)) => {
                                        info!("[terminal-{}] Child reaped after {:?}: {:?}", id, start.elapsed(), status);
                                        return;
                                    }
                                    Ok(None) => {
                                        if start.elapsed() > timeout {
                                            warn!("[terminal-{}] Child did not exit within {:?} after kill, abandoning", id, timeout);
                                            // Let the OS reap it when it eventually exits.
                                            // std::mem::forget(child) would leak — instead just drop
                                            // and let the destructor handle it however it can.
                                            return;
                                        }
                                        std::thread::sleep(Duration::from_millis(10));
                                    }
                                    Err(e) => {
                                        warn!("[terminal-{}] try_wait error: {}", id, e);
                                        return;
                                    }
                                }
                            }
                        })
                        .ok(); // If thread spawn fails, just abandon the child
                }
                Err(e) => {
                    warn!("[terminal-{}] Failed to check child status: {}", self.id, e);
                }
            }
        }

        // No reader thread to join — the shared reader pool handles all PTY reads.

        info!("[terminal-{}] Terminal destroyed", self.id);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn filters_codex_malloc_stack_logging_noise_line() {
        let input = b"before\r\ncodex(67690) MallocStackLogging: can't turn off malloc stack logging because it was not enabled.\r\nafter\n";
        let filtered = filter_terminal_output_noise(input);
        assert_eq!(filtered.as_ref(), b"before\r\nafter\n");
    }

    #[test]
    fn filters_codex_malloc_stack_logging_noise_without_newline() {
        let input = b"codex(67690) MallocStackLogging: can't turn off malloc stack logging because it was not enabled.";
        let filtered = filter_terminal_output_noise(input);
        assert!(filtered.is_empty());
    }

    #[test]
    fn keeps_related_non_matching_output() {
        let input = b"echo codex(67690) MallocStackLogging: can't turn off malloc stack logging because it was not enabled.\n";
        let filtered = filter_terminal_output_noise(input);
        assert_eq!(filtered.as_ref(), input);
    }

    #[test]
    fn echo_detection_does_not_wait_for_pty_handle_lock() {
        let term = Arc::new(Chau7Terminal::new_headless(2, 2).expect("headless terminal"));
        let _held_writer_lock = term.pty_handle.lock();

        let (tx, rx) = std::sync::mpsc::channel();
        let worker_term = Arc::clone(&term);
        std::thread::spawn(move || {
            let _ = worker_term.is_echo_disabled();
            let _ = tx.send(());
        });

        assert!(
            rx.recv_timeout(std::time::Duration::from_millis(200))
                .is_ok(),
            "echo detection must not wait behind the PTY writer lock"
        );
    }

    #[test]
    fn test_grid_snapshot_has_visible_content() {
        let _ = env_logger::try_init();

        // Create terminal with small dimensions
        let term = Chau7Terminal::new_with_env(40, 10, "", &[]).expect("Should create terminal");

        // Wait briefly for shell to start and produce output
        std::thread::sleep(std::time::Duration::from_millis(500));

        // Poll to process any PTY data
        let _changed = term.poll(100);

        // Inject known content: "Hello World" with newline
        term.inject_output(b"Hello World\r\n");

        // Get grid snapshot
        let snapshot = term.get_grid_snapshot();
        assert!(snapshot.cols > 0, "Snapshot should have cols");
        assert!(snapshot.rows > 0, "Snapshot should have rows");
        assert!(
            !snapshot.cells.is_null(),
            "Cells pointer should not be null"
        );

        let total = snapshot.cols as usize * snapshot.rows as usize;
        let cells = unsafe { std::slice::from_raw_parts(snapshot.cells, total) };
        let clusters = if snapshot.clusters_utf8.is_null() {
            &[][..]
        } else {
            unsafe { std::slice::from_raw_parts(snapshot.clusters_utf8, snapshot.clusters_len) }
        };
        let cell_str = |c: &CellData| -> &str {
            if c.cluster_len == 0 {
                return "";
            }
            let start = c.cluster_offset as usize;
            let end = start + c.cluster_len as usize;
            std::str::from_utf8(&clusters[start..end]).unwrap_or("?")
        };

        // Print first row for debugging
        let first_row: String = cells[..snapshot.cols as usize]
            .iter()
            .map(|c| {
                let s = cell_str(c);
                if s.len() == 1 && s.as_bytes()[0].is_ascii_graphic() {
                    s.chars().next().unwrap()
                } else {
                    '.'
                }
            })
            .collect();
        eprintln!("First row chars: {:?}", first_row);

        // Print first few cells with color info
        for (i, c) in cells.iter().enumerate().take(std::cmp::min(12, total)) {
            eprintln!(
                "  cell[{}]: cluster={:?} w={} cont={} fg=({},{},{}) bg=({},{},{}) flags=0x{:02X}",
                i,
                cell_str(c),
                c.width,
                c.continuation,
                c.fg_r,
                c.fg_g,
                c.fg_b,
                c.bg_r,
                c.bg_g,
                c.bg_b,
                c.flags
            );
        }

        // Verify "Hello" appears somewhere in the grid
        let has_h = cells.iter().any(|c| cell_str(c) == "H");
        let has_visible_fg = cells.iter().any(|c| c.fg_r > 0 || c.fg_g > 0 || c.fg_b > 0);

        eprintln!("Has 'H': {}", has_h);
        eprintln!("Has visible fg: {}", has_visible_fg);

        assert!(has_h, "Grid should contain 'H' from injected 'Hello World'");
        assert!(
            has_visible_fg,
            "At least some cells should have non-black foreground"
        );

        // Clean up - reconstruct Vec to free memory
        unsafe {
            let _ = Vec::from_raw_parts(snapshot.cells, total, snapshot.capacity);
            if !snapshot.clusters_utf8.is_null() {
                let _ = Vec::from_raw_parts(
                    snapshot.clusters_utf8,
                    snapshot.clusters_len,
                    snapshot.clusters_capacity,
                );
            }
        }
    }

    #[test]
    fn test_full_buffer_text_preserves_soft_wrapped_logical_lines() {
        let _ = env_logger::try_init();

        let term = Chau7Terminal::new_with_env(5, 4, "", &[]).expect("Should create terminal");
        term.inject_output(b"hello world");

        let text = term.full_buffer_text();

        assert!(
            text.contains("hello world"),
            "Expected wrapped output to remain one logical line, got: {:?}",
            text
        );
        assert!(
            !text.contains("hello\n worl"),
            "Expected no hard newline at soft-wrap boundary, got: {:?}",
            text
        );
    }

    #[test]
    fn test_full_buffer_ansi_text_preserves_sgr_attributes() {
        let _ = env_logger::try_init();

        let term = Chau7Terminal::new_with_env(20, 4, "", &[]).expect("Should create terminal");
        term.inject_output(b"\x1b[31mred\x1b[0m plain");

        let plain = term.full_buffer_text();
        let ansi = term.full_buffer_ansi_text();

        assert!(plain.contains("red plain"));
        assert!(!plain.contains('\u{1b}'));
        assert!(ansi.contains("red"));
        assert!(
            ansi.contains("\u{1b}[") && ansi.contains("38;2;"),
            "Expected ANSI SGR truecolor styling in export, got: {:?}",
            ansi
        );
    }

    #[test]
    fn test_tail_buffer_ansi_text_limits_logical_lines() {
        let _ = env_logger::try_init();

        let term = Chau7Terminal::new_with_env(40, 4, "", &[]).expect("Should create terminal");
        term.inject_output(b"one\ntwo\nthree\nfour\nfive\n");

        let tail = term.tail_buffer_ansi_text(2, 4096);

        assert!(
            !tail.contains("one"),
            "Expected old line to be trimmed: {:?}",
            tail
        );
        assert!(
            !tail.contains("two"),
            "Expected old line to be trimmed: {:?}",
            tail
        );
        assert!(
            tail.contains("four"),
            "Expected recent line in tail: {:?}",
            tail
        );
        assert!(
            tail.contains("five"),
            "Expected recent line in tail: {:?}",
            tail
        );
    }

    #[test]
    fn test_tail_buffer_ansi_text_preserves_sgr_attributes() {
        let _ = env_logger::try_init();

        let term = Chau7Terminal::new_with_env(40, 4, "", &[]).expect("Should create terminal");
        term.inject_output(b"plain\n\x1b[31mred tail\x1b[0m\n");

        let tail = term.tail_buffer_ansi_text(1, 4096);

        assert!(!tail.contains("plain"));
        assert!(tail.contains("red tail"));
        assert!(
            tail.contains("\u{1b}[") && tail.contains("38;2;"),
            "Expected ANSI SGR truecolor styling in tail export, got: {:?}",
            tail
        );
    }

    #[test]
    fn test_tail_buffer_ansi_text_limits_bytes_on_char_boundary() {
        let _ = env_logger::try_init();

        let term = Chau7Terminal::new_with_env(80, 4, "", &[]).expect("Should create terminal");
        term.inject_output("alpha beta gamma delta epsilon 😀\n".as_bytes());

        let tail = term.tail_buffer_ansi_text(10, 32);

        assert!(
            tail.len() <= 32,
            "Expected bounded tail to stay within max bytes, got {} bytes: {:?}",
            tail.len(),
            tail
        );
        assert!(tail.is_char_boundary(tail.len()));
    }

    #[test]
    fn test_logical_line_text_returns_wrapped_text_and_clicked_offset() {
        let _ = env_logger::try_init();

        let term = Chau7Terminal::new_with_env(5, 4, "", &[]).expect("Should create terminal");
        term.inject_output(b"docs/readme.md");

        let (text, start_row, clicked_offset) = term
            .logical_line_text(1, 2)
            .expect("Expected wrapped logical line");

        assert_eq!(text, "docs/readme.md");
        assert_eq!(start_row, 0);
        assert_eq!(clicked_offset, 7);
    }

    #[test]
    fn test_logical_line_text_uses_utf16_offset_for_combining_sequences() {
        let _ = env_logger::try_init();

        let term = Chau7Terminal::new_with_env(20, 4, "", &[]).expect("Should create terminal");
        term.inject_output("e\u{301}docs/readme.md".as_bytes());

        let (text, start_row, clicked_offset) =
            term.logical_line_text(0, 2).expect("Expected logical line");

        assert_eq!(text, "e\u{301}docs/readme.md");
        assert_eq!(start_row, 0);
        assert_eq!(clicked_offset, 3);
    }

    // ======================================================================
    // Escape Sequence Conformance Tests (vttest/esctest equivalent)
    // ======================================================================
    //
    // These tests feed standard escape sequences into the terminal and verify
    // the resulting grid state. They serve as a lightweight alternative to
    // running the full vttest/esctest suites.

    /// Helper: extract text from row 0 of a terminal
    fn row_text(term: &Chau7Terminal, row: usize) -> String {
        let t = term.term.lock();
        let grid = t.grid();
        let cols = grid.columns();
        let line = Line(row as i32);
        (0..cols)
            .map(|c| {
                let cell = &grid[line][Column(c)];
                let ch = cell.c;
                if ch == ' ' || ch == '\0' { ' ' } else { ch }
            })
            .collect::<String>()
            .trim_end()
            .to_string()
    }

    /// Helper: get cursor position (col, row) — 0-indexed
    fn cursor_pos(term: &Chau7Terminal) -> (usize, usize) {
        let t = term.term.lock();
        let point = t.grid().cursor.point;
        (point.column.0, point.line.0 as usize)
    }

    #[test]
    fn test_csi_cursor_up() {
        let _ = env_logger::try_init();
        let term = Chau7Terminal::new_with_env(20, 10, "", &[]).expect("create");
        // Move to row 5, then cursor up 3
        term.inject_output(b"\x1b[6;1H"); // Move to row 6, col 1
        term.inject_output(b"\x1b[3A"); // Cursor up 3
        let (_, row) = cursor_pos(&term);
        assert_eq!(row, 2, "CUU 3 from row 5 should land on row 2");
    }

    #[test]
    fn test_csi_cursor_down() {
        let _ = env_logger::try_init();
        let term = Chau7Terminal::new_with_env(20, 10, "", &[]).expect("create");
        term.inject_output(b"\x1b[1;1H"); // Home
        term.inject_output(b"\x1b[4B"); // Cursor down 4
        let (_, row) = cursor_pos(&term);
        assert_eq!(row, 4, "CUD 4 from row 0 should land on row 4");
    }

    #[test]
    fn test_csi_cursor_forward_backward() {
        let _ = env_logger::try_init();
        let term = Chau7Terminal::new_with_env(20, 10, "", &[]).expect("create");
        term.inject_output(b"\x1b[1;1H"); // Home
        term.inject_output(b"\x1b[10C"); // Forward 10
        let (col, _) = cursor_pos(&term);
        assert_eq!(col, 10, "CUF 10 from col 0 should land on col 10");

        term.inject_output(b"\x1b[3D"); // Back 3
        let (col, _) = cursor_pos(&term);
        assert_eq!(col, 7, "CUB 3 from col 10 should land on col 7");
    }

    #[test]
    fn test_csi_erase_in_display() {
        let _ = env_logger::try_init();
        let term = Chau7Terminal::new_with_env(20, 5, "", &[]).expect("create");
        term.inject_output(b"AAAA\r\nBBBB\r\nCCCC");
        // Erase from cursor to end of display
        term.inject_output(b"\x1b[2;1H"); // Move to row 2, col 1
        term.inject_output(b"\x1b[0J"); // Erase below
        let _row2 = row_text(&term, 1);
        // Row 1 (0-indexed) should still have content (cursor is ON this row)
        // Row 2+ should be cleared
        let row3 = row_text(&term, 2);
        assert!(
            row3.trim().is_empty(),
            "Row below cursor should be cleared after ED 0, got: {:?}",
            row3
        );
    }

    #[test]
    fn test_csi_erase_in_line() {
        let _ = env_logger::try_init();
        let term = Chau7Terminal::new_with_env(20, 5, "", &[]).expect("create");
        term.inject_output(b"Hello World");
        term.inject_output(b"\x1b[1;6H"); // Move to col 6 (the W)
        term.inject_output(b"\x1b[0K"); // Erase to end of line
        let text = row_text(&term, 0);
        assert_eq!(
            text, "Hello",
            "EL 0 should erase from cursor to end of line"
        );
    }

    #[test]
    fn test_csi_absolute_position() {
        let _ = env_logger::try_init();
        let term = Chau7Terminal::new_with_env(20, 10, "", &[]).expect("create");
        term.inject_output(b"\x1b[5;8H"); // Row 5, Col 8 (1-indexed)
        let (col, row) = cursor_pos(&term);
        assert_eq!(row, 4, "CUP row should be 4 (0-indexed from 5)");
        assert_eq!(col, 7, "CUP col should be 7 (0-indexed from 8)");
    }

    #[test]
    fn test_sgr_colors_applied() {
        let _ = env_logger::try_init();
        let term = Chau7Terminal::new_with_env(20, 5, "", &[]).expect("create");
        // Write with red foreground (SGR 31)
        term.inject_output(b"\x1b[31mRED\x1b[0m");
        let snapshot = term.get_grid_snapshot();
        let total = snapshot.cols as usize * snapshot.rows as usize;
        let cells = unsafe { std::slice::from_raw_parts(snapshot.cells, total) };
        let clusters =
            unsafe { std::slice::from_raw_parts(snapshot.clusters_utf8, snapshot.clusters_len) };
        // First cell 'R' should have red foreground
        let r_cell = &cells[0];
        let r_start = r_cell.cluster_offset as usize;
        let r_end = r_start + r_cell.cluster_len as usize;
        assert_eq!(&clusters[r_start..r_end], b"R");
        // Red in default 16-color palette is typically (205, 49, 49) or similar
        assert!(
            r_cell.fg_r > 150,
            "Red text should have high fg_r, got {}",
            r_cell.fg_r
        );
        unsafe {
            let _ = Vec::from_raw_parts(snapshot.cells, total, snapshot.capacity);
        }
    }

    #[test]
    fn test_osc_title() {
        let _ = env_logger::try_init();
        let term = Chau7Terminal::new_with_env(20, 5, "", &[]).expect("create");
        // OSC 0 sets the terminal title. The VTE processor parses this and
        // dispatches a Title event. Verify the escape doesn't leak into the
        // grid text (the VTE processor correctly consumed it).
        term.inject_output(b"\x1b]0;My Custom Title\x07Visible");
        let text = term.full_buffer_text();
        assert!(text.contains("Visible"), "Text after OSC should be visible");
        assert!(
            !text.contains("My Custom Title"),
            "OSC payload should NOT appear in grid text"
        );
    }

    #[test]
    fn test_alternate_screen() {
        let _ = env_logger::try_init();
        let term = Chau7Terminal::new_with_env(20, 5, "", &[]).expect("create");
        term.inject_output(b"\x1b[HMain Screen");
        let before = row_text(&term, 0);
        assert!(
            before.contains("Main Screen"),
            "Initial content, got: {:?}",
            before
        );

        // Switch to alternate screen and write content
        assert!(!term.is_alternate_screen_active());
        term.inject_output(b"\x1b[?1049h");
        assert!(term.is_alternate_screen_active());
        term.inject_output(b"\x1b[HAlt Screen");

        // Switch back — main screen content should be restored.
        // The alternate screen content ("Alt Screen") is discarded.
        term.inject_output(b"\x1b[?1049l");
        assert!(!term.is_alternate_screen_active());
        let after = row_text(&term, 0);
        assert!(
            after.contains("Main Screen"),
            "Restoring from alt screen should show original content, got: {:?}",
            after
        );
    }

    #[test]
    fn test_scroll_region() {
        let _ = env_logger::try_init();
        let term = Chau7Terminal::new_with_env(20, 10, "", &[]).expect("create");
        // Set scroll region to rows 3-7 (1-indexed)
        term.inject_output(b"\x1b[3;7r");
        // Fill rows
        for i in 0..10 {
            term.inject_output(format!("\x1b[{};1H{}", i + 1, (b'A' + i) as char).as_bytes());
        }
        // Scroll within region by adding lines at the bottom
        term.inject_output(b"\x1b[7;1H\n\n");
        // Row outside scroll region (row 1) should be unchanged
        let row1 = row_text(&term, 0);
        assert!(
            row1.starts_with('A'),
            "Row outside scroll region should be preserved, got: {:?}",
            row1
        );
    }

    #[test]
    fn test_utf8_wide_characters() {
        let _ = env_logger::try_init();
        let term = Chau7Terminal::new_with_env(20, 5, "", &[]).expect("create");
        term.inject_output("你好世界".as_bytes());
        let text = term.full_buffer_text();
        assert!(
            text.contains("你好世界"),
            "CJK characters should render correctly"
        );
    }

    #[test]
    fn test_bracketed_paste_mode() {
        let _ = env_logger::try_init();
        let term = Chau7Terminal::new_with_env(20, 5, "", &[]).expect("create");
        // Enable bracketed paste mode
        term.inject_output(b"\x1b[?2004h");
        assert!(
            term.is_bracketed_paste_mode(),
            "Bracketed paste mode should be enabled"
        );
        // Disable
        term.inject_output(b"\x1b[?2004l");
        assert!(
            !term.is_bracketed_paste_mode(),
            "Bracketed paste mode should be disabled"
        );
    }

    #[test]
    fn test_insert_delete_characters() {
        let _ = env_logger::try_init();
        let term = Chau7Terminal::new_with_env(20, 5, "", &[]).expect("create");
        term.inject_output(b"ABCDEF");
        term.inject_output(b"\x1b[1;3H"); // Move to col 3
        term.inject_output(b"\x1b[2P"); // Delete 2 characters
        let text = row_text(&term, 0);
        assert_eq!(
            text, "ABEF",
            "DCH 2 at col 2 should delete 'CD', got: {:?}",
            text
        );
    }

    #[test]
    fn test_tab_stops() {
        let _ = env_logger::try_init();
        let term = Chau7Terminal::new_with_env(40, 5, "", &[]).expect("create");
        term.inject_output(b"\x1b[1;1H"); // Home
        term.inject_output(b"\t"); // Tab to first stop (col 8)
        let (col, _) = cursor_pos(&term);
        assert_eq!(col, 8, "First tab stop should be at col 8, got {}", col);
    }

    /// Helper: snapshot the grid and return (cell at row r col c, its cluster as &str,
    /// and the continuation cell to the right if any). Used by grapheme round-trip tests.
    fn snapshot_cell_str(term: &Chau7Terminal, row: usize, col: usize) -> (String, u8, u8) {
        let snap = term.get_grid_snapshot();
        let total = snap.cols as usize * snap.rows as usize;
        let cells = unsafe { std::slice::from_raw_parts(snap.cells, total) };
        let clusters = if snap.clusters_utf8.is_null() {
            &[][..]
        } else {
            unsafe { std::slice::from_raw_parts(snap.clusters_utf8, snap.clusters_len) }
        };
        let idx = row * snap.cols as usize + col;
        let c = &cells[idx];
        let s = if c.cluster_len == 0 {
            String::new()
        } else {
            let start = c.cluster_offset as usize;
            String::from_utf8_lossy(&clusters[start..start + c.cluster_len as usize]).into_owned()
        };
        let (width, cont) = (c.width, c.continuation);
        unsafe {
            let _ = Vec::from_raw_parts(snap.cells, total, snap.capacity);
            if !snap.clusters_utf8.is_null() {
                let _ = Vec::from_raw_parts(
                    snap.clusters_utf8,
                    snap.clusters_len,
                    snap.clusters_capacity,
                );
            }
        }
        (s, width, cont)
    }

    #[test]
    fn grapheme_ascii_survives_snapshot() {
        let term = Chau7Terminal::new_with_env(10, 2, "", &[]).expect("create");
        term.inject_output(b"A");
        let (s, w, cont) = snapshot_cell_str(&term, 0, 0);
        assert_eq!(s, "A");
        assert_eq!(w, 1);
        assert_eq!(cont, 0);
    }

    #[test]
    fn grapheme_nfd_e_acute_normalizes_to_nfc() {
        // "e" + U+0301 (combining acute) → NFC "é"
        let term = Chau7Terminal::new_with_env(10, 2, "", &[]).expect("create");
        term.inject_output("e\u{0301}".as_bytes());
        let (s, w, cont) = snapshot_cell_str(&term, 0, 0);
        assert_eq!(s, "é");
        assert_eq!(w, 1);
        assert_eq!(cont, 0);
    }

    #[test]
    fn grapheme_emoji_vs16_survives() {
        // ❤ + VS16 (U+FE0F) → emoji-presentation heart
        let term = Chau7Terminal::new_with_env(10, 2, "", &[]).expect("create");
        term.inject_output("\u{2764}\u{FE0F}".as_bytes());
        let (s, _w, cont) = snapshot_cell_str(&term, 0, 0);
        assert_eq!(s, "\u{2764}\u{FE0F}", "VS16 must survive the snapshot");
        assert_eq!(cont, 0);
    }

    #[test]
    fn grapheme_regional_indicator_flag_survives() {
        // 🇫🇷 = Regional Indicator F + R. One grapheme, but Alacritty assigns the
        // pair to two columns (each RI is itself a 2-wide codepoint). The first
        // cell carries the flag bytes; we just verify the bytes round-trip.
        let term = Chau7Terminal::new_with_env(10, 2, "", &[]).expect("create");
        term.inject_output("\u{1F1EB}\u{1F1F7}".as_bytes());
        let (s, _w, _cont) = snapshot_cell_str(&term, 0, 0);
        assert!(
            s.starts_with('\u{1F1EB}'),
            "First RI must survive intact, got {:?}",
            s
        );
    }

    #[test]
    fn grapheme_zwj_family_emoji_survives() {
        // 👨🏽‍💻 = U+1F468 U+1F3FD U+200D U+1F4BB (4 codepoints, single grapheme).
        // Alacritty's cell model puts each wide codepoint in its own cell pair;
        // zero-width chars (ZWJ) attach to the preceding cell. We verify all four
        // codepoints survive *somewhere* on the row — none are silently dropped.
        let term = Chau7Terminal::new_with_env(10, 2, "", &[]).expect("create");
        term.inject_output("\u{1F468}\u{1F3FD}\u{200D}\u{1F4BB}".as_bytes());
        let snap = term.get_grid_snapshot();
        let total = snap.cols as usize * snap.rows as usize;
        let cells = unsafe { std::slice::from_raw_parts(snap.cells, total) };
        let clusters = unsafe { std::slice::from_raw_parts(snap.clusters_utf8, snap.clusters_len) };
        let mut row0 = String::new();
        for c in cells.iter().take(snap.cols as usize) {
            if c.cluster_len > 0 {
                let start = c.cluster_offset as usize;
                row0.push_str(
                    std::str::from_utf8(&clusters[start..start + c.cluster_len as usize]).unwrap(),
                );
            }
        }
        unsafe {
            let _ = Vec::from_raw_parts(snap.cells, total, snap.capacity);
            let _ = Vec::from_raw_parts(
                snap.clusters_utf8,
                snap.clusters_len,
                snap.clusters_capacity,
            );
        }
        assert!(row0.contains('\u{1F468}'), "man codepoint lost: {:?}", row0);
        assert!(row0.contains('\u{1F3FD}'), "skin-tone lost: {:?}", row0);
        assert!(row0.contains('\u{200D}'), "ZWJ lost: {:?}", row0);
        assert!(row0.contains('\u{1F4BB}'), "laptop lost: {:?}", row0);
    }

    #[test]
    fn grapheme_wide_char_marks_continuation_cell() {
        // CJK char is wide → cell 0 has width=2, cell 1 has continuation=1, len=0.
        let term = Chau7Terminal::new_with_env(10, 2, "", &[]).expect("create");
        term.inject_output("中".as_bytes());
        let (s0, w0, c0) = snapshot_cell_str(&term, 0, 0);
        let (s1, w1, c1) = snapshot_cell_str(&term, 0, 1);
        assert_eq!(s0, "中");
        assert_eq!(w0, 2);
        assert_eq!(c0, 0);
        assert_eq!(s1, "", "continuation cell must have empty cluster");
        assert_eq!(w1, 0);
        assert_eq!(c1, 1);
    }
}
