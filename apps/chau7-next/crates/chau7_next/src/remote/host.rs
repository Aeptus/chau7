//! What the phone sees and may do (`RemoteControlManager.swift`, minus the
//! agent process and the UI): tab list, snapshots, output of the selected
//! tab, input with protected actions, approvals, AI activity and interactive
//! prompts.
//!
//! [`RemoteHost`] has no GPUI in it: the app hands it a [`HostEnv`] (tabs,
//! sessions, input) and a [`FrameSink`] (the IPC socket), so the whole
//! protocol is tested with a fake app and a fake agent.

use std::collections::HashMap;

use chau7_next_core::interactive_prompt_detector;
use chau7_next_core::monitoring::claude_code::ClaudeCodeEvent;
use chau7_next_core::remote::activity_state::{
    self, RemoteActivityApproval, RemoteActivityCandidate, RemoteActivityState,
    RemoteActivityStatus,
};
use chau7_next_core::remote::frame::{RemoteFrame, RemoteFrameType};
use chau7_next_core::remote::interactive_prompt::{
    RemoteInteractivePrompt, RemoteInteractivePromptListPayload,
};
use chau7_next_core::remote::key_input::{RemoteKey, RemoteKeyInput, navigation_keys};
use chau7_next_core::remote::models::{
    ApprovalRequestPayload, ApprovalResponsePayload, RemoteClientAppState,
    RemoteClientStatePayload, RemoteClientStreamMode, RemoteErrorPayload, RemotePairingInfo,
    RemoteSessionStatus, RemoteTabDescriptor, RemoteTabListPayload, RemoteTabSwitchPayload,
};
use chau7_next_core::remote::output_buffering::RemoteOutputTuning;
use chau7_next_core::remote::prompt_response::{Action, RemotePaneInput, RemotePromptResponse};
use chau7_next_core::remote::protection;
use chau7_next_core::remote::structured_prompt::StructuredPromptStore;
use chau7_next_core::remote::tab_registry::{RemoteTabRegistry, RemoteTabRegistryEntry};
use chau7_next_core::remote::viewer_protocol::{
    ViewerFrame, ViewerJoinPayload, ViewerLeavePayload,
};
use chau7_next_core::shell_session::CommandStatus;
use chau7_next_core::telemetry::remote_client_event::RemoteClientTelemetryEvent;
use chrono::{DateTime, SecondsFormat, Utc};

/// The app's own tab identity (the Swift tab UUID).
pub type TabKey = u64;

/// A protected input expires after this long without an answer.
const PROTECTED_INPUT_TTL_SECS: i64 = 120;
/// At most this many protected inputs wait at once (oldest dropped).
const MAX_PENDING_PROTECTED_INPUTS: usize = 20;
/// A finished command shows as completed or failed for this long.
const RECENT_COMPLETION_SECS: i64 = 20;

/// One terminal pane of a tab.
#[derive(Debug, Clone, PartialEq)]
pub struct PaneInfo {
    /// Pane identity (`paneID` in activity and prompt IDs).
    pub pane_id: u64,
    /// The pane's terminal session.
    pub session_id: u64,
    /// `aiDisplayAppName`: the AI tool running in the pane.
    pub ai_app: Option<String>,
    /// `effectiveAIProvider`.
    pub ai_provider: Option<String>,
    /// `effectiveAISessionId`.
    pub ai_session_id: Option<String>,
    pub status: CommandStatus,
    pub at_prompt: bool,
    pub cwd: Option<String>,
    pub git_branch: Option<String>,
    /// When output last arrived (`lastOutputDate`).
    pub last_output_at: Option<DateTime<Utc>>,
}

/// The tab's last command (`tab.lastCommand`).
#[derive(Debug, Clone, PartialEq)]
pub struct LastCommandInfo {
    pub command: String,
    pub start_time: DateTime<Utc>,
    pub end_time: Option<DateTime<Utc>>,
    pub exit_code: Option<i64>,
}

/// A tab that has at least one terminal session.
#[derive(Debug, Clone, PartialEq)]
pub struct TabInfo {
    pub key: TabKey,
    /// `displayTitle`.
    pub title: String,
    pub custom_title: Option<String>,
    pub is_mcp_controlled: bool,
    /// The tab's main pane (the focused one): its output and snapshots go to
    /// the phone. An index into `panes`.
    pub main_pane: usize,
    pub panes: Vec<PaneInfo>,
    pub last_command: Option<LastCommandInfo>,
}

impl TabInfo {
    fn main(&self) -> Option<&PaneInfo> {
        self.panes.get(self.main_pane)
    }

    /// `activityTabTitle`: the custom title, else the display title.
    fn activity_title(&self) -> String {
        match self.custom_title.as_deref().map(str::trim) {
            Some(custom) if !custom.is_empty() => custom.to_string(),
            _ => self.title.clone(),
        }
    }
}

/// What the host needs from the app.
pub trait HostEnv {
    /// Every tab with a terminal session, in order.
    fn tabs(&mut self) -> Vec<TabInfo>;
    /// The selected tab.
    fn selected(&mut self) -> Option<TabKey>;
    /// Select a tab (in its window). False when it is gone.
    fn select(&mut self, key: TabKey) -> bool;
    /// The main pane's whole buffer as text.
    fn text_snapshot(&mut self, key: TabKey) -> Option<Vec<u8>>;
    /// The main pane's grid (`CHG1`).
    fn grid_snapshot(&mut self, key: TabKey) -> Option<Vec<u8>>;
    /// The last lines of a pane, for prompt detection.
    fn pane_text(&mut self, key: TabKey, pane_id: u64) -> Option<String>;
    /// Type `text` in the tab's main pane. False when it cannot.
    fn write_input(&mut self, key: TabKey, text: &str) -> bool;
    fn write_pane_input(&mut self, _key: TabKey, _pane_id: u64, _text: &str) -> bool {
        false
    }
    fn write_keys(&mut self, _key: TabKey, _pane_id: Option<u64>, _keys: &[RemoteKey]) -> bool {
        false
    }
    /// Clear the tab's persistent notification style (approval answered).
    fn clear_persistent_style(&mut self, key: TabKey);
    /// Answer an MCP command approval (`TerminalControlService.resolveApproval`).
    fn resolve_approval(&mut self, request_id: &str, approved: bool);
    /// Store an iOS telemetry event (TEL-015).
    fn store_telemetry(&mut self, event: RemoteClientTelemetryEvent);
    fn now(&self) -> DateTime<Utc>;
}

/// Where frames for the agent go.
pub trait FrameSink {
    fn send(&mut self, frame: RemoteFrame);
}

impl FrameSink for Vec<RemoteFrame> {
    fn send(&mut self, frame: RemoteFrame) {
        self.push(frame);
    }
}

/// An input held until the phone approves it (`ProtectedRemoteInput`).
#[derive(Debug, Clone)]
struct ProtectedInput {
    tab_id: u32,
    pane_id: Option<u64>,
    text: String,
    created_at: DateTime<Utc>,
}

/// An approval shown on the phone (`PendingRemoteApprovalContext`).
#[derive(Debug, Clone)]
struct ApprovalContext {
    request_id: String,
    tab_id: u32,
    tab_title: String,
    tool_name: String,
    project_name: Option<String>,
    branch_name: Option<String>,
    current_directory: Option<String>,
    recent_command: Option<String>,
    context_note: Option<String>,
    session_id: Option<String>,
    command: String,
    flagged_command: String,
    requested_at: DateTime<Utc>,
}

impl ApprovalContext {
    fn approval(&self) -> RemoteActivityApproval {
        RemoteActivityApproval::new(&self.request_id, &self.command, &self.flagged_command)
    }

    fn payload(&self) -> ApprovalRequestPayload {
        ApprovalRequestPayload {
            request_id: self.request_id.clone(),
            command: self.command.clone(),
            flagged_command: self.flagged_command.clone(),
            timestamp: iso8601(self.requested_at),
            tab_title: Some(self.tab_title.clone()),
            tool_name: Some(self.tool_name.clone()),
            project_name: self.project_name.clone(),
            branch_name: self.branch_name.clone(),
            current_directory: self.current_directory.clone(),
            recent_command: self.recent_command.clone(),
            context_note: self.context_note.clone(),
            session_id: self.session_id.clone(),
        }
    }
}

/// `ISO8601DateFormatter` output: seconds, `Z`.
pub fn iso8601(date: DateTime<Utc>) -> String {
    date.to_rfc3339_opts(SecondsFormat::Secs, true)
}

fn parse_iso8601(text: &str, now: DateTime<Utc>) -> DateTime<Utc> {
    DateTime::parse_from_rfc3339(text)
        .map(|d| d.with_timezone(&Utc))
        .unwrap_or(now)
}

fn trimmed(value: Option<&str>) -> Option<String> {
    value
        .map(str::trim)
        .filter(|v| !v.is_empty())
        .map(str::to_string)
}

