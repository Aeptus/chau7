//! Remote control with the Chau7 iOS app (`Remote/RemoteControlManager.swift`).
//!
//! `iOS app <-> relay <-> chau7-remote (Go agent) <-> remote.sock <-> Chau7 Next`.
//! When "Enable Remote Control" is on, Chau7 Next listens on its own socket
//! and starts the agent with its own state file (never the Swift app's), so
//! both apps pair separately and the phone sees "<computer> (Chau7 Next)".
//!
//! | File | Part |
//! |---|---|
//! | `host.rs` | the protocol: what the phone sees and may do (no GPUI) |
//! | `env.rs` | the host's view of windows, tabs and sessions |
//! | `ipc.rs` | the Unix socket server |
//! | `agent.rs` | finding, starting and stopping the agent |
//! | `snapshot.rs` | grid snapshot payload |
//!
//! Viewer sharing (RMT-027) keeps its state here too; see
//! `chau7_next_core::remote::viewer`.

pub mod agent;
mod env;
pub mod host;
pub mod ipc;
pub mod snapshot;
pub mod viewer_ui;

use std::time::{Duration, Instant};

use chau7_next_core::app_shell::URL_SCHEME;
use chau7_next_core::data_root::DataRoot;
use chau7_next_core::remote::agent_state::{self, AgentPairedDevice};
use chau7_next_core::remote::frame::RemoteFrame;
use chau7_next_core::remote::models::{ApprovalRequestPayload, RemotePairingInfo};
use chau7_next_core::remote::viewer::{RemoteViewerMode, ViewerArrival};
use chau7_next_core::remote::viewer_protocol;
use chau7_next_core::telemetry::remote_client_event::RemoteClientTelemetryEvent;
use chrono::Utc;
use gpui::{AnyWindowHandle, App, AppContext, Context, Entity, Global};

use self::agent::AgentProcess;
use self::env::GpuiEnv;
use self::host::{FrameSink, RemoteHost, ViewerInbound};
use self::ipc::{IpcEvent, IpcServer};
use crate::settings::{RemoteSettings, Settings};
use crate::workspace::AppData;

/// Timer while remote control is on: output batches go out at this pace.
const TICK_ON: Duration = Duration::from_millis(33);
/// Timer while it is off (only watches the setting).
const TICK_OFF: Duration = Duration::from_millis(500);
/// Tabs, activity and prompts are refreshed this often (Swift: 150 ms debounce).
const REFRESH_EVERY: Duration = Duration::from_millis(150);

/// Answers MCP command approvals from the phone (`TerminalControlService
/// .resolveApproval`). Set by the MCP module.
pub type ApprovalResolver = Box<dyn Fn(&str, bool, &mut App)>;
/// Stores iOS telemetry events (TEL-015). Set by the telemetry module.
pub type TelemetrySink = Box<dyn Fn(RemoteClientTelemetryEvent, &mut App)>;

struct IpcSink<'a>(Option<&'a IpcServer>);

impl FrameSink for IpcSink<'_> {
    fn send(&mut self, frame: RemoteFrame) {
        if let Some(ipc) = self.0 {
            ipc.send(&frame);
        }
    }
}

