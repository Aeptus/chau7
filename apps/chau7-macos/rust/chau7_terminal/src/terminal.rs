//! Core terminal emulator: Chau7Terminal struct, PTY management, and terminal operations.

use std::collections::HashMap;
use std::io::{Read, Write};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

use alacritty_terminal::event::Event;
use alacritty_terminal::grid::Dimensions;
use alacritty_terminal::index::{Column, Line, Point, Side};
use alacritty_terminal::selection::{Selection, SelectionType};
use alacritty_terminal::term::cell::{Flags as CellFlags, LineLength};
use alacritty_terminal::term::{Config as TermConfig, Term, TermMode};
use alacritty_terminal::vte::ansi::{Color as AnsiColor, NamedColor, Processor};
use crossbeam_channel::{Receiver, TryRecvError, bounded};
use log::{debug, error, info, trace, warn};
use parking_lot::{Mutex, RwLock};
use portable_pty::{CommandBuilder, PtySize, native_pty_system};

use crate::color::{ThemeColors, color_to_rgb_with_theme};
use crate::graphics;
use crate::metrics::{AdaptivePoller, DirtyRowTracker};
use crate::pool::get_cell_buffer_pool;
use crate::pty::{Chau7EventListener, PtyHandle, PtyMessage, SizeInfo};
use crate::types::{
    CellData, DebugState, GridSnapshot, PerformanceMetrics, cell_flags_to_u8, underline_style,
};

/// Static counter for terminal IDs (for logging)
static TERMINAL_COUNTER: AtomicU64 = AtomicU64::new(0);

