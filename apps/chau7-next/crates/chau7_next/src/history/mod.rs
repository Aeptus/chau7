//! Command history, session history files and session recording.
//!
//! | File | Feature |
//! |---|---|
//! | `mod.rs` | the history database service (HIS-001 to HIS-009) |
//! | `monitor.rs` | Claude and Codex history files and PTY logs (HIS-012 to HIS-014, HIS-016) |
//! | `recorder.rs` | session recording for the timeline scrubber (HIS-015) |
//!
//! Chau7 Next keeps its own SQLite database (`DataRoot::history_db`) and never
//! touches the Swift app's `history.db`. Commands are recorded when they
//! finish (OSC 133 D), with their exit code and duration; the Swift app never
//! fills its store from the terminal, so this is new behavior on purpose.
//! Writes go through a thread so the UI never waits for SQLite.

pub mod monitor;
pub mod recorder;
pub mod shell_file;
pub mod shell_histories;

use std::sync::Arc;
use std::sync::mpsc::{Sender, channel};

use chau7_next_core::data_root::DataRoot;
use chau7_next_core::history_record::HistoryRecord;
use chau7_next_core::history_store::HistoryStore;
use gpui::{App, Global};
use parking_lot::Mutex;

use crate::settings::Settings;

type StatisticsObserver = Arc<dyn Fn() + Send + Sync>;

/// The command history database.
pub struct HistoryService {
    store: Arc<Mutex<HistoryStore>>,
    tx: Sender<HistoryRecord>,
    statistics_observer: Arc<Mutex<Option<StatisticsObserver>>>,
    /// Records kept (the settings value, applied by [`apply_settings`]).
    enabled: Arc<std::sync::atomic::AtomicBool>,
}

impl Global for HistoryService {}

impl HistoryService {
    /// Open the database. A database that cannot be opened at all (disk
    /// error) leaves history off for this run.
    fn open(root: &DataRoot, settings: &Settings) -> Option<Self> {
        let mut store = match HistoryStore::open(&root.history_db()) {
            Ok(store) => store,
            Err(err) => {
                log::error!("history database: {err}");
                return None;
            }
        };
        store.max_records = settings.history.max_records;
        import_legacy_tsv(&store, &root.history_file());
        let store = Arc::new(Mutex::new(store));
        let (tx, rx) = channel::<HistoryRecord>();
        let writer = store.clone();
        let statistics_observer: Arc<Mutex<Option<StatisticsObserver>>> = Arc::default();
        let observer = statistics_observer.clone();
        std::thread::Builder::new()
            .name("chau7-history-writer".into())
            .spawn(move || {
                while let Ok(record) = rx.recv() {
                    let inserted = writer.lock().insert(&record);
                    if let Err(err) = inserted {
                        log::error!("history insert failed: {err}");
                    }
                    // The writer released its store lock before invalidating
                    // the held statistics; the callback only coalesces a job.
                    let notify = observer.lock().clone();
                    if let Some(notify) = notify {
                        notify();
                    }
                }
            })
            .ok()?;
        Some(Self {
            store,
            tx,
            statistics_observer,
            enabled: Arc::new(std::sync::atomic::AtomicBool::new(
                settings.history.persistent_history,
            )),
        })
    }

    /// Whether commands are being recorded.
    pub fn enabled(&self) -> bool {
        self.enabled.load(std::sync::atomic::Ordering::Relaxed)
    }

    /// Queue a record for the writer thread (dropped when history is off).
    pub fn record(&self, record: HistoryRecord) {
        if self.enabled() {
            let _ = self.tx.send(record);
        }
    }

    /// Read from the database. Keep `f` short: the writer waits for it.
    pub fn with_store<R>(&self, f: impl FnOnce(&HistoryStore) -> R) -> R {
        f(&self.store.lock())
    }

