//! Event-driven Settings snapshots. The renderer reads held values only;
//! filesystem/SQLite work runs in one coalesced background batch per app root.
#[cfg(target_os = "macos")]
mod fsevents;

use super::SettingsView;
#[cfg(not(test))]
use crate::monitoring::file_monitor::FileMonitor;
use crate::{history, workspace::AppData};
use chau7_next_core::{
    data_root::DataRoot,
    history_store::HistoryStore,
    snippet_store::Snippet,
    work_profiler::{self, Key, Queue},
};
use futures::{StreamExt, channel::mpsc};
use gpui::{App, AppContext, BorrowAppContext, Context, Global, Task, WeakEntity};
use parking_lot::Mutex;
use std::{
    collections::HashMap,
    path::{Path, PathBuf},
    sync::{
        Arc, OnceLock, Weak,
        atomic::{AtomicBool, AtomicU8, AtomicU64, Ordering},
    },
};

const SNIPPETS: u8 = 1;
const HISTORY: u8 = 2;
type Store = Arc<Mutex<HistoryStore>>;

struct Signal {
    sender: Mutex<mpsc::Sender<()>>,
    dirty: AtomicU8,
    snippets_revision: AtomicU64,
    history_revision: AtomicU64,
    active: AtomicBool,
}
impl Signal {
    fn invalidate(&self, bits: u8) {
        if !self.active.load(Ordering::Acquire) {
            return;
        }
        if bits & SNIPPETS != 0 {
            self.snippets_revision.fetch_add(1, Ordering::AcqRel);
        }
        if bits & HISTORY != 0 {
            self.history_revision.fetch_add(1, Ordering::AcqRel);
        }
        self.dirty.fetch_or(bits, Ordering::AcqRel);
        // Exactly one sender, shared behind the mutex: invalidation bursts do
        // not acquire extra sender buffer slots or enqueue unbounded jobs.
        let _ = self.sender.lock().try_send(());
    }
    fn revisions(&self) -> (u64, u64) {
        (
            self.snippets_revision.load(Ordering::Acquire),
            self.history_revision.load(Ordering::Acquire),
        )
    }
}
type SnippetSignals = Mutex<HashMap<PathBuf, Weak<Signal>>>;
fn snippet_signals() -> &'static SnippetSignals {
    static SIGNALS: OnceLock<SnippetSignals> = OnceLock::new();
    SIGNALS.get_or_init(Default::default)
}
/// Called only after actual owned snippet mutations; no disk operation here.
pub(crate) fn invalidate_snippets(root: &DataRoot) {
    let signal = snippet_signals()
        .lock()
        .get(&root.user_snippets_dir())
        .and_then(Weak::upgrade);
    if let Some(signal) = signal {
        signal.invalidate(SNIPPETS);
    }
}

struct Reading<T> {
    revision: u64,
    value: Result<T, String>,
}
struct Snapshots {
    root: PathBuf,
    store: Option<Store>,
    signal: Arc<Signal>,
    snippets: Option<Reading<usize>>,
    history: Option<Reading<(i64, u64)>>,
    last_history_value: Option<(i64, u64)>,
    subscribers: Vec<WeakEntity<SettingsView>>,
    _worker: Task<()>,
}
impl Global for Snapshots {}

pub(super) fn snippets(cx: &App) -> Option<usize> {
    let state = cx.try_global::<Snapshots>()?;
    let reading = state.snippets.as_ref()?;
    (reading.revision == state.signal.revisions().0)
        .then_some(reading.value.as_ref().ok().copied())
        .flatten()
}
#[derive(Default)]
pub(super) struct Statistics {
    pub value: Option<(i64, u64)>,
    pub pending: bool,
    pub unavailable: bool,
}
pub(super) fn statistics(cx: &App) -> Statistics {
    let Some(state) = cx.try_global::<Snapshots>() else {
        return Statistics {
            pending: true,
            ..Default::default()
        };
    };
    let Some(reading) = &state.history else {
        return Statistics {
            pending: true,
            ..Default::default()
        };
    };
    if reading.revision != state.signal.revisions().1 {
        return Statistics {
            pending: true,
            ..Default::default()
        };
    }
    statistics_result(&reading.value, state.last_history_value)
}
fn statistics_result(
    value: &Result<(i64, u64), String>,
    previous: Option<(i64, u64)>,
) -> Statistics {
    match value {
        Ok(value) => Statistics {
            value: Some(*value),
            ..Default::default()
        },
        Err(_) => Statistics {
            value: previous,
            unavailable: true,
            ..Default::default()
        },
    }
}

