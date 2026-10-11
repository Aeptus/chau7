//! One shell: a `chau7_terminal::Chau7Terminal` plus the state the UI shows
//! (grid snapshot, title, directory, git info, detected AI tool, command
//! status and blocks, exit status).
//!
//! PTY output is read by `chau7_terminal`'s own reader thread. A small poll
//! thread here calls `Chau7Terminal::poll` (which feeds the parser), keeps the
//! raw output for the UI thread and wakes it; the UI then takes a grid
//! snapshot on the main thread and feeds the output, the typed input and the
//! OSC 133 marks to [`ShellSession`] (`chau7_next_core::shell_session`), the
//! port of `TerminalSessionModel`'s shell logic. Input goes to the PTY from a
//! writer thread ([`PtyWriter`]), so the UI never blocks on a full PTY.
//! This mirrors `RustTerminalView.swift` (display link, `poll()`, write queue)
//! and `TerminalSessionModel.swift`.

use std::cell::{Cell, RefCell};
use std::collections::{BTreeSet, HashMap};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::time::{Duration, Instant};

use chau7_next_core::ai::detection_state::now_secs;
use chau7_next_core::ai::event::{AiEvent, AiEventReliability, AiEventSource};
use chau7_next_core::command_block::{CommandBlockList, git_changes};
use chau7_next_core::data_root::DataRoot;
use chau7_next_core::feature_profiler::{self, Feature};
use chau7_next_core::monitoring::dev_server::{
    BURST_CHECKS, BURST_FIRST_DELAY, BURST_INTERVAL, CheckRequest, DevServerInfo,
    should_stop_burst_checks,
};
use chau7_next_core::shell_bookmarks::{self, Bookmark, BookmarkList};
use chau7_next_core::shell_history::CommandHistory;
use chau7_next_core::shell_latency::{LagEvent, LatencyTracker};
use chau7_next_core::shell_restore;
use chau7_next_core::shell_session::{
    CommandStatus, ShellContext, ShellMark, ShellSession, ShellSessionConfig, ShellSessionEvent,
};
use chau7_next_core::work_profiler::{self, Key as WorkKey, Kind as WorkKind, Queue as WorkQueue};
use chau7_next_core::{shell_env, shell_integration, shell_tips};
use chau7_terminal::{Chau7Terminal, GridCopy, OutputInterrupt, graphics::ShellIntegrationEvent};
use futures::channel::mpsc;
use futures::{FutureExt, StreamExt};
use gpui::{AppContext, Context, EventEmitter, Global, Task};
use parking_lot::{Mutex, RwLock};

use super::pty_writer::{CloseMode, PtyWriter, Signal, signal_group};
use crate::monitoring::session::{SessionMonitor, shell_ai_event};
use crate::platform::process as procinfo;
use crate::settings::{ActivePollingRateCap, BellSound, Settings};

const PTY_READINESS_MAX_WAIT_MS: u64 = 200;

fn replay_restored_terminal(term: &Chau7Terminal, context: &str) {
    let live = term.full_buffer_ansi_text();
    let mut bytes = context.as_bytes().to_vec();
    bytes.extend_from_slice(b"\r\n\x1b[0m");
    bytes.extend_from_slice(live.as_bytes());
    term.replay_buffer(&bytes);
}

#[derive(Clone, Copy)]
enum RefreshWake {
    Output,
    Cadence,
}

fn refresh_interval(
    interactive: bool,
    active: ActivePollingRateCap,
    inactive_fps: u32,
) -> Duration {
    let fps = if interactive {
        active.cap_hz()
    } else {
        Some(inactive_fps.clamp(1, 120))
    };
    fps.map_or(Duration::ZERO, |fps| {
        Duration::from_secs_f64(1.0 / f64::from(fps))
    })
}

fn refresh_wait(interval: Duration, suspended: bool, elapsed: Duration) -> Duration {
    let interval = if suspended {
        Duration::from_millis(500)
    } else {
        interval
    };
    interval.saturating_sub(elapsed)
}

static NEXT_SESSION_ID: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(1);

/// Set when the app quits: sessions dropped afterwards get SIGTERM at once.
static APP_QUITTING: AtomicBool = AtomicBool::new(false);

/// Live shells (session id to shell pid), for [`terminate_all_for_quit`].
static LIVE_SHELLS: Mutex<Option<HashMap<u64, i32>>> = Mutex::new(None);

/// No PTY output this long after start: "Shell initializing" notice
/// (`shellStartupTimeoutWork`, RBK-009).
const STARTUP_SLOW_AFTER: Duration = Duration::from_secs(5);
/// White flash of the visual bell (`flashBell`: 0.05 s in, 0.12 s out).
pub const BELL_FLASH: Duration = Duration::from_millis(170);

/// Events other views listen to (tab bar, workspace).
#[derive(Debug, Clone)]
pub enum SessionEvent {
    /// New output was processed (grid changed).
    Output,
    /// Title, directory, git root, AI tool, status or loading state changed.
    MetadataChanged,
    /// The bell rang (after the bell setting allowed it).
    Bell,
    /// A command started (typed line or shell integration), with its text.
    CommandStarted(String),
    /// A command finished (shell integration, OSC 133 D) with this exit code.
    CommandFinished(i32),
    /// The shell exited, with its exit code when known.
    Exited(Option<i32>),
    /// The program asked to set the clipboard (OSC 52).
    ClipboardStore(String),
    /// The program asked to read the clipboard (OSC 52): answer with
    /// [`TerminalSession::respond_clipboard`].
    ClipboardLoad,
    /// The shell's directory changed (profile rules, snippet repo context).
    DirectoryChanged(PathBuf),
    /// The user answered a prompt: clear a permission border.
    PermissionResolved,
    /// An AI tool handed back the prompt (`waiting_input` fallback event).
    WaitingInput { tool: String },
    /// An event for the AI event feed (shell events, waiting input, shell
    /// exit). The workspace fills in the tab and, with `tab_name_as_tool`,
    /// puts the tab title in `tool` (`notificationTabName`).
    Ai {
        event: Box<AiEvent>,
        notify: bool,
        tab_name_as_tool: bool,
    },
    /// The last command changed these files (git, MON-014).
    ChangedFiles(Vec<String>),
}

/// Last finished command, from shell integration (OSC 133 D).
#[derive(Debug, Clone, Copy)]
pub struct LastCommand {
    pub exit_code: i32,
    pub duration: Duration,
}

/// Command history shared by every session (`CommandHistoryManager.shared`).
#[derive(Default)]
pub struct SharedCommandHistory(pub CommandHistory);
impl Global for SharedCommandHistory {}

/// What the session needs from the environment.
struct EnvContext {
    search_path: Option<String>,
    home: String,
}

impl ShellContext for EnvContext {
    fn is_dir(&self, path: &str) -> bool {
        Path::new(path).is_dir()
    }
    fn search_path(&self) -> Option<String> {
        self.search_path.clone()
    }
    fn home(&self) -> String {
        self.home.clone()
    }
}

pub struct TerminalSession {
    pub id: u64,
    /// This terminal's identity for the analytics proxy and AI run
    /// telemetry (`tabIdentifier`, `CHAU7_NEXT_TAB_ID`): a UUID per session.
    pub tab_identifier: String,
    term: Arc<RwLock<Chau7Terminal>>,
    memory: Arc<crate::memory_pressure::SessionMemory>,
    writer: PtyWriter,
    stop: Arc<AtomicBool>,
    poll_interrupt: OutputInterrupt,
    poll_interactive: AtomicBool,
    /// Raw output collected by the poll thread since the last refresh, and
    /// when the first of it arrived (latency).
    output: Arc<Mutex<(Vec<u8>, Option<Instant>)>>,
    /// (dev) Input and output latency (TRM-062).
    latency: RefCell<LatencyTracker>,
    /// Bytes of output the last refresh processed (output bursts, TRM-055).
    pub last_output_bytes: usize,
    /// Actual PTY bytes only, bounded to 16 KiB for failing-command permission diagnosis.
    permission_output_tail: chau7_next_core::permission_center::PermissionOutputTail,
    /// Bookmarks of this session (TRM-057).
    bookmarks: BookmarkList,
    /// Resume command waiting to be typed at the prompt (TRM-010).
    restore_intent: Option<chau7_next_core::session_restore::lifecycle::RestorePrefillIntent>,
    restore_token: u64,
    restore_input_generation: Cell<u64>,
    restore_presented: Cell<bool>,
    restore_selected: Cell<bool>,
    restore_window_visible: Cell<bool>,
    restore_hidden_since: Cell<Option<Instant>>,
    surface_prewarm: Cell<chau7_next_core::session_restore::lifecycle::SurfacePrewarm>,
    pending_prefill: Option<String>,
    prefill_retries: u32,
    prefill_scheduled: bool,
    /// Typed input not yet given to the tracker, with the echo state.
    pending_input: RefCell<Vec<(Vec<u8>, bool)>>,
    echo_fd: i32,
    pub grid: GridCopy,
    pub cursor: (u16, u16),
    pub title: Option<String>,
    pub cwd: Option<PathBuf>,
    pub git_root: Option<PathBuf>,
    pub git_branch: Option<String>,
    pub ai_app: Option<String>,
    /// Id the token optimizer knows this shell by (`CHAU7_CTO_SESSION`, the
    /// flag file name).
    cto_id: String,
    pub exited: Option<Option<i32>>,
    pub last_activity: Instant,
    pub last_command: Option<LastCommand>,
    /// OSC9 prompt status is metadata, not a second command completion.
    pub last_prompt_exit_code: Option<i32>,
    pub last_prompt_exit_at: Option<Instant>,
    osc9: chau7_next_core::osc9::Parser,
    pub command_running: bool,
    pub started_at: Instant,
    /// Suspend Background Rendering (`paint.rs`, view blink timer): while
    /// set, output is still parsed but the grid is refreshed at most every
    /// 500 ms (Swift `startBackgroundDrain`).
    render_suspended: Arc<AtomicBool>,
    refresh_interval_ns: Arc<AtomicU64>,
    refresh_wake: mpsc::UnboundedSender<RefreshWake>,
    /// Shell state machine (status, typed lines, AI tool, command blocks).
    tracker: ShellSession,
    shell_context: EnvContext,
    /// Our startup files are installed for this shell (zsh, bash, fish).
    has_hooks: bool,
    /// Some PTY output arrived.
    first_output: bool,
    /// No output 5 s after start (`shellStartupSlow`).
    pub shell_slow: bool,
    /// Visual bell: paint a white flash until this time.
    pub bell_flash_until: Option<Instant>,
    /// Git status at the start of the running command (OSC 133 C).
    git_baseline: Arc<Mutex<Option<BTreeSet<String>>>>,
    /// The user closed this session (no "shell exited" notice).
    close_requested: bool,
    last_cwd_check: Instant,
    last_branch_check: Instant,
    /// Directory of the running command and the shell's name, for the
    /// command history.
    command_dir: Option<String>,
    /// The session restore line was typed and its command has not finished
    /// yet: its start and end are not command results (no success style,
    /// history, AI shell events or last command).
    restore_line_pending: bool,
    shell_name: Option<String>,
    pending_resize: Option<(u16, u16)>,
    /// Shell events, dev server and AI log (Monitoring).
    monitor: SessionMonitor,
    /// Dev server port checks in flight (burst or one-shot).
    dev_checks: Option<Task<()>>,
    /// `[terminal] mouse_reporting` (`input.mouse_reporting`): off hides the program's mouse modes,
    /// so the mouse always selects (TRM-018).
    mouse_reporting_enabled: std::cell::Cell<bool>,
    _pump: Task<()>,
    _ticker: Task<()>,
    process_subscription: Option<crate::monitoring::process_tree::Subscription>,
}

impl EventEmitter<SessionEvent> for TerminalSession {}

/// Login shell of the user's passwd entry (`systemDefaultShell`), else
/// `$SHELL`, else zsh (PowerShell on Windows).
pub fn system_login_shell() -> String {
    #[cfg(unix)]
    {
        // SAFETY: getpwuid_r writes into our buffer and `pwd`; the shell
        // string is copied before the buffer goes away.
        unsafe {
            let mut pwd: libc::passwd = std::mem::zeroed();
            let mut result: *mut libc::passwd = std::ptr::null_mut();
            let mut buffer = vec![0 as libc::c_char; 4096];
            if libc::getpwuid_r(
                libc::getuid(),
                &mut pwd,
                buffer.as_mut_ptr(),
                buffer.len(),
                &mut result,
            ) == 0
                && !result.is_null()
                && !pwd.pw_shell.is_null()
            {
                let shell = std::ffi::CStr::from_ptr(pwd.pw_shell)
                    .to_string_lossy()
                    .to_string();
                if !shell.is_empty() {
                    return shell;
                }
            }
        }
    }
    std::env::var("SHELL")
        .ok()
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| {
            if cfg!(windows) {
                "powershell.exe"
            } else {
                "/bin/zsh"
            }
            .to_string()
        })
}

/// SIGTERM to every live shell's process group (`closeSessionForTermination`
/// on quit). Sessions dropped afterwards skip the grace delays.
pub fn terminate_all_for_quit() {
    APP_QUITTING.store(true, Ordering::Release);
    let pids: Vec<i32> = LIVE_SHELLS
        .lock()
        .as_ref()
        .map(|m| m.values().copied().collect())
        .unwrap_or_default();
    for pid in pids {
        signal_group(pid, Signal::Term);
    }
}

