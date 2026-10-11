//! Reloadable zsh/bash history owned by Chau7 Next, distinct from history.tsv
//! and the searchable command database. Call filesystem work off the UI thread.
use std::collections::HashSet;
use std::fs::{self, File, Metadata, OpenOptions};
use std::io::{self, Read, Write};
use std::path::{Path, PathBuf};
use std::time::SystemTime;
use uuid::Uuid;

use crate::data_root::DataRoot;

pub const DEFAULT_MAX_LINES: usize = 1000;
pub const MAX_LINES: usize = 1_000_000;
pub const MIN_LINES_PER_TAB: usize = 5;
const MAX_FILE_BYTES: u64 = 64 * 1024 * 1024;
const MAX_FILES_PER_PASS: usize = 100_000;

fn suffix(shell: &str) -> Option<&'static str> {
    match Path::new(shell).file_name()?.to_str()? {
        "zsh" => Some("zsh_history"),
        "bash" => Some("bash_history"),
        _ => None,
    }
}
pub fn path(root: &DataRoot, tab: Uuid, shell: &str) -> Option<PathBuf> {
    Some(root.shell_histories_dir().join(format!(
        "{}.{}",
        tab.to_string().to_uppercase(),
        suffix(shell)?
    )))
}
fn real_directory(path: &Path) -> io::Result<()> {
    let metadata = fs::symlink_metadata(path)?;
    if !metadata.is_dir() || metadata.file_type().is_symlink() {
        return Err(io::Error::other(
            "shell history directory is not an owned regular directory",
        ));
    }
    Ok(())
}
fn open_regular(path: &Path, write: bool, create: bool) -> io::Result<File> {
    let mut options = OpenOptions::new();
    options
        .read(true)
        .write(write)
        .create(create)
        .truncate(false);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK);
    }
    #[cfg(windows)]
    {
        use std::os::windows::fs::OpenOptionsExt;
        options.custom_flags(0x0020_0000); // FILE_FLAG_OPEN_REPARSE_POINT
    }
    let file = options.open(path)?;
    let named = fs::symlink_metadata(path)?;
    if !named.is_file() || named.file_type().is_symlink() || !same_file(&named, &file.metadata()?) {
        return Err(io::Error::other(
            "shell history target is not a regular file",
        ));
    }
    Ok(file)
}
fn same_file(a: &Metadata, b: &Metadata) -> bool {
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        if a.dev() != b.dev() || a.ino() != b.ino() {
            return false;
        }
    }
    a.len() == b.len() && a.modified().ok() == b.modified().ok()
}

/// Prepare only a stable UUID file under the Next-owned namespace. Never
/// follow a linked app directory or history target into another app's profile.
pub fn prepare(root: &DataRoot, tab: Uuid, shell: &str) -> io::Result<Option<PathBuf>> {
    let Some(path) = path(root, tab, shell) else {
        return Ok(None);
    };
    for dir in [root.config_dir().to_path_buf(), root.shell_histories_dir()] {
        match fs::create_dir(&dir) {
            Ok(()) => {
                #[cfg(unix)]
                {
                    use std::os::unix::fs::PermissionsExt;
                    fs::set_permissions(&dir, fs::Permissions::from_mode(0o700))?;
                }
            }
            Err(error) if error.kind() == io::ErrorKind::AlreadyExists => {}
            Err(error) => return Err(error),
        }
        real_directory(&dir)?;
    }
    let file = open_regular(&path, true, true)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::{MetadataExt, PermissionsExt};
        if file.metadata()?.nlink() != 1 {
            return Err(io::Error::other(
                "shell history target has foreign hard links",
            ));
        }
        file.set_permissions(fs::Permissions::from_mode(0o600))?;
    }
    drop(file);
    Ok(Some(path))
}

