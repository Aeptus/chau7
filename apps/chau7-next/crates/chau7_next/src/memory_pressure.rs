//! Current Swift memory lifecycle: weak registrations, serial disk operations,
//! selected-surface protection and verified history before ring reduction.
use crate::workspace::AppData;
use chau7_next_core::{
    memory_pressure::{
        self as policy, FlushKind, FlushRecord, PressureLevel, PressureState, RenderPhase,
    },
    scrollback_cache::{self, ContentKind},
};
use chau7_terminal::Chau7Terminal;
use gpui::{App, Global, Task};
use parking_lot::{Mutex, RwLock};
use serde_json::{Value, json};
use std::{
    collections::{HashMap, HashSet},
    path::PathBuf,
    sync::{
        Arc, Weak,
        atomic::{AtomicBool, Ordering},
        mpsc,
    },
    time::{Duration, Instant},
};

#[derive(Default)]
struct Metrics {
    flushes: u64,
    reloads: u64,
    failures: u64,
    reclaimed_bytes: u64,
    last_error: Option<String>,
}
struct State {
    phase: RenderPhase,
    configured: usize,
    flushed: Option<FlushRecord>,
    idle_counter: u64,
    idle_since: Instant,
    queued: bool,
    retry_after: Option<Instant>,
    force_pending: bool,
}
pub(crate) struct SessionMemory {
    pub id: u64,
    terminal: Weak<RwLock<Chau7Terminal>>,
    cache: PathBuf,
    state: Mutex<State>,
    tui: AtomicBool,
    metrics: Mutex<Metrics>,
    refresh_needed: AtomicBool,
    restore_preview: Mutex<Option<String>>,
}
static REGISTRY: Mutex<Vec<Weak<SessionMemory>>> = Mutex::new(Vec::new());
struct Service {
    sender: mpsc::Sender<Arc<SessionMemory>>,
    pressure: Arc<Mutex<PressureState>>,
    epoch: Instant,
    stop: Arc<AtomicBool>,
    _task: Task<()>,
    _native: native::Source,
    views: Vec<gpui::WeakEntity<crate::terminal::view::TerminalView>>,
    reclaimed_cache_bytes: u64,
    last_critical_reclaim: Option<Instant>,
}
impl Global for Service {}
impl Drop for Service {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Release);
    }
}

