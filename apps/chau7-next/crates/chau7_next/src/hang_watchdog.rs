//! Independent evidence capture for a confirmed main-thread stall.
//! The helper samples the app; it never terminates a shell-owning process.
#[cfg(target_os = "macos")]
use chau7_next_core::hang_monitor::{Lifetime, Phase, SampleEvidence, StackObservations};
use chau7_next_core::{
    data_root::DataRoot,
    hang_monitor::{Heartbeat, Monitor, Policy, WatchdogCommand},
};
use gpui::{App, Global};
#[cfg(target_os = "macos")]
use serde::Deserialize;
use serde::Serialize;
use serde_json::{Value, json};
use std::{
    fs, io,
    path::{Path, PathBuf},
    process::Child,
    sync::{
        Arc,
        atomic::{AtomicBool, AtomicU64, Ordering},
    },
    thread::{self, JoinHandle},
    time::{Duration, Instant},
};
#[cfg(any(target_os = "macos", test))]
use std::{fs::File, io::Read};
#[cfg(target_os = "macos")]
use std::{
    fs::OpenOptions,
    process::{Command, Stdio},
};
const TICK: Duration = Duration::from_millis(250);
const HEARTBEAT_INTERVAL: Duration = Duration::from_secs(1);
const MAX_HEARTBEAT: u64 = 16 * 1024;
#[cfg(any(target_os = "macos", test))]
const MAX_SAMPLE: u64 = 8 * 1024 * 1024;
#[cfg(target_os = "macos")]
const SAMPLE_TIMEOUT: Duration = Duration::from_secs(10);

struct Shared {
    stop: AtomicBool,
    token: AtomicU64,
    last_progress_ms: AtomicU64,
    render_blocked: AtomicBool,
    stalls: AtomicU64,
    recoveries: AtomicU64,
    launch_id: String,
}
struct Worker {
    shared: Arc<Shared>,
    thread: Option<JoinHandle<()>>,
    directory: PathBuf,
}
impl Global for Worker {}
impl Drop for Worker {
    fn drop(&mut self) {
        self.shared.stop.store(true, Ordering::Release);
        if let Some(worker) = &self.thread {
            worker.thread().unpark();
        }
    }
}
static RENDER_BLOCKED: AtomicBool = AtomicBool::new(false);
pub fn render_blocked() -> bool {
    RENDER_BLOCKED.load(Ordering::Acquire)
}

pub fn snapshot(cx: &App) -> Value {
    let Some(worker) = cx.try_global::<Worker>() else {
        return json!({"status":"not_started","render_circuit_breaker_open":false});
    };
    json!({"status":if worker.shared.render_blocked.load(Ordering::Acquire) {"stalled"} else {"healthy"},
        "progress_token":worker.shared.token.load(Ordering::Acquire),
        "stall_count":worker.shared.stalls.load(Ordering::Acquire),
        "recovery_count":worker.shared.recoveries.load(Ordering::Acquire),
        "render_circuit_breaker_open":worker.shared.render_blocked.load(Ordering::Acquire),
        "diagnostics_directory":worker.directory, "external_sample_supported":cfg!(target_os = "macos"),
        "heartbeat_interval_ms":250,"stall_threshold_ms":2000,"sample_cooldown_ms":60000})
}

