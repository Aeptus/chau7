//! PTY management: handle wrapper, message types, event listener, dimensions.

use std::io::Write;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};

use alacritty_terminal::event::{Event, EventListener};
use alacritty_terminal::grid::Dimensions;
use crossbeam_channel::Sender;
use log::{debug, trace};
use portable_pty::PtySize;

// ============================================================================
// Terminal dimensions
// ============================================================================

pub struct SizeInfo {
    pub cols: usize,
    pub rows: usize,
}

impl SizeInfo {
    pub fn new(cols: usize, rows: usize) -> Self {
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
// PTY message types
// ============================================================================

pub enum PtyMessage {
    Data(Vec<u8>),
    Closed,
}

// ============================================================================
// PTY writer wrapper
// ============================================================================

/// Wrapper that holds both the master PTY and its writer
pub struct PtyHandle {
    pub writer: Box<dyn Write + Send>,
    pub _master: Box<dyn portable_pty::MasterPty + Send>,
    /// Raw file descriptor of the master PTY, used for tcgetattr echo detection.
    /// Captured at creation time while the concrete type is still available.
    pub master_fd: i32,
}

impl PtyHandle {
    pub fn write_all(&mut self, data: &[u8]) -> std::io::Result<()> {
        self.writer.write_all(data)
    }

    pub fn resize(&self, size: PtySize) -> Result<(), String> {
        self._master.resize(size).map_err(|e| e.to_string())
    }
}

// ============================================================================
// Event listener
// ============================================================================

/// Event listener that forwards events to a channel and tracks bell events
pub struct Chau7EventListener {
    pub sender: Sender<Event>,
    pub terminal_id: u64,
    /// Flag indicating if a bell occurred since last check
    pub bell_pending: Arc<AtomicBool>,
}

impl EventListener for Chau7EventListener {
    fn send_event(&self, event: Event) {
        trace!("[terminal-{}] Event received: {:?}", self.terminal_id, event);

        // Track bell events for Swift to poll
        if matches!(event, Event::Bell) {
            debug!("[terminal-{}] Bell event received", self.terminal_id);
            self.bell_pending.store(true, Ordering::Release);
        }

        if self.sender.try_send(event).is_err() {
            trace!("[terminal-{}] Event channel full, dropping event", self.terminal_id);
        }
    }
}
