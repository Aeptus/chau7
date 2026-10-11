//! API analytics proxy (`Proxy/ProxyManager.swift`, `ProxyIPCServer.swift`).
//!
//! When "Enable API Analytics" is on, Chau7 Next runs its own `chau7-proxy`
//! (`process.rs`) on its own ports and shells route AI CLIs through it
//! (`chau7_next_core::proxy::shell_env`). The proxy reports each API call
//! and task event on the IPC socket (`ipc.rs`); this module keeps the last
//! calls, puts them on the AI event timeline, and tracks the task
//! candidates and active tasks per terminal (`tab_id`), which the workspace
//! shows as a banner and a bar (`workspace/tasks.rs`).

pub mod ipc;
pub mod process;

use std::collections::{HashMap, VecDeque};
use std::time::{Duration, Instant};

use chau7_next_core::ai::event::{AiEvent, AiEventSource};
use chau7_next_core::data_root::DataRoot;
use chau7_next_core::proxy::{
    self as core, ApiCallEvent, ApiCallStats, MAX_RECENT_CALLS, ProxyMessage, RESTART_DELAY,
    TaskCandidate, TrackedTask,
};
use chrono::Utc;
use gpui::{App, Global};
use serde_json::json;

use self::ipc::IpcServer;
use self::process::ProxyProcess;
use crate::settings::Settings;
use crate::workspace::AppData;

/// Timer of the manager: IPC messages, process exits, settings changes.
const TICK: Duration = Duration::from_millis(200);
/// Today's stats are refreshed this often while the proxy runs.
const STATS_EVERY: Duration = Duration::from_secs(30);
/// Timeout of one request to the proxy's local endpoints.
const HTTP_TIMEOUT: Duration = Duration::from_secs(5);
/// Wait after a stop before starting again (`restart`).
const RESTART_PAUSE: Duration = Duration::from_millis(500);

/// What the settings window shows (`ProxyStatus`).
#[derive(Debug, Clone, PartialEq)]
pub enum ProxyStatus {
    Disabled,
    Starting,
    Running(u16),
    Error(String),
}

pub struct ProxyManager {
    root: DataRoot,
    process: Option<ProxyProcess>,
    ipc: Option<IpcServer>,
    /// Port the running proxy listens on.
    port: u16,
    last_error: Option<String>,
    /// Set while the app stops the proxy on purpose (no auto-restart).
    stopping: bool,
    /// Start (again) at this time: after a crash or a restart.
    start_at: Option<Instant>,
    /// Settings the proxy runs with: enabled and port.
    applied: Option<(bool, u16)>,
    /// The 100 most recent calls, newest first.
    pub recent: VecDeque<ApiCallEvent>,
    /// Tab identifier -> pending candidate.
    pub pending_candidates: HashMap<String, TaskCandidate>,
    /// Tab identifier -> active task.
    pub active_tasks: HashMap<String, TrackedTask>,
    /// Today's numbers (`GET /stats`) and health (`GET /health`).
    pub stats: Option<ApiCallStats>,
    pub healthy: Option<bool>,
    last_stats: Option<Instant>,
    /// The proxy binary, once looked up (a development build may run `go
    /// build`, so the lookup happens off the main thread).
    binary: Option<Result<std::path::PathBuf, String>>,
    /// A start is waiting for the binary lookup.
    wants_binary: bool,
    resolving: bool,
}

impl Global for ProxyManager {}

/// Start the IPC server and watch the settings (`AppDelegate`:
/// `ProxyIPCServer.start()`, `ProxyManager.startIfEnabled()`).
pub fn init(cx: &mut App) {
    let root = cx.global::<AppData>().root.clone();
    let ipc = match IpcServer::start(&root.proxy_socket()) {
        Ok(ipc) => Some(ipc),
        Err(err) => {
            log::error!("Proxy IPC server: {err}");
            None
        }
    };
    cx.set_global(ProxyManager {
        port: Settings::get(cx).proxy.port,
        root,
        process: None,
        ipc,
        last_error: None,
        stopping: false,
        start_at: None,
        applied: None,
        recent: VecDeque::new(),
        pending_candidates: HashMap::new(),
        active_tasks: HashMap::new(),
        stats: None,
        healthy: None,
        last_stats: None,
        binary: None,
        wants_binary: false,
        resolving: false,
    });
    cx.spawn(async move |cx| {
        loop {
            cx.background_executor().timer(TICK).await;
            cx.update(tick);
        }
    })
    .detach();
    // The proxy and the IPC server stop with the app.
    cx.on_app_quit(|cx| {
        if let Some(manager) = manager_mut(cx) {
            manager.stop();
            if let Some(ipc) = manager.ipc.take() {
                ipc.stop();
            }
        }
        async {}
    })
    .detach();
}

