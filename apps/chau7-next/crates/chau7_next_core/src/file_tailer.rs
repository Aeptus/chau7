//! Follow a log file live (`History/FileTailer.swift`).
//!
//! [`FileTailer`] is the polling state machine: each [`FileTailer::poll`]
//! reads what was appended since the last one, splits it into lines
//! (`\n`, `\r` and `\r\n` all end a line), keeps a trailing partial line for
//! the next poll, and hands complete non-blank lines to a parser. The file
//! may be truncated or replaced: the tailer then starts again from the
//! beginning. [`TailerHandle`] runs a tailer on its own thread.
//!
//! One implementation serves the history monitors (500 ms), the Claude hook
//! events (250 ms) and the PTY logs (250 ms, 8 MB buffer).
//!
//! Differences from Swift: the pending fragment is kept as bytes, so a
//! multi-byte character split between two reads is not mangled, and a file
//! replaced by a larger one (log rotation) is detected through its file id
//! on Unix, not only through a smaller size.

use std::fs::File;
use std::io::{Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::thread::JoinHandle;
use std::time::Duration;

/// Poll interval of the history and event tailers.
pub const DEFAULT_POLL_INTERVAL: Duration = Duration::from_millis(500);
/// Poll interval of the Claude hook events tailer.
pub const EVENT_POLL_INTERVAL: Duration = Duration::from_millis(250);
/// Poll interval of the plain text (PTY log) tailers.
pub const TEXT_POLL_INTERVAL: Duration = Duration::from_millis(250);
/// Largest pending partial line (default).
pub const DEFAULT_MAX_BUFFER: usize = 4 * 1024 * 1024;
/// Largest pending partial line of PTY log tailers (AI streaming headroom).
pub const PTY_MAX_BUFFER: usize = 8 * 1024 * 1024;
/// Parse errors logged per tailer before it goes quiet.
const MAX_PARSE_ERROR_LOGS: usize = 10;
/// The prefill reads at most this much from the end of the file.
const PREFILL_MAX_BYTES: u64 = 2 * 1024 * 1024;

/// How a tailer follows its file.
#[derive(Debug, Clone)]
pub struct TailerConfig {
    pub path: PathBuf,
    pub poll_interval: Duration,
    /// Create an empty file when it does not exist.
    pub create_if_missing: bool,
    pub max_buffer_size: usize,
}

impl TailerConfig {
    pub fn new(path: impl Into<PathBuf>) -> Self {
        Self {
            path: path.into(),
            poll_interval: DEFAULT_POLL_INTERVAL,
            create_if_missing: false,
            max_buffer_size: DEFAULT_MAX_BUFFER,
        }
    }

    /// `FileTailer.historyTailer`: 500 ms, creates the file.
    pub fn history(path: impl Into<PathBuf>) -> Self {
        Self {
            create_if_missing: true,
            ..Self::new(path)
        }
    }

    /// `FileTailer.textTailer`: 250 ms, 8 MB, creates the file.
    pub fn text(path: impl Into<PathBuf>) -> Self {
        Self {
            poll_interval: TEXT_POLL_INTERVAL,
            create_if_missing: true,
            max_buffer_size: PTY_MAX_BUFFER,
            ..Self::new(path)
        }
    }

    /// `FileTailer.eventTailer`: 250 ms (the Claude hook events).
    pub fn events(path: impl Into<PathBuf>) -> Self {
        Self {
            poll_interval: EVENT_POLL_INTERVAL,
            ..Self::new(path)
        }
    }
}

type Parser<T> = Box<dyn FnMut(&str) -> Result<T, String> + Send>;

/// The polling state machine (no thread, no timer).
pub struct FileTailer<T> {
    config: TailerConfig,
    parser: Parser<T>,
    offset: u64,
    /// The unfinished last line of the previous poll.
    buffer: Vec<u8>,
    /// File id at the last read (Unix inode), to notice a replaced file.
    file_id: Option<u64>,
    parse_errors: usize,
}

fn file_id(meta: &std::fs::Metadata) -> Option<u64> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        Some(meta.ino())
    }
    #[cfg(not(unix))]
    {
        let _ = meta;
        None
    }
}

