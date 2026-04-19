//! Shared PTY reader pool: one thread monitors all PTY file descriptors
//! via `poll()`, replacing per-terminal reader threads.
//!
//! When data arrives on any PTY fd, the pool reads it and sends a
//! `PtyMessage::Data` to the corresponding terminal's crossbeam channel.
//! The channel API is unchanged — `Chau7Terminal::poll()` still receives
//! from the same channel as before.

use std::collections::HashMap;
use std::os::fd::RawFd;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
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
                    tid, fd, s.entries.len()
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

            // Rebuild pollfd array
            pollfds.clear();
            fd_list.clear();
            for &fd in s.entries.keys() {
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
        let s = state.lock();
        for (i, pfd) in pollfds.iter().enumerate() {
            if pfd.revents == 0 {
                continue;
            }

            let fd = fd_list[i];
            let entry = match s.entries.get(&fd) {
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
                        entry.terminal_id,
                        bytes_read
                    );
                    if entry.sender.send(PtyMessage::Data(data)).is_err() {
                        warn!(
                            "SharedPtyReaderPool: channel closed for terminal {}",
                            entry.terminal_id
                        );
                    }
                } else if bytes_read == 0 {
                    // EOF
                    info!(
                        "SharedPtyReaderPool: EOF on terminal {} (fd={})",
                        entry.terminal_id, fd
                    );
                    let _ = entry.sender.send(PtyMessage::Closed);
                } else {
                    // Error
                    let errno = std::io::Error::last_os_error();
                    if entry.running.load(Ordering::Acquire) {
                        error!(
                            "SharedPtyReaderPool: read error on terminal {} (fd={}): {}",
                            entry.terminal_id, fd, errno
                        );
                    }
                    let _ = entry.sender.send(PtyMessage::Closed);
                }
            }

            if pfd.revents & (libc::POLLHUP | libc::POLLERR) != 0 {
                info!(
                    "SharedPtyReaderPool: HUP/ERR on terminal {} (fd={})",
                    entry.terminal_id, fd
                );
                let _ = entry.sender.send(PtyMessage::Closed);
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