#[derive(Default, Debug, Clone, PartialEq, Eq)]
pub struct PruneReport {
    pub trimmed_files: usize,
    pub removed_files: usize,
    pub protected_files: usize,
    pub failed_operations: usize,
    pub deferred_entries: usize,
    /// Observed lines in readable closed-tab files; failures remain explicit.
    pub retained_lines: usize,
}
struct Orphan {
    path: PathBuf,
    tab: Uuid,
    metadata: Metadata,
    modified: SystemTime,
    lines: usize,
    retained: bool,
}
fn tab_from_path(path: &Path) -> Option<Uuid> {
    let name = path.file_name()?.to_str()?;
    let id = name
        .strip_suffix(".zsh_history")
        .or_else(|| name.strip_suffix(".bash_history"))?;
    let tab = Uuid::parse_str(id).ok()?;
    id.eq_ignore_ascii_case(&tab.to_string()).then_some(tab)
}
fn count_lines(file: &mut File) -> io::Result<usize> {
    if file.metadata()?.len() > MAX_FILE_BYTES {
        return Err(io::Error::other(
            "shell history exceeds bounded maintenance size",
        ));
    }
    let mut bytes = [0; 64 * 1024];
    let mut read = 0u64;
    let mut lines = 0usize;
    loop {
        let count = file.read(&mut bytes)?;
        if count == 0 {
            return Ok(lines);
        }
        read += count as u64;
        if read > MAX_FILE_BYTES {
            return Err(io::Error::other(
                "shell history grew beyond maintenance bound",
            ));
        }
        lines += bytes[..count].iter().filter(|&&b| b == b'\n').count();
    }
}
fn trim(orphan: &mut Orphan) -> io::Result<()> {
    let mut file = open_regular(&orphan.path, false, false)?;
    if !same_file(&file.metadata()?, &orphan.metadata) {
        return Err(io::Error::other("shell history changed before trimming"));
    }
    let mut bytes = Vec::new();
    (&mut file)
        .take(MAX_FILE_BYTES + 1)
        .read_to_end(&mut bytes)?;
    if bytes.len() as u64 > MAX_FILE_BYTES {
        return Err(io::Error::other(
            "shell history grew beyond maintenance bound",
        ));
    }
    let text = std::str::from_utf8(&bytes).map_err(io::Error::other)?;
    let lines: Vec<_> = text
        .split_terminator('\n')
        .rev()
        .take(MIN_LINES_PER_TAB)
        .collect();
    let retained = lines.into_iter().rev().collect::<Vec<_>>().join("\n") + "\n";
    let parent = orphan
        .path
        .parent()
        .ok_or_else(|| io::Error::other("missing history parent"))?;
    real_directory(parent)?;
    let temp = parent.join(format!(".history-{}.tmp", Uuid::new_v4()));
    let result = (|| {
        let mut options = OpenOptions::new();
        options.write(true).create_new(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600).custom_flags(libc::O_NOFOLLOW);
        }
        let mut out = options.open(&temp)?;
        out.write_all(retained.as_bytes())?;
        out.sync_all()?;
        if !same_file(&fs::symlink_metadata(&orphan.path)?, &orphan.metadata) {
            return Err(io::Error::other("shell history changed during trimming"));
        }
        fs::rename(&temp, &orphan.path)?;
        orphan.metadata = fs::symlink_metadata(&orphan.path)?;
        orphan.lines = retained.bytes().filter(|&b| b == b'\n').count();
        Ok(())
    })();
    let _ = fs::remove_file(temp);
    result
}

