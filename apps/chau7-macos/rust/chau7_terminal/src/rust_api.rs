//! Safe Rust accessors for Rust callers (Chau7 Next, `apps/chau7-next`).
//!
//! The Swift app reaches these values through the C functions in `ffi.rs`.
//! Rust code linking this crate as an rlib uses the methods below instead.
//! Each one mirrors the FFI function named in its doc comment, with the same
//! locking order and flag handling, so both apps see identical behavior.
//! Nothing here is exported to C: the generated header is unchanged.

use std::collections::HashMap;
use std::sync::atomic::Ordering;
use std::time::Duration;

use crate::pty::PtyMessage;
use crossbeam_channel::{Receiver, Select, Sender, bounded};

use crate::graphics::{DecodedImage, ShellIntegrationEvent};
use crate::pool::get_cell_buffer_pool;
use crate::terminal::Chau7Terminal;
use crate::types::CellData;

/// Non-consuming PTY readiness for Rust callers. Waiting owns no terminal,
/// parser, poll or PTY writer lock and does not keep a terminal alive.
/// Readiness is a hint: another consumer can drain output before `poll(0)`.
pub struct OutputReadiness {
    output: Option<Receiver<PtyMessage>>,
    interrupt: Receiver<()>,
    // Keep the interrupt channel connected if the caller drops its wake handle.
    // This owns only the bounded channel, never the terminal or PTY.
    _interrupt_keepalive: Sender<()>,
}

/// A coalesced wakeup for input, focus changes and shutdown. At most one
/// pending interrupt is retained; shutdown state remains the caller's atomic.
#[derive(Clone)]
pub struct OutputInterrupt(Sender<()>);

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OutputReady {
    /// Output or disconnection is ready. Only the existing parser dequeues it.
    Output,
    Interrupted,
    Timeout,
}

impl OutputReadiness {
    fn new(output: Option<Receiver<PtyMessage>>) -> (Self, OutputInterrupt) {
        let (sender, interrupt) = bounded(1);
        (
            Self {
                output,
                interrupt,
                _interrupt_keepalive: sender.clone(),
            },
            OutputInterrupt(sender),
        )
    }

    /// Wait until output or an interrupt is ready. This never removes PTY
    /// messages, including the closed message and disconnection notification.
    /// A headless terminal returns immediately so its caller can observe close.
    pub fn wait(&self, timeout: Duration) -> OutputReady {
        let Some(output) = &self.output else {
            return OutputReady::Output;
        };
        let mut select = Select::new();
        let output_index = select.recv(output);
        select.recv(&self.interrupt);
        match select.ready_timeout(timeout) {
            Ok(index) if index == output_index => OutputReady::Output,
            Ok(_) => {
                let _ = self.interrupt.try_recv();
                OutputReady::Interrupted
            }
            Err(_) => OutputReady::Timeout,
        }
    }
}
impl OutputInterrupt {
    pub fn wake(&self) {
        // Full means an existing wake already covers this input/focus/stop.
        let _ = self.0.try_send(());
    }
}

/// An owned copy of the visible grid.
#[derive(Debug, Clone, Default)]
pub struct GridCopy {
    pub cols: u16,
    pub rows: u16,
    pub cursor_visible: bool,
    pub scrollback_rows: u32,
    pub display_offset: u32,
    /// Row-major cells, `cols * rows` entries.
    pub cells: Vec<OwnedCell>,
    /// Full grapheme cluster of the cells whose cluster is more than one
    /// `char` (ZWJ emoji, flags, combining marks, VS16), by cell index. The
    /// cell itself keeps the first `char` in [`OwnedCell::character`].
    pub clusters: HashMap<usize, String>,
}

impl GridCopy {
    /// Text of the cell at `index`: its full grapheme cluster, or its
    /// character. `None` past the end of the grid.
    pub fn cell_text(&self, index: usize) -> Option<String> {
        if let Some(cluster) = self.clusters.get(&index) {
            return Some(cluster.clone());
        }
        self.cells.get(index).map(|cell| cell.character.to_string())
    }
}