/// Swift `String.capitalized`: first letter of each word upper case.
fn capitalized(text: &str) -> String {
    text.split(' ')
        .map(|word| {
            let mut chars = word.chars();
            match chars.next() {
                Some(first) => first
                    .to_uppercase()
                    .chain(chars.flat_map(char::to_lowercase))
                    .collect(),
                None => String::new(),
            }
        })
        .collect::<Vec<_>>()
        .join(" ")
}

fn tool_name(pane: &PaneInfo, tab: &TabInfo) -> String {
    if let Some(name) = trimmed(pane.ai_app.as_deref()) {
        return name;
    }
    if let Some(provider) = trimmed(pane.ai_provider.as_deref()) {
        return capitalized(&provider);
    }
    tab.activity_title()
}

fn project_name(pane: &PaneInfo) -> Option<String> {
    let dir = trimmed(pane.cwd.as_deref())?;
    let last = std::path::Path::new(&dir)
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_default();
    Some(if last.is_empty() { dir } else { last })
}

fn context_note(pane: &PaneInfo) -> Option<String> {
    match pane.status {
        CommandStatus::ApprovalRequired => Some("Approval required".into()),
        CommandStatus::WaitingForInput => Some(if pane.at_prompt {
            "Waiting at prompt".into()
        } else {
            "Waiting for input".into()
        }),
        CommandStatus::Running => Some("Command is running".into()),
        CommandStatus::Stuck => Some("No output for a while".into()),
        CommandStatus::Idle | CommandStatus::Done | CommandStatus::Exited => None,
    }
}

fn recent_command(tab: &TabInfo) -> Option<String> {
    trimmed(tab.last_command.as_ref().map(|c| c.command.as_str()))
}

fn updated_at(pane: &PaneInfo, tab: &TabInfo, now: DateTime<Utc>) -> DateTime<Utc> {
    let command = tab.last_command.as_ref();
    [
        command.and_then(|c| c.end_time),
        command.map(|c| c.start_time),
        pane.last_output_at,
    ]
    .into_iter()
    .flatten()
    .max()
    .unwrap_or(now)
}

/// `recentCompletionStatus`: the last command finished less than 20 s ago.
fn recent_completion(
    tab: &TabInfo,
    now: DateTime<Utc>,
) -> Option<(RemoteActivityStatus, Option<String>)> {
    let command = tab.last_command.as_ref()?;
    let end = command.end_time?;
    if (now - end).num_milliseconds() > RECENT_COMPLETION_SECS * 1000 {
        return None;
    }
    let text = command.command.trim();
    let code = command.exit_code.unwrap_or(0);
    if code == 0 {
        return Some((
            RemoteActivityStatus::Completed,
            (!text.is_empty()).then(|| text.to_string()),
        ));
    }
    Some((
        RemoteActivityStatus::Failed,
        Some(if text.is_empty() {
            format!("Exit {code}")
        } else {
            format!("Exit {code}: {text}")
        }),
    ))
}

/// Pane IDs as lowercase UUID strings, like the Swift pane UUIDs.
pub fn pane_uuid(pane_id: u64) -> String {
    uuid::Uuid::from_u64_pair(0, pane_id).to_string()
}

#[derive(Default)]
pub struct RemoteHost {
    registry: RemoteTabRegistry<TabKey>,
    seq: u64,
    /// The agent is connected to the socket.
    pub ipc_connected: bool,
    /// `connecting`, `ready` or `disconnected`, from the agent.
    pub session_status: Option<String>,
    pub connected_device_id: Option<String>,
    pub connected_device_name: Option<String>,
    pub pairing_info: Option<RemotePairingInfo>,
    pub last_error: Option<String>,
    app_state: RemoteClientAppState,
    stream_mode: RemoteClientStreamMode,
    pending_protected: HashMap<String, ProtectedInput>,
    approvals: HashMap<String, ApprovalContext>,
    pub activity: Option<RemoteActivityState>,
    pub prompts: Vec<RemoteInteractivePrompt>,
    structured: StructuredPromptStore,
    answered_prompts: HashMap<String, DateTime<Utc>>,
    last_tab_list: Option<Vec<RemoteTabDescriptor>>,
    selected_tab_id: Option<u32>,
    /// Output of the selected tab not sent yet, with its tab ID.
    pending_output: Option<(u32, Vec<u8>)>,
    /// The paired devices may have changed: reread the agent's state file.
    pub devices_dirty: bool,
    /// Viewer joins and leaves from the agent, for the app's viewer state
    /// (RMT-027); drained by `RemoteControl`.
    pub viewer_inbox: Vec<ViewerInbound>,
}

/// A viewer message from the agent.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ViewerInbound {
    Join(ViewerJoinPayload),
    Leave(String),
}

impl RemoteHost {
    pub fn new() -> Self {
        Self {
            seq: 1,
            devices_dirty: true,
            ..Default::default()
        }
    }

    /// Send viewer frames (`viewer_protocol`) to the agent.
    pub fn send_viewer_frames(&mut self, sink: &mut dyn FrameSink, frames: Vec<ViewerFrame>) {
        for (kind, payload) in frames {
            self.send(sink, kind, 0, payload);
        }
    }

    fn full(&self) -> bool {
        self.stream_mode == RemoteClientStreamMode::Full
    }

    fn next_seq(&mut self) -> u64 {
        let seq = self.seq;
        self.seq = self.seq.wrapping_add(1);
        seq
    }

    fn send(
        &mut self,
        sink: &mut dyn FrameSink,
        kind: RemoteFrameType,
        tab_id: u32,
        payload: Vec<u8>,
    ) {
        let seq = self.next_seq();
        sink.send(RemoteFrame::new(kind.raw_value(), tab_id, seq, payload));
    }

    fn send_json<T: serde::Serialize>(
        &mut self,
        sink: &mut dyn FrameSink,
        kind: RemoteFrameType,
        tab_id: u32,
        value: &T,
    ) {
        match serde_json::to_vec(value) {
            Ok(payload) => self.send(sink, kind, tab_id, payload),
            Err(err) => log::warn!("Remote: failed to encode {kind:?}: {err}"),
        }
    }

    fn send_error(&mut self, sink: &mut dyn FrameSink, code: &str, message: &str, tab_id: u32) {
        let payload = RemoteErrorPayload {
            code: code.into(),
            message: message.into(),
        };
        self.send_json(sink, RemoteFrameType::Error, tab_id, &payload);
    }

    // ----- connection -------------------------------------------------------

    /// The agent connected to the socket.
    pub fn on_connected(&mut self, env: &mut dyn HostEnv, sink: &mut dyn FrameSink) {
        self.ipc_connected = true;
        self.send_initial_state(env, sink);
    }

    /// The agent went away.
    pub fn on_disconnected(&mut self) {
        self.ipc_connected = false;
        self.session_status = None;
        self.connected_device_id = None;
        self.connected_device_name = None;
        self.app_state = RemoteClientAppState::Foreground;
        self.stream_mode = RemoteClientStreamMode::Full;
        self.activity = None;
        self.pending_output = None;
        self.devices_dirty = true;
    }

    /// The agent was stopped (`stopAgent`).
    pub fn on_agent_stopped(&mut self) {
        self.pending_output = None;
        self.pending_protected.clear();
    }

    /// Revoking the connected device marks the session disconnected.
    pub fn on_device_revoked(&mut self, id: &str) {
        if self.connected_device_id.as_deref() == Some(id) {
            self.connected_device_id = None;
            self.connected_device_name = None;
            self.session_status = Some("disconnected".into());
        }
        self.devices_dirty = true;
    }

    fn send_initial_state(&mut self, env: &mut dyn HostEnv, sink: &mut dyn FrameSink) {
        self.send_pending_approvals(env, sink);
        if !self.full() {
            self.send_prompts(env, sink, true);
            return;
        }
        self.send_tab_list(env, sink, true);
        self.send_selected_snapshot(env, sink);
        self.send_activity(env, sink, true);
    }

    // ----- frames from the agent --------------------------------------------