/// What the settings window shows.
#[derive(Debug, Clone, PartialEq)]
pub struct RemoteStatus {
    pub agent_running: bool,
    pub ipc_connected: bool,
    pub session_status: Option<String>,
    pub last_error: Option<String>,
    pub pairing_info: Option<RemotePairingInfo>,
    /// Paired devices with whether each is connected now.
    pub devices: Vec<(AgentPairedDevice, bool)>,
    pub viewer: RemoteViewerMode,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct GridContext {
    connected: bool,
    streams_terminal: bool,
    tab: Option<u32>,
    session: Option<u64>,
}

fn advance_grid_context(
    current: &mut Option<GridContext>,
    epoch: &mut u64,
    next: GridContext,
) -> bool {
    if *current == Some(next) {
        return false;
    }
    *current = Some(next);
    *epoch = epoch.wrapping_add(1);
    true
}

pub struct RemoteControl {
    root: DataRoot,
    host: RemoteHost,
    grid_worker: snapshot::GridSnapshotWorker,
    grid_epoch: u64,
    grid_context: Option<GridContext>,
    ipc: Option<IpcServer>,
    agent: Option<AgentProcess>,
    start_generation: u64,
    start_pending: bool,
    shutting_down: bool,
    devices_refreshing: bool,
    devices_refresh_again: bool,
    /// Settings the agent runs with (enabled, relay URL).
    applied: Option<(bool, String)>,
    focus_window: Option<AnyWindowHandle>,
    devices: Vec<AgentPairedDevice>,
    viewer: RemoteViewerMode,
    last_refresh: Instant,
    approval_resolver: Option<ApprovalResolver>,
    telemetry_sink: Option<TelemetrySink>,
    last_status: Option<RemoteStatus>,
}

struct RemoteHandle(Entity<RemoteControl>);
impl Global for RemoteHandle {}

fn handle(cx: &App) -> Option<Entity<RemoteControl>> {
    cx.try_global::<RemoteHandle>().map(|h| h.0.clone())
}

/// Start remote control (the agent runs only while the setting is on).
pub fn init(cx: &mut App) {
    let root = cx.global::<AppData>().root.clone();
    let entity = cx.new(|_| RemoteControl {
        root,
        host: RemoteHost::new(),
        grid_worker: snapshot::GridSnapshotWorker::default(),
        grid_epoch: 0,
        grid_context: None,
        ipc: None,
        agent: None,
        start_generation: 0,
        start_pending: false,
        shutting_down: false,
        devices_refreshing: false,
        devices_refresh_again: false,
        applied: None,
        focus_window: None,
        devices: Vec::new(),
        viewer: RemoteViewerMode::default(),
        last_refresh: Instant::now(),
        approval_resolver: None,
        telemetry_sink: None,
        last_status: None,
    });
    cx.set_global(RemoteHandle(entity.clone()));
    let weak = entity.downgrade();
    cx.spawn(async move |cx| {
        loop {
            let Ok(delay) = weak.update(cx, |rc, cx| rc.tick(cx)) else {
                break;
            };
            cx.background_executor().timer(delay).await;
        }
    })
    .detach();
    // The agent stops with the app (`applicationWillTerminate`).
    cx.on_app_quit(move |cx| {
        entity.update(cx, |rc, _| rc.shutdown());
        async {}
    })
    .detach();
}

/// Measured native remote capture data. No frame has been captured until the
/// lazy worker starts; timing/row samples remain null until an actual capture.
pub fn grid_diagnostics(cx: &App) -> Option<serde_json::Value> {
    let entity = handle(cx)?;
    let rc = entity.read(cx);
    let mut value = rc.grid_worker.diagnostics();
    value["connection_epoch"] = serde_json::json!(rc.grid_epoch);
    value["selected_tab"] = serde_json::json!(rc.grid_context.and_then(|c| c.tab));
    value["selected_session"] = serde_json::json!(rc.grid_context.and_then(|c| c.session));
    Some(value)
}

/// `CHAU7_NEXT_REMOTE_OUTPUT_BATCH=0` (or `CHAU7_REMOTE_OUTPUT_BATCH`) sends
/// each chunk at once instead of every timer tick (`remoteOutputBatchingEnabled`).
fn output_batching_enabled() -> bool {
    static ENABLED: std::sync::OnceLock<bool> = std::sync::OnceLock::new();
    *ENABLED.get_or_init(|| {
        let raw = crate::logging::env_var(chau7_next_core::env_vars::REMOTE_OUTPUT_BATCH);
        chau7_next_core::remote::output_buffering::RemoteOutputTuning::batching_enabled(
            raw.as_deref(),
        )
    })
}

/// Output of a terminal session (`recordOutput`), called for every batch
/// the session parses. Only the selected tab's output is kept. Batches go
/// out on the remote timer (33 ms) or as soon as 32 KB are pending, which
/// matches Swift's per-tab batching (50 ms or 256 KB, then the relay limit).
pub fn ingest_claude_event(
    event: &chau7_next_core::monitoring::claude_code::ClaudeCodeEvent,
    tab: Option<u64>,
    cx: &mut App,
) {
    let Some(entity) = handle(cx) else {
        return;
    };
    entity.update(cx, |rc, _| {
        rc.host.ingest_claude_event(event, tab, chrono::Utc::now())
    });
}

pub fn record_output(session: u64, data: &[u8], cx: &mut App) {
    let Some(entity) = handle(cx) else { return };
    let full = entity.update(cx, |rc, _| {
        if rc.viewer.should_broadcast() {
            log::trace!(
                "RemoteViewerMode: broadcast {} bytes to {} viewers",
                data.len(),
                rc.viewer.connected.len()
            );
        }
        rc.host.record_output(session, data)
    });
    if full || (entity.read(cx).host.has_pending_output() && !output_batching_enabled()) {
        // The session is being updated: send once it is done.
        cx.defer(move |cx| {
            entity.update(cx, |rc, cx| rc.flush_output(cx));
        });
    }
}

/// Show an MCP command approval on the phone (`sendApprovalRequest`).
/// Called by `mcp::approval::request_command_approval`.
pub fn send_approval_request(
    request: ApprovalRequestPayload,
    target_tab: crate::tab_bar::TabId,
    cx: &mut App,
) {
    if let Some(entity) = handle(cx) {
        // Deferred: the caller may be inside a window or tab update, and the
        // host reads every window's tabs.
        cx.defer(move |cx| {
            entity.update(cx, |rc, cx| {
                rc.with_host(cx, |host, env, sink| {
                    host.send_approval_request(&request, Some(target_tab), env, sink)
                });
            });
        });
    }
}

/// Who answers approvals the phone sends for MCP commands (set by MCP).
pub fn set_approval_resolver(resolver: ApprovalResolver, cx: &mut App) {
    if let Some(entity) = handle(cx) {
        entity.update(cx, |rc, _| rc.approval_resolver = Some(resolver));
    }
}

/// Where iOS telemetry events go (default: the log). Set by the
/// telemetry store (TEL-015).
#[allow(dead_code)]
pub fn set_telemetry_sink(sink: TelemetrySink, cx: &mut App) {
    if let Some(entity) = handle(cx) {
        entity.update(cx, |rc, _| rc.telemetry_sink = Some(sink));
    }
}

/// The state shown in settings.
pub fn status(cx: &App) -> Option<RemoteStatus> {
    handle(cx).map(|e| e.read(cx).status())
}

/// "Regenerate": restart the agent for a new pairing code.
pub fn regenerate(cx: &mut App) {
    if let Some(entity) = handle(cx) {
        entity.update(cx, |rc, cx| rc.restart_agent_if_running(cx));
    }
}

/// Forget a paired device; it must pair again.
pub fn revoke_device(id: String, cx: &mut App) {
    if let Some(entity) = handle(cx) {
        entity.update(cx, |rc, cx| rc.revoke(&id, cx));
    }
}

/// Viewer sharing actions (popover buttons).
pub fn update_viewer(cx: &mut App, change: impl FnOnce(&mut RemoteViewerMode)) {
    let Some(entity) = handle(cx) else { return };
    let known = entity.update(cx, |rc, cx| {
        let before = rc.viewer.clone();
        change(&mut rc.viewer);
        // Tell the agent: share code, decisions, ended viewings (RMT-027).
        let frames = viewer_protocol::sync_frames(&before, &rc.viewer);
        if !frames.is_empty() {
            rc.send_viewer_frames(frames);
        }
        cx.refresh_windows();
        (rc.viewer.known_ids != before.known_ids)
            .then(|| rc.viewer.known_ids.iter().cloned().collect())
    });
    // Trusted viewers are a setting (`remoteViewer.knownIDs`).
    if let Some(ids) = known {
        crate::settings_window::update(cx, |s| s.remote.viewer_known_ids = ids);
    }
}

/// Start or stop sharing (a new 8-character link each time).
pub fn set_sharing(on: bool, cx: &mut App) {
    update_viewer(cx, |viewer| {
        if on {
            let token = uuid::Uuid::new_v4().to_string();
            viewer.start_sharing(URL_SCHEME, &token);
        } else {
            viewer.stop_sharing();
        }
    });
}

/// A viewer with a valid code asks to watch (`viewer_join` from the agent):
/// a trusted viewer is let in at once, one over the maximum is turned away,
/// anyone else waits for the owner.
pub fn viewer_connected(id: &str, name: &str, cx: &mut App) {
    let mut arrival = None;
    update_viewer(cx, |viewer| {
        arrival = Some(viewer.handle_connection(id, name, Utc::now()));
    });
    let Some(entity) = handle(cx) else { return };
    let frame = match arrival {
        Some(ViewerArrival::AutoApproved) => Some(viewer_protocol::decision_frame(id, true, None)),
        Some(ViewerArrival::Rejected) => Some(viewer_protocol::decision_frame(
            id,
            false,
            Some("max_viewers"),
        )),
        _ => None,
    };
    if let Some(frame) = frame {
        entity.update(cx, |rc, _| rc.send_viewer_frames(vec![frame]));
    }
}

/// A viewer left on its side (`viewer_leave` from the agent).
fn viewer_left(id: &str, cx: &mut App) {
    if let Some(entity) = handle(cx) {
        entity.update(cx, |rc, cx| {
            rc.viewer.deny(id);
            rc.viewer.disconnect(id);
            cx.refresh_windows();
        });
    }
}

impl RemoteControl {
    fn status(&self) -> RemoteStatus {
        let ready = self.host.session_status.as_deref() == Some("ready");
        RemoteStatus {
            agent_running: self.agent.is_some(),
            ipc_connected: self.host.ipc_connected,
            session_status: self.host.session_status.clone(),
            last_error: self.host.last_error.clone(),
            pairing_info: self.host.pairing_info.clone(),
            devices: self
                .devices
                .iter()
                .map(|d| {
                    let connected =
                        ready && self.host.connected_device_id.as_deref() == Some(d.id.as_str());
                    (d.clone(), connected)
                })
                .collect(),
            viewer: self.viewer.clone(),
        }
    }