/// Current Swift two-pass policy, confined to regular UUID histories owned by
/// Next. The additional live predicate protects tabs opened while the worker
/// scans. Failed reads/writes never count as successful pruning.
pub fn prune(
    root: &DataRoot,
    protected: &HashSet<Uuid>,
    max_lines: usize,
    is_live: impl Fn(Uuid) -> bool,
) -> io::Result<PruneReport> {
    let mut report = PruneReport::default();
    if !root.shell_histories_dir().exists() {
        return Ok(report);
    }
    real_directory(root.config_dir())?;
    real_directory(&root.shell_histories_dir())?;
    let mut orphans = Vec::new();
    for (index, entry) in fs::read_dir(root.shell_histories_dir())?.enumerate() {
        if index >= MAX_FILES_PER_PASS {
            report.deferred_entries += 1;
            continue;
        }
        let entry = entry?;
        let Some(tab) = tab_from_path(&entry.path()) else {
            continue;
        };
        if protected.contains(&tab) || is_live(tab) {
            report.protected_files += 1;
            continue;
        }
        let path = entry.path();
        let Ok(mut file) = open_regular(&path, false, false) else {
            report.failed_operations += 1;
            continue;
        };
        let metadata = file.metadata()?;
        let Ok(lines) = count_lines(&mut file) else {
            report.failed_operations += 1;
            continue;
        };
        report.retained_lines = report.retained_lines.saturating_add(lines);
        let modified = metadata.modified().unwrap_or(SystemTime::UNIX_EPOCH);
        orphans.push(Orphan {
            path,
            tab,
            metadata,
            modified,
            lines,
            retained: true,
        });
    }
    orphans.sort_by(|a, b| {
        a.modified
            .cmp(&b.modified)
            .then_with(|| a.path.cmp(&b.path))
    });
    let max_lines = max_lines.min(MAX_LINES);
    for orphan in &mut orphans {
        if report.retained_lines <= max_lines {
            break;
        }
        if is_live(orphan.tab) {
            report.retained_lines = report.retained_lines.saturating_sub(orphan.lines);
            orphan.retained = false;
            report.protected_files += 1;
            continue;
        }
        if orphan.lines <= MIN_LINES_PER_TAB {
            continue;
        }
        let before = orphan.lines;
        match trim(orphan) {
            Ok(()) => {
                report.retained_lines -= before - orphan.lines;
                report.trimmed_files += 1;
            }
            Err(_) => report.failed_operations += 1,
        }
    }
    for orphan in orphans {
        if report.retained_lines <= max_lines {
            break;
        }
        if !orphan.retained {
            continue;
        }
        if is_live(orphan.tab) {
            report.retained_lines = report.retained_lines.saturating_sub(orphan.lines);
            report.protected_files += 1;
            continue;
        }
        if fs::symlink_metadata(&orphan.path).is_ok_and(|m| same_file(&m, &orphan.metadata))
            && fs::remove_file(&orphan.path).is_ok()
        {
            report.retained_lines -= orphan.lines;
            report.removed_files += 1;
        } else {
            report.failed_operations += 1;
        }
    }
    Ok(report)
}