    pub fn handle_frame(
        &mut self,
        frame: RemoteFrame,
        env: &mut dyn HostEnv,
        sink: &mut dyn FrameSink,
    ) {
        let Some(kind) = frame.frame_type() else {
            log::warn!("Unknown IPC frame type: 0x{:x}", frame.type_);
            return;
        };
        fn decode<T: serde::de::DeserializeOwned>(frame: &RemoteFrame, what: &str) -> Option<T> {
            serde_json::from_slice(&frame.payload)
                .map_err(|err| log::warn!("Failed to decode {what}: {err}"))
                .ok()
        }
        match kind {
            RemoteFrameType::PairingInfo => {
                if let Some(info) = decode::<RemotePairingInfo>(&frame, "pairing info") {
                    self.pairing_info = Some(info);
                    self.devices_dirty = true;
                }
            }
            RemoteFrameType::SessionReady => {
                self.ipc_connected = true;
                self.send_initial_state(env, sink);
            }
            RemoteFrameType::SessionStatus => {
                let Some(status) = decode::<RemoteSessionStatus>(&frame, "session status") else {
                    return;
                };
                let ready = status.status == "ready";
                self.session_status = Some(status.status);
                self.connected_device_id = status.paired_device_id.filter(|s| !s.is_empty());
                self.connected_device_name = status.paired_device_name.filter(|s| !s.is_empty());
                if ready {
                    self.send_initial_state(env, sink);
                }
                self.devices_dirty = true;
            }
            RemoteFrameType::TabSwitch => {
                let Some(payload) = decode::<RemoteTabSwitchPayload>(&frame, "tab switch") else {
                    return;
                };
                match self.registry.key(payload.tab_id) {
                    Some(key) if env.select(key) => {
                        self.selected_tab_id = Some(payload.tab_id);
                        self.send_snapshot(env, sink, payload.tab_id);
                    }
                    _ => self.send_error(
                        sink,
                        "tab_unavailable",
                        "That tab is no longer available for remote control.",
                        payload.tab_id,
                    ),
                }
            }
            RemoteFrameType::Input => self.handle_input(frame, env, sink),
            RemoteFrameType::KeyInput => self.handle_keys(frame, env, sink),
            RemoteFrameType::PaneInput => self.handle_pane_input(frame, env, sink),
            RemoteFrameType::InteractivePromptResponse => {
                self.handle_prompt_response(frame, env, sink)
            }
            RemoteFrameType::RemoteTelemetry => {
                if let Some(event) =
                    decode::<RemoteClientTelemetryEvent>(&frame, "remote telemetry")
                {
                    env.store_telemetry(event);
                }
            }
            RemoteFrameType::ClientState => {
                let Some(payload) = decode::<RemoteClientStatePayload>(&frame, "client state")
                else {
                    return;
                };
                self.app_state = payload.app_state;
                let previous = self.stream_mode;
                self.stream_mode = payload.stream_mode;
                if previous != payload.stream_mode
                    && payload.stream_mode == RemoteClientStreamMode::ApprovalsOnly
                {
                    self.pending_output = None;
                }
                if payload.stream_mode == RemoteClientStreamMode::Full {
                    self.send_initial_state(env, sink);
                } else {
                    self.send_pending_approvals(env, sink);
                    self.send_prompts(env, sink, true);
                }
            }
            RemoteFrameType::ApprovalResponse => self.handle_approval_response(frame, env, sink),
            RemoteFrameType::ViewerJoin => {
                if let Some(join) = decode::<ViewerJoinPayload>(&frame, "viewer join") {
                    self.viewer_inbox.push(ViewerInbound::Join(join));
                }
            }
            RemoteFrameType::ViewerLeave => {
                if let Some(leave) = decode::<ViewerLeavePayload>(&frame, "viewer leave") {
                    self.viewer_inbox
                        .push(ViewerInbound::Leave(leave.viewer_id));
                }
            }
            RemoteFrameType::Ping => {
                self.send(sink, RemoteFrameType::Pong, frame.tab_id, frame.payload);
            }
            RemoteFrameType::Error => {
                if let Ok(message) = String::from_utf8(frame.payload) {
                    self.last_error = Some(message);
                }
            }
            other => log::debug!("Unhandled IPC frame type: {other:?}"),
        }
    }

    fn resolve_input_target(
        &mut self,
        env: &mut dyn HostEnv,
        tab_id: u32,
    ) -> Option<(TabKey, u32)> {
        if tab_id == 0 {
            let key = env.selected()?;
            let id = self.registry.tab_id(key)?;
            return Some((key, id));
        }
        let key = self.registry.key(tab_id)?;
        env.tabs()
            .iter()
            .any(|t| t.key == key)
            .then_some((key, tab_id))
    }

    fn handle_input(
        &mut self,
        frame: RemoteFrame,
        env: &mut dyn HostEnv,
        sink: &mut dyn FrameSink,
    ) {
        let tab_id = frame.tab_id;
        let Ok(text) = String::from_utf8(frame.payload) else {
            self.send_error(
                sink,
                "invalid_input_encoding",
                "Remote input must be valid UTF-8.",
                tab_id,
            );
            return;
        };
        let Some((key, resolved)) = self.resolve_input_target(env, tab_id) else {
            self.send_error(
                sink,
                "tab_unavailable",
                "That tab cannot receive remote input right now.",
                tab_id,
            );
            return;
        };
        if let Some(flagged) = protection::flagged_termination_action(&text) {
            let request_id = uuid::Uuid::new_v4().to_string().to_uppercase();
            self.queue_protected_input(env, sink, request_id, text, (resolved, None), flagged);
            return;
        }
        if !env.write_input(key, &text) {
            self.send_error(
                sink,
                "tab_unavailable",
                "That tab cannot receive remote input right now.",
                tab_id,
            );
        }
    }

    pub fn ingest_claude_event(
        &mut self,
        event: &ClaudeCodeEvent,
        tab: Option<TabKey>,
        now: DateTime<Utc>,
    ) {
        self.structured.apply(event, tab, now);
    }

    fn handle_keys(&mut self, frame: RemoteFrame, env: &mut dyn HostEnv, sink: &mut dyn FrameSink) {
        let Ok(input) = serde_json::from_slice::<RemoteKeyInput>(&frame.payload) else {
            return;
        };
        let Some((key, _)) = self.resolve_input_target(env, frame.tab_id) else {
            return;
        };
        if !env.write_keys(key, None, &input.keys) {
            self.send_error(
                sink,
                "tab_unavailable",
                "That tab cannot receive keys right now.",
                frame.tab_id,
            );
        }
    }
    fn handle_pane_input(
        &mut self,
        frame: RemoteFrame,
        env: &mut dyn HostEnv,
        sink: &mut dyn FrameSink,
    ) {
        let Ok(input) = serde_json::from_slice::<RemotePaneInput>(&frame.payload) else {
            return;
        };
        let Some((key, resolved)) = self.resolve_input_target(env, frame.tab_id) else {
            return;
        };
        let tabs = env.tabs();
        let Some(pane) = tabs.iter().find(|tab| tab.key == key).and_then(|tab| {
            tab.panes
                .iter()
                .find(|pane| uuid::Uuid::from_u64_pair(0, pane.pane_id) == input.pane_id)
        }) else {
            return;
        };
        match (input.text, input.keys) {
            (Some(text), None) if text.len() <= 16384 => {
                if let Some(flagged) = protection::flagged_termination_action(&text) {
                    self.queue_protected_input(
                        env,
                        sink,
                        uuid::Uuid::new_v4().to_string(),
                        text,
                        (resolved, Some(pane.pane_id)),
                        flagged,
                    );
                } else {
                    env.write_pane_input(key, pane.pane_id, &text);
                }
            }
            (None, Some(keys)) => {
                env.write_keys(key, Some(pane.pane_id), &keys);
            }
            _ => {}
        }
    }
    fn handle_prompt_response(
        &mut self,
        frame: RemoteFrame,
        env: &mut dyn HostEnv,
        sink: &mut dyn FrameSink,
    ) {
        let Ok(response) = serde_json::from_slice::<RemotePromptResponse>(&frame.payload) else {
            return;
        };
        if self.answered_prompts.contains_key(&response.prompt_id) {
            self.send_error(
                sink,
                "stale_prompt",
                "That prompt has already been answered. Refresh before answering.",
                frame.tab_id,
            );
            self.send_activity(env, sink, true);
            return;
        }
        let Some((key, resolved)) = self.resolve_input_target(env, frame.tab_id) else {
            return;
        };
        let tabs = env.tabs();
        let now = env.now();
        let prompts = self.current_prompts(env, &tabs, now);
        let Some(prompt) = prompts
            .iter()
            .find(|prompt| prompt.id == response.prompt_id)
        else {
            self.send_error(
                sink,
                "stale_prompt",
                "That prompt or terminal pane is no longer available. Refresh before answering.",
                frame.tab_id,
            );
            self.send_activity(env, sink, true);
            return;
        };
        let panes: Vec<uuid::Uuid> = tabs
            .iter()
            .filter(|tab| tab.key == key)
            .flat_map(|tab| &tab.panes)
            .map(|pane| uuid::Uuid::from_u64_pair(0, pane.pane_id))
            .collect();
        let Some(text) = response.response_text(prompt, resolved, &panes) else {
            self.send_error(
                sink,
                "stale_prompt",
                "That prompt or terminal pane is no longer available. Refresh before answering.",
                frame.tab_id,
            );
            self.send_activity(env, sink, true);
            return;
        };
        let pane = response.pane_id.as_u64_pair().1;
        let written = if let Some(flagged) = protection::flagged_termination_action(&text) {
            self.queue_protected_input(
                env,
                sink,
                uuid::Uuid::new_v4().to_string(),
                text,
                (resolved, Some(pane)),
                flagged,
            );
            return;
        } else if let Some(keys) = navigation_keys(&text) {
            env.write_keys(key, Some(pane), &keys)
        } else {
            env.write_pane_input(key, pane, &text)
        };
        if written && response.action != Action::Toggle {
            if self.answered_prompts.len() >= 128
                && let Some(oldest) = self
                    .answered_prompts
                    .iter()
                    .min_by_key(|(_, at)| *at)
                    .map(|(id, _)| id.clone())
            {
                self.answered_prompts.remove(&oldest);
            }
            self.answered_prompts.insert(response.prompt_id, env.now());
        }
        self.send_activity(env, sink, true);
    }

