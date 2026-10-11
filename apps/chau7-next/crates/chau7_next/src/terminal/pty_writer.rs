//! Input to the PTY, written from a background thread per session
//! (`RustTerminalFFI.writeQueue` in `RustTerminalView.swift`).
//!
//! The kernel PTY buffer is finite; when a program stops reading stdin a
//! blocking write would freeze whoever calls it. Writes are queued here in
//! order and written in small chunks, each after the PTY reports it can take
//! input, so the PTY lock is never held for long and the UI thread never
//! blocks. The same thread closes the session (TRM-007) and drops the
//! terminal, whose `Drop` kills the shell and can wait for it.

use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{self, Receiver, Sender};
use std::time::{Duration, Instant};

use chau7_terminal::Chau7Terminal;
use parking_lot::RwLock;

/// Largest piece written at once.
const CHUNK: usize = 1024;
/// How long one writability wait lasts before checking for shutdown.
const WAIT_MS: i32 = 50;

/// How a session ends.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CloseMode {
    /// Tab or pane closed: `exit`, then SIGTERM to the process group after
    /// a grace delay (1 s, 3 s when an AI tool runs), then SIGKILL after 0.5 s
    /// (2 s) (`closeSession`, `scheduleForcedTerminationIfNeeded`).
    Graceful { ai_running: bool },
    /// The app quits: `exit` and SIGTERM to the process group at once
    /// (`closeSessionForTermination`).
    AppQuit,
}

enum Job {
    Write(Vec<u8>),
    /// OSC 52 clipboard read answer (written by the terminal itself).
    ClipboardResponse(String),
    Close(CloseMode),
}

/// Sends input to the writer thread. Dropping it without [`PtyWriter::close`]
/// stops the thread after the queued writes.
pub struct PtyWriter {
    tx: Sender<Job>,
    /// Set by [`PtyWriter::close`]: pending writes are abandoned, so a
    /// program that never reads its input cannot keep the session alive.
    closing: Arc<AtomicBool>,
}

impl PtyWriter {
    /// Starts the writer thread. It owns one reference to the terminal and
    /// drops it last when it ends.
    pub fn spawn(term: Arc<RwLock<Chau7Terminal>>) -> Self {
        let (tx, rx) = mpsc::channel();
        let closing = Arc::new(AtomicBool::new(false));
        let flag = closing.clone();
        let spawned = std::thread::Builder::new()
            .name("chau7-next-pty-write".into())
            .spawn(move || run(term, rx, flag));
        if let Err(err) = spawned {
            log::error!("could not start the PTY writer thread: {err}");
        }
        Self { tx, closing }
    }

    /// Queues bytes; they are written in order.
    pub fn write(&self, bytes: Vec<u8>) {
        if !bytes.is_empty() {
            let _ = self.tx.send(Job::Write(bytes));
        }
    }

    /// Answers a pending OSC 52 clipboard read, in order with the input.
    pub fn respond_clipboard(&self, text: String) {
        let _ = self.tx.send(Job::ClipboardResponse(text));
    }

    /// Ends the session after the queued writes.
    pub fn close(&self, mode: CloseMode) {
        self.closing.store(true, Ordering::Release);
        let _ = self.tx.send(Job::Close(mode));
    }
}

fn run(term: Arc<RwLock<Chau7Terminal>>, rx: Receiver<Job>, closing: Arc<AtomicBool>) {
    loop {
        match rx.recv() {
            Ok(Job::Write(bytes)) => {
                if !closing.load(Ordering::Acquire) {
                    write_all(&term, &bytes, &closing);
                }
            }
            Ok(Job::ClipboardResponse(text)) => {
                if !closing.load(Ordering::Acquire) && term.read().wait_input_writable(1000) {
                    term.read().respond_clipboard_load(&text);
                }
            }
            Ok(Job::Close(mode)) => {
                close(&term, mode);
                break;
            }
            Err(_) => break,
        }
    }
    // Last reference in most cases: `Drop` of the terminal runs here, off
    // the UI thread.
    drop(term);
}

fn write_all(term: &RwLock<Chau7Terminal>, bytes: &[u8], closing: &AtomicBool) {
    for chunk in bytes.chunks(CHUNK) {
        let started = Instant::now();
        let mut warned = false;
        loop {
            if term.read().wait_input_writable(WAIT_MS) {
                break;
            }
            if closing.load(Ordering::Acquire) || term.read().is_pty_closed() {
                return;
            }
            if !warned && started.elapsed() > Duration::from_secs(5) {
                warned = true;
                log::warn!("PTY input blocked: the program is not reading its input");
            }
        }
        term.read().send_bytes(chunk);
    }
}

