//! Tab-scoped session notes live in Next's overlay; repository metadata is read only.
use crate::data_root::DataRoot;
use std::path::{Path, PathBuf};
use uuid::Uuid;

pub fn path(root: &DataRoot, repo: &Path, tab: Uuid) -> PathBuf {
    root.repo_overlay_dir(repo)
        .join("session-notes")
        .join(tab.to_string())
        .join("note.md")
}
/// Focus precedence is resolved before checking existence; stale focus never falls through.
pub fn selected_repository(candidates: &[Option<PathBuf>]) -> Option<PathBuf> {
    candidates
        .iter()
        .find_map(|p| p.as_ref().filter(|p| !p.as_os_str().is_empty()))
        .cloned()
}
pub fn existing(root: &DataRoot, repo: &Path, tab: Uuid) -> Option<PathBuf> {
    access(root, repo, tab, false)
}
pub fn prepare(root: &DataRoot, repo: &Path, tab: Uuid) -> Option<PathBuf> {
    access(root, repo, tab, true)
}

#[cfg(unix)]
fn access(root: &DataRoot, repo: &Path, tab: Uuid, create: bool) -> Option<PathBuf> {
    use std::ffi::CString;
    use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
    use std::os::unix::ffi::OsStrExt;
    fn open_dir(path: &Path) -> Option<OwnedFd> {
        let path = CString::new(path.as_os_str().as_bytes()).ok()?;
        let fd = unsafe {
            libc::open(
                path.as_ptr(),
                libc::O_RDONLY | libc::O_DIRECTORY | libc::O_CLOEXEC | libc::O_NOFOLLOW,
            )
        };
        (fd >= 0).then(|| unsafe { OwnedFd::from_raw_fd(fd) })
    }
    fn stat_fd(fd: &OwnedFd) -> Option<libc::stat> {
        let mut stat = std::mem::MaybeUninit::uninit();
        (unsafe { libc::fstat(fd.as_raw_fd(), stat.as_mut_ptr()) } == 0)
            .then(|| unsafe { stat.assume_init() })
    }
    fn named(parent: &OwnedFd, name: &CString, child: &OwnedFd) -> bool {
        let Some(opened) = stat_fd(child) else {
            return false;
        };
        let mut current = std::mem::MaybeUninit::uninit();
        if unsafe {
            libc::fstatat(
                parent.as_raw_fd(),
                name.as_ptr(),
                current.as_mut_ptr(),
                libc::AT_SYMLINK_NOFOLLOW,
            )
        } != 0
        {
            return false;
        }
        let current = unsafe { current.assume_init() };
        opened.st_dev == current.st_dev && opened.st_ino == current.st_ino
    }
    fn still_repo(repo: &Path, fd: &OwnedFd) -> bool {
        let Ok(path) = CString::new(repo.as_os_str().as_bytes()) else {
            return false;
        };
        let Some(opened) = stat_fd(fd) else {
            return false;
        };
        let mut current = std::mem::MaybeUninit::uninit();
        if unsafe { libc::lstat(path.as_ptr(), current.as_mut_ptr()) } != 0 {
            return false;
        }
        let current = unsafe { current.assume_init() };
        if opened.st_dev != current.st_dev || opened.st_ino != current.st_ino {
            return false;
        }
        let marker = c".git";
        let mut git = std::mem::MaybeUninit::uninit();
        if unsafe { libc::fstatat(fd.as_raw_fd(), marker.as_ptr(), git.as_mut_ptr(), 0) } != 0 {
            return false;
        }
        let kind = unsafe { git.assume_init() }.st_mode & libc::S_IFMT;
        kind == libc::S_IFDIR || kind == libc::S_IFREG
    }
    let repo_fd = open_dir(repo)?;
    if !still_repo(repo, &repo_fd) {
        return None;
    }
    let target = path(root, repo, tab);
    let anchor = if target.starts_with(root.home()) {
        root.home().to_path_buf()
    } else {
        root.state_dir()
            .ancestors()
            .find(|p| p.is_dir())?
            .to_path_buf()
    };
    let home = open_dir(&anchor)?;
    let mut descriptors = vec![home];
    let components = target.parent()?.strip_prefix(&anchor).ok()?;
    let names: Vec<_> = components
        .components()
        .map(|p| CString::new(p.as_os_str().as_bytes()))
        .collect::<Result<_, _>>()
        .ok()?;
    for name in &names {
        let parent = descriptors.last()?;
        if create
            && unsafe { libc::mkdirat(parent.as_raw_fd(), name.as_ptr(), 0o700) } != 0
            && std::io::Error::last_os_error().raw_os_error() != Some(libc::EEXIST)
        {
            return None;
        }
        let fd = unsafe {
            libc::openat(
                parent.as_raw_fd(),
                name.as_ptr(),
                libc::O_RDONLY | libc::O_DIRECTORY | libc::O_CLOEXEC | libc::O_NOFOLLOW,
            )
        };
        if fd < 0 {
            return None;
        }
        descriptors.push(unsafe { OwnedFd::from_raw_fd(fd) });
    }
    let flags = if create {
        libc::O_WRONLY | libc::O_CREAT
    } else {
        libc::O_RDONLY
    };
    let fd = unsafe {
        libc::openat(
            descriptors.last()?.as_raw_fd(),
            c"note.md".as_ptr(),
            flags | libc::O_CLOEXEC | libc::O_NOFOLLOW | libc::O_NONBLOCK,
            0o600,
        )
    };
    if fd < 0 {
        return None;
    }
    let note = unsafe { OwnedFd::from_raw_fd(fd) };
    if stat_fd(&note)?.st_mode & libc::S_IFMT != libc::S_IFREG || !still_repo(repo, &repo_fd) {
        return None;
    }
    for (index, name) in names.iter().enumerate() {
        if !named(&descriptors[index], name, &descriptors[index + 1]) {
            return None;
        }
    }
    Some(path(root, repo, tab))
}
#[cfg(not(unix))]
fn access(root: &DataRoot, repo: &Path, tab: Uuid, create: bool) -> Option<PathBuf> {
    fn regular_path(path: &Path) -> bool {
        let Ok(metadata) = std::fs::symlink_metadata(path) else {
            return false;
        };
        #[cfg(windows)]
        {
            use std::os::windows::fs::MetadataExt;
            if metadata.file_attributes() & 0x400 != 0 {
                return false;
            }
        }
        !metadata.file_type().is_symlink()
    }
    if !regular_path(repo) || !repo.is_dir() || !repo.join(".git").exists() {
        return None;
    }
    let target = path(root, repo, tab);
    let anchor = if target.starts_with(root.home()) {
        root.home().to_path_buf()
    } else {
        root.state_dir()
            .ancestors()
            .find(|p| p.is_dir())?
            .to_path_buf()
    };
    if !regular_path(&anchor) {
        return None;
    }
    let mut current = anchor.clone();
    for part in target.parent()?.strip_prefix(&anchor).ok()?.components() {
        current.push(part);
        if create && !current.exists() {
            std::fs::create_dir(&current).ok()?;
        }
        if !regular_path(&current) || !current.is_dir() {
            return None;
        }
    }
    if create {
        match std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&target)
        {
            Ok(_) => (),
            Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => (),
            Err(_) => return None,
        }
    }
    if !regular_path(&target) || !target.is_file() || !repo.join(".git").exists() {
        return None;
    }
    Some(target)
}
#[cfg(test)]
mod tests {
    use super::*;
    fn fixture() -> (PathBuf, DataRoot, PathBuf, Uuid) {
        let home = std::env::temp_dir().join(format!("next-note-{}", Uuid::new_v4()));
        let repo = home.join("repository");
        std::fs::create_dir_all(repo.join(".git")).unwrap();
        let root = DataRoot::with_home(home.clone(), true);
        (home, root, repo, Uuid::new_v4())
    }
    #[test]
    fn preparation_preserves_contents_and_never_writes_repo_metadata() {
        let (home, root, repo, tab) = fixture();
        assert!(existing(&root, &repo, tab).is_none());
        let note = prepare(&root, &repo, tab).unwrap();
        std::fs::write(&note, "original").unwrap();
        assert_eq!(prepare(&root, &repo, tab), Some(note.clone()));
        assert_eq!(std::fs::read_to_string(&note).unwrap(), "original");
        assert!(!DataRoot::repo_metadata_file(&repo).parent().unwrap().exists());
        assert!(note.starts_with(root.state_dir()));
        std::fs::remove_dir_all(home).unwrap();
    }
    #[test]
    fn missing_root_and_stale_focus_do_not_create_or_redirect() {
        let (home, root, repo, tab) = fixture();
        let missing = home.join("gone");
        assert_eq!(
            selected_repository(&[Some(missing.clone()), Some(repo.clone())]),
            Some(missing.clone())
        );
        assert!(prepare(&root, &missing, tab).is_none());
        assert!(!root.state_dir().exists());
        std::fs::remove_dir_all(&repo).unwrap();
        assert!(prepare(&root, &repo, tab).is_none());
        assert!(!repo.exists());
        std::fs::remove_dir_all(home).unwrap();
    }
    #[cfg(unix)]
    #[test]
    fn symlinked_owned_directory_or_note_never_escapes() {
        use std::os::unix::fs::symlink;
        let (home, root, repo, tab) = fixture();
        let outside = home.join("outside");
        std::fs::create_dir(&outside).unwrap();
        std::fs::create_dir(root.state_dir()).unwrap();
        symlink(&outside, root.state_dir().join("repo-overlays")).unwrap();
        assert!(prepare(&root, &repo, tab).is_none());
        assert_eq!(std::fs::read_dir(&outside).unwrap().count(), 0);
        std::fs::remove_file(root.state_dir().join("repo-overlays")).unwrap();
        let note = prepare(&root, &repo, tab).unwrap();
        std::fs::remove_file(&note).unwrap();
        let other = outside.join("other");
        std::fs::write(&other, "keep").unwrap();
        symlink(&other, &note).unwrap();
        assert!(prepare(&root, &repo, tab).is_none());
        assert!(existing(&root, &repo, tab).is_none());
        assert_eq!(std::fs::read_to_string(other).unwrap(), "keep");
        std::fs::remove_dir_all(home).unwrap();
    }
}