    // ----- approvals --------------------------------------------------------

    fn purge_expired(&mut self, now: DateTime<Utc>) {
        let expired: Vec<String> = self
            .pending_protected
            .iter()
            .filter(|(_, p)| {
                (now - p.created_at).num_milliseconds() > PROTECTED_INPUT_TTL_SECS * 1000
            })
            .map(|(k, _)| k.clone())
            .collect();
        for key in expired {
            if let Some(input) = self.pending_protected.remove(&key) {
                log::info!(
                    "Remote: expired protected action for tab {} after {PROTECTED_INPUT_TTL_SECS}s",
                    input.tab_id
                );
            }
            self.approvals.remove(&key);
        }
    }

    fn tab_and_main(&self, tabs: &[TabInfo], tab_id: u32) -> Option<TabInfo> {
        let key = self.registry.key(tab_id)?;
        tabs.iter().find(|t| t.key == key).cloned()
    }

    fn context_for(
        &self,
        tab: &TabInfo,
        tab_id: u32,
        request: &ApprovalRequestPayload,
        now: DateTime<Utc>,
    ) -> Option<ApprovalContext> {
        let pane = tab.main()?;
        Some(ApprovalContext {
            request_id: request.request_id.clone(),
            tab_id,
            tab_title: request
                .tab_title
                .clone()
                .unwrap_or_else(|| tab.activity_title()),
            tool_name: request
                .tool_name
                .clone()
                .unwrap_or_else(|| tool_name(pane, tab)),
            project_name: request.project_name.clone().or_else(|| project_name(pane)),
            branch_name: request
                .branch_name
                .clone()
                .or_else(|| trimmed(pane.git_branch.as_deref())),
            current_directory: request
                .current_directory
                .clone()
                .or_else(|| trimmed(pane.cwd.as_deref())),
            recent_command: request
                .recent_command
                .clone()
                .or_else(|| recent_command(tab)),
            context_note: request.context_note.clone().or_else(|| context_note(pane)),
            session_id: request
                .session_id
                .clone()
                .or_else(|| pane.ai_session_id.clone()),
            command: request.command.clone(),
            flagged_command: request.flagged_command.clone(),
            requested_at: parse_iso8601(&request.timestamp, now),
        })
    }

    /// `registerApprovalContext`: tie the request to the protected input's
    /// tab, else to the selected tab.
    fn register_approval(&mut self, env: &mut dyn HostEnv, request: &ApprovalRequestPayload) {
        let now = env.now();
        let tabs = env.tabs();
        let target = match self.pending_protected.get(&request.request_id) {
            Some(input) => Some(input.tab_id),
            None => env.selected().and_then(|key| self.registry.tab_id(key)),
        };
        let Some(tab_id) = target else { return };
        let Some(tab) = self.tab_and_main(&tabs, tab_id) else {
            return;
        };
        if let Some(context) = self.context_for(&tab, tab_id, request, now) {
            self.approvals.insert(request.request_id.clone(), context);
        }
    }

    /// Show an approval on the phone (`sendApprovalRequest`). MCP command
    /// approvals come here; nothing is kept while the agent is not connected.
    pub fn send_approval_request(
        &mut self,
        request: &ApprovalRequestPayload,
        env: &mut dyn HostEnv,
        sink: &mut dyn FrameSink,
    ) {
        if !self.ipc_connected {
            return;
        }
        self.register_approval(env, request);
        self.send_json(sink, RemoteFrameType::ApprovalRequest, 0, request);
        self.send_activity(env, sink, false);
        log::info!("Remote: sent approval request {}", request.request_id);
    }

    fn queue_protected_input(
        &mut self,
        env: &mut dyn HostEnv,
        sink: &mut dyn FrameSink,
        request_id: String,
        text: String,
        target: (u32, Option<u64>),
        flagged: &str,
    ) {
        let (tab_id, pane_id) = target;
        let now = env.now();
        self.purge_expired(now);
        if self.pending_protected.len() >= MAX_PENDING_PROTECTED_INPUTS {
            log::warn!(
                "Remote: pending protected inputs at capacity ({MAX_PENDING_PROTECTED_INPUTS}), dropping oldest"
            );
            if let Some(oldest) = self
                .pending_protected
                .iter()
                .min_by_key(|(_, p)| p.created_at)
                .map(|(k, _)| k.clone())
            {
                self.pending_protected.remove(&oldest);
            }
        }
        self.pending_protected.insert(
            request_id.clone(),
            ProtectedInput {
                tab_id,
                pane_id,
                text: text.clone(),
                created_at: now,
            },
        );
        let command = text.trim().to_string();
        let mut request = ApprovalRequestPayload::new(&request_id, &command, flagged, iso8601(now));
        let tabs = env.tabs();
        if let Some(mut tab) = self.tab_and_main(&tabs, tab_id) {
            if let Some(pane) = pane_id
                && let Some(index) = tab.panes.iter().position(|value| value.pane_id == pane)
            {
                tab.main_pane = index;
            }
            if let Some(context) = self.context_for(&tab, tab_id, &request, now) {
                request = context.payload();
                self.approvals.insert(request_id.clone(), context);
            }
        }
        self.send_approval_request(&request, env, sink);
        log::warn!("Remote: queued protected action approval for tab {tab_id}");
    }

    fn handle_approval_response(
        &mut self,
        frame: RemoteFrame,
        env: &mut dyn HostEnv,
        sink: &mut dyn FrameSink,
    ) {
        self.purge_expired(env.now());
        let Ok(response) = serde_json::from_slice::<ApprovalResponsePayload>(&frame.payload) else {
            log::warn!("Failed to decode approval response");
            return;
        };
        let context = self.approvals.remove(&response.request_id);
        if let Some(input) = self.pending_protected.remove(&response.request_id) {
            let key = if input.tab_id == 0 {
                env.selected()
            } else {
                self.registry.key(input.tab_id)
            };
            if response.approved
                && let Some(key) = key
            {
                if let Some(pane) = input.pane_id {
                    env.write_pane_input(key, pane, &input.text);
                } else {
                    env.write_input(key, &input.text);
                }
                log::info!("Remote: protected action approved for tab {}", input.tab_id);
            } else {
                log::info!("Remote: protected action denied for tab {}", input.tab_id);
            }
            self.send_activity(env, sink, false);
            return;
        }
        if let Some(key) = context.and_then(|c| self.registry.key(c.tab_id)) {
            env.clear_persistent_style(key);
        }
        env.resolve_approval(&response.request_id, response.approved);
        self.send_activity(env, sink, false);
        log::info!(
            "Remote: approval response for {}: {}",
            response.request_id,
            if response.approved {
                "allowed"
            } else {
                "denied"
            }
        );
    }

    fn send_pending_approvals(&mut self, env: &mut dyn HostEnv, sink: &mut dyn FrameSink) {
        if !self.ipc_connected {
            return;
        }
        self.purge_expired(env.now());
        let mut contexts: Vec<ApprovalContext> = self.approvals.values().cloned().collect();
        contexts.sort_by_key(|c| c.requested_at);
        for context in contexts {
            self.send_json(
                sink,
                RemoteFrameType::ApprovalRequest,
                0,
                &context.payload(),
            );
        }
    }

    // ----- tabs, snapshots, output ------------------------------------------

    fn entries(tabs: &[TabInfo], selected: Option<TabKey>) -> Vec<RemoteTabRegistryEntry<TabKey>> {
        tabs.iter()
            .map(|tab| {
                let main = tab.main();
                RemoteTabRegistryEntry {
                    key: tab.key,
                    session: main.map(|p| p.session_id),
                    title: tab.title.clone(),
                    project_name: main.and_then(project_name),
                    branch_name: main.and_then(|p| trimmed(p.git_branch.as_deref())),
                    is_active: Some(tab.key) == selected,
                    is_mcp_controlled: tab.is_mcp_controlled,
                }
            })
            .collect()
    }