fn register_shell(id: u64, pid: i32) {
    if pid > 0 {
        LIVE_SHELLS
            .lock()
            .get_or_insert_with(HashMap::new)
            .insert(id, pid);
    }
}

fn unregister_shell(id: u64) {
    if let Some(map) = LIVE_SHELLS.lock().as_mut() {
        map.remove(&id);
    }
}

impl TerminalSession {
    /// Start a shell in `cwd` (or the configured/default directory).
    pub fn spawn(
        cols: u16,
        rows: u16,
        cwd: Option<PathBuf>,
        settings: &Settings,
        root: &DataRoot,
        cx: &mut Context<Self>,
    ) -> anyhow::Result<Self> {
        super::pty_capture::init(&root.pty_capture_file());
        let shell_path = settings.terminal.resolved_shell();
        let home = root.home().to_string_lossy().to_string();
        let mut env =
            shell_env::shell_environment(Some(&home), std::env::var("PATH").ok().as_deref());
        let integration_dir = root.shell_integration_dir();
        env.extend(shell_integration::environment(
            &shell_path,
            &integration_dir,
            &root.history_file(),
            |key| std::env::var(key).ok(),
        ));
        let start_dir = start_directory(cwd.as_deref(), settings, &home);
        let session_id = uuid::Uuid::new_v4().to_string().to_uppercase();
        env.extend(shell_env::session_environment(
            &shell_path,
            &session_id,
            &start_dir.to_string_lossy(),
            &settings.terminal.startup_command,
            settings.terminal.ls_colors,
        ));
        // TRM-026: AI CLIs go through the local analytics proxy.
        let tab_identifier = uuid::Uuid::new_v4().to_string().to_uppercase();
        env.extend([
            ("CHAU7_NEXT_SESSION_ID".into(), session_id.clone()),
            ("CHAU7_NEXT_TAB_ID".into(), tab_identifier.clone()),
            (
                "CHAU7_NEXT_PROJECT".into(),
                start_dir.to_string_lossy().into_owned(),
            ),
            // Installed Swift hooks must not treat a Next shell as their tab.
            ("CHAU7_TAB_ID".into(), String::new()),
            (
                "CHAU7_NEXT_CODEX_PROXY_WRAPPER_DIR".into(),
                shell_integration::codex_wrapper_dir(&integration_dir)
                    .to_string_lossy()
                    .into_owned(),
            ),
        ]);
        if settings.proxy.enabled {
            env.extend(chau7_next_core::proxy::shell_env(
                settings.proxy.port,
                settings.proxy.include_openai,
                &session_id,
                &tab_identifier,
                &start_dir.to_string_lossy(),
            ));
            if settings.proxy.include_openai {
                env.extend(chau7_next_core::proxy::codex_shell_env(
                    root,
                    settings.proxy.port,
                ));
            }
        }
        // Token optimization: the wrapper folder in front of PATH, and the
        // variables the wrappers read (`launchPATHValue`, `buildEnvironment`).
        if settings.cto.mode != chau7_next_core::token_optimization::TokenOptimizationMode::Off {
            let paths = chau7_next_core::cto_wrappers::CtoPaths::from_root(root);
            let path = env
                .iter()
                .find(|(k, _)| k == "PATH")
                .map(|(_, v)| v.clone())
                .unwrap_or_default();
            env.retain(|(k, _)| k != "PATH");
            env.extend(crate::cto::shell_environment(&paths, &path, &session_id));
        }
        // The owned dispatcher also provides notification capture when
        // analytics is disabled; Codex's shim transparently passes through.
        #[cfg(unix)]
        {
            let wrapper = shell_integration::codex_wrapper_dir(&integration_dir);
            let previous = env
                .iter()
                .find(|(key, _)| key == "PATH")
                .map(|(_, value)| value.clone())
                .unwrap_or_default();
            env.retain(|(key, _)| key != "PATH");
            env.push(("PATH".into(), format!("{}:{previous}", wrapper.display())));
        }
        let search_path = env
            .iter()
            .find(|(k, _)| k == "PATH")
            .map(|(_, v)| v.clone());
        let args = shell_integration::arguments(&shell_path, &integration_dir);
        let arg_refs: Vec<&str> = args.iter().map(String::as_str).collect();
        let env_refs: Vec<(&str, &str)> =
            env.iter().map(|(k, v)| (k.as_str(), v.as_str())).collect();
        let term = Chau7Terminal::new_with_args_env_in_dir(
            cols.max(2),
            rows.max(1),
            &shell_path,
            &arg_refs,
            &env_refs,
            Some(&start_dir),
        )
        .map_err(|e| anyhow::anyhow!("could not start shell: {e}"))?;
        term.set_scrollback_size(settings.terminal.scrollback_lines);
        apply_colors(&term, settings);
        apply_image_protocols(&term, settings);
        let mouse_reporting = settings.input.mouse_reporting;
        // Tip box above the first prompt (TRM-005, injected without the PTY).
        if let Some(tip) = shell_tips::header_box(
            cols.max(2) as usize,
            &crate::l10n::platform(&shell_tips::random_formatted_tip(now_secs() as u64)),
        ) {
            term.inject_output(tip.as_bytes());
        }
        let has_hooks =
            !shell_integration::environment(&shell_path, &integration_dir, Path::new(""), |_| None)
                .is_empty();
        let mut session = Self::from_terminal(term, Some(start_dir), cx);
        session.tab_identifier = tab_identifier;
        session.has_hooks = has_hooks;
        session.shell_name = Path::new(&shell_path)
            .file_name()
            .map(|n| n.to_string_lossy().to_string());
        session.mouse_reporting_enabled.set(mouse_reporting);
        session.shell_context = EnvContext { search_path, home };
        session.cto_id = session_id;
        crate::cto::register_session(
            &session.cto_id,
            chau7_next_core::token_optimization::TabTokenOptOverride::Default,
        );
        session.apply_cto_prefix(settings);
        Ok(session)
    }

    /// Wrap an existing terminal (also used by tests with headless terminals).
    pub fn from_terminal(
        term: Chau7Terminal,
        cwd: Option<PathBuf>,
        cx: &mut Context<Self>,
    ) -> Self {
        Self::from_terminal_driving(term, cwd, true, cx)
    }

    /// Real fixture PTYs use the production model and writer, while their
    /// deterministic GPUI tests manually drive input instead of permitting
    /// external native threads to wake the mock foreground scheduler.
    #[cfg(all(test, unix))]
    pub(crate) fn from_terminal_manually_driven(
        term: Chau7Terminal,
        cwd: Option<PathBuf>,
        cx: &mut Context<Self>,
    ) -> Self {
        Self::from_terminal_driving(term, cwd, false, cx)
    }

    fn from_terminal_driving(
        term: Chau7Terminal,
        cwd: Option<PathBuf>,
        start_external_workers: bool,
        cx: &mut Context<Self>,
    ) -> Self {
        let echo_fd = term.echo_fd();
        let has_pty = term.has_pty();
        let pid = term.shell_pid() as i32;
        let (readiness, poll_interrupt) = term.output_readiness();
        let term = Arc::new(RwLock::new(term));
        let stop = Arc::new(AtomicBool::new(false));
        let output = Arc::new(Mutex::new((Vec::new(), None)));
        let (tx, mut rx) = mpsc::unbounded::<RefreshWake>();
        let refresh_wake = tx.clone();
        let id = NEXT_SESSION_ID.fetch_add(1, Ordering::Relaxed);
        // The poll thread observes the actual retention phase without owning
        // the session or altering construction/teardown order.
        let profile_memory = Arc::new(std::sync::OnceLock::<
            std::sync::Weak<crate::memory_pressure::SessionMemory>,
        >::new());

        if start_external_workers {
            let term = term.clone();
            let stop = stop.clone();
            let output = output.clone();
            let profile_memory = profile_memory.clone();
            std::thread::Builder::new()
                .name("chau7-next-poll".into())
                .spawn(move || {
                    while !stop.load(Ordering::Acquire) {
                        // Reader-channel readiness never dequeues output and owns
                        // no terminal/parser lock. Input/focus/stop interrupts are
                        // coalesced; PTY arrival wakes this wait immediately.
                        let wait_visibility = profile_memory
                            .get()
                            .and_then(std::sync::Weak::upgrade)
                            .map_or("unobserved", |memory| memory.profiling_phase());
                        let wait_key = WorkKey::work(
                            "pty_readiness_wait",
                            "readiness",
                            wait_visibility,
                            "pty_poll",
                            WorkQueue::Background,
                        );
                        let _ready = work_profiler::measure(wait_key, || {
                            readiness.wait(Duration::from_millis(PTY_READINESS_MAX_WAIT_MS))
                        });
                        if stop.load(Ordering::Acquire) {
                            break;
                        }
                        let visibility = profile_memory
                            .get()
                            .and_then(std::sync::Weak::upgrade)
                            .map_or("unobserved", |memory| memory.profiling_phase());
                        let mut wake = work_profiler::begin(WorkKey::wakeup(
                            "pty_poll",
                            visibility,
                            WorkQueue::Background,
                        ));
                        let (had_data, closed, bytes) = {
                            let term = term.read();
                            let had = work_profiler::measure(
                                WorkKey::work(
                                    "native_poll_and_parse",
                                    "drain",
                                    visibility,
                                    "pty_poll",
                                    WorkQueue::Background,
                                ),
                                || term.poll(0),
                            );
                            let mut extraction = work_profiler::begin(WorkKey::work(
                                "get_last_output",
                                "drain",
                                visibility,
                                "pty_poll",
                                WorkQueue::Background,
                            ));
                            let bytes = term.get_last_output();
                            extraction.bytes(bytes.len());
                            (had, term.is_pty_closed(), bytes)
                        };
                        let got_bytes = !bytes.is_empty();
                        wake.bytes(bytes.len());
                        wake.idle(!had_data && !closed && !got_bytes);
                        if got_bytes {
                            super::pty_capture::record(&bytes, "read");
                            crate::history::recorder::output(id, &bytes);
                            let mut out = output.lock();
                            out.0.extend_from_slice(&bytes);
                            out.1.get_or_insert_with(Instant::now);
                        }
                        if (had_data || closed || got_bytes)
                            && tx.unbounded_send(RefreshWake::Output).is_err()
                        {
                            break;
                        }
                        if closed {
                            break;
                        }
                    }
                })
                .expect("spawn poll thread");
        }

        // Coalesce wakeups: one UI refresh per batch of output.
        let render_suspended = Arc::new(AtomicBool::new(false));
        let suspended = render_suspended.clone();
        let refresh_interval_ns = Arc::new(AtomicU64::new(0));
        let pacing = refresh_interval_ns.clone();
        let pump = cx.spawn(async move |this, cx| {
            let mut last_refresh: Option<Instant> = None;
            'pump: while let Some(first) = rx.next().await {
                let mut notifications = usize::from(matches!(first, RefreshWake::Output));
                while let Ok(next) = rx.try_recv() {
                    notifications += usize::from(matches!(next, RefreshWake::Output));
                }
                // Focus/settings changes only interrupt a pending deadline.
                // They do not invent output or reset session activity.
                if notifications == 0 { continue; }
                loop {
                    let wait = last_refresh.map_or(Duration::ZERO, |at| refresh_wait(
                        Duration::from_nanos(pacing.load(Ordering::Relaxed)),
                        suspended.load(Ordering::Relaxed), at.elapsed()));
                    if wait.is_zero() { break; }
                    let delay = cx.background_executor().timer(wait).fuse();
                    let next = rx.next().fuse();
                    futures::pin_mut!(delay, next);
                    futures::select_biased! {
                        event = next => match event {
                            Some(event) => notifications += usize::from(matches!(event, RefreshWake::Output)),
                            None => break 'pump,
                        },
                        _ = delay => {},
                    }
                }
                while let Ok(next) = rx.try_recv() {
                    notifications += usize::from(matches!(next, RefreshWake::Output));
                }
                if this.update(cx, |this, cx| {
                    let mut wake = work_profiler::begin(WorkKey::wakeup(
                        "output_dispatch", this.profiling_phase(), WorkQueue::Main));
                    wake.items(notifications);
                    this.refresh(cx);
                }).is_err() { break; }
                last_refresh = Some(Instant::now());
            }
        });
        // Once a second: idle/stuck timers, startup notice, cwd and branch.
        let ticker = cx.spawn(async move |this, cx| {
            loop {
                cx.background_executor()
                    .timer(Duration::from_millis(1000))
                    .await;
                if this.update(cx, |this, cx| this.tick(cx)).is_err() {
                    break;
                }
            }
        });

