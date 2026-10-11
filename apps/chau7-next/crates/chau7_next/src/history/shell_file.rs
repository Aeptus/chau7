//! The shell integration's history file (`DataRoot::history_file`), indexed
//! once in the background and reused.
//!
//! At launch and whenever the file changes, a background thread keeps it
//! private (0600), redacted and capped (`shell_integration::maintain_history`)
//! and parses it. Readers on the main thread (history picker, prompt history,
//! Data Explorer) take the parsed list without touching the disk.

use std::path::PathBuf;
use std::sync::Arc;
use std::time::{Duration, SystemTime};

use chau7_next_core::shell_integration::{self, HistoryEntry};
use gpui::{App, Global};
use parking_lot::RwLock;

/// How often the thread looks for new lines.
const POLL: Duration = Duration::from_secs(30);

type Entries = Arc<RwLock<Arc<Vec<HistoryEntry>>>>;

/// The parsed history file, most recent first, duplicates collapsed.
#[derive(Clone, Default)]
pub struct ShellHistoryIndex {
    entries: Entries,
}

impl Global for ShellHistoryIndex {}

impl ShellHistoryIndex {
    pub fn entries(&self) -> Arc<Vec<HistoryEntry>> {
        self.entries.read().clone()
    }
}

/// Start the background indexer.
pub fn init(cx: &mut App) {
    let path = cx.global::<crate::workspace::AppData>().root.history_file();
    // Created (private) right away: the shell hooks only append to an
    // existing file, and the first shells start before the thread runs.
    if let Err(err) = shell_integration::ensure_private_history(&path) {
        log::warn!("shell history file: {err}");
    }
    let index = ShellHistoryIndex::default();
    let entries = index.entries.clone();
    cx.set_global(index);
    let _ = std::thread::Builder::new()
        .name("chau7-shell-history".into())
        .spawn(move || run(path, entries));
}

fn run(path: PathBuf, entries: Entries) {
    let mut last: Option<(u64, Option<SystemTime>)> = None;
    loop {
        let stamp = std::fs::metadata(&path)
            .ok()
            .map(|m| (m.len(), m.modified().ok()));
        if stamp.is_none() || stamp != last {
            match shell_integration::maintain_history(&path, shell_integration::HISTORY_MAX_BYTES) {
                Ok(text) => {
                    let parsed = shell_integration::parse_history(&text, usize::MAX);
                    *entries.write() = Arc::new(parsed);
                }
                Err(err) => log::warn!("shell history file: {err}"),
            }
            last = std::fs::metadata(&path)
                .ok()
                .map(|m| (m.len(), m.modified().ok()));
        }
        std::thread::sleep(POLL);
    }
}

/// The indexed entries (empty until the first pass finished).
pub fn entries(cx: &App) -> Arc<Vec<HistoryEntry>> {
    cx.try_global::<ShellHistoryIndex>()
        .map(ShellHistoryIndex::entries)
        .unwrap_or_default()
}
