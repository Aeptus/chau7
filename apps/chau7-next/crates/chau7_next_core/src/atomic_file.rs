//! Crash-safe file replacement shared by both crates (no Swift counterpart:
//! Swift uses `Data.write(options: .atomic)`).
//!
//! [`write`] puts the bytes in a uniquely named temporary file next to the
//! target, flushes it, renames it over the target and flushes the folder, so
//! a crash leaves either the old file or the new one, never half of either.
//! [`sweep_stale_temps`] removes temporary files a crash left behind.

use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime};

/// Temporary files older than this are leftovers of a crashed write.
pub const STALE_TEMP_AGE: Duration = Duration::from_secs(5 * 60);

fn temp_path(parent: &Path, path: &Path) -> PathBuf {
    let name = path
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_else(|| "file".into());
    parent.join(format!(".{name}.{}.tmp", uuid::Uuid::new_v4()))
}

/// Whether `name` is a temporary file of [`write`] (or of the restore
/// store's earlier `.restore-<uuid>.tmp` scheme).
pub fn is_temp_name(name: &str) -> bool {
    let Some(stem) = name
        .strip_prefix('.')
        .and_then(|rest| rest.strip_suffix(".tmp"))
    else {
        return false;
    };
    if let Some(id) = stem.strip_prefix("restore-") {
        return uuid::Uuid::parse_str(id).is_ok();
    }
    stem.rsplit_once('.')
        .is_some_and(|(_, id)| uuid::Uuid::parse_str(id).is_ok())
}

/// Replace `path` with `bytes` atomically and durably. The parent folder is
/// created when missing. A new file is private (0600); an existing file keeps
/// its permissions. The temporary file is removed when anything fails.
pub fn write(path: &Path, bytes: &[u8]) -> io::Result<()> {
    let parent = match path.parent() {
        Some(parent) if !parent.as_os_str().is_empty() => parent,
        _ => return Err(io::Error::other("missing parent directory")),
    };
    std::fs::create_dir_all(parent)?;
    let tmp = temp_path(parent, path);
    let result = (|| {
        let mut options = std::fs::OpenOptions::new();
        options.write(true).create_new(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600);
        }
        let mut file = options.open(&tmp)?;
        if let Ok(meta) = std::fs::metadata(path) {
            file.set_permissions(meta.permissions())?;
        }
        file.write_all(bytes)?;
        file.sync_all()?;
        drop(file);
        std::fs::rename(&tmp, path)?;
        #[cfg(unix)]
        std::fs::File::open(parent)?.sync_all()?;
        Ok(())
    })();
    if result.is_err() {
        let _ = std::fs::remove_file(&tmp);
    }
    result
}

/// Remove temporary files of [`write`] in `dir` that are older than
/// `max_age`. Only regular files with a temporary name are touched. Returns
/// how many were removed.
pub fn sweep_stale_temps(dir: &Path, max_age: Duration) -> usize {
    let Ok(entries) = std::fs::read_dir(dir) else {
        return 0;
    };
    let now = SystemTime::now();
    let mut removed = 0;
    for entry in entries.flatten() {
        if !is_temp_name(&entry.file_name().to_string_lossy()) {
            continue;
        }
        let Ok(meta) = std::fs::symlink_metadata(entry.path()) else {
            continue;
        };
        let stale = meta
            .modified()
            .is_ok_and(|at| now.duration_since(at).unwrap_or_default() > max_age);
        if meta.is_file() && stale && std::fs::remove_file(entry.path()).is_ok() {
            removed += 1;
        }
    }
    removed
}

#[cfg(test)]
mod tests {
    use super::*;

    struct TempDir(PathBuf);
    impl TempDir {
        fn new() -> Self {
            let path = std::env::temp_dir().join(format!(
                "chau7-next-atomic-file-test-{}",
                uuid::Uuid::new_v4()
            ));
            std::fs::create_dir_all(&path).unwrap();
            Self(path)
        }
    }
    impl Drop for TempDir {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    fn names(dir: &Path) -> Vec<String> {
        let mut names: Vec<_> = std::fs::read_dir(dir)
            .unwrap()
            .flatten()
            .map(|e| e.file_name().to_string_lossy().into_owned())
            .collect();
        names.sort();
        names
    }

    #[test]
    fn replaces_the_file_through_a_new_inode_and_leaves_no_temp() {
        let dir = TempDir::new();
        let path = dir.0.join("nested/config.toml");
        write(&path, b"old").unwrap();
        // A hard link to the old file keeps the old bytes: the target is
        // replaced by a rename, never truncated in place.
        let snapshot = dir.0.join("snapshot");
        std::fs::hard_link(&path, &snapshot).unwrap();
        write(&path, b"new").unwrap();
        assert_eq!(std::fs::read(&path).unwrap(), b"new");
        assert_eq!(std::fs::read(&snapshot).unwrap(), b"old");
        assert_eq!(names(&dir.0.join("nested")), vec!["config.toml"]);
    }

    #[cfg(unix)]
    #[test]
    fn new_files_are_private_and_existing_permissions_are_kept() {
        use std::os::unix::fs::PermissionsExt;
        let dir = TempDir::new();
        let path = dir.0.join("a.json");
        write(&path, b"1").unwrap();
        let mode = |p: &Path| std::fs::metadata(p).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode(&path), 0o600);
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o644)).unwrap();
        write(&path, b"2").unwrap();
        assert_eq!(mode(&path), 0o644);
    }

    #[test]
    fn a_failed_write_removes_its_temp_and_keeps_the_target() {
        let dir = TempDir::new();
        let path = dir.0.join("target");
        // A directory cannot be replaced by a file: the rename fails.
        std::fs::create_dir(&path).unwrap();
        std::fs::write(path.join("inside"), b"kept").unwrap();
        assert!(write(&path, b"bytes").is_err());
        assert_eq!(names(&dir.0), vec!["target"]);
        assert_eq!(std::fs::read(path.join("inside")).unwrap(), b"kept");
    }

    #[test]
    fn temp_names_are_recognized() {
        let id = uuid::Uuid::new_v4();
        assert!(is_temp_name(&format!(".session.json.{id}.tmp")));
        assert!(is_temp_name(&format!(".restore-{id}.tmp")));
        assert!(!is_temp_name("session.json"));
        assert!(!is_temp_name(".deleted.json.tmp"));
        assert!(!is_temp_name(&format!("session.json.{id}.tmp")));
    }

    #[test]
    fn sweep_removes_only_stale_temp_files() {
        let dir = TempDir::new();
        let old = SystemTime::now() - Duration::from_secs(3600);
        let stale = dir.0.join(format!(".a.json.{}.tmp", uuid::Uuid::new_v4()));
        let legacy = dir.0.join(format!(".restore-{}.tmp", uuid::Uuid::new_v4()));
        let fresh = dir.0.join(format!(".b.json.{}.tmp", uuid::Uuid::new_v4()));
        let other = dir.0.join(".other.tmp");
        for path in [&stale, &legacy, &fresh, &other] {
            std::fs::write(path, b"x").unwrap();
        }
        for path in [&stale, &legacy, &other] {
            std::fs::File::options()
                .write(true)
                .open(path)
                .unwrap()
                .set_modified(old)
                .unwrap();
        }
        assert_eq!(sweep_stale_temps(&dir.0, STALE_TEMP_AGE), 2);
        assert!(!stale.exists() && !legacy.exists());
        assert!(fresh.exists() && other.exists());
    }
}