        if has_pty {
            register_shell(id, pid);
        }
        let writer = PtyWriter::spawn(term.clone());
        let git_root = cwd.as_deref().and_then(procinfo::git_root);
        let git_branch = git_root.as_deref().and_then(|root| {
            crate::repository::resolve(root, cx)
                .and_then(|shared| crate::repository::branch(&shared, cx))
        });
        let grid = term.read().grid_copy();
        let now = Instant::now();
        let directory = cwd
            .as_ref()
            .map(|p| p.to_string_lossy().to_string())
            .unwrap_or_default();
        let mut config = ShellSessionConfig::from_env(|k| std::env::var(k).ok());
        let (root, shell_events) = match cx.try_global::<Settings>() {
            Some(settings) => {
                config.custom_rules = settings.ai.detection_rules();
                (
                    cx.try_global::<crate::workspace::AppData>()
                        .map(|d| d.root.clone())
                        .unwrap_or_else(DataRoot::from_env),
                    chau7_next_core::monitoring::shell_events::ShellEventConfig::from_notification_settings(
                        &settings.notifications.shell_events,
                    ),
                )
            }
            None => (DataRoot::from_env(), Default::default()),
        };
        let lines = cx
            .try_global::<Settings>()
            .map_or(10_000, |settings| settings.terminal.scrollback_lines);
        let memory = crate::memory_pressure::register(id, &term, &root, lines);
        let _ = profile_memory.set(Arc::downgrade(&memory));
        let process_subscription = (start_external_workers && has_pty && pid > 0).then(|| {
            crate::monitoring::process_tree::subscribe(pid as u32, cx.entity().downgrade(), cx)
        });
        Self {
            id,
            term,
            memory,
            writer,
            stop,
            poll_interrupt,
            poll_interactive: AtomicBool::new(true),
            output,
            pending_input: RefCell::new(Vec::new()),
            latency: RefCell::new(LatencyTracker::new()),
            last_output_bytes: 0,
            permission_output_tail: Default::default(),
            bookmarks: BookmarkList::new(),
            restore_intent: None,
            restore_token: 0,
            restore_input_generation: Cell::new(0),
            restore_presented: Cell::new(false),
            restore_selected: Cell::new(false),
            restore_window_visible: Cell::new(false),
            restore_hidden_since: Cell::new(Some(Instant::now())),
            surface_prewarm: Cell::new(Default::default()),
            pending_prefill: None,
            prefill_retries: 0,
            prefill_scheduled: false,
            echo_fd,
            grid,
            cursor: (0, 0),
            title: None,
            cwd,
            git_root,
            git_branch,
            ai_app: None,
            cto_id: uuid::Uuid::new_v4().to_string().to_uppercase(),
            exited: None,
            last_activity: now,
            last_command: None,
            last_prompt_exit_code: None,
            last_prompt_exit_at: None,
            osc9: Default::default(),
            command_running: false,
            started_at: now,
            render_suspended,
            refresh_interval_ns,
            refresh_wake,
            tracker: ShellSession::new(config, &directory, now_secs()),
            shell_context: EnvContext {
                search_path: std::env::var("PATH").ok(),
                home: std::env::var("HOME").unwrap_or_default(),
            },
            has_hooks: false,
            first_output: false,
            shell_slow: false,
            bell_flash_until: None,
            git_baseline: Arc::new(Mutex::new(None)),
            close_requested: false,
            last_cwd_check: now,
            last_branch_check: now,
            command_dir: None,
            restore_line_pending: false,
            shell_name: None,
            pending_resize: None,
            monitor: SessionMonitor::new(id, &root, shell_events),
            tab_identifier: uuid::Uuid::new_v4().to_string().to_uppercase(),
            dev_checks: None,
            mouse_reporting_enabled: std::cell::Cell::new(false),
            _pump: pump,
            _ticker: ticker,
            process_subscription,
        }
    }

    /// Pull everything new from the terminal and notify observers.
    /// On-demand retained capacities and native estimates, never terminal text.
    /// Native debug_state uses O(1) row counters rather than walking history.
    pub fn allocation_snapshot(&self) -> serde_json::Value {
        let native = self.term.read().debug_state();
        let output = self.output.lock();
        let pending = self.pending_input.borrow();
        let grid_cells = self
            .grid
            .cells
            .capacity()
            .saturating_mul(std::mem::size_of::<chau7_terminal::OwnedCell>());
        let clusters = self
            .grid
            .clusters
            .values()
            .map(String::capacity)
            .sum::<usize>();
        let pending_input = pending
            .iter()
            .map(|(bytes, _)| bytes.capacity())
            .sum::<usize>();
        let output_capacity = output.0.capacity();
        let preview = self.memory.restoration_preview_capacity_bytes();
        serde_json::json!({
            "session_id":self.id, "render_phase":self.profiling_phase(),
            "grid_cols":native.cols, "grid_rows":native.rows,
            "history_rows":native.history_size, "alternate_screen_active":native.alternate_screen != 0,
            "native_ring_estimated_bytes":native.estimated_grid_bytes,
            "ui_grid_cells_capacity_bytes":grid_cells, "ui_grid_cluster_string_capacity_bytes":clusters,
            "pending_output_bytes":output.0.len(), "pending_output_capacity_bytes":output_capacity,
            "pending_input_capacity_bytes":pending_input, "restoration_preview_capacity_bytes":preview,
            "known_session_capacity_bytes":grid_cells.saturating_add(clusters).saturating_add(output_capacity).saturating_add(pending_input).saturating_add(preview),
            "refresh_cap_interval_ms":self.refresh_interval_ns.load(Ordering::Relaxed) as f64 / 1_000_000.0,
            "display_native_refresh":self.refresh_interval_ns.load(Ordering::Relaxed) == 0,
            "refresh_interactive":self.poll_interactive.load(Ordering::Relaxed),
            "pty_readiness_max_wait_ms":PTY_READINESS_MAX_WAIT_MS,
            "render_suspended":self.is_render_suspended(),
            "native_pending_image_bytes":serde_json::Value::Null,
            "unavailable_reason":"Native pending images and private GPUI GPU resources expose no allocation accessor; native ring bytes are estimated. Known capacities exclude allocator/HashMap overhead."
        })
    }

    pub fn profiling_phase(&self) -> &'static str {
        self.memory.profiling_phase()
    }

    pub fn refresh(&mut self, cx: &mut Context<Self>) {
        let mut processing = work_profiler::begin(WorkKey::work(
            "output_processing",
            "drain",
            self.profiling_phase(),
            "session_refresh",
            WorkQueue::Main,
        ));
        let started = Instant::now();
        self.memory.set_tui(self.is_ai_running());
        let mut metadata_changed = self.retry_resize();
        let (grid, cursor, title, closed, events, bell, clipboard, clipboard_load) = {
            let term = self.term.read();
            (
                {
                    let mut capture = work_profiler::begin(WorkKey::work(
                        "get_grid",
                        "drain",
                        self.profiling_phase(),
                        "session_refresh",
                        WorkQueue::Main,
                    ));
                    let grid = term.grid_copy();
                    capture.items(grid.cells.len());
                    capture.bytes(
                        grid.cells
                            .len()
                            .saturating_mul(std::mem::size_of::<chau7_terminal::OwnedCell>())
                            .saturating_add(grid.clusters.values().map(String::len).sum::<usize>()),
                    );
                    grid
                },
                work_profiler::measure(
                    WorkKey::work(
                        "cursor_mode_read",
                        "drain",
                        self.profiling_phase(),
                        "session_refresh",
                        WorkQueue::Main,
                    ),
                    || term.cursor_position(),
                ),
                term.take_pending_title(),
                term.is_pty_closed(),
                term.take_shell_events(),
                term.check_bell(),
                term.take_clipboard_store(),
                term.has_pending_clipboard_load(),
            )
        };
        let (output, output_at) = std::mem::take(&mut *self.output.lock());
        self.last_output_bytes = output.len();
        processing.bytes(output.len());
        processing.idle(output.is_empty());
        self.permission_output_tail.push(&output);
        if let Some(at) = output_at {
            let mut key = WorkKey::work(
                "event_dispatch_wait",
                "drain",
                self.profiling_phase(),
                "output_dispatch",
                WorkQueue::Main,
            );
            key.kind = WorkKind::Latency;
            work_profiler::record(
                key,
                at.elapsed().as_secs_f64() * 1000.0,
                output.len(),
                1,
                false,
            );
            // Output latency runs from the bytes' arrival to the frame that
            // shows them (`mark_frame_drawn`); a measure no frame closed
            // within 0.2 s (hidden tab) is dropped first.
            let mut latency = self.latency.borrow_mut();
            latency.expire_output(clock(Instant::now()));
            let spike = latency.mark_output(clock(at));
            drop(latency);
            if let Some(spike) = spike {
                self.log_lag(&spike);
            }
        }
        let display_offset_before = self.grid.display_offset;
        self.grid = grid;
        self.cursor = cursor;
        self.last_activity = Instant::now();
        let now = now_secs();

        if let Some(title) = title {
            let stable = chau7_next_core::terminal_title::stable_display_title(&title);
            let next = (!stable.is_empty()).then(|| stable.to_string());
            if next != self.title {
                self.title = next;
                metadata_changed = true;
            }
        }

        // Typed input first (the command line), then the marks, then the
        // output: an OSC 133 D must be seen before the OSC 7 of the next
        // prompt, or the command would complete without its exit code.
        self.process_pending_input(now);
        let line = self.grid.scrollback_rows as i64 + self.cursor.1 as i64;
        for event in events {
            let mark = match event {
                ShellIntegrationEvent::PromptStart => ShellMark::PromptStart,
                ShellIntegrationEvent::CommandStart => ShellMark::CommandStart,
                ShellIntegrationEvent::CommandExecuted => ShellMark::CommandExecuted,
                ShellIntegrationEvent::CommandFinished { exit_code } => {
                    ShellMark::CommandFinished(exit_code)
                }
            };
            let prompt = mark == ShellMark::PromptStart;
            crate::monitoring::process_tree::refresh(cx, mark == ShellMark::CommandStart);
            self.tracker.handle_mark(mark, line, now);
            if prompt {
                // The first prompt creates the deferred token optimizer flag.
                crate::cto::prompt_detected(&self.cto_id);
            }
        }
        if !output.is_empty() {
            if !self.first_output {
                self.first_output = true;
                if self.shell_slow {
                    self.shell_slow = false;
                    metadata_changed = true;
                }
                if !self.has_hooks {
                    // No prompt marks will come: loading ends with output.
                    crate::cto::prompt_detected(&self.cto_id);
                    metadata_changed = true;
                }
            }
            let ctx = &self.shell_context;
            feature_profiler::measure(Feature::Semantic, output.len(), || {
                self.tracker.handle_output(&output, ctx, now);
            });
            let (events, dev_changed, check, ai_exit) =
                feature_profiler::measure(Feature::AiDetect, output.len(), || {
                    self.monitor.output(&output, now)
                });
            for event in events {
                self.emit_ai(shell_ai_event(event), true, cx);
            }
            if let Some(check) = check {
                self.schedule_dev_check(check, cx);
            }
            metadata_changed |= dev_changed;
            if let Some(code) = ai_exit {
                self.finish_ai_run(Some(code), cx);
            }
            // Remote control: the selected tab's output goes to the phone.
            feature_profiler::measure(Feature::RemoteOutput, output.len(), || {
                crate::remote::record_output(self.id, &output, cx);
            });
            // Smart scroll off: new output brings the view back down.
            if !Settings::get(cx).terminal.smart_scroll
                && (display_offset_before > 0 || self.grid.display_offset > 0)
            {
                self.scroll_to_bottom();
                self.grid = self.term.read().grid_copy();
            }
        }
        metadata_changed |= self.drain_tracker_events(cx);
        if !output.is_empty() {
            metadata_changed |= self.handle_osc9(&output, cx);
            crate::telemetry::note_output(&self.tab_identifier, &output, cx);
        }

        if bell {
            self.ring_bell(cx);
        }
        if let Some(text) = clipboard {
            cx.emit(SessionEvent::ClipboardStore(text));
        }
        if clipboard_load {
            cx.emit(SessionEvent::ClipboardLoad);
        }
        if closed && self.exited.is_none() {
            let code = self.term.read().try_child_exit_code();
            self.exited = Some(code);
            self.process_subscription.take();
            self.tracker.update_live_agent(None);
            self.tracker.mark_exited();
            self.tracker.take_events();
            self.command_running = false;
            unregister_shell(self.id);
            self.finish_ai_run(None, cx);
            self.dev_checks = None;
            self.monitor.dev_server.stop();
            if !self.close_requested {
                match code {
                    Some(code) => log::info!("Shell exited with code {code}."),
                    None => log::info!("Shell exited."),
                }
                // `handleProcessTermination`: recorded and notified.
                let (kind, message) = match code {
                    Some(code) => (
                        if code == 0 { "finished" } else { "failed" },
                        format!("Shell exited with code {code}."),
                    ),
                    None => ("failed", "Shell exited.".to_string()),
                };
                let mut event = AiEvent::new(
                    AiEventSource::terminal_session(),
                    kind,
                    "Shell",
                    message,
                    chau7_next_core::iso8601::now_iso8601(),
                );
                event.directory = Some(self.tracker.current_directory().to_string());
                cx.emit(SessionEvent::Ai {
                    event: Box::new(event),
                    notify: true,
                    tab_name_as_tool: true,
                });
            }
            cx.emit(SessionEvent::Exited(code));
            metadata_changed = true;
        }
        if metadata_changed {
            cx.emit(SessionEvent::MetadataChanged);
        }
        self.memory.set_tui(self.is_ai_running());
        cx.emit(SessionEvent::Output);
        cx.notify();
        feature_profiler::record(
            Feature::OutputProcessing,
            started.elapsed().as_secs_f64() * 1000.0,
            output.len(),
        );
    }

    fn process_pending_input(&mut self, now: f64) {
        let pending = std::mem::take(&mut *self.pending_input.borrow_mut());
        for (bytes, echo_disabled) in pending {
            let text = String::from_utf8_lossy(&bytes);
            self.monitor.ai_log.input(
                &chau7_next_core::shell_session::sanitize_input_for_buffer(&text),
                echo_disabled,
            );
            self.tracker
                .handle_input(&text, echo_disabled, &self.shell_context, now);
        }
    }

    fn handle_agent_feedback(&mut self, event: &AiEvent, cx: &mut Context<Self>) {
        let Some(provider) = chau7_next_core::ai::resume::normalize_provider_name(&event.tool)
            .or_else(|| {
                chau7_next_core::ai::resume::normalize_provider_name(event.source.raw_value())
            })
        else {
            return;
        };
        let Some(date) = chau7_next_core::telemetry::date_codec::parse_iso8601(Some(&event.ts))
        else {
            return;
        };
        if self.tracker.apply_agent_feedback(
            feedback_kind(event).unwrap_or(&event.event_type),
            &provider,
            event.session_id.as_deref(),
            date.timestamp_millis() as f64 / 1000.0,
        ) {
            self.drain_tracker_events(cx);
            cx.notify();
        }
    }

    /// Apply the tracker's events. Returns true when metadata changed.
    fn drain_tracker_events(&mut self, cx: &mut Context<Self>) -> bool {
        let mut changed = false;
        for event in self.tracker.take_events() {
            match event {
                ShellSessionEvent::StatusChanged(status) => {
                    let mut event = chau7_next_core::events::StructuralEvent::new(
                        "terminal_status_changed",
                        "terminal",
                    );
                    event.session_id = self.tracker.ai_session_id().map(str::to_string);
                    event.repo_path = self
                        .git_root
                        .as_ref()
                        .map(|path| path.to_string_lossy().into_owned());
                    event.detail.insert(
                        "terminal_session_id".into(),
                        serde_json::json!(self.tab_identifier),
                    );
                    event
                        .detail
                        .insert("status".into(), serde_json::json!(status.as_str()));
                    crate::observability::record(event, cx);

                    self.command_running = matches!(
                        status,
                        CommandStatus::Running
                            | CommandStatus::Stuck
                            | CommandStatus::WaitingForInput
                            | CommandStatus::ApprovalRequired
                    );
                    changed = true;
                }
                ShellSessionEvent::CommandStarted {
                    command,
                    directory,
                    from_shell_integration,
                } => {
                    if self.is_restore_command(command.as_deref()) {
                        continue;
                    }
                    self.command_dir = Some(directory.clone());
                    if from_shell_integration {
                        crate::history::recorder::command_start(
                            self.id,
                            command.as_deref().unwrap_or_default(),
                        );
                    }
                    if from_shell_integration && self.git_root.is_some() {
                        let baseline = self.git_baseline.clone();
                        let directory = directory.clone();
                        cx.background_spawn(async move {
                            *baseline.lock() = Some(git_dirty_files(&directory));
                        })
                        .detach();
                    }
                    if let Some(command) = command.as_deref().filter(|c| !c.trim().is_empty()) {
                        cx.emit(SessionEvent::CommandStarted(command.to_string()));
                    }
                    let events = self.monitor.shell_events.command_started(
                        command.as_deref(),
                        &directory,
                        now_secs(),
                    );
                    for event in events {
                        self.emit_ai(shell_ai_event(event), true, cx);
                    }
                    if let Some(check) = command
                        .as_deref()
                        .and_then(|c| self.monitor.command_typed(c))
                    {
                        self.schedule_dev_check(check, cx);
                    }
                }
                ShellSessionEvent::CommandFinished {
                    command,
                    exit_code,
                    duration,
                    from_shell_integration,
                } => {
                    if self.is_restore_command(command.as_deref()) {
                        self.restore_line_pending = false;
                        self.tracker
                            .blocks_mut()
                            .remove_where(chau7_next_core::session_restore::is_restore_line);
                        continue;
                    }
                    crate::history::recorder::command_end(self.id, exit_code);
                    if let Some(command) = command.as_deref() {
                        let directory = self
                            .command_dir
                            .take()
                            .unwrap_or_else(|| self.tracker.current_directory().to_string());
                        crate::history::record_command(
                            command,
                            Some(&directory),
                            exit_code,
                            duration,
                            self.shell_name.as_deref(),
                            &self.id.to_string(),
                            cx,
                        );
                    }
                    let events = self
                        .monitor
                        .shell_events
                        .command_finished(exit_code, command.as_deref());
                    for event in events {
                        self.emit_ai(shell_ai_event(event), true, cx);
                    }
                    if let Some(check) = self.monitor.dev_server.command_did_finish() {
                        self.schedule_dev_check(check, cx);
                    }
                    if let Some(code) = exit_code {
                        if code != 0 {
                            crate::permission_center::report_command_denial(
                                code,
                                &self.permission_output_tail.text(),
                                self.tracker.current_directory(),
                                cx,
                            );
                        }
                        self.last_command = Some(LastCommand {
                            exit_code: code,
                            duration: Duration::from_secs_f64(duration.max(0.0)),
                        });
                        changed = true;
                        cx.emit(SessionEvent::CommandFinished(code));
                    }
                    if from_shell_integration && self.git_root.is_some() {
                        self.collect_changed_files(cx);
                    }
                }
                ShellSessionEvent::ActiveAppChanged(app) => {
                    match &app {
                        Some(tool) => {
                            log::info!("AI detected: {tool}");
                            let command = self.tracker.pending_command().map(str::to_string);
                            self.start_ai_run(tool, command.as_deref(), cx);
                            if command
                                .as_deref()
                                .is_some_and(|line| !line.trim().is_empty())
                            {
                                crate::telemetry::note_prompt(&self.tab_identifier, cx);
                            }
                        }
                        None => self.finish_ai_run(None, cx),
                    }
                    // The token optimizer follows AI tools (AI Only mode).
                    self.sync_cto_state();
                    self.ai_app = app;
                    changed = true;
                }
                ShellSessionEvent::DirectoryChanged(path) => {
                    let events = self.monitor.shell_events.directory_changed(&path);
                    for event in events {
                        self.emit_ai(shell_ai_event(event), true, cx);
                    }
                    let path = PathBuf::from(path);
                    self.set_cwd(path.clone());
                    cx.emit(SessionEvent::DirectoryChanged(path));
                    changed = true;
                }
                ShellSessionEvent::HistoryLine { command, sensitive } => {
                    if !sensitive && !command.trim().is_empty() {
                        crate::telemetry::note_prompt(&self.tab_identifier, cx);
                    }
                    log::debug!(
                        "session {}: typed line ({} chars, sensitive={sensitive})",
                        self.id,
                        command.chars().count()
                    );
                    let tab = self.id.to_string();
                    cx.default_global::<SharedCommandHistory>()
                        .0
                        .record(&command, &tab, sensitive);
                }
                ShellSessionEvent::PermissionResolved => {
                    cx.emit(SessionEvent::PermissionResolved);
                }
                ShellSessionEvent::WaitingInputFallback { tool, provider } => {
                    self.emit_waiting_input(&tool, &provider, cx);
                    cx.emit(SessionEvent::WaitingInput { tool });
                }
            }
        }
        changed
    }

    fn collect_changed_files(&mut self, cx: &mut Context<Self>) {
        let directory = self.tracker.current_directory().to_string();
        let baseline = self.git_baseline.lock().take();
        let task = cx.background_spawn(async move {
            let current = git_dirty_files(&directory);
            git_changes::changed_files(baseline.as_ref(), &current)
        });
        cx.spawn(async move |this, cx| {
            let files = task.await;
            if files.is_empty() {
                return;
            }
            let _ = this.update(cx, |this, cx| {
                this.tracker.blocks_mut().set_changed_files(files.clone());
                cx.emit(SessionEvent::ChangedFiles(files));
                cx.notify();
            });
        })
        .detach();
    }

    /// Once a second.
    fn tick(&mut self, cx: &mut Context<Self>) {
        let mut wake = work_profiler::begin(WorkKey::wakeup(
            "session_timer",
            self.profiling_phase(),
            WorkQueue::Main,
        ));
        wake.idle(self.last_activity.elapsed() >= Duration::from_secs(1));
        if self.exited.is_some() {
            return;
        }
        let mut changed = self.retry_resize();
        self.process_pending_input(now_secs());
        self.tracker.tick(now_secs());
        // TEL-003: a resume command named the AI session.
        if self.ai_app.is_some()
            && let Some(session) = self.tracker.ai_session_id()
        {
            crate::telemetry::update_session_id(&self.tab_identifier, session, cx);
        }
        if !self.first_output
            && !self.shell_slow
            && self.term.read().has_pty()
            && self.started_at.elapsed() >= STARTUP_SLOW_AFTER
        {
            log::warn!(
                "session {}: no PTY output after 5s, shell may be hung",
                self.id
            );
            self.shell_slow = true;
            changed = true;
        }
        // Without OSC 7 (shells without our hooks), read the directory from
        // the process table.
        if !self.tracker.saw_osc7() && self.last_cwd_check.elapsed() > Duration::from_millis(500) {
            self.last_cwd_check = Instant::now();
            changed |= self.update_cwd();
        }
        // The branch can change without a cd (git checkout): re-read HEAD.
        if self.last_branch_check.elapsed() >= Duration::from_secs(2) {
            self.last_branch_check = Instant::now();
            // Tabs in one repository share one branch value.
            let branch = match self.git_root.as_deref() {
                Some(root) => match crate::repository::resolve(root, cx) {
                    Some(shared) => crate::repository::branch(&shared, cx),
                    None => None,
                },
                None => None,
            };
            if branch != self.git_branch {
                log::info!(
                    "session {}: git branch {:?} -> {:?}",
                    self.id,
                    self.git_branch,
                    branch
                );
                let events = self
                    .monitor
                    .shell_events
                    .git_branch_changed(branch.as_deref());
                for event in events {
                    self.emit_ai(shell_ai_event(event), true, cx);
                }
                self.git_branch = branch;
                changed = true;
            }
        }
        if self.monitor.shell_events.is_timing() {
            let events = self.monitor.shell_events.check_long_running(now_secs());
            for event in events {
                self.emit_ai(shell_ai_event(event), true, cx);
            }
        }
        changed |= self.drain_tracker_events(cx);
        self.flush_restored_resume(cx);
        if self.pending_prefill.is_some() && !self.prefill_scheduled {
            self.flush_prefill(cx);
        }
        if changed {
            cx.emit(SessionEvent::MetadataChanged);
            cx.notify();
        }
    }

    fn handle_osc9(&mut self, output: &[u8], cx: &mut Context<Self>) -> bool {
        use chau7_next_core::osc9::Event;
        let mut changed = false;
        for event in self.osc9.ingest(output) {
            match event {
                Event::Chau7 { key, value } => match key.as_str() {
                    "exit" => {
                        if let Ok(code) = value.parse::<i32>() {
                            self.last_prompt_exit_code = Some(code);
                            self.last_prompt_exit_at = Some(Instant::now());
                            changed = true;
                        }
                    }
                    "repo-root" => {
                        let previous = self.git_root.as_deref().map(|root| root.to_string_lossy());
                        let normalized = Path::new(value.trim())
                            .is_absolute()
                            .then(|| {
                                chau7_next_core::repository::known_identity::normalize_root(
                                    value.trim(),
                                )
                            })
                            .flatten();
                        if let Some(root) = normalized {
                            let branch = if previous.as_deref().is_none_or(|old| old == root) {
                                self.git_branch.clone()
                            } else {
                                None
                            };
                            if let Some(root) =
                                crate::repository::report_shell_root(&root, branch.as_deref(), cx)
                            {
                                changed |= self.git_root.as_deref() != Some(Path::new(&root));
                                self.git_root = Some(root.into());
                                changed |= self.adopt_reported_branch(branch, cx);
                            }
                        }
                    }
                    "branch" => {
                        let branch =
                            chau7_next_core::repository::known_identity::branch_name(Some(&value));
                        if let Some(root) = &self.git_root {
                            crate::repository::report_shell_root(
                                &root.to_string_lossy(),
                                Some(&value),
                                cx,
                            );
                        }
                        changed |= self.adopt_reported_branch(branch, cx);
                    }
                    _ => {}
                },
                Event::Foreign { message } => {
                    let provider = self.tracker.effective_provider();
                    if let Some(event) = chau7_next_core::osc9::foreign_event(
                        &message,
                        provider.as_deref(),
                        self.ai_app.as_deref().or(self.tracker.active_app()),
                        self.tracker.current_directory(),
                        self.tracker.ai_session_id(),
                        &chau7_next_core::iso8601::now_iso8601(),
                    ) {
                        self.emit_ai(event, true, cx);
                    }
                }
            }
        }
        if changed {
            self.sync_cto_state();
        }
        changed
    }

    fn sync_cto_state(&self) {
        crate::cto::set_session_state(
            &self.cto_id,
            self.is_ai_running(),
            self.tracker.effective_provider(),
            self.tracker.ai_session_id().map(str::to_string),
        );
    }

    fn adopt_reported_branch(&mut self, branch: Option<String>, cx: &mut Context<Self>) -> bool {
        if self.git_branch == branch {
            return false;
        }
        let events = self
            .monitor
            .shell_events
            .git_branch_changed(branch.as_deref());
        self.git_branch = branch;
        for event in events {
            self.emit_ai(shell_ai_event(event), true, cx);
        }
        true
    }

    fn emit_ai(&self, event: AiEvent, notify: bool, cx: &mut Context<Self>) {
        cx.emit(SessionEvent::Ai {
            event: Box::new(event),
            notify,
            tab_name_as_tool: false,
        });
    }

    /// `emitWaitingInputFallbackIfNeeded`: "<tool> is waiting for your
    /// input in <project>".
    fn emit_waiting_input(&self, tool: &str, provider: &str, cx: &mut Context<Self>) {
        let Some(source) = AiEventSource::for_provider(Some(provider)) else {
            return;
        };
        let directory = self.tracker.current_directory().to_string();
        let project = directory
            .trim_end_matches('/')
            .rsplit('/')
            .next()
            .unwrap_or_default()
            .to_string();
        let location = if project.is_empty() {
            "this tab".to_string()
        } else {
            project
        };
        let mut event = AiEvent::new(
            source,
            "waiting_input",
            tool,
            format!("{tool} is waiting for your input in {location}"),
            chau7_next_core::iso8601::now_iso8601(),
        );
        event.directory = Some(directory);
        event.session_id = self.tracker.ai_session_id().map(str::to_string);
        event.producer = Some("terminal_prompt_waiting_input".into());
        event.reliability = AiEventReliability::Fallback;
        self.emit_ai(event, true, cx);
    }

    /// The dev server running in this session (`devServer`).
    pub fn dev_server(&self) -> Option<&DevServerInfo> {
        self.monitor.dev_server()
    }

    /// TRM-046: an AI CLI was detected (by command or output): its PTY log
    /// and its telemetry run start.
    fn start_ai_run(&mut self, tool: &str, command: Option<&str>, cx: &mut Context<Self>) {
        self.monitor.ai_log.start(tool, command);
        let repo = self
            .git_root
            .as_ref()
            .map(|p| p.to_string_lossy().into_owned());
        crate::telemetry::run_started(
            &self.tab_identifier,
            tool,
            self.tracker.current_directory(),
            repo.as_deref(),
            self.tracker.ai_session_id(),
            cx,
        );
        crate::telemetry::register_live_log(
            &self.tab_identifier,
            self.monitor.ai_log.last_log_path.clone(),
            cx,
        );
    }

    /// TRM-046: the AI CLI exited (`finishAILogging`): the run ends with the
    /// PTY log and the terminal text as fallback transcripts.
    fn finish_ai_run(&mut self, exit_code: Option<i32>, cx: &mut Context<Self>) {
        self.monitor.ai_log.finish(exit_code);
        let running = crate::telemetry::recorder(cx)
            .is_some_and(|r| r.active_run_for_tab(&self.tab_identifier).is_some());
        if !running {
            return;
        }
        let pty_log = self.monitor.ai_log.last_log_path.clone();
        let buffer = self.buffer_text();
        crate::telemetry::run_ended(
            &self.tab_identifier,
            exit_code,
            self.tracker.ai_session_id(),
            Some(buffer),
            pty_log,
            cx,
        );
    }

    /// A worker receives only the native terminal handle, never this GPUI entity.
    pub(crate) fn remote_terminal(&self) -> Arc<RwLock<Chau7Terminal>> {
        self.term.clone()
    }

    /// PTY log of the current or last AI run (`lastPTYLogPath`).
    #[allow(dead_code)]
    pub fn last_ai_log_path(&self) -> Option<&Path> {
        self.monitor.ai_log.last_log_path.as_deref()
    }

    /// Port checks (`startBurstCheck`, `scheduleOneShot`).
    fn schedule_dev_check(&mut self, request: CheckRequest, cx: &mut Context<Self>) {
        let pid = self.term.read().shell_pid() as u32;
        if pid == 0 || self.exited.is_some() {
            return;
        }
        let (first, count) = match request {
            CheckRequest::Burst => (BURST_FIRST_DELAY, BURST_CHECKS),
            CheckRequest::Once(delay) => (delay, 1),
        };
        self.dev_checks = Some(cx.spawn(async move |this, cx| {
            let mut delay = first;
            for remaining in (0..count).rev() {
                cx.background_executor()
                    .timer(Duration::from_secs_f64(delay))
                    .await;
                delay = BURST_INTERVAL;
                let (descendants, listening) = cx
                    .background_executor()
                    .spawn(async move {
                        let descendants: Vec<u32> =
                            procinfo::process_tree(pid).into_iter().skip(1).collect();
                        let listening = procinfo::listening_port(&descendants).map(|(p, port)| {
                            let name = procinfo::process_name(p).unwrap_or_default();
                            (p, port, name)
                        });
                        (descendants, listening)
                    })
                    .await;
                let stop = this
                    .update(cx, |this, cx| {
                        if this.monitor.dev_server.apply_check(&descendants, listening) {
                            if let Some(server) = this.monitor.dev_server() {
                                log::info!(
                                    "session {}: dev server {} port {:?}",
                                    this.id,
                                    server.name,
                                    server.port
                                );
                            }
                            cx.emit(SessionEvent::MetadataChanged);
                            cx.notify();
                        }
                        should_stop_burst_checks(this.monitor.dev_server(), remaining)
                    })
                    .unwrap_or(true);
                if stop {
                    break;
                }
            }
        }));
    }

    /// Direct emulator replay never sends a restore command to the PTY. The
    /// outer write guard prevents the poll worker from parsing between capture
    /// and replay, preserving the newly launched shell's prompt/output.
    pub(crate) fn replay_restored_context(&mut self, context: &str, cx: &mut Context<Self>) {
        let term = self.term.write();
        replay_restored_terminal(&term, context);
        self.grid = term.grid_copy();
        self.cursor = term.cursor_position();
        drop(term);
        cx.emit(SessionEvent::Output);
        cx.notify();
    }
    pub(crate) fn queue_restored_resume(
        &mut self,
        command: String,
        directory: PathBuf,
        identity: chau7_next_core::session_restore::lifecycle::ResumeIdentity,
        cx: &mut Context<Self>,
    ) {
        self.restore_token = self.restore_token.wrapping_add(1);
        self.restore_intent = Some(
            chau7_next_core::session_restore::lifecycle::RestorePrefillIntent {
                token: self.restore_token,
                command,
                expected_directory: directory,
                expected_identity: identity,
                // The shell was just constructed. Input typed while background
                // restore validation/first-frame preparation ran cancels delivery.
                input_generation: 0,
            },
        );
        self.flush_restored_resume(cx);
    }
    pub(crate) fn set_restore_selected(&self, selected: bool) {
        self.restore_selected.set(selected);
        if selected {
            let mut prewarm = self.surface_prewarm.get();
            prewarm.clear();
            self.surface_prewarm.set(prewarm);
        }
        self.sync_surface_clock();
    }
    pub(crate) fn mark_restore_surface(&self, visible: bool) {
        self.restore_window_visible.set(visible);
        self.sync_surface_clock();
    }
    fn sync_surface_clock(&self) {
        if self.restore_surface_visible() {
            self.restore_hidden_since.set(None);
        } else if self.restore_hidden_since.get().is_none() {
            self.restore_hidden_since.set(Some(Instant::now()));
        }
    }
    pub(crate) fn prewarm_surface(&mut self, hovered: bool, cx: &mut Context<Self>) {
        if self.restore_selected.get() {
            return;
        }
        let mut prewarm = self.surface_prewarm.get();
        let refresh = if hovered {
            prewarm.begin(Instant::now())
        } else {
            prewarm.end(Instant::now());
            false
        };
        self.surface_prewarm.set(prewarm);
        self.set_render_suspended(false);
        if refresh {
            self.refresh(cx);
        }
    }
    pub(crate) fn surface_prewarm_remaining(&self) -> Option<Duration> {
        self.surface_prewarm.get().remaining(Instant::now())
    }
    pub(crate) fn surface_hidden_for(&self) -> Option<Duration> {
        self.restore_hidden_since.get().map(|at| at.elapsed())
    }
    pub(crate) fn restore_surface_visible(&self) -> bool {
        self.restore_selected.get() && self.restore_window_visible.get()
    }
    pub(crate) fn mark_restore_presented(&self) {
        self.restore_presented.set(true);
    }
    pub(crate) fn surface_has_live_frame(&self) -> bool {
        self.restore_presented.get()
    }
    pub(crate) fn request_surface_frame(&self) {
        self.restore_presented.set(false);
    }

    fn flush_restored_resume(&mut self, _cx: &mut Context<Self>) {
        use chau7_next_core::session_restore::lifecycle::{PrefillDecision, PrefillSnapshot};
        let Some(intent) = self.restore_intent.as_ref() else {
            return;
        };
        let snapshot = PrefillSnapshot {
            current_token: self.restore_token,
            directory: self.cwd.clone().unwrap_or_default(),
            provider: self.tracker.ai_provider().map(str::to_owned),
            session_id: self.tracker.ai_session_id().map(str::to_owned),
            input_generation: self.restore_input_generation.get(),
            view_presented: self.restore_presented.get(),
            surface_visible: self.restore_surface_visible(),
            at_prompt: self.is_at_prompt(),
            loading: self.is_loading(),
            ai_running: self.is_ai_running(),
            exited: self.exited.is_some(),
        };
        match intent.decision(&snapshot) {
            PrefillDecision::Wait => {}
            PrefillDecision::Reject(reason) => {
                self.restore_intent = None;
                // Outcomes only: no command, path, transcript or credential.
                log::info!("restore resume rejected: {reason:?}");
            }
            PrefillDecision::Deliver => {
                if let Some(intent) = self.restore_intent.take() {
                    self.write(intent.command.as_bytes()); // Deliberately no CR/LF.
                    log::info!("restore resume prefilled");
                }
            }
        }
    }

    /// Types `text` (without running it) once the shell shows its prompt
    /// (`prefillInput`).
    pub fn prefill_input(&mut self, text: String, cx: &mut Context<Self>) {
        if text.is_empty() {
            return;
        }
        self.tracker.track_resume_metadata(&text);
        self.tracker.prefill_pending = true;
        self.pending_prefill = Some(text);
        self.prefill_retries = 0;
        self.flush_prefill(cx);
    }

    /// `flushPendingPrefillInputIfReady`: retried up to 20 times, 0.3 s more
    /// each time (3 s at most); after 4 tries the shell counts as started.
    fn flush_prefill(&mut self, cx: &mut Context<Self>) {
        self.prefill_scheduled = false;
        let Some(text) = self.pending_prefill.clone() else {
            self.prefill_retries = 0;
            return;
        };
        if self.exited.is_some() {
            self.pending_prefill = None;
            self.tracker.prefill_pending = false;
            return;
        }
        let forced = self.prefill_retries >= shell_restore::PREFILL_FORCE_READY_AFTER;
        let loading = self.is_loading() && !forced;
        let at_prompt = self.tracker.is_at_prompt() || (forced && !self.has_hooks);
        if !loading && at_prompt {
            self.pending_prefill = None;
            self.prefill_retries = 0;
            self.tracker.prefill_pending = false;
            log::info!(
                "Resume prefill delivered: {}",
                text.chars().take(60).collect::<String>()
            );
            self.write(text.as_bytes());
            return;
        }
        if self.prefill_retries >= shell_restore::PREFILL_MAX_RETRIES {
            // Wait for the next prompt (the tick tries again).
            self.prefill_retries = 0;
            return;
        }
        self.prefill_retries += 1;
        self.prefill_scheduled = true;
        let delay = Duration::from_secs_f64(shell_restore::prefill_retry_delay_secs(
            self.prefill_retries,
        ));
        cx.spawn(async move |this, cx| {
            cx.background_executor().timer(delay).await;
            let _ = this.update(cx, |this, cx| this.flush_prefill(cx));
        })
        .detach();
    }

    fn set_cwd(&mut self, cwd: PathBuf) {
        if self.cwd.as_ref() == Some(&cwd) {
            return;
        }
        self.git_root = procinfo::git_root(&cwd);
        self.git_branch = None;
        // New directory: reconcile on the next existing monitor tick, off UI.
        self.last_branch_check = Instant::now()
            .checked_sub(Duration::from_secs(2))
            .unwrap_or_else(Instant::now);
        self.cwd = Some(cwd);
    }

    /// Re-read the shell's directory from the process table. Returns true
    /// when it changed.
    pub fn update_cwd(&mut self) -> bool {
        let pid = self.term.read().shell_pid() as u32;
        let Some(cwd) = procinfo::process_cwd(pid) else {
            return false;
        };
        let path = cwd.to_string_lossy().to_string();
        if self.tracker.update_directory(&path, &self.shell_context) {
            // The tracker's DirectoryChanged event is applied on the next drain.
            self.set_cwd(cwd);
            return true;
        }
        false
    }

    fn ring_bell(&mut self, cx: &mut Context<Self>) {
        let settings = &Settings::get(cx).terminal;
        if !settings.bell_enabled {
            return;
        }
        match settings.bell_sound {
            BellSound::Visual => {
                self.bell_flash_until = Some(Instant::now() + BELL_FLASH);
                cx.spawn(async move |this, cx| {
                    cx.background_executor().timer(BELL_FLASH).await;
                    let _ = this.update(cx, |this, cx| {
                        this.bell_flash_until = None;
                        cx.emit(SessionEvent::MetadataChanged);
                        cx.notify();
                    });
                })
                .detach();
            }
            BellSound::Subtle => {
                if crate::platform::sound::play_named("Pop", 1.0).is_err() {
                    crate::platform::sound::beep();
                }
            }
            BellSound::Default => crate::platform::sound::beep(),
        }
        cx.emit(SessionEvent::Bell);
    }

    /// A frame of this session was drawn: closes the output latency measure
    /// (`recordOutputLatencyIfNeeded`, TRM-062).
    pub fn mark_frame_drawn(&self) {
        let spike = self
            .latency
            .borrow_mut()
            .mark_rendered(clock(Instant::now()));
        if let Some(spike) = spike {
            self.log_lag(&spike);
        }
    }

    /// A dangerous-output highlight pass ran `congestion_ms` after it was
    /// due (`dangerousHighlightDelayMs`, TRM-062).
    pub fn record_highlight_latency(&self, congestion_ms: f64) {
        let spike = self
            .latency
            .borrow_mut()
            .record_highlight(congestion_ms, clock(Instant::now()));
        if let Some(spike) = spike {
            self.log_lag(&spike);
        }
    }

    /// Input and output lag (average, else last) for `isCpuSaturated`.
    pub fn ui_lag_ms(&self) -> (Option<i64>, Option<i64>) {
        let latency = self.latency.borrow();
        (
            latency.lag_ms(chau7_next_core::shell_latency::LagKind::Input),
            latency.lag_ms(chau7_next_core::shell_latency::LagKind::Output),
        )
    }

    fn log_lag(&self, spike: &LagEvent) {
        log::warn!(
            "Latency spike: {}={}ms avg={}ms p50/p95={:?}/{:?} n={} session={} app={}",
            spike.kind.as_str(),
            spike.elapsed_ms,
            spike.average_ms,
            spike.p50,
            spike.p95,
            spike.sample_count,
            self.id,
            self.ai_app.as_deref().unwrap_or("shell"),
        );
    }

    /// Bookmarks the line at the top of the view (TRM-057). `max` is the
    /// per-tab limit (`feature.maxBookmarks`).
    pub fn add_bookmark(&mut self, label: Option<String>, max: usize) -> u64 {
        let history = self.grid.scrollback_rows as i64;
        let offset = self.grid.display_offset as i64;
        let line = shell_bookmarks::top_line(history, offset);
        let preview = self.line_text(-(offset as i32)).unwrap_or_default();
        self.bookmarks.add(line, &preview, label, max, now_secs())
    }

    pub fn bookmarks(&self) -> &[Bookmark] {
        self.bookmarks.all()
    }

    pub fn remove_bookmark(&mut self, id: u64) {
        self.bookmarks.remove(id);
    }

    /// Scrolls back to a bookmark.
    pub fn jump_to_bookmark(&mut self, id: u64, cx: &mut Context<Self>) {
        let Some(line) = self.bookmarks.get(id).map(|b| b.line) else {
            return;
        };
        let term = self.term.read();
        let history = self.grid.scrollback_rows as i64;
        let target = shell_bookmarks::display_offset_for(line, history);
        let current = term.display_offset() as i64;
        term.scroll_lines((target - current) as i32);
        drop(term);
        self.refresh(cx);
    }

    /// Text of the last finished command (hover card, Debug Console).
    pub fn last_command_text(&self) -> Option<String> {
        self.tracker
            .blocks()
            .blocks()
            .iter()
            .rev()
            .find(|b| !b.is_running())
            .map(|b| b.command.clone())
            .filter(|c| !c.trim().is_empty())
    }

    /// The shell loads our startup files (OSC 133 marks): the Debug Console
    /// Health tab counts these tabs.
    pub fn has_shell_integration(&self) -> bool {
        self.has_hooks
    }

    /// (dev) Forget the lag timeline (Debug Console, Lag tab, Clear).
    pub fn clear_lag_timeline(&self) {
        self.latency.borrow_mut().clear_timeline();
    }

    /// (dev) Latency samples and lag timeline (TRM-062), for the debug console.
    pub fn latency(&self) -> std::cell::Ref<'_, LatencyTracker> {
        self.latency.borrow()
    }

    /// Strength of the visual bell flash now, 0 to 1 (fades out).
    pub fn bell_flash_alpha(&self) -> f32 {
        let Some(until) = self.bell_flash_until else {
            return 0.0;
        };
        let now = Instant::now();
        if now >= until {
            return 0.0;
        }
        let left = (until - now).as_secs_f32() / BELL_FLASH.as_secs_f32();
        left.clamp(0.0, 1.0)
    }

    /// Raw bytes for the program (key and mouse reports, replies). Written
    /// in order on the writer thread.
    pub fn write(&self, bytes: &[u8]) {
        if !bytes.is_empty() {
            self.poll_interrupt.wake();
        }
        self.writer.write(bytes.to_vec());
    }

    /// The session restore line (`session_restore::restore_input`): written
    /// like [`Self::write`], and the command it runs is kept out of the
    /// command results, so a restored tab does not show "success".
    pub fn write_restore_line(&mut self, line: &str) {
        self.restore_line_pending = true;
        self.write(line.as_bytes());
    }

    /// True when a command event belongs to the restore line.
    fn is_restore_command(&self, command: Option<&str>) -> bool {
        self.restore_line_pending
            && command.is_none_or(chau7_next_core::session_restore::is_restore_line)
    }

    /// Bytes typed or pasted by the user: written like [`Self::write`] and
    /// given to the command tracker (typed lines, history, AI detection).
    /// Immediate user-input revision; independent of delayed tracker processing.
    pub fn input_revision(&self) -> u64 {
        self.restore_input_generation.get()
    }

    /// Rebuild the current line from cached tracker state and not-yet-processed
    /// user fragments. No PTY read or native process scan runs here.
    pub fn reviewed_input_prefix(&self) -> String {
        let pending = self.pending_input.borrow();
        chau7_next_core::command_risk::admission::pending_prefix(
            self.tracker.pending_input_text(),
            pending
                .iter()
                .filter(|(_, secret)| !secret)
                .map(|(bytes, _)| String::from_utf8_lossy(bytes)),
        )
    }

    pub fn write_input(&self, bytes: &[u8]) {
        if bytes.is_empty() {
            return;
        }
        self.restore_input_generation
            .set(self.restore_input_generation.get().wrapping_add(1));
        // Password prompts only: Swift checks ECHO alone, which line editors
        // (readline, ZLE) also clear, so every typed command looked secret.
        let echo_disabled = Chau7Terminal::password_input_on_fd(self.echo_fd);
        self.latency.borrow_mut().mark_input(clock(Instant::now()));
        if !echo_disabled {
            crate::history::recorder::input(self.id, bytes);
        }
        self.pending_input
            .borrow_mut()
            .push((bytes.to_vec(), echo_disabled));
        self.write(bytes);
    }

    /// Text shown in the terminal without going through the PTY
    /// (`injectOutput`, RBK-053).
    pub fn inject_output(&self, text: &str) {
        self.term.read().inject_output(text.as_bytes());
    }

    /// Answer an OSC 52 clipboard read (RBK-012).
    pub fn has_pending_clipboard_response(&self) -> bool {
        self.writer.has_pending_clipboard_response()
    }
    pub fn respond_clipboard(&self, text: &str) {
        self.writer.respond_clipboard(text);
    }

    pub fn resize(&mut self, cols: u16, rows: u16) {
        let cols = cols.max(2);
        let rows = rows.max(1);
        if self.grid.cols == cols && self.grid.rows == rows && self.pending_resize.is_none() {
            return;
        }
        self.pending_resize = Some((cols, rows));
        crate::history::recorder::resize(self.id, cols, rows);
        self.retry_resize();
    }

    /// Applies a pending resize. Waits at most 50 ms for the terminal lock
    /// (a blocked input write could hold it) and retries on the next refresh.
    fn retry_resize(&mut self) -> bool {
        let Some((cols, rows)) = self.pending_resize else {
            return false;
        };
        let Some(term) = self.term.try_write_for(Duration::from_millis(50)) else {
            return false;
        };
        term.resize(cols, rows);
        drop(term);
        self.pending_resize = None;
        self.grid = self.term.read().grid_copy();
        true
    }

    pub fn scroll_lines(&self, lines: i32) {
        self.term.read().scroll_lines(lines);
    }

    pub fn scroll_to_bottom(&self) {
        let term = self.term.read();
        if term.display_offset() > 0 {
            term.scroll_to(0.0);
        }
    }

    /// Top of the scrollback (RBK-026).
    pub fn scroll_to_top(&self) {
        self.term.read().scroll_to(1.0);
    }

    pub fn selection_start(&self, col: i32, row: i32, kind: SelectionKind) {
        self.term.read().selection_start(col, row, kind as u8);
    }

    pub fn selection_update(&self, col: i32, row: i32) {
        self.term.read().selection_update(col, row);
    }

    pub fn selection_clear(&self) {
        self.term.read().selection_clear();
    }

    pub fn select_all(&self) {
        self.term.read().selection_all();
    }

    pub fn selection_text(&self) -> Option<String> {
        clipboard_selection(&self.term.read(), self.tracker.is_ai_running())
    }

    pub fn clear_scrollback(&self) {
        self.term.read().clear_scrollback();
    }

    pub fn is_bracketed_paste(&self) -> bool {
        self.term.read().is_bracketed_paste_mode()
    }

    pub fn is_app_cursor(&self) -> bool {
        self.term.read().is_application_cursor_mode()
    }

    pub fn mouse_reporting(&self) -> bool {
        self.mouse_reporting_enabled.get() && self.term.read().is_mouse_reporting_active()
    }

    /// `Chau7Terminal::mouse_mode` bits (see `key_encoding::mouse_mode`).
    /// The click, drag and motion bits are cleared when mouse reporting is
    /// turned off in settings.
    pub fn mouse_mode(&self) -> u32 {
        let mode = self.term.read().mouse_mode();
        if self.mouse_reporting_enabled.get() {
            mode
        } else {
            mode & !0b111
        }
    }

    pub fn link_url(&self, link_id: u16) -> Option<String> {
        self.term.read().get_link_url(link_id)
    }

    /// Text of one grid line (negative values are scrollback).
    pub fn line_text(&self, line: i32) -> Option<String> {
        self.term.read().line_text(line)
    }

    /// The soft-wrapped logical line holding a grid row: its text and the
    /// UTF-16 offset of `column` in it (`RustTerminalView.getClickableLineHit`).
    pub fn logical_line_hit(&self, line: i32, column: usize) -> Option<(String, usize)> {
        self.term
            .read()
            .logical_line_text(line, column)
            .map(|(text, _, offset)| (text, offset))
    }

    /// Whole buffer (scrollback + screen) as text, for search and export.
    pub fn mark_memory_visible(&self, cx: &gpui::App) {
        self.memory.activate(cx);
    }

    pub fn take_memory_refresh(&self) -> bool {
        self.memory.take_refresh()
    }

    pub fn styled_buffer_for_restore(&self) -> String {
        self.memory
            .styled_for_restore()
            .unwrap_or_else(|| self.term.read().full_buffer_ansi_text())
    }

    pub fn buffer_text(&self) -> String {
        let mut capture = work_profiler::begin(WorkKey::work(
            "full_buffer_text",
            "capture",
            self.profiling_phase(),
            "session",
            WorkQueue::Main,
        ));
        let text = self.term.read().full_buffer_text();
        capture.bytes(text.len());
        text
    }

    pub fn display_offset(&self) -> usize {
        self.term.read().display_offset()
    }

    pub fn scroll_position(&self) -> f64 {
        self.term.read().scroll_position()
    }

    pub fn scroll_to(&self, position: f64) {
        self.term.read().scroll_to(position);
    }

    pub fn shell_pid(&self) -> u64 {
        self.term.read().shell_pid()
    }

    /// Run `f` with the emulator (input handling reads modes, the cursor,
    /// echo state and the Kitty keyboard flags through it).
    pub fn with_terminal<R>(&self, f: impl FnOnce(&Chau7Terminal) -> R) -> R {
        f(&self.term.read())
    }

    /// Images decoded since the last call (iTerm2, Sixel, Kitty).
    pub fn take_images(&self) -> Vec<chau7_terminal::graphics::DecodedImage> {
        self.term.read().take_pending_images()
    }

    /// Suspend Background Rendering for a hidden tab (see `render_suspended`).
    pub fn set_render_suspended(&self, suspended: bool) {
        if self.render_suspended.swap(suspended, Ordering::Relaxed) != suspended {
            self.poll_interrupt.wake();
            let _ = self.refresh_wake.unbounded_send(RefreshWake::Cadence);
        }
        self.memory.set_tui(self.is_ai_running());
    }

    /// Actual view/window focus supplies interactive state. A zero interval
    /// leaves display-native presentation to GPUI's display scheduling.
    pub fn set_refresh_pacing(
        &self,
        interactive: bool,
        active: ActivePollingRateCap,
        inactive_fps: u32,
    ) {
        let interval = refresh_interval(interactive, active, inactive_fps);
        let ns = interval.as_nanos().min(u128::from(u64::MAX)) as u64;
        let focus_changed =
            self.poll_interactive.swap(interactive, Ordering::Relaxed) != interactive;
        if self.refresh_interval_ns.swap(ns, Ordering::Relaxed) != ns || focus_changed {
            self.poll_interrupt.wake();
            let _ = self.refresh_wake.unbounded_send(RefreshWake::Cadence);
        }
    }

    pub fn is_render_suspended(&self) -> bool {
        self.render_suspended.load(Ordering::Relaxed)
    }

    /// Typed input is not echoed (password prompt).
    pub fn is_echo_disabled(&self) -> bool {
        Chau7Terminal::password_input_on_fd(self.echo_fd)
    }

    /// Command status (idle, running, waiting for input, stuck, exited).
    pub fn status(&self) -> CommandStatus {
        self.tracker.status()
    }

    /// "Loading" until the first prompt (`isShellLoading`).
    pub fn is_loading(&self) -> bool {
        if self.exited.is_some() || !self.term.read().has_pty() {
            return false;
        }
        if self.has_hooks {
            self.tracker.is_shell_loading()
        } else {
            !self.first_output
        }
    }

    pub fn is_at_prompt(&self) -> bool {
        self.tracker.is_at_prompt()
    }

    /// The command being run (typed line, secrets redacted).
    pub fn pending_command(&self) -> Option<&str> {
        self.tracker.pending_command()
    }

    /// Semantic command search (`updateSemanticSearch`): past commands
    /// containing `query`, with previews "cmd (exit N)". The caller checks
    /// `feature.semanticSearch`.
    pub fn semantic_search(
        &self,
        query: &str,
        max_matches: usize,
        max_preview_lines: usize,
    ) -> (
        Vec<chau7_next_core::semantic_search::SemanticMatch>,
        Vec<String>,
    ) {
        chau7_next_core::semantic_search::search(
            self.tracker.blocks().blocks(),
            query,
            max_matches,
            max_preview_lines,
        )
    }

    /// Command blocks of this session (OSC 133).
    pub fn blocks(&self) -> &CommandBlockList {
        self.tracker.blocks()
    }

    /// Automation must never overwrite a typed fragment or queued restore.
    pub(crate) fn has_pending_automation_input(&self) -> bool {
        !self.pending_input.borrow().is_empty()
            || self.restore_intent.is_some()
            || self.pending_prefill.is_some()
            || self.tracker.prefill_pending
            || self.tracker.has_pending_input()
    }

    /// Shell state (AI provider and session id, prompt, integration).
    pub fn shell(&self) -> &ShellSession {
        &self.tracker
    }

    pub(crate) fn ai_display_app_name(&self) -> Option<String> {
        self.tracker.ai_display_app_name()
    }
    pub(crate) fn is_ai_running(&self) -> bool {
        self.exited.is_none() && self.tracker.is_ai_running()
    }
    pub(crate) fn apply_live_process_snapshot(
        &mut self,
        provider: Option<&str>,
        cx: &mut Context<Self>,
    ) {
        if self.close_requested || self.exited.is_some() {
            return;
        }
        if self.tracker.update_live_agent(provider) {
            self.memory.set_tui(self.is_ai_running());
            self.sync_cto_state();
            cx.emit(SessionEvent::MetadataChanged);
            cx.notify();
        }
    }

    /// The tab hosts an agent runtime session: no terminal-prompt
    /// "waiting for input" fallback (RUN-023).
    pub fn set_runtime_owned(&mut self, owned: bool) {
        self.tracker.runtime_owns_tab = owned;
    }

    /// Restores AI metadata of a saved tab (TRM-044).
    pub fn restore_ai_metadata(
        &mut self,
        provider: Option<&str>,
        session_id: Option<&str>,
        cx: &mut Context<Self>,
    ) {
        self.tracker.restore_ai_metadata(provider, session_id);
        self.ai_app = self.tracker.active_app().map(str::to_string);
        self.sync_cto_state();
        cx.emit(SessionEvent::MetadataChanged);
    }

    /// Close the session: `exit`, then signals (TRM-007). Also done on drop.
    pub fn close(&mut self) {
        self.process_subscription.take();
        if self.close_requested {
            return;
        }
        self.close_requested = true;
        self.poll_interrupt.wake();
        unregister_shell(self.id);
        let mode = if APP_QUITTING.load(Ordering::Acquire) {
            CloseMode::AppQuit
        } else {
            CloseMode::Graceful {
                ai_running: self.is_ai_running(),
            }
        };
        if self.exited.is_none() {
            self.writer.close(mode);
        }
    }

    /// The id of this shell for the token optimizer (flag file name, the
    /// key of the per-tab input prefix overrides).
    pub fn cto_id(&self) -> &str {
        &self.cto_id
    }

    /// The tab's token optimization override changed (`recalculate` is false
    /// when a saved one comes back at restore).
    pub fn set_token_opt_override(
        &mut self,
        value: chau7_next_core::token_optimization::TabTokenOptOverride,
        recalculate: bool,
    ) {
        crate::cto::set_override(&self.cto_id, value, recalculate);
    }

    /// The input prefix of this shell (`applyCTOPrefixIfNeeded`).
    fn apply_cto_prefix(&mut self, settings: &Settings) {
        self.tracker
            .set_input_prefix(settings.cto.prefix_for(&self.cto_id).map(str::to_string));
    }

    pub fn apply_settings(&mut self, settings: &Settings) {
        self.apply_cto_prefix(settings);
        let mut config = ShellSessionConfig::from_env(|k| std::env::var(k).ok());
        config.custom_rules = settings.ai.detection_rules();
        self.tracker.set_config(config);
        self.monitor.shell_events.set_config(
            chau7_next_core::monitoring::shell_events::ShellEventConfig::from_notification_settings(
                &settings.notifications.shell_events,
            ),
        );
        self.mouse_reporting_enabled
            .set(settings.input.mouse_reporting);
        let term = self.term.read();
        apply_colors(&term, settings);
        apply_image_protocols(&term, settings);
        self.memory.configure(settings.terminal.scrollback_lines);
        term.set_scrollback_size(self.memory.capacity());
    }
}