/// Split bytes into lines on `\n` and `\r`; returns the complete lines and
/// leaves the unfinished last line in `rest`. Blank lines are dropped.
fn split_lines(bytes: &[u8]) -> (Vec<String>, &[u8]) {
    let mut lines = Vec::new();
    let mut start = 0;
    for (i, b) in bytes.iter().enumerate() {
        if *b == b'\n' || *b == b'\r' {
            push_line(&mut lines, &bytes[start..i]);
            start = i + 1;
        }
    }
    (lines, &bytes[start..])
}

fn push_line(lines: &mut Vec<String>, raw: &[u8]) {
    let text = String::from_utf8_lossy(raw);
    let trimmed = text.trim();
    if !trimmed.is_empty() {
        lines.push(trimmed.to_string());
    }
}

impl<T> FileTailer<T> {
    pub fn new(
        config: TailerConfig,
        parser: impl FnMut(&str) -> Result<T, String> + Send + 'static,
    ) -> Self {
        Self {
            config,
            parser: Box::new(parser),
            offset: 0,
            buffer: Vec::new(),
            file_id: None,
            parse_errors: 0,
        }
    }

    pub fn path(&self) -> &Path {
        &self.config.path
    }

    pub fn poll_interval(&self) -> Duration {
        self.config.poll_interval
    }

    /// Where the next poll reads from.
    pub fn offset(&self) -> u64 {
        self.offset
    }

    /// Begin following: create the file when asked to, read the last
    /// `prefill_lines` lines (0 means start fresh), and continue from the
    /// current end of the file. Returns the prefilled items; lines that do
    /// not parse are skipped silently.
    pub fn start(&mut self, prefill_lines: usize) -> Vec<T> {
        if self.config.create_if_missing && !self.config.path.exists() {
            log::warn!(
                "file not found, creating an empty file at {}",
                self.config.path.display()
            );
            if let Some(dir) = self.config.path.parent() {
                let _ = std::fs::create_dir_all(dir);
            }
            let _ = File::create(&self.config.path);
        }
        let items = if prefill_lines > 0 {
            self.prefill(prefill_lines)
        } else {
            Vec::new()
        };
        let meta = std::fs::metadata(&self.config.path).ok();
        self.offset = meta.as_ref().map_or(0, std::fs::Metadata::len);
        self.file_id = meta.as_ref().and_then(file_id);
        self.buffer.clear();
        log::trace!(
            "file tailer start: path={} offset={}",
            self.config.path.display(),
            self.offset
        );
        items
    }

    fn prefill(&mut self, count: usize) -> Vec<T> {
        let Ok(mut file) = File::open(&self.config.path) else {
            return Vec::new();
        };
        let Ok(size) = file.metadata().map(|m| m.len()) else {
            return Vec::new();
        };
        if size == 0 {
            return Vec::new();
        }
        let read_size = size.min(PREFILL_MAX_BYTES);
        let start = size - read_size;
        if file.seek(SeekFrom::Start(start)).is_err() {
            return Vec::new();
        }
        let mut data = Vec::with_capacity(read_size as usize);
        if file.take(read_size).read_to_end(&mut data).is_err() {
            return Vec::new();
        }
        let text = String::from_utf8_lossy(&data).replace('\r', "\n");
        let mut parts: Vec<&str> = text.split('\n').collect();
        if parts.last().is_some_and(|l| l.is_empty()) {
            parts.pop();
        }
        // A read that began mid-file starts with a partial line: drop it.
        if start > 0 && !parts.is_empty() {
            parts.remove(0);
        }
        let skip = parts.len().saturating_sub(count);
        let mut items = Vec::new();
        for line in &parts[skip..] {
            let trimmed = line.trim();
            if trimmed.is_empty() {
                continue;
            }
            if let Ok(item) = (self.parser)(trimmed) {
                items.push(item);
            }
        }
        if !items.is_empty() {
            log::trace!(
                "file tailer prefill {} lines: {}",
                items.len(),
                self.config.path.display()
            );
        }
        items
    }