pub(crate) fn register(
    id: u64,
    terminal: &Arc<RwLock<Chau7Terminal>>,
    root: &chau7_next_core::data_root::DataRoot,
    lines: usize,
) -> Arc<SessionMemory> {
    let memory = Arc::new(SessionMemory {
        id,
        terminal: Arc::downgrade(terminal),
        cache: root
            .state_dir()
            .join("scrollback-cache")
            .join(format!("{}.gz", uuid::Uuid::new_v4())),
        state: Mutex::new(State {
            phase: RenderPhase::Active,
            configured: policy::configured_lines(lines),
            flushed: None,
            idle_counter: 0,
            idle_since: Instant::now(),
            queued: false,
            retry_after: None,
            force_pending: false,
        }),
        tui: AtomicBool::new(false),
        metrics: Mutex::new(Metrics::default()),
        refresh_needed: AtomicBool::new(false),
        restore_preview: Mutex::new(None),
    });
    REGISTRY.lock().push(Arc::downgrade(&memory));
    memory
}
impl SessionMemory {
    pub fn activate(self: &Arc<Self>, cx: &App) {
        let mut state = self.state.lock();
        state.phase = RenderPhase::Active;
        state.retry_after = None;
        if state.flushed.is_some()
            && !state.queued
            && let Some(service) = cx.try_global::<Service>()
        {
            state.queued = true;
            let _ = service.sender.send(self.clone());
        }
    }
    pub fn take_refresh(&self) -> bool {
        self.refresh_needed.swap(false, Ordering::AcqRel)
    }
    pub fn configure(&self, lines: usize) {
        self.state.lock().configured = policy::configured_lines(lines);
    }
    pub fn set_tui(&self, tui: bool) {
        self.tui.store(tui, Ordering::Relaxed);
    }
    pub fn capacity(&self) -> usize {
        let state = self.state.lock();
        if let Some(record) = state.flushed {
            if record.kind == FlushKind::TuiCompact {
                policy::TUI_TIER_LINES
            } else {
                policy::HIDDEN_FLOOR_LINES
            }
        } else {
            state.configured
        }
    }
    /// Autosave must include disk-retained history while a ring is compacted.
    pub fn styled_for_restore(&self) -> Option<String> {
        let term = self.terminal.upgrade()?;
        let flushed = self.state.lock().flushed;
        let term = term.read();
        let tail = term.full_buffer_ansi_text();
        let Some(record) = flushed else {
            return Some(tail);
        };
        // This bounded preview is prepared on the worker before trimming.
        // Autosave never reads or inflates cache files on the main thread.
        let mut text = self.restore_preview.lock().clone()?;
        if record.output_arrived(Some(term.stats().1)) {
            let mut bytes = text.into_bytes();
            append_tail(&mut bytes, &tail);
            text = String::from_utf8(bytes).ok()?;
        }
        Some(text)
    }
    fn fail(&self, error: std::io::Error) {
        self.state.lock().retry_after = Some(Instant::now() + Duration::from_secs(30));
        let mut metrics = self.metrics.lock();
        metrics.failures += 1;
        metrics.last_error = Some(error.to_string());
        log::warn!("scrollback retention {}: {}", self.id, error);
    }
    /// The shared serial worker does all compression and disk I/O without a
    /// terminal lock. After persistence, a counter check under the parser lock
    /// aborts trimming if output arrived during the transaction.
    fn maintain(&self) {
        self.maintain_inner(|| {});
        self.state.lock().queued = false;
    }
    fn maintain_inner(&self, after_persist: impl FnOnce()) {
        let Some(terminal) = self.terminal.upgrade() else {
            return;
        };
        let (phase, configured, record, idle, armed, force) = {
            let s = self.state.lock();
            (
                s.phase,
                s.configured,
                s.flushed,
                s.idle_since.elapsed(),
                s.idle_counter,
                s.force_pending,
            )
        };
        let tui = self.tui.load(Ordering::Relaxed) || terminal.read().is_alternate_screen_active();
        if phase.visible() {
            if let Some(record) = record {
                if tui {
                    return;
                }
                // Decode outside the parser lock and outside the UI thread.
                match scrollback_cache::load(&self.cache) {
                    Ok(cache) => {
                        let mut bytes = cache.replay_data();
                        let term = terminal.write();
                        if !self.state.lock().phase.visible() || term.is_alternate_screen_active() {
                            return;
                        }
                        if record.output_arrived(Some(term.stats().1)) {
                            append_tail(&mut bytes, &term.full_buffer_ansi_text());
                        }
                        term.set_scrollback_size(configured);
                        term.replay_buffer(&bytes);
                        self.state.lock().flushed = None;
                        *self.restore_preview.lock() = None;
                        self.metrics.lock().reloads += 1;
                        self.refresh_needed.store(true, Ordering::Release);
                        drop(term);
                        let _ = std::fs::remove_file(&self.cache);
                    }
                    Err(error) => self.fail(error),
                }
            } else {
                terminal.read().set_scrollback_size(configured);
            }
            return;
        }
        if record.is_some() {
            return;
        }
        let due = phase == RenderPhase::Hidden
            || idle
                >= if tui {
                    policy::TUI_IDLE_DELAY
                } else {
                    policy::WARM_IDLE_DELAY
                };
        if !due || phase == RenderPhase::Hidden && tui {
            return;
        }
        let kind = if tui {
            FlushKind::TuiCompact
        } else if phase == RenderPhase::Hidden {
            FlushKind::Hidden
        } else {
            FlushKind::Idle
        };
        let (bytes, counter, before) = {
            let term = terminal.write();
            if phase != RenderPhase::Hidden && !force && term.stats().1 != armed {
                return;
            }
            let before = term.debug_state().estimated_grid_bytes;
            if term.is_alternate_screen_active() {
                term.set_scrollback_size(policy::TUI_TIER_LINES);
                self.metrics.lock().reclaimed_bytes +=
                    before.saturating_sub(term.debug_state().estimated_grid_bytes);
                return;
            }
            (term.full_buffer_ansi_text(), term.stats().1, before)
        };
        // Durable verification must succeed before touching retained grid history.
        if let Err(error) =
            scrollback_cache::persist_verified(&self.cache, bytes.as_bytes(), ContentKind::Ansi)
        {
            self.fail(error);
            return;
        }
        after_persist();
        let preview = chau7_next_core::session_restore::capture_scrollback(
            &bytes,
            chau7_next_core::session_restore::MAX_RESTORED_SCROLLBACK_LINES,
        );
        let term = terminal.write();
        // An active promotion or output during disk I/O cancels the trim. The live
        // ring still owns the complete history and the unused file is overwritten
        // on the next attempt. No parser bytes can race this check and reduction.
        let mut state = self.state.lock();
        if state.phase.visible() || term.stats().1 != counter || term.is_alternate_screen_active() {
            return;
        }
        term.set_scrollback_size(if tui {
            policy::TUI_TIER_LINES
        } else {
            policy::HIDDEN_FLOOR_LINES
        });
        *self.restore_preview.lock() = preview;
        state.flushed = Some(FlushRecord {
            kind,
            bytes_received: Some(counter),
        });
        state.retry_after = None;
        state.force_pending = false;
        drop(state);
        let mut metrics = self.metrics.lock();
        metrics.flushes += 1;
        metrics.reclaimed_bytes += before.saturating_sub(term.debug_state().estimated_grid_bytes);
    }
}