fn manager_mut(cx: &mut App) -> Option<&mut ProxyManager> {
    if cx.has_global::<ProxyManager>() {
        Some(cx.global_mut::<ProxyManager>())
    } else {
        None
    }
}

fn manager(cx: &App) -> Option<&ProxyManager> {
    cx.try_global::<ProxyManager>()
}

/// PRX-015.
pub fn status(cx: &App) -> ProxyStatus {
    let enabled = Settings::get(cx).proxy.enabled;
    let Some(m) = manager(cx) else {
        return ProxyStatus::Disabled;
    };
    if !enabled {
        ProxyStatus::Disabled
    } else if m.process.is_some() {
        ProxyStatus::Running(m.port)
    } else if let Some(err) = &m.last_error {
        ProxyStatus::Error(err.clone())
    } else {
        ProxyStatus::Starting
    }
}

/// Today's totals from the proxy (PRX-019), when it answered.
pub fn today_stats(cx: &App) -> Option<ApiCallStats> {
    manager(cx).and_then(|m| m.stats.clone())
}

/// The candidate shown on a terminal (`currentCandidate`).
pub fn candidate_for(tab_id: &str, cx: &App) -> Option<TaskCandidate> {
    manager(cx).and_then(|m| m.pending_candidates.get(tab_id).cloned())
}

/// The task tracked in a terminal (`currentTask`).
pub fn task_for(tab_id: &str, cx: &App) -> Option<TrackedTask> {
    manager(cx).and_then(|m| m.active_tasks.get(tab_id).cloned())
}

/// The most recent calls, newest first (`recentEvents`).
#[allow(dead_code)]
pub fn recent_calls(cx: &App) -> Vec<ApiCallEvent> {
    manager(cx)
        .map(|m| m.recent.iter().cloned().collect())
        .unwrap_or_default()
}

impl ProxyManager {
    fn stop(&mut self) {
        self.start_at = None;
        if let Some(process) = self.process.take() {
            self.stopping = true;
            log::info!("Stopping proxy...");
            process.stop();
        }
    }

    fn start(&mut self, port: u16, log_prompts: bool) {
        if self.process.is_some() {
            return;
        }
        self.stopping = false;
        self.port = port;
        let binary = match &self.binary {
            None => {
                self.wants_binary = true;
                return;
            }
            Some(Ok(binary)) => binary.clone(),
            Some(Err(err)) => {
                log::error!("{err}");
                self.last_error = Some(err.clone());
                // Look again next time (Go may have been installed since).
                self.binary = None;
                return;
            }
        };
        match ProxyProcess::spawn(&binary, &self.root, port, log_prompts) {
            Ok(process) => {
                self.process = Some(process);
                self.last_error = None;
                self.last_stats = None;
            }
            Err(err) => {
                log::error!("{err}");
                self.last_error = Some(err);
            }
        }
    }

    /// `settingsChanged`: start when enabled, stop when disabled, restart
    /// when the port changed.
    fn apply(&mut self, enabled: bool, port: u16, log_prompts: bool) {
        let wanted = (enabled, port);
        if self.applied == Some(wanted) {
            return;
        }
        let first = self.applied.is_none();
        self.applied = Some(wanted);
        if !enabled {
            if !first {
                log::info!("API analytics disabled, stopping proxy");
            }
            self.stop();
            self.last_error = None;
        } else if self.process.is_some() && port != self.port {
            self.stop();
            self.start_at = Some(Instant::now() + RESTART_PAUSE);
        } else if self.process.is_none() {
            self.start(port, log_prompts);
        }
    }

