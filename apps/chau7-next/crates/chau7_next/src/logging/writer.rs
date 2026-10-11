//! The file writer of the app log (`Log.fileQueue`): lines are queued and
//! written on one thread, so logging never waits for the disk. If the file
//! cannot be opened (or a trim broke the handle) it is reopened on the next
//! line. Every 200 writes the size is checked and a file over the cap keeps
//! only its newest half.

use std::fs::{File, OpenOptions};
use std::io::{Read, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};
use std::sync::mpsc::{Receiver, Sender, channel};
use std::time::Duration;

use chau7_next_core::logging::{TRIM_CHECK_EVERY, trim_keep};

enum Msg {
    Line(String),
    Flush(Sender<()>),
}

/// Queue in front of the writer thread.
pub struct Writer {
    tx: Sender<Msg>,
}

impl Writer {
    /// Start the thread. The file and its folder are created on the first
    /// line (or now, when possible, so the file exists from launch).
    pub fn spawn(path: PathBuf, max_bytes: u64) -> Writer {
        let (tx, rx) = channel();
        let _ = std::thread::Builder::new()
            .name("chau7-next-log".into())
            .spawn(move || run(rx, path, max_bytes));
        Writer { tx }
    }

    /// Queue one line (without the newline).
    pub fn write(&self, line: String) {
        let _ = self.tx.send(Msg::Line(line));
    }

    /// Wait until everything queued so far is on disk (quit, tests).
    pub fn flush(&self, timeout: Duration) {
        let (ack_tx, ack_rx) = channel();
        if self.tx.send(Msg::Flush(ack_tx)).is_ok() {
            let _ = ack_rx.recv_timeout(timeout);
        }
    }
}

fn open(path: &Path) -> Option<File> {
    if let Some(dir) = path.parent() {
        let _ = std::fs::create_dir_all(dir);
    }
    OpenOptions::new().create(true).append(true).open(path).ok()
}

fn run(rx: Receiver<Msg>, path: PathBuf, max_bytes: u64) {
    let mut file = open(&path);
    if file.is_none() {
        eprintln!(
            "[Chau7] WARNING: Failed to open log file at {}",
            path.display()
        );
    }
    let mut writes: u64 = 0;
    while let Ok(msg) = rx.recv() {
        match msg {
            Msg::Line(line) => {
                // Lazy recovery: retry when the handle is gone.
                if file.is_none() {
                    file = open(&path);
                }
                let Some(handle) = file.as_mut() else {
                    continue;
                };
                if writeln!(handle, "{line}").is_err() {
                    file = None;
                    continue;
                }
                writes += 1;
                if writes.is_multiple_of(TRIM_CHECK_EVERY) {
                    match trim_tail(&path, max_bytes) {
                        // The file was replaced: write to the new one.
                        Ok(true) => file = None,
                        Ok(false) => {}
                        Err(err) => {
                            eprintln!("[Chau7] WARNING: Failed to trim log: {err}");
                            file = None;
                        }
                    }
                }
            }
            Msg::Flush(ack) => {
                if let Some(handle) = file.as_mut() {
                    let _ = handle.flush();
                }
                let _ = ack.send(());
            }
        }
    }
}

/// If `path` is over `max_bytes`, keep its newest half (cut at a line start)
/// by replacing the file atomically. Returns whether the file was replaced.
pub fn trim_tail(path: &Path, max_bytes: u64) -> std::io::Result<bool> {
    let size = std::fs::metadata(path)?.len();
    let Some(keep) = trim_keep(size, max_bytes) else {
        return Ok(false);
    };
    let tail = read_tail(path, size, keep)?;
    replace_with(path, &tail)?;
    Ok(true)
}

/// The last `keep` bytes of a file of `size` bytes, starting after the first
/// newline of the cut (a partial line is dropped).
pub fn read_tail(path: &Path, size: u64, keep: u64) -> std::io::Result<Vec<u8>> {
    let mut file = File::open(path)?;
    let start = size.saturating_sub(keep);
    file.seek(SeekFrom::Start(start))?;
    let mut tail = Vec::with_capacity(keep as usize);
    file.read_to_end(&mut tail)?;
    if start > 0
        && let Some(newline) = tail.iter().position(|b| *b == b'\n')
    {
        tail.drain(..=newline);
    }
    Ok(tail)
}

/// Write `data` to a sibling file and rename it over `path`.
pub fn replace_with(path: &Path, data: &[u8]) -> std::io::Result<()> {
    let mut tmp = path.as_os_str().to_owned();
    tmp.push(".tmp");
    let tmp = PathBuf::from(tmp);
    std::fs::write(&tmp, data)?;
    std::fs::rename(&tmp, path)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp(name: &str) -> PathBuf {
        let dir =
            std::env::temp_dir().join(format!("chau7-next-log-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn trim_keeps_the_newest_half_at_a_line_start() {
        let dir = temp("trim");
        let path = dir.join("a.log");
        let lines: Vec<String> = (0..100).map(|i| format!("line {i:03}")).collect();
        std::fs::write(&path, lines.join("\n") + "\n").unwrap();
        let size = std::fs::metadata(&path).unwrap().len();
        // Under the cap: untouched.
        assert!(!trim_tail(&path, size).unwrap());
        // Over the cap: about half is kept, ending with the newest line.
        assert!(trim_tail(&path, size - 1).unwrap());
        let text = std::fs::read_to_string(&path).unwrap();
        assert!(text.ends_with("line 099\n"));
        assert!(text.starts_with("line "));
        assert!(text.len() as u64 <= size / 2 + 1);
        assert!(text.lines().count() > 30);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn writer_appends_and_recovers_after_a_trim() {
        let dir = temp("writer");
        let path = dir.join("sub").join("w.log");
        // Cap of 400 bytes: the 200th write triggers a trim.
        let writer = Writer::spawn(path.clone(), 400);
        for i in 0..250 {
            writer.write(format!("[Chau7][INFO] message number {i}"));
        }
        writer.flush(Duration::from_secs(5));
        let text = std::fs::read_to_string(&path).unwrap();
        assert!(text.contains("message number 249"));
        assert!(!text.contains("message number 0\n"));
        let _ = std::fs::remove_dir_all(&dir);
    }
}