/// Reconcile an overlapping retained tail in linear time. If the boundary
/// cannot be established, keep both pieces, matching Swift's lossless fallback.
fn append_tail(cached: &mut Vec<u8>, tail: &str) {
    let Ok(previous) = std::str::from_utf8(cached) else {
        cached.extend_from_slice(b"\x1b[0m\r\n");
        cached.extend_from_slice(tail.as_bytes());
        return;
    };
    let mut old: Vec<&str> = previous.split_inclusive('\n').collect();
    let mut new: Vec<&str> = tail.split_inclusive('\n').collect();
    let visible = |line: &str| {
        chau7_next_core::session_restore::visible_for_restore(line)
            .trim_end()
            .to_string()
    };
    while old.last().is_some_and(|line| visible(line).is_empty()) {
        old.pop();
    }
    while new.last().is_some_and(|line| visible(line).is_empty()) {
        new.pop();
    }
    let pattern: Vec<String> = new.iter().map(|line| visible(line)).collect();
    let mut matched = 0;
    if !pattern.is_empty() {
        let mut prefix = vec![0; pattern.len()];
        for i in 1..pattern.len() {
            let mut j = prefix[i - 1];
            while j > 0 && pattern[i] != pattern[j] {
                j = prefix[j - 1];
            }
            if pattern[i] == pattern[j] {
                j += 1;
            }
            prefix[i] = j;
        }
        for line in &old {
            let line = visible(line);
            while matched > 0 && (matched == pattern.len() || line != pattern[matched]) {
                matched = prefix[matched - 1];
            }
            if line == pattern[matched] {
                matched += 1;
            }
        }
    }
    if matched > 0 {
        let boundary = old[..old.len() - matched]
            .iter()
            .map(|line| line.len())
            .sum::<usize>();
        cached.truncate(boundary);
        cached.extend_from_slice(b"\x1b[0m");
    } else {
        cached.extend_from_slice(b"\x1b[0m\r\n");
    }
    cached.extend_from_slice(tail.as_bytes());
}