    /// Process exits: a crash restarts after 2 seconds (PRX-004).
    fn watch_process(&mut self) -> bool {
        let Some(process) = &mut self.process else {
            return false;
        };
        let Some(code) = process.try_exit() else {
            return false;
        };
        self.process = None;
        if code != 0 && !self.stopping {
            let error = format!("Proxy exited with status {code}");
            log::error!("{error}");
            self.last_error = Some(error);
            log::info!("Auto-restarting proxy in 2s...");
            self.start_at = Some(Instant::now() + RESTART_DELAY);
        } else {
            log::info!("Proxy stopped cleanly");
        }
        true
    }

    /// Apply one IPC message; returns a timeline event for API calls.
    fn handle(&mut self, message: ProxyMessage) -> Option<ApiCallEvent> {
        match message {
            ProxyMessage::ApiCall { event, tab_id, .. } => {
                if let Some(task) = tab_id.and_then(|t| self.active_tasks.get_mut(&t)) {
                    task.add_call(&event);
                }
                log::info!(
                    "API call: {} {} - in:{} out:{} ${:.4}",
                    event.provider.raw_value(),
                    event.model,
                    event.input_tokens,
                    event.output_tokens,
                    event.cost_usd
                );
                self.recent.push_front(event.clone());
                self.recent.truncate(MAX_RECENT_CALLS);
                Some(event)
            }
            ProxyMessage::GenerationProgress { .. } => None,
            ProxyMessage::TaskCandidate(candidate) => {
                log::info!("Task candidate received: {}", candidate.suggested_name);
                self.pending_candidates
                    .insert(candidate.tab_id.clone(), candidate);
                None
            }
            ProxyMessage::TaskStarted(task) => {
                log::info!("Task started: {}", task.name);
                self.pending_candidates.remove(&task.tab_id);
                self.active_tasks.insert(task.tab_id.clone(), task);
                None
            }
            ProxyMessage::TaskCandidateDismissed { tab_id, .. } => {
                if let Some(removed) = self.pending_candidates.remove(&tab_id) {
                    log::info!("Task candidate dismissed: {}", removed.suggested_name);
                }
                None
            }
            ProxyMessage::TaskAssessment(assessment) => {
                if let Some(task) = self
                    .active_tasks
                    .values_mut()
                    .find(|t| t.id == assessment.task_id)
                {
                    task.completed_at = Some(Utc::now());
                }
                log::info!(
                    "Task assessed: {} - {}",
                    assessment.task_id,
                    if assessment.approved {
                        "approved"
                    } else {
                        "failed"
                    }
                );
                None
            }
            ProxyMessage::Unknown(kind) => {
                log::warn!("Unknown message type: {kind}");
                None
            }
        }
    }
}

/// The timeline event of an API call (APP-084, PRX-010).
fn timeline_event(call: &ApiCallEvent) -> AiEvent {
    AiEvent::new(
        AiEventSource::api_proxy(),
        call.timeline_type(),
        call.provider.display_name(),
        call.timeline_message(),
        call.timestamp
            .to_rfc3339_opts(chrono::SecondsFormat::Secs, true),
    )
}