    /// Rebuild the tab IDs; send the list when it changed (or `force`).
    /// Returns whether it was sent.
    fn send_tab_list(
        &mut self,
        env: &mut dyn HostEnv,
        sink: &mut dyn FrameSink,
        force: bool,
    ) -> bool {
        let tabs = env.tabs();
        let selected = env.selected();
        if tabs.is_empty() {
            log::info!("Remote: no controllable tabs");
        }
        let descriptors = self.registry.rebuild(&Self::entries(&tabs, selected));
        self.selected_tab_id = selected.and_then(|k| self.registry.tab_id(k));
        if !self.full() || (!force && self.last_tab_list.as_ref() == Some(&descriptors)) {
            return false;
        }
        let payload = RemoteTabListPayload {
            capabilities: ["key_input", "scoped_prompt_response", "pane_input"]
                .map(str::to_string)
                .to_vec(),
            tabs: descriptors.clone(),
        };
        self.last_tab_list = Some(descriptors);
        self.send_json(sink, RemoteFrameType::TabList, 0, &payload);
        log::info!("Remote: sent tab list with {} tabs", payload.tabs.len());
        true
    }

    fn send_selected_snapshot(&mut self, env: &mut dyn HostEnv, sink: &mut dyn FrameSink) {
        if !self.full() {
            return;
        }
        if let Some(tab_id) = self.selected_tab_id {
            self.send_snapshot(env, sink, tab_id);
        }
    }

    fn key_for(&self, env: &mut dyn HostEnv, tab_id: u32) -> Option<TabKey> {
        if tab_id == 0 {
            env.selected()
        } else {
            self.registry.key(tab_id)
        }
    }

    /// Text snapshot then grid snapshot of a tab (`sendSnapshot`).
    pub fn send_snapshot(&mut self, env: &mut dyn HostEnv, sink: &mut dyn FrameSink, tab_id: u32) {
        if self.full()
            && let Some(key) = self.key_for(env, tab_id)
            && let Some(text) = env.text_snapshot(key)
        {
            self.send(
                sink,
                RemoteFrameType::Snapshot,
                tab_id,
                RemoteOutputTuning::cap_snapshot(&text),
            );
        }
        self.send_grid_snapshot(env, sink, tab_id);
    }

    fn send_grid_snapshot(&mut self, env: &mut dyn HostEnv, sink: &mut dyn FrameSink, tab_id: u32) {
        if let Some(key) = self.key_for(env, tab_id)
            && let Some(grid) = env.grid_snapshot(key)
        {
            self.send(sink, RemoteFrameType::TerminalGridSnapshot, tab_id, grid);
        }
    }

    /// Output of a session (`recordOutput`): kept when it belongs to the
    /// selected tab. Returns true when the batch is full and should be sent now.
    pub fn record_output(&mut self, session: u64, data: &[u8]) -> bool {
        if !self.ipc_connected || !self.full() {
            return false;
        }
        let Some(tab_id) = self.registry.tab_id_for_session(session) else {
            return false;
        };
        if Some(tab_id) != self.selected_tab_id {
            return false;
        }
        match &mut self.pending_output {
            Some((id, buf)) if *id == tab_id => buf.extend_from_slice(data),
            _ => self.pending_output = Some((tab_id, data.to_vec())),
        }
        self.pending_output
            .as_ref()
            .is_some_and(|(_, b)| b.len() >= RemoteOutputTuning::MAX_PENDING_BYTES_PER_TAB)
    }

    pub fn has_pending_output(&self) -> bool {
        self.pending_output.is_some()
    }

    /// Send the batched output, then a fresh grid snapshot (`flushPendingOutput`).
    /// Returns the bytes sent (viewers get them too).
    pub fn flush_output(
        &mut self,
        env: &mut dyn HostEnv,
        sink: &mut dyn FrameSink,
    ) -> Option<Vec<u8>> {
        let (tab_id, data) = self.pending_output.take()?;
        if !self.full() || !self.ipc_connected || Some(tab_id) != self.selected_tab_id {
            return None;
        }
        self.send(sink, RemoteFrameType::Output, tab_id, data.clone());
        self.send_grid_snapshot(env, sink, tab_id);
        Some(data)
    }

    // ----- activity and prompts ---------------------------------------------

    fn current_activity(
        &self,
        tabs: &[TabInfo],
        selected: Option<TabKey>,
        now: DateTime<Utc>,
    ) -> Option<RemoteActivityState> {
        let mut candidates = Vec::new();
        for tab in tabs {
            let Some(tab_id) = self.registry.tab_id(tab.key) else {
                continue;
            };
            let is_selected = Some(tab.key) == selected;
            if let Some(approval) = self
                .approvals
                .values()
                .filter(|a| a.tab_id == tab_id)
                .max_by_key(|a| a.requested_at)
            {
                let mut c = RemoteActivityCandidate::new(
                    format!("tab-{tab_id}-approval"),
                    tab_id,
                    &approval.tab_title,
                    &approval.tool_name,
                    RemoteActivityStatus::WaitingInput,
                    is_selected,
                    approval.requested_at,
                );
                c.project_name = approval.project_name.clone();
                c.session_id = approval.session_id.clone();
                c.detail = Some(approval.approval().display_command().to_string());
                c.started_at = Some(approval.requested_at);
                c.approval = Some(approval.approval());
                candidates.push(c);
            }
            for pane in &tab.panes {
                if pane.ai_app.is_none()
                    && pane.ai_provider.is_none()
                    && pane.ai_session_id.is_none()
                {
                    continue;
                }
                let structured = pane
                    .ai_session_id
                    .as_deref()
                    .and_then(|session| self.structured.entry(tab.key, session, now));
                let (status, detail) = if let Some(entry) = structured {
                    (
                        RemoteActivityStatus::WaitingInput,
                        Some(entry.prompt.clone()),
                    )
                } else {
                    match pane.status {
                        CommandStatus::ApprovalRequired => (
                            RemoteActivityStatus::WaitingInput,
                            Some("Approval required".into()),
                        ),
                        CommandStatus::WaitingForInput => (
                            RemoteActivityStatus::WaitingInput,
                            pane.at_prompt.then(|| "Waiting at prompt".to_string()),
                        ),
                        CommandStatus::Running => (RemoteActivityStatus::Running, None),
                        CommandStatus::Stuck => (
                            RemoteActivityStatus::Running,
                            Some("No output for a while".to_string()),
                        ),
                        CommandStatus::Idle | CommandStatus::Done | CommandStatus::Exited => {
                            match recent_completion(tab, now) {
                                Some(outcome) => outcome,
                                None => continue,
                            }
                        }
                    }
                };
                let mut c = RemoteActivityCandidate::new(
                    format!("tab-{tab_id}-pane-{}", pane_uuid(pane.pane_id)),
                    tab_id,
                    tab.activity_title(),
                    tool_name(pane, tab),
                    status,
                    is_selected,
                    updated_at(pane, tab, now),
                );
                c.project_name = project_name(pane);
                c.session_id = pane.ai_session_id.clone();
                c.detail = detail;
                c.started_at = tab.last_command.as_ref().map(|lc| lc.start_time);
                candidates.push(c);
            }
        }
        activity_state::project(&candidates)
    }

    fn current_prompts(
        &self,
        env: &mut dyn HostEnv,
        tabs: &[TabInfo],
        now: DateTime<Utc>,
    ) -> Vec<RemoteInteractivePrompt> {
        let mut prompts = Vec::new();
        for tab in tabs {
            let Some(tab_id) = self.registry.tab_id(tab.key) else {
                continue;
            };
            for pane in &tab.panes {
                let structured = pane
                    .ai_session_id
                    .as_deref()
                    .and_then(|session| self.structured.entry(tab.key, session, now));
                if structured.is_none()
                    && !matches!(
                        pane.status,
                        CommandStatus::WaitingForInput | CommandStatus::ApprovalRequired
                    )
                {
                    continue;
                }
                let tool = tool_name(pane, tab);
                let detected = env
                    .pane_text(tab.key, pane.pane_id)
                    .and_then(|text| interactive_prompt_detector::detect(&text, &tool));
                let (signature, prompt, detail, options, detected_at, multi) =
                    if let Some(entry) = structured {
                        let options = if entry.options.is_empty() {
                            detected.map(|value| value.options).unwrap_or_default()
                        } else {
                            entry.options.clone()
                        };
                        if options.is_empty() {
                            continue;
                        }
                        (
                            entry.signature.clone(),
                            entry.prompt.clone(),
                            entry.detail.clone(),
                            options,
                            entry.created_at,
                            Some(entry.is_multi_select),
                        )
                    } else if let Some(detected) = detected {
                        (
                            detected.signature,
                            detected.prompt,
                            detected.detail,
                            detected.options,
                            updated_at(pane, tab, now),
                            None,
                        )
                    } else {
                        continue;
                    };
                prompts.push(RemoteInteractivePrompt {
                    id: format!(
                        "tab-{tab_id}-pane-{}-{}",
                        pane_uuid(pane.pane_id),
                        signature
                    ),
                    tab_id,
                    tab_title: tab.activity_title(),
                    tool_name: tool,
                    project_name: project_name(pane),
                    branch_name: trimmed(pane.git_branch.as_deref()),
                    current_directory: trimmed(pane.cwd.as_deref()),
                    prompt,
                    detail,
                    options,
                    detected_at,
                    pane_id: Some(uuid::Uuid::from_u64_pair(0, pane.pane_id)),
                    is_multi_select: multi,
                });
            }
        }
        prompts
    }

