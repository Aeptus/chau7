//! Shared PTY reader pool: one thread monitors all PTY file descriptors
//! via `poll()`, replacing per-terminal reader threads.
//!
//! When data arrives on any PTY fd, the pool reads it and sends a
//! `PtyMessage::Data` to the corresponding terminal's crossbeam channel.
//! The channel API is unchanged — `Chau7Terminal::poll()` still receives
//! from the same channel as before.

use std::collections::HashMap;
use std::os::fd::RawFd;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::thread::{self, JoinHandle};
use std::time::Duration;

use crossbeam_channel::Sender;
use log::{debug, error, info, trace, warn};
use parking_lot::Mutex;

use crate::pty::PtyMessage;

/// Registration info for a single PTY fd in the pool.
struct PtyEntry {
    fd: RawFd,
    terminal_id: u64,
    sender: Sender<PtyMessage>,
    running: Arc<AtomicBool>,
    /// Set to true once the pool observes EOF / POLLHUP / POLLERR on this fd.
    /// Prevents the pool from re-polling a dead fd in a tight loop between the
    /// shell exiting and `Chau7Terminal::drop` running `unregister()`, which
    /// on macOS latches POLLHUP and pegs one core per zombie fd, starving
    /// every other terminal that shares the pool.
    closed: AtomicBool,
    /// Bytes that were read from this fd but couldn't be delivered yet
    /// because the consumer's bounded channel was full. While this is
    /// non-empty, the pool stops including this fd in its `poll()` set —
    /// the kernel's PTY buffer fills up, and the shell-side writer
    /// backpressures via a blocked `write()`. No bytes are lost.
    ///
    /// This replaces the previous `try_send` + drop-on-full behaviour.
    /// Dropping was correct for cumulative state (a stale grid catches
    /// up on the next sync) but wrong for cursor-positioning escape
    /// sequences, which are byte-for-byte relative: drop a `ESC[3A`
    /// chunk and every subsequent redraw lands on the wrong row, leaving
    /// stale UI elements stranded mid-scrollback.
    retained: Vec<u8>,
}

/// Shared state protected by a mutex.
struct PoolState {
    entries: HashMap<RawFd, PtyEntry>,
    pending_adds: Vec<PtyEntry>,
    pending_removes: Vec<RawFd>,
}

/// Global shared PTY reader pool. One thread monitors all terminal PTY fds
/// using `poll()` and dispatches data to per-terminal crossbeam channels.
pub struct SharedPtyReaderPool {
    state: Arc<Mutex<PoolState>>,
    shutdown: Arc<AtomicBool>,
    thread: Mutex<Option<JoinHandle<()>>>,
}

impl SharedPtyReaderPool {
    pub fn new() -> Self {
        let state = Arc::new(Mutex::new(PoolState {
            entries: HashMap::new(),
            pending_adds: Vec::new(),
            pending_removes: Vec::new(),
        }));

        let shutdown = Arc::new(AtomicBool::new(false));

        let thread = {
            let state = state.clone();
            let shutdown = shutdown.clone();
            thread::Builder::new()
                .name("pty-reader-pool".into())
                .spawn(move || run_pool(state, shutdown))
                .expect("Failed to spawn pty-reader-pool thread")
        };

        info!("SharedPtyReaderPool: started");

        Self {
            state,
            shutdown,
            thread: Mutex::new(Some(thread)),
        }
    }

    /// Register a PTY fd for monitoring. The pool thread will read from this
    /// fd and send data to `sender`. Call from any thread.
    pub fn register(
        &self,
        fd: RawFd,
        terminal_id: u64,
        sender: Sender<PtyMessage>,
        running: Arc<AtomicBool>,
    ) {
        let mut state = self.state.lock();
        state.pending_adds.push(PtyEntry {
            fd,
            terminal_id,
            sender,
            running,
            closed: AtomicBool::new(false),
            retained: Vec::new(),
        });
        debug!(
            "SharedPtyReaderPool: queued registration for terminal {} (fd={})",
            terminal_id, fd
        );
    }

    /// Unregister a PTY fd. The pool thread will stop monitoring it and close
    /// the fd on its next cycle. Call from any thread.
    pub fn unregister(&self, fd: RawFd, terminal_id: u64) {
        let mut state = self.state.lock();
        state.pending_removes.push(fd);
        debug!(
            "SharedPtyReaderPool: queued unregistration for terminal {} (fd={})",
            terminal_id, fd
        );
    }

