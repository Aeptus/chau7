//! The file writer of the app log (`Log.fileQueue`): lines are queued and
//! written on one thread, so logging never waits for the disk. If the file
//! cannot be opened (or a trim broke the handle) it is reopened on the next
//! line and external inode replacements are observed before the next write.
//! Every 200 writes the active file keeps its newest half while five archives
//! preserve complete earlier logs. Repeated failures emit bounded summaries.

use std::fs::{File, OpenOptions};
use std::io::{Read, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};
use std::sync::mpsc::{Receiver, Sender, channel};
use std::time::{Duration, Instant};

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

const ARCHIVE_COUNT: usize = 5;
const FAILURE_REPORT_INTERVAL: Duration = Duration::from_secs(60);
#[derive(Default)]
struct FailureLimiter {
    last: Option<Instant>,
    suppressed: u64,
}
impl FailureLimiter {
    fn record(&mut self, now: Instant) -> Option<u64> {
        if self
            .last
            .is_none_or(|last| now.saturating_duration_since(last) >= FAILURE_REPORT_INTERVAL)
        {
            let suppressed = std::mem::take(&mut self.suppressed);
            self.last = Some(now);
            Some(suppressed)
        } else {
            self.suppressed = self.suppressed.saturating_add(1);
            None
        }
    }
    fn report(&mut self, operation: &str) {
        if let Some(suppressed) = self.record(Instant::now()) {
            eprintln!(
                "[Chau7 Next] log {operation} failed (suppressed {suppressed} repeated failures)"
            );
        }
    }
}
fn same_file(handle: &File, path: &Path) -> bool {
    chau7_next_core::file_identity::for_file(handle)
        .ok()
        .zip(chau7_next_core::file_identity::for_path(path).ok())
        .is_some_and(|(open, current)| open == current)
}

fn run(rx: Receiver<Msg>, path: PathBuf, max_bytes: u64) {
    let mut file = open(&path);
    let mut failures = FailureLimiter::default();
    if file.is_none() {
        failures.report("open");
    }
    let mut writes: u64 = 0;
    while let Ok(msg) = rx.recv() {
        match msg {
            Msg::Line(line) => {
                // External rotation must not strand future records on the old
                // inode. This check runs on the serial writer, never the UI.
                if file
                    .as_ref()
                    .is_some_and(|handle| !same_file(handle, &path))
                {
                    file = None;
                }
                if file.is_none() {
                    file = open(&path);
                }
                let Some(handle) = file.as_mut() else {
                    failures.report("open");
                    continue;
                };
                if writeln!(handle, "{line}").is_err() {
                    failures.report("write");
                    file = None;
                    continue;
                }
                writes = writes.wrapping_add(1);
                if max_bytes > 0 && writes.is_multiple_of(TRIM_CHECK_EVERY) {
                    // Closing before rename also supports Windows open-handle
                    // rules; the next line/flush reopens the authoritative file.
                    drop(file.take());
                    if rotate_tail(&path, max_bytes, ARCHIVE_COUNT).is_err() {
                        failures.report("rotation");
                    }
                    file = open(&path);
                    if file.is_none() {
                        failures.report("reopen");
                    }
                }
            }
            Msg::Flush(ack) => {
                if let Some(handle) = file.as_mut()
                    && handle.flush().is_err()
                {
                    failures.report("flush");
                    file = None;
                }
                let _ = ack.send(());
            }
        }
    }
}
fn archive_path(path: &Path, index: usize) -> PathBuf {
    let mut archived = path.as_os_str().to_owned();
    archived.push(format!(".{index}"));
    PathBuf::from(archived)
}
/// Retain complete pre-rotation logs in the five current-Swift archive slots.
fn rotate_tail(path: &Path, max_bytes: u64, count: usize) -> std::io::Result<bool> {
    let size = std::fs::metadata(path)?.len();
    let Some(keep) = trim_keep(size, max_bytes) else {
        return Ok(false);
    };
    let tail = read_tail(path, size, keep)?;
    if count == 0 {
        replace_with(path, &tail)?;
        return Ok(true);
    }
    let temporary = prepare_replacement(path, &tail)?;
    let result = (|| {
        for index in (2..=count).rev() {
            let source = archive_path(path, index - 1);
            let target = archive_path(path, index);
            if source.exists() {
                if target.exists() {
                    std::fs::remove_file(&target)?;
                }
                std::fs::rename(&source, &target)?;
            }
        }
        let archive = archive_path(path, 1);
        if archive.exists() {
            std::fs::remove_file(&archive)?;
        }
        std::fs::rename(path, &archive)?;
        if let Err(error) = std::fs::rename(&temporary, path) {
            // Preserve the complete original if publishing the prepared tail
            // fails; logging remains recoverable on the next queued line.
            let _ = std::fs::rename(&archive, path);
            return Err(error);
        }
        Ok(true)
    })();
    if result.is_err() {
        let _ = std::fs::remove_file(&temporary);
    }
    result
}