fn tick(cx: &mut App) {
    let settings = Settings::get(cx).proxy.clone();
    let Some(m) = manager_mut(cx) else {
        return;
    };
    let mut changed = false;
    m.apply(settings.enabled, settings.port, settings.log_prompts);
    changed |= m.watch_process();
    if let Some(at) = m.start_at
        && Instant::now() >= at
    {
        m.start_at = None;
        if settings.enabled && m.process.is_none() {
            m.start(settings.port, settings.log_prompts);
            changed = true;
        }
    }
    let messages: Vec<ProxyMessage> = m
        .ipc
        .as_ref()
        .map(|ipc| ipc.messages.try_iter().collect())
        .unwrap_or_default();
    let mut calls = Vec::new();
    let mut rates = Vec::new();
    let mut observations = Vec::new();
    for message in messages {
        if let ProxyMessage::ApiCall {
            event, evidence, ..
        } = &message
            && (200..300).contains(&event.status_code)
        {
            observations.push((**evidence).clone());
        }
        match &message {
            ProxyMessage::ApiCall {
                tab_id: Some(tab),
                token_rate: Some(reading),
                ..
            }
            | ProxyMessage::GenerationProgress {
                tab_id: tab,
                reading,
            } => rates.push((tab.clone(), reading.clone())),
            _ => {}
        }
        changed = true;
        if let Some(call) = m.handle(message) {
            calls.push(call);
        }
    }
    let refresh_stats =
        m.process.is_some() && m.last_stats.is_none_or(|at| at.elapsed() >= STATS_EVERY);
    let resolve = (m.wants_binary && !m.resolving).then(|| {
        m.wants_binary = false;
        m.resolving = true;
        m.root.clone()
    });
    let stats_port = refresh_stats.then(|| {
        m.last_stats = Some(Instant::now());
        m.port
    });
    if !observations.is_empty()
        && let Some(recorder) = crate::telemetry::recorder(cx)
    {
        cx.background_executor()
            .spawn(async move {
                for observation in observations {
                    recorder.store().record_usage_evidence(&observation);
                }
            })
            .detach();
    }
    for (tab, reading) in rates {
        crate::telemetry::record_token_rate(&tab, reading, cx);
    }
    if let Some(port) = stats_port {
        cx.spawn(async move |cx| {
            let fetched = cx
                .background_executor()
                .spawn(async move {
                    let health = core::http_request(port, "GET", "/health", None, HTTP_TIMEOUT)
                        .ok()
                        .map(|(code, body)| code == 200 && core::health_ok(&body));
                    let stats = core::http_request(port, "GET", "/stats", None, HTTP_TIMEOUT)
                        .ok()
                        .filter(|(code, _)| *code == 200)
                        .and_then(|(_, body)| core::decode_stats(&body));
                    (health, stats)
                })
                .await;
            cx.update(|cx| {
                if let Some(m) = manager_mut(cx) {
                    m.healthy = fetched.0;
                    if fetched.1.is_some() {
                        m.stats = fetched.1;
                    }
                }
            });
        })
        .detach();
    }
    if let Some(root) = resolve {
        cx.spawn(async move |cx| {
            let found = cx
                .background_executor()
                .spawn(async move { process::binary_path(&root) })
                .await;
            cx.update(|cx| {
                if let Some(m) = manager_mut(cx) {
                    m.resolving = false;
                    m.binary = Some(found);
                    m.start_at = Some(Instant::now());
                }
            });
        })
        .detach();
    }
    for call in calls {
        crate::ai::events_out::publish(timeline_event(&call), false, cx);
        log::info!(
            "API call recorded: {} {} ${:.4}",
            call.provider.raw_value(),
            call.model,
            call.cost_usd
        );
    }
    if changed {
        cx.refresh_windows();
    }
}

/// Stop, then start again with the current settings (`restart`).
pub fn restart(cx: &mut App) {
    if let Some(m) = manager_mut(cx) {
        m.stop();
        m.start_at = Some(Instant::now() + RESTART_PAUSE);
    }
}

/// "Open Database Folder" (PRX-016).
pub fn open_database_folder(cx: &mut App) {
    let dir = cx.global::<AppData>().root.proxy_dir();
    let _ = std::fs::create_dir_all(&dir);
    cx.open_with_system(&dir);
}

/// "Clear All Data" (PRX-017): delete the database and restart the proxy so
/// it creates a new one.
pub fn clear_all_data(cx: &mut App) {
    let db = cx.global::<AppData>().root.proxy_db();
    if db.exists() {
        match std::fs::remove_file(&db) {
            Ok(()) => log::info!("Analytics database cleared"),
            Err(err) => log::error!("Failed to clear analytics database: {err}"),
        }
    }
    for suffix in ["-wal", "-shm"] {
        let mut side = db.clone().into_os_string();
        side.push(suffix);
        let _ = std::fs::remove_file(std::path::PathBuf::from(side));
    }
    if let Some(m) = manager_mut(cx) {
        m.recent.clear();
    }
    if Settings::get(cx).proxy.enabled {
        restart(cx);
    }
}