    /// Run `f` on the host with the app as its environment and the socket
    /// as its sink, then hand out what it resolved.
    fn with_host<R>(
        &mut self,
        cx: &mut Context<Self>,
        f: impl FnOnce(&mut RemoteHost, &mut GpuiEnv, &mut IpcSink) -> R,
    ) -> R {
        let (result, resolved, telemetry) = {
            let mut env = GpuiEnv::new(
                cx,
                &mut self.focus_window,
                &mut self.grid_worker,
                self.grid_epoch,
            );
            let mut sink = IpcSink(self.ipc.as_ref());
            let result = f(&mut self.host, &mut env, &mut sink);
            let scope = self.host.grid_capture_scope(&mut env, 0);
            let context = GridContext {
                connected: self.host.ipc_connected,
                streams_terminal: self.host.streams_terminal(),
                tab: scope.map(|s| s.tab),
                session: scope.map(|s| s.session),
            };
            if advance_grid_context(&mut self.grid_context, &mut self.grid_epoch, context) {
                env.reset_grid_epoch(self.grid_epoch);
                self.host.capture_selected_grid(&mut env, true);
            }
            if let Some(frame) = env.take_grid_result() {
                self.host
                    .deliver_grid_result(&mut env, &mut sink, self.grid_epoch, frame);
            }
            (result, env.resolved, env.telemetry)
        };
        for (id, approved) in resolved {
            match &self.approval_resolver {
                Some(resolve) => resolve(&id, approved, cx),
                None => log::info!("Remote: approval {id} answered ({approved}), no MCP handler"),
            }
        }
        for event in telemetry {
            match &self.telemetry_sink {
                Some(store) => store(event, cx),
                None => log::debug!("Remote telemetry: {:?}", event.event_type),
            }
        }
        result
    }

