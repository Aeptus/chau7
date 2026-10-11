//! Numeric diagnostics: live MCP/UI snapshots and bounded background persistence.
//! No terminal output, command text, repository paths, or environment is exported.

use std::fs::{self, OpenOptions};
use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::sync::{
    Mutex, OnceLock,
    mpsc::{self, SyncSender},
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
const MAX_HISTORY_BYTES: u64 = 4 * 1024 * 1024;

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

/// Same public identity keys as Swift, populated from this app's own bundle.
pub fn runtime_info() -> Value {
    let version = system::bundle_string("CFBundleShortVersionString")
        .unwrap_or_else(|| env!("CARGO_PKG_VERSION").into());
    let build = system::bundle_string("CFBundleVersion");
    let sha = system::bundle_string("Chau7NextSourceRevision");
    json!({"app_version": version, "build_number": build, "build_sha": sha,
        "build_timestamp": system::bundle_string("Chau7BuildTimestamp"),
        "build_channel": "next", "bundle_id": system::bundle_string("CFBundleIdentifier"),
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
        "process":process_snapshot(),"partial":true,
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
        "process": process, "hang_watchdog":crate::hang_watchdog::snapshot(cx),
        "main_thread": {"timer_delay_ms": heartbeat.and_then(|h| h.last_delay_ms),
            "max_timer_delay_ms": heartbeat.map(|h| h.max_delay_ms),
            "sample_count": heartbeat.map(|h| h.sample_count),
            "timer_interval_seconds": INTERVAL.as_secs()},
        "window_count": live.len(), "terminal_count": terminal_count,
        "terminals_truncated": terminal_count > terminals.len(), "terminals": terminals,
        "features": feature_profiler::snapshot().to_json(80),
        "persistence": {"interval_seconds": INTERVAL.as_secs(), "history_file_count": 2,
            "max_history_file_bytes": MAX_HISTORY_BYTES, "max_snapshot_bytes": MAX_RECORD_BYTES}
    })
}

#[derive(Default)]
struct Heartbeat {
    last_delay_ms: Option<f64>,
    max_delay_ms: f64,
    sample_count: u64,
}
impl Global for Heartbeat {}

struct Writer(SyncSender<Value>);
impl Global for Writer {}

pub fn directory(cx: &App) -> PathBuf {
    cx.global::<AppData>()
        .root
        .reports_dir()
        .join("performance")
}

/// Queue without blocking rendering or growing a backlog during disk stalls.
pub fn persist(snapshot: Value, cx: &App) -> bool {
    cx.try_global::<Writer>()
        .is_some_and(|writer| writer.0.try_send(snapshot).is_ok())
}

pub fn start(cx: &mut App) {
    let _ = identity();
    cx.set_global(Heartbeat::default());
    let dir = directory(cx);
    let (sender, receiver) = mpsc::sync_channel::<Value>(1);
    match std::thread::Builder::new()
        .name("chau7-next-performance".into())
        .spawn(move || {
            while let Ok(snapshot) = receiver.recv() {
                if let Err(error) = write_snapshot(&dir, &snapshot, MAX_HISTORY_BYTES) {
                    log::warn!("Performance diagnostics persistence failed: {error}");
                }
            }
        }) {
        Ok(_) => cx.set_global(Writer(sender)),
        Err(error) => {
            log::warn!("Performance diagnostics worker failed: {error}");
            return;
        }
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

fn write_snapshot(dir: &Path, snapshot: &Value, history_limit: u64) -> io::Result<()> {
    let mut bytes = serde_json::to_vec(snapshot)?;
    bytes.push(b'\n');
    if bytes.len() > MAX_RECORD_BYTES {
        return Err(io::Error::other("performance snapshot exceeds size bound"));
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
    if fs::metadata(&history).is_ok_and(|m| m.len() + bytes.len() as u64 > history_limit) {
        let previous = dir.join("history.1.jsonl");
        if previous.exists() {
            fs::remove_file(&previous)?;
        }
        fs::rename(&history, previous)?;
    }
    OpenOptions::new()
        .create(true)
        .append(true)
        .open(history)?
        .write_all(&bytes)
}

#[cfg(test)]
mod tests {
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
        let size = serde_json::to_vec(&value).unwrap().len() as u64 + 1;
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
        assert_eq!(fs::read_dir(&dir).unwrap().count(), 3);
        fs::remove_dir_all(dir).unwrap();
    }
}