impl Drop for TerminalSession {
    fn drop(&mut self) {
        crate::cto::unregister_session(&self.cto_id);
        if crate::history::recorder::is_recording(self.id) {
            crate::history::recorder::stop();
        }
        self.close();
        self.stop.store(true, Ordering::Release);
        self.poll_interrupt.wake();
    }
}

/// Seconds since the first call, for the latency tracker.
fn clock(at: Instant) -> f64 {
    static EPOCH: std::sync::OnceLock<Instant> = std::sync::OnceLock::new();
    let epoch = *EPOCH.get_or_init(Instant::now);
    at.saturating_duration_since(epoch).as_secs_f64()
}

/// The latency clock now: lag events carry times on this clock, so the Debug
/// Console subtracts to get how long ago they happened.
pub fn clock_seconds_now() -> f64 {
    clock(Instant::now())
}

/// Where a new shell starts (`startDirectoryForLaunch`): the tab's directory
/// when it exists, else the "default start directory" setting, else home.
fn start_directory(cwd: Option<&Path>, settings: &Settings, home: &str) -> PathBuf {
    let default = || {
        let raw = settings
            .general
            .default_directory
            .clone()
            .unwrap_or_default();
        let resolved = PathBuf::from(shell_env::resolve_start_directory(&raw, home));
        if resolved.is_dir() {
            resolved
        } else {
            PathBuf::from(home)
        }
    };
    match cwd {
        Some(dir) => {
            let resolved = PathBuf::from(shell_env::resolve_start_directory(
                &dir.to_string_lossy(),
                home,
            ));
            if resolved.is_dir() {
                resolved
            } else {
                default()
            }
        }
        None => default(),
    }
}