/// One cell of [`GridCopy`]. Same fields as [`CellData`], with the grapheme
/// resolved to its first `char` (see [`GridCopy::clusters`] for the rest).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct OwnedCell {
    /// First `char` of the cell's grapheme; `' '` for a blank cell and for
    /// the right half of a wide character (`continuation`).
    pub character: char,
    pub fg: (u8, u8, u8),
    pub bg: (u8, u8, u8),
    /// `CELL_FLAG_*` bits from `types.rs`.
    pub flags: u8,
    pub link_id: u16,
    /// Underline variant from SGR 4:x (`CellData::underline_style`): 0 none,
    /// 1 single, 2 double, 3 curly, 4 dotted, 5 dashed (`UNDERLINE_*`).
    pub underline: u8,
    /// Display width in columns: 1 narrow, 2 wide, 0 on continuation cells.
    pub width: u8,
    /// Right half of a wide grapheme owned by the cell to its left.
    pub continuation: bool,
}

impl Default for OwnedCell {
    fn default() -> Self {
        Self {
            character: ' ',
            fg: (255, 255, 255),
            bg: (0, 0, 0),
            flags: 0,
            link_id: 0,
            underline: 0,
            width: 1,
            continuation: false,
        }
    }
}

impl OwnedCell {
    /// Builds the cell from a snapshot cell and its grapheme (empty when blank).
    fn from_cell(cell: &CellData, cluster: &str) -> Self {
        Self {
            character: cluster.chars().next().unwrap_or(' '),
            fg: (cell.fg_r, cell.fg_g, cell.fg_b),
            bg: (cell.bg_r, cell.bg_g, cell.bg_b),
            flags: cell.flags,
            link_id: cell.link_id,
            underline: cell.underline_style,
            width: cell.width,
            continuation: cell.continuation != 0,
        }
    }
}

impl Chau7Terminal {
    /// Rust-only output readiness, independent of terminal ownership and all
    /// locks. The clone observes readiness but never consumes PTY messages;
    /// `poll(0)` keeps the sole ordered receive/parse/publish transaction.
    pub fn output_readiness(&self) -> (OutputReadiness, OutputInterrupt) {
        OutputReadiness::new(self.pty_rx.clone())
    }

    /// Copy of the visible grid. Mirrors `chau7_terminal_get_grid` followed by
    /// `chau7_terminal_free_grid` (the cell buffer goes back to the pool).
    pub fn grid_copy(&self) -> GridCopy {
        let snapshot = self.get_grid_snapshot();
        let total = snapshot.cols as usize * snapshot.rows as usize;
        let mut copy = GridCopy {
            cols: snapshot.cols,
            rows: snapshot.rows,
            cursor_visible: snapshot.cursor_visible != 0,
            scrollback_rows: snapshot.scrollback_rows,
            display_offset: snapshot.display_offset,
            cells: Vec::with_capacity(total),
            clusters: HashMap::new(),
        };
        // SAFETY: `get_grid_snapshot` builds `clusters_utf8` from a Vec with
        // the recorded length and capacity and leaks it; we take ownership
        // back exactly once, as `chau7_terminal_free_grid` does.
        let clusters: Vec<u8> = if snapshot.clusters_utf8.is_null() {
            Vec::new()
        } else {
            unsafe {
                Vec::from_raw_parts(
                    snapshot.clusters_utf8,
                    snapshot.clusters_len,
                    snapshot.clusters_capacity,
                )
            }
        };
        if !snapshot.cells.is_null() {
            // SAFETY: `get_grid_snapshot` builds `cells` from a Vec of exactly
            // `cols * rows` elements with the recorded capacity and leaks it;
            // we take ownership back exactly once, as `chau7_terminal_free_grid` does.
            let buffer = unsafe { Vec::from_raw_parts(snapshot.cells, total, snapshot.capacity) };
            for (index, cell) in buffer.iter().enumerate() {
                let start = cell.cluster_offset as usize;
                let end = start + cell.cluster_len as usize;
                let text = if cell.continuation != 0 {
                    ""
                } else {
                    clusters
                        .get(start..end)
                        .and_then(|bytes| std::str::from_utf8(bytes).ok())
                        .unwrap_or("")
                };
                let owned = OwnedCell::from_cell(cell, text);
                if text.chars().nth(1).is_some() {
                    copy.clusters.insert(index, text.to_string());
                }
                copy.cells.push(owned);
            }
            get_cell_buffer_pool().release(buffer);
        }
        copy
    }