pub fn start(cx: &mut App) {
    if cx.try_global::<Worker>().is_some() {
        return;
    }
    let directory = cx
        .global::<crate::workspace::AppData>()
        .root
        .reports_dir()
        .join("hangs");
    let shared = Arc::new(Shared {
        stop: AtomicBool::new(false),
        token: AtomicU64::new(1),
        last_progress_ms: AtomicU64::new(uptime_ms()),
        render_blocked: AtomicBool::new(false),
        stalls: AtomicU64::new(0),
        recoveries: AtomicU64::new(0),
        launch_id: uuid::Uuid::new_v4().to_string(),
    });
    let monitor_shared = shared.clone();
    let monitor_directory = directory.clone();
    let monitor_timer = crate::observability::timer_registry(cx).map(|registry| {
        registry.register(
            "performance.hang_monitor",
            "Independent hang monitor",
            "performance",
            250,
            "thread_timer",
            "chau7-next-hang-monitor",
        )
    });
    let worker = match thread::Builder::new()
        .name("chau7-next-hang-monitor".into())
        .spawn(move || {
            let _timer = monitor_timer;
            monitor(monitor_shared, monitor_directory);
        }) {
        Ok(worker) => worker,
        Err(error) => {
            log::warn!("Hang monitor could not start: {error}");
            return;
        }
    };
    cx.set_global(Worker {
        shared: shared.clone(),
        thread: Some(worker),
        directory,
    });
    let timer = crate::observability::register_timer(
        cx,
        "performance.main_thread_heartbeat",
        "Main thread hang heartbeat",
        "performance",
        250,
    );
    cx.spawn(async move |cx| {
        let _timer = timer;
        loop {
            cx.background_executor().timer(TICK).await;
            if shared.stop.load(Ordering::Acquire) {
                break;
            }
            cx.update(|_| {
                let _callback = chau7_next_core::work_profiler::timer_callback(
                    "performance.main_thread_heartbeat",
                    "callback",
                    chau7_next_core::work_profiler::Queue::Main,
                );
                shared
                    .last_progress_ms
                    .store(uptime_ms(), Ordering::Relaxed);
                shared.token.fetch_add(1, Ordering::Release);
            });
        }
    })
    .detach();
}
/// Signal promptly on the main thread; join the monitor on the quit worker.
pub fn stop(cx: &mut App) -> Option<JoinHandle<()>> {
    cx.try_global::<Worker>()?;
    let worker = cx.global_mut::<Worker>();
    worker.shared.stop.store(true, Ordering::Release);
    RENDER_BLOCKED.store(false, Ordering::Release);
    let handle = worker.thread.take()?;
    handle.thread().unpark();
    Some(handle)
}
fn heartbeat(shared: &Shared) -> Heartbeat {
    Heartbeat {
        schema_version: 1,
        parent_pid: std::process::id(),
        launch_id: shared.launch_id.clone(),
        progress_token: shared.token.load(Ordering::Acquire),
        observed_uptime_ms: shared.last_progress_ms.load(Ordering::Acquire),
    }
}
fn monitor(shared: Arc<Shared>, directory: PathBuf) {
    let path = directory.join("main-thread-heartbeat.json");
    let mut state = Monitor::new(shared.token.load(Ordering::Acquire), uptime(), None);
    let mut last_write = Instant::now()
        .checked_sub(HEARTBEAT_INTERVAL)
        .unwrap_or_else(Instant::now);
    let mut last_written = 0;
    let mut child: Option<Child> = None;
    let mut last_launch: Option<Instant> = None;
    while !shared.stop.load(Ordering::Acquire) {
        let hb = heartbeat(&shared);
        let observation = state.observe(hb.progress_token, uptime(), Policy::default());
        if hb.progress_token != last_written && last_write.elapsed() >= HEARTBEAT_INTERVAL {
            match write_json(&path, &hb) {
                Ok(()) => {
                    last_written = hb.progress_token;
                    last_write = Instant::now();
                }
                Err(error) => {
                    log::warn!("Hang heartbeat write failed: {error}");
                    last_write = Instant::now();
                }
            }
        }
        if observation.entered_stall || observation.recovered {
            let stalled = observation.entered_stall;
            shared.render_blocked.store(stalled, Ordering::Release);
            RENDER_BLOCKED.store(stalled, Ordering::Release);
            if stalled {
                shared.stalls.fetch_add(1, Ordering::Relaxed);
            } else {
                shared.recoveries.fetch_add(1, Ordering::Relaxed);
            }
            let record = json!({"schema_version":1,"timestamp":chrono::Utc::now().to_rfc3339(),
                "kind":"main_thread_hang","phase":observation.phase,"stale_ms":observation.stale_for.as_millis(),
                "render_circuit_breaker_open":stalled,"parent_pid":std::process::id(),"launch_id":shared.launch_id});
            crate::incidents::record(
                chau7_next_core::incidents::Kind::MainThreadHang,
                if stalled {
                    chau7_next_core::incidents::Severity::Warning
                } else {
                    chau7_next_core::incidents::Severity::Info
                },
                if stalled {
                    "Main thread stalled"
                } else {
                    "Main thread recovered"
                },
                std::collections::BTreeMap::from([
                    (
                        "phase".into(),
                        if stalled { "stalled" } else { "healthy" }.into(),
                    ),
                    (
                        "staleMillis".into(),
                        observation.stale_for.as_millis().to_string(),
                    ),
                    ("launchID".into(), shared.launch_id.to_string()),
                    (
                        "diagnosticFile".into(),
                        directory
                            .join("latest-transition.json")
                            .display()
                            .to_string(),
                    ),
                ]),
            );
            if let Err(error) = write_json(&directory.join("latest-transition.json"), &record) {
                log::warn!("Hang breadcrumb write failed: {error}");
            }
            if stalled {
                log::error!("Main thread stalled; terminal paint circuit breaker opened");
            } else {
                log::info!("Main thread recovered; terminal paint circuit breaker closed");
            }
        }
        if let Some(process) = &mut child {
            match process.try_wait() {
                Ok(Some(_)) => child = None,
                Ok(None) => {}
                Err(error) => {
                    log::warn!("Hang watchdog wait failed: {error}");
                    terminate_helper(process);
                    child = None;
                }
            }
        }
        // Healthy ticks never spawn. Retain a live child until it retires itself,
        // so shutdown can reap it and no orphan diagnostics inherit app lifetime.
        #[cfg(target_os = "macos")]
        if observation.phase == Phase::Stalled
            && child.is_none()
            && last_launch.is_none_or(|at| at.elapsed() >= Duration::from_secs(5))
        {
            last_launch = Some(Instant::now());
            match launch_helper(&path, &directory) {
                Ok(process) => child = Some(process),
                Err(error) => log::warn!("Hang watchdog launch failed: {error}"),
            }
        }
        #[cfg(not(target_os = "macos"))]
        let _ = (&mut last_launch, observation.phase);
        thread::park_timeout(TICK);
    }
    let _ = fs::remove_file(&path);
    if let Some(mut process) = child {
        let deadline = Instant::now() + Duration::from_secs(1);
        while process.try_wait().is_ok_and(|status| status.is_none()) && Instant::now() < deadline {
            thread::sleep(Duration::from_millis(25));
        }
        terminate_helper(&mut process);
    }
    shared.render_blocked.store(false, Ordering::Release);
    RENDER_BLOCKED.store(false, Ordering::Release);
    let _ = fs::remove_file(path);
}
#[cfg(target_os = "macos")]
fn launch_helper(path: &Path, directory: &Path) -> io::Result<Child> {
    Command::new(std::env::current_exe()?)
        .args([
            "--hang-watchdog",
            "--parent-pid",
            &std::process::id().to_string(),
            "--heartbeat",
        ])
        .arg(path)
        .arg("--output-directory")
        .arg(directory)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
}
fn terminate_helper(process: &mut Child) {
    let _ = process.kill();
    let _ = process.wait();
}