/// The last `keep` bytes of a file of `size` bytes, starting after the first
/// newline of the cut (a partial line is dropped).
pub fn read_tail(path: &Path, size: u64, keep: u64) -> std::io::Result<Vec<u8>> {
    let mut file = File::open(path)?;
    let start = size.saturating_sub(keep);
    file.seek(SeekFrom::Start(start))?;
    let capacity = usize::try_from(keep.min(size))
        .unwrap_or(0)
        .min(16 * 1024 * 1024);
    let mut tail = Vec::with_capacity(capacity);
    // Read only the observed suffix. A growing writer cannot make this
    // supposedly bounded operation follow an unbounded stream to EOF.
    file.take(size.saturating_sub(start))
        .read_to_end(&mut tail)?;
    if start > 0 {
        match tail.iter().position(|b| *b == b'\n') {
            Some(newline) => {
                tail.drain(..=newline);
            }
            None => tail.clear(),
        }
    }
    Ok(tail)
}
fn prepare_replacement(path: &Path, data: &[u8]) -> std::io::Result<PathBuf> {
    let metadata = std::fs::symlink_metadata(path)?;
    if !metadata.is_file() {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidInput,
            "log replacement requires a regular file",
        ));
    }
    let mut name = path.as_os_str().to_owned();
    name.push(format!(".{}.tmp", uuid::Uuid::new_v4()));
    let temporary = PathBuf::from(name);
    let result = (|| {
        let mut file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&temporary)?;
        file.write_all(data)?;
        file.set_permissions(metadata.permissions())?;
        file.sync_all()?;
        Ok(())
    })();
    if let Err(error) = result {
        let _ = std::fs::remove_file(&temporary);
        return Err(error);
    }
    Ok(temporary)
}
/// Atomically publish a uniquely created sibling; unrelated .tmp files and
/// symlink destinations are never overwritten.
pub fn replace_with(path: &Path, data: &[u8]) -> std::io::Result<()> {
    let temporary = prepare_replacement(path, data)?;
    let result = std::fs::rename(&temporary, path);
    if result.is_err() {
        let _ = std::fs::remove_file(temporary);
    }
    result
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
        assert!(!rotate_tail(&path, size, 0).unwrap());
        // Over the cap: about half is kept, ending with the newest line.
        assert!(rotate_tail(&path, size - 1, 0).unwrap());
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
    #[test]
    fn bounded_suffix_drops_partial_record_without_following_growth() {
        let dir = temp("bounded-tail");
        let path = dir.join("log");
        std::fs::write(&path, b"old\nlast\nnewer-growth\n").unwrap();
        assert_eq!(read_tail(&path, 9, 6).unwrap(), b"last\n");
        assert_eq!(read_tail(&path, 9, 3).unwrap(), b"");
        assert_eq!(read_tail(&path, 9, 0).unwrap(), b"");
        let _ = std::fs::remove_dir_all(dir);
    }
    #[test]
    fn rotation_keeps_five_complete_archives_and_active_line_aligned_tail() {
        let dir = temp("archives");
        let path = dir.join("log");
        for index in 0..7 {
            let complete = format!("original-{index}\nrecent-{index}\n");
            std::fs::write(&path, &complete).unwrap();
            assert!(rotate_tail(&path, 10, 5).unwrap());
            assert_eq!(
                std::fs::read_to_string(archive_path(&path, 1)).unwrap(),
                complete
            );
        }
        for index in 1..=5 {
            assert!(
                std::fs::read_to_string(archive_path(&path, index))
                    .unwrap()
                    .contains(&format!("original-{}", 7 - index))
            );
        }
        assert!(!archive_path(&path, 6).exists());
        assert_eq!(std::fs::read(&path).unwrap(), b"");
        let _ = std::fs::remove_dir_all(dir);
    }
    #[test]
    fn writer_reopens_external_rotation_and_preserves_unrelated_temp() {
        let dir = temp("external-rotation");
        let path = dir.join("log");
        let unrelated = dir.join("log.tmp");
        std::fs::write(&unrelated, b"unrelated").unwrap();
        let writer = Writer::spawn(path.clone(), 1000);
        writer.write("before".into());
        writer.flush(Duration::from_secs(5));
        let rotated = dir.join("external-archive");
        std::fs::rename(&path, &rotated).unwrap();
        std::fs::write(&path, b"new file\n").unwrap();
        writer.write("after".into());
        writer.flush(Duration::from_secs(5));
        assert_eq!(std::fs::read(&rotated).unwrap(), b"before\n");
        assert_eq!(std::fs::read(&path).unwrap(), b"new file\nafter\n");
        replace_with(&path, b"replacement").unwrap();
        assert_eq!(std::fs::read(&unrelated).unwrap(), b"unrelated");
        drop(writer);
        let _ = std::fs::remove_dir_all(dir);
    }
    #[test]
    fn repeated_writer_failures_emit_one_bounded_summary_per_minute() {
        let now = Instant::now();
        let mut limiter = FailureLimiter::default();
        assert_eq!(limiter.record(now), Some(0));
        for _ in 0..5000 {
            assert_eq!(limiter.record(now + Duration::from_secs(1)), None);
        }
        assert_eq!(limiter.record(now + Duration::from_secs(60)), Some(5000));
        assert_eq!(limiter.record(now + Duration::from_secs(61)), None);
    }
    #[test]
    fn rotation_failure_keeps_authoritative_log_and_cleans_prepared_sibling() {
        let dir = temp("failed-archive");
        let path = dir.join("log");
        let original = b"complete original record\nmost recent record\n";
        std::fs::write(&path, original).unwrap();
        std::fs::write(archive_path(&path, 4), b"previous archive").unwrap();
        std::fs::create_dir(archive_path(&path, 5)).unwrap();
        assert!(rotate_tail(&path, 10, 5).is_err());
        assert_eq!(std::fs::read(&path).unwrap(), original);
        assert!(
            std::fs::read_dir(&dir)
                .unwrap()
                .flatten()
                .all(|entry| !entry.file_name().to_string_lossy().ends_with(".tmp"))
        );
        let _ = std::fs::remove_dir_all(dir);
    }
    #[cfg(unix)]
    #[test]
    fn replacement_preserves_permissions_and_refuses_symlink_destination() {
        use std::os::unix::fs::PermissionsExt;
        let dir = temp("permissions");
        let path = dir.join("log");
        let alias = dir.join("alias");
        std::fs::write(&path, b"original").unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600)).unwrap();
        replace_with(&path, b"new").unwrap();
        assert_eq!(
            std::fs::metadata(&path).unwrap().permissions().mode() & 0o777,
            0o600
        );
        std::os::unix::fs::symlink(&path, &alias).unwrap();
        assert!(replace_with(&alias, b"foreign").is_err());
        assert_eq!(std::fs::read(&path).unwrap(), b"new");
        let _ = std::fs::remove_dir_all(dir);
    }
}
