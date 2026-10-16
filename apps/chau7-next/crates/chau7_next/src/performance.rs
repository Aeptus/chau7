//! Numeric diagnostics: live MCP/UI snapshots and bounded background persistence.
//! No terminal output, command text, repository paths, or environment is exported.

use std::fs::{self, OpenOptions};
use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::sync::{
    Arc, Mutex, OnceLock,
    mpsc::{self, SyncSender, TrySendError},
};
use std::time::{Duration, Instant};

use crate::{
    platform::{process, system},
    workspace::AppData,
};
use chau7_next_core::feature_profiler;
use gpui::{App, Global};
use serde_json::{Value, json};

const INTERVAL: Duration = Duration::from_secs(5);
const MAX_TERMINALS: usize = 128;
const MAX_RECORD_BYTES: usize = 1024 * 1024;
const MAX_HISTORY_BYTES: u64 = 8 * 1024 * 1024;

struct Identity {
    started: Instant,
    launch_time: String,
}
fn identity() -> &'static Identity {
    static IDENTITY: OnceLock<Identity> = OnceLock::new();
    IDENTITY.get_or_init(|| Identity {
        started: Instant::now(),
        launch_time: chrono::Utc::now().to_rfc3339(),
    })
}

#[derive(Default)]
struct CpuSampler {
    previous: Option<(Instant, Duration)>,
}
impl CpuSampler {
    fn sample(&mut self, now: Instant, cpu: Option<Duration>) -> Option<f64> {
        let Some(cpu) = cpu else {
            self.previous = None;
            return None;
        };
        let previous = self.previous.replace((now, cpu));
        let (at, before) = previous?;
        let elapsed = now.checked_duration_since(at)?.as_secs_f64();
        let delta = cpu.checked_sub(before)?.as_secs_f64();
        (elapsed > 0.0).then_some(delta / elapsed * 100.0)
    }
}

/// Initialize the process identity at Rust main entry.
pub fn begin_launch() {
    let _ = identity();
}

fn bundle_build_metadata(
    lookup: impl Fn(&str) -> Option<String>,
    production: bool,
) -> (String, Option<String>) {
    let channel = lookup("Chau7BuildChannel")
        .filter(|value| matches!(value.as_str(), "production" | "next"))
        .unwrap_or_else(|| if production { "production" } else { "next" }.into());
    let (revision_key, legacy_key) = if channel == "production" {
        ("Chau7SourceRevision", "Chau7NextSourceRevision")
    } else {
        ("Chau7NextSourceRevision", "Chau7SourceRevision")
    };
    let revision = lookup(revision_key).or_else(|| lookup(legacy_key));
    (channel, revision)
}

pub(crate) fn build_metadata() -> (String, Option<String>) {
    bundle_build_metadata(
        system::bundle_string,
        chau7_next_core::data_root::PRODUCTION_CHANNEL,
    )
}

/// Same public identity keys as Swift, populated from this app's own bundle.
pub fn runtime_info() -> Value {
    let version = system::bundle_string("CFBundleShortVersionString")
        .unwrap_or_else(|| env!("CARGO_PKG_VERSION").into());
    let build = system::bundle_string("CFBundleVersion");
    let (channel, sha) = build_metadata();
    json!({"app_version": version, "build_number": build, "build_sha": sha,
        "build_timestamp": system::bundle_string("Chau7BuildTimestamp"),
        "build_channel": channel, "bundle_id": system::bundle_string("CFBundleIdentifier"),
        "process_id": std::process::id(), "launch_time": identity().launch_time,
        "session_started_at": identity().launch_time,
        "mcp_protocol_version": chau7_next_core::mcp::protocol::PROTOCOL_VERSION,
        "observability_schema_version": 2,
        "components": {"app": {"status": "running", "version": version, "build_number": build, "build_sha": sha}}
    })
}

