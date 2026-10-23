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

use chau7_next_core::work_profiler::{self, Key as WorkKey, Kind as WorkKind, Queue as WorkQueue};
use chau7_terminal::Chau7Terminal;
use parking_lot::RwLock;

/// Largest piece written at once.
const CHUNK: usize = 1024;
/// How long one writability wait lasts before checking for shutdown.
const WAIT_MS: i32 = 50;
const MAX_CLIPBOARD_BYTES: usize = 1_048_576;

/// How a session ends.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CloseMode {
    /// Tab or pane closed: `exit`, then SIGHUP to the foreground job and the
    /// shell's group after a grace delay (1 s, 3 s when an AI tool runs),
    /// then SIGKILL after 0.5 s (2 s).
    Graceful { ai_running: bool },
    /// The app quits: `exit` and SIGHUP to the foreground job and the
    /// shell's group at once.
    AppQuit,
}

/// Owns the single queued/in-flight clipboard slot through success, cancellation
/// or a disconnected receiver. Clearing it is independent of payload contents.
struct ClipboardReply {
    text: String,
    pending: Arc<AtomicBool>,
}
impl Drop for ClipboardReply {
    fn drop(&mut self) {
        self.pending.store(false, Ordering::Release);
    }
}

enum Job {
    Write(Vec<u8>),
    Input {
        bytes: Vec<u8>,
        enqueued_at: Instant,
    },
    /// OSC 52 clipboard read answer (written by the terminal itself).
    ClipboardResponse(ClipboardReply),
    Close(CloseMode),
}

