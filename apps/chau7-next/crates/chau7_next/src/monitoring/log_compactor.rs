//! Launch-only compaction of Next-owned transient helper event queues.
//! Invoke before all sessions/writers and tailers start. Shared Swift/provider
//! files are never eligible; the durable record remains in the event spine.

use std::fs;
use std::path::Path;

use chau7_next_core::data_root::DataRoot;

pub const DEFAULT_MAX_BYTES: u64 = 16 * 1024 * 1024;
pub const DEFAULT_KEEP_BYTES: u64 = 8 * 1024 * 1024;

fn unchanged(before: &fs::Metadata, after: &fs::Metadata) -> bool {
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        if before.dev() != after.dev() || before.ino() != after.ino() {
            return false;
        }
    }
    before.len() == after.len()
        && before.modified().ok() == after.modified().ok()
        && before.created().ok() == after.created().ok()
}
/// The caller guarantees quiescent writers. Recheck the observed fingerprint
/// before replacing, and refuse symlink/foreign file aliases.
fn compact_if_needed(path: &Path, max_bytes: u64, keep_bytes: u64) -> std::io::Result<bool> {
    let before = match fs::symlink_metadata(path) {
        Ok(metadata) if metadata.is_file() => metadata,
        Ok(_) => return Ok(false),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(false),
        Err(error) => return Err(error),
    };
    if before.len() <= max_bytes {
        return Ok(false);
    }
    let tail = crate::logging::writer::read_tail(path, before.len(), keep_bytes)?;
    let after = fs::symlink_metadata(path)?;
    if !after.is_file() || !unchanged(&before, &after) {
        return Ok(false);
    }
    crate::logging::writer::replace_with(path, &tail)?;
    Ok(true)
}
pub fn compact_owned_queues(root: &DataRoot) {
    for path in [root.ai_events_log(), root.next_claude_hook_events_file()] {
        match compact_if_needed(&path, DEFAULT_MAX_BYTES, DEFAULT_KEEP_BYTES) {
            Ok(true) => log::info!("Compacted owned Next event queue {}", path.display()),
            Ok(false) => {}
            Err(error) => log::warn!(
                "Next event queue compaction failed at {}: {error}",
                path.display()
            ),
        }
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    fn fixture() -> std::path::PathBuf {
        let dir =
            std::env::temp_dir().join(format!("chau7-next-compactor-{}", uuid::Uuid::new_v4()));
        fs::create_dir_all(&dir).unwrap();
        dir
    }
    #[test]
    fn bounds_tail_and_drops_leading_incomplete_record() {
        let dir = fixture();
        let path = dir.join("events");
        fs::write(&path, b"old-record\nretained-a\nretained-b\n").unwrap();
        assert!(!compact_if_needed(&path, 100, 16).unwrap());
        assert!(compact_if_needed(&path, 20, 16).unwrap());
        assert_eq!(fs::read(&path).unwrap(), b"retained-b\n");
        fs::write(&path, b"long-record-with-no-newline").unwrap();
        assert!(compact_if_needed(&path, 10, 5).unwrap());
        assert!(fs::read(&path).unwrap().is_empty());
        fs::remove_dir_all(dir).unwrap();
    }
    #[test]
    fn only_next_owned_queues_are_compacted() {
        let dir = fixture();
        let root = DataRoot::with_home(dir.clone(), true);
        root.ensure_dirs().unwrap();
        let shared = root.claude_hook_events_file();
        let foreign = root.shared_ai_events_log();
        fs::create_dir_all(shared.parent().unwrap()).unwrap();
        let bytes = vec![b'x'; DEFAULT_MAX_BYTES as usize + 1];
        for path in [
            &shared,
            &foreign,
            &root.ai_events_log(),
            &root.next_claude_hook_events_file(),
        ] {
            fs::write(path, &bytes).unwrap();
        }
        compact_owned_queues(&root);
        assert_eq!(fs::metadata(shared).unwrap().len(), bytes.len() as u64);
        assert_eq!(fs::metadata(foreign).unwrap().len(), bytes.len() as u64);
        assert_eq!(fs::metadata(root.ai_events_log()).unwrap().len(), 0);
        assert_eq!(
            fs::metadata(root.next_claude_hook_events_file())
                .unwrap()
                .len(),
            0
        );
        fs::remove_dir_all(dir).unwrap();
    }
    #[cfg(unix)]
    #[test]
    fn symlink_queue_is_not_compacted() {
        let dir = fixture();
        let foreign = dir.join("foreign");
        let alias = dir.join("alias");
        fs::write(&foreign, b"foreign-long-record\n").unwrap();
        std::os::unix::fs::symlink(&foreign, &alias).unwrap();
        assert!(!compact_if_needed(&alias, 1, 1).unwrap());
        assert_eq!(fs::read(&foreign).unwrap(), b"foreign-long-record\n");
        fs::remove_dir_all(dir).unwrap();
    }
}