    /// `sendRemoteActivity`: send the activity when it changed (or `force`),
    /// then the prompts.
    fn send_activity(&mut self, env: &mut dyn HostEnv, sink: &mut dyn FrameSink, force: bool) {
        let tabs = env.tabs();
        let selected = env.selected();
        let next = self.current_activity(&tabs, selected, env.now());
        let changed = force || next != self.activity;
        if changed {
            self.activity = next.clone();
        }
        if self.full() && self.ipc_connected && changed {
            match &next {
                Some(activity) => {
                    let tab_id = activity.tab_id;
                    self.send_json(sink, RemoteFrameType::ActivityState, tab_id, activity);
                }
                None => self.send(sink, RemoteFrameType::ActivityCleared, 0, Vec::new()),
            }
        }
        self.send_prompts_from(env, sink, &tabs, force);
    }

    fn send_prompts(&mut self, env: &mut dyn HostEnv, sink: &mut dyn FrameSink, force: bool) {
        let tabs = env.tabs();
        self.send_prompts_from(env, sink, &tabs, force);
    }

    fn send_prompts_from(
        &mut self,
        env: &mut dyn HostEnv,
        sink: &mut dyn FrameSink,
        tabs: &[TabInfo],
        force: bool,
    ) {
        let now = env.now();
        let mut next = self.current_prompts(env, tabs, now);
        self.answered_prompts.retain(|id, answered| {
            *answered > now - chrono::Duration::hours(1)
                && next.iter().any(|prompt| &prompt.id == id)
        });
        next.retain(|prompt| !self.answered_prompts.contains_key(&prompt.id));
        if !force && next == self.prompts {
            return;
        }
        self.prompts = next.clone();
        if !self.ipc_connected {
            return;
        }
        let payload = RemoteInteractivePromptListPayload { prompts: next };
        self.send_json(sink, RemoteFrameType::InteractivePromptList, 0, &payload);
    }

    /// Periodic refresh (tabs, selection, activity, prompts). Swift reacts to
    /// tab and session changes with a 150 ms debounce; the app calls this
    /// every 150 ms instead.
    pub fn refresh(&mut self, env: &mut dyn HostEnv, sink: &mut dyn FrameSink) {
        if !self.ipc_connected {
            return;
        }
        let previous_selected = self.selected_tab_id;
        let sent = self.send_tab_list(env, sink, false);
        if self.full() && (sent || previous_selected != self.selected_tab_id) {
            self.pending_output = None;
            self.send_selected_snapshot(env, sink);
        }
        self.send_activity(env, sink, false);
    }

    /// Requests waiting on the phone, oldest first.
    #[cfg(test)]
    pub fn pending_approval_ids(&self) -> Vec<String> {
        let mut contexts: Vec<&ApprovalContext> = self.approvals.values().collect();
        contexts.sort_by_key(|c| c.requested_at);
        contexts.into_iter().map(|c| c.request_id.clone()).collect()
    }
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use chrono::TimeZone;

    /// A fake app: tabs with text, input recorded.
    pub(crate) struct FakeEnv {
        pub tabs: Vec<TabInfo>,
        pub selected: Option<TabKey>,
        pub texts: HashMap<TabKey, String>,
        pub pane_texts: HashMap<(TabKey, u64), String>,
        pub typed: Vec<(TabKey, String)>,
        pub pane_typed: Vec<(TabKey, u64, String)>,
        pub resolved: Vec<(String, bool)>,
        pub cleared: Vec<TabKey>,
        pub telemetry: Vec<RemoteClientTelemetryEvent>,
        pub now: DateTime<Utc>,
    }

    pub(crate) fn pane(pane_id: u64, session_id: u64) -> PaneInfo {
        PaneInfo {
            pane_id,
            session_id,
            ai_app: None,
            ai_provider: None,
            ai_session_id: None,
            status: CommandStatus::Idle,
            at_prompt: true,
            cwd: Some("/Users/me/Projects/Chau7".into()),
            git_branch: Some("main".into()),
            last_output_at: None,
        }
    }

    pub(crate) fn tab(key: TabKey, title: &str, panes: Vec<PaneInfo>) -> TabInfo {
        TabInfo {
            key,
            title: title.into(),
            custom_title: None,
            is_mcp_controlled: false,
            main_pane: 0,
            panes,
            last_command: None,
        }
    }

    impl FakeEnv {
        pub(crate) fn new() -> Self {
            let mut texts = HashMap::new();
            texts.insert(10, "hello from tab one\n".to_string());
            texts.insert(20, "tab two\n".to_string());
            Self {
                tabs: vec![
                    tab(10, "Shell", vec![pane(1, 100)]),
                    tab(20, "Build", vec![pane(2, 200)]),
                ],
                selected: Some(10),
                texts,
                pane_texts: HashMap::new(),
                typed: Vec::new(),
                pane_typed: Vec::new(),
                resolved: Vec::new(),
                cleared: Vec::new(),
                telemetry: Vec::new(),
                now: Utc.timestamp_opt(1_760_000_000, 0).unwrap(),
            }
        }
    }

    impl HostEnv for FakeEnv {
        fn tabs(&mut self) -> Vec<TabInfo> {
            self.tabs.clone()
        }
        fn selected(&mut self) -> Option<TabKey> {
            self.selected
        }
        fn select(&mut self, key: TabKey) -> bool {
            if self.tabs.iter().any(|t| t.key == key) {
                self.selected = Some(key);
                true
            } else {
                false
            }
        }
        fn text_snapshot(&mut self, key: TabKey) -> Option<Vec<u8>> {
            self.texts.get(&key).map(|t| t.as_bytes().to_vec())
        }
        fn grid_snapshot(&mut self, key: TabKey) -> Option<Vec<u8>> {
            Some(format!("GRID{key}").into_bytes())
        }
        fn pane_text(&mut self, key: TabKey, pane_id: u64) -> Option<String> {
            self.pane_texts.get(&(key, pane_id)).cloned()
        }
        fn write_input(&mut self, key: TabKey, text: &str) -> bool {
            self.typed.push((key, text.to_string()));
            true
        }
        fn write_pane_input(&mut self, key: TabKey, pane: u64, text: &str) -> bool {
            if !self
                .tabs
                .iter()
                .any(|tab| tab.key == key && tab.panes.iter().any(|value| value.pane_id == pane))
            {
                return false;
            }
            self.pane_typed.push((key, pane, text.into()));
            true
        }
        fn write_keys(&mut self, key: TabKey, pane: Option<u64>, keys: &[RemoteKey]) -> bool {
            let pane = pane.or_else(|| {
                self.tabs
                    .iter()
                    .find(|tab| tab.key == key)
                    .and_then(|tab| tab.panes.get(tab.main_pane))
                    .map(|pane| pane.pane_id)
            });
            let Some(pane) = pane else {
                return false;
            };
            let steps = chau7_next_core::remote::key_input::key_steps(keys, false);
            for step in steps {
                if !self.write_pane_input(key, pane, std::str::from_utf8(&step.bytes).unwrap()) {
                    return false;
                }
            }
            true
        }
        fn clear_persistent_style(&mut self, key: TabKey) {
            self.cleared.push(key);
        }
        fn resolve_approval(&mut self, request_id: &str, approved: bool) {
            self.resolved.push((request_id.to_string(), approved));
        }
        fn store_telemetry(&mut self, event: RemoteClientTelemetryEvent) {
            self.telemetry.push(event);
        }
        fn now(&self) -> DateTime<Utc> {
            self.now
        }
    }

    fn types(frames: &[RemoteFrame]) -> Vec<RemoteFrameType> {
        frames.iter().filter_map(|f| f.frame_type()).collect()
    }

    fn frame(kind: RemoteFrameType, tab_id: u32, payload: &str) -> RemoteFrame {
        RemoteFrame::new(kind.raw_value(), tab_id, 1, payload.as_bytes().to_vec())
    }

    fn connected() -> (RemoteHost, FakeEnv, Vec<RemoteFrame>) {
        let mut host = RemoteHost::new();
        let mut env = FakeEnv::new();
        let mut out = Vec::new();
        host.on_connected(&mut env, &mut out);
        (host, env, out)
    }