    /// Mirrors `chau7_terminal_get_pending_title`.
    pub fn take_pending_title(&self) -> Option<String> {
        if !self.has_pending_title.load(Ordering::Acquire) {
            return None;
        }
        let mut pending = self.pending_title.lock();
        let title = pending.take();
        if title.is_some() {
            self.has_pending_title.store(false, Ordering::Release);
        }
        title
    }

    /// Mirrors `chau7_terminal_get_pending_exit_code` (`None` instead of -1).
    pub fn take_pending_exit_code(&self) -> Option<i32> {
        self.pending_exit_code.lock().take()
    }

    /// Mirrors `chau7_terminal_is_pty_closed`.
    pub fn is_pty_closed(&self) -> bool {
        self.pty_closed.load(Ordering::Acquire)
    }

    /// Mirrors `chau7_terminal_get_pending_shell_events`.
    pub fn take_shell_events(&self) -> Vec<ShellIntegrationEvent> {
        if !self.has_pending_shell_events.load(Ordering::Acquire) {
            return Vec::new();
        }
        let mut pending = self.pending_shell_events.lock();
        self.has_pending_shell_events
            .store(false, Ordering::Release);
        pending.drain(..).collect()
    }

    /// Mirrors `chau7_terminal_get_pending_clipboard` (OSC 52 store request).
    pub fn take_clipboard_store(&self) -> Option<String> {
        self.take_pending_clipboard_store()
    }

    /// Waits up to `timeout_ms` until the PTY accepts input without blocking
    /// (`POLLOUT` on the duplicated master fd). Rust-only (no C counterpart):
    /// Chau7 Next writes input from a background thread and uses this to
    /// write in small chunks, so a program that stops reading stdin never
    /// holds the PTY lock for long. True when writable, when the terminal has
    /// no PTY (headless), when the fd is unknown, or on a poll error (the
    /// write then reports it).
    pub fn wait_input_writable(&self, timeout_ms: i32) -> bool {
        #[cfg(unix)]
        {
            let fd = self.echo_fd.load(Ordering::Acquire);
            if fd < 0 {
                return true;
            }
            let mut pfd = libc::pollfd {
                fd,
                events: libc::POLLOUT,
                revents: 0,
            };
            // SAFETY: one valid pollfd; the fd stays open while `self` lives
            // (it is closed only in `Drop`).
            let ready = unsafe { libc::poll(&mut pfd, 1, timeout_ms) };
            ready != 0
        }
        #[cfg(not(unix))]
        {
            let _ = timeout_ms;
            true
        }
    }

    /// Exit code of the shell once it has exited (non-blocking `try_wait`),
    /// `None` while it runs or for a headless terminal. Rust-only: the C API
    /// reports exits through `chau7_terminal_get_pending_exit_code`.
    pub fn try_child_exit_code(&self) -> Option<i32> {
        let mut child = self.child.lock();
        let status = child.as_mut()?.try_wait().ok()??;
        Some(status.exit_code() as i32)
    }

    /// The duplicated PTY master fd used for echo detection, -1 when there is
    /// none. Rust-only. It stays open until the terminal is dropped, so a
    /// caller holding the terminal can check echo with
    /// [`Chau7Terminal::echo_disabled_on_fd`] without any terminal lock.
    pub fn echo_fd(&self) -> i32 {
        self.echo_fd.load(Ordering::Acquire)
    }