/// Sends input to the writer thread. Dropping it without [`PtyWriter::close`]
/// stops the thread after the queued writes.
pub struct PtyWriter {
    tx: Sender<Job>,
    /// Set by [`PtyWriter::close`]: pending writes are abandoned, so a
    /// program that never reads its input cannot keep the session alive.
    closing: Arc<AtomicBool>,
    clipboard_pending: Arc<AtomicBool>,
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
        Self {
            tx,
            closing,
            clipboard_pending: Arc::new(AtomicBool::new(false)),
        }
    }

    /// Queues bytes; they are written in order.
    pub fn write(&self, bytes: Vec<u8>) {
        if !bytes.is_empty() {
            let _ = self.tx.send(Job::Write(bytes));
        }
    }

    /// Queues user input with a timestamp for queue-delay diagnostics.
    /// Metrics contain only static operation labels and byte counts.
    pub fn write_input(&self, bytes: Vec<u8>) {
        if bytes.is_empty() {
            return;
        }
        let size = bytes.len();
        let enqueued_at = Instant::now();
        if self.tx.send(Job::Input { bytes, enqueued_at }).is_err() {
            record_input_metric("pty_input_enqueue_failure", "enqueue", enqueued_at, size);
        }
    }

    /// Answers a pending OSC 52 clipboard read, in order with the input.
    pub fn has_pending_clipboard_response(&self) -> bool {
        self.clipboard_pending.load(Ordering::Acquire)
    }
    pub fn respond_clipboard(&self, text: &str) -> bool {
        if self.closing.load(Ordering::Acquire)
            || self
                .clipboard_pending
                .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
                .is_err()
        {
            return false;
        }
        // Bound before making an owned copy; never transmit a truncated secret.
        let text = if text.len() <= MAX_CLIPBOARD_BYTES {
            text.to_owned()
        } else {
            String::new()
        };
        self.tx
            .send(Job::ClipboardResponse(ClipboardReply {
                text,
                pending: self.clipboard_pending.clone(),
            }))
            .is_ok()
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
                    send_all_chunks(&term, &bytes, &closing);
                }
            }
            Ok(Job::Input { bytes, enqueued_at }) => {
                let size = bytes.len();
                record_input_metric("pty_input_queue", "dequeue", enqueued_at, size);
                if !closing.load(Ordering::Acquire) {
                    let write_started = Instant::now();
                    let sent_all_chunks = send_all_chunks(&term, &bytes, &closing);
                    if sent_all_chunks {
                        record_input_metric(
                            "pty_input_send_bytes",
                            "send_bytes_calls_returned",
                            write_started,
                            size,
                        );
                    } else {
                        record_input_metric(
                            "pty_input_send_aborted",
                            "closed_before_all_chunks_sent",
                            write_started,
                            size,
                        );
                    }
                } else {
                    record_input_metric(
                        "pty_input_send_aborted",
                        "cancelled_before_send",
                        Instant::now(),
                        size,
                    );
                }
            }
            Ok(Job::ClipboardResponse(reply)) => {
                if !closing.load(Ordering::Acquire) && term.read().wait_input_writable(1000) {
                    term.read().respond_clipboard_load(&reply.text);
                }
                // Drop releases the slot even when closing or unwritable.
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

// The terminal API exposes no PTY write acknowledgement/error result. This
// reports whether all send_bytes calls returned before close, not delivery.
fn send_all_chunks(term: &RwLock<Chau7Terminal>, bytes: &[u8], closing: &AtomicBool) -> bool {
    for chunk in bytes.chunks(CHUNK) {
        let started = Instant::now();
        let mut warned = false;
        loop {
            if term.read().wait_input_writable(WAIT_MS) {
                break;
            }
            if closing.load(Ordering::Acquire) || term.read().is_pty_closed() {
                return false;
            }
            if !warned && started.elapsed() > Duration::from_secs(5) {
                warned = true;
                log::warn!("PTY input blocked: the program is not reading its input");
            }
        }
        term.read().send_bytes(chunk);
    }
    true
}

fn record_input_metric(
    operation: &'static str,
    phase: &'static str,
    started: Instant,
    bytes: usize,
) {
    let mut key = WorkKey::work(
        operation,
        phase,
        "unobserved",
        "pty_writer",
        WorkQueue::Background,
    );
    key.kind = WorkKind::Latency;
    work_profiler::record(
        key,
        started.elapsed().as_secs_f64() * 1000.0,
        bytes,
        1,
        false,
    );
}

fn close(term: &RwLock<Chau7Terminal>, mode: CloseMode) {
    let started = Instant::now();
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
        CloseMode::AppQuit => hang_up(term, pid),
        CloseMode::Graceful { ai_running } => {
            let (grace, escalation) = termination_delays(ai_running);
            if wait_for_exit(term, grace) {
                return;
            }
            log::warn!(
                "shell {pid} did not exit after `exit`: sending SIGHUP; close_mode={mode:?} grace_ms={} elapsed_ms={}",
                grace.as_millis(),
                started.elapsed().as_millis()
            );
            hang_up(term, pid);
            if wait_for_exit(term, escalation) {
                return;
            }
            log::error!(
                "shell {pid} still alive after SIGHUP: sending SIGKILL; close_mode={mode:?} escalation_ms={} elapsed_ms={}",
                escalation.as_millis(),
                started.elapsed().as_millis()
            );
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

/// A closing terminal hangs up, as Terminal.app and iTerm do. Interactive
/// shells ignore SIGTERM but handle SIGHUP by saving history, running exit
/// hooks and passing it on to their jobs. A full-screen program runs in its
/// own foreground group, which the shell's group does not include.
fn hang_up(term: &RwLock<Chau7Terminal>, pid: i32) {
    let foreground = term.read().foreground_pgrp();
    if let Some(pgrp) = foreground.filter(|pgrp| *pgrp != pid) {
        signal_group(pgrp, Signal::Hangup);
    }
    signal_group(pid, Signal::Hangup);
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
    Hangup,
    Kill,
}

/// Signals the shell's process group, or the shell alone when the group is
/// gone (`sendTerminationSignal`).
pub fn signal_group(pid: i32, signal: Signal) {
    #[cfg(unix)]
    {
        let sig = match signal {
            Signal::Hangup => libc::SIGHUP,
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

    fn isolated_queue() -> (PtyWriter, Receiver<Job>) {
        let (tx, rx) = mpsc::channel();
        (
            PtyWriter {
                tx,
                closing: Arc::new(AtomicBool::new(false)),
                clipboard_pending: Arc::new(AtomicBool::new(false)),
            },
            rx,
        )
    }
    #[test]
    fn user_input_uses_timestamped_queue_job() {
        let (writer, rx) = isolated_queue();
        writer.write_input(b"input".to_vec());
        match rx.recv().unwrap() {
            Job::Input { bytes, enqueued_at } => {
                assert_eq!(bytes, b"input");
                assert!(enqueued_at.elapsed() >= Duration::ZERO);
            }
            _ => panic!("user input job was not tagged"),
        }
    }

    #[test]
    fn clipboard_is_queued_once_and_remains_in_input_order() {
        let (writer, rx) = isolated_queue();
        writer.write(b"before".to_vec());
        assert!(writer.respond_clipboard("é"));
        assert!(writer.has_pending_clipboard_response());
        assert!(!writer.respond_clipboard("duplicate"));
        writer.write(b"after".to_vec());
        match rx.recv().unwrap() {
            Job::Write(bytes) => assert_eq!(bytes, b"before"),
            _ => panic!("input reordered"),
        }
        match rx.recv().unwrap() {
            Job::ClipboardResponse(reply) => {
                assert_eq!(reply.text, "é");
                assert!(writer.has_pending_clipboard_response());
            }
            _ => panic!("clipboard reordered"),
        }
        assert!(!writer.has_pending_clipboard_response());
        match rx.recv().unwrap() {
            Job::Write(bytes) => assert_eq!(bytes, b"after"),
            _ => panic!("input reordered"),
        }
        assert!(rx.try_recv().is_err());
        assert!(writer.respond_clipboard("next request"));
    }
    #[test]
    fn oversized_clipboard_is_empty_and_utf8_boundaries_are_exact() {
        let (writer, rx) = isolated_queue();
        let maximum = "é".repeat(MAX_CLIPBOARD_BYTES / 2);
        assert_eq!(maximum.len(), MAX_CLIPBOARD_BYTES);
        assert!(writer.respond_clipboard(&maximum));
        match rx.recv().unwrap() {
            Job::ClipboardResponse(reply) => assert_eq!(reply.text, maximum),
            _ => panic!("missing clipboard"),
        }
        let oversized = maximum + "x";
        assert!(writer.respond_clipboard(&oversized));
        match rx.recv().unwrap() {
            Job::ClipboardResponse(reply) => assert!(reply.text.is_empty()),
            _ => panic!("missing empty reply"),
        }
        assert!(!writer.has_pending_clipboard_response());
    }
    #[test]
    fn clipboard_slot_releases_on_queue_drop_send_failure_and_close() {
        let (writer, rx) = isolated_queue();
        assert!(writer.respond_clipboard("queued"));
        drop(rx);
        assert!(!writer.has_pending_clipboard_response());
        assert!(!writer.respond_clipboard("disconnected"));
        assert!(!writer.has_pending_clipboard_response());
        let (writer, _rx) = isolated_queue();
        writer.close(CloseMode::AppQuit);
        assert!(!writer.respond_clipboard("closed"));
        assert!(!writer.has_pending_clipboard_response());
    }
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

    /// A shell that ignores SIGTERM and never reads the typed `exit` (as
    /// an interactive zsh behind a full-screen program) is hung up, so it
    /// runs its exit handling instead of being killed.
    #[cfg(unix)]
    #[test]
    fn closing_hangs_up_a_shell_that_ignores_sigterm() {
        let dir = std::env::temp_dir().join(format!("chau7-next-hangup-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        let marker = dir.join("hangup");
        let script = format!(
            "trap '' TERM; trap 'echo hup > {}; exit 0' HUP; while :; do sleep 0.05; done",
            marker.display()
        );
        let term =
            Chau7Terminal::new_with_args_env_in_dir(80, 24, "/bin/sh", &["-c", &script], &[], None)
                .unwrap();
        let term = RwLock::new(term);
        // Let the shell install its traps before closing.
        std::thread::sleep(Duration::from_millis(300));
        close(&term, CloseMode::Graceful { ai_running: false });
        assert!(exited(&term));
        assert!(marker.exists(), "the shell was killed instead of hung up");
        let _ = std::fs::remove_dir_all(dir);
    }
}