/// Opening/reopening a Settings view registers interest and requests fresh
/// values. The global task holds no Settings entity strongly.
pub(super) fn init(cx: &mut Context<SettingsView>) {
    let root = cx.global::<AppData>().root.clone();
    let view = cx.weak_entity();
    let store = history::service(cx).map(|service| service.store_handle());
    if cx.try_global::<Snapshots>().is_some_and(|state| {
        state.root == root.state_dir() && same_store(state.store.as_ref(), store.as_ref())
    }) {
        cx.update_global::<Snapshots, _>(|state, _| {
            state.subscribers.retain(|view| view.upgrade().is_some());
            state.subscribers.push(view);
            state.signal.active.store(true, Ordering::Release);
            state.signal.invalidate(SNIPPETS | HISTORY);
        });
        return;
    }
    let (sender, mut receiver) = mpsc::channel(1);
    let signal = Arc::new(Signal {
        sender: Mutex::new(sender),
        dirty: AtomicU8::new(0),
        snippets_revision: AtomicU64::new(0),
        history_revision: AtomicU64::new(0),
        active: AtomicBool::new(true),
    });
    {
        let mut registry = snippet_signals().lock();
        registry.retain(|_, signal| signal.strong_count() > 0);
        registry.insert(root.user_snippets_dir(), Arc::downgrade(&signal));
    }
    #[cfg(not(test))]
    if let Some(service) = history::service(cx) {
        let weak = Arc::downgrade(&signal);
        service.set_statistics_observer(Arc::new(move || {
            if let Some(signal) = weak.upgrade() {
                signal.invalidate(HISTORY);
            }
        }));
    }
    signal.invalidate(SNIPPETS | HISTORY);
    let worker_signal = signal.clone();
    let worker_root = root.clone();
    let worker_store = store.clone();
    let worker = cx.spawn(async move |_, cx| {
        // TestScheduler forbids native/background-thread foreground wakes.
        // Headless GPUI tests use a passive event source; standalone watcher
        // and writer tests exercise actual OS/SQLite events separately. The
        // optional real-window fixture build keeps production subscriptions.
        #[cfg(test)]
        let snippet_watch: Result<(), String> = Ok(());
        #[cfg(not(test))]
        let monitor_root = worker_root.clone();
        #[cfg(not(test))]
        let weak = Arc::downgrade(&worker_signal);
        // Existing shared watchers are installed off UI, including canonical
        // paths and replacement/missing-parent recovery. No polling timer.
        #[cfg(not(test))]
        let (_monitors, snippet_watch) = cx
            .background_spawn(async move {
                let mut monitors = Vec::new();
                for (path, bit) in [
                    (monitor_root.history_db(), HISTORY),
                    (
                        PathBuf::from(format!("{}-wal", monitor_root.history_db().display())),
                        HISTORY,
                    ),
                ] {
                    let signal = weak.clone();
                    let monitor = FileMonitor::new(path, move || {
                        if let Some(signal) = signal.upgrade() {
                            signal.invalidate(bit);
                        }
                    });
                    monitor.start();
                    monitors.push(monitor);
                }
                #[cfg(target_os = "macos")]
                let snippet_watch = fsevents::SnippetWatch::new(
                    &monitor_root.user_snippets_dir(),
                    monitor_root.config_dir(),
                    Arc::new(move || {
                        if let Some(signal) = weak.upgrade() {
                            signal.invalidate(SNIPPETS);
                        }
                    }),
                );
                #[cfg(not(target_os = "macos"))]
                let snippet_watch: Result<FileMonitor, String> = {
                    let monitor = FileMonitor::new(monitor_root.user_snippets_dir(), move || {
                        if let Some(signal) = weak.upgrade() {
                            signal.invalidate(SNIPPETS);
                        }
                    });
                    monitor.start();
                    Ok(monitor)
                };
                (monitors, snippet_watch)
            })
            .await;
        while receiver.next().await.is_some() {
            let interested = cx.update(|cx| {
                if !cx
                    .try_global::<Snapshots>()
                    .is_some_and(|state| Arc::ptr_eq(&state.signal, &worker_signal))
                {
                    return false;
                }
                cx.update_global::<Snapshots, _>(|state, _| {
                    state.subscribers.retain(|view| view.upgrade().is_some());
                    !state.subscribers.is_empty()
                })
            });
            let bits = worker_signal.dirty.swap(0, Ordering::AcqRel);
            if !interested {
                worker_signal.active.store(false, Ordering::Release);
                continue;
            }
            if bits == 0 {
                continue;
            }
            let revisions = worker_signal.revisions();
            let root = worker_root.clone();
            let store = worker_store.clone();
            let mut batch = cx
                .background_spawn(async move { read_batch(&root, store.as_ref(), bits, revisions) })
                .await;
            if let (Some(reading), Err(error)) = (&mut batch.snippets, &snippet_watch) {
                reading.value = Err(error.clone());
            }
            let subscribers = cx.update(|cx| {
                if !cx
                    .try_global::<Snapshots>()
                    .is_some_and(|state| Arc::ptr_eq(&state.signal, &worker_signal))
                {
                    return Vec::new();
                }
                cx.update_global::<Snapshots, _>(|state, _| {
                    let current = state.signal.revisions();
                    if let Some(reading) =
                        batch.snippets.filter(|value| value.revision == current.0)
                    {
                        state.snippets = Some(reading);
                    }
                    if let Some(reading) = batch.history.filter(|value| value.revision == current.1)
                    {
                        if let Ok(value) = reading.value {
                            state.last_history_value = Some(value);
                        }
                        state.history = Some(reading);
                    }
                    state.subscribers.clone()
                })
            });
            cx.update(|cx| {
                for subscriber in subscribers {
                    let _ = subscriber.update(cx, |_, cx| cx.notify());
                }
            });
        }
    });
    cx.set_global(Snapshots {
        root: root.state_dir().to_path_buf(),
        store,
        signal,
        snippets: None,
        history: None,
        last_history_value: None,
        subscribers: vec![view],
        _worker: worker,
    });
}
fn same_store(left: Option<&Store>, right: Option<&Store>) -> bool {
    match (left, right) {
        (None, None) => true,
        (Some(left), Some(right)) => Arc::ptr_eq(left, right),
        _ => false,
    }
}
struct Batch {
    snippets: Option<Reading<usize>>,
    history: Option<Reading<(i64, u64)>>,
}
fn read_batch(root: &DataRoot, store: Option<&Store>, bits: u8, revisions: (u64, u64)) -> Batch {
    Batch {
        snippets: (bits & SNIPPETS != 0).then(|| Reading {
            revision: revisions.0,
            value: read_snippets(&root.user_snippets_dir()),
        }),
        history: (bits & HISTORY != 0).then(|| {
            let mut span = work_profiler::begin(Key::work(
                "settings_snapshot",
                "history_statistics",
                "application",
                "settings",
                Queue::Background,
            ));
            let value = store
                .ok_or_else(|| "History database is not open".to_string())
                .and_then(|store| store.lock().statistics());
            span.items(1);
            Reading {
                revision: revisions.1,
                value,
            }
        }),
    }
}
fn read_snippets(directory: &Path) -> Result<usize, String> {
    let mut span = work_profiler::begin(Key::work(
        "settings_snapshot",
        "snippet_count",
        "application",
        "settings",
        Queue::Background,
    ));
    let entries = match std::fs::read_dir(directory) {
        Ok(entries) => entries,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(0),
        Err(error) => return Err(error.to_string()),
    };
    let mut count = 0;
    let mut bytes = 0;
    let mut files = 0;
    for entry in entries {
        let path = entry.map_err(|error| error.to_string())?.path();
        if path.extension().is_none_or(|e| e != "json")
            || path
                .file_name()
                .is_none_or(|n| n.to_string_lossy().starts_with('.'))
        {
            continue;
        }
        files += 1;
        let text = std::fs::read_to_string(&path).map_err(|error| error.to_string())?;
        bytes += text.len();
        // Match the snippet loader's valid-snippet count; invalid JSON does
        // not invent entries, while read errors remain explicitly unknown.
        if serde_json::from_str::<Snippet>(&text).is_ok() {
            count += 1;
        }
    }
    span.bytes(bytes);
    span.items(files);
    Ok(count)
}