    /// Same check as [`Chau7Terminal::is_echo_disabled`] on a fd from
    /// [`Chau7Terminal::echo_fd`] (false for -1).
    pub fn echo_disabled_on_fd(fd: i32) -> bool {
        fd >= 0 && crate::terminal::echo_disabled_for_fd(0, fd)
    }

    /// Password-style input on a fd from [`Chau7Terminal::echo_fd`]: echo off
    /// while the line discipline still buffers lines (canonical mode), as
    /// `getpass`, `sudo` and `ssh` set it. Line editors (readline, zsh ZLE)
    /// also turn echo off but switch canonical mode off too, so typing at a
    /// shell prompt does not count. False for -1 and on other platforms.
    pub fn password_input_on_fd(fd: i32) -> bool {
        #[cfg(unix)]
        {
            if fd < 0 {
                return false;
            }
            // SAFETY: tcgetattr fills a zeroed termios for a fd the caller
            // keeps open.
            unsafe {
                let mut termios: libc::termios = std::mem::zeroed();
                if libc::tcgetattr(fd, &mut termios) != 0 {
                    return false;
                }
                let echo = termios.c_lflag & (libc::ECHO as libc::tcflag_t) != 0;
                let canonical = termios.c_lflag & (libc::ICANON as libc::tcflag_t) != 0;
                !echo && canonical
            }
        }
        #[cfg(not(unix))]
        {
            let _ = fd;
            false
        }
    }

    /// Whether this terminal has a live PTY (false for headless terminals).
    pub fn has_pty(&self) -> bool {
        self.pty_handle.lock().is_some()
    }

    /// Mirrors `chau7_terminal_get_pending_images`: images decoded from
    /// iTerm2 (`rgba` holds the base64 payload, see `args`), Sixel (RGBA)
    /// and Kitty (RGBA, or PNG bytes for `f=100`) sequences.
    pub fn take_pending_images(&self) -> Vec<DecodedImage> {
        self.image_store.lock().take_pending()
    }

    /// Mirrors `chau7_terminal_set_image_protocols`: which image sequences
    /// are intercepted (a disabled protocol passes through to the parser,
    /// which ignores it).
    pub fn set_image_protocols(&self, sixel: bool, kitty: bool, iterm2: bool) {
        let mut interceptor = self.graphics_interceptor.lock();
        interceptor.sixel_enabled = sixel;
        interceptor.kitty_enabled = kitty;
        interceptor.iterm2_enabled = iterm2;
    }

    /// Turn the Kitty keyboard protocol on or off (Rust callers only; the
    /// Swift app never enables it, so its behavior is unchanged). When on,
    /// the emulator keeps the `CSI > flags u` / `CSI < n u` stack and answers
    /// `CSI ? u` queries; the caller encodes keys for
    /// [`Chau7Terminal::kitty_keyboard_flags`]. Replacing the emulator
    /// options also resets the scrollback limit, so it is passed again.
    pub fn set_kitty_keyboard(&self, enabled: bool, scrollback_lines: usize) {
        let config = alacritty_terminal::term::Config {
            kitty_keyboard: enabled,
            scrolling_history: scrollback_lines,
            ..Default::default()
        };
        self.term.lock().set_options(config);
        self.grid_dirty.store(true, Ordering::Release);
    }

    /// Current Kitty keyboard enhancement flags (1 disambiguate, 2 event
    /// types, 4 alternate keys, 8 all keys as escapes, 16 associated text).
    pub fn kitty_keyboard_flags(&self) -> u32 {
        use alacritty_terminal::term::TermMode;
        let mode = *self.term.lock().mode();
        [
            (TermMode::DISAMBIGUATE_ESC_CODES, 1),
            (TermMode::REPORT_EVENT_TYPES, 2),
            (TermMode::REPORT_ALTERNATE_KEYS, 4),
            (TermMode::REPORT_ALL_KEYS_AS_ESC, 8),
            (TermMode::REPORT_ASSOCIATED_TEXT, 16),
        ]
        .iter()
        .filter(|(m, _)| mode.contains(*m))
        .map(|(_, bit)| bit)
        .sum()
    }