fn close(term: &RwLock<Chau7Terminal>, mode: CloseMode) {
    let (pid, has_pty) = {
        let t = term.read();
        (t.shell_pid() as i32, t.has_pty())
    };
    if !has_pty || pid <= 0 || exited(term) {
        return;
    }
    // A full input buffer would block the write: then rely on the signals.
    if term.read().wait_input_writable(100) {
        term.read().send_bytes(b"exit\n");
    }
    match mode {
        CloseMode::AppQuit => signal_group(pid, Signal::Term),
        CloseMode::Graceful { ai_running } => {
            let (grace, escalation) = termination_delays(ai_running);
            if wait_for_exit(term, grace) {
                return;
            }
            log::warn!("shell {pid} did not exit after `exit`: sending SIGTERM to its group");
            signal_group(pid, Signal::Term);
            if wait_for_exit(term, escalation) {
                return;
            }
            log::error!("shell {pid} still alive after SIGTERM: sending SIGKILL");
            signal_group(pid, Signal::Kill);
        }
    }
}

/// Grace delay before SIGTERM and before SIGKILL (Swift: 1 s and 0.5 s,
/// 3 s and 2 s when an AI tool runs).
pub fn termination_delays(ai_running: bool) -> (Duration, Duration) {
    if ai_running {
        (Duration::from_secs(3), Duration::from_secs(2))
    } else {
        (Duration::from_secs(1), Duration::from_millis(500))
    }
}

fn exited(term: &RwLock<Chau7Terminal>) -> bool {
    let t = term.read();
    t.try_child_exit_code().is_some()
}

fn wait_for_exit(term: &RwLock<Chau7Terminal>, timeout: Duration) -> bool {
    let deadline = Instant::now() + timeout;
    while Instant::now() < deadline {
        if exited(term) {
            return true;
        }
        std::thread::sleep(Duration::from_millis(25));
    }
    exited(term)
}

#[derive(Debug, Clone, Copy)]
pub enum Signal {
    Term,
    Kill,
}

/// Signals the shell's process group, or the shell alone when the group is
/// gone (`sendTerminationSignal`).
pub fn signal_group(pid: i32, signal: Signal) {
    #[cfg(unix)]
    {
        let sig = match signal {
            Signal::Term => libc::SIGTERM,
            Signal::Kill => libc::SIGKILL,
        };
        // SAFETY: plain kill(2) calls on a pid we started.
        unsafe {
            if libc::kill(-pid, sig) != 0 {
                libc::kill(pid, sig);
            }
        }
    }
    #[cfg(not(unix))]
    {
        // Windows: the terminal's Drop kills the child.
        let _ = (pid, signal);
    }
}

/// Waits on `rx` for at most `timeout` (test helper for ordering).
#[cfg(test)]
fn recv_for<T>(rx: &Receiver<T>, timeout: Duration) -> Option<T> {
    rx.recv_timeout(timeout).ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn delays_match_swift() {
        assert_eq!(
            termination_delays(false),
            (Duration::from_secs(1), Duration::from_millis(500))
        );
        assert_eq!(
            termination_delays(true),
            (Duration::from_secs(3), Duration::from_secs(2))
        );
    }

    #[test]
    fn headless_writer_drops_terminal_off_thread() {
        let term = Arc::new(RwLock::new(Chau7Terminal::new_headless(10, 2).unwrap()));
        let weak = Arc::downgrade(&term);
        let writer = PtyWriter::spawn(term);
        writer.write(b"ignored".to_vec());
        writer.close(CloseMode::Graceful { ai_running: false });
        let (tx, rx) = mpsc::channel();
        std::thread::spawn(move || {
            for _ in 0..200 {
                if weak.upgrade().is_none() {
                    let _ = tx.send(());
                    return;
                }
                std::thread::sleep(Duration::from_millis(10));
            }
        });
        assert!(recv_for(&rx, Duration::from_secs(3)).is_some());
    }

    #[cfg(unix)]
    #[test]
    fn writes_arrive_in_order_and_close_ends_the_shell() {
        let Ok(term) = Chau7Terminal::new_with_env_in_dir(40, 5, "/bin/sh", &[], None) else {
            return;
        };
        let term = Arc::new(RwLock::new(term));
        let writer = PtyWriter::spawn(term.clone());
        writer.write(b"echo one".to_vec());
        writer.write(b"two\n".to_vec());
        let deadline = Instant::now() + Duration::from_secs(5);
        let mut seen = String::new();
        while Instant::now() < deadline && !seen.contains("onetwo\r\n") {
            let t = term.read();
            let _ = t.poll(20);
            seen.push_str(&String::from_utf8_lossy(&t.get_last_output()));
        }
        assert!(seen.contains("onetwo"), "{seen:?}");
        writer.close(CloseMode::Graceful { ai_running: false });
        let deadline = Instant::now() + Duration::from_secs(5);
        while Instant::now() < deadline && term.read().try_child_exit_code().is_none() {
            std::thread::sleep(Duration::from_millis(20));
        }
        assert!(term.read().try_child_exit_code().is_some());
    }
}