pub fn start(cx: &mut App) {
    if cx.try_global::<Service>().is_some() {
        return;
    }
    let (sender, receiver) = mpsc::channel::<Arc<SessionMemory>>();
    let stop = Arc::new(AtomicBool::new(false));
    let worker_stop = stop.clone();
    std::thread::Builder::new()
        .name("next-scrollback-retention".into())
        .spawn(move || {
            while !worker_stop.load(Ordering::Acquire) {
                match receiver.recv_timeout(Duration::from_secs(1)) {
                    Ok(memory) => memory.maintain(),
                    Err(mpsc::RecvTimeoutError::Timeout) => {}
                    Err(mpsc::RecvTimeoutError::Disconnected) => break,
                }
            }
        })
        .expect("scrollback retention worker");
    let pressure = Arc::new(Mutex::new(PressureState::default()));
    let epoch = Instant::now();
    let native = native::Source::new(pressure.clone(), epoch);
    let timer = crate::observability::register_timer(
        cx,
        "memory-lifecycle",
        "Terminal memory lifecycle",
        "memory",
        1000,
    );
    let task_stop = stop.clone();
    let task = cx.spawn(async move |cx| {
        let _timer = timer;
        while !task_stop.load(Ordering::Acquire) {
            cx.background_executor().timer(Duration::from_secs(1)).await;
            cx.update(tick);
        }
    });
    cx.set_global(Service {
        sender,
        pressure,
        epoch,
        stop,
        _task: task,
        _native: native,
        views: Vec::new(),
        reclaimed_cache_bytes: 0,
        last_critical_reclaim: None,
    });
}
pub(crate) fn register_view(
    view: gpui::WeakEntity<crate::terminal::view::TerminalView>,
    cx: &mut App,
) {
    if cx.try_global::<Service>().is_some() {
        cx.global_mut::<Service>().views.push(view);
    }
}
pub fn stop(cx: &mut App) {
    if cx.try_global::<Service>().is_some() {
        drop(cx.remove_global::<Service>());
    }
}
fn selected(cx: &mut App) -> HashMap<u64, bool> {
    let mut selected = HashMap::new();
    for (handle, workspace) in AppData::live(cx) {
        let visible = handle
            .update(cx, |_, window, _| window.is_visible())
            .unwrap_or(false);
        if let Some(panes) = workspace.read(cx).selected_panes() {
            let sessions = panes.read(cx).pane_sessions(cx);
            for (_, session) in sessions {
                selected.insert(session.read(cx).id, visible);
                if session.read(cx).take_memory_refresh() {
                    session.update(cx, |session, cx| session.refresh(cx));
                }
            }
        }
    }
    for parked in &cx.global::<AppData>().hidden {
        if let Some((_, panes)) = parked.tabs.get(parked.selected) {
            for (_, session) in panes.read(cx).pane_sessions(cx) {
                selected.insert(session.read(cx).id, false);
            }
        }
    }
    selected
}
fn tick(cx: &mut App) {
    let selected = selected(cx);
    let visible: HashSet<u64> = selected
        .iter()
        .filter_map(|(id, visible)| visible.then_some(*id))
        .collect();
    let Some(service) = cx.try_global::<Service>() else {
        return;
    };
    let now = service.epoch.elapsed();
    if now.as_secs() % 30 == 0
        && let Some((used, physical)) = native::footprint()
    {
        service.pressure.lock().check_footprint(used, physical, now);
    }
    let pressure = service.pressure.lock().is_under_pressure(now);
    let sender = service.sender.clone();
    reclaim_caches(&visible, pressure, cx);
    let memories = {
        let mut registry = REGISTRY.lock();
        registry.retain(|weak| weak.strong_count() > 0);
        registry
            .iter()
            .filter_map(Weak::upgrade)
            .collect::<Vec<_>>()
    };
    let sizes: Vec<u64> = memories
        .iter()
        .map(|memory| {
            if visible.contains(&memory.id) || memory.tui.load(Ordering::Relaxed) {
                return 0;
            }
            memory
                .terminal
                .upgrade()
                .and_then(|term| {
                    term.try_read().map(|term| {
                        if term.is_alternate_screen_active() {
                            0
                        } else {
                            term.debug_state().estimated_grid_bytes
                        }
                    })
                })
                .unwrap_or(0)
        })
        .collect();
    let forced: HashSet<usize> =
        policy::eviction_indices(&sizes, &HashSet::new(), policy::WARM_SCROLLBACK_BYTES)
            .into_iter()
            .collect();
    for (index, memory) in memories.iter().enumerate() {
        let Some(term) = memory.terminal.upgrade() else {
            continue;
        };
        // try_read avoids waiting on compression/disk transactions on the UI thread.
        let Some(term) = term.try_read() else {
            continue;
        };
        let counter = term.stats().1;
        let bytes = term.debug_state().estimated_grid_bytes;
        let mut state = memory.state.lock();
        let old = state.phase;
        state.phase = policy::render_phase(
            selected.contains_key(&memory.id),
            selected.get(&memory.id).copied().unwrap_or(false),
            pressure,
        );
        if counter != state.idle_counter {
            state.idle_counter = counter;
            state.idle_since = Instant::now();
        }
        let backstop = !state.phase.visible()
            && !memory.tui.load(Ordering::Relaxed)
            && !term.is_alternate_screen_active()
            && (bytes > policy::PER_TAB_SCROLLBACK_BYTES || forced.contains(&index));
        if backstop {
            state.idle_since = Instant::now() - policy::TUI_IDLE_DELAY;
            state.force_pending = true;
        }
        let due = state.phase == RenderPhase::Hidden && state.flushed.is_none()
            || old != state.phase
            || state.flushed.is_some() && state.phase.visible()
            || !state.phase.visible()
                && (backstop || state.idle_since.elapsed() >= policy::WARM_IDLE_DELAY);
        if old != state.phase && state.phase.visible() {
            state.retry_after = None;
        }
        if due && !state.queued && state.retry_after.is_none_or(|at| Instant::now() >= at) {
            state.queued = true;
            let _ = sender.send(memory.clone());
        }
    }
}
fn reclaim_caches(selected: &HashSet<u64>, pressure: bool, cx: &mut App) {
    let (views, critical) = {
        let service = cx.global::<Service>();
        (
            service
                .views
                .iter()
                .filter_map(gpui::WeakEntity::upgrade)
                .collect::<Vec<_>>(),
            service
                .pressure
                .lock()
                .should_shed_best_effort(service.epoch.elapsed())
                && service
                    .last_critical_reclaim
                    .is_none_or(|at| at.elapsed() >= Duration::from_secs(30)),
        )
    };
    let bytes: Vec<u64> = views
        .iter()
        .map(|view| view.read(cx).overlays.cache_bytes())
        .collect();
    let protected: HashSet<usize> = views
        .iter()
        .enumerate()
        .filter_map(|(index, view)| {
            selected
                .contains(&view.read(cx).memory_session_id(cx))
                .then_some(index)
        })
        .collect();
    let mut evict: HashSet<usize> =
        policy::eviction_indices(&bytes, &protected, policy::GLOBAL_CACHE_BYTES)
            .into_iter()
            .collect();
    for (index, size) in bytes.iter().enumerate() {
        if critical
            || !protected.contains(&index) && (pressure || *size > policy::PER_TAB_CACHE_BYTES)
        {
            evict.insert(index);
        }
    }
    let mut reclaimed = 0u64;
    for index in evict {
        reclaimed += views[index].update(cx, |view, cx| view.overlays.reclaim_cache(cx));
    }
    if critical {
        reclaimed += crate::terminal::paint::release_glyph_cache(cx);
    }
    let service = cx.global_mut::<Service>();
    service.views.retain(|view| view.upgrade().is_some());
    service.reclaimed_cache_bytes += reclaimed;
    if critical {
        service.last_critical_reclaim = Some(Instant::now());
    }
}
pub fn diagnostics(cx: &App) -> Value {
    let Some(service) = cx.try_global::<Service>() else {
        return json!({"available":false});
    };
    let mut sessions = Vec::new();
    for memory in REGISTRY.lock().iter().filter_map(Weak::upgrade) {
        let state = memory.state.lock();
        let metrics = memory.metrics.lock();
        sessions.push(json!({"session_id":memory.id,"phase":state.phase,"retained_on_disk":state.flushed.is_some(),"configured_lines":state.configured,"flushes":metrics.flushes,"reloads":metrics.reloads,"failures":metrics.failures,"reclaimed_grid_bytes":metrics.reclaimed_bytes,"last_error":metrics.last_error}));
    }
    let renderers:Vec<Value>=service.views.iter().filter_map(gpui::WeakEntity::upgrade).map(|view|json!({"session_id":view.read(cx).memory_session_id(cx),"renderer":view.read(cx).overlays.renderer_diagnostics()})).collect();
    json!({"configured_renderer":if crate::settings::Settings::get(cx).appearance.rendering.gpu_renderer {"gpu"}else{"cpu"},"renderer_samples":renderers,"cpu_glyph_cache_bytes":crate::terminal::paint::glyph_cache_bytes(cx),"regenerable_cache_scope":"CPU terminal bitmap and glyph pixels","available":true,"native_pressure_source":service._native.available(),"under_pressure":service.pressure.lock().is_under_pressure(service.epoch.elapsed()),"shed_best_effort":service.pressure.lock().should_shed_best_effort(service.epoch.elapsed()),"regenerable_cache_bytes_released": service.reclaimed_cache_bytes,"sessions":sessions})
}

