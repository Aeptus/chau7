//! Stable filesystem identity from an open handle, including Windows rotations.
use std::{fs::File, io, path::Path};

pub type FileIdentity = (u64, u64);

pub fn for_file(file: &File) -> io::Result<FileIdentity> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        let metadata = file.metadata()?;
        Ok((metadata.dev(), metadata.ino()))
    }
    #[cfg(windows)]
    {
        use std::os::windows::io::AsRawHandle;
        use windows_sys::Win32::Storage::FileSystem::{
            BY_HANDLE_FILE_INFORMATION, GetFileInformationByHandle,
        };
        let mut info = std::mem::MaybeUninit::<BY_HANDLE_FILE_INFORMATION>::uninit();
        // SAFETY: File owns a live handle throughout the call. The output
        // buffer has exactly the layout required by the Windows API.
        let success =
            unsafe { GetFileInformationByHandle(file.as_raw_handle(), info.as_mut_ptr()) };
        if success == 0 {
            return Err(io::Error::last_os_error());
        }
        // SAFETY: A successful call initializes the complete output structure.
        let info = unsafe { info.assume_init() };
        Ok((
            u64::from(info.dwVolumeSerialNumber),
            u64::from(info.nFileIndexHigh) << 32 | u64::from(info.nFileIndexLow),
        ))
    }
    #[cfg(not(any(unix, windows)))]
    {
        let _ = file;
        Err(io::Error::new(
            io::ErrorKind::Unsupported,
            "stable file identity is unavailable",
        ))
    }
}

pub fn for_path(path: &Path) -> io::Result<FileIdentity> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        let metadata = std::fs::metadata(path)?;
        Ok((metadata.dev(), metadata.ino()))
    }
    #[cfg(windows)]
    {
        use std::os::windows::fs::OpenOptionsExt;
        use windows_sys::Win32::Storage::FileSystem::FILE_FLAG_BACKUP_SEMANTICS;
        // Directory handles need this flag; it does not request backup privileges.
        let file = File::options()
            .read(true)
            .custom_flags(FILE_FLAG_BACKUP_SEMANTICS)
            .open(path)?;
        for_file(&file)
    }
    #[cfg(not(any(unix, windows)))]
    {
        let _ = path;
        Err(io::Error::new(
            io::ErrorKind::Unsupported,
            "stable file identity is unavailable",
        ))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    #[test]
    fn appends_keep_identity_but_equal_size_replacements_do_not() {
        let dir = std::env::temp_dir().join(format!("c7n-file-identity-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("file");
        std::fs::write(&path, b"before").unwrap();
        let original = File::open(&path).unwrap();
        let identity = for_file(&original).unwrap();
        assert_eq!(for_path(&path).unwrap(), identity);
        let mut append = File::options().append(true).open(&path).unwrap();
        append.write_all(b"!").unwrap();
        drop(append);
        assert_eq!(for_path(&path).unwrap(), identity);
        let archive = dir.join("archive");
        std::fs::rename(&path, &archive).unwrap();
        std::fs::write(&path, b"newfile").unwrap();
        assert_ne!(for_path(&path).unwrap(), identity);
        assert_eq!(for_file(&original).unwrap(), identity);
        assert_eq!(for_path(&dir).unwrap(), for_path(&dir).unwrap());
        drop(original);
        std::fs::remove_dir_all(dir).unwrap();
    }
}