    /// Read what was appended since the last poll and return the parsed
    /// lines. After a truncation or replacement the file is read again from
    /// its start.
    pub fn poll(&mut self) -> Vec<T> {
        let meta = std::fs::metadata(&self.config.path).ok();
        let size = meta.as_ref().map(std::fs::Metadata::len);
        let id = meta.as_ref().and_then(file_id);
        let replaced = matches!((self.file_id, id), (Some(a), Some(b)) if a != b);
        if replaced || size.is_some_and(|s| s < self.offset) {
            self.offset = 0;
            self.buffer.clear();
            log::trace!(
                "file tailer reset after truncation or rotation: {}",
                self.config.path.display()
            );
        }
        self.file_id = id;
        let Some(size) = size else {
            return Vec::new();
        };
        if size == self.offset {
            return Vec::new();
        }
        let data = match self.read_from(self.offset) {
            Ok(data) => data,
            Err(err) => {
                log::trace!("file tailer read error: {err}");
                return Vec::new();
            }
        };
        if data.is_empty() {
            return Vec::new();
        }
        self.offset += data.len() as u64;
        self.consume(data)
    }

    fn read_from(&self, offset: u64) -> std::io::Result<Vec<u8>> {
        let mut file = File::open(&self.config.path)?;
        file.seek(SeekFrom::Start(offset))?;
        let mut data = Vec::new();
        file.read_to_end(&mut data)?;
        Ok(data)
    }

    /// Process-then-discard: prepend the fragment of the last poll, parse
    /// every complete line, keep only the unfinished last one.
    fn consume(&mut self, mut data: Vec<u8>) -> Vec<T> {
        if !self.buffer.is_empty() {
            let mut joined = std::mem::take(&mut self.buffer);
            joined.append(&mut data);
            data = joined;
        }
        let (lines, rest) = split_lines(&data);
        let rest = rest.to_vec();
        let mut items = Vec::new();
        for line in lines {
            match (self.parser)(&line) {
                Ok(item) => items.push(item),
                Err(err) => {
                    self.parse_errors += 1;
                    if self.parse_errors <= MAX_PARSE_ERROR_LOGS {
                        log::warn!(
                            "file tailer parse failed ({}): {err}. line={}",
                            self.parse_errors,
                            line.chars().take(120).collect::<String>()
                        );
                    }
                }
            }
        }
        if rest.len() > self.config.max_buffer_size {
            log::trace!(
                "file tailer fragment over {} bytes, discarding: {}",
                self.config.max_buffer_size,
                self.config.path.display()
            );
        } else {
            self.buffer = rest;
        }
        items
    }

    /// Forget the pending fragment (`stop`).
    pub fn stop(&mut self) {
        self.buffer.clear();
    }
}

/// A tailer running on its own thread; dropping the handle stops it.
pub struct TailerHandle {
    stop: Arc<AtomicBool>,
    thread: Option<JoinHandle<()>>,
}

impl TailerHandle {
    /// Start `tailer` (prefilling `prefill_lines`) and call `on_item` from
    /// the tailer thread for every parsed line.
    pub fn spawn<T: Send + 'static>(
        mut tailer: FileTailer<T>,
        prefill_lines: usize,
        on_item: impl Fn(T) + Send + 'static,
    ) -> Self {
        let stop = Arc::new(AtomicBool::new(false));
        let flag = stop.clone();
        let thread = std::thread::Builder::new()
            .name("chau7-file-tailer".into())
            .spawn(move || {
                for item in tailer.start(prefill_lines) {
                    on_item(item);
                }
                let interval = tailer.poll_interval();
                while !flag.load(Ordering::Acquire) {
                    // Sleep until the actual poll deadline. stop/drop unpark
                    // this thread; an early unpark retains its token, so a stop
                    // between this check and park cannot be lost.
                    std::thread::park_timeout(interval);
                    if flag.load(Ordering::Acquire) {
                        break;
                    }
                    for item in tailer.poll() {
                        on_item(item);
                    }
                }
                tailer.stop();
            })
            .ok();
        Self { stop, thread }
    }

    /// Stop the thread and wait for it.
    pub fn stop(&mut self) {
        self.stop.store(true, Ordering::Release);
        if let Some(thread) = self.thread.take() {
            thread.thread().unpark();
            let _ = thread.join();
        }
    }
}