    /// The database itself, for readers off the main thread (MCP tools).
    pub fn store_handle(&self) -> Arc<Mutex<HistoryStore>> {
        self.store.clone()
    }

    /// Change the database (clear, trim, import).
    pub fn with_store_mut<R>(&self, f: impl FnOnce(&mut HistoryStore) -> R) -> R {
        let result = f(&mut self.store.lock());
        let observer = self.statistics_observer.lock().clone();
        if let Some(observer) = observer {
            observer();
        }
        result
    }

    /// Register one app-owned snapshot observer. Its callback performs no
    /// database work and should retain its consumer only weakly.
    pub(crate) fn set_statistics_observer(&self, observer: StatisticsObserver) {
        *self.statistics_observer.lock() = Some(observer);
    }
}

/// One-time import of `history.tsv` (the commands the shell hooks logged
/// before the database existed) into an empty database.
fn import_legacy_tsv(store: &HistoryStore, tsv: &std::path::Path) {
    if store.total_count() > 0 {
        return;
    }
    let Ok(text) = std::fs::read_to_string(tsv) else {
        return;
    };
    let text = chau7_next_core::shell_integration::sanitize_history(&text, usize::MAX);
    let mut count = 0;
    for line in text.lines() {
        let mut parts = line.splitn(3, '\t');
        let (Some(time), Some(directory), Some(command)) =
            (parts.next(), parts.next(), parts.next())
        else {
            continue;
        };
        let command = command.trim();
        if command.is_empty() {
            continue;
        }
        let Some(timestamp) = time
            .trim()
            .parse::<i64>()
            .ok()
            .and_then(|t| chrono::DateTime::from_timestamp(t, 0))
        else {
            continue;
        };
        let record = HistoryRecord {
            directory: Some(directory.to_string()).filter(|d| !d.is_empty()),
            timestamp,
            ..HistoryRecord::new(command)
        };
        if store.insert(&record).is_ok() {
            count += 1;
        }
    }
    if count > 0 {
        log::info!("history: imported {count} commands from {}", tsv.display());
    }
}

/// Open the database at launch and start the log monitors.
pub fn init(cx: &mut App) {
    shell_file::init(cx);
    let root = cx.global::<crate::workspace::AppData>().root.clone();
    let settings = Settings::get(cx).clone();
    if let Some(service) = HistoryService::open(&root, &settings) {
        cx.set_global(service);
    }
    monitor::init(cx);
    recorder::init(cx);
}

/// The history service, when the database opened.
pub fn service(cx: &App) -> Option<&HistoryService> {
    cx.try_global::<HistoryService>()
}

/// Apply the settings: recording on or off, record limit, monitors.
pub fn apply_settings(cx: &mut App) {
    let settings = Settings::get(cx).history.clone();
    if let Some(service) = cx.try_global::<HistoryService>() {
        service.enabled.store(
            settings.persistent_history,
            std::sync::atomic::Ordering::Relaxed,
        );
        service.with_store_mut(|s| s.set_max_records(settings.max_records));
    }
    monitor::apply_settings(cx);
}

/// Record a finished command (`command` already passed the secret and
/// password filters of the shell session).
#[allow(clippy::too_many_arguments)]
pub fn record_command(
    command: &str,
    directory: Option<&str>,
    exit_code: Option<i32>,
    duration: f64,
    shell: Option<&str>,
    tab_id: &str,
    cx: &App,
) {
    let Some(service) = service(cx) else { return };
    if !service.enabled() {
        return;
    }
    let command = command.trim();
    if command.is_empty() {
        return;
    }
    service.record(HistoryRecord {
        id: None,
        command: command.to_string(),
        directory: directory.map(str::to_string).filter(|d| !d.is_empty()),
        exit_code: exit_code.map(i64::from),
        shell: shell.map(str::to_string),
        tab_id: Some(tab_id.to_string()),
        session_id: None,
        timestamp: chrono::Utc::now(),
        duration: (duration > 0.0).then_some(duration),
    });
}