/// Intercept helper mode before platform, log, import or GUI initialization.
pub fn run_cli_if_requested() -> Option<i32> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let command = match WatchdogCommand::parse(&args) {
        Ok(None) => return None,
        Ok(Some(command)) => command,
        Err(error) => {
            eprintln!("Chau7 Next hang watchdog: {error}");
            return Some(2);
        }
    };
    let expected = DataRoot::from_env().reports_dir().join("hangs");
    if command.parent_pid == std::process::id()
        || command.output_directory != expected
        || command.heartbeat != expected.join("main-thread-heartbeat.json")
    {
        eprintln!("Chau7 Next hang watchdog: invalid diagnostic paths or parent");
        return Some(2);
    }
    #[cfg(target_os = "macos")]
    return Some(run_helper(command));
    #[cfg(not(target_os = "macos"))]
    {
        let _ = command;
        Some(2)
    }
}

#[cfg(target_os = "macos")]
#[derive(Serialize, Deserialize)]
struct Cooldown {
    parent_pid: u32,
    launch_id: String,
    sampled_uptime_ms: u64,
}
#[cfg(target_os = "macos")]
fn run_helper(command: WatchdogCommand) -> i32 {
    let Some(initial) = read_heartbeat(&command.heartbeat, command.parent_pid) else {
        return 2;
    };
    let cooldown_path = command.output_directory.join("last-sample.json");
    let previous = read_bounded(&cooldown_path, MAX_HEARTBEAT)
        .ok()
        .and_then(|bytes| serde_json::from_slice::<Cooldown>(&bytes).ok())
        .filter(|c| {
            c.parent_pid == command.parent_pid
                && c.launch_id == initial.launch_id
                && c.sampled_uptime_ms <= uptime_ms()
        })
        .map(|c| Duration::from_millis(c.sampled_uptime_ms));
    let mut state = Monitor::new(
        initial.progress_token,
        Duration::from_millis(initial.observed_uptime_ms).min(uptime()),
        previous,
    );
    let mut lifetime = Lifetime::new(uptime());
    while parent_alive(command.parent_pid) {
        let Some(hb) = read_heartbeat(&command.heartbeat, command.parent_pid)
            .filter(|h| h.launch_id == initial.launch_id)
        else {
            break;
        };
        let observation = state.observe(hb.progress_token, uptime(), Policy::default());
        if observation.should_sample {
            let cooldown = Cooldown {
                parent_pid: command.parent_pid,
                launch_id: hb.launch_id.clone(),
                sampled_uptime_ms: uptime_ms(),
            };
            // A failed budget write must not create an unbounded helper respawn loop.
            if write_json(&cooldown_path, &cooldown).is_err() {
                return 2;
            }
            capture_sample(&command, &hb, observation.stale_for);
        }
        lifetime.observe(observation.phase == Phase::Healthy, uptime());
        if lifetime.should_exit(parent_alive(command.parent_pid), uptime()) {
            break;
        }
        thread::sleep(TICK);
    }
    0
}
#[cfg(target_os = "macos")]
fn parent_alive(pid: u32) -> bool {
    // SAFETY: signal zero only checks the existence/permission of this valid PID.
    unsafe {
        libc::kill(pid as i32, 0) == 0
            || io::Error::last_os_error().raw_os_error() == Some(libc::EPERM)
    }
}
#[cfg(any(target_os = "macos", test))]
fn read_heartbeat(path: &Path, pid: u32) -> Option<Heartbeat> {
    let hb: Heartbeat = serde_json::from_slice(&read_bounded(path, MAX_HEARTBEAT).ok()?).ok()?;
    (hb.schema_version == 1
        && hb.parent_pid == pid
        && hb.launch_id.len() <= 64
        && !hb.launch_id.is_empty())
    .then_some(hb)
}
#[cfg(any(target_os = "macos", test))]
fn read_bounded(path: &Path, cap: u64) -> io::Result<Vec<u8>> {
    let mut bytes = Vec::new();
    File::open(path)?.take(cap + 1).read_to_end(&mut bytes)?;
    if bytes.len() as u64 > cap {
        return Err(io::Error::other("diagnostic exceeds size bound"));
    }
    Ok(bytes)
}
fn write_json(path: &Path, value: &impl Serialize) -> io::Result<()> {
    let bytes = serde_json::to_vec(value)?;
    if bytes.len() as u64 > MAX_HEARTBEAT {
        return Err(io::Error::other("diagnostic JSON exceeds size bound"));
    }
    fs::create_dir_all(
        path.parent()
            .ok_or_else(|| io::Error::other("missing diagnostic directory"))?,
    )?;
    let pending = path.with_extension(format!("{}-tmp", std::process::id()));
    fs::write(&pending, bytes)?;
    #[cfg(target_os = "windows")]
    if path.exists() {
        fs::remove_file(path)?;
    }
    fs::rename(pending, path)
}
#[cfg(target_os = "macos")]
fn capture_sample(command: &WatchdogCommand, before: &Heartbeat, stale: Duration) {
    let started = uptime();
    let stem = format!(
        "hang-{}-pid-{}",
        chrono::Utc::now().timestamp_millis(),
        command.parent_pid
    );
    let sample_path = command.output_directory.join(format!("{stem}.sample.txt"));
    let mut error = None;
    let mut timed_out = false;
    let mut status = None;
    match Command::new("/usr/bin/sample")
        .args([
            command.parent_pid.to_string(),
            "5".into(),
            "10".into(),
            "-file".into(),
        ])
        .arg(&sample_path)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
    {
        Ok(mut process) => loop {
            match process.try_wait() {
                Ok(Some(exit)) => {
                    status = exit.code();
                    break;
                }
                Ok(None)
                    if started.saturating_add(SAMPLE_TIMEOUT) > uptime()
                        && parent_alive(command.parent_pid)
                        && command.heartbeat.exists() =>
                {
                    thread::sleep(Duration::from_millis(50))
                }
                Ok(None) => {
                    timed_out = true;
                    terminate_helper(&mut process);
                    break;
                }
                Err(e) => {
                    error = Some(e.to_string());
                    terminate_helper(&mut process);
                    break;
                }
            }
        },
        Err(e) => error = Some(e.to_string()),
    }
    let mut truncated = false;
    if let Ok(meta) = fs::metadata(&sample_path)
        && meta.len() > MAX_SAMPLE
    {
        match OpenOptions::new()
            .write(true)
            .open(&sample_path)
            .and_then(|f| f.set_len(MAX_SAMPLE))
        {
            Ok(()) => truncated = true,
            Err(e) => error = Some(e.to_string()),
        }
    }
    let after = read_heartbeat(&command.heartbeat, command.parent_pid)
        .filter(|h| h.launch_id == before.launch_id);
    let completed = uptime();
    let text = File::open(&sample_path)
        .and_then(|file| {
            let mut bytes = Vec::new();
            file.take(StackObservations::MAX_INPUT_BYTES as u64 + 1)
                .read_to_end(&mut bytes)?;
            Ok(bytes)
        })
        .unwrap_or_default();
    let manifest = json!({"schema_version":3,"detected_at":chrono::Utc::now().to_rfc3339(),"parent_pid":command.parent_pid,
        "watchdog_pid":std::process::id(),"stale_milliseconds":stale.as_millis(),"sample_path":sample_path,
        "sample_exit_status":status,"sample_launch_error":error,"sample_timed_out":timed_out,"sample_truncated":truncated,
        "build_sha":crate::platform::system::bundle_string("Chau7NextSourceRevision"),
        "heartbeat_before_capture":before,"heartbeat_after_capture":after,
        "capture_evidence":SampleEvidence::new(Some(before.progress_token),after.as_ref().map(|h| h.progress_token),started,completed),
        "main_thread_stacks":StackObservations::from_sample(&text)});
    if let Err(e) = write_json(
        &command.output_directory.join(format!("{stem}.json")),
        &manifest,
    ) {
        eprintln!("Hang manifest failed: {e}");
    }
    let _ = write_json(
        &command.output_directory.join("latest-hang.json"),
        &manifest,
    );
    prune_diagnostics(&command.output_directory);
}
#[cfg(any(target_os = "macos", test))]
fn prune_diagnostics(directory: &Path) {
    use std::collections::BTreeMap;
    let Ok(entries) = fs::read_dir(directory) else {
        return;
    };
    let mut groups: BTreeMap<String, (Vec<PathBuf>, u64, std::time::SystemTime)> = BTreeMap::new();
    for entry in entries.flatten() {
        let name = entry.file_name();
        let Some(name) = name.to_str() else {
            continue;
        };
        let Some(stem) = name
            .strip_suffix(".sample.txt")
            .or_else(|| name.strip_suffix(".json"))
            .filter(|s| s.starts_with("hang-"))
        else {
            continue;
        };
        let Ok(meta) = fs::symlink_metadata(entry.path()) else {
            continue;
        };
        if !meta.is_file() {
            continue;
        }
        let group = groups
            .entry(stem.into())
            .or_insert_with(|| (Vec::new(), 0, std::time::UNIX_EPOCH));
        group.0.push(entry.path());
        group.1 = group.1.saturating_add(meta.len());
        group.2 = group
            .2
            .max(meta.modified().unwrap_or(std::time::UNIX_EPOCH));
    }
    let mut groups: Vec<_> = groups.into_iter().collect();
    groups.sort_by(|(left_key, left), (right_key, right)| {
        right.2.cmp(&left.2).then_with(|| right_key.cmp(left_key))
    });
    let mut count = 0;
    let mut bytes = 0_u64;
    for (_, (paths, size, modified)) in groups {
        let old = std::time::SystemTime::now()
            .duration_since(modified)
            .is_ok_and(|age| age > Duration::from_secs(7 * 86400));
        if old
            || count >= 40
            || size > MAX_SAMPLE + 64 * 1024
            || bytes.saturating_add(size) > 64 * 1024 * 1024
        {
            for path in paths {
                let _ = fs::remove_file(path);
            }
        } else {
            count += 1;
            bytes += size;
        }
    }
}
#[cfg(unix)]
fn uptime() -> Duration {
    let mut time = std::mem::MaybeUninit::<libc::timespec>::uninit();
    // SAFETY: a valid writable timespec is passed and read only on success.
    if unsafe { libc::clock_gettime(libc::CLOCK_MONOTONIC, time.as_mut_ptr()) } == 0 {
        // SAFETY: clock_gettime initialized the entire structure.
        let time = unsafe { time.assume_init() };
        return Duration::new(
            time.tv_sec.max(0) as u64,
            time.tv_nsec.clamp(0, 999_999_999) as u32,
        );
    }
    Duration::ZERO
}
#[cfg(not(unix))]
fn uptime() -> Duration {
    static START: std::sync::OnceLock<Instant> = std::sync::OnceLock::new();
    START.get_or_init(Instant::now).elapsed()
}
fn uptime_ms() -> u64 {
    uptime().as_millis().min(u64::MAX as u128) as u64
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn monitor_stop_retires_without_launching_on_healthy_start() {
        let directory =
            std::env::temp_dir().join(format!("chau7-next-hang-lifetime-{}", uuid::Uuid::new_v4()));
        let shared = Arc::new(Shared {
            stop: AtomicBool::new(false),
            token: AtomicU64::new(1),
            last_progress_ms: AtomicU64::new(uptime_ms()),
            render_blocked: AtomicBool::new(false),
            stalls: AtomicU64::new(0),
            recoveries: AtomicU64::new(0),
            launch_id: "test".into(),
        });
        let worker_shared = shared.clone();
        let worker_directory = directory.clone();
        let worker = thread::spawn(move || monitor(worker_shared, worker_directory));
        let path = directory.join("main-thread-heartbeat.json");
        let due = Instant::now() + Duration::from_secs(1);
        while !path.exists() && Instant::now() < due {
            thread::sleep(Duration::from_millis(10));
        }
        shared.stop.store(true, Ordering::Release);
        worker.thread().unpark();
        worker.join().unwrap();
        assert_eq!(shared.stalls.load(Ordering::Relaxed), 0);
        assert!(!path.exists());
        if directory.exists() {
            fs::remove_dir_all(directory).unwrap();
        }
    }
    #[test]
    fn bounds_and_identity_are_enforced_on_heartbeat_reads() {
        let dir =
            std::env::temp_dir().join(format!("chau7-next-hang-test-{}", uuid::Uuid::new_v4()));
        let path = dir.join("heartbeat.json");
        let hb = Heartbeat {
            schema_version: 1,
            parent_pid: 42,
            launch_id: "test".into(),
            progress_token: 7,
            observed_uptime_ms: 0,
        };
        write_json(&path, &hb).unwrap();
        assert_eq!(read_heartbeat(&path, 42).unwrap().progress_token, 7);
        assert!(read_heartbeat(&path, 43).is_none());
        fs::write(&path, vec![b' '; MAX_HEARTBEAT as usize + 1]).unwrap();
        assert!(read_heartbeat(&path, 42).is_none());
        fs::remove_dir_all(dir).unwrap();
    }
    #[test]
    fn pruning_never_removes_unrelated_files_or_symlinks() {
        let dir =
            std::env::temp_dir().join(format!("chau7-next-hang-prune-{}", uuid::Uuid::new_v4()));
        fs::create_dir(&dir).unwrap();
        fs::write(dir.join("unrelated.json"), b"keep").unwrap();
        fs::write(dir.join("main-thread-heartbeat.json"), b"keep").unwrap();
        let modified = std::time::SystemTime::now();
        for i in 0..45 {
            for (suffix, text) in [("json", "{}"), ("sample.txt", "sample")] {
                let path = dir.join(format!("hang-{i:02}.{suffix}"));
                fs::write(&path, text).unwrap();
                std::fs::OpenOptions::new()
                    .write(true)
                    .open(path)
                    .unwrap()
                    .set_times(std::fs::FileTimes::new().set_modified(modified))
                    .unwrap();
            }
        }
        prune_diagnostics(&dir);
        assert!(
            dir.join("unrelated.json").exists() && dir.join("main-thread-heartbeat.json").exists()
        );
        assert_eq!(fs::read_dir(&dir).unwrap().count(), 82);
        assert!(!dir.join("hang-04.json").exists());
        assert!(dir.join("hang-05.json").exists());
        assert!(dir.join("hang-44.sample.txt").exists());
        fs::remove_dir_all(dir).unwrap();
    }
}