impl Drop for TailerHandle {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Release);
        if let Some(thread) = &self.thread {
            thread.thread().unpark();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    fn temp(name: &str) -> PathBuf {
        let dir =
            std::env::temp_dir().join(format!("chau7-next-tailer-{}-{name}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir.join("log.txt")
    }

    fn append(path: &Path, text: &str) {
        let mut f = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(path)
            .unwrap();
        f.write_all(text.as_bytes()).unwrap();
    }

    fn lines_tailer(path: &Path) -> FileTailer<String> {
        FileTailer::new(TailerConfig::new(path), |l| Ok(l.to_string()))
    }

    #[test]
    fn reads_only_appended_lines() {
        let path = temp("append");
        append(&path, "old\n");
        let mut t = lines_tailer(&path);
        assert!(t.start(0).is_empty());
        assert!(t.poll().is_empty());
        append(&path, "one\ntwo\n");
        assert_eq!(t.poll(), ["one", "two"]);
        assert!(t.poll().is_empty());
    }

    #[test]
    fn buffers_a_partial_line() {
        let path = temp("partial");
        let mut t = lines_tailer(&path);
        t.start(0);
        append(&path, "hel");
        assert!(t.poll().is_empty());
        append(&path, "lo\nwor");
        assert_eq!(t.poll(), ["hello"]);
        append(&path, "ld\n");
        assert_eq!(t.poll(), ["world"]);
    }

    #[test]
    fn carriage_returns_end_lines_and_blanks_are_skipped() {
        let path = temp("cr");
        let mut t = lines_tailer(&path);
        t.start(0);
        append(&path, "a\r\nb\r\r  \nc\n");
        assert_eq!(t.poll(), ["a", "b", "c"]);
    }

    #[test]
    fn multibyte_character_split_across_reads() {
        let path = temp("utf8");
        let mut t = lines_tailer(&path);
        t.start(0);
        let bytes = "caf\u{e9}\n".as_bytes();
        let mut f = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(&path)
            .unwrap();
        f.write_all(&bytes[..4]).unwrap();
        assert!(t.poll().is_empty());
        f.write_all(&bytes[4..]).unwrap();
        assert_eq!(t.poll(), ["caf\u{e9}"]);
    }

    #[test]
    fn restarts_after_truncation() {
        let path = temp("trunc");
        append(&path, "first line here\n");
        let mut t = lines_tailer(&path);
        t.start(0);
        std::fs::write(&path, "new\n").unwrap();
        assert_eq!(t.poll(), ["new"]);
    }

    #[cfg(unix)]
    #[test]
    fn restarts_after_rotation_to_a_larger_file() {
        let path = temp("rotate");
        append(&path, "a\n");
        let mut t = lines_tailer(&path);
        t.start(0);
        std::fs::rename(&path, path.with_extension("1")).unwrap();
        append(&path, "fresh one\nfresh two\n");
        assert_eq!(t.poll(), ["fresh one", "fresh two"]);
    }

    #[test]
    fn prefill_reads_the_last_lines() {
        let path = temp("prefill");
        append(&path, "1\n2\n3\n4\n5\n");
        let mut t = lines_tailer(&path);
        assert_eq!(t.start(3), ["3", "4", "5"]);
        append(&path, "6\n");
        assert_eq!(t.poll(), ["6"]);
    }

    #[test]
    fn parse_errors_do_not_stop_the_tailer() {
        let path = temp("errors");
        let mut t = FileTailer::new(TailerConfig::new(&path), |l| {
            l.parse::<i32>().map_err(|e| e.to_string())
        });
        t.start(0);
        append(&path, "1\nx\n3\n");
        assert_eq!(t.poll(), [1, 3]);
    }

    #[test]
    fn creates_a_missing_file_when_asked() {
        let path = temp("create");
        let mut t = FileTailer::new(TailerConfig::history(&path), |l| Ok(l.to_string()));
        t.start(0);
        assert!(path.exists());
        let mut other = temp("nocreate");
        other.set_file_name("nope.txt");
        let mut t = lines_tailer(&other);
        t.start(0);
        assert!(!other.exists());
        assert!(t.poll().is_empty());
    }

    #[test]
    fn oversized_fragment_is_discarded() {
        let path = temp("big");
        let mut cfg = TailerConfig::new(&path);
        cfg.max_buffer_size = 8;
        let mut t = FileTailer::new(cfg, |l| Ok(l.to_string()));
        t.start(0);
        append(&path, "0123456789012345");
        assert!(t.poll().is_empty());
        append(&path, "x\nok\n");
        assert_eq!(t.poll(), ["x", "ok"]);
    }

    #[test]
    fn thread_delivers_items_and_stops() {
        let path = temp("thread");
        let mut cfg = TailerConfig::new(&path);
        cfg.poll_interval = Duration::from_millis(20);
        let tailer = FileTailer::new(cfg, |l| Ok(l.to_string()));
        let (tx, rx) = std::sync::mpsc::channel();
        let mut handle = TailerHandle::spawn(tailer, 0, move |s| {
            let _ = tx.send(s);
        });
        std::thread::sleep(Duration::from_millis(100));
        append(&path, "hello\n");
        let got = rx.recv_timeout(Duration::from_secs(3)).unwrap();
        assert_eq!(got, "hello");
        handle.stop();
    }

    #[test]
    fn long_poll_stop_is_prompt_even_before_the_first_wait() {
        let path = temp("stop-before-park");
        append(&path, "ready\n");
        let mut cfg = TailerConfig::new(&path);
        cfg.poll_interval = Duration::from_secs(3600);
        let tailer = FileTailer::new(cfg, |line| Ok(line.to_string()));
        let (ready_tx, ready_rx) = std::sync::mpsc::channel();
        let barrier = Arc::new(std::sync::Barrier::new(2));
        let worker_barrier = barrier.clone();
        let mut handle = TailerHandle::spawn(tailer, 1, move |_| {
            ready_tx.send(()).unwrap();
            worker_barrier.wait();
        });
        ready_rx.recv_timeout(Duration::from_secs(3)).unwrap();
        let stopped = handle.stop.clone();
        let (done_tx, done_rx) = std::sync::mpsc::channel();
        let stopper = std::thread::spawn(move || {
            handle.stop();
            done_tx.send(()).unwrap();
        });
        let deadline = std::time::Instant::now() + Duration::from_secs(3);
        while !stopped.load(Ordering::Acquire) {
            assert!(std::time::Instant::now() < deadline);
            std::thread::yield_now();
        }
        barrier.wait();
        done_rx.recv_timeout(Duration::from_secs(3)).unwrap();
        stopper.join().unwrap();
    }

    #[test]
    fn dropping_a_long_poll_handle_wakes_and_retires_its_worker() {
        struct Retired(std::sync::mpsc::Sender<()>);
        impl Drop for Retired {
            fn drop(&mut self) {
                let _ = self.0.send(());
            }
        }
        let path = temp("drop-parked");
        append(&path, "ready\n");
        let mut cfg = TailerConfig::new(&path);
        cfg.poll_interval = Duration::from_secs(3600);
        let tailer = FileTailer::new(cfg, |line| Ok(line.to_string()));
        let (ready_tx, ready_rx) = std::sync::mpsc::channel();
        let (retired_tx, retired_rx) = std::sync::mpsc::channel();
        let retired = Retired(retired_tx);
        let handle = TailerHandle::spawn(tailer, 1, move |_| {
            let _keep_until_thread_exit = &retired;
            ready_tx.send(()).unwrap();
        });
        ready_rx.recv_timeout(Duration::from_secs(3)).unwrap();
        std::thread::sleep(Duration::from_millis(50));
        drop(handle);
        retired_rx.recv_timeout(Duration::from_secs(3)).unwrap();
    }
}