#[cfg(test)]
mod tests {
    use super::*;
    fn fixture() -> DataRoot {
        let home = std::env::temp_dir().join(format!("chau7-next-histories-{}", Uuid::new_v4()));
        fs::create_dir(&home).unwrap();
        DataRoot::with_home(home, true)
    }
    fn populate(root: &DataRoot, tab: Uuid, n: usize, age: u64) -> PathBuf {
        let path = prepare(root, tab, "/bin/zsh").unwrap().unwrap();
        fs::write(
            &path,
            (0..n).map(|i| format!("cmd-{i}\n")).collect::<String>(),
        )
        .unwrap();
        OpenOptions::new()
            .write(true)
            .open(&path)
            .unwrap()
            .set_times(
                fs::FileTimes::new()
                    .set_modified(SystemTime::UNIX_EPOCH + std::time::Duration::from_secs(age)),
            )
            .unwrap();
        path
    }
    #[test]
    fn stable_owned_paths_and_shell_selection() {
        let root = fixture();
        let id = Uuid::new_v4();
        let a = prepare(&root, id, "/bin/zsh").unwrap().unwrap();
        let b = prepare(&root, id, "/bin/zsh").unwrap().unwrap();
        assert_eq!(a, b);
        assert!(a.starts_with(root.config_dir()));
        assert_ne!(a, prepare(&root, id, "/bin/bash").unwrap().unwrap());
        assert!(prepare(&root, id, "/bin/fish").unwrap().is_none());
        fs::remove_dir_all(root.home()).unwrap();
    }
    #[test]
    fn oldest_first_floor_then_removal_preserves_protected_and_unrelated() {
        let root = fixture();
        let a = Uuid::new_v4();
        let b = Uuid::new_v4();
        let live = Uuid::new_v4();
        let pa = populate(&root, a, 20, 1);
        let pb = populate(&root, b, 20, 2);
        let pl = populate(&root, live, 80, 0);
        let unrelated = root.shell_histories_dir().join("notes.zsh_history");
        fs::write(&unrelated, "keep\n").unwrap();
        let report = prune(&root, &HashSet::from([live]), 10, |_| false).unwrap();
        assert_eq!(report.trimmed_files, 2);
        assert_eq!(report.retained_lines, 10);
        assert_eq!(report.protected_files, 1);
        assert_eq!(
            fs::read_to_string(&pa).unwrap(),
            (15..20).map(|i| format!("cmd-{i}\n")).collect::<String>()
        );
        let report = prune(&root, &HashSet::from([live]), 5, |_| false).unwrap();
        assert_eq!(report.removed_files, 1);
        assert!(!pa.exists());
        assert!(pb.exists());
        assert!(pl.exists());
        assert!(unrelated.exists());
        let report = prune(&root, &HashSet::from([live]), 0, |_| false).unwrap();
        assert_eq!(report.retained_lines, 0);
        assert!(pl.exists());
        assert!(unrelated.exists());
        fs::remove_dir_all(root.home()).unwrap();
    }
    #[test]
    fn actual_live_predicate_protects_history_without_static_restore_id() {
        let root = fixture();
        let live = Uuid::new_v4();
        let file = populate(&root, live, 20, 0);
        let report = prune(&root, &HashSet::new(), 0, |id| id == live).unwrap();
        assert_eq!(report.protected_files, 1);
        assert_eq!(fs::read_to_string(file).unwrap().lines().count(), 20);
        fs::remove_dir_all(root.home()).unwrap();
    }
    #[cfg(unix)]
    #[test]
    fn linked_targets_and_roots_cannot_touch_foreign_histories() {
        use std::os::unix::fs::symlink;
        let root = fixture();
        let foreign = root.home().join("foreign");
        fs::create_dir(&foreign).unwrap();
        let data = foreign.join("original");
        fs::write(&data, "foreign\n").unwrap();
        let id = Uuid::new_v4();
        prepare(&root, id, "zsh").unwrap();
        let target = path(&root, id, "zsh").unwrap();
        fs::remove_file(&target).unwrap();
        symlink(&data, &target).unwrap();
        assert!(prepare(&root, id, "zsh").is_err());
        let report = prune(&root, &HashSet::new(), 0, |_| false).unwrap();
        assert_eq!(report.failed_operations, 1);
        assert_eq!(fs::read_to_string(&data).unwrap(), "foreign\n");
        fs::remove_file(target).unwrap();
        fs::remove_dir(root.shell_histories_dir()).unwrap();
        symlink(&foreign, root.shell_histories_dir()).unwrap();
        assert!(prepare(&root, id, "bash").is_err());
        assert!(prune(&root, &HashSet::new(), 0, |_| false).is_err());
        assert_eq!(fs::read_to_string(data).unwrap(), "foreign\n");
        fs::remove_dir_all(root.home()).unwrap();
    }
    #[test]
    fn maintenance_is_bounded_and_active_promotion_preserves_bytes() {
        use std::sync::atomic::{AtomicUsize, Ordering};
        let root = fixture();
        let id = Uuid::new_v4();
        let file = populate(&root, id, 20, 0);
        let calls = AtomicUsize::new(0);
        let report = prune(&root, &HashSet::new(), 0, |_| {
            calls.fetch_add(1, Ordering::Relaxed) > 0
        })
        .unwrap();
        assert_eq!(report.protected_files, 1);
        assert_eq!(report.removed_files, 0);
        assert_eq!(fs::read_to_string(&file).unwrap().lines().count(), 20);
        OpenOptions::new()
            .write(true)
            .open(&file)
            .unwrap()
            .set_len(MAX_FILE_BYTES + 1)
            .unwrap();
        let report = prune(&root, &HashSet::new(), 0, |_| false).unwrap();
        assert_eq!(report.failed_operations, 1);
        assert_eq!(report.removed_files, 0);
        assert!(file.exists());
        fs::remove_dir_all(root.home()).unwrap();
    }
    #[test]
    fn concurrent_change_is_neither_overwritten_nor_reported_deleted() {
        use std::sync::atomic::{AtomicUsize, Ordering};
        let root = fixture();
        let id = Uuid::new_v4();
        let file = populate(&root, id, 20, 0);
        let calls = AtomicUsize::new(0);
        let report = prune(&root, &HashSet::new(), 0, |_| {
            if calls.fetch_add(1, Ordering::Relaxed) == 1 {
                fs::write(&file, "new concurrent history\n").unwrap();
            }
            false
        })
        .unwrap();
        assert_eq!(report.trimmed_files, 0);
        assert_eq!(report.removed_files, 0);
        assert_eq!(report.failed_operations, 2);
        assert_eq!(
            fs::read_to_string(file).unwrap(),
            "new concurrent history\n"
        );
        fs::remove_dir_all(root.home()).unwrap();
    }
}
