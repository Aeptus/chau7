//! Launch-time purge of AI PTY logs (`purgeLargePTYLogs` in
//! `App/AppDelegate.swift`): every `*-pty.log` over 10 MB is cut to its last
//! 5 MB ([`purge_large_logs`]).
//!
//! The logs themselves are written by `crate::ai::session_log` (one writer
//! for AIX-009, LOG-026 and TRM-045).

use std::fs::File;
use std::io::{Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};

use chau7_next_core::logging::{PTY_PURGE_KEEP_BYTES, is_pty_log_name, purge_keep};

/// Replace the file by its last `keep` bytes (the cut may fall inside a line:
/// PTY data is not line based).
fn rewrite_tail(path: &Path, size: u64, keep: u64) -> std::io::Result<()> {
    let mut file = File::open(path)?;
    file.seek(SeekFrom::Start(size.saturating_sub(keep)))?;
    let mut tail = Vec::new();
    file.read_to_end(&mut tail)?;
    super::writer::replace_with(path, &tail)
}

/// On launch: cut every `*-pty.log` over 10 MB to its last 5 MB. Runs on a
/// background thread. Returns nothing; results go to the log.
pub fn purge_large_logs(dir: PathBuf) {
    let _ = std::thread::Builder::new()
        .name("chau7-next-pty-purge".into())
        .spawn(move || {
            let purged = purge_dir(&dir);
            for (name, size) in purged {
                log::info!(
                    "Purged PTY log {name}: {}MB -> {}MB",
                    size / 1024 / 1024,
                    PTY_PURGE_KEEP_BYTES / 1024 / 1024
                );
            }
        });
}

/// The synchronous part of [`purge_large_logs`]: the (name, old size) of each
/// purged file.
pub fn purge_dir(dir: &Path) -> Vec<(String, u64)> {
    let Ok(entries) = std::fs::read_dir(dir) else {
        return Vec::new();
    };
    let mut purged = Vec::new();
    for entry in entries.flatten() {
        let name = entry.file_name().to_string_lossy().to_string();
        if !is_pty_log_name(&name) {
            continue;
        }
        let path = entry.path();
        let Ok(size) = std::fs::metadata(&path).map(|m| m.len()) else {
            continue;
        };
        let Some(keep) = purge_keep(size) else {
            continue;
        };
        match rewrite_tail(&path, size, keep) {
            Ok(()) => purged.push((name, size)),
            Err(err) => log::warn!("Failed to purge PTY log {name}: {err}"),
        }
    }
    purged
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp(name: &str) -> PathBuf {
        let dir =
            std::env::temp_dir().join(format!("chau7-next-aipty-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn purge_cuts_only_big_pty_logs() {
        let dir = temp("purge");
        let big = dir.join("claude-pty.log");
        let other = dir.join("notes.txt");
        let small = dir.join("codex-pty.log");
        let size = (10 * 1024 * 1024 + 1) as usize;
        std::fs::write(&big, vec![b'a'; size]).unwrap();
        std::fs::write(&other, vec![b'b'; size]).unwrap();
        std::fs::write(&small, b"tiny").unwrap();
        let purged = purge_dir(&dir);
        assert_eq!(purged.len(), 1);
        assert_eq!(purged[0].0, "claude-pty.log");
        assert_eq!(std::fs::metadata(&big).unwrap().len(), PTY_PURGE_KEEP_BYTES);
        assert_eq!(std::fs::metadata(&other).unwrap().len(), size as u64);
        assert_eq!(std::fs::read(&small).unwrap(), b"tiny");
        let _ = std::fs::remove_dir_all(&dir);
    }
}