/// `git status --porcelain` paths in `directory` (empty outside a repo).
/// Runs with a 5 s kill timeout (`GitDiffTracker.runGit`).
fn git_dirty_files(directory: &str) -> BTreeSet<String> {
    let output =
        chau7_next_core::monitoring::git::run_git_raw(&["status", "--porcelain"], directory);
    git_changes::dirty_files(&output)
}

/// Selection modes understood by `Chau7Terminal::selection_start`.
#[derive(Debug, Clone, Copy)]
#[repr(u8)]
pub enum SelectionKind {
    Simple = 0,
    Block = 1,
    Word = 2,
    Line = 3,
}

fn apply_colors(term: &Chau7Terminal, settings: &Settings) {
    use chau7_next_core::color_schemes::ColorScheme;
    let scheme = settings.appearance.color_scheme;
    term.set_colors(
        ColorScheme::rgb(scheme.foreground),
        ColorScheme::rgb(scheme.background),
        ColorScheme::rgb(scheme.cursor),
        scheme.ansi_rgb(),
    );
}

/// Which image sequences the emulator intercepts (`setImageProtocols`):
/// iTerm2 follows Inline Images, Sixel and Kitty their own toggles.
fn apply_image_protocols(term: &Chau7Terminal, settings: &Settings) {
    let appearance = &settings.appearance;
    term.set_image_protocols(
        appearance.graphics.sixel,
        appearance.graphics.kitty,
        appearance.display.inline_images,
    );
}