/// Process measurements remain available from a client thread during UI stalls.
fn process_snapshot() -> Value {
    static CPU: Mutex<CpuSampler> = Mutex::new(CpuSampler { previous: None });
    let usage = process::process_usage(std::process::id());
    let cpu = CPU
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .sample(Instant::now(), usage.map(|u| u.cpu_time));
    json!({"cpu_percent":cpu,
        "cpu_percent_basis":"one logical CPU = 100 percent; app process only",
        "cpu_time_seconds":usage.map(|u|u.cpu_time.as_secs_f64()),
        "resident_bytes":usage.map(|u|u.resident_bytes)})
}
pub fn unresponsive_snapshot() -> Value {
    json!({"schema_version":1,"captured_at":chrono::Utc::now().to_rfc3339(),
        "runtime":runtime_info(),"uptime_seconds":identity().started.elapsed().as_secs_f64(),
        "process":process_snapshot(),"startup":crate::startup::snapshot(),"partial":true,
        "hang_watchdog":{"status":"main_thread_unresponsive","render_circuit_breaker_open":crate::hang_watchdog::render_blocked()},
        "error":"main_thread_unresponsive","retryable":true,"timeout_ms":1000,
        "main_thread":{"status":"unresponsive","timer_delay_ms":null,"sample_count":null},
        "window_count":null,"terminal_count":null,"terminals":null,"features":null})
}

/// Capture all windows and panes. Missing measurements are JSON null, never zero.
pub fn capture(cx: &App) -> Value {
    let process = process_snapshot();
    let live = AppData::live(cx);
    let mut terminals = Vec::new();
    let mut terminal_count = 0;
    for (window_id, (_, workspace)) in live.iter().enumerate() {
        let entries = workspace.read(cx).performance_terminals(window_id, cx);
        terminal_count += entries.len();
        terminals.extend(
            entries
                .into_iter()
                .take(MAX_TERMINALS.saturating_sub(terminals.len())),
        );
    }
    let heartbeat = cx.try_global::<Heartbeat>();
    json!({"schema_version": 1, "captured_at": chrono::Utc::now().to_rfc3339(),
        "runtime": runtime_info(), "uptime_seconds": identity().started.elapsed().as_secs_f64(),
        "process": process, "startup":crate::startup::snapshot(), "hang_watchdog":crate::hang_watchdog::snapshot(cx),
        "memory_retention": crate::memory_pressure::diagnostics(cx),
        "window_renderer": crate::window_backend::diagnostics(cx),
        "incidents": crate::incidents::diagnostics(),
        "remote_grid": crate::remote::grid_diagnostics(cx),
        "work_profile": chau7_next_core::work_profiler::snapshot(),
        "telemetry":crate::telemetry::diagnostics(cx),
        "main_thread": {"timer_delay_ms": heartbeat.and_then(|h| h.last_delay_ms)
                .filter(|ms| ms.is_finite() && *ms >= 0.0),
            "max_timer_delay_ms": heartbeat.filter(|h| h.sample_count > 0)
                .map(|h| h.max_delay_ms).filter(|ms| ms.is_finite() && *ms >= 0.0),
            "sample_count": heartbeat.map(|h| h.sample_count),
            "timer_interval_seconds": INTERVAL.as_secs()},
        "window_count": live.len(), "terminal_count": terminal_count,
        "terminals_truncated": terminal_count > terminals.len(), "terminals": terminals,
        "features": feature_profiler::snapshot().to_json(80),
        "instrumentation": {"os_signpost_supported":cfg!(target_os="macos"),
            "signpost_subsystem":if cfg!(target_os="macos") {Some("com.chau7.next")} else {None},
            "signpost_category":if cfg!(target_os="macos") {Some("performance")} else {None}},
        "persistence": persistence_snapshot(cx)
    })
}

#[derive(Default)]
struct Heartbeat {
    last_delay_ms: Option<f64>,
    max_delay_ms: f64,
    sample_count: u64,
}
impl Global for Heartbeat {}

#[derive(Clone, Copy, PartialEq, Eq)]
enum WriterState {
    Running,
    Draining,
    Closed,
    Disconnected,
    StartFailed,
}
impl WriterState {
    fn name(self) -> &'static str {
        match self {
            Self::Running => "running",
            Self::Draining => "draining",
            Self::Closed => "closed",
            Self::Disconnected => "disconnected",
            Self::StartFailed => "start_failed",
        }
    }
}