/// File size as Finder shows it (`ByteCountFormatter` with the file style):
/// decimal units.
pub fn format_bytes(bytes: u64) -> String {
    chau7_next_core::l10n::formatters::file_size(chau7_next_core::l10n::current(), bytes)
}

/// Duration for the picker: `250ms`, `1.5s`, `2m5s` (`HistoryRecordRow`).
pub fn format_duration(seconds: f64) -> String {
    if seconds < 1.0 {
        format!("{:.0}ms", seconds * 1000.0)
    } else if seconds < 60.0 {
        format!("{seconds:.1}s")
    } else {
        format!("{}m{}s", seconds as i64 / 60, seconds as i64 % 60)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn byte_and_duration_labels() {
        assert_eq!(format_bytes(0), "0 bytes");
        assert_eq!(format_bytes(1), "1 byte");
        assert_eq!(format_bytes(999), "999 bytes");
        assert_eq!(format_bytes(4096), "4.1 KB");
        assert_eq!(format_bytes(1_500_000), "1.5 MB");
        assert_eq!(format_bytes(250_000_000), "250 MB");
        assert_eq!(format_duration(0.25), "250ms");
        assert_eq!(format_duration(1.5), "1.5s");
        assert_eq!(format_duration(125.0), "2m5s");
    }

    #[test]
    fn statistics_observer_runs_after_owned_writer_and_mutation_release_the_store() {
        let directory = std::env::temp_dir().join(format!(
            "chau7-next-history-snapshot-{}",
            uuid::Uuid::new_v4()
        ));
        let root = DataRoot::with_home(directory, true);
        root.ensure_dirs().unwrap();
        let mut settings = Settings::default();
        settings.history.persistent_history = true;
        let service = HistoryService::open(&root, &settings).unwrap();
        let store = service.store_handle();
        let (events, completed) = std::sync::mpsc::sync_channel(1);
        let observer_store = store.clone();
        service.set_statistics_observer(Arc::new(move || {
            // This would fail if notification ran while holding SQLite's mutex.
            let unlocked = observer_store.try_lock().is_some();
            let _ = events.try_send(unlocked);
        }));
        service.record(HistoryRecord::new("owned command"));
        assert!(
            completed
                .recv_timeout(std::time::Duration::from_secs(5))
                .unwrap()
        );
        assert_eq!(store.lock().statistics().unwrap().0, 1);
        service.with_store_mut(|store| store.clear_all());
        assert!(
            completed
                .recv_timeout(std::time::Duration::from_secs(5))
                .unwrap()
        );
        assert_eq!(store.lock().statistics().unwrap().0, 0);
        let weak = Arc::downgrade(&store);
        drop(service);
        drop(store);
        let started = std::time::Instant::now();
        while weak.upgrade().is_some() {
            assert!(started.elapsed() < std::time::Duration::from_secs(5));
            std::thread::sleep(std::time::Duration::from_millis(5));
        }
        std::fs::remove_dir_all(root.home()).unwrap();
    }

    #[test]
    fn legacy_tsv_is_imported_once_into_an_empty_store() {
        let dir = std::env::temp_dir().join(format!("chau7-next-tsv-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let tsv = dir.join("history.tsv");
        std::fs::write(
            &tsv,
            "1700000000\t/tmp\tls -la\nbroken line\n1700000100\t/home\tgit status\n1700000200\t\t  \n",
        )
        .unwrap();
        let store = HistoryStore::open(std::path::Path::new(":memory:")).unwrap();
        import_legacy_tsv(&store, &tsv);
        assert_eq!(store.total_count(), 2);
        assert_eq!(store.recent(1)[0].command, "git status");
        // Not again.
        import_legacy_tsv(&store, &tsv);
        assert_eq!(store.total_count(), 2);
        let _ = std::fs::remove_dir_all(&dir);
    }
}