fn running_port(cx: &App) -> Option<u16> {
    manager(cx).filter(|m| m.process.is_some()).map(|m| m.port)
}

/// Run a request to the proxy off the main thread, then `done` with the
/// answer's body when it returned 200.
fn request(
    method: &'static str,
    path: String,
    body: Option<serde_json::Value>,
    cx: &mut App,
    done: impl FnOnce(Option<String>, &mut App) + 'static,
) {
    let Some(port) = running_port(cx) else {
        done(None, cx);
        return;
    };
    let request_path = path.clone();
    cx.spawn(async move |cx| {
        let result = cx
            .background_executor()
            .spawn(async move {
                core::http_request(port, method, &request_path, body.as_ref(), HTTP_TIMEOUT)
            })
            .await;
        let body = match result {
            Ok((200, body)) => Some(body),
            Ok((code, _)) => {
                log::warn!("Proxy request {method} {path}: HTTP {code}");
                None
            }
            Err(err) => {
                log::warn!("Proxy request {method} {path}: {err}");
                None
            }
        };
        cx.update(|cx| done(body, cx));
    })
    .detach();
}

/// Confirm the terminal's candidate (`POST /task/start`, PRX-012).
pub fn confirm_candidate(tab_id: &str, cx: &mut App) {
    let Some(candidate) = candidate_for(tab_id, cx) else {
        return;
    };
    let tab = tab_id.to_string();
    let body = json!({"tab_id": tab, "task_name": null, "candidate_id": candidate.id});
    request(
        "POST",
        "/task/start".into(),
        Some(body),
        cx,
        move |body, cx| {
            let task = body
                .and_then(|b| core::decode_started_task(&b, &tab, Some(&candidate.id), Utc::now()));
            match task {
                Some(task) => {
                    log::info!("Task confirmed: {}", task.name);
                    if let Some(m) = manager_mut(cx) {
                        m.pending_candidates.remove(&tab);
                        m.active_tasks.entry(tab).or_insert(task);
                    }
                    cx.refresh_windows();
                }
                None => log::error!(
                    "OverlayTabsModel: failed to confirm task candidate {}",
                    candidate.id
                ),
            }
        },
    );
}

/// Dismiss the terminal's candidate (`POST /task/dismiss`, PRX-012).
pub fn dismiss_candidate(tab_id: &str, cx: &mut App) {
    let Some(candidate) = candidate_for(tab_id, cx) else {
        return;
    };
    let tab = tab_id.to_string();
    let body = json!({"tab_id": tab, "candidate_id": candidate.id});
    request(
        "POST",
        "/task/dismiss".into(),
        Some(body),
        cx,
        move |body, cx| {
            if body.is_some_and(|b| core::decode_flag(&b, "dismissed")) {
                log::info!("Task candidate dismissed");
                if let Some(m) = manager_mut(cx) {
                    m.pending_candidates.remove(&tab);
                }
                cx.refresh_windows();
            } else {
                log::error!(
                    "OverlayTabsModel: failed to dismiss task candidate {}",
                    candidate.id
                );
            }
        },
    );
}

/// Mark the terminal's task done or failed (`POST /task/assess`, PRX-013,
/// PRX-014). `done(true)` once the proxy accepted it.
pub fn assess_task(
    tab_id: &str,
    approved: bool,
    note: Option<String>,
    cx: &mut App,
    done: impl FnOnce(bool, &mut App) + 'static,
) {
    let Some(task) = task_for(tab_id, cx) else {
        return;
    };
    let tab = tab_id.to_string();
    let body = json!({"task_id": task.id, "approved": approved, "note": note});
    request(
        "POST",
        "/task/assess".into(),
        Some(body),
        cx,
        move |body, cx| {
            let ok = body.is_some_and(|b| core::decode_flag(&b, "success"));
            if ok {
                log::info!(
                    "Task assessed: {}",
                    if approved { "success" } else { "failed" }
                );
                if let Some(m) = manager_mut(cx) {
                    m.active_tasks.remove(&tab);
                }
                cx.refresh_windows();
            } else {
                log::error!("OverlayTabsModel: failed to assess task {}", task.id);
            }
            done(ok, cx);
        },
    );
}