/// Apply authoritative CLI feedback to panes belonging to the explicitly bound tab.
/// Reconcile a hook only against one exact native session, or one live Claude
/// pane with an ownership-checked related cwd. No filesystem access occurs here.
pub(crate) fn adopt_claude_hook_identity(
    event: &chau7_next_core::monitoring::claude_code::ClaudeCodeEvent,
    transcript_owned: bool,
    cx: &mut gpui::App,
) -> Option<uuid::Uuid> {
    let home = cx
        .try_global::<crate::workspace::AppData>()?
        .root
        .home()
        .to_path_buf();
    let replace = event.event_type
        == chau7_next_core::command_detection::event_parsing::EventType::UserPrompt;
    let mut exact = Vec::new();
    let mut eligible = Vec::new();
    for window in crate::mcp::windows::windows(cx) {
        let workspace = window.workspace.read(cx);
        for uuid in workspace.mcp_tab_uuids() {
            let Some(tab) = workspace.mcp_find(uuid) else {
                continue;
            };
            let Some(panes) = workspace.mcp_panes(tab) else {
                continue;
            };
            for (_, entity) in panes.read(cx).pane_sessions(cx) {
                let session = entity.read(cx);
                if !session.is_ai_running()
                    || session.exited.is_some()
                    || !session.tracker.can_adopt_observed_ai_identity(
                        "claude",
                        &event.session_id,
                        event.timestamp,
                        replace,
                    )
                {
                    continue;
                }
                let cwd = session.tracker.current_directory();
                let related = chau7_next_core::monitoring::claude_resolver::related_directory(
                    &home, &event.cwd, cwd,
                );
                let candidate = (crate::ai::events_out::tab_uuid(tab), entity.clone());
                if session.tracker.ai_session_id() == Some(event.session_id.trim()) && related {
                    exact.push(candidate);
                } else if transcript_owned && related {
                    eligible.push(candidate);
                }
            }
        }
    }
    let (tab, entity) = unique_claude_owner(exact, eligible)?;
    entity.update(cx, |session, cx| {
        if session.tracker.adopt_observed_ai_identity(
            "claude",
            &event.session_id,
            event.timestamp,
            replace,
        ) {
            cx.emit(SessionEvent::MetadataChanged);
            cx.notify();
        }
    });
    Some(tab)
}