    fn tick(&mut self, cx: &mut Context<Self>) -> Duration {
        let mut wake =
            chau7_next_core::work_profiler::begin(chau7_next_core::work_profiler::Key::wakeup(
                "remote_timer",
                "app",
                chau7_next_core::work_profiler::Queue::Main,
            ));
        let settings = Settings::get(cx).remote.clone();
        self.apply_settings(&settings, cx);

        if let Some(agent) = &mut self.agent
            && let Some(code) = agent.try_exit()
        {
            self.agent = None;
            if code != 0 {
                let error = format!("Remote agent exited with status {code}");
                log::error!("{error}");
                self.host.last_error = Some(error);
            }
        }

        let events = self.ipc.as_ref().map(IpcServer::drain).unwrap_or_default();
        wake.idle(
            events.is_empty() && !self.host.has_pending_output() && !self.grid_worker.has_result(),
        );
        for event in events {
            match event {
                IpcEvent::Connected => {
                    self.invalidate_grid();
                    self.with_host(cx, |host, env, sink| host.on_connected(env, sink));
                    // A restarted agent learns the share code again.
                    if self.viewer.is_sharing {
                        let frame = viewer_protocol::share_frame(&self.viewer);
                        self.send_viewer_frames(vec![frame]);
                    }
                }
                IpcEvent::Frame(frame) => {
                    self.with_host(cx, |host, env, sink| host.handle_frame(frame, env, sink));
                }
                IpcEvent::Disconnected => {
                    self.invalidate_grid();
                    self.host.on_disconnected();
                }
            }
        }

        for message in std::mem::take(&mut self.host.viewer_inbox) {
            let weak = cx.entity().downgrade();
            // The viewer state is changed through `update_viewer`, outside
            // this entity's update.
            cx.defer(move |cx| {
                if weak.upgrade().is_none() {
                    return;
                }
                match message {
                    ViewerInbound::Join(join) => viewer_connected(&join.viewer_id, &join.name, cx),
                    ViewerInbound::Leave(id) => viewer_left(&id, cx),
                }
            });
        }
        if self.host.has_pending_output() {
            self.flush_output(cx);
        }
        if self.host.ipc_connected && self.last_refresh.elapsed() >= REFRESH_EVERY {
            self.last_refresh = Instant::now();
            self.with_host(cx, |host, env, sink| host.refresh(env, sink));
        }
        if self.grid_worker.has_result() {
            self.with_host(cx, |_, _, _| ());
        }
        if self.host.devices_dirty {
            self.host.devices_dirty = false;
            self.refresh_devices(cx);
        }

        let status = self.status();
        if self.last_status.as_ref() != Some(&status) {
            self.last_status = Some(status);
            cx.refresh_windows();
        }
        if settings.enabled { TICK_ON } else { TICK_OFF }
    }