#[derive(Default)]
struct PersistenceCounters {
    accepted: u64,
    written: u64,
    drop_full: u64,
    failure: u64,
    disconnected: u64,
    rejected_closed: u64,
    worker_start_failure: u64,
}
struct PersistenceStats {
    state: WriterState,
    counters: PersistenceCounters,
    last_error_category: Option<&'static str>,
}
impl PersistenceStats {
    fn new() -> Self {
        Self {
            state: WriterState::Running,
            counters: PersistenceCounters::default(),
            last_error_category: None,
        }
    }
}

/// Fixed vocabulary only: never retain an error's message, path or OS text.
fn error_category(error: &io::Error) -> &'static str {
    match error.kind() {
        io::ErrorKind::NotFound => "not_found",
        io::ErrorKind::PermissionDenied => "permission_denied",
        io::ErrorKind::AlreadyExists => "already_exists",
        io::ErrorKind::InvalidInput => "invalid_input",
        io::ErrorKind::InvalidData => "invalid_data",
        io::ErrorKind::WriteZero => "write_zero",
        io::ErrorKind::Interrupted => "interrupted",
        io::ErrorKind::WouldBlock => "would_block",
        io::ErrorKind::StorageFull => "storage_full",
        io::ErrorKind::OutOfMemory => "out_of_memory",
        _ => "other_io",
    }
}

struct Writer {
    sender: Mutex<Option<SyncSender<Value>>>,
    worker: Mutex<Option<std::thread::JoinHandle<()>>>,
    stats: Arc<Mutex<PersistenceStats>>,
}
impl Global for Writer {}
impl Writer {
    fn new(dir: PathBuf) -> Self {
        Self::spawn(move |snapshot| write_snapshot(&dir, snapshot, MAX_HISTORY_BYTES))
    }

    /// The worker never holds a snapshot lock across filesystem operations.
    fn spawn(mut write: impl FnMut(&Value) -> io::Result<()> + Send + 'static) -> Self {
        let (sender, receiver) = mpsc::sync_channel::<Value>(1);
        let stats = Arc::new(Mutex::new(PersistenceStats::new()));
        let worker_stats = stats.clone();
        let worker = std::thread::Builder::new()
            .name("chau7-next-performance".into())
            .spawn(move || {
                let mut reported_failure = false;
                while let Ok(snapshot) = receiver.recv() {
                    let result = write(&snapshot);
                    {
                        let mut stats = worker_stats.lock().unwrap_or_else(|e| e.into_inner());
                        match &result {
                            Ok(()) => {
                                stats.counters.written = stats.counters.written.saturating_add(1);
                            }
                            Err(error) => {
                                stats.counters.failure = stats.counters.failure.saturating_add(1);
                                stats.last_error_category = Some(error_category(error));
                            }
                        }
                    }
                    // Logging is also outside the lock read by the UI snapshot.
                    match result {
                        Ok(()) => reported_failure = false,
                        Err(error) if !reported_failure => {
                            log::warn!(
                                "Performance diagnostics persistence failed: {}",
                                error_category(&error)
                            );
                            reported_failure = true;
                        }
                        Err(_) => {}
                    }
                }
                worker_stats.lock().unwrap_or_else(|e| e.into_inner()).state = WriterState::Closed;
            });
        match worker {
            Ok(worker) => Self {
                sender: Mutex::new(Some(sender)),
                worker: Mutex::new(Some(worker)),
                stats,
            },
            Err(error) => {
                {
                    let mut measured = stats.lock().unwrap_or_else(|e| e.into_inner());
                    measured.state = WriterState::StartFailed;
                    measured.counters.worker_start_failure = 1;
                    measured.last_error_category = Some(error_category(&error));
                }
                log::warn!(
                    "Performance diagnostics worker failed: {}",
                    error_category(&error)
                );
                Self {
                    sender: Mutex::new(None),
                    worker: Mutex::new(None),
                    stats,
                }
            }
        }
    }

