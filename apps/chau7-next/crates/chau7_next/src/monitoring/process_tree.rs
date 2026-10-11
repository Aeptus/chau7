//! One native process snapshot shared by all subscribed terminals, off the UI.
//! Matches ProcessTreeSnapshotService's 1.5s cadence and 200/600ms launch bursts.
use crate::{mcp::MainThread, terminal::session::TerminalSession};
use chau7_next_core::monitoring::process_tree::{INTERPRETERS, ProcessRow, Snapshot};
use chau7_next_core::work_profiler::{self, Key, Queue};
use gpui::{App, Context, Global, WeakEntity};
use parking_lot::{Condvar, Mutex};
use std::{
    collections::HashMap,
    sync::Arc,
    time::{Duration, Instant},
};
use uuid::Uuid;

const INTERVAL: Duration = Duration::from_millis(1500);
#[derive(Default)]
struct Schedule {
    immediate: bool,
    periodic: Option<Instant>,
    settle: Vec<Instant>,
}
impl Schedule {
    fn request(&mut self, now: Instant, launch: bool) {
        self.immediate = true;
        self.periodic.get_or_insert(now + INTERVAL);
        if launch {
            self.settle = vec![
                now + Duration::from_millis(200),
                now + Duration::from_millis(600),
            ];
        }
    }
    fn next(&self) -> Option<Instant> {
        self.periodic
            .into_iter()
            .chain(self.settle.iter().copied())
            .min()
    }
    fn due(&mut self, now: Instant) -> bool {
        let due = self.immediate || self.next().is_some_and(|deadline| deadline <= now);
        if due {
            self.immediate = false;
            if self.periodic.is_none_or(|deadline| deadline <= now) {
                self.periodic = Some(now + INTERVAL);
            }
            self.settle.retain(|deadline| *deadline > now);
        }
        due
    }
}
#[derive(Clone)]
struct Subscriber {
    pid: u32,
    session: WeakEntity<TerminalSession>,
}
#[derive(Default)]
struct State {
    stopped: bool,
    subscribers: HashMap<Uuid, Subscriber>,
    schedule: Schedule,
    timer: Option<crate::observability::TimerGuard>,
    projection: Option<Snapshot>,
    projection_queued: bool,
}
#[derive(Default)]
struct Shared {
    state: Mutex<State>,
    changed: Condvar,
}
struct Service(Arc<Shared>);
impl Global for Service {}
impl Drop for Service {
    fn drop(&mut self) {
        let mut state = self.0.state.lock();
        state.stopped = true;
        state.timer.take();
        self.0.changed.notify_one();
    }
}
pub struct Subscription {
    id: Uuid,
    shared: Arc<Shared>,
}
impl Drop for Subscription {
    fn drop(&mut self) {
        let mut state = self.shared.state.lock();
        state.subscribers.remove(&self.id);
        if state.subscribers.is_empty() {
            state.timer.take();
            state.schedule = Schedule::default();
            state.projection.take();
        }
        self.shared.changed.notify_one();
    }
}
pub fn subscribe(
    pid: u32,
    session: WeakEntity<TerminalSession>,
    cx: &mut Context<TerminalSession>,
) -> Subscription {
    if !cx.has_global::<Service>() {
        let shared = Arc::new(Shared::default());
        let worker = shared.clone();
        let main = MainThread::start(cx);
        std::thread::Builder::new()
            .name("chau7-next-process-tree".into())
            .spawn(move || run(worker, main))
            .expect("process snapshot worker");
        cx.set_global(Service(shared));
    }
    let shared = cx.global::<Service>().0.clone();
    let id = Uuid::new_v4();
    {
        let mut state = shared.state.lock();
        if state.subscribers.is_empty() && crate::observability::timer_registry(cx).is_some() {
            state.timer = Some(crate::observability::register_background_timer(
                cx,
                "monitor.process_tree",
                "Shared native process tree",
                "monitoring",
                1500,
            ));
        }
        state.subscribers.insert(id, Subscriber { pid, session });
        state.schedule.request(Instant::now(), false);
    }
    shared.changed.notify_one();
    Subscription { id, shared }
}
pub fn refresh(cx: &App, launch: bool) {
    let Some(service) = cx.try_global::<Service>() else {
        return;
    };
    let mut state = service.0.state.lock();
    if !state.stopped && !state.subscribers.is_empty() {
        state.schedule.request(Instant::now(), launch);
        service.0.changed.notify_one();
    }
}
pub fn stop(cx: &mut App) {
    if !cx.has_global::<Service>() {
        return;
    }
    let service = cx.remove_global::<Service>();
    let mut state = service.0.state.lock();
    state.stopped = true;
    state.timer.take();
    state.projection.take();
    state.subscribers.clear();
    service.0.changed.notify_one();
}
fn run(shared: Arc<Shared>, main: MainThread) {
    loop {
        {
            let mut state = shared.state.lock();
            loop {
                if state.stopped {
                    return;
                }
                if state.subscribers.is_empty() {
                    shared.changed.wait(&mut state);
                } else {
                    let now = Instant::now();
                    if state.schedule.due(now) {
                        break;
                    }
                    let wait = state
                        .schedule
                        .next()
                        .unwrap_or(now + INTERVAL)
                        .saturating_duration_since(now);
                    shared.changed.wait_for(&mut state, wait);
                }
            }
        }
        let snapshot = work_profiler::measure(
            Key::work(
                "process_tree_capture",
                "capture",
                "subscribed",
                "shared_process_tree",
                Queue::Background,
            ),
            || capture(&shared),
        );
        let Some(snapshot) = snapshot else {
            continue;
        };
        let mut state = shared.state.lock();
        if state.stopped || state.subscribers.is_empty() {
            continue;
        }
        state.projection = Some(snapshot);
        if state.projection_queued {
            continue;
        }
        state.projection_queued = true;
        drop(state);
        let projection = shared.clone();
        if !main.dispatch(move |cx| {
            let (snapshot, subscribers) = {
                let mut state = projection.state.lock();
                state.projection_queued = false;
                if state.stopped {
                    return;
                }
                let Some(snapshot) = state.projection.take() else {
                    return;
                };
                (snapshot, state.subscribers.clone())
            };
            for (id, subscriber) in subscribers {
                // A queued projection must not resurrect an unsubscribed session.
                if !projection.state.lock().subscribers.contains_key(&id) {
                    continue;
                }
                let provider = snapshot.resolve(subscriber.pid);
                let _ = subscriber.session.update(cx, |session, cx| {
                    session.apply_live_process_snapshot(provider, cx);
                });
            }
        }) {
            return;
        }
    }
}
fn capture(shared: &Shared) -> Option<Snapshot> {
    if let Some(rows) = native_rows()
        && !rows.is_empty()
    {
        return Some(Snapshot::from_rows(rows));
    }
    // Native enumeration can be unavailable. One bounded process, never one per tab.
    #[cfg(unix)]
    {
        let result = chau7_next_core::subprocess::capture_unless(
            std::process::Command::new("/bin/ps").args(["-axo", "pid,ppid,args"]),
            Duration::from_secs(5),
            4 * 1024 * 1024,
            || shared.state.lock().stopped,
        )
        .ok()?;
        if result.completed() && result.status == Some(0) {
            let snapshot = Snapshot::parse(std::str::from_utf8(&result.stdout).ok()?);
            return (!snapshot.rows.is_empty()).then_some(snapshot);
        }
    }
    #[cfg(not(unix))]
    let _ = shared;
    None
}
fn row(pid: u32, parent_pid: u32, command: String) -> ProcessRow {
    let argv = if INTERPRETERS.contains(&command.to_ascii_lowercase().as_str()) {
        crate::platform::process::process_args_env(pid)
            .map(|(args, _)| args)
            .unwrap_or_default()
    } else {
        Vec::new()
    };
    ProcessRow {
        pid,
        parent_pid,
        command,
        argv,
    }
}
#[cfg(target_os = "macos")]
fn native_rows() -> Option<Vec<ProcessRow>> {
    let count = unsafe { libc::proc_listallpids(std::ptr::null_mut(), 0) };
    if count <= 0 {
        return None;
    }
    let mut pids = vec![0_i32; (count as usize + 256).min(65536)];
    let bytes = (pids.len() * std::mem::size_of::<i32>()) as i32;
    // SAFETY: both native calls receive their actual writable buffer size.
    let written = unsafe { libc::proc_listallpids(pids.as_mut_ptr().cast(), bytes) };
    if written <= 0 || written as usize >= pids.len() {
        return None;
    }
    let mut rows = Vec::with_capacity(written as usize);
    for &pid in &pids[..written as usize] {
        if pid <= 0 {
            continue;
        }
        let mut info = std::mem::MaybeUninit::<libc::proc_bsdshortinfo>::zeroed();
        let size = std::mem::size_of::<libc::proc_bsdshortinfo>() as i32;
        let result = unsafe {
            libc::proc_pidinfo(
                pid,
                libc::PROC_PIDT_SHORTBSDINFO,
                0,
                info.as_mut_ptr().cast(),
                size,
            )
        };
        if result != size {
            continue;
        }
        let info = unsafe { info.assume_init() };
        // Fixed comm buffer can be entirely filled: no unbounded CStr scan.
        let bytes: Vec<_> = info
            .pbsi_comm
            .iter()
            .take_while(|c| **c != 0)
            .map(|c| *c as u8)
            .collect();
        let command = String::from_utf8_lossy(&bytes).into_owned();
        rows.push(row(pid as u32, info.pbsi_ppid, command));
    }
    Some(rows)
}
#[cfg(target_os = "linux")]
fn native_rows() -> Option<Vec<ProcessRow>> {
    let mut rows = Vec::new();
    for entry in std::fs::read_dir("/proc").ok()?.flatten().take(65536) {
        let Some(pid) = entry.file_name().to_str().and_then(|s| s.parse().ok()) else {
            continue;
        };
        let Ok(stat) = std::fs::read_to_string(entry.path().join("stat")) else {
            continue;
        };
        let Some(start) = stat.find('(') else {
            continue;
        };
        let Some(end) = stat.rfind(')') else { continue };
        let Some(parent) = stat[end + 1..]
            .split_whitespace()
            .nth(1)
            .and_then(|s| s.parse().ok())
        else {
            continue;
        };
        rows.push(row(pid, parent, stat[start + 1..end].to_string()));
    }
    Some(rows)
}
#[cfg(windows)]
fn native_rows() -> Option<Vec<ProcessRow>> {
    use std::ffi::c_void;
    #[repr(C)]
    struct Entry {
        size: u32,
        usage: u32,
        pid: u32,
        heap: usize,
        module: u32,
        threads: u32,
        parent: u32,
        priority: i32,
        flags: u32,
        executable: [u16; 260],
    }
    #[link(name = "kernel32")]
    unsafe extern "system" {
        fn CreateToolhelp32Snapshot(flags: u32, pid: u32) -> *mut c_void;
        fn Process32FirstW(handle: *mut c_void, entry: *mut Entry) -> i32;
        fn Process32NextW(handle: *mut c_void, entry: *mut Entry) -> i32;
        fn CloseHandle(handle: *mut c_void) -> i32;
    }
    // SAFETY: PROCESSENTRY32W layout and dwSize match Windows ABI; handle owned here.
    unsafe {
        let handle = CreateToolhelp32Snapshot(2, 0);
        if handle as isize == -1 {
            return None;
        }
        let mut entry: Entry = std::mem::zeroed();
        entry.size = std::mem::size_of::<Entry>() as u32;
        let mut success = Process32FirstW(handle, &mut entry);
        let mut rows = Vec::new();
        while success != 0 && rows.len() < 65536 {
            let end = entry.executable.iter().position(|c| *c == 0).unwrap_or(260);
            rows.push(row(
                entry.pid,
                entry.parent,
                String::from_utf16_lossy(&entry.executable[..end]),
            ));
            success = Process32NextW(handle, &mut entry);
        }
        CloseHandle(handle);
        (!rows.is_empty()).then_some(rows)
    }
}
#[cfg(not(any(target_os = "macos", target_os = "linux", windows)))]
fn native_rows() -> Option<Vec<ProcessRow>> {
    None
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn launches_coalesce_and_keep_only_two_settle_deadlines() {
        let now = Instant::now();
        let mut schedule = Schedule::default();
        for _ in 0..100 {
            schedule.request(now, true);
        }
        assert_eq!(schedule.settle.len(), 2);
        assert!(schedule.due(now));
        assert!(!schedule.due(now));
        assert!(schedule.due(now + Duration::from_millis(200)));
        assert!(!schedule.due(now + Duration::from_millis(201)));
        assert!(schedule.due(now + Duration::from_millis(600)));
        assert!(schedule.due(now + INTERVAL));
    }
    #[test]
    fn idle_has_no_deadline_and_teardown_drops_projection() {
        let mut state = State::default();
        assert_eq!(state.schedule.next(), None);
        state.schedule.request(Instant::now(), true);
        state.projection = Some(Snapshot::default());
        state.schedule = Schedule::default();
        state.projection.take();
        assert_eq!(state.schedule.next(), None);
        assert!(state.projection.is_none());
    }
    #[test]
    fn unsubscribed_worker_stays_idle_and_teardown_wakes_it() {
        let shared = Arc::new(Shared::default());
        let worker = shared.clone();
        let (jobs, mut rx) = futures::channel::mpsc::unbounded();
        let main = MainThread::for_tests(jobs);
        let (finished, completed) = std::sync::mpsc::channel();
        let thread = std::thread::spawn(move || {
            run(worker, main);
            finished.send(()).unwrap();
        });
        std::thread::sleep(Duration::from_millis(30));
        assert!(rx.try_recv().is_err());
        assert!(shared.state.lock().projection.is_none());
        drop(Service(shared));
        completed
            .recv_timeout(Duration::from_secs(1))
            .expect("idle worker cancelled");
        thread.join().unwrap();
    }

    #[cfg(unix)]
    #[test]
    fn native_snapshot_contains_owned_child_and_its_parent() {
        let mut child = std::process::Command::new("/bin/sleep")
            .arg("2")
            .spawn()
            .unwrap();
        let rows = native_rows().expect("native process list");
        let observed = rows
            .iter()
            .find(|row| row.pid == child.id())
            .map(|row| row.parent_pid);
        let _ = child.kill();
        let _ = child.wait();
        assert_eq!(observed, Some(std::process::id()));
    }
}