    fn send_viewer_frames(&mut self, frames: Vec<viewer_protocol::ViewerFrame>) {
        let mut sink = IpcSink(self.ipc.as_ref());
        self.host.send_viewer_frames(&mut sink, frames);
    }

    fn flush_output(&mut self, cx: &mut Context<Self>) {
        self.with_host(cx, |host, env, sink| host.flush_output(env, sink));
    }

    /// Follow the settings: start, stop or restart the agent.
    fn apply_settings(&mut self, settings: &RemoteSettings, cx: &mut Context<Self>) {
        self.viewer.enabled = settings.viewer_enabled;
        self.viewer.set_max_viewers(i64::from(settings.viewer_max));
        self.viewer.auto_approve_known = settings.viewer_auto_approve_known;
        self.viewer.known_ids = settings.viewer_known_ids.iter().cloned().collect();
        if !self.viewer.enabled && self.viewer.is_sharing {
            self.viewer.stop_sharing();
        }

        let wanted = (settings.enabled, settings.relay_url.trim().to_string());
        let Some(applied) = self.applied.clone() else {
            self.applied = Some(wanted.clone());
            if wanted.0 {
                self.start_agent(cx);
            }
            self.refresh_devices(cx);
            return;
        };
        if applied == wanted {
            return;
        }
        self.applied = Some(wanted.clone());
        match (applied.0, wanted.0) {
            (false, true) => self.start_agent(cx),
            (true, false) => self.stop_agent(),
            // The relay URL changed: a running agent restarts.
            (true, true) => self.restart_agent_if_running(cx),
            (false, false) => {}
        }
    }

