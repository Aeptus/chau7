//! Port of `History/FileTailer.swift`, read-only: follows a file that other
//! programs append to and returns the complete new lines on each poll.
//!
//! Differences from Swift: the tailer never creates the file (Chau7 Next
//! must not write files the Swift app or AI CLI hooks own, see
//! `docs/rust-port/DUAL-SHIP.md`); a missing file is simply polled until it
//! appears. The caller drives the polling (Swift owns a timer).

use std::fs::File;
use std::io::{Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};

/// Trailing fragment cap (`maxBufferSize`, 4 MB; text tailers use 8 MB).
pub const DEFAULT_MAX_BUFFER: usize = 4 * 1024 * 1024;

/// Bytes read for the prefill (`prefillLastLines`: 2 MB).
const PREFILL_MAX_BYTES: u64 = 2 * 1024 * 1024;

#[derive(Debug)]
pub struct FileTailer {
    path: PathBuf,
    offset: u64,
    buffer: String,
    max_buffer: usize,
    started: bool,
}

impl FileTailer {
    pub fn new(path: impl Into<PathBuf>) -> Self {
        Self::with_max_buffer(path, DEFAULT_MAX_BUFFER)
    }

    pub fn with_max_buffer(path: impl Into<PathBuf>, max_buffer: usize) -> Self {
        Self {
            path: path.into(),
            offset: 0,
            buffer: String::new(),
            max_buffer,
            started: false,
        }
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    fn size(&self) -> Option<u64> {
        std::fs::metadata(&self.path).ok().map(|m| m.len())
    }

    /// Starts at the end of the file (`start`): existing content is not
    /// returned, except the last `prefill_lines` lines, returned here.
    pub fn start(&mut self, prefill_lines: usize) -> Vec<String> {
        let prefill = if prefill_lines > 0 {
            self.last_lines(prefill_lines)
        } else {
            Vec::new()
        };
        self.offset = self.size().unwrap_or(0);
        self.buffer.clear();
        self.started = true;
        prefill
    }

    /// The last `count` non-empty lines (trimmed) of the file's last 2 MB.
    fn last_lines(&self, count: usize) -> Vec<String> {
        let Some(size) = self.size().filter(|s| *s > 0) else {
            return Vec::new();
        };
        let Ok(mut file) = File::open(&self.path) else {
            return Vec::new();
        };
        let read = size.min(PREFILL_MAX_BYTES);
        if file.seek(SeekFrom::Start(size - read)).is_err() {
            return Vec::new();
        }
        let mut data = Vec::new();
        if file.read_to_end(&mut data).is_err() {
            return Vec::new();
        }
        let text = String::from_utf8_lossy(&data).replace('\r', "\n");
        let mut parts: Vec<&str> = text.split('\n').collect();
        if parts.last().is_some_and(|l| l.is_empty()) {
            parts.pop();
        }
        let start = parts.len().saturating_sub(count);
        parts[start..]
            .iter()
            .map(|l| l.trim())
            .filter(|l| !l.is_empty())
            .map(str::to_string)
            .collect()
    }

    /// Reads what was appended since the last poll and returns the complete
    /// lines, trimmed, without blank ones (`tick`). A file that shrank is
    /// read again from the start.
    pub fn poll(&mut self) -> Vec<String> {
        if !self.started {
            self.start(0);
            return Vec::new();
        }
        let Some(size) = self.size() else {
            return Vec::new();
        };
        if size < self.offset {
            log::trace!(
                "FileTailer reset after truncation. path={}",
                self.path.display()
            );
            self.offset = 0;
            self.buffer.clear();
        }
        if size == self.offset {
            return Vec::new();
        }
        let Ok(mut file) = File::open(&self.path) else {
            return Vec::new();
        };
        if file.seek(SeekFrom::Start(self.offset)).is_err() {
            return Vec::new();
        }
        let mut data = Vec::new();
        if file.read_to_end(&mut data).is_err() || data.is_empty() {
            return Vec::new();
        }
        self.offset += data.len() as u64;
        let chunk = String::from_utf8_lossy(&data);
        let mut working = std::mem::take(&mut self.buffer);
        working.push_str(&chunk);
        let normalized = working.replace('\r', "\n");
        let mut parts: Vec<&str> = normalized.split('\n').collect();
        let rest = parts.pop().unwrap_or_default().to_string();
        let lines = parts
            .into_iter()
            .map(str::trim)
            .filter(|l| !l.is_empty())
            .map(str::to_string)
            .collect();
        self.buffer = if rest.len() > self.max_buffer {
            String::new()
        } else {
            rest
        };
        lines
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    fn temp_file(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "chau7-next-tailer-{name}-{}-{}",
            std::process::id(),
            uuid::Uuid::new_v4()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        dir.join("log.jsonl")
    }

    fn append(path: &Path, text: &str) {
        std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(path)
            .unwrap()
            .write_all(text.as_bytes())
            .unwrap();
    }

    #[test]
    fn reads_only_new_complete_lines() {
        let path = temp_file("new");
        append(&path, "old\n");
        let mut tailer = FileTailer::new(&path);
        assert!(tailer.start(0).is_empty());
        assert!(tailer.poll().is_empty());
        append(&path, "one\n  \ntw");
        assert_eq!(tailer.poll(), vec!["one"]);
        append(&path, "o\r\nthree\n");
        assert_eq!(tailer.poll(), vec!["two", "three"]);
        let _ = std::fs::remove_dir_all(path.parent().unwrap());
    }

    #[test]
    fn missing_file_is_not_created_and_is_picked_up_later() {
        let path = temp_file("missing");
        let mut tailer = FileTailer::new(&path);
        tailer.start(0);
        assert!(tailer.poll().is_empty());
        assert!(!path.exists());
        append(&path, "first\n");
        assert_eq!(tailer.poll(), vec!["first"]);
        let _ = std::fs::remove_dir_all(path.parent().unwrap());
    }

    #[test]
    fn truncation_restarts_from_the_top() {
        let path = temp_file("trunc");
        append(&path, "aaaaaaaaaa\n");
        let mut tailer = FileTailer::new(&path);
        tailer.start(0);
        std::fs::write(&path, "b\n").unwrap();
        assert_eq!(tailer.poll(), vec!["b"]);
        let _ = std::fs::remove_dir_all(path.parent().unwrap());
    }

    #[test]
    fn prefill_returns_last_lines() {
        let path = temp_file("prefill");
        append(&path, "1\n2\n\n3\n");
        let mut tailer = FileTailer::new(&path);
        assert_eq!(tailer.start(2), vec!["3"]);
        let mut tailer = FileTailer::new(&path);
        assert_eq!(tailer.start(3), vec!["2", "3"]);
        let _ = std::fs::remove_dir_all(path.parent().unwrap());
    }

    #[test]
    fn oversized_fragment_is_dropped() {
        let path = temp_file("big");
        let mut tailer = FileTailer::with_max_buffer(&path, 4);
        tailer.start(0);
        append(&path, "123456789");
        assert!(tailer.poll().is_empty());
        append(&path, "x\nnext\n");
        assert_eq!(tailer.poll(), vec!["x", "next"]);
        let _ = std::fs::remove_dir_all(path.parent().unwrap());
    }
}