    #[test]
    fn initial_state_sends_tabs_snapshots_activity_and_prompts() {
        let (_, _, out) = connected();
        assert_eq!(
            types(&out),
            [
                RemoteFrameType::TabList,
                RemoteFrameType::Snapshot,
                RemoteFrameType::TerminalGridSnapshot,
                RemoteFrameType::ActivityCleared,
                RemoteFrameType::InteractivePromptList,
            ]
        );
        let list: RemoteTabListPayload = serde_json::from_slice(&out[0].payload).unwrap();
        assert_eq!(list.tabs.len(), 2);
        assert_eq!(list.tabs[0].tab_id, 1);
        assert!(list.tabs[0].is_active);
        assert_eq!(list.tabs[0].project_name.as_deref(), Some("Chau7"));
        assert_eq!(out[1].tab_id, 1);
        assert_eq!(out[1].payload, b"hello from tab one\n");
        // Sequence numbers start at 1 and grow.
        assert_eq!(
            out.iter().map(|f| f.seq).collect::<Vec<_>>(),
            [1, 2, 3, 4, 5]
        );
        assert!(out.iter().all(|f| f.flags == 0));
    }

    #[test]
    fn tab_switch_selects_and_snapshots_or_errors() {
        let (mut host, mut env, _) = connected();
        let mut out = Vec::new();
        host.handle_frame(
            frame(RemoteFrameType::TabSwitch, 0, r#"{"tab_id":2}"#),
            &mut env,
            &mut out,
        );
        assert_eq!(env.selected, Some(20));
        assert_eq!(
            types(&out),
            [
                RemoteFrameType::Snapshot,
                RemoteFrameType::TerminalGridSnapshot
            ]
        );
        assert_eq!(out[0].payload, b"tab two\n");

        out.clear();
        host.handle_frame(
            frame(RemoteFrameType::TabSwitch, 0, r#"{"tab_id":99}"#),
            &mut env,
            &mut out,
        );
        let error: RemoteErrorPayload = serde_json::from_slice(&out[0].payload).unwrap();
        assert_eq!(error.code, "tab_unavailable");
        assert_eq!(out[0].tab_id, 99);
    }

    #[test]
    fn input_goes_to_the_tab_and_bad_input_errors() {
        let (mut host, mut env, _) = connected();
        let mut out = Vec::new();
        host.handle_frame(frame(RemoteFrameType::Input, 0, "ls\n"), &mut env, &mut out);
        host.handle_frame(
            frame(RemoteFrameType::Input, 2, "make\n"),
            &mut env,
            &mut out,
        );
        assert_eq!(
            env.typed,
            [(10, "ls\n".to_string()), (20, "make\n".to_string())]
        );
        assert!(out.is_empty());

        let bad = RemoteFrame::new(RemoteFrameType::Input.raw_value(), 0, 1, vec![0xff, 0xfe]);
        host.handle_frame(bad, &mut env, &mut out);
        host.handle_frame(frame(RemoteFrameType::Input, 7, "x"), &mut env, &mut out);
        let codes: Vec<String> = out
            .iter()
            .map(|f| {
                serde_json::from_slice::<RemoteErrorPayload>(&f.payload)
                    .unwrap()
                    .code
            })
            .collect();
        assert_eq!(codes, ["invalid_input_encoding", "tab_unavailable"]);
    }

    #[test]
    fn protected_input_waits_for_approval() {
        let (mut host, mut env, _) = connected();
        let mut out = Vec::new();
        host.handle_frame(
            frame(RemoteFrameType::Input, 0, "killall chau7\n"),
            &mut env,
            &mut out,
        );
        assert!(env.typed.is_empty());
        let request: ApprovalRequestPayload = serde_json::from_slice(&out[0].payload).unwrap();
        assert_eq!(out[0].frame_type(), Some(RemoteFrameType::ApprovalRequest));
        assert_eq!(request.command, "killall chau7");
        assert_eq!(request.flagged_command, "Terminate Chau7 on Mac");
        assert_eq!(request.tab_title.as_deref(), Some("Shell"));
        assert_eq!(request.context_note, None);
        // The approval becomes the activity.
        let activity = host.activity.clone().unwrap();
        assert_eq!(activity.activity_id, "tab-1-approval");
        assert_eq!(activity.headline, "Approval required");

        out.clear();
        let response = format!(
            r#"{{"request_id":"{}","approved":true}}"#,
            request.request_id
        );
        host.handle_frame(
            frame(RemoteFrameType::ApprovalResponse, 0, &response),
            &mut env,
            &mut out,
        );
        assert_eq!(env.typed, [(10, "killall chau7\n".to_string())]);
        assert!(host.pending_approval_ids().is_empty());
        assert!(env.resolved.is_empty());
    }

    #[test]
    fn protected_inputs_expire_and_are_capped() {
        let (mut host, mut env, _) = connected();
        let mut out = Vec::new();
        for _ in 0..25 {
            host.handle_frame(
                frame(RemoteFrameType::Input, 0, "pkill chau7"),
                &mut env,
                &mut out,
            );
            env.now += chrono::Duration::seconds(1);
        }
        assert_eq!(host.pending_protected.len(), 20);
        env.now += chrono::Duration::seconds(121);
        let response = r#"{"request_id":"other","approved":true}"#;
        host.handle_frame(
            frame(RemoteFrameType::ApprovalResponse, 0, response),
            &mut env,
            &mut out,
        );
        assert!(host.pending_protected.is_empty());
        assert!(env.typed.is_empty());
        // Not a protected input: handed to the MCP resolver.
        assert_eq!(env.resolved, [("other".to_string(), true)]);
    }

    #[test]
    fn mcp_approvals_are_registered_resent_and_cleared() {
        let (mut host, mut env, _) = connected();
        let mut out = Vec::new();
        let mut request =
            ApprovalRequestPayload::new("REQ-1", "rm -rf build", "rm -rf", iso8601(env.now));
        request.context_note = Some("Permissions source: global settings".into());
        host.send_approval_request(&request, &mut env, &mut out);
        assert_eq!(out[0].frame_type(), Some(RemoteFrameType::ApprovalRequest));
        assert_eq!(host.pending_approval_ids(), ["REQ-1"]);

        // Reconnect: pending approvals are sent first.
        host.on_disconnected();
        out.clear();
        host.on_connected(&mut env, &mut out);
        assert_eq!(out[0].frame_type(), Some(RemoteFrameType::ApprovalRequest));
        let resent: ApprovalRequestPayload = serde_json::from_slice(&out[0].payload).unwrap();
        assert_eq!(resent.tab_title.as_deref(), Some("Shell"));
        assert_eq!(
            resent.context_note.as_deref(),
            Some("Permissions source: global settings")
        );

        out.clear();
        host.handle_frame(
            frame(
                RemoteFrameType::ApprovalResponse,
                0,
                r#"{"request_id":"REQ-1","approved":false}"#,
            ),
            &mut env,
            &mut out,
        );
        assert_eq!(env.resolved, [("REQ-1".to_string(), false)]);
        assert_eq!(env.cleared, [10]);
        assert!(types(&out).contains(&RemoteFrameType::ActivityCleared));

        // Not registered while the agent is away.
        host.on_disconnected();
        host.send_approval_request(&request, &mut env, &mut out);
        assert!(host.pending_approval_ids().is_empty());
    }

    #[test]
    fn approvals_only_mode_stops_live_frames() {
        let (mut host, mut env, _) = connected();
        let mut out = Vec::new();
        host.handle_frame(
            frame(
                RemoteFrameType::ClientState,
                0,
                r#"{"app_state":"background","stream_mode":"approvals_only","notifications_authorized":false}"#,
            ),
            &mut env,
            &mut out,
        );
        assert_eq!(types(&out), [RemoteFrameType::InteractivePromptList]);
        out.clear();
        assert!(!host.record_output(100, b"data"));
        env.tabs[0].title = "Renamed".into();
        host.refresh(&mut env, &mut out);
        assert!(out.is_empty());
        host.handle_frame(
            frame(
                RemoteFrameType::ClientState,
                0,
                r#"{"app_state":"foreground","stream_mode":"full","notifications_authorized":true}"#,
            ),
            &mut env,
            &mut out,
        );
        assert_eq!(types(&out)[0], RemoteFrameType::TabList);
    }

    #[test]
    fn output_of_the_selected_tab_is_batched_then_flushed_with_a_grid() {
        let (mut host, mut env, _) = connected();
        let mut out = Vec::new();
        assert!(!host.record_output(200, b"other tab"));
        assert!(!host.has_pending_output());
        assert!(!host.record_output(100, b"one "));
        assert!(!host.record_output(100, b"two"));
        assert!(host.record_output(100, &vec![b'x'; 40_000]));
        let sent = host.flush_output(&mut env, &mut out).unwrap();
        assert!(sent.starts_with(b"one two"));
        assert_eq!(
            types(&out),
            [
                RemoteFrameType::Output,
                RemoteFrameType::TerminalGridSnapshot
            ]
        );
        assert_eq!(out[0].tab_id, 1);
        assert!(host.flush_output(&mut env, &mut out).is_none());
    }

    #[test]
    fn refresh_resends_tabs_on_change_and_snapshot_on_selection() {
        let (mut host, mut env, _) = connected();
        let mut out = Vec::new();
        host.refresh(&mut env, &mut out);
        assert!(out.is_empty());
        env.selected = Some(20);
        host.refresh(&mut env, &mut out);
        assert_eq!(
            types(&out),
            [
                RemoteFrameType::TabList,
                RemoteFrameType::Snapshot,
                RemoteFrameType::TerminalGridSnapshot
            ]
        );
        assert_eq!(out[1].tab_id, 2);
    }

    #[test]
    fn activity_follows_ai_panes() {
        let (mut host, mut env, _) = connected();
        let mut out = Vec::new();
        env.tabs[1].panes[0].ai_app = Some("Claude".into());
        env.tabs[1].panes[0].status = CommandStatus::WaitingForInput;
        host.refresh(&mut env, &mut out);
        let activity: RemoteActivityState = serde_json::from_slice(&out[0].payload).unwrap();
        assert_eq!(out[0].frame_type(), Some(RemoteFrameType::ActivityState));
        assert_eq!(out[0].tab_id, 2);
        assert_eq!(activity.headline, "Claude needs input");
        assert_eq!(activity.detail.as_deref(), Some("Waiting at prompt"));
        assert_eq!(activity.activity_id, format!("tab-2-pane-{}", pane_uuid(2)));

        // A failed command within 20 s.
        out.clear();
        env.tabs[1].panes[0].status = CommandStatus::Idle;
        env.tabs[1].panes[0].ai_app = None;
        env.tabs[1].panes[0].ai_provider = Some("codex".into());
        env.tabs[1].last_command = Some(LastCommandInfo {
            command: "cargo test".into(),
            start_time: env.now - chrono::Duration::seconds(30),
            end_time: Some(env.now - chrono::Duration::seconds(5)),
            exit_code: Some(101),
        });
        host.refresh(&mut env, &mut out);
        let activity: RemoteActivityState = serde_json::from_slice(&out[0].payload).unwrap();
        assert_eq!(activity.status, RemoteActivityStatus::Failed);
        assert_eq!(activity.tool_name, "Codex");
        assert_eq!(activity.detail.as_deref(), Some("Exit 101: cargo test"));

        out.clear();
        env.now += chrono::Duration::seconds(30);
        host.refresh(&mut env, &mut out);
        assert_eq!(types(&out), [RemoteFrameType::ActivityCleared]);
    }

    #[test]
    fn interactive_prompts_are_detected_for_waiting_panes() {
        let (mut host, mut env, _) = connected();
        let mut out = Vec::new();
        env.tabs[0].panes[0].ai_app = Some("Claude".into());
        env.tabs[0].panes[0].status = CommandStatus::WaitingForInput;
        env.pane_texts.insert(
            (10, 1),
            "Do you want to proceed?\n❯ 1. Yes\n  2. No, and tell Claude what to do differently\n"
                .into(),
        );
        host.refresh(&mut env, &mut out);
        let list = out
            .iter()
            .find(|f| f.frame_type() == Some(RemoteFrameType::InteractivePromptList))
            .unwrap();
        let payload: RemoteInteractivePromptListPayload =
            serde_json::from_slice(&list.payload).unwrap();
        assert_eq!(payload.prompts.len(), 1);
        let prompt = &payload.prompts[0];
        assert_eq!(prompt.prompt, "Do you want to proceed?");
        assert_eq!(prompt.options[0].response, "1\r");
        assert!(
            prompt
                .id
                .starts_with(&format!("tab-1-pane-{}-", pane_uuid(1)))
        );
        // Unchanged: not sent again.
        out.clear();
        host.refresh(&mut env, &mut out);
        assert!(!types(&out).contains(&RemoteFrameType::InteractivePromptList));
    }

    #[test]
    fn agent_frames_update_status() {
        let (mut host, mut env, _) = connected();
        let mut out = Vec::new();
        host.handle_frame(
            frame(
                RemoteFrameType::PairingInfo,
                0,
                r#"{"device_id":"d","mac_pub":"k","pairing_code":"123456","expires_at":"x","relay_url":"wss://r"}"#,
            ),
            &mut env,
            &mut out,
        );
        assert_eq!(host.pairing_info.as_ref().unwrap().pairing_code, "123456");
        host.handle_frame(
            frame(
                RemoteFrameType::SessionStatus,
                0,
                r#"{"status":"ready","paired_device_id":"fp","paired_device_name":"iPhone"}"#,
            ),
            &mut env,
            &mut out,
        );
        assert_eq!(host.session_status.as_deref(), Some("ready"));
        assert_eq!(host.connected_device_id.as_deref(), Some("fp"));
        assert_eq!(types(&out)[0], RemoteFrameType::TabList);
        out.clear();
        host.handle_frame(frame(RemoteFrameType::Ping, 3, "abc"), &mut env, &mut out);
        assert_eq!(out[0].frame_type(), Some(RemoteFrameType::Pong));
        assert_eq!((out[0].tab_id, out[0].payload.as_slice()), (3, &b"abc"[..]));
        host.handle_frame(
            frame(RemoteFrameType::Error, 0, "relay down"),
            &mut env,
            &mut out,
        );
        assert_eq!(host.last_error.as_deref(), Some("relay down"));
        host.on_device_revoked("fp");
        assert_eq!(host.session_status.as_deref(), Some("disconnected"));
        host.on_disconnected();
        assert_eq!(host.session_status, None);
    }

    #[test]
    fn telemetry_events_are_stored() {
        let (mut host, mut env, _) = connected();
        let mut out = Vec::new();
        let event = RemoteClientTelemetryEvent::new(
            "1.0",
            chau7_next_core::telemetry::remote_client_event::RemoteClientTelemetryEventType::TabSwitched,
        );
        let payload = serde_json::to_string(&event).unwrap();
        host.handle_frame(
            frame(RemoteFrameType::RemoteTelemetry, 0, &payload),
            &mut env,
            &mut out,
        );
        assert_eq!(env.telemetry.len(), 1);
    }

    #[test]
    fn helpers_match_swift() {
        assert_eq!(capitalized("claude code"), "Claude Code");
        assert_eq!(pane_uuid(255), "00000000-0000-0000-0000-0000000000ff");
        assert_eq!(
            iso8601(Utc.timestamp_opt(0, 500).unwrap()),
            "1970-01-01T00:00:00Z"
        );
    }
    #[test]
    fn structured_response_targets_pane_and_rejects_replay_or_stale_pane() {
        let mut env = FakeEnv::new();
        let mut host = RemoteHost::new();
        let mut out = Vec::new();
        env.tabs[0].panes.push(pane(3, 300));
        env.tabs[0].panes[1].ai_session_id = Some("s".into());
        host.handle_frame(
            frame(RemoteFrameType::SessionReady, 0, ""),
            &mut env,
            &mut out,
        );
        let event=chau7_next_core::monitoring::claude_code::parse_event_line(r#"{"type":"tool_start","sessionId":"s","toolName":"AskUserQuestion","toolUseID":"q","toolInput":{"questions":[{"question":"Choose","options":[{"label":"Keep"},{"label":"Cancel"}]}]}}"#,0.).unwrap();
        host.ingest_claude_event(&event, Some(10), env.now);
        host.refresh(&mut env, &mut out);
        let prompt = host.prompts[0].clone();
        assert_eq!(prompt.pane_id, Some(uuid::Uuid::from_u64_pair(0, 3)));
        let payload=serde_json::json!({"prompt_id":prompt.id,"pane_id":prompt.pane_id,"action":"select","option_id":"1"}).to_string();
        host.handle_frame(
            frame(
                RemoteFrameType::InteractivePromptResponse,
                prompt.tab_id,
                &payload,
            ),
            &mut env,
            &mut out,
        );
        assert_eq!(env.pane_typed, vec![(10, 3, "1".into())]);
        assert!(env.typed.is_empty());
        assert!(host.prompts.is_empty());
        host.handle_frame(
            frame(
                RemoteFrameType::InteractivePromptResponse,
                prompt.tab_id,
                &payload,
            ),
            &mut env,
            &mut out,
        );
        assert_eq!(env.pane_typed.len(), 1);
        env.tabs[0].panes.pop();
        host.handle_frame(
            frame(
                RemoteFrameType::PaneInput,
                prompt.tab_id,
                &serde_json::json!({"pane_id":prompt.pane_id,"text":"stale"}).to_string(),
            ),
            &mut env,
            &mut out,
        );
        assert_eq!(env.pane_typed.len(), 1);
    }
}