#[cfg(target_os = "macos")]
mod native {
    use super::*;
    use std::ffi::c_void;
    unsafe extern "C" {
        static _dispatch_source_type_memorypressure: u8;
        fn dispatch_get_global_queue(priority: isize, flags: usize) -> *mut c_void;
        fn dispatch_source_create(
            kind: *const c_void,
            handle: usize,
            mask: usize,
            queue: *mut c_void,
        ) -> *mut c_void;
        fn dispatch_set_context(object: *mut c_void, context: *mut c_void);
        fn dispatch_source_set_event_handler_f(
            source: *mut c_void,
            handler: unsafe extern "C" fn(*mut c_void),
        );
        fn dispatch_source_set_cancel_handler_f(
            source: *mut c_void,
            handler: unsafe extern "C" fn(*mut c_void),
        );
        fn dispatch_source_get_data(source: *mut c_void) -> usize;
        fn dispatch_resume(object: *mut c_void);
        fn dispatch_source_cancel(source: *mut c_void);
        fn dispatch_release(object: *mut c_void);
        static mach_task_self_: u32;
        fn task_info(task: u32, flavor: u32, info: *mut u32, count: *mut u32) -> i32;
    }
    struct Handler {
        source: *mut c_void,
        pressure: Arc<Mutex<PressureState>>,
        epoch: Instant,
    }
    unsafe extern "C" fn event(context: *mut c_void) {
        let context = unsafe { &*(context as *const Handler) };
        let flags = unsafe { dispatch_source_get_data(context.source) };
        let level = if flags & 4 != 0 {
            PressureLevel::Critical
        } else {
            PressureLevel::Warning
        };
        context
            .pressure
            .lock()
            .record(level, context.epoch.elapsed());
    }
    unsafe extern "C" fn cancelled(context: *mut c_void) {
        drop(unsafe { Box::from_raw(context as *mut Handler) });
    }
    pub struct Source(*mut c_void);
    impl Source {
        pub fn new(pressure: Arc<Mutex<PressureState>>, epoch: Instant) -> Self {
            // The context lives until dispatch invokes its cancellation callback;
            // cancellation serializes against the event callback on this queue.
            unsafe {
                let source = dispatch_source_create(
                    (&raw const _dispatch_source_type_memorypressure).cast(),
                    0,
                    2 | 4,
                    dispatch_get_global_queue(0x11, 0),
                );
                if !source.is_null() {
                    let context = Box::into_raw(Box::new(Handler {
                        source,
                        pressure,
                        epoch,
                    }));
                    dispatch_set_context(source, context.cast());
                    dispatch_source_set_event_handler_f(source, event);
                    dispatch_source_set_cancel_handler_f(source, cancelled);
                    dispatch_resume(source);
                }
                Self(source)
            }
        }
        pub fn available(&self) -> bool {
            !self.0.is_null()
        }
    }
    impl Drop for Source {
        fn drop(&mut self) {
            if !self.0.is_null() {
                unsafe {
                    dispatch_source_cancel(self.0);
                    dispatch_release(self.0);
                }
            }
        }
    }
    pub fn footprint() -> Option<(u64, u64)> {
        // TASK_VM_INFO rev1 is 19 u64 words, with phys_footprint at word18.
        // A generous native buffer supports current kernels without ABI overrun.
        let mut info = [0u64; 128];
        let mut count = 256u32;
        if unsafe { task_info(mach_task_self_, 22, info.as_mut_ptr().cast(), &mut count) } != 0
            || count < 38
        {
            return None;
        }
        let mut physical = 0u64;
        let mut size = 8usize;
        if unsafe {
            libc::sysctlbyname(
                c"hw.memsize".as_ptr(),
                (&mut physical as *mut u64).cast(),
                &mut size,
                std::ptr::null_mut(),
                0,
            )
        } != 0
        {
            return None;
        }
        Some((info[18], physical))
    }
}
#[cfg(not(target_os = "macos"))]
mod native {
    use super::*;
    pub struct Source;
    impl Source {
        pub fn new(_: Arc<Mutex<PressureState>>, _: Instant) -> Self {
            Self
        }
        pub fn available(&self) -> bool {
            false
        }
    }
    pub fn footprint() -> Option<(u64, u64)> {
        #[cfg(target_os = "linux")]
        {
            let text = std::fs::read_to_string("/proc/meminfo").ok()?;
            let physical = text
                .lines()
                .find_map(|line| {
                    line.strip_prefix("MemTotal:")
                        .and_then(|value| value.split_whitespace().next()?.parse::<u64>().ok())
                })?
                .saturating_mul(1024);
            Some((crate::platform::process::own_resident_bytes()?, physical))
        }
        #[cfg(target_os = "windows")]
        {
            windows_footprint()
        }
        #[cfg(not(any(target_os = "linux", target_os = "windows")))]
        {
            None
        }
    }
    #[cfg(target_os = "windows")]
    fn windows_footprint() -> Option<(u64, u64)> {
        use std::ffi::c_void;
        #[repr(C)]
        struct Counters {
            cb: u32,
            faults: u32,
            bytes: [usize; 9],
        }
        #[link(name = "kernel32")]
        unsafe extern "system" {
            fn GetCurrentProcess() -> *mut c_void;
            fn GetPhysicallyInstalledSystemMemory(kb: *mut u64) -> i32;
        }
        #[link(name = "psapi")]
        unsafe extern "system" {
            fn GetProcessMemoryInfo(
                process: *mut c_void,
                counters: *mut Counters,
                size: u32,
            ) -> i32;
        }
        let mut counters = Counters {
            cb: std::mem::size_of::<Counters>() as u32,
            faults: 0,
            bytes: [0; 9],
        };
        let mut physical = 0u64;
        // The process pseudo handle needs no close; both pointers reference
        // properly sized writable C-layout storage owned by this call.
        unsafe {
            if GetProcessMemoryInfo(GetCurrentProcess(), &mut counters, counters.cb) == 0
                || GetPhysicallyInstalledSystemMemory(&mut physical) == 0
            {
                return None;
            }
        }
        Some((counters.bytes[1] as u64, physical.saturating_mul(1024)))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    struct Fixture {
        root: PathBuf,
        terminal: Arc<RwLock<Chau7Terminal>>,
        memory: Arc<SessionMemory>,
    }
    impl Fixture {
        fn new(lines: usize) -> Self {
            let root =
                std::env::temp_dir().join(format!("next-memory-test-{}", uuid::Uuid::new_v4()));
            let data = chau7_next_core::data_root::DataRoot::with_home(root.clone(), true);
            let terminal = Arc::new(RwLock::new(Chau7Terminal::new_headless(40, 8).unwrap()));
            terminal.read().set_scrollback_size(lines);
            let output = (0..lines.min(4000))
                .map(|row| format!("\x1b[31mrow-{row:04}\x1b[0m\r\n"))
                .collect::<String>();
            terminal.read().inject_output(output.as_bytes());
            let memory = register(100, &terminal, &data, lines);
            Self {
                root,
                terminal,
                memory,
            }
        }
        fn phase(&self, phase: RenderPhase, idle: Duration) {
            let mut state = self.memory.state.lock();
            state.phase = phase;
            state.idle_since = Instant::now() - idle;
        }
    }
    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.root);
        }
    }
    #[test]
    fn verified_flush_compacts_then_promotion_restores_ansi_and_new_tail() {
        let fixture = Fixture::new(300);
        fixture.phase(RenderPhase::Hidden, Duration::ZERO);
        fixture.memory.maintain();
        assert_eq!(fixture.memory.metrics.lock().flushes, 1);
        assert!(fixture.terminal.read().debug_state().history_size <= 50);
        assert!(
            scrollback_cache::load(&fixture.memory.cache)
                .unwrap()
                .data
                .windows(8)
                .any(|part| part == b"row-0000")
        );
        fixture.terminal.read().inject_output(b"after-flush\r\n");
        // Headless injected output does not increment the native PTY byte
        // counter; simulate the authoritative counter delta observed in a shell.
        fixture
            .memory
            .state
            .lock()
            .flushed
            .as_mut()
            .unwrap()
            .bytes_received = Some(u64::MAX);
        assert!(
            fixture
                .memory
                .styled_for_restore()
                .unwrap()
                .contains("after-flush")
        );
        fixture.phase(RenderPhase::Active, Duration::ZERO);
        fixture.memory.maintain();
        let text = fixture.terminal.read().full_buffer_text();
        assert!(text.contains("row-0000"));
        assert!(text.contains("after-flush"));
        assert!(fixture.memory.state.lock().flushed.is_none());
        assert!(!fixture.memory.cache.exists());
        assert!(fixture.memory.take_refresh());
        assert!(!fixture.memory.take_refresh());
    }
    #[test]
    fn disk_failure_and_corrupt_reload_leave_authoritative_history_intact() {
        let fixture = Fixture::new(300);
        let before = fixture.terminal.read().full_buffer_text();
        let parent = fixture.memory.cache.parent().unwrap();
        std::fs::create_dir_all(parent.parent().unwrap()).unwrap();
        std::fs::write(parent, b"not a directory").unwrap();
        fixture.phase(RenderPhase::Hidden, Duration::ZERO);
        fixture.memory.maintain();
        assert_eq!(fixture.terminal.read().full_buffer_text(), before);
        assert!(fixture.memory.state.lock().flushed.is_none());
        assert_eq!(fixture.memory.metrics.lock().failures, 1);
        std::fs::remove_file(parent).unwrap();
        fixture.memory.maintain();
        std::fs::write(
            &fixture.memory.cache,
            b"CHAU7_SCROLLBACK_ZLIB_V2\ntruncated",
        )
        .unwrap();
        let compact = fixture.terminal.read().full_buffer_text();
        fixture.phase(RenderPhase::Active, Duration::ZERO);
        fixture.memory.maintain();
        assert_eq!(fixture.terminal.read().full_buffer_text(), compact);
        assert!(fixture.memory.state.lock().flushed.is_some());
        assert_eq!(fixture.memory.metrics.lock().reloads, 0);
    }
    #[test]
    fn warm_idle_and_live_tui_follow_distinct_retention_tiers() {
        let fixture = Fixture::new(3000);
        fixture.memory.set_tui(true);
        fixture.phase(RenderPhase::Hidden, policy::TUI_IDLE_DELAY);
        fixture.memory.maintain();
        assert!(fixture.memory.state.lock().flushed.is_none());
        assert!(fixture.terminal.read().debug_state().history_size > 2000);
        fixture.phase(RenderPhase::Warm, policy::TUI_IDLE_DELAY);
        fixture.memory.maintain();
        assert_eq!(fixture.memory.capacity(), 2000);
        assert_eq!(
            fixture.memory.state.lock().flushed.unwrap().kind,
            FlushKind::TuiCompact
        );
        fixture.phase(RenderPhase::Active, Duration::ZERO);
        fixture.memory.maintain();
        assert_eq!(fixture.memory.metrics.lock().reloads, 0);
        fixture.memory.set_tui(false);
        fixture.memory.maintain();
        assert_eq!(fixture.memory.metrics.lock().reloads, 1);
        assert!(
            fixture
                .terminal
                .read()
                .full_buffer_text()
                .contains("row-0000")
        );
        let ordinary = Fixture::new(300);
        ordinary.phase(
            RenderPhase::Warm,
            policy::WARM_IDLE_DELAY - Duration::from_secs(1),
        );
        ordinary.memory.maintain();
        assert!(ordinary.memory.state.lock().flushed.is_none());
        ordinary.phase(RenderPhase::Warm, policy::WARM_IDLE_DELAY);
        ordinary.memory.maintain();
        assert_eq!(
            ordinary.memory.state.lock().flushed.unwrap().kind,
            FlushKind::Idle
        );
    }
    #[test]
    fn promotion_during_durable_write_cancels_ring_reduction() {
        let fixture = Fixture::new(300);
        let before = fixture.terminal.read().full_buffer_text();
        fixture.phase(RenderPhase::Hidden, Duration::ZERO);
        fixture
            .memory
            .maintain_inner(|| fixture.phase(RenderPhase::Active, Duration::ZERO));
        assert_eq!(fixture.terminal.read().full_buffer_text(), before);
        assert!(fixture.memory.state.lock().flushed.is_none());
        assert_eq!(fixture.memory.metrics.lock().flushes, 0);
    }
    #[test]
    fn overlap_reconciliation_is_lossless_for_known_and_unknown_boundaries() {
        let mut bytes = b"first\r\n\x1b[31msecond\x1b[0m\r\nthird\r\n".to_vec();
        append_tail(&mut bytes, "second\r\nthird\r\nfourth\r\n");
        let text = String::from_utf8(bytes).unwrap();
        assert_eq!(
            chau7_next_core::session_restore::visible_for_restore(&text),
            "first\r\nsecond\r\nthird\r\nfourth\r\n"
        );
        let mut unknown = b"old\r\n".to_vec();
        append_tail(&mut unknown, "replacement\r\n");
        let text = String::from_utf8(unknown).unwrap();
        assert!(text.contains("old"));
        assert!(text.contains("replacement"));
        let mut empty = Vec::new();
        append_tail(&mut empty, "");
        assert!(empty.len() < 20);
    }
    #[cfg(target_os = "macos")]
    #[test]
    fn native_footprint_uses_positive_process_and_physical_measurements() {
        let (used, physical) = native::footprint().unwrap();
        assert!(used > 0);
        assert!(physical > used);
    }
}