    fn start_agent(&mut self, cx: &mut Context<Self>) {
        if self.agent.is_some() || self.start_pending || self.shutting_down {
            return;
        }
        self.start_generation = self.start_generation.wrapping_add(1);
        let generation = self.start_generation;
        self.start_pending = true;
        let root = self.root.clone();
        let relay = self
            .applied
            .as_ref()
            .map(|(_, url)| url.clone())
            .unwrap_or_else(|| Settings::get(cx).remote.relay_url.clone());
        let preparation = cx.background_executor().spawn(async move {
            let binary = agent::binary_path(&root)?;
            agent::prepare_credentials(&binary, &root)?;
            Ok::<_, String>((binary, root, relay, crate::platform::system::host_name()))
        });
        cx.spawn(async move |weak, cx| {
            let prepared = preparation.await;
            let job = weak
                .update(cx, |rc, cx| {
                    if !rc.accepts_start(generation) {
                        return None;
                    }
                    let (binary, root, relay, name) = match prepared {
                        Ok(prepared) => prepared,
                        Err(error) => {
                            rc.start_pending = false;
                            rc.host.last_error = Some(error);
                            cx.refresh_windows();
                            return None;
                        }
                    };
                    // Binding a Unix socket is small. Expensive binary sync, identity
                    // preparation and process startup are delegated to workers.
                    if rc.ipc.is_none() {
                        match IpcServer::start(&rc.root.remote_socket()) {
                            Ok(server) => rc.ipc = Some(server),
                            Err(error) => {
                                rc.start_pending = false;
                                rc.host.last_error =
                                    Some(format!("Cannot start remote agent: {error}"));
                                return None;
                            }
                        }
                    }
                    Some(
                        cx.background_executor().spawn(async move {
                            AgentProcess::spawn(&binary, &root, &relay, name)
                        }),
                    )
                })
                .ok()
                .flatten();
            let Some(job) = job else { return };
            let result = job.await;
            let _ = weak.update(cx, |rc, cx| {
                if !rc.accepts_start(generation) {
                    // AgentProcess owns an asynchronous reaper, including stale completions.
                    drop(result);
                    return;
                }
                rc.start_pending = false;
                match result {
                    Ok(process) => {
                        rc.agent = Some(process);
                        rc.host.last_error = None;
                    }
                    Err(error) => {
                        rc.host.last_error = Some(error);
                    }
                }
                rc.refresh_devices(cx);
                cx.refresh_windows();
            });
        })
        .detach();
    }

    fn accepts_start(&self, generation: u64) -> bool {
        start_is_current(
            generation,
            self.start_generation,
            self.start_pending,
            self.shutting_down,
            self.applied.as_ref().is_some_and(|(enabled, _)| *enabled),
        )
    }

    fn invalidate_grid(&mut self) {
        self.grid_epoch = self.grid_epoch.wrapping_add(1);
        self.grid_context = None;
        self.grid_worker.invalidate();
    }

    fn stop_agent(&mut self) {
        self.invalidate_grid();
        self.grid_worker.stop();
        self.start_generation = self.start_generation.wrapping_add(1);
        self.start_pending = false;
        if let Some(agent) = self.agent.take() {
            agent.stop();
        }
        self.host.on_agent_stopped();
        if let Some(mut ipc) = self.ipc.take() {
            ipc.stop();
        }
        if self.host.ipc_connected {
            self.host.on_disconnected();
        }
    }

    fn restart_agent_if_running(&mut self, cx: &mut Context<Self>) {
        if !self.applied.as_ref().is_some_and(|(enabled, _)| *enabled) {
            return;
        }
        self.stop_agent();
        self.start_agent(cx);
    }

    fn shutdown(&mut self) {
        self.shutting_down = true;
        self.stop_agent();
    }