    fn enqueue(&self, snapshot: Value) -> bool {
        let sender = self.sender.lock().unwrap_or_else(|e| e.into_inner());
        // Keep the successful admission increment ordered before its completion.
        // This bounded lock covers try_send only, never I/O or a blocking send.
        let mut stats = self.stats.lock().unwrap_or_else(|e| e.into_inner());
        let Some(sender) = sender.as_ref() else {
            stats.counters.rejected_closed = stats.counters.rejected_closed.saturating_add(1);
            return false;
        };
        match sender.try_send(snapshot) {
            Ok(()) => {
                stats.counters.accepted = stats.counters.accepted.saturating_add(1);
                true
            }
            Err(TrySendError::Full(_)) => {
                stats.counters.drop_full = stats.counters.drop_full.saturating_add(1);
                false
            }
            Err(TrySendError::Disconnected(_)) => {
                stats.counters.disconnected = stats.counters.disconnected.saturating_add(1);
                stats.state = WriterState::Disconnected;
                false
            }
        }
    }

    fn close(&self) -> Option<std::thread::JoinHandle<()>> {
        let sender = self.sender.lock().unwrap_or_else(|e| e.into_inner()).take();
        let worker = self.worker.lock().unwrap_or_else(|e| e.into_inner()).take();
        if sender.is_some() {
            self.stats.lock().unwrap_or_else(|e| e.into_inner()).state = if worker.is_some() {
                WriterState::Draining
            } else {
                WriterState::Closed
            };
        }
        // Dropping the last producer lets the worker drain its one pending value.
        drop(sender);
        worker
    }
}

/// Only measured in-memory state is read here; no I/O, timers or joins.
fn persistence_snapshot(cx: &App) -> Value {
    let writer = cx.try_global::<Writer>();
    let stats = writer.map(|writer| writer.stats.lock().unwrap_or_else(|e| e.into_inner()));
    let counters = stats.as_ref().map(|stats| {
        let counts = &stats.counters;
        json!({"accepted":counts.accepted,"written":counts.written,
            "drop_full":counts.drop_full,"failure":counts.failure,
            "disconnected":counts.disconnected,"rejected_closed":counts.rejected_closed,
            "worker_start_failure":counts.worker_start_failure})
    });
    json!({"interval_seconds":INTERVAL.as_secs(),"history_file_count":2,
        "max_history_file_bytes":MAX_HISTORY_BYTES,"max_snapshot_bytes":MAX_RECORD_BYTES,
        "availability":stats.as_ref().map(|stats|stats.state==WriterState::Running),
        "state":stats.as_ref().map(|stats|stats.state.name()),"counters":counters,
        "last_error_category":stats.as_ref().and_then(|stats|stats.last_error_category),
        "accepted_basis":"nonblocking queue admission; not an acknowledgement of writing",
        "written_basis":"latest replacement and history append/flush completed; no fsync durability guarantee"})
}

pub fn directory(cx: &App) -> PathBuf {
    cx.global::<AppData>()
        .root
        .reports_dir()
        .join("performance")
}

/// Queue without blocking rendering or growing a backlog during disk stalls.
pub fn persist(snapshot: Value, cx: &App) -> bool {
    cx.try_global::<Writer>()
        .is_some_and(|writer| writer.enqueue(snapshot))
}

pub fn start(cx: &mut App) {
    let _ = identity();
    cx.set_global(Heartbeat::default());
    let writer = Writer::new(directory(cx));
    let started = writer
        .worker
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .is_some();
    cx.set_global(writer);
    if !started {
        return;
    }
    let _ = persist(capture(cx), cx);
    let timer = crate::observability::register_timer(
        cx,
        "performance.capture",
        "Numeric performance capture",
        "performance",
        INTERVAL.as_millis() as u64,
    );
    cx.spawn(async move |cx| {
        let _timer = timer;
        loop {
            let due = Instant::now() + INTERVAL;
            cx.background_executor().timer(INTERVAL).await;
            cx.update(|cx| {
                let delay = Instant::now().saturating_duration_since(due).as_secs_f64() * 1000.0;
                let heartbeat = cx.global_mut::<Heartbeat>();
                heartbeat.last_delay_ms = Some(delay);
                heartbeat.max_delay_ms = heartbeat.max_delay_ms.max(delay);
                heartbeat.sample_count += 1;
                let _ = persist(capture(cx), cx);
            });
        }
    })
    .detach();
}