#[cfg(test)]
mod tests {
    use super::*;
    use chau7_next_core::{
        history_record::HistoryRecord,
        snippet_store::{self, Snippet},
    };
    use futures::FutureExt;

    fn owned_root(label: &str) -> DataRoot {
        let directory = std::env::temp_dir().join(format!(
            "chau7-next-settings-snapshot-{label}-{}",
            uuid::Uuid::new_v4()
        ));
        let root = DataRoot::with_home(directory, true);
        root.ensure_dirs().unwrap();
        root
    }
    #[test]
    fn owned_files_and_sqlite_are_read_on_the_background_thread() {
        let root = owned_root("exact");
        let dir = root.user_snippets_dir();
        snippet_store::save_snippet(&dir, &Snippet::new("a", "A", "first")).unwrap();
        snippet_store::save_snippet(&dir, &Snippet::new("b", "B", "second")).unwrap();
        std::fs::write(dir.join("invalid.json"), "broken").unwrap();
        std::fs::write(dir.join(".hidden.json"), "{}").unwrap();
        let store = Arc::new(Mutex::new(HistoryStore::open(&root.history_db()).unwrap()));
        store
            .lock()
            .insert(&HistoryRecord::new("owned first"))
            .unwrap();
        store
            .lock()
            .insert(&HistoryRecord::new("owned second"))
            .unwrap();
        let main = std::thread::current().id();
        let worker_root = root.clone();
        let worker_store = store.clone();
        let (batch, thread) = std::thread::spawn(move || {
            (
                read_batch(
                    &worker_root,
                    Some(&worker_store),
                    SNIPPETS | HISTORY,
                    (17, 19),
                ),
                std::thread::current().id(),
            )
        })
        .join()
        .unwrap();
        assert_ne!(main, thread);
        let snippets = batch.snippets.unwrap();
        assert_eq!(snippets.revision, 17);
        assert_eq!(snippets.value.unwrap(), 2);
        let history = batch.history.unwrap();
        assert_eq!(history.revision, 19);
        assert_eq!(history.value.unwrap(), store.lock().statistics().unwrap());
        assert_eq!(store.lock().statistics().unwrap().0, 2);
        assert!(store.lock().statistics().unwrap().1 > 0);
        drop(store);
        std::fs::remove_dir_all(root.home()).unwrap();
    }
    #[test]
    fn failed_statistics_keep_the_last_count_with_explicit_unavailable_state() {
        let failed = Err("owned read error".to_string());
        let reading = statistics_result(&failed, Some((37, 4096)));
        assert_eq!(reading.value, Some((37, 4096)));
        assert!(reading.unavailable);
        assert!(!reading.pending);
        let initial = statistics_result(&failed, None);
        assert_eq!(initial.value, None);
        assert!(initial.unavailable);
        let recovered = statistics_result(&Ok((38, 8192)), Some((37, 4096)));
        assert_eq!(recovered.value, Some((38, 8192)));
        assert!(!recovered.unavailable);
    }
    #[test]
    fn same_root_reopening_requires_the_actual_database_instance() {
        let first = Arc::new(Mutex::new(
            HistoryStore::open(Path::new(":memory:")).unwrap(),
        ));
        let alias = first.clone();
        let replacement = Arc::new(Mutex::new(
            HistoryStore::open(Path::new(":memory:")).unwrap(),
        ));
        assert!(same_store(None, None));
        assert!(same_store(Some(&first), Some(&alias)));
        assert!(!same_store(Some(&first), Some(&replacement)));
        assert!(!same_store(Some(&first), None));
        assert!(!same_store(None, Some(&first)));
    }
    #[test]
    fn burst_invalidations_coalesce_and_fence_older_readings() {
        let (sender, mut receiver) = mpsc::channel(1);
        let signal = Signal {
            sender: Mutex::new(sender),
            dirty: AtomicU8::new(0),
            snippets_revision: AtomicU64::new(0),
            history_revision: AtomicU64::new(0),
            active: AtomicBool::new(true),
        };
        for _ in 0..1000 {
            signal.invalidate(SNIPPETS);
        }
        for _ in 0..1000 {
            signal.invalidate(HISTORY);
        }
        let mut queued = 0;
        while let Some(Some(())) = receiver.next().now_or_never() {
            queued += 1;
        }
        assert!(
            queued <= 2,
            "one shared sender must not grow a per-invalidation queue"
        );
        assert_eq!(signal.dirty.swap(0, Ordering::AcqRel), SNIPPETS | HISTORY);
        let admitted = signal.revisions();
        assert_eq!(admitted, (1000, 1000));
        signal.invalidate(SNIPPETS);
        assert_ne!(admitted.0, signal.revisions().0);
        assert_eq!(admitted.1, signal.revisions().1);
        signal.active.store(false, Ordering::Release);
        let revision = signal.revisions();
        signal.invalidate(SNIPPETS | HISTORY);
        assert_eq!(signal.revisions(), revision);
    }
    #[test]
    fn snippet_changes_and_read_errors_do_not_invent_counts() {
        let root = owned_root("changed");
        let dir = root.user_snippets_dir();
        assert_eq!(read_snippets(&dir).unwrap(), 0);
        snippet_store::save_snippet(&dir, &Snippet::new("a", "A", "first")).unwrap();
        assert_eq!(read_snippets(&dir).unwrap(), 1);
        std::fs::write(dir.join("a.json"), "invalid JSON").unwrap();
        assert_eq!(read_snippets(&dir).unwrap(), 0);
        snippet_store::save_snippet(&dir, &Snippet::new("a", "A", "recreated")).unwrap();
        assert_eq!(read_snippets(&dir).unwrap(), 1);
        std::fs::remove_file(dir.join("a.json")).unwrap();
        assert_eq!(read_snippets(&dir).unwrap(), 0);
        let not_directory = root.home().join("not-a-directory");
        std::fs::write(&not_directory, "file").unwrap();
        assert!(read_snippets(&not_directory).is_err());
        std::fs::remove_dir_all(root.home()).unwrap();
    }
    #[test]
    fn unrelated_sources_are_not_read_and_closed_database_is_unknown() {
        let root = owned_root("scope");
        let batch = read_batch(&root, None, HISTORY, (3, 5));
        assert!(batch.snippets.is_none());
        assert!(batch.history.unwrap().value.is_err());
        let batch = read_batch(&root, None, SNIPPETS, (7, 9));
        assert!(batch.history.is_none());
        assert_eq!(batch.snippets.unwrap().value.unwrap(), 0);
        std::fs::remove_dir_all(root.home()).unwrap();
    }
    #[gpui::test]
    fn actual_settings_worker_coalesces_owned_events_and_refreshes_on_reopening(
        harness: &mut gpui::TestAppContext,
    ) {
        use crate::settings::Settings;
        use crate::settings::config_files::ConfigFiles;
        let mut fixture = harness.new_app();
        let cx = &mut fixture;
        let root = owned_root("scheduler");
        let directory = root.user_snippets_dir();
        snippet_store::save_snippet(&directory, &Snippet::new("a", "A", "synthetic")).unwrap();
        snippet_store::save_snippet(&directory, &Snippet::new("b", "B", "synthetic")).unwrap();
        cx.update(|cx| {
            gpui_kit::init(cx);
            let settings = Settings::default();
            cx.set_global(AppData::new(root.clone()));
            cx.set_global(ConfigFiles::new(root.config_file(), settings.clone()));
            cx.set_global(settings);
            crate::observability::init_for_test(cx);
        });
        let open = |cx: &mut gpui::TestAppContext| {
            cx.update(|cx| {
                gpui_kit::open_window(gpui::WindowOptions::default(), cx, |window, cx| {
                    cx.new(|cx| SettingsView::new_inner(window, cx, Some(String::new())))
                })
                .unwrap()
            })
        };
        let (window, view) = open(cx);
        cx.run_until_parked();
        let signal = cx.update(|cx| {
            assert_eq!(snippets(cx), Some(2));
            assert!(statistics(cx).unavailable);
            cx.global::<Snapshots>().signal.clone()
        });
        std::fs::write(directory.join("a.json"), "invalid JSON").unwrap();
        cx.update(|cx| {
            for _ in 0..1000 {
                invalidate_snippets(&root);
            }
            assert_eq!(
                snippets(cx),
                None,
                "a changed revision cannot claim stale freshness"
            );
        });
        cx.run_until_parked();
        cx.update(|cx| {
            assert_eq!(snippets(cx), Some(1));
            assert_eq!(
                cx.global::<Snapshots>().signal.revisions().0,
                signal.revisions().0
            );
        });
        cx.update_window(window, |_, window, _| window.remove_window())
            .unwrap();
        drop(view);
        cx.run_until_parked();
        cx.update(|_| signal.invalidate(SNIPPETS));
        cx.run_until_parked();
        assert!(
            !signal.active.load(Ordering::Acquire),
            "a closed Settings view must stop producer interest"
        );
        snippet_store::save_snippet(&directory, &Snippet::new("a", "A", "recreated")).unwrap();
        let (window, view) = open(cx);
        cx.run_until_parked();
        cx.update(|cx| {
            assert!(Arc::ptr_eq(&signal, &cx.global::<Snapshots>().signal));
            assert_eq!(
                snippets(cx),
                Some(2),
                "reopening revalidates even when inactive events were suppressed"
            );
        });
        cx.update_window(window, |_, window, _| window.remove_window())
            .unwrap();
        drop(view);
        drop(fixture);
        std::fs::remove_dir_all(root.home()).unwrap();
    }
    #[gpui::test]
    fn uninitialized_render_snapshots_are_explicitly_unknown(cx: &mut gpui::TestAppContext) {
        cx.update(|cx| {
            assert_eq!(snippets(cx), None);
            let snapshot = statistics(cx);
            assert!(snapshot.pending);
            assert!(!snapshot.unavailable);
            assert_eq!(snapshot.value, None);
        });
    }
}