fn unique_claude_owner<T>(mut exact: Vec<T>, mut eligible: Vec<T>) -> Option<T> {
    if exact.len() == 1 {
        exact.pop()
    } else if exact.is_empty() && eligible.len() == 1 {
        eligible.pop()
    } else {
        None
    }
}

#[cfg(test)]
mod claude_owner_tests {
    use super::unique_claude_owner;
    #[test]
    fn ownership_requires_unique_exact_or_unique_eligible_candidate() {
        assert_eq!(unique_claude_owner(vec![1], vec![2, 3]), Some(1));
        assert_eq!(unique_claude_owner(Vec::<u8>::new(), vec![2]), Some(2));
        assert_eq!(unique_claude_owner(vec![1, 2], vec![3]), None);
        assert_eq!(unique_claude_owner(Vec::<u8>::new(), vec![2, 3]), None);
        assert_eq!(unique_claude_owner(Vec::<u8>::new(), vec![]), None);
    }
}

#[derive(Default)]
struct FeedbackQuarantine(chau7_next_core::monitoring::quarantine::Quarantine);
impl Global for FeedbackQuarantine {}

fn feedback_kind(event: &AiEvent) -> Option<&str> {
    Some(match event.event_type.as_str() {
        "permission_request" => "permission",
        "response_complete" => "turn_completed",
        "approval_requested"
        | "permission"
        | "user_input_requested"
        | "waiting_input"
        | "approval_resolved"
        | "permission_resolved"
        | "user_input_resolved"
        | "turn_completed"
        | "finished" => &event.event_type,
        _ => return None,
    })
}
fn feedback_provider(event: &AiEvent) -> Option<String> {
    chau7_next_core::ai::resume::normalize_provider_name(&event.tool)
        .or_else(|| chau7_next_core::ai::resume::normalize_provider_name(event.source.raw_value()))
}
fn feedback_owner_accepts_kind(kind: &str, is_live: bool) -> bool {
    is_live || matches!(kind, "turn_completed" | "finished")
}
fn feedback_target_matches(
    target: Option<uuid::Uuid>,
    metadata_uuid: uuid::Uuid,
    tab: crate::tab_bar::TabId,
    native_tab_identifier: &str,
) -> bool {
    target.is_none_or(|target| {
        target == metadata_uuid
            || target == crate::ai::events_out::tab_uuid(tab)
            || uuid::Uuid::parse_str(native_tab_identifier).ok() == Some(target)
    })
}
fn feedback_owner(
    event: &AiEvent,
    target: Option<uuid::Uuid>,
    exact_only: bool,
    cx: &mut gpui::App,
) -> Option<(uuid::Uuid, gpui::Entity<TerminalSession>)> {
    let kind = feedback_kind(event)?;
    let provider = feedback_provider(event)?;
    let date = chau7_next_core::telemetry::date_codec::parse_iso8601(Some(&event.ts))?;
    let observed_at = date.timestamp_millis() as f64 / 1000.0;
    let home = cx
        .try_global::<crate::workspace::AppData>()?
        .root
        .home()
        .to_path_buf();
    let mut exact = Vec::new();
    let mut unbound = Vec::new();
    for window in crate::mcp::windows::windows(cx) {
        let workspace = window.workspace.read(cx);
        for uuid in workspace.mcp_tab_uuids() {
            let Some(tab) = workspace.mcp_find(uuid) else {
                continue;
            };
            let Some(panes) = workspace.mcp_panes(tab) else {
                continue;
            };
            for (_, entity) in panes.read(cx).pane_sessions(cx) {
                let session = entity.read(cx);
                if !feedback_target_matches(target, uuid, tab, &session.tab_identifier) {
                    continue;
                }
                let id = event
                    .session_id
                    .as_deref()
                    .or(session.tracker.ai_session_id())
                    .unwrap_or("unbound");
                if session.exited.is_some()
                    || !feedback_owner_accepts_kind(kind, session.is_ai_running())
                    || !session.tracker.can_adopt_observed_ai_identity(
                        &provider,
                        id,
                        observed_at,
                        false,
                    )
                {
                    continue;
                }
                if let Some(directory) = event.directory.as_deref().filter(|d| !d.trim().is_empty())
                {
                    let cwd = session.tracker.current_directory();
                    let anchors: Vec<_> = [
                        Some(cwd).filter(|d| !d.is_empty()),
                        session.git_root.as_deref().and_then(|p| p.to_str()),
                    ]
                    .into_iter()
                    .flatten()
                    .collect();
                    if !anchors.is_empty()
                        && !anchors.iter().any(|anchor| {
                            chau7_next_core::monitoring::claude_resolver::related_directory(
                                &home, directory, anchor,
                            )
                        })
                    {
                        continue;
                    }
                }
                let candidate = (crate::ai::events_out::tab_uuid(tab), entity.clone());
                if event
                    .session_id
                    .as_deref()
                    .is_some_and(|id| session.tracker.ai_session_id() == Some(id.trim()))
                {
                    exact.push(candidate);
                } else if !exact_only
                    && session.is_ai_running()
                    && (event.session_id.is_none()
                        || (provider == "codex" && session.tracker.ai_session_id().is_none()))
                {
                    unbound.push(candidate);
                }
            }
        }
    }
    unique_claude_owner(exact, unbound)
}