/// Close the producer on the UI thread; drain accepted records and join only
/// from the app's background quit future. Repeated stop calls are harmless.
pub fn stop(cx: &App) -> Option<std::thread::JoinHandle<()>> {
    cx.try_global::<Writer>()?.close()
}

fn history_record(snapshot: &Value) -> io::Result<Vec<u8>> {
    let timestamp = snapshot
        .get("captured_at")
        .cloned()
        .unwrap_or_else(|| json!(chrono::Utc::now().to_rfc3339()));
    let envelope = json!({"schema_version":1, "timestamp":timestamp,
        "category":"runtime_snapshot", "metrics":snapshot});
    let mut bytes = serde_json::to_vec(&envelope)?;
    bytes.push(b'\n');
    if bytes.len() > MAX_RECORD_BYTES {
        return Err(io::Error::other(
            "performance history record exceeds size bound",
        ));
    }
    Ok(bytes)
}

fn write_snapshot(dir: &Path, snapshot: &Value, history_limit: u64) -> io::Result<()> {
    let mut bytes = serde_json::to_vec(snapshot)?;
    bytes.push(b'\n');
    if bytes.len() > MAX_RECORD_BYTES {
        return Err(io::Error::other("performance snapshot exceeds size bound"));
    }
    let record = history_record(snapshot)?;
    if record.len() as u64 > history_limit {
        return Err(io::Error::other(
            "performance history record exceeds rotation bound",
        ));
    }
    fs::create_dir_all(dir)?;
    let pending = dir.join("latest.tmp");
    fs::write(&pending, &bytes)?;
    let latest = dir.join("latest.json");
    #[cfg(target_os = "windows")]
    if latest.exists() {
        fs::remove_file(&latest)?;
    }
    fs::rename(pending, latest)?;
    let history = dir.join("history.jsonl");
    if fs::metadata(&history)
        .is_ok_and(|m| m.len().saturating_add(record.len() as u64) > history_limit)
    {
        let previous = dir.join("history.1.jsonl");
        if previous.exists() {
            fs::remove_file(&previous)?;
        }
        fs::rename(&history, previous)?;
    }
    let mut file = OpenOptions::new().create(true).append(true).open(history)?;
    file.write_all(&record)?;
    file.flush()
}

#[cfg(test)]
mod tests {
    #[test]
    fn production_runtime_uses_canonical_bundle_metadata() {
        let (channel, revision) = super::bundle_build_metadata(
            |key| match key {
                "Chau7BuildChannel" => Some("production".into()),
                "Chau7SourceRevision" => Some("production-sha".into()),
                "Chau7NextSourceRevision" => Some("other-sha".into()),
                _ => None,
            },
            false,
        );
        assert_eq!(channel, "production");
        assert_eq!(revision.as_deref(), Some("production-sha"));
    }

    #[test]
    fn next_runtime_preserves_its_own_revision_key() {
        let (channel, revision) = super::bundle_build_metadata(
            |key| match key {
                "Chau7BuildChannel" => Some("next".into()),
                "Chau7NextSourceRevision" => Some("next-sha".into()),
                "Chau7SourceRevision" => Some("other-sha".into()),
                _ => None,
            },
            true,
        );
        assert_eq!(channel, "next");
        assert_eq!(revision.as_deref(), Some("next-sha"));
    }

    #[test]
    fn runtime_build_fallback_uses_compiled_channel_and_keeps_unknown_revision_null() {
        assert_eq!(
            super::bundle_build_metadata(|_| None, true),
            ("production".into(), None)
        );
        assert_eq!(
            super::bundle_build_metadata(|_| None, false),
            ("next".into(), None)
        );
        let (_, revision) = super::bundle_build_metadata(
            |key| (key == "Chau7NextSourceRevision").then(|| "legacy-sha".into()),
            true,
        );
        assert_eq!(revision.as_deref(), Some("legacy-sha"));
    }