    /// True while a full-screen program uses the alternate screen.
    pub fn is_alt_screen(&self) -> bool {
        self.is_alternate_screen_active()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn grid_copy_matches_injected_output() {
        let term = Chau7Terminal::new_headless(10, 3).unwrap();
        term.inject_output(b"hi");
        let grid = term.grid_copy();
        assert_eq!((grid.cols, grid.rows), (10, 3));
        assert_eq!(grid.cells.len(), 30);
        assert_eq!(grid.cells[0].character, 'h');
        assert_eq!(grid.cells[1].character, 'i');
        assert_eq!(grid.cells[2].character, ' ');
        // Pool round-trip: a second copy still works.
        assert_eq!(term.grid_copy().cells[0].character, 'h');
    }

    #[test]
    fn grid_copy_keeps_clusters_and_wide_cells() {
        let term = Chau7Terminal::new_headless(10, 2).unwrap();
        // e + combining acute (normalized to one char), a wide CJK char,
        // then a heart with VS16 (a two-char cluster).
        term.inject_output("e\u{301}\u{4e2d}\u{2764}\u{fe0f}".as_bytes());
        let grid = term.grid_copy();
        assert_eq!(grid.cells[0].character, '\u{e9}');
        assert_eq!(grid.cells[1].character, '\u{4e2d}');
        assert_eq!(grid.cells[1].width, 2);
        assert!(grid.cells[2].continuation);
        assert_eq!(grid.cells[2].character, ' ');
        assert_eq!(grid.cell_text(3).as_deref(), Some("\u{2764}\u{fe0f}"));
        assert_eq!(grid.cells[3].character, '\u{2764}');
        assert_eq!(grid.cell_text(0).as_deref(), Some("\u{e9}"));
    }

    #[test]
    fn kitty_keyboard_flags_follow_push_and_pop() {
        let term = Chau7Terminal::new_headless(10, 3).unwrap();
        // Off by default: requests are ignored.
        term.inject_output(b"\x1b[>1u");
        assert_eq!(term.kitty_keyboard_flags(), 0);
        term.set_kitty_keyboard(true, 1000);
        term.inject_output(b"\x1b[>1u");
        assert_eq!(term.kitty_keyboard_flags(), 1);
        term.inject_output(b"\x1b[>11u");
        assert_eq!(term.kitty_keyboard_flags(), 11);
        term.inject_output(b"\x1b[<u");
        assert_eq!(term.kitty_keyboard_flags(), 1);
        term.inject_output(b"\x1b[<u");
        assert_eq!(term.kitty_keyboard_flags(), 0);
    }

    #[test]
    fn alt_screen_is_reported() {
        let term = Chau7Terminal::new_headless(10, 3).unwrap();
        assert!(!term.is_alt_screen());
        term.inject_output(b"\x1b[?1049h");
        assert!(term.is_alt_screen());
    }

    #[test]
    fn underline_variant_is_kept() {
        let term = Chau7Terminal::new_headless(10, 1).unwrap();
        term.inject_output(b"\x1b[4:3mx\x1b[0m\x1b[4my");
        let grid = term.grid_copy();
        assert_eq!(grid.cells[0].underline, crate::types::UNDERLINE_CURL);
        assert_eq!(grid.cells[1].underline, crate::types::UNDERLINE_SINGLE);
        assert_eq!(grid.cells[2].underline, 0);
    }

    #[test]
    fn sixel_image_is_queued_with_its_arrival_point() {
        let term = Chau7Terminal::new_headless(10, 3).unwrap();
        term.inject_output(b"ab\x1bPq#0;2;100;0;0~~\x1b\\");
        let images = term.take_pending_images();
        assert_eq!(images.len(), 1);
        assert_eq!((images[0].width, images[0].height), (2, 6));
        assert_eq!(images[0].arrival_col, 2);
        assert!(term.take_pending_images().is_empty());
        // An image in the middle of a chunk arrives where the cursor was at
        // that point, while `anchor_*` keep the C API meaning (the cursor
        // after the whole chunk).
        term.inject_output(b"\r\nx\x1bPq#0;2;100;0;0~\x1b\\\r\nmore\r\n");
        let images = term.take_pending_images();
        assert_eq!((images[0].arrival_row, images[0].arrival_col), (1, 1));
        assert_eq!((images[0].anchor_row, images[0].anchor_col), (2, 0));
        term.set_image_protocols(false, true, true);
        term.inject_output(b"\x1bPq~\x1b\\");
        assert!(term.take_pending_images().is_empty());
    }

    #[test]
    fn iterm2_image_keeps_its_arguments() {
        let term = Chau7Terminal::new_headless(10, 3).unwrap();
        term.inject_output(b"\x1b]1337;File=name=eA==;inline=1:aGk=\x07");
        let images = term.take_pending_images();
        assert_eq!(images.len(), 1);
        assert_eq!(images[0].args, "File=name=eA==;inline=1");
        assert_eq!(images[0].rgba, b"aGk=");
    }

    #[test]
    fn output_readiness_never_consumes_data_or_close() {
        let (tx, rx) = crossbeam_channel::unbounded();
        let (ready, _wake) = OutputReadiness::new(Some(rx.clone()));
        tx.send(PtyMessage::Data(b"first".to_vec())).unwrap();
        tx.send(PtyMessage::Closed).unwrap();
        for _ in 0..4 {
            assert_eq!(ready.wait(Duration::ZERO), OutputReady::Output);
        }
        assert!(matches!(rx.try_recv(), Ok(PtyMessage::Data(bytes)) if bytes == b"first"));
        assert_eq!(ready.wait(Duration::ZERO), OutputReady::Output);
        assert!(matches!(rx.try_recv(), Ok(PtyMessage::Closed)));
        assert_eq!(ready.wait(Duration::ZERO), OutputReady::Timeout);
        drop(tx);
        assert_eq!(ready.wait(Duration::ZERO), OutputReady::Output);
        assert!(rx.try_recv().is_err());
    }

    #[test]
    fn output_arriving_during_wait_and_at_transition_is_not_lost() {
        let (tx, rx) = crossbeam_channel::unbounded();
        let (ready, _wake) = OutputReadiness::new(Some(rx.clone()));
        let producer = std::thread::spawn(move || {
            std::thread::sleep(Duration::from_millis(10));
            tx.send(PtyMessage::Data(b"later".to_vec())).unwrap();
            tx
        });
        assert_eq!(ready.wait(Duration::from_secs(1)), OutputReady::Output);
        let tx = producer.join().unwrap();
        assert!(matches!(rx.try_recv(), Ok(PtyMessage::Data(bytes)) if bytes == b"later"));
        assert_eq!(ready.wait(Duration::ZERO), OutputReady::Timeout);
        // Output becomes available immediately after the empty observation.
        tx.send(PtyMessage::Data(b"transition".to_vec())).unwrap();
        assert_eq!(ready.wait(Duration::from_secs(1)), OutputReady::Output);
        assert!(matches!(rx.try_recv(), Ok(PtyMessage::Data(bytes)) if bytes == b"transition"));
    }

    #[test]
    fn interrupts_coalesce_and_do_not_hide_shutdown_state() {
        let (_tx, rx) = crossbeam_channel::unbounded();
        let (ready, wake) = OutputReadiness::new(Some(rx));
        for _ in 0..1000 {
            wake.wake();
        }
        assert_eq!(ready.interrupt.len(), 1);
        assert_eq!(ready.wait(Duration::from_secs(1)), OutputReady::Interrupted);
        assert_eq!(ready.wait(Duration::ZERO), OutputReady::Timeout);
        let stopped = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
        let flag = stopped.clone();
        let producer = std::thread::spawn(move || {
            std::thread::sleep(Duration::from_millis(10));
            flag.store(true, Ordering::Release);
            wake.wake();
        });
        assert_eq!(ready.wait(Duration::from_secs(1)), OutputReady::Interrupted);
        assert!(stopped.load(Ordering::Acquire));
        producer.join().unwrap();
    }

    #[test]
    fn dropping_interrupt_handle_does_not_create_disconnected_busy_loop() {
        let (_tx, rx) = crossbeam_channel::unbounded();
        let (ready, wake) = OutputReadiness::new(Some(rx));
        drop(wake);
        assert_eq!(ready.wait(Duration::from_millis(1)), OutputReady::Timeout);
        assert_eq!(ready.wait(Duration::ZERO), OutputReady::Timeout);
    }

    #[test]
    fn readiness_does_not_own_terminal_or_delay_headless_close() {
        let term = std::sync::Arc::new(Chau7Terminal::new_headless(10, 3).unwrap());
        let weak = std::sync::Arc::downgrade(&term);
        let (ready, wake) = term.output_readiness();
        assert_eq!(std::sync::Arc::strong_count(&term), 1);
        assert_eq!(ready.wait(Duration::from_secs(1)), OutputReady::Output);
        drop(term);
        assert!(weak.upgrade().is_none());
        wake.wake();
        assert_eq!(ready.wait(Duration::ZERO), OutputReady::Output);
    }

    #[cfg(unix)]
    #[test]
    fn real_pty_readiness_wakes_without_consuming_parser_output() {
        let term = Chau7Terminal::new_with_args_env_in_dir(
            40,
            5,
            "/bin/sh",
            &["-c", "sleep 0.05; printf readiness-marker"],
            &[],
            None,
        )
        .unwrap();
        let (ready, _wake) = term.output_readiness();
        let deadline = std::time::Instant::now() + Duration::from_secs(5);
        let mut output = Vec::new();
        while std::time::Instant::now() < deadline {
            assert_ne!(ready.wait(Duration::from_secs(1)), OutputReady::Interrupted);
            let _ = term.poll(0);
            output.extend_from_slice(&term.get_last_output());
            if term.is_pty_closed() {
                break;
            }
        }
        assert!(String::from_utf8_lossy(&output).contains("readiness-marker"));
        assert!(term.is_pty_closed());
    }

    #[test]
    fn headless_terminal_is_always_writable_and_has_no_child() {
        let term = Chau7Terminal::new_headless(10, 3).unwrap();
        assert!(term.wait_input_writable(0));
        assert_eq!(term.try_child_exit_code(), None);
        assert!(!term.has_pty());
        assert_eq!(term.echo_fd(), -1);
        assert!(!Chau7Terminal::echo_disabled_on_fd(-1));
        assert!(!Chau7Terminal::password_input_on_fd(-1));
    }

    #[test]
    fn title_is_taken_once() {
        let term = Chau7Terminal::new_headless(10, 3).unwrap();
        term.inject_output(b"\x1b]0;hello\x07");
        // Terminal events (title included) are drained by `poll`.
        let _ = term.poll(0);
        assert_eq!(term.take_pending_title().as_deref(), Some("hello"));
        assert_eq!(term.take_pending_title(), None);
    }

    #[cfg(unix)]
    #[test]
    fn shell_starts_in_the_given_directory_with_arguments() {
        let dir = std::env::temp_dir();
        let term = Chau7Terminal::new_with_args_env_in_dir(
            40,
            5,
            "/bin/sh",
            &["-c", "pwd; printf \"$CHAU7_RUST_API_TEST\""],
            &[("CHAU7_RUST_API_TEST", "marker")],
            Some(&dir),
        )
        .unwrap();
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
        let mut output = Vec::new();
        while std::time::Instant::now() < deadline {
            let _ = term.poll(50);
            output.extend(term.get_last_output());
            if String::from_utf8_lossy(&output).contains("marker") {
                break;
            }
        }
        let text = String::from_utf8_lossy(&output);
        assert!(text.contains("marker"), "{text}");
        let canonical = dir.canonicalize().unwrap_or(dir.clone());
        let file_name = canonical.file_name().unwrap().to_string_lossy().to_string();
        assert!(text.contains(&file_name), "{text}");
    }
}