#[cfg(test)]
mod feedback_owner_tests {
    use super::{AiEvent, feedback_kind, feedback_owner_accepts_kind, feedback_target_matches};

    #[test]
    fn current_publishers_and_native_pane_aliases_match_only_the_actual_tab() {
        let metadata = uuid::Uuid::new_v4();
        let native = uuid::Uuid::new_v4();
        let encoded = crate::ai::events_out::tab_uuid(7);
        for target in [None, Some(metadata), Some(encoded), Some(native)] {
            assert!(feedback_target_matches(
                target,
                metadata,
                7,
                &native.to_string()
            ));
        }
        for target in [uuid::Uuid::new_v4(), crate::ai::events_out::tab_uuid(8)] {
            assert!(!feedback_target_matches(
                Some(target),
                metadata,
                7,
                &native.to_string()
            ));
        }
        assert!(!feedback_target_matches(
            Some(native),
            metadata,
            7,
            "invalid native id"
        ));
        assert!(feedback_target_matches(
            Some(encoded),
            metadata,
            7,
            "invalid native id"
        ));
    }

    #[test]
    fn inactive_exact_owner_only_accepts_completion_not_requests_or_resolutions() {
        let alias = AiEvent::new(
            chau7_next_core::ai::event::AiEventSource("codex".into()),
            "response_complete",
            "codex",
            "",
            "2026-10-11T12:00:00Z",
        );
        assert_eq!(feedback_kind(&alias), Some("turn_completed"));
        assert!(feedback_owner_accepts_kind(
            feedback_kind(&alias).unwrap(),
            false
        ));
        for kind in ["turn_completed", "finished"] {
            assert!(feedback_owner_accepts_kind(kind, false), "{kind}");
        }
        for kind in [
            "approval_requested",
            "permission",
            "user_input_requested",
            "waiting_input",
            "approval_resolved",
            "permission_resolved",
            "user_input_resolved",
        ] {
            assert!(!feedback_owner_accepts_kind(kind, false), "{kind}");
            assert!(feedback_owner_accepts_kind(kind, true), "{kind}");
        }
    }
}

/// Final projection authority: preserve the durable raw event, but never apply
/// its status/notification to a different session. Reconcile exactly once.
pub(crate) fn reconcile_feedback_route(event: &mut AiEvent, cx: &mut gpui::App) -> bool {
    if feedback_kind(event).is_none() {
        return true;
    }
    let Some(tab) = event.tab_id else {
        return true;
    };
    let Some(provider) = feedback_provider(event) else {
        return true;
    };
    if feedback_owner(event, Some(tab), false, cx).is_some() {
        if let Some(id) = event.session_id.as_deref() {
            let key = chau7_next_core::monitoring::quarantine::SourceKey::new(tab, id, &provider);
            cx.default_global::<FeedbackQuarantine>().0.clear(&key);
        }
        return true;
    }
    let Some(id) = event
        .session_id
        .as_deref()
        .filter(|id| !id.trim().is_empty())
    else {
        return false;
    };
    let key = chau7_next_core::monitoring::quarantine::SourceKey::new(tab, id, &provider);
    let decision = cx
        .default_global::<FeedbackQuarantine>()
        .0
        .record_failure(key.clone(), now_secs());
    use chau7_next_core::monitoring::quarantine::Decision;
    match decision {
        Decision::ReconcileAndReport => {
            if let Some((owner, _)) = feedback_owner(event, None, true, cx) {
                event.tab_id = Some(owner);
                cx.default_global::<FeedbackQuarantine>().0.clear(&key);
                log::info!("Reconciled stale provider feedback to one exact native-session owner");
                return true;
            }
            log::warn!("Quarantined mismatched provider feedback source; no unique exact owner");
        }
        Decision::ReportSummary { suppressed_count } => {
            log::warn!("Provider feedback remains quarantined; suppressed={suppressed_count}")
        }
        Decision::Suppress => (),
    }
    false
}

pub(crate) fn apply_agent_feedback(event: &AiEvent, cx: &mut gpui::App) {
    if event.reliability != AiEventReliability::Authoritative || feedback_kind(event).is_none() {
        return;
    }
    let Some(tab) = event.tab_id else {
        return;
    };
    let Some((_, entity)) = feedback_owner(event, Some(tab), false, cx) else {
        return;
    };
    entity.update(cx, |session, cx| {
        if session.tracker.ai_session_id().is_none()
            && let (Some(id), Some(provider), Some(date)) = (
                event.session_id.as_deref(),
                feedback_provider(event),
                chau7_next_core::telemetry::date_codec::parse_iso8601(Some(&event.ts)),
            )
            && session.tracker.adopt_observed_ai_identity(
                &provider,
                id,
                date.timestamp_millis() as f64 / 1000.0,
                false,
            )
        {
            cx.emit(SessionEvent::MetadataChanged);
        }
        session.handle_agent_feedback(event, cx);
    });
}

/// Shared by all UI and MCP selection callers; native selection joins soft wraps.
fn clipboard_selection(terminal: &Chau7Terminal, live_ai: bool) -> Option<String> {
    terminal
        .selection_text()
        .map(|text| {
            chau7_next_core::terminal_clipboard::copied_text(
                &text,
                live_ai || terminal.is_alt_screen(),
            )
            .into_owned()
        })
        .filter(|text| !text.is_empty())
}

#[cfg(test)]
mod clipboard_tests {
    use super::*;
    #[test]
    fn actual_native_selection_preserves_soft_wrap_spaces_and_trims_padding() {
        let term = Chau7Terminal::new_headless(5, 2).unwrap();
        term.inject_output(b"echo hello");
        term.selection_start(0, 0, 0);
        term.selection_update(4, 1);
        let native = term.selection_text().unwrap();
        assert_eq!(native.trim_end_matches('\n'), "echo hello");
        assert_eq!(clipboard_selection(&term, false).unwrap(), native);
        assert_eq!(clipboard_selection(&term, true).unwrap(), "echo hello");
    }
    #[test]
    fn actual_tui_hard_wrapped_path_and_argument_selection() {
        for (raw, end, expected) in [
            (
                &b"cat /tmp/very\r\nlongpath"[..],
                7,
                "cat /tmp/verylongpath",
            ),
            (&b"echo hello\r\n    --flag"[..], 9, "echo hello --flag"),
        ] {
            let term = Chau7Terminal::new_headless(40, 2).unwrap();
            term.inject_output(raw);
            term.selection_start(0, 0, 0);
            term.selection_update(end, 1);
            assert_eq!(clipboard_selection(&term, true).unwrap(), expected);
            assert_eq!(
                clipboard_selection(&term, false).unwrap(),
                term.selection_text().unwrap()
            );
        }
    }
    #[test]
    fn actual_alternate_screen_is_tui_without_detected_ai() {
        let term = Chau7Terminal::new_headless(40, 2).unwrap();
        term.inject_output(b"\x1b[?1049hecho hello\r\n    --flag");
        assert!(term.is_alt_screen());
        term.selection_start(0, 0, 0);
        term.selection_update(9, 1);
        assert_eq!(
            clipboard_selection(&term, false).unwrap(),
            "echo hello --flag"
        );
        term.selection_clear();
        assert_eq!(clipboard_selection(&term, false), None);
    }
}

#[cfg(test)]
mod refresh_pacing_tests {
    use super::*;
    #[test]
    fn actual_focus_rate_options_and_inactive_bounds_have_real_deadlines() {
        assert_eq!(
            refresh_interval(true, ActivePollingRateCap::DisplayNative, 42),
            Duration::ZERO
        );
        for (cap, fps) in [
            (ActivePollingRateCap::Hz60, 60.0),
            (ActivePollingRateCap::Hz30, 30.0),
        ] {
            assert_eq!(
                refresh_interval(true, cap, 42),
                Duration::from_secs_f64(1.0 / fps)
            );
        }
        assert_eq!(
            refresh_interval(false, ActivePollingRateCap::Hz30, 42),
            Duration::from_secs_f64(1.0 / 42.0)
        );
        assert_eq!(
            refresh_interval(false, ActivePollingRateCap::DisplayNative, 0),
            Duration::from_secs(1)
        );
        assert_eq!(
            refresh_interval(false, ActivePollingRateCap::Hz60, u32::MAX),
            Duration::from_secs_f64(1.0 / 120.0)
        );
    }
    #[test]
    fn coalesced_output_deadline_does_not_restart_and_resume_cancels_suspension() {
        let cap = refresh_interval(true, ActivePollingRateCap::Hz30, 42);
        assert_eq!(
            refresh_wait(cap, false, Duration::from_millis(10)),
            cap - Duration::from_millis(10)
        );
        assert_eq!(
            refresh_wait(cap, false, Duration::from_millis(40)),
            Duration::ZERO
        );
        assert_eq!(
            refresh_wait(Duration::ZERO, true, Duration::from_millis(10)),
            Duration::from_millis(490)
        );
        assert_eq!(
            refresh_wait(Duration::ZERO, false, Duration::from_millis(10)),
            Duration::ZERO
        );
        assert_eq!(
            refresh_wait(Duration::from_secs(1), true, Duration::from_millis(10)),
            Duration::from_millis(490)
        );
    }
}

#[cfg(test)]
mod restored_context_tests {
    use super::*;

    #[test]
    fn direct_restore_replay_preserves_live_prompt_without_a_pty() {
        let term = Chau7Terminal::new_headless(80, 24).unwrap();
        term.replay_buffer(b"fresh shell\r\nlive-prompt> ");
        replay_restored_terminal(&term, "\x1b[31msaved history\x1b[0m");
        let text = term.full_buffer_text();
        assert!(text.contains("saved history"), "{text:?}");
        assert!(text.contains("fresh shell"), "{text:?}");
        assert!(text.contains("live-prompt>"), "{text:?}");
        assert!(text.find("saved history").unwrap() < text.find("fresh shell").unwrap());
        assert!(!text.contains("cat "));
    }
}
