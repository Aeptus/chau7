//! PTY management: handle wrapper, message types, event listener, dimensions.

use std::io::Write;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};

use alacritty_terminal::event::{Event, EventListener};
use alacritty_terminal::grid::Dimensions;
use crossbeam_channel::{Receiver, Sender};
use log::{debug, trace, warn};
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

/// Queued events beyond which lossy events (wakeups, bells, cursor
/// notifications) are dropped. Matches the old bounded channel capacity.
pub(crate) const LOSSY_EVENT_LIMIT: usize = 100;

/// Queued events beyond which even events that must reach the consumer are
/// dropped. Only a safety valve against a terminal that is fed but never
/// polled: `poll_events` drains the queue after every PTY chunk, so a chunk
/// would need thousands of queries to get near it.
pub(crate) const DELIVERED_EVENT_LIMIT: usize = 16 * 1024;

/// Channel for emulator events. Unbounded so a burst of terminal queries in
/// one poll cannot drop their replies; [`Chau7EventListener`] enforces the
/// limits above instead.
pub(crate) fn event_channel() -> (Sender<Event>, Receiver<Event>) {
    crossbeam_channel::unbounded()
}

/// Events the consumer must see: replies to the program (`PtyWrite`, color
/// and size requests), clipboard and title changes, and exit notifications.
fn must_deliver(event: &Event) -> bool {
    !matches!(
        event,
        Event::Wakeup | Event::Bell | Event::MouseCursorDirty | Event::CursorBlinkingChange
    )
}

/// Event listener that forwards events to a channel and tracks bell events
pub struct Chau7EventListener {
    pub sender: Sender<Event>,
    pub terminal_id: u64,
    /// Flag indicating if a bell occurred since last check
    pub bell_pending: Arc<AtomicBool>,
}

impl EventListener for Chau7EventListener {
    fn send_event(&self, event: Event) {
        trace!(
            "[terminal-{}] Event received: {:?}",
            self.terminal_id, event
        );

        // Track bell events for Swift to poll
        if matches!(event, Event::Bell) {
            debug!("[terminal-{}] Bell event received", self.terminal_id);
            self.bell_pending.store(true, Ordering::Release);
        }

        let limit = if must_deliver(&event) {
            DELIVERED_EVENT_LIMIT
        } else {
            LOSSY_EVENT_LIMIT
        };
        if self.sender.len() >= limit {
            if limit == DELIVERED_EVENT_LIMIT {
                // No payload in the log: it can hold clipboard text.
                warn!(
                    "[terminal-{}] Event queue full ({} queued), dropping a reply/metadata event",
                    self.terminal_id, limit
                );
            } else {
                trace!(
                    "[terminal-{}] Event queue full, dropping lossy event",
                    self.terminal_id
                );
            }
            return;
        }
        // Unbounded: fails only once the terminal (receiver) is gone.
        let _ = self.sender.send(event);
    }
}
