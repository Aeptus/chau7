//! Replace a document through an exclusively owned sibling temporary file.
use std::fs::{self, OpenOptions};
use std::io::{self, Write};
use std::path::Path;
use std::sync::atomic::{AtomicU64, Ordering};

static NEXT_TEMP: AtomicU64 = AtomicU64::new(0);

pub(super) fn write_atomic(path: &Path, content: &[u8]) -> io::Result<()> {
    // Saving through a symlink edits its target and keeps the link intact.
    let target = match fs::symlink_metadata(path) {
        Ok(metadata) if metadata.file_type().is_symlink() => fs::canonicalize(path)?,
        Ok(_) => path.to_path_buf(),
        Err(error) if error.kind() == io::ErrorKind::NotFound => path.to_path_buf(),
        Err(error) => return Err(error),
    };
    let permissions = match fs::metadata(&target) {
        Ok(metadata) => Some(metadata.permissions()),
        Err(error) if error.kind() == io::ErrorKind::NotFound => None,
        Err(error) => return Err(error),
    };
    let parent = target
        .parent()
        .filter(|p| !p.as_os_str().is_empty())
        .unwrap_or(Path::new("."));
    let (temporary, mut file) = loop {
        let temporary = parent.join(format!(
            ".chau7-save-{}-{}",
            std::process::id(),
            NEXT_TEMP.fetch_add(1, Ordering::Relaxed)
        ));
        let mut options = OpenOptions::new();
        options.write(true).create_new(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            // Never expose private document contents while constructing a save.
            options.mode(0o600);
        }
        match options.open(&temporary) {
            Ok(file) => break (temporary, file),
            Err(error) if error.kind() == io::ErrorKind::AlreadyExists => continue,
            Err(error) => return Err(error),
        }
    };
    let result = (|| {
        file.write_all(content)?;
        if let Some(permissions) = permissions {
            file.set_permissions(permissions)?;
        }
        file.sync_all()?;
        drop(file);
        fs::rename(&temporary, &target)
    })();
    if result.is_err() {
        let _ = fs::remove_file(&temporary);
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;
    struct Directory(std::path::PathBuf);
    impl Directory {
        fn new() -> Self {
            let path = std::env::temp_dir().join(format!(
                "chau7-save-test-{}-{}",
                std::process::id(),
                NEXT_TEMP.fetch_add(1, Ordering::Relaxed)
            ));
            fs::create_dir(&path).unwrap();
            Self(path)
        }
    }
    impl Drop for Directory {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    #[test]
    fn saves_never_touch_the_previous_fixed_temporary_filename() {
        let dir = Directory::new();
        let path = dir.0.join("note.md");
        let unrelated = dir.0.join("note.md.chau7-tmp");
        fs::write(&path, "old").unwrap();
        fs::write(&unrelated, "do not touch").unwrap();
        write_atomic(&path, "café😀".as_bytes()).unwrap();
        assert_eq!(fs::read_to_string(&path).unwrap(), "café😀");
        assert_eq!(fs::read_to_string(&unrelated).unwrap(), "do not touch");
        assert_eq!(fs::read_dir(&dir.0).unwrap().count(), 2);
    }

    #[cfg(unix)]
    #[test]
    fn saves_preserve_executable_permissions_and_symlinks() {
        use std::os::unix::fs::{PermissionsExt, symlink};
        let dir = Directory::new();
        let target = dir.0.join("script.sh");
        let link = dir.0.join("link.sh");
        fs::write(&target, "old").unwrap();
        fs::set_permissions(&target, fs::Permissions::from_mode(0o750)).unwrap();
        symlink("script.sh", &link).unwrap();
        write_atomic(&link, b"new").unwrap();
        assert!(
            fs::symlink_metadata(&link)
                .unwrap()
                .file_type()
                .is_symlink()
        );
        assert_eq!(fs::read_link(&link).unwrap(), Path::new("script.sh"));
        assert_eq!(fs::read_to_string(&target).unwrap(), "new");
        assert_eq!(
            fs::metadata(&target).unwrap().permissions().mode() & 0o777,
            0o750
        );
    }

    #[test]
    fn a_failed_replacement_leaves_target_and_no_temporary_file() {
        let dir = Directory::new();
        let target = dir.0.join("directory");
        fs::create_dir(&target).unwrap();
        assert!(write_atomic(&target, b"new").is_err());
        assert!(target.is_dir());
        assert_eq!(fs::read_dir(&dir.0).unwrap().count(), 1);
    }

    #[cfg(unix)]
    #[test]
    fn a_dangling_link_is_not_replaced_with_a_regular_file() {
        use std::os::unix::fs::symlink;
        let dir = Directory::new();
        let link = dir.0.join("link.md");
        symlink("missing.md", &link).unwrap();
        assert!(write_atomic(&link, b"new").is_err());
        assert!(
            fs::symlink_metadata(&link)
                .unwrap()
                .file_type()
                .is_symlink()
        );
    }
}
