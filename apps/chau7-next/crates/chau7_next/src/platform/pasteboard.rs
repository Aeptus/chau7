//! Noticing copies made in other apps (clipboard history, KBD-001): the
//! general pasteboard's change count, which goes up on every copy.
//!
//! Reading and writing the clipboard itself goes through GPUI
//! (`cx.read_from_clipboard()`, `cx.write_to_clipboard(..)`). Where the
//! change count is not available, a feature can compare the clipboard text
//! with the last one it saw instead.

use super::Result;

/// The general pasteboard's change count.
pub fn change_count() -> Result<i64> {
    imp::change_count()
}

/// Polled from a timer (the Swift app checks every second): tells whether
/// the clipboard changed since the last poll.
#[derive(Debug, Default)]
pub struct ChangeWatcher {
    last: Option<i64>,
}

impl ChangeWatcher {
    pub fn new() -> Self {
        Self::default()
    }

    /// `Ok(true)` when the pasteboard changed since the last call. The first
    /// call only records the current count and returns `Ok(false)`.
    pub fn poll(&mut self) -> Result<bool> {
        Ok(self.observe(change_count()?))
    }

    /// Records a change count; true when it differs from the previous one.
    pub fn observe(&mut self, count: i64) -> bool {
        let changed = self.last.is_some_and(|last| last != count);
        self.last = Some(count);
        changed
    }
}

#[cfg(target_os = "macos")]
mod imp {
    use objc2_app_kit::NSPasteboard;

    use crate::platform::Result;

    pub fn change_count() -> Result<i64> {
        Ok(NSPasteboard::generalPasteboard().changeCount() as i64)
    }
}

#[cfg(not(target_os = "macos"))]
mod imp {
    use crate::platform::{Result, unsupported};

    pub fn change_count() -> Result<i64> {
        unsupported("pasteboard change count")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn watcher_reports_changes_after_the_first_count() {
        let mut watcher = ChangeWatcher::new();
        assert!(!watcher.observe(5));
        assert!(!watcher.observe(5));
        assert!(watcher.observe(6));
        assert!(!watcher.observe(6));
    }

    #[cfg(not(target_os = "macos"))]
    #[test]
    fn stub_is_unsupported() {
        assert!(change_count().is_err());
        assert!(ChangeWatcher::new().poll().is_err());
    }
}