    #[test]
    fn unresponsive_diagnostics_keep_process_identity_and_mark_gui_data_unknown() {
        let snapshot = super::unresponsive_snapshot();
        assert_eq!(snapshot["partial"], true);
        assert_eq!(snapshot["error"], "main_thread_unresponsive");
        assert_eq!(snapshot["timeout_ms"], 1000);
        assert_eq!(snapshot["runtime"]["process_id"], std::process::id());
        assert!(snapshot["uptime_seconds"].as_f64().is_some());
        assert!(snapshot["terminals"].is_null());
        assert!(snapshot["window_count"].is_null());
        assert!(snapshot["terminal_count"].is_null());
        let process = snapshot["process"].as_object().unwrap();
        assert!(process.contains_key("resident_bytes"));
        for key in [
            "command",
            "prompt",
            "environment",
            "terminal_content",
            "cwd",
            "title",
        ] {
            assert!(!snapshot.to_string().contains(&format!("\"{key}\"")));
        }
    }

    use super::*;
    #[gpui::test]
    fn actual_capture_keeps_unmeasured_delay_unknown_and_measured_zero_valid(
        cx: &mut gpui::TestAppContext,
    ) {
        cx.update(|cx| {
            // No window, service timers, provider calls or user profile access.
            let root = chau7_next_core::data_root::DataRoot::with_home(
                std::env::temp_dir()
                    .join(format!("next-heartbeat-capture-{}", uuid::Uuid::new_v4())),
                true,
            );
            cx.set_global(AppData::new(root));
            cx.set_global(Heartbeat::default());
            let initial = capture(cx);
            assert!(initial["persistence"]["availability"].is_null());
            assert!(initial["persistence"]["state"].is_null());
            assert!(initial["persistence"]["counters"].is_null());
            assert!(initial["persistence"]["last_error_category"].is_null());
            assert!(initial["main_thread"]["timer_delay_ms"].is_null());
            assert!(initial["main_thread"]["max_timer_delay_ms"].is_null());
            assert_eq!(initial["main_thread"]["sample_count"], 0);
            *cx.global_mut::<Heartbeat>() = Heartbeat {
                last_delay_ms: Some(0.0),
                max_delay_ms: 0.0,
                sample_count: 1,
            };
            let measured = capture(cx);
            assert_eq!(
                measured["main_thread"]["timer_delay_ms"].as_f64(),
                Some(0.0)
            );
            assert_eq!(
                measured["main_thread"]["max_timer_delay_ms"].as_f64(),
                Some(0.0)
            );
            assert_eq!(measured["main_thread"]["sample_count"], 1);
            for invalid in [f64::NAN, f64::INFINITY, f64::NEG_INFINITY, -1.0] {
                *cx.global_mut::<Heartbeat>() = Heartbeat {
                    last_delay_ms: Some(invalid),
                    max_delay_ms: invalid,
                    sample_count: 1,
                };
                let invalid = capture(cx);
                assert!(invalid["main_thread"]["timer_delay_ms"].is_null());
                assert!(invalid["main_thread"]["max_timer_delay_ms"].is_null());
                assert_eq!(invalid["main_thread"]["sample_count"], 1);
            }
        });
    }

    fn owned_directory(label: &str) -> PathBuf {
        std::env::temp_dir().join(format!("next-perf-{label}-{}", uuid::Uuid::new_v4()))
    }