    fn refresh_devices(&mut self, cx: &mut Context<Self>) {
        if self.shutting_down {
            return;
        }
        if self.devices_refreshing {
            self.devices_refresh_again = true;
            return;
        }
        self.devices_refreshing = true;
        let path = self.root.remote_state_file();
        let read = cx.background_executor().spawn(async move {
            use std::io::Read;
            match std::fs::File::open(path) {
                Ok(file) => {
                    let mut text = String::new();
                    file.take(1024 * 1024 + 1)
                        .read_to_string(&mut text)
                        .map_err(|_| ())?;
                    if text.len() > 1024 * 1024 {
                        return Err(());
                    }
                    agent_state::paired_devices(&text).map_err(|_| ())
                }
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(Vec::new()),
                Err(_) => Err(()),
            }
        });
        cx.spawn(async move |weak, cx| {
            let result = read.await;
            let _ = weak.update(cx, |rc, cx| {
                rc.devices_refreshing = false;
                if rc.shutting_down {
                    return;
                }
                match result {
                    Ok(devices) => rc.devices = devices,
                    Err(()) => log::warn!("Failed to read bounded remote paired-device state"),
                }
                if std::mem::take(&mut rc.devices_refresh_again) {
                    rc.refresh_devices(cx);
                }
                cx.refresh_windows();
            });
        })
        .detach();
    }

    fn revoke(&mut self, id: &str, cx: &mut Context<Self>) {
        let path = self.root.remote_state_file();
        let result = std::fs::read_to_string(&path)
            .map_err(|e| e.to_string())
            .and_then(|text| agent_state::remove_paired_device(&text, id))
            .and_then(|updated| match updated {
                Some(text) => write_private(&path, &text).map_err(|e| e.to_string()),
                None => Ok(()),
            });
        match result {
            Ok(()) => {
                self.host.on_device_revoked(id);
                self.refresh_devices(cx);
                self.restart_agent_if_running(cx);
            }
            Err(err) => {
                log::error!("Failed to revoke paired device: {err}");
                self.host.last_error = Some("Failed to revoke paired device".into());
            }
        }
        cx.refresh_windows();
    }
}

/// Write the agent state file atomically, readable by the user only.
fn write_private(path: &std::path::Path, text: &str) -> std::io::Result<()> {
    let dir = path.parent().unwrap_or(std::path::Path::new("."));
    std::fs::create_dir_all(dir)?;
    let tmp = dir.join(format!(".state-{}.tmp", std::process::id()));
    std::fs::write(&tmp, text)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&tmp, std::fs::Permissions::from_mode(0o600))?;
    }
    std::fs::rename(&tmp, path)
}

#[cfg(all(test, unix))]
mod e2e_tests;

/// A disabled setting, changed relay or app quit invalidates all late completions.
fn start_is_current(
    requested: u64,
    current: u64,
    pending: bool,
    shutting_down: bool,
    enabled: bool,
) -> bool {
    requested == current && pending && !shutting_down && enabled
}

#[cfg(test)]
mod startup_tests {
    use super::*;
    #[test]
    fn grid_epoch_changes_on_connection_mode_tab_and_pane_session_transitions() {
        let initial = GridContext {
            connected: true,
            streams_terminal: true,
            tab: Some(1),
            session: Some(100),
        };
        let mut current = None;
        let mut epoch = 0;
        assert!(advance_grid_context(&mut current, &mut epoch, initial));
        assert_eq!(epoch, 1);
        assert!(!advance_grid_context(&mut current, &mut epoch, initial));
        for next in [
            GridContext {
                connected: false,
                ..initial
            },
            GridContext {
                streams_terminal: false,
                ..initial
            },
            GridContext {
                tab: Some(2),
                ..initial
            },
            GridContext {
                session: Some(200),
                ..initial
            },
            initial,
        ] {
            let previous = epoch;
            assert!(advance_grid_context(&mut current, &mut epoch, next));
            assert_eq!(epoch, previous + 1);
        }
    }
    #[test]
    fn only_current_enabled_pending_start_can_publish() {
        assert!(start_is_current(5, 5, true, false, true));
        assert!(!start_is_current(5, 6, true, false, true));
        assert!(!start_is_current(5, 5, false, false, true));
        assert!(!start_is_current(5, 5, true, true, true));
        assert!(!start_is_current(5, 5, true, false, false));
    }
}
