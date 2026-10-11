//! Bounded read-only incremental JSONL tails, including rotation and partial lines.
use std::{
    fs::File,
    io::{Read, Seek, SeekFrom},
    path::{Path, PathBuf},
    time::SystemTime,
};
const FIRST_BYTES: u64 = 262_144;
const MAX_BYTES: u64 = 1_048_576;
#[derive(Default)]
pub struct JsonlTail {
    path: PathBuf,
    offset: u64,
    size: u64,
    modified: Option<SystemTime>,
    identity: Option<(u64, u64)>,
    carry: Vec<u8>,
    discard_line: bool,
}
impl JsonlTail {
    pub fn read(&mut self, path: &Path) -> std::io::Result<String> {
        let mut file = File::open(path)?;
        let metadata = file.metadata()?;
        let size = metadata.len();
        let modified = metadata.modified().ok();
        #[cfg(unix)]
        let identity = {
            use std::os::unix::fs::MetadataExt;
            Some((metadata.dev(), metadata.ino()))
        };
        #[cfg(windows)]
        let identity = Some(windows_file_identity(&file)?);
        #[cfg(not(any(unix, windows)))]
        let identity = None;
        let reset = self.path != path
            || self.identity != identity
            || size < self.offset
            || size == self.size && modified != self.modified;
        if !reset && size == self.size && modified == self.modified && self.offset == size {
            return Ok(String::new());
        }
        if reset {
            self.path = path.to_owned();
            self.offset = size.saturating_sub(FIRST_BYTES);
            self.carry.clear();
            self.discard_line = self.offset > 0;
        }
        file.seek(SeekFrom::Start(self.offset))?;
        let mut bytes = Vec::new();
        file.take((size - self.offset).min(MAX_BYTES))
            .read_to_end(&mut bytes)?;
        self.offset += bytes.len() as u64;
        self.size = size;
        self.modified = modified;
        self.identity = identity;
        if self.discard_line {
            if let Some(i) = bytes.iter().position(|b| *b == b'\n') {
                bytes.drain(..=i);
                self.discard_line = false;
            } else {
                bytes.clear();
            }
        }
        self.carry.extend(bytes);
        let result = if let Some(i) = self.carry.iter().rposition(|b| *b == b'\n') {
            let result = String::from_utf8_lossy(&self.carry[..=i]).into_owned();
            self.carry.drain(..=i);
            result
        } else {
            String::new()
        };
        if self.carry.len() > MAX_BYTES as usize {
            self.carry.clear();
            self.discard_line = true;
        }
        Ok(result)
    }
}
// Read identity from the same handle as metadata and contents, so a replacement
// between opening and reading cannot pair the new file with the old offset.
#[cfg(windows)]
fn windows_file_identity(file: &File) -> std::io::Result<(u64, u64)> {
    use std::os::windows::io::AsRawHandle;
    use windows_sys::Win32::Storage::FileSystem::{
        BY_HANDLE_FILE_INFORMATION, GetFileInformationByHandle,
    };
    let mut info = std::mem::MaybeUninit::<BY_HANDLE_FILE_INFORMATION>::uninit();
    // SAFETY: File owns a live handle throughout the call, and info points to a
    // writable buffer with exactly the layout required by the Windows API.
    let success = unsafe { GetFileInformationByHandle(file.as_raw_handle(), info.as_mut_ptr()) };
    if success == 0 {
        return Err(std::io::Error::last_os_error());
    }
    // SAFETY: A successful call initializes all fields of the output structure.
    let info = unsafe { info.assume_init() };
    Ok((
        u64::from(info.dwVolumeSerialNumber),
        u64::from(info.nFileIndexHigh) << 32 | u64::from(info.nFileIndexLow),
    ))
}
#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;
    #[test]
    fn partial_lines_rotation_and_truncation() {
        let d = std::env::temp_dir().join(format!("chau7-tail-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&d).unwrap();
        let p = d.join("a");
        std::fs::write(&p, b"first\npar").unwrap();
        let mut t = JsonlTail::default();
        assert_eq!(t.read(&p).unwrap(), "first\n");
        assert!(t.read(&p).unwrap().is_empty());
        File::options()
            .append(true)
            .open(&p)
            .unwrap()
            .write_all(b"tial\n")
            .unwrap();
        assert_eq!(t.read(&p).unwrap(), "partial\n");
        std::fs::write(&p, b"x\n").unwrap();
        assert_eq!(t.read(&p).unwrap(), "x\n");
        std::fs::rename(&p, d.join("old")).unwrap();
        std::fs::write(&p, b"rotated\n").unwrap();
        assert_eq!(t.read(&p).unwrap(), "rotated\n");
        std::fs::remove_dir_all(d).unwrap();
    }
    #[test]
    fn same_size_rotation_with_same_timestamp_resets_identity() {
        let d = std::env::temp_dir().join(format!("chau7-tail-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&d).unwrap();
        let p = d.join("a");
        std::fs::write(&p, b"first\ncarry").unwrap();
        let previous_modified = p.metadata().unwrap().modified().unwrap();
        let mut tail = JsonlTail::default();
        assert_eq!(tail.read(&p).unwrap(), "first\n");
        std::fs::rename(&p, d.join("old")).unwrap();
        std::fs::write(&p, b"other\nlast\n").unwrap();
        File::options()
            .write(true)
            .open(&p)
            .unwrap()
            .set_modified(previous_modified)
            .unwrap();
        assert_eq!(tail.read(&p).unwrap(), "other\nlast\n");
        assert!(tail.read(&p).unwrap().is_empty());
        std::fs::remove_dir_all(d).unwrap();
    }
    #[test]
    fn bounded_first_read() {
        let p = std::env::temp_dir().join(format!("chau7-tail-{}", uuid::Uuid::new_v4()));
        let mut bytes = vec![b'x'; 2_000_000];
        bytes.extend(b"\nlast\n");
        std::fs::write(&p, bytes).unwrap();
        assert_eq!(JsonlTail::default().read(&p).unwrap(), "last\n");
        std::fs::remove_file(p).unwrap();
    }
}