    /// Shut down the pool thread. Blocks until the thread exits.
    pub fn shutdown(&self) {
        self.shutdown.store(true, Ordering::Release);
        if let Some(handle) = self.thread.lock().take() {
            let _ = handle.join();
        }
        info!("SharedPtyReaderPool: shut down");
    }
}

impl Drop for SharedPtyReaderPool {
    fn drop(&mut self) {
        self.shutdown();
    }
}

/// Global singleton. Created lazily on first terminal creation.
static POOL: std::sync::OnceLock<SharedPtyReaderPool> = std::sync::OnceLock::new();

pub fn shared_reader_pool() -> &'static SharedPtyReaderPool {
    POOL.get_or_init(SharedPtyReaderPool::new)
}

// ============================================================================
// Pool thread
// ============================================================================

fn run_pool(state: Arc<Mutex<PoolState>>, shutdown: Arc<AtomicBool>) {
    let mut buf = [0u8; 8192];
    let mut pollfds: Vec<libc::pollfd> = Vec::new();
    // Map from pollfd index → fd for quick lookup after poll returns
    let mut fd_list: Vec<RawFd> = Vec::new();

    info!("SharedPtyReaderPool: thread started");

    loop {
        if shutdown.load(Ordering::Acquire) {
            break;
        }

        // Process pending adds/removes
        {
            let mut s = state.lock();
            let adds: Vec<PtyEntry> = s.pending_adds.drain(..).collect();
            for entry in adds {
                let tid = entry.terminal_id;
                let fd = entry.fd;
                s.entries.insert(fd, entry);
                info!(
                    "SharedPtyReaderPool: registered terminal {} (fd={}), total={}",
                    tid,
                    fd,
                    s.entries.len()
                );
            }
            let removes: Vec<RawFd> = s.pending_removes.drain(..).collect();
            for fd in removes {
                if let Some(entry) = s.entries.remove(&fd) {
                    info!(
                        "SharedPtyReaderPool: unregistered terminal {} (fd={}), total={}",
                        entry.terminal_id,
                        fd,
                        s.entries.len()
                    );
                    unsafe { libc::close(fd) };
                }
            }

            // Rebuild pollfd array, excluding entries already observed as
            // closed (shell exited, EOF/HUP/POLLERR latched). They stay
            // registered until Drop runs `unregister()` to reclaim the fd,
            // but we must not poll them in the meantime — POLLHUP on macOS
            // is edge-latched and re-fires every iteration, spinning the
            // single pool thread at 100% CPU and starving every other
            // terminal.
            //
            // Also exclude fds with non-empty `retained` buffers (consumer
            // is behind). For each such fd we first try to drain the
            // retained bytes via `try_send`; if that succeeds the fd is
            // re-included in the poll set, otherwise it stays excluded so
            // the kernel PTY buffer fills up and the shell backpressures.
            pollfds.clear();
            fd_list.clear();
            for (&fd, entry) in s.entries.iter_mut() {
                if entry.closed.load(Ordering::Acquire) {
                    continue;
                }
                if !entry.retained.is_empty() {
                    let data = std::mem::take(&mut entry.retained);
                    match entry.sender.try_send(PtyMessage::Data(data)) {
                        Ok(()) => {
                            // Drained — fall through and re-include this
                            // fd in the poll set.
                            trace!(
                                "SharedPtyReaderPool: drained retained buffer for terminal {}",
                                entry.terminal_id
                            );
                        }
                        Err(crossbeam_channel::TrySendError::Full(PtyMessage::Data(buf))) => {
                            // Still full — put the bytes back and skip.
                            entry.retained = buf;
                            continue;
                        }
                        Err(crossbeam_channel::TrySendError::Full(_)) => continue,
                        Err(crossbeam_channel::TrySendError::Disconnected(_)) => continue,
                    }
                }
                pollfds.push(libc::pollfd {
                    fd,
                    events: libc::POLLIN,
                    revents: 0,
                });
                fd_list.push(fd);
            }
        }

        if pollfds.is_empty() {
            // No fds to monitor — sleep briefly and check for new registrations
            thread::sleep(Duration::from_millis(100));
            continue;
        }

        // Block until one or more fds are readable (200ms timeout to pick up
        // new registrations and check the shutdown flag).
        let n = unsafe { libc::poll(pollfds.as_mut_ptr(), pollfds.len() as _, 200) };

        if n < 0 {
            let errno = std::io::Error::last_os_error();
            if errno.kind() == std::io::ErrorKind::Interrupted {
                continue; // EINTR — retry
            }
            error!("SharedPtyReaderPool: poll() error: {}", errno);
            thread::sleep(Duration::from_millis(50));
            continue;
        }

        if n == 0 {
            continue; // Timeout — loop to check shutdown/registrations
        }

        // Read from fds that have data
        let mut s = state.lock();
        for (i, pfd) in pollfds.iter().enumerate() {
            if pfd.revents == 0 {
                continue;
            }

            let fd = fd_list[i];
            let entry = match s.entries.get_mut(&fd) {
                Some(e) => e,
                None => continue,
            };

            if !entry.running.load(Ordering::Acquire) {
                continue;
            }

            if pfd.revents & libc::POLLIN != 0 {
                let bytes_read =
                    unsafe { libc::read(fd, buf.as_mut_ptr() as *mut libc::c_void, buf.len()) };

                if bytes_read > 0 {
                    let data = buf[..bytes_read as usize].to_vec();
                    trace!(
                        "SharedPtyReaderPool: terminal {} read {} bytes",
                        entry.terminal_id, bytes_read
                    );
                    // try_send keeps the pool thread non-blocking — a
                    // blocking send would starve every other terminal
                    // sharing this single pool thread. On Full, we retain
                    // the bytes on the entry and stop including the fd in
                    // the next pollfd rebuild; the kernel PTY buffer fills
                    // up and the shell backpressures via blocked write().
                    // Bytes are never dropped: cursor-positioning escape
                    // sequences are byte-for-byte relative, and dropping
                    // any chunk corrupts every subsequent redraw (stale
                    // UI elements stranded in scrollback).
                    match entry.sender.try_send(PtyMessage::Data(data)) {
                        Ok(()) => {}
                        Err(crossbeam_channel::TrySendError::Full(PtyMessage::Data(buf))) => {
                            warn!(
                                "SharedPtyReaderPool: backpressuring terminal {} — channel full, retaining {} bytes (next read paused until consumer drains)",
                                entry.terminal_id,
                                buf.len()
                            );
                            entry.retained = buf;
                        }
                        Err(crossbeam_channel::TrySendError::Full(_)) => {
                            warn!(
                                "SharedPtyReaderPool: unexpected non-Data Full for terminal {}",
                                entry.terminal_id
                            );
                        }
                        Err(crossbeam_channel::TrySendError::Disconnected(_)) => {
                            debug!(
                                "SharedPtyReaderPool: channel disconnected for terminal {}",
                                entry.terminal_id
                            );
                        }
                    }
                } else if bytes_read == 0 {
                    // EOF — mark closed so the next pollfd rebuild excludes
                    // this fd. Otherwise POLLIN+read==0 latches every
                    // iteration and burns a CPU core.
                    info!(
                        "SharedPtyReaderPool: EOF on terminal {} (fd={})",
                        entry.terminal_id, fd
                    );
                    entry.closed.store(true, Ordering::Release);
                    let _ = entry.sender.try_send(PtyMessage::Closed);
                } else {
                    // Error — mark closed for the same reason.
                    let errno = std::io::Error::last_os_error();
                    if entry.running.load(Ordering::Acquire) {
                        error!(
                            "SharedPtyReaderPool: read error on terminal {} (fd={}): {}",
                            entry.terminal_id, fd, errno
                        );
                    }
                    entry.closed.store(true, Ordering::Release);
                    let _ = entry.sender.try_send(PtyMessage::Closed);
                }
            }

            if pfd.revents & (libc::POLLHUP | libc::POLLERR) != 0 {
                // POLLHUP is edge-latched on macOS — flag the entry closed so
                // the next pollfd rebuild drops it. A single Closed send is
                // enough; Chau7Terminal::poll() handles the follow-up
                // Disconnected state idempotently.
                if !entry.closed.load(Ordering::Acquire) {
                    info!(
                        "SharedPtyReaderPool: HUP/ERR on terminal {} (fd={})",
                        entry.terminal_id, fd
                    );
                    entry.closed.store(true, Ordering::Release);
                    let _ = entry.sender.try_send(PtyMessage::Closed);
                }
            }
        }
    }

    // Cleanup: close all remaining fds
    let s = state.lock();
    for (&fd, entry) in s.entries.iter() {
        debug!(
            "SharedPtyReaderPool: closing fd {} for terminal {} on shutdown",
            fd, entry.terminal_id
        );
        unsafe { libc::close(fd) };
    }

    info!("SharedPtyReaderPool: thread exiting");
}