    #[gpui::test]
    fn persistence_admission_is_distinct_from_real_write_and_double_quit_drains_once(
        cx: &mut gpui::TestAppContext,
    ) {
        let dir = owned_directory("success");
        let snapshot = json!({"schema_version":1,"observed":42});
        cx.update(|cx| {
            assert!(!persist(snapshot.clone(), cx));
            assert!(persistence_snapshot(cx)["counters"].is_null());
            cx.set_global(Writer::new(dir.clone()));
            let initial = persistence_snapshot(cx);
            assert_eq!(initial["availability"], true);
            assert_eq!(initial["state"], "running");
            assert_eq!(initial["counters"]["accepted"], 0);
            assert_eq!(initial["counters"]["written"], 0);
            assert!(persist(snapshot.clone(), cx));
        });
        let worker = cx.update(|cx| {
            let worker = stop(cx).expect("first quit owns the worker");
            assert!(stop(cx).is_none(), "second quit never joins twice");
            let stopped = persistence_snapshot(cx);
            assert_eq!(stopped["availability"], false);
            assert_eq!(stopped["counters"]["accepted"], 1);
            assert!(!persist(snapshot.clone(), cx));
            worker
        });
        // Real filesystem I/O drains on the worker, joined outside the UI update.
        worker.join().unwrap();
        cx.update(|cx| {
            let measured = persistence_snapshot(cx);
            assert_eq!(measured["state"], "closed");
            assert_eq!(measured["counters"]["accepted"], 1);
            assert_eq!(measured["counters"]["written"], 1);
            assert_eq!(measured["counters"]["failure"], 0);
            assert_eq!(measured["counters"]["rejected_closed"], 1);
            assert_eq!(measured["counters"]["disconnected"], 0);
            assert!(measured["last_error_category"].is_null());
            assert!(
                measured["written_basis"]
                    .as_str()
                    .unwrap()
                    .contains("no fsync")
            );
        });
        assert_eq!(
            serde_json::from_slice::<Value>(&fs::read(dir.join("latest.json")).unwrap()).unwrap(),
            snapshot
        );
        assert_eq!(
            fs::read(dir.join("history.jsonl"))
                .unwrap()
                .iter()
                .filter(|b| **b == b'\n')
                .count(),
            1
        );
        fs::remove_dir_all(dir).unwrap();
    }

    #[gpui::test]
    fn persistence_real_io_failure_is_counted_without_path_or_error_text(
        cx: &mut gpui::TestAppContext,
    ) {
        let dir = owned_directory("failure");
        fs::write(&dir, b"owned fixture blocks directory creation").unwrap();
        let worker = cx.update(|cx| {
            cx.set_global(Writer::new(dir.clone()));
            assert!(persist(json!({"observed":7}), cx));
            stop(cx).unwrap()
        });
        worker.join().unwrap();
        cx.update(|cx| {
            let measured = persistence_snapshot(cx);
            assert_eq!(measured["counters"]["accepted"], 1);
            assert_eq!(measured["counters"]["written"], 0);
            assert_eq!(measured["counters"]["failure"], 1);
            assert_eq!(measured["state"], "closed");
            assert_eq!(measured["last_error_category"], "already_exists");
            assert!(
                !measured
                    .to_string()
                    .contains(&dir.to_string_lossy().into_owned())
            );
        });
        fs::remove_file(dir).unwrap();
    }

    #[gpui::test]
    fn persistence_busy_worker_has_only_one_pending_record_and_reports_drop_full(
        cx: &mut gpui::TestAppContext,
    ) {
        let dir = owned_directory("busy");
        let worker_dir = dir.clone();
        let (entered, wait_entered) = mpsc::sync_channel(0);
        let (release, wait_release) = mpsc::sync_channel(0);
        let mut first = true;
        let writer = Writer::spawn(move |snapshot| {
            if first {
                first = false;
                entered.send(()).unwrap();
                wait_release.recv().unwrap();
            }
            write_snapshot(&worker_dir, snapshot, MAX_HISTORY_BYTES)
        });
        cx.update(|cx| {
            cx.set_global(writer);
            assert!(persist(json!({"sequence":1}), cx));
        });
        wait_entered.recv_timeout(Duration::from_secs(5)).unwrap();
        let worker = cx.update(|cx| {
            // The first write is blocked; exactly one other record is pending.
            assert!(persist(json!({"sequence":2}), cx));
            assert!(!persist(json!({"sequence":3}), cx));
            let measured = persistence_snapshot(cx);
            assert_eq!(measured["availability"], true);
            assert_eq!(measured["counters"]["accepted"], 2);
            assert_eq!(measured["counters"]["written"], 0);
            assert_eq!(measured["counters"]["drop_full"], 1);
            let worker = stop(cx).unwrap();
            assert_eq!(persistence_snapshot(cx)["state"], "draining");
            worker
        });
        release.send(()).unwrap();
        worker.join().unwrap();
        cx.update(|cx| {
            let measured = persistence_snapshot(cx);
            assert_eq!(measured["counters"]["written"], 2);
            assert_eq!(measured["counters"]["drop_full"], 1);
            assert_eq!(measured["counters"]["failure"], 0);
            assert_eq!(measured["state"], "closed");
        });
        assert_eq!(
            serde_json::from_slice::<Value>(&fs::read(dir.join("latest.json")).unwrap()).unwrap(),
            json!({"sequence":2})
        );
        assert_eq!(
            fs::read(dir.join("history.jsonl"))
                .unwrap()
                .iter()
                .filter(|b| **b == b'\n')
                .count(),
            2
        );
        fs::remove_dir_all(dir).unwrap();
    }

