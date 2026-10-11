//! Live repository agent dashboard (AgentDashboardModel/View.swift).
//! Shared by repository-group overlays and persistent split panes.
use super::SidePaneEvent;
use crate::workspace::widgets::{button as base_button, chrome_input};
use crate::{mcp::MainThread, theme::Chrome};
use chau7_next_core::dashboard::{self as core, Agent, FilesTracker, Usage};
use gpui::{
    App, Context, Entity, EventEmitter, FocusHandle, Focusable, Render, Task, Window, div,
    prelude::*,
};
use gpui_kit::assets::IconName;
use gpui_kit::component::Icon;
use gpui_kit::component::input::InputState;
use serde_json::{Value, json};
use std::collections::{BTreeSet, HashMap};
use std::sync::mpsc::{self, Receiver};
use std::time::{Duration, Instant};

fn button(
    id: &'static str,
    label: &'static str,
    chrome: Chrome,
    primary: bool,
) -> gpui::Stateful<gpui::Div> {
    let text = match label {
        "Start Agent" => crate::l10n::l("dashboard.startAgent", label),
        "Stop All" => crate::l10n::l("dashboard.stopAll", label),
        "Commit All" => crate::l10n::l("dashboard.commitAll", label),
        "Commit Files" | "Commit" => crate::l10n::l("repo.commit", "Commit"),
        "Open Tab" => crate::l10n::l("dashboard.tab", "Tab"),
        "Stop" => crate::l10n::l("dashboard.stop", label),
        "Launch" => crate::l10n::l("dashboard.launch", label),
        "Auto approve" => crate::l10n::l("dashboard.autoApprove", "Auto-approve tool use"),
        other => crate::l10n::tr(other),
    };
    base_button(id, "", chrome, primary).child(text)
}
#[derive(Default)]
struct DashboardState {
    root: Option<String>,
    refreshed: Option<Instant>,
    generation: u64,
    refresh_pending: Option<Receiver<DashboardSnapshot>>,
    clear_on_refresh: bool,
    agents: Vec<Agent>,
    has_snapshot: bool,
    trackers: HashMap<String, FilesTracker>,
    timeline: Vec<core::TimelineEntry>,
    timeline_limit: usize,
    bridge: Option<MainThread>,
    pending: Option<Receiver<DashboardReply>>,
    plan_to_open: Option<std::path::PathBuf>,
    plan_path: Option<std::path::PathBuf>,
    plan_progress: Option<(usize, usize)>,
    plan_pending: Option<Receiver<Option<(usize, usize)>>>,
    message: Option<String>,
    form: Option<StartForm>,
    commit_form: Option<CommitForm>,
    review_form: Option<ReviewForm>,
}
#[derive(Default)]
struct DashboardReply {
    message: String,
    reset_files: bool,
    close_forms: bool,
    open_plan: Option<std::path::PathBuf>,
    focus_tab: Option<uuid::Uuid>,
}
fn successful_launch_tab(name: &str, response: &Value) -> Option<uuid::Uuid> {
    if name != "runtime_session_create" || response.get("error").is_some() {
        return None;
    }
    response
        .get("tab_id")
        .and_then(Value::as_str)
        .and_then(crate::mcp::windows::parse_tab_id)
}
struct DashboardSnapshot {
    root: String,
    generation: u64,
    agents: Vec<Agent>,
    trackers: HashMap<String, FilesTracker>,
    timeline: Vec<core::TimelineEntry>,
}
struct CommitForm {
    message: Entity<InputState>,
    session: Option<String>,
}
struct ReviewForm {
    base: Entity<InputState>,
    head: Entity<InputState>,
    model: Entity<InputState>,
    instructions: Entity<InputState>,
    parent: Option<String>,
    auto_approve: bool,
}
struct StartForm {
    backend: String,
    model: Entity<InputState>,
    prompt: Entity<InputState>,
    auto_approve: bool,
}
/// Independent scoped controller shared by the group overlay and saved dashboard panes.
/// It references real registered tabs, and never constructs an artificial workspace.
pub struct DashboardPane {
    dashboard: DashboardState,
    focus: FocusHandle,
    _refresh_task: Task<()>,
    auto_open_plan: bool,
    plan_auto_opened: bool,
}
impl EventEmitter<SidePaneEvent> for DashboardPane {}
impl Focusable for DashboardPane {
    fn focus_handle(&self, _cx: &App) -> FocusHandle {
        self.focus.clone()
    }
}
impl DashboardPane {
    pub fn new(
        root: String,
        auto_open_plan: bool,
        _window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Self {
        let timer = crate::observability::register_timer(
            cx,
            &format!("dashboard.pane.{}", cx.entity_id()),
            "Agent dashboard refresh",
            "dashboard",
            1000,
        );
        let task = cx.spawn(async move |this, cx| {
            let _timer = timer;
            loop {
                cx.background_executor().timer(Duration::from_secs(1)).await;
                if this
                    .update(cx, |this, cx| {
                        let id = cx.entity_id();
                        let visible = crate::workspace::AppData::live(cx).into_iter().any(
                            |(handle, workspace)| {
                                let selected = workspace.read(cx).dashboard_contains(id, cx);
                                selected
                                    && handle
                                        .update(cx, |_, window, _| window.is_visible())
                                        .unwrap_or(false)
                            },
                        );
                        if visible {
                            this.refresh_dashboard(cx);
                            cx.notify();
                        }
                    })
                    .is_err()
                {
                    break;
                }
            }
        });
        Self {
            dashboard: DashboardState {
                root: Some(root),
                timeline_limit: 50,
                ..Default::default()
            },
            focus: cx.focus_handle(),
            _refresh_task: task,
            auto_open_plan,
            plan_auto_opened: false,
        }
    }
    pub fn repository_root(&self) -> &str {
        self.dashboard.root.as_deref().unwrap_or_default()
    }
    fn refresh_dashboard(&mut self, cx: &mut Context<Self>) {
        let Some(root) = self.dashboard.root.clone() else {
            return;
        };
        if let Some(receiver) = &self.dashboard.pending {
            match receiver.try_recv() {
                Ok(reply) => {
                    if let Some(tab) = reply.focus_tab {
                        self.open_dashboard_tab(tab, cx);
                    }
                    self.dashboard.message = Some(reply.message);
                    self.dashboard.plan_to_open = reply.open_plan;
                    if reply.close_forms {
                        self.dashboard.form = None;
                        self.dashboard.commit_form = None;
                        self.dashboard.review_form = None;
                    }
                    if reply.reset_files {
                        if self.dashboard.refresh_pending.is_some() {
                            self.dashboard.clear_on_refresh = true;
                        } else {
                            for tracker in self.dashboard.trackers.values_mut() {
                                tracker.clear_committed_files();
                            }
                        }
                    }
                    self.dashboard.pending = None;
                    self.dashboard.refreshed = None;
                }
                Err(mpsc::TryRecvError::Disconnected) => {
                    self.dashboard.pending = None;
                    self.dashboard.message = Some("Action interrupted".into());
                }
                Err(mpsc::TryRecvError::Empty) => {}
            }
        }
        if let Some(receiver) = &self.dashboard.plan_pending {
            match receiver.try_recv() {
                Ok(progress) => {
                    self.dashboard.plan_progress = progress;
                    self.dashboard.plan_pending = None;
                }
                Err(mpsc::TryRecvError::Disconnected) => {
                    self.dashboard.plan_pending = None;
                }
                Err(mpsc::TryRecvError::Empty) => {}
            }
        }
        if let Some(receiver) = &self.dashboard.refresh_pending {
            match receiver.try_recv() {
                Ok(mut snapshot) => {
                    self.dashboard.refresh_pending = None;
                    if snapshot.root == root && snapshot.generation == self.dashboard.generation {
                        if self.dashboard.clear_on_refresh {
                            for tracker in snapshot.trackers.values_mut() {
                                tracker.clear_committed_files();
                            }
                            for agent in &mut snapshot.agents {
                                agent.files.clear();
                                agent.current_files.clear();
                            }
                            self.dashboard.clear_on_refresh = false;
                        }
                        self.dashboard.has_snapshot = true;
                        self.dashboard.agents = snapshot.agents;
                        self.dashboard.trackers = snapshot.trackers;
                        self.dashboard.timeline = snapshot.timeline;
                    }
                }
                Err(mpsc::TryRecvError::Disconnected) => {
                    self.dashboard.refresh_pending = None;
                    self.dashboard.message = Some("Dashboard refresh interrupted".into());
                }
                Err(mpsc::TryRecvError::Empty) => {}
            }
        }
        if self.dashboard.refresh_pending.is_some() {
            return;
        }
        if self
            .dashboard
            .refreshed
            .is_some_and(|t| t.elapsed() < Duration::from_secs(1))
        {
            return;
        }
        self.dashboard.refreshed = Some(Instant::now());
        let mut agents = Vec::new();
        let mut journals = HashMap::new();
        for session in crate::runtime::manager().all_sessions(false) {
            let Some(tab_id) = crate::mcp::windows::parse_tab_id(&session.tab_id) else {
                continue;
            };
            let usage = session.cumulative_token_usage();
            let usage_complete = session.token_usage_state()
                == chau7_next_core::telemetry::token_metrics::TelemetryMetricState::Complete;
            let latest_result = session.latest_turn_result().map(|result| {
                let status = match result.status {
                    chau7_next_core::runtime::delegated_task::TurnResultStatus::Available => {
                        "available"
                    }
                    chau7_next_core::runtime::delegated_task::TurnResultStatus::Invalid => {
                        "invalid"
                    }
                    chau7_next_core::runtime::delegated_task::TurnResultStatus::Missing => {
                        "missing"
                    }
                };
                let summary = result
                    .value
                    .as_ref()
                    .and_then(|v| {
                        v.get("summary")
                            .and_then(Value::as_str)
                            .or_else(|| v.as_str())
                    })
                    .map(str::to_string);
                (status.into(), summary)
            });
            agents.push(Agent {
                id: session.id.clone(),
                tab_id,
                telemetry_tab: None,
                backend: session.backend.name().into(),
                directory: session.config.directory.clone(),
                purpose: session.config.purpose.clone(),
                parent_id: session.config.parent_session_id.clone(),
                delegation_depth: session.config.delegation_depth as usize,
                state: session.state(),
                turns: session.turn_count(),
                usage: session.has_token_usage_evidence().then(|| Usage {
                    input: usage.input_tokens.max(0) as u64,
                    output: usage
                        .output_tokens
                        .saturating_add(usage.reasoning_output_tokens)
                        .max(0) as u64,
                    cache_creation: session.cumulative_cache_creation_tokens().max(0) as u64,
                    cache_read: session.cumulative_cache_read_tokens().max(0) as u64,
                }),
                usage_complete,
                cost: None,
                requires_approval: session.pending_approval().is_some(),
                latest_result,
                created_at: Some(session.created_at),
                child_count: 0,
                last_tool: None,
                files: BTreeSet::new(),
                current_files: BTreeSet::new(),
            });
            journals.insert(session.id.clone(), session);
        }
        let mut agents = core::newest_by_tab(agents);
        let recorder = crate::telemetry::recorder(cx);
        let mut blocks = HashMap::new();
        let live = self.dashboard_live_sessions(cx);
        for (tab_id, session) in live {
            let shell = session.read(cx);
            let run = recorder
                .as_ref()
                .and_then(|r| r.active_run_for_tab(&shell.tab_identifier));
            let directory = shell
                .cwd
                .as_ref()
                .or(shell.git_root.as_ref())
                .map(|p| p.to_string_lossy().into_owned())
                .unwrap_or_default();
            if !core::in_repository(&directory, &root) {
                continue;
            }
            let position = agents.iter().position(|a| a.tab_id == tab_id);
            if position.is_none()
                && shell.ai_app.is_none()
                && shell.shell().effective_provider().is_none()
                && shell.shell().ai_session_id().is_none()
                && run.is_none()
            {
                continue;
            }
            let position = position.unwrap_or_else(|| {
                agents.push(Agent {
                    id: format!("tab_{tab_id}"),
                    tab_id,
                    telemetry_tab: Some(shell.tab_identifier.clone()),
                    backend: shell
                        .ai_app
                        .clone()
                        .or_else(|| run.as_ref().map(|r| r.provider.clone()))
                        .or_else(|| shell.shell().effective_provider())
                        .unwrap_or_else(|| "AI".into()),
                    directory: directory.clone(),
                    purpose: None,
                    parent_id: None,
                    delegation_depth: 0,
                    state: core::live_state(shell.status().as_str(), shell.is_at_prompt()),
                    turns: 0,
                    usage: None,
                    usage_complete: false,
                    cost: None,
                    requires_approval: false,
                    latest_result: None,
                    created_at: run.as_ref().map(|r| r.started_at),
                    child_count: 0,
                    last_tool: None,
                    files: BTreeSet::new(),
                    current_files: BTreeSet::new(),
                });
                agents.len() - 1
            });
            let agent = &mut agents[position];
            agent.directory = directory;
            agent.telemetry_tab = Some(shell.tab_identifier.clone());
            agent.state = if agent.requires_approval {
                chau7_next_core::runtime::session_state::State::AwaitingApproval
            } else {
                core::live_state(shell.status().as_str(), shell.is_at_prompt())
            };
            if let Some(run) = run {
                agent.turns = agent.turns.max(run.turn_count.max(0) as u64);
                agent.cost = run.cost_usd.or(agent.cost);
                if run.total_input_tokens.is_some()
                    || run.total_output_tokens.is_some()
                    || run.total_cached_input_tokens.is_some()
                {
                    // The runtime lifetime counters remain authoritative.
                    if agent.usage.is_none() {
                        agent.usage_complete=run.token_usage_state==chau7_next_core::telemetry::token_metrics::TelemetryMetricState::Complete;
                        agent.usage = Some(Usage {
                            input: run.total_input_tokens.unwrap_or_default().max(0) as u64,
                            output: run
                                .total_output_tokens
                                .unwrap_or_default()
                                .saturating_add(
                                    run.total_reasoning_output_tokens.unwrap_or_default(),
                                )
                                .max(0) as u64,
                            cache_creation: 0,
                            cache_read: run.total_cached_input_tokens.unwrap_or_default().max(0)
                                as u64,
                        });
                    }
                }
            }
            blocks.insert(agent.id.clone(), shell.blocks().blocks().to_vec());
        }
        let generation = self.dashboard.generation;
        let mut trackers = std::mem::take(&mut self.dashboard.trackers);
        let refresh_root = root.clone();
        let (tx, rx) = mpsc::channel();
        self.dashboard.refresh_pending = Some(rx);
        let spawned = std::thread::Builder::new()
            .name("chau7-next-dashboard-refresh".into())
            .spawn(move || {
                agents.retain(|a| core::in_repository(&a.directory, &refresh_root));
                let ids: std::collections::HashSet<_> =
                    agents.iter().map(|a| a.id.clone()).collect();
                trackers.retain(|id, _| ids.contains(id));
                for agent in &mut agents {
                    let tracker = trackers.entry(agent.id.clone()).or_default();
                    tracker.update(
                        journals.get(&agent.id).map(|s| &s.journal),
                        blocks.get(&agent.id).map(Vec::as_slice).unwrap_or(&[]),
                        &refresh_root,
                    );
                    agent.files = tracker.files.clone();
                    agent.current_files = tracker.current_files.clone();
                    agent.last_tool = tracker.last_tool.clone();
                }
                core::count_children(&mut agents);
                agents.sort_by(|a, b| b.created_at.cmp(&a.created_at).then(a.id.cmp(&b.id)));
                let timeline = core::build_timeline(agents.iter().flat_map(|agent| {
                    let backend = agent.backend.clone();
                    journals
                        .get(&agent.id)
                        .into_iter()
                        .flat_map(move |session| {
                            let backend = backend.clone();
                            session
                                .journal
                                .events(0, 1000)
                                .events
                                .into_iter()
                                .map(move |event| (backend.clone(), event))
                        })
                }));
                let _ = tx.send(DashboardSnapshot {
                    root: refresh_root,
                    generation,
                    agents,
                    trackers,
                    timeline,
                });
            });
        if let Err(error) = spawned {
            self.dashboard.refresh_pending = None;
            self.dashboard.message = Some(error.to_string());
        }
        let data_root = cx.global::<crate::workspace::AppData>().root.clone();
        let session_ids: Vec<_> = self
            .dashboard
            .agents
            .iter()
            .map(|a| a.id.as_str())
            .collect();
        let plan_path = core::owned_plan_path(&data_root, &root, &session_ids);
        let plan_files: BTreeSet<_> = self
            .dashboard
            .agents
            .iter()
            .flat_map(|a| a.files.iter().cloned())
            .collect();
        let plan_sessions: Vec<_> = session_ids.iter().map(|id| id.to_string()).collect();
        if self.dashboard.plan_path.as_ref() != Some(&plan_path) {
            self.dashboard.plan_progress = None;
            self.dashboard.plan_pending = None;
        }
        self.dashboard.plan_path = Some(plan_path.clone());
        if self.dashboard.plan_pending.is_none() {
            let (tx, rx) = mpsc::channel();
            self.dashboard.plan_pending = Some(rx);
            let _ = std::thread::Builder::new()
                .name("chau7-next-dashboard-plan".into())
                .spawn(move || {
                    let sessions: Vec<_> = plan_sessions.iter().map(String::as_str).collect();
                    let source = if plan_path.exists() {
                        Some(plan_path)
                    } else {
                        core::plan_source(std::path::Path::new(&root), &plan_files, &sessions)
                    };
                    let progress = source
                        .and_then(|path| std::fs::read_to_string(path).ok())
                        .map(|text| chau7_next_core::editor::markdown::plan_progress(&text));
                    let _ = tx.send(progress);
                });
        }
    }
    fn dashboard_live_sessions(
        &self,
        cx: &App,
    ) -> Vec<(
        uuid::Uuid,
        Entity<crate::terminal::session::TerminalSession>,
    )> {
        crate::workspace::AppData::live(cx)
            .into_iter()
            .flat_map(|(_, workspace)| workspace.read(cx).dashboard_live_sessions(cx))
            .collect()
    }
    fn open_dashboard_tab(&mut self, tab: uuid::Uuid, cx: &mut Context<Self>) {
        for (handle, workspace) in crate::workspace::AppData::live(cx) {
            if workspace.read(cx).mcp_find(tab).is_some() {
                cx.defer(move |cx| {
                    let _ = handle.update(cx, |_, window, cx| {
                        workspace.update(cx, |workspace, cx| {
                            workspace.focus_dashboard_tab(tab, window, cx)
                        });
                        window.activate_window();
                    });
                });
                break;
            }
        }
        cx.notify();
    }
    fn dashboard_work(
        &mut self,
        work: impl FnOnce(&MainThread) -> DashboardReply + Send + 'static,
        cx: &mut Context<Self>,
    ) {
        if self.dashboard.pending.is_some() {
            return;
        }
        let bridge = self
            .dashboard
            .bridge
            .get_or_insert_with(|| MainThread::start(cx))
            .clone();
        let (tx, rx) = mpsc::channel();
        self.dashboard.pending = Some(rx);
        self.dashboard.message = None;
        let spawned = std::thread::Builder::new()
            .name("chau7-next-dashboard-action".into())
            .spawn(move || {
                let _ = tx.send(work(&bridge));
            });
        if let Err(error) = spawned {
            self.dashboard.pending = None;
            self.dashboard.message = Some(error.to_string());
        }
        cx.notify();
    }
    fn dashboard_call(&mut self, name: &'static str, args: Value, cx: &mut Context<Self>) {
        self.dashboard_work(
            move |bridge| {
                let context = crate::mcp::tools::ToolContext::internal(bridge);
                let result = crate::runtime::control::handle_tool_call(
                    name,
                    args.as_object().unwrap_or(&serde_json::Map::new()),
                    &context,
                );
                let parsed = serde_json::from_str::<Value>(&result).unwrap_or(Value::Null);
                let succeeded = !parsed.is_null() && parsed.get("error").is_none();
                let message = if parsed.is_null() {
                    "Invalid runtime response".into()
                } else if let Some(error) = parsed.get("error").and_then(Value::as_str) {
                    error.into()
                } else if name == "runtime_session_create" {
                    "Agent started".into()
                } else {
                    "Agent stopped".into()
                };
                DashboardReply {
                    message,
                    close_forms: succeeded,
                    focus_tab: successful_launch_tab(name, &parsed),
                    ..Default::default()
                }
            },
            cx,
        );
    }
    fn stop_dashboard_all(&mut self, cx: &mut Context<Self>) {
        let agents = self.dashboard.agents.clone();
        self.dashboard_work(
            move |bridge| {
                let context = crate::mcp::tools::ToolContext::internal(bridge);
                let mut errors = Vec::new();
                for agent in agents {
                    if crate::runtime::manager().session(&agent.id).is_some() {
                        let args = json!({"session_id":agent.id,"force":true});
                        let response = crate::runtime::control::handle_tool_call(
                            "runtime_session_stop",
                            args.as_object().unwrap(),
                            &context,
                        );
                        match serde_json::from_str::<Value>(&response) {
                            Ok(value) => {
                                if let Some(error) = value.get("error") {
                                    errors.push(
                                        error
                                            .as_str()
                                            .map(str::to_string)
                                            .unwrap_or_else(|| error.to_string()),
                                    );
                                }
                            }
                            Err(_) => errors.push("Invalid runtime response".into()),
                        }
                    } else {
                        let uuid = agent.tab_id;
                        let stopped = bridge.call(move |cx| {
                            if let Some(tab) = crate::mcp::windows::find_tab(&uuid.to_string(), cx)
                                && let Some(panes) =
                                    tab.window.workspace.read(cx).mcp_panes(tab.tab)
                            {
                                crate::pane::PaneTree::send_input(&panes, b"\x03", cx);
                                true
                            } else {
                                false
                            }
                        });
                        if stopped != Some(true) {
                            errors.push(format!("Tab {uuid} is unavailable"));
                        }
                    }
                }
                DashboardReply {
                    message: if errors.is_empty() {
                        "Agents stopped".into()
                    } else {
                        errors.join("\n")
                    },
                    ..Default::default()
                }
            },
            cx,
        );
    }
    fn open_dashboard_plan(&mut self, cx: &mut Context<Self>) {
        let Some(path) = self.dashboard.plan_path.clone() else {
            return;
        };
        let name = self
            .dashboard
            .root
            .as_ref()
            .map(|r| chau7_next_core::repo_metadata::repo_name(r))
            .unwrap_or_default();
        let root = self.dashboard.root.clone().unwrap_or_default();
        let files = self
            .dashboard
            .agents
            .iter()
            .flat_map(|a| a.files.iter().cloned())
            .collect();
        let sessions: Vec<_> = self.dashboard.agents.iter().map(|a| a.id.clone()).collect();
        self.dashboard_work(
            move |_| {
                let sessions: Vec<_> = sessions.iter().map(String::as_str).collect();
                let source = core::plan_source(std::path::Path::new(&root), &files, &sessions);
                match core::prepare_plan_from(&path, &name, source.as_deref()) {
                    Ok(()) => DashboardReply {
                        message: "Plan ready".into(),
                        open_plan: Some(path),
                        ..Default::default()
                    },
                    Err(error) => DashboardReply {
                        message: error.to_string(),
                        ..Default::default()
                    },
                }
            },
            cx,
        );
    }
    fn stop_dashboard_agent(&mut self, id: String, tab: uuid::Uuid, cx: &mut Context<Self>) {
        if crate::runtime::manager().session(&id).is_some() {
            self.dashboard_call(
                "runtime_session_stop",
                json!({"session_id":id,"force":true}),
                cx,
            );
        } else {
            let sessions = self.dashboard_live_sessions(cx);
            for (uuid, session) in sessions {
                if uuid == tab {
                    session.read(cx).write_input(b"\x03");
                }
            }
            self.dashboard.refreshed = None;
            cx.notify();
        }
    }
    fn start_dashboard_form(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.dashboard.commit_form = None;
        self.dashboard.review_form = None;
        self.dashboard.form = Some(StartForm {
            backend: "claude".into(),
            model: cx.new(|cx| InputState::new(window, cx).placeholder("Model (optional)")),
            prompt: cx
                .new(|cx| InputState::new(window, cx).placeholder("Initial prompt (optional)")),
            auto_approve: false,
        });
        cx.notify();
    }
    fn submit_dashboard_form(&mut self, cx: &mut Context<Self>) {
        if self.dashboard.pending.is_some() {
            return;
        }
        let Some(root) = self.dashboard.root.clone() else {
            return;
        };
        let Some(form) = self.dashboard.form.as_ref() else {
            return;
        };
        let model = form.model.read(cx).value().trim().to_string();
        let prompt = form.prompt.read(cx).value().trim().to_string();
        let mut args =
            json!({"backend":form.backend,"directory":root,"auto_approve":form.auto_approve});
        if !model.is_empty() {
            args["model"] = json!(model);
        }
        if !prompt.is_empty() {
            args["initial_prompt"] = json!(prompt);
        }
        self.dashboard_call("runtime_session_create", args, cx);
    }
    fn begin_dashboard_commit(
        &mut self,
        session: Option<String>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let message = cx.new(|cx| InputState::new(window, cx).placeholder("Commit message"));
        message.update(cx, |input, cx| {
            input.set_value("chore: agent batch commit", window, cx)
        });
        self.dashboard.commit_form = Some(CommitForm { message, session });
        self.dashboard.form = None;
        self.dashboard.review_form = None;
        cx.notify();
    }
    fn submit_dashboard_commit(&mut self, cx: &mut Context<Self>) {
        if self.dashboard.pending.is_some() {
            return;
        }
        let Some(root) = self.dashboard.root.clone() else {
            return;
        };
        let Some(form) = self.dashboard.commit_form.as_ref() else {
            return;
        };
        let message = form.message.read(cx).value().trim().to_string();
        let files: Vec<_> = self
            .dashboard
            .agents
            .iter()
            .filter(|a| form.session.as_ref().is_none_or(|id| id == &a.id))
            .flat_map(|a| a.files.iter().cloned())
            .collect();
        self.dashboard_work(
            move |_| match core::commit_files(&root, &files, &message) {
                Ok(_) => DashboardReply {
                    message: "Changes committed".into(),
                    reset_files: true,
                    close_forms: true,
                    ..Default::default()
                },
                Err(error) => DashboardReply {
                    message: error,
                    ..Default::default()
                },
            },
            cx,
        );
    }
    fn begin_dashboard_review(
        &mut self,
        parent: Option<String>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let base = cx.new(|cx| InputState::new(window, cx).placeholder("Base commit"));
        base.update(cx, |input, cx| input.set_value("HEAD~1", window, cx));
        let head = cx.new(|cx| InputState::new(window, cx).placeholder("Head commit"));
        head.update(cx, |input, cx| input.set_value("HEAD", window, cx));
        let parent = parent.filter(|id| crate::runtime::manager().session(id).is_some());
        self.dashboard.review_form = Some(ReviewForm {
            base,
            head,
            model: cx.new(|cx| InputState::new(window, cx).placeholder("Model (optional)")),
            instructions: cx.new(|cx| {
                InputState::new(window, cx).placeholder("Extra review instructions (optional)")
            }),
            parent,
            auto_approve: false,
        });
        self.dashboard.form = None;
        self.dashboard.commit_form = None;
        cx.notify();
    }
    fn submit_dashboard_review(&mut self, cx: &mut Context<Self>) {
        if self.dashboard.pending.is_some() {
            return;
        }
        let Some(root) = self.dashboard.root.clone() else {
            return;
        };
        let Some(form) = self.dashboard.review_form.as_ref() else {
            return;
        };
        let base = form.base.read(cx).value().trim().to_string();
        let head = form.head.read(cx).value().trim().to_string();
        if base.is_empty() || head.is_empty() {
            self.dashboard.message = Some("Base and head commits are required.".into());
            cx.notify();
            return;
        }
        let extra = form.instructions.read(cx).value().trim().to_string();
        let model = form.model.read(cx).value().trim().to_string();
        let mut args = json!({"backend":"codex","directory":root,"purpose":"code_review","task_metadata":{"base_commit":base,"head_commit":head},"result_schema":chau7_next_core::runtime::code_review::result_schema(),"policy":chau7_next_core::runtime::code_review::default_policy(),"initial_prompt":chau7_next_core::runtime::code_review::prompt(&base,&head,(!extra.is_empty()).then_some(extra.as_str())),"auto_approve":form.auto_approve});
        if let Some(parent) = form.parent.clone() {
            let depth = self
                .dashboard
                .agents
                .iter()
                .find(|a| a.id == parent)
                .map(|a| a.delegation_depth + 1)
                .unwrap_or(1);
            args["parent_session_id"] = json!(parent);
            args["delegation_depth"] = json!(depth);
        }
        if !model.is_empty() {
            args["model"] = json!(model);
        }
        self.dashboard_call("runtime_session_create", args, cx);
    }
    fn render_dashboard(
        &mut self,
        chrome: Chrome,
        _window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Option<gpui::AnyElement> {
        self.refresh_dashboard(cx);
        if let Some(path) = self.dashboard.plan_to_open.take() {
            cx.emit(SidePaneEvent::OpenEditor(path));
        }
        let root = self.dashboard.root.clone()?;
        let agents = self.dashboard.agents.clone();
        let conflicts = core::conflicts(&agents);
        let status = core::overall_status(&agents, &conflicts);
        let tokens: u64 = agents
            .iter()
            .filter_map(|a| a.usage.as_ref())
            .map(Usage::total)
            .sum();
        let cost: f64 = agents.iter().filter_map(|a| a.cost).sum();
        let metrics = format!(
            "{} agents · {} · {} tokens · {}",
            agents.len(),
            crate::l10n::tr(match status {
                core::OverallStatus::Idle => "No agents active",
                core::OverallStatus::Active => "Agents working",
                core::OverallStatus::HasApprovals => "Approvals pending",
                core::OverallStatus::HasConflicts => "File conflicts detected",
            }),
            if agents.iter().all(|a| a.usage.is_some() && a.usage_complete) && !agents.is_empty() {
                tokens.to_string()
            } else if agents.iter().any(|a| a.usage.is_some()) {
                format!("{tokens} known")
            } else {
                "—".into()
            },
            if agents.iter().all(|a| a.cost.is_some()) && !agents.is_empty() {
                format!("${cost:.4}")
            } else if agents.iter().any(|a| a.cost.is_some()) {
                format!("${cost:.4} known")
            } else {
                crate::l10n::tr("cost unavailable")
            }
        );
        let mut body = div()
            .id("repo-dashboard")
            .size_full()
            .track_focus(&self.focus)
            .on_mouse_down(
                gpui::MouseButton::Left,
                cx.listener(|_, _, _, cx| cx.emit(SidePaneEvent::Focused)),
            )
            .bg(chrome.terminal_bg)
            .flex()
            .flex_col()
            .p_4()
            .gap_3()
            .child(
                div()
                    .flex()
                    .flex_wrap()
                    .items_center()
                    .gap_3()
                    .child(
                        div()
                            .flex_1()
                            .child(div().text_lg().child(format!(
                                    "Agents · {}",
                                    std::path::Path::new(&root)
                                        .file_name()
                                        .unwrap_or_default()
                                        .to_string_lossy()
                                )))
                            .child(div().text_xs().text_color(chrome.text_muted).child(metrics)),
                    )
                    .child(
                        button("dashboard-start", "Start Agent", chrome, true).on_click(
                            cx.listener(|this, _, window, cx| {
                                this.start_dashboard_form(window, cx)
                            }),
                        ),
                    )
                    .child(
                        button("dashboard-review", "Code Review", chrome, false).on_click(
                            cx.listener(|this, _, window, cx| {
                                this.begin_dashboard_review(None, window, cx)
                            }),
                        ),
                    )
                    .child(
                        button("dashboard-commit-all", "Commit All", chrome, false).on_click(
                            cx.listener(|this, _, window, cx| {
                                this.begin_dashboard_commit(None, window, cx)
                            }),
                        ),
                    )
                    .child(
                        button("dashboard-stop-all", "Stop All", chrome, false)
                            .on_click(cx.listener(|this, _, _, cx| this.stop_dashboard_all(cx))),
                    )
                    .child(
                        button("dashboard-plan", "Plan", chrome, false)
                            .on_click(cx.listener(|this, _, _, cx| this.open_dashboard_plan(cx))),
                    )
                    .child(
                        button("dashboard-split", "Open in Split", chrome, false).on_click(
                            cx.listener(|this, _, _, cx| {
                                cx.emit(SidePaneEvent::OpenDashboard(
                                    this.repository_root().to_owned(),
                                ));
                            }),
                        ),
                    )
                    .child(
                        button("dashboard-close", "Close", chrome, false)
                            .on_click(cx.listener(|_, _, _, cx| cx.emit(SidePaneEvent::Close))),
                    ),
            );
        let health = match crate::proxy::status(cx) {
            crate::proxy::ProxyStatus::Disabled => "API proxy disabled",
            crate::proxy::ProxyStatus::Starting => "API proxy starting",
            crate::proxy::ProxyStatus::Error(_) => "API proxy error",
            crate::proxy::ProxyStatus::Running(_) => match cx
                .try_global::<crate::proxy::ProxyManager>()
                .and_then(|m| m.healthy)
            {
                Some(true) => "API proxy healthy",
                Some(false) => "API proxy unhealthy",
                None => "API proxy health unknown",
            },
        };
        body = body.child(div().text_xs().text_color(chrome.text_muted).child(health));
        if let Some((checked, total)) = self.dashboard.plan_progress {
            body = body.child(
                div()
                    .text_sm()
                    .child(format!("Plan: {checked}/{total} tasks completed")),
            );
        }
        if let Some(message) = &self.dashboard.message {
            body = body.child(div().text_sm().child(message.clone()));
        }
        if self.dashboard.pending.is_some() {
            body = body.child(
                div()
                    .text_sm()
                    .text_color(chrome.text_muted)
                    .child(crate::l10n::tr("Working…")),
            );
        }
        if let Some(form) = &self.dashboard.form {
            let mut controls = div().flex().gap_2();
            for backend in ["claude", "codex", "opencode"] {
                controls = controls.child(
                    button(
                        match backend {
                            "claude" => "dashboard-claude",
                            "codex" => "dashboard-codex",
                            _ => "dashboard-opencode",
                        },
                        backend,
                        chrome,
                        form.backend == backend,
                    )
                    .on_click(cx.listener(move |this, _, _, cx| {
                        if let Some(form) = &mut this.dashboard.form {
                            form.backend = backend.into();
                        }
                        cx.notify();
                    })),
                );
            }
            body = body.child(
                div()
                    .flex()
                    .flex_col()
                    .gap_2()
                    .p_3()
                    .rounded_lg()
                    .bg(chrome.panel_bg)
                    .child(controls)
                    .child(chrome_input(&form.model, chrome))
                    .child(chrome_input(&form.prompt, chrome))
                    .child(
                        button("dashboard-auto", "Auto approve", chrome, form.auto_approve)
                            .on_click(cx.listener(|this, _, _, cx| {
                                if let Some(form) = &mut this.dashboard.form {
                                    form.auto_approve = !form.auto_approve;
                                }
                                cx.notify();
                            })),
                    )
                    .child(
                        div()
                            .flex()
                            .gap_2()
                            .child(button("dashboard-launch", "Launch", chrome, true).on_click(
                                cx.listener(|this, _, _, cx| this.submit_dashboard_form(cx)),
                            ))
                            .child(
                                button("dashboard-cancel", "Cancel", chrome, false).on_click(
                                    cx.listener(|this, _, _, cx| {
                                        this.dashboard.form = None;
                                        cx.notify();
                                    }),
                                ),
                            ),
                    ),
            );
        }
        if let Some(form) = &self.dashboard.commit_form {
            body = body.child(
                div()
                    .p_3()
                    .rounded_lg()
                    .bg(chrome.panel_bg)
                    .flex()
                    .flex_col()
                    .gap_2()
                    .child(chrome_input(&form.message, chrome))
                    .child(
                        div()
                            .flex()
                            .gap_2()
                            .child(
                                button("dashboard-commit-confirm", "Commit", chrome, true)
                                    .on_click(cx.listener(|this, _, _, cx| {
                                        this.submit_dashboard_commit(cx)
                                    })),
                            )
                            .child(
                                button("dashboard-commit-cancel", "Cancel", chrome, false)
                                    .on_click(cx.listener(|this, _, _, cx| {
                                        this.dashboard.commit_form = None;
                                        cx.notify();
                                    })),
                            ),
                    ),
            );
        }
        if let Some(form) = &self.dashboard.review_form {
            let mut parents = div().flex().gap_2().flex_wrap().child(
                button(
                    "dashboard-review-independent",
                    "Independent Review",
                    chrome,
                    form.parent.is_none(),
                )
                .on_click(cx.listener(|this, _, _, cx| {
                    if let Some(form) = &mut this.dashboard.review_form {
                        form.parent = None;
                    }
                    cx.notify();
                })),
            );
            for agent in agents
                .iter()
                .filter(|a| crate::runtime::manager().session(&a.id).is_some())
            {
                let id = agent.id.clone();
                parents = parents.child(
                    div()
                        .id(gpui::SharedString::from(format!("review-parent-{id}")))
                        .px_2()
                        .py_1()
                        .rounded_md()
                        .bg(if form.parent.as_ref() == Some(&id) {
                            chrome.accent
                        } else {
                            chrome.tab_bg
                        })
                        .child(format!("{} · {}", agent.backend, id))
                        .on_click(cx.listener(move |this, _, _, cx| {
                            if let Some(form) = &mut this.dashboard.review_form {
                                form.parent = Some(id.clone());
                            }
                            cx.notify();
                        })),
                );
            }
            body = body.child(
                div()
                    .p_3()
                    .rounded_lg()
                    .bg(chrome.panel_bg)
                    .flex()
                    .flex_col()
                    .gap_2()
                    .child(parents)
                    .child(chrome_input(&form.base, chrome))
                    .child(chrome_input(&form.head, chrome))
                    .child(chrome_input(&form.model, chrome))
                    .child(chrome_input(&form.instructions, chrome))
                    .child(
                        button(
                            "dashboard-review-auto",
                            "Auto approve",
                            chrome,
                            form.auto_approve,
                        )
                        .on_click(cx.listener(|this, _, _, cx| {
                            if let Some(form) = &mut this.dashboard.review_form {
                                form.auto_approve = !form.auto_approve;
                            }
                            cx.notify();
                        })),
                    )
                    .child(
                        div()
                            .flex()
                            .gap_2()
                            .child(
                                button("dashboard-review-launch", "Launch Review", chrome, true)
                                    .on_click(cx.listener(|this, _, _, cx| {
                                        this.submit_dashboard_review(cx)
                                    })),
                            )
                            .child(
                                button("dashboard-review-cancel", "Cancel", chrome, false)
                                    .on_click(cx.listener(|this, _, _, cx| {
                                        this.dashboard.review_form = None;
                                        cx.notify();
                                    })),
                            ),
                    ),
            );
        }
        let mut scroll = div()
            .id("dashboard-scroll")
            .flex_1()
            .min_h_0()
            .overflow_y_scroll()
            .flex()
            .flex_col()
            .gap_3();
        if agents.is_empty() {
            scroll = scroll.child(
                div()
                    .p_4()
                    .text_color(chrome.text_muted)
                    .child(crate::l10n::l(
                        "dashboard.noAgents",
                        "No agents running in this repo",
                    ))
                    .child(div().text_xs().child(crate::l10n::l(
                        "dashboard.noAgents.help",
                        "Start an AI agent in a tab with this repository to see it here.",
                    ))),
            );
        }
        for agent in &agents {
            let tab = agent.tab_id;
            let id = agent.id.clone();
            let metrics = format!(
                "{} · {} tokens · {}",
                crate::l10n::lf(
                    "dashboard.turns",
                    "Turns: %d",
                    &[chau7_next_core::l10n::Arg::Int(
                        agent.turns.min(i64::MAX as u64) as i64
                    )]
                ),
                agent
                    .usage
                    .as_ref()
                    .map(|u| if agent.usage_complete {
                        u.total().to_string()
                    } else {
                        format!("{} known", u.total())
                    })
                    .unwrap_or_else(|| "—".into()),
                agent
                    .cost
                    .map(|c| format!("${c:.4}"))
                    .unwrap_or_else(|| crate::l10n::tr("cost unavailable"))
            );
            let mut card = div()
                .id(gpui::SharedString::from(format!("agent-{}", agent.id)))
                .p_3()
                .rounded_lg()
                .bg(chrome.panel_bg)
                .border_1()
                .border_color(chrome.border)
                .flex()
                .flex_col()
                .gap_1()
                .child(
                    div()
                        .flex()
                        .gap_2()
                        .items_center()
                        .child(
                            div()
                                .flex_1()
                                .font_weight(gpui::FontWeight::SEMIBOLD)
                                .child(format!("{} · {}", agent.backend, crate::l10n::tr(match agent.state {chau7_next_core::runtime::session_state::State::Ready=>"Ready",chau7_next_core::runtime::session_state::State::Busy=>"Busy",chau7_next_core::runtime::session_state::State::AwaitingApproval=>"Needs approval",chau7_next_core::runtime::session_state::State::WaitingInput=>"Waiting for input",chau7_next_core::runtime::session_state::State::Interrupted=>"Interrupted",chau7_next_core::runtime::session_state::State::Failed=>"Failed",chau7_next_core::runtime::session_state::State::Stopped=>"Stopped",chau7_next_core::runtime::session_state::State::Starting=>"Starting"}))),
                        )
                        .child(
                            button("dashboard-agent-open", "Open Tab", chrome, false).on_click(
                                cx.listener(move |this, _, _, cx| {
                                    this.open_dashboard_tab(tab, cx);
                                }),
                            ),
                        )
                        .child(
                            button("dashboard-agent-stop", "Stop", chrome, false).on_click(
                                cx.listener(move |this, _, _, cx| {
                                    this.stop_dashboard_agent(id.clone(), tab, cx)
                                }),
                            ),
                        ),
                )
                .child(div().text_xs().text_color(chrome.text_muted).child(metrics));
            if agent.requires_approval {
                card = card.child(
                    div()
                        .text_xs()
                        .text_color(chrome.accent)
                        .child(crate::l10n::l(
                            "dashboard.awaitingApproval",
                            "Awaiting approval",
                        )),
                );
            }
            if let Some(usage) = &agent.usage {
                card = card.child(div().text_xs().text_color(chrome.text_muted).child(format!(
                    "{} {} · {} {} · {} {} · {} {}",
                    crate::l10n::tr("Input"),
                    chau7_next_core::l10n::numbers::abbreviated(
                        usage.input.min(i64::MAX as u64) as i64
                    ),
                    crate::l10n::tr("Output"),
                    chau7_next_core::l10n::numbers::abbreviated(
                        usage.output.min(i64::MAX as u64) as i64
                    ),
                    crate::l10n::tr("Cache creation"),
                    chau7_next_core::l10n::numbers::abbreviated(
                        usage.cache_creation.min(i64::MAX as u64) as i64
                    ),
                    crate::l10n::tr("Cache read"),
                    chau7_next_core::l10n::numbers::abbreviated(
                        usage.cache_read.min(i64::MAX as u64) as i64
                    )
                )));
            }
            let commit_id = agent.id.clone();
            let review_id = agent.id.clone();
            card = card.child(
                div()
                    .flex()
                    .gap_2()
                    .child(
                        button("dashboard-agent-commit", "Commit Files", chrome, false).on_click(
                            cx.listener(move |this, _, window, cx| {
                                this.begin_dashboard_commit(Some(commit_id.clone()), window, cx)
                            }),
                        ),
                    )
                    .child(
                        button("dashboard-agent-review", "Review", chrome, false).on_click(
                            cx.listener(move |this, _, window, cx| {
                                this.begin_dashboard_review(Some(review_id.clone()), window, cx)
                            }),
                        ),
                    ),
            );
            if let Some(rate) = agent
                .telemetry_tab
                .as_deref()
                .and_then(|id| crate::telemetry::token_rate(id, cx))
            {
                card = card.child(div().text_xs().text_color(chrome.accent).child(format!(
                        "{}{} · {}",
                        if chrono::Utc::now()
                            .signed_duration_since(rate.updated_at)
                            .num_seconds()
                            > 15
                            || !matches!(
                                agent.state,
                                chau7_next_core::runtime::session_state::State::Busy
                                    | chau7_next_core::runtime::session_state::State::Starting
                            )
                        {
                            "Last measured: "
                        } else {
                            ""
                        },
                        rate.formatted(),
                        rate.detail()
                    )));
            }
            if let Some(parent) = &agent.parent_id {
                card = card.child(div().text_xs().child(format!(
                    "Parent: {parent} · depth {} · {} children",
                    agent.delegation_depth, agent.child_count
                )));
            }
            if let Some(purpose) = &agent.purpose {
                card = card.child(purpose.clone());
            }
            if let Some(tool) = &agent.last_tool {
                card = card.child(crate::l10n::lf(
                    "dashboard.lastTool",
                    "Last: %@",
                    &[chau7_next_core::l10n::Arg::Str(tool.clone())],
                ));
            }
            if !agent.files.is_empty() {
                card = card.child(
                    div()
                        .text_xs()
                        .child(agent.files.iter().cloned().collect::<Vec<_>>().join(" · ")),
                );
            }
            if let Some((status, summary)) = &agent.latest_result {
                card = card.child(format!(
                    "Result: {status} {}",
                    summary.as_deref().unwrap_or("")
                ));
            }
            scroll = scroll.child(card);
        }
        if !conflicts.is_empty() {
            let mut section = div().flex().flex_col().gap_1().child(
                div()
                    .font_weight(gpui::FontWeight::SEMIBOLD)
                    .child("File conflicts"),
            );
            for conflict in conflicts {
                section = section.child(format!(
                    "{} · {} agents · {}",
                    conflict.file,
                    conflict.agents.len(),
                    if conflict.critical {
                        "current turn overlap"
                    } else {
                        "session overlap"
                    }
                ));
            }
            scroll = scroll.child(section);
        }
        let mut timeline = div().flex().flex_col().gap_1().child(
            div()
                .font_weight(gpui::FontWeight::SEMIBOLD)
                .child("Timeline"),
        );
        for event in self
            .dashboard
            .timeline
            .iter()
            .take(self.dashboard.timeline_limit)
        {
            let icon = match event.icon {
                core::TimelineIcon::Tool => IconName::Wrench,
                core::TimelineIcon::Result => IconName::Check,
                core::TimelineIcon::Started => IconName::Play,
                core::TimelineIcon::Completed => IconName::Square,
                core::TimelineIcon::ApprovalNeeded => IconName::Lock,
                core::TimelineIcon::ApprovalResolved => IconName::LockOpen,
                core::TimelineIcon::StateChanged => IconName::RefreshCw,
                core::TimelineIcon::Other => IconName::Circle,
            };
            timeline = timeline.child(
                div()
                    .id(gpui::SharedString::from(event.id.clone()))
                    .flex()
                    .items_center()
                    .gap_2()
                    .text_xs()
                    .child(event.timestamp.format("%H:%M:%S").to_string())
                    .child(
                        div()
                            .text_color(chrome.text_muted)
                            .child(event.backend.clone()),
                    )
                    .child(Icon::new(icon).size_3())
                    .child(event.message.clone()),
            );
        }
        if self.dashboard.timeline.len() > self.dashboard.timeline_limit {
            timeline = timeline.child(
                button("dashboard-more", "Load More", chrome, false).on_click(cx.listener(
                    |this, _, _, cx| {
                        this.dashboard.timeline_limit += 50;
                        cx.notify();
                    },
                )),
            );
        }
        scroll = scroll.child(timeline);
        Some(body.child(scroll).into_any_element())
    }
}

impl Render for DashboardPane {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let element = self.render_dashboard(Chrome::get(cx), window, cx);
        if self.auto_open_plan
            && self.dashboard.has_snapshot
            && !self.plan_auto_opened
            && !self.repository_root().is_empty()
            && self.dashboard.plan_path.is_some()
            && self.dashboard.pending.is_none()
        {
            self.open_dashboard_plan(cx);
            self.plan_auto_opened = self.dashboard.pending.is_some();
        }
        element.unwrap_or_else(|| div().size_full().into_any_element())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn successful_agent_launch_targets_the_real_returned_tab() {
        let id = uuid::Uuid::new_v4();
        let response = json!({"id":"runtime-session","tab_id":id.to_string(),"state":"starting"});
        assert_eq!(
            successful_launch_tab("runtime_session_create", &response),
            Some(id)
        );
        assert_eq!(
            successful_launch_tab("runtime_session_stop", &response),
            None
        );
    }
    #[test]
    fn failed_or_malformed_launch_never_selects_a_tab() {
        let id = uuid::Uuid::new_v4();
        for response in [
            Value::Null,
            json!({}),
            json!({"tab_id":42}),
            json!({"tab_id":"invalid"}),
            json!({"tab_id":id.to_string(),"error":"Launch failed"}),
        ] {
            assert_eq!(
                successful_launch_tab("runtime_session_create", &response),
                None
            );
        }
    }
}