/// Type alias for the clipboard load formatter function.
type ClipboardLoadFormatter = Arc<dyn Fn(&str) -> String + Sync + Send>;

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
    /// PTY handle for writing input
    pub(crate) pty_handle: Mutex<PtyHandle>,
    /// Child process handle (to avoid zombies)
    pub(crate) child: Mutex<Option<Box<dyn portable_pty::Child + Send + Sync>>>,
    /// Shell process ID (for dev server monitoring)
    pub(crate) shell_pid: AtomicU64,
    /// Channel receiver for PTY output data
    pub(crate) pty_rx: Receiver<PtyMessage>,
    /// Flag to signal the reader thread to stop
    pub(crate) running: Arc<AtomicBool>,
    /// Reader thread handle
    pub(crate) reader_thread: Option<JoinHandle<()>>,
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

    // Performance optimization structures
    /// Adaptive polling rate controller
    pub(crate) adaptive_poller: AdaptivePoller,
    /// Dirty row tracker for partial updates
    pub(crate) dirty_rows: DirtyRowTracker,

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

        // Get reader for PTY output
        let mut reader = pair.master.try_clone_reader().map_err(|e| {
            error!("[terminal-{}] Failed to clone PTY reader: {}", id, e);
            TerminalError::PtyCloneReader(e.into())
        })?;
        debug!("[terminal-{}] PTY reader cloned", id);

        // Get writer for PTY input
        let writer = pair.master.take_writer().map_err(|e| {
            error!("[terminal-{}] Failed to get PTY writer: {}", id, e);
            TerminalError::PtyWriter(e.into())
        })?;
        debug!("[terminal-{}] PTY writer obtained", id);

        // Create running flag for the reader thread
        let running = Arc::new(AtomicBool::new(true));
        let running_clone = running.clone();
        let thread_terminal_id = id;

        // Create channel for PTY data
        let (pty_tx, pty_rx) = bounded::<PtyMessage>(256);

        // Spawn reader thread
        info!("[terminal-{}] Spawning PTY reader thread", id);
        let reader_thread = thread::Builder::new()
            .name(format!("pty-reader-{}", id))
            .spawn(move || {
                debug!(
                    "[terminal-{}] PTY reader thread started",
                    thread_terminal_id
                );
                let mut buf = [0u8; 8192];
                let mut total_bytes = 0u64;

                while running_clone.load(Ordering::Acquire) {
                    match reader.read(&mut buf) {
                        Ok(0) => {
                            info!(
                                "[terminal-{}] PTY EOF received (total bytes read: {})",
                                thread_terminal_id, total_bytes
                            );
                            let _ = pty_tx.send(PtyMessage::Closed);
                            break;
                        }
                        Ok(n) => {
                            total_bytes += n as u64;
                            // Log first few reads at info level to debug startup output
                            if total_bytes <= 4096 {
                                let preview: String = buf[..n]
                                    .iter()
                                    .take(200)
                                    .map(|&b| {
                                        if (32..127).contains(&b) {
                                            b as char
                                        } else {
                                            '.'
                                        }
                                    })
                                    .collect();
                                info!(
                                    "[terminal-{}] PTY startup read {} bytes: {:?}",
                                    thread_terminal_id, n, preview
                                );
                            } else {
                                trace!(
                                    "[terminal-{}] PTY read {} bytes (total: {})",
                                    thread_terminal_id, n, total_bytes
                                );
                            }
                            let data = buf[..n].to_vec();
                            if pty_tx.send(PtyMessage::Data(data)).is_err() {
                                warn!(
                                    "[terminal-{}] PTY channel closed, exiting reader",
                                    thread_terminal_id
                                );
                                break;
                            }
                        }
                        Err(e) => {
                            // Check if this is just because the PTY was closed
                            if running_clone.load(Ordering::Acquire) {
                                error!(
                                    "[terminal-{}] PTY read error: {} (total bytes read: {})",
                                    thread_terminal_id, e, total_bytes
                                );
                            } else {
                                debug!(
                                    "[terminal-{}] PTY read interrupted during shutdown",
                                    thread_terminal_id
                                );
                            }
                            let _ = pty_tx.send(PtyMessage::Closed);
                            break;
                        }
                    }
                }
                info!(
                    "[terminal-{}] PTY reader thread exiting",
                    thread_terminal_id
                );
            })
            .map_err(|e| {
                error!("[terminal-{}] Failed to spawn reader thread: {}", id, e);
                TerminalError::ReaderThread(e)
            })?;

        // Create the PTY handle
        let pty_handle = PtyHandle {
            writer,
            _master: pair.master,
            master_fd,
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
            write_errors: AtomicU64::new(0),
            theme_colors: RwLock::new(ThemeColors::default()),
            last_output: Mutex::new(Vec::new()),
            bell_pending,
            metrics: PerformanceMetrics::default(),
            pending_title: Mutex::new(None),
            has_pending_title: AtomicBool::new(false),
            pending_exit_code: Mutex::new(None),
            pty_closed: AtomicBool::new(false),
            // Hyperlinks (OSC 8) — index 0 reserved for "no link"
            link_urls: Mutex::new(vec![String::new()]),
            // Clipboard (OSC 52)
            pending_clipboard_store: Mutex::new(None),
            has_pending_clipboard_store: AtomicBool::new(false),
            pending_clipboard_load: Mutex::new(None),
            has_pending_clipboard_load: AtomicBool::new(false),
            // Performance optimizations
            adaptive_poller: AdaptivePoller::new(),
            dirty_rows: DirtyRowTracker::new(rows as usize),
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
        let handle = self.pty_handle.lock();
        if handle.master_fd < 0 {
            // fd capture failed at creation time, can't check
            return false;
        }
        unsafe {
            let mut termios: libc::termios = std::mem::zeroed();
            if libc::tcgetattr(handle.master_fd, &mut termios) == 0 {
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

        // Try to receive data with timeout for the first message
        match self.pty_rx.recv_timeout(timeout) {
            Ok(PtyMessage::Data(data)) => {
                bytes_this_poll += data.len();
                local_output.extend_from_slice(&data);
                self.process_pty_data(&data);
                had_data = true;
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
            match self.pty_rx.try_recv() {
                Ok(PtyMessage::Data(data)) => {
                    bytes_this_poll += data.len();
                    local_output.extend_from_slice(&data);
                    self.process_pty_data(&data);
                    had_data = true;
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

        let (passthrough_owned, events) = {
            let mut interceptor = self.graphics_interceptor.lock();
            interceptor.feed_owned(data)
            // Lock dropped here — passthrough_owned is an owned Vec, no borrow.
        };

        if !passthrough_owned.is_empty() {
            let mut term = self.term.lock();
            let mut processor = self.processor.lock();
            processor.advance(&mut *term, &passthrough_owned);
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
        let (mut cells, cols, rows, display_offset, history_size, link_url_vec, cursor_visible) = {
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

                    let character = cell.c as u32;

                    let is_bold = cell.flags.contains(CellFlags::BOLD);

                    // Bold brightening: when a cell is bold and has a standard
                    // ANSI foreground color (indices 0-7), promote it to the
                    // corresponding bright variant (8-15).  This matches the
                    // traditional xterm convention used by SwiftTerm and most
                    // other terminals.  Without this, CLI tools that rely on
                    // bold+color (e.g. Claude Code, Codex) appear too dim.
                    let fg_color = if is_bold {
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
                    };

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
                        character,
                        fg_r,
                        fg_g,
                        fg_b,
                        bg_r,
                        bg_g,
                        bg_b,
                        flags,
                        _pad: underline_style(cell.flags),
                        link_id,
                    });
                }
            }

            // term lock is dropped at the end of this block
            (
                cells,
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
            avg_poll_time_us: if poll_count > 0 {
                poll_time / poll_count
            } else {
                0
            },
            max_poll_time_us: self.metrics.max_poll_time_us.load(Ordering::Relaxed),
            avg_grid_snapshot_time_us: if grid_count > 0 {
                grid_time / grid_count
            } else {
                0
            },
            max_grid_snapshot_time_us: self
                .metrics
                .max_grid_snapshot_time_us
                .load(Ordering::Relaxed),
            activity_percent: self.adaptive_poller.activity_percent(),
            idle_polls,
            avg_batch_size: if batch_count > 0 {
                bytes_batched / batch_count
            } else {
                0
            },
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

    fn grid_line_text(
        grid: &alacritty_terminal::grid::Grid<alacritty_terminal::term::Cell>,
        line: Line,
    ) -> (String, bool) {
        let grid_line = &grid[line];
        let line_length = grid_line.line_length();
        let wraps = Self::grid_line_wraps(grid, line);

        let mut text = String::with_capacity(line_length.0);
        for col in 0..line_length.0 {
            let cell = &grid_line[Column(col)];
            if cell.flags.intersects(
                CellFlags::WIDE_CHAR_SPACER | CellFlags::LEADING_WIDE_CHAR_SPACER,
            ) {
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

    fn grid_line_wraps(
        grid: &alacritty_terminal::grid::Grid<alacritty_terminal::term::Cell>,
        line: Line,
    ) -> bool {
        let grid_line = &grid[line];
        let line_length = grid_line.line_length();
        line_length.0 > 0 && grid_line[line_length - 1].flags.contains(CellFlags::WRAPLINE)
    }

    fn grid_column_utf16_offset(
        grid: &alacritty_terminal::grid::Grid<alacritty_terminal::term::Cell>,
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

        // Close the duplicated master fd used for echo detection
        let handle = self.pty_handle.lock();
        if handle.master_fd >= 0 {
            unsafe {
                libc::close(handle.master_fd);
            }
            debug!(
                "[terminal-{}] Closed echo detection fd {}",
                self.id, handle.master_fd
            );
        }
        drop(handle);

        // Signal the reader thread to stop
        self.running.store(false, Ordering::Release);
        debug!("[terminal-{}] Signaled reader thread to stop", self.id);

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

        // Join the reader thread on a background thread so we don't block the caller.
        // The reader should exit promptly since we set running=false and killed the child,
        // but we won't risk blocking the main thread if it doesn't.
        if let Some(handle) = self.reader_thread.take() {
            let id = self.id;
            debug!(
                "[terminal-{}] Spawning background thread to join reader",
                id
            );
            std::thread::Builder::new()
                .name(format!("term-{}-join", id))
                .spawn(move || {
                    let start = Instant::now();
                    match handle.join() {
                        Ok(()) => {
                            debug!(
                                "[terminal-{}] Reader thread joined in {:?}",
                                id,
                                start.elapsed()
                            );
                        }
                        Err(e) => {
                            error!("[terminal-{}] Reader thread panicked: {:?}", id, e);
                        }
                    }
                })
                .ok();
        }

        info!("[terminal-{}] Terminal destroyed", self.id);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

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

        // Print first row for debugging
        let first_row: String = cells[..snapshot.cols as usize]
            .iter()
            .map(|c| {
                if c.character >= 32 && c.character < 127 {
                    char::from_u32(c.character).unwrap_or('?')
                } else {
                    '.'
                }
            })
            .collect();
        eprintln!("First row chars: {:?}", first_row);

        // Print first few cells with color info
        for (i, c) in cells.iter().enumerate().take(std::cmp::min(12, total)) {
            eprintln!(
                "  cell[{}]: char=U+{:04X} ({}) fg=({},{},{}) bg=({},{},{}) flags=0x{:02X}",
                i,
                c.character,
                if (32..127).contains(&c.character) {
                    char::from_u32(c.character).unwrap_or('?')
                } else {
                    '.'
                },
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
        let has_h = cells.iter().any(|c| c.character == b'H' as u32);
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

        let (text, start_row, clicked_offset) = term
            .logical_line_text(0, 2)
            .expect("Expected logical line");

        assert_eq!(text, "e\u{301}docs/readme.md");
        assert_eq!(start_row, 0);
        assert_eq!(clicked_offset, 3);
    }
}