    #[gpui::test]
    fn persistence_disconnected_receiver_is_distinct_from_explicit_close(
        cx: &mut gpui::TestAppContext,
    ) {
        let (sender, receiver) = mpsc::sync_channel(1);
        drop(receiver);
        cx.update(|cx| {
            cx.set_global(Writer {
                sender: Mutex::new(Some(sender)),
                worker: Mutex::new(None),
                stats: Arc::new(Mutex::new(PersistenceStats::new())),
            });
            assert!(!persist(json!({"observed":1}), cx));
            let disconnected = persistence_snapshot(cx);
            assert_eq!(disconnected["availability"], false);
            assert_eq!(disconnected["state"], "disconnected");
            assert_eq!(disconnected["counters"]["disconnected"], 1);
            assert_eq!(disconnected["counters"]["rejected_closed"], 0);
            assert_eq!(disconnected["counters"]["accepted"], 0);
            assert!(stop(cx).is_none());
            assert!(!persist(json!({"observed":2}), cx));
            let closed = persistence_snapshot(cx);
            assert_eq!(closed["state"], "closed");
            assert_eq!(closed["counters"]["disconnected"], 1);
            assert_eq!(closed["counters"]["rejected_closed"], 1);
        });
    }

    #[test]
    fn cpu_is_a_delta_with_missing_and_reset_handling() {
        let mut sampler = CpuSampler::default();
        let now = Instant::now();
        assert_eq!(sampler.sample(now, Some(Duration::from_secs(1))), None);
        assert_eq!(
            sampler.sample(now + Duration::from_secs(2), Some(Duration::from_secs(4))),
            Some(150.0)
        );
        assert_eq!(sampler.sample(now + Duration::from_secs(3), None), None);
        assert_eq!(
            sampler.sample(now + Duration::from_secs(4), Some(Duration::from_secs(4))),
            None
        );
        assert_eq!(
            sampler.sample(now + Duration::from_secs(5), Some(Duration::from_secs(1))),
            None
        );
    }
    #[test]
    fn persistence_rotates_and_latest_is_valid() {
        let dir = std::env::temp_dir().join(format!("chau7-next-perf-{}", uuid::Uuid::new_v4()));
        let value = json!({"schema_version": 1, "sample": 42});
        let size = history_record(&value).unwrap().len() as u64;
        for _ in 0..6 {
            write_snapshot(&dir, &value, size * 2).unwrap();
        }
        assert_eq!(
            serde_json::from_slice::<Value>(&fs::read(dir.join("latest.json")).unwrap()).unwrap(),
            value
        );
        for name in ["history.jsonl", "history.1.jsonl"] {
            assert!(fs::metadata(dir.join(name)).unwrap().len() <= size * 2);
        }
        let row: Value = serde_json::from_slice(
            fs::read(dir.join("history.jsonl"))
                .unwrap()
                .split(|b| *b == b'\n')
                .next()
                .unwrap(),
        )
        .unwrap();
        assert_eq!(row["schema_version"], 1);
        assert!(row["timestamp"].is_string());
        assert_eq!(row["category"], "runtime_snapshot");
        assert_eq!(row["metrics"], value);
        assert_eq!(fs::read_dir(&dir).unwrap().count(), 3);
        fs::remove_dir_all(dir).unwrap();
    }
}