/// `GET /task/current` for a terminal (PRX-019), refreshing the bar's numbers.
#[allow(dead_code)]
pub fn refresh_current_task(tab_id: &str, cx: &mut App) {
    let tab = tab_id.to_string();
    let path = format!("/task/current?tab_id={}", core::query_escape(tab_id));
    request("GET", path, None, cx, move |body, cx| {
        if let Some(task) = body.and_then(|b| core::decode_current_task(&b, &tab, Utc::now()))
            && let Some(m) = manager_mut(cx)
        {
            m.active_tasks.insert(tab, task);
            cx.refresh_windows();
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;
    use chau7_next_core::proxy::parse_message;

    fn manager() -> ProxyManager {
        ProxyManager {
            root: DataRoot::with_home(std::env::temp_dir(), true),
            process: None,
            ipc: None,
            port: 18090,
            last_error: None,
            stopping: false,
            start_at: None,
            applied: None,
            recent: VecDeque::new(),
            pending_candidates: HashMap::new(),
            active_tasks: HashMap::new(),
            stats: None,
            healthy: None,
            last_stats: None,
            binary: None,
            wants_binary: false,
            resolving: false,
        }
    }

    #[test]
    fn task_lifecycle_and_live_numbers() {
        let mut m = manager();
        let now = Utc::now();
        let candidate = parse_message(
            r#"{"type":"task_candidate","data":{"candidate_id":"C","tab_id":"TAB","session_id":"S","project_path":"/p","suggested_name":"Fix","trigger":"idle_gap","confidence":0.8,"grace_period_seconds":5}}"#,
            now,
        )
        .unwrap();
        m.handle(candidate);
        assert!(m.pending_candidates.contains_key("TAB"));
        let started = parse_message(
            r#"{"type":"task_started","data":{"task_id":"T","tab_id":"TAB","session_id":"S","project_path":"/p","task_name":"Fix","start_method":"auto_confirmed","trigger":"idle_gap"}}"#,
            now,
        )
        .unwrap();
        m.handle(started);
        assert!(m.pending_candidates.is_empty());
        let call = parse_message(
            r#"{"type":"api_call","data":{"session_id":"S","provider":"openai","model":"gpt","endpoint":"/v1/responses","input_tokens":3,"output_tokens":4,"latency_ms":10,"status_code":200,"cost_usd":0.5,"timestamp":"2026-10-10T10:00:00Z","tab_id":"TAB"}}"#,
            now,
        )
        .unwrap();
        let event = m.handle(call).unwrap();
        assert_eq!(m.active_tasks["TAB"].total_tokens, 7);
        assert_eq!(m.recent.len(), 1);
        let timeline = timeline_event(&event);
        assert_eq!(timeline.source.raw_value(), "api_proxy");
        assert_eq!(timeline.event_type, "api_call");
        assert_eq!(timeline.tool, "OpenAI");
        assert_eq!(timeline.message, "OpenAI gpt: in:3 out:4 $0.50");
    }

    #[test]
    fn keeps_the_last_hundred_calls() {
        let mut m = manager();
        for i in 0..120 {
            let line = format!(
                r#"{{"type":"api_call","data":{{"session_id":"S","provider":"anthropic","model":"m{i}","endpoint":"/","input_tokens":1,"output_tokens":1,"latency_ms":1,"status_code":200,"cost_usd":0,"timestamp":"x"}}}}"#
            );
            m.handle(parse_message(&line, Utc::now()).unwrap());
        }
        assert_eq!(m.recent.len(), MAX_RECENT_CALLS);
        assert_eq!(m.recent[0].model, "m119");
    }

    #[test]
    fn disabled_settings_stop_and_clear_the_error() {
        let mut m = manager();
        m.last_error = Some("x".into());
        m.apply(false, 18090, false);
        assert_eq!(m.applied, Some((false, 18090)));
        assert!(m.last_error.is_none());
        assert!(m.process.is_none());
    }
}
