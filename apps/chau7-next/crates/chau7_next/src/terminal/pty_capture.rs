//! (dev) PTY capture (`TerminalOutputCapture.swift`): with
//! `CHAU7_NEXT_PTY_DUMP=1` (or `CHAU7_NEXT_TRACE_PTY=true`), every chunk of
//! PTY output is appended, escaped, to `pty-capture.log` in the state folder
//! (`CHAU7_NEXT_PTY_DUMP_PATH` to change it), and the file is cut to its last
//! half past 20 MB (`CHAU7_NEXT_PTY_DUMP_MAX_BYTES`). The `CHAU7_` names of
//! the Swift app are read too, but Chau7 Next drops inherited `CHAU7_`
//! variables when started from a Chau7 tab.
//!
//! Writes happen on the poll thread, never on the UI thread.

use std::fs::{File, OpenOptions};
use std::io::{Read, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};
use std::sync::OnceLock;

use chau7_next_core::shell_output;
use parking_lot::Mutex;

struct Capture {
    path: PathBuf,
    max_bytes: u64,
    file: Option<File>,
    writes: u64,
}

static CAPTURE: OnceLock<Option<Mutex<Capture>>> = OnceLock::new();

fn env(name: &str) -> Option<String> {
    std::env::var(name.replacen("CHAU7_", "CHAU7_NEXT_", 1))
        .ok()
        .or_else(|| std::env::var(name).ok())
}

/// Reads the environment once. `default_path` is
/// `DataRoot::pty_capture_file`.
pub fn init(default_path: &Path) {
    CAPTURE.get_or_init(|| {
        let enabled = shell_output::capture_enabled(env("CHAU7_PTY_DUMP").as_deref())
            || shell_output::capture_enabled(env("CHAU7_TRACE_PTY").as_deref());
        if !enabled {
            return None;
        }
        let path = env("CHAU7_PTY_DUMP_PATH")
            .map(PathBuf::from)
            .unwrap_or_else(|| default_path.to_path_buf());
        let max_bytes = env("CHAU7_PTY_DUMP_MAX_BYTES")
            .and_then(|v| v.trim().parse().ok())
            .filter(|v| *v > 0)
            .unwrap_or(shell_output::DEFAULT_CAPTURE_MAX_BYTES);
        log::info!("PTY capture on: {}", path.display());
        Some(Mutex::new(Capture {
            path,
            max_bytes,
            file: None,
            writes: 0,
        }))
    });
}

fn open(path: &Path) -> Option<File> {
    if let Some(dir) = path.parent() {
        let _ = std::fs::create_dir_all(dir);
    }
    OpenOptions::new().create(true).append(true).open(path).ok()
}

/// Appends one chunk (no-op unless capture is on).
pub fn record(data: &[u8], source: &str) {
    let Some(Some(capture)) = CAPTURE.get() else {
        return;
    };
    let mut capture = capture.lock();
    if capture.file.is_none() {
        capture.file = open(&capture.path);
    }
    let timestamp = chau7_next_core::iso8601::now_iso8601();
    let line = shell_output::capture_line(&timestamp, source, data);
    if let Some(file) = capture.file.as_mut() {
        let _ = file.write_all(line.as_bytes());
    }
    capture.writes += 1;
    if capture.writes.is_multiple_of(200) {
        trim(&mut capture);
    }
}

fn trim(capture: &mut Capture) {
    let Ok(size) = std::fs::metadata(&capture.path).map(|m| m.len()) else {
        return;
    };
    let Some(keep) = shell_output::capture_trim_keep(size, capture.max_bytes) else {
        return;
    };
    let mut tail = Vec::new();
    if let Ok(mut file) = File::open(&capture.path)
        && file.seek(SeekFrom::Start(size - keep)).is_ok()
    {
        let _ = file.read_to_end(&mut tail);
    }
    capture.file = None;
    if std::fs::write(&capture.path, &tail).is_ok() {
        capture.file = open(&capture.path);
    }
}
