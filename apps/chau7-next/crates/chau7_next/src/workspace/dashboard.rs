//! Live repository agent dashboard (AgentDashboardModel/View.swift).
//! Click a group to open; dragging it still reorders tabs.
use super::{
    Workspace,
    widgets::{button, chrome_input},
};
use crate::{mcp::MainThread, theme::Chrome};
use chau7_next_core::dashboard::{self as core, Agent, FilesTracker, Usage};
use chau7_next_core::runtime::runtime_event::RuntimeEvent;
use gpui::{Context, Entity, Window, div, prelude::*};
use gpui_kit::component::input::InputState;
use serde_json::{Value, json};
use std::collections::{BTreeSet, HashMap};
use std::sync::mpsc::{self, Receiver};
use std::time::{Duration, Instant};

#[derive(Default)]
pub(super) struct DashboardUi {
    root: Option<String>,
    refreshed: Option<Instant>,
    agents: Vec<Agent>,
    trackers: HashMap<String, FilesTracker>,
    timeline: Vec<RuntimeEvent>,
    timeline_limit: usize,
    bridge: Option<MainThread>,
    pending: Option<Receiver<String>>,
    message: Option<String>,
    form: Option<StartForm>,
}
impl DashboardUi {
    pub(super) fn dismiss(&mut self) {
        self.root = None;
    }
}
struct StartForm {
    backend: String,
    model: Entity<InputState>,
    prompt: Entity<InputState>,
    auto_approve: bool,
}
impl Workspace {
    pub(super) fn toggle_dashboard(&mut self, root: String, cx: &mut Context<Self>) {
        if self.dashboard.root.as_ref() == Some(&root) {
            self.dashboard.root = None;
        } else {
            self.dashboard.root = Some(root);
            self.dashboard.refreshed = None;
            self.dashboard.timeline_limit = 50;
            self.dashboard.form = None;
            self.hover = None;
            self.idle_open = false;
        }
        cx.notify();
    }
    fn refresh_dashboard(&mut self, cx: &mut Context<Self>) {
        let Some(root) = self.dashboard.root.clone() else {
            return;
        };
        if let Some(receiver) = &self.dashboard.pending
            && let Ok(message) = receiver.try_recv()
        {
            self.dashboard.message = Some(message);
            self.dashboard.pending = None;
            self.dashboard.refreshed = None;
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
            let config = serde_json::to_value(&session.config).unwrap_or(Value::Null);
            let summary = session.summary();
            agents.push(Agent {
                id: session.id.clone(),
                tab_id,
                backend: session.backend.name().into(),
                directory: session.config.directory.clone(),
                purpose: config
                    .get("purpose")
                    .and_then(Value::as_str)
                    .map(str::to_string),
                parent_id: config
                    .get("parentSessionID")
                    .and_then(Value::as_str)
                    .map(str::to_string),
                delegation_depth: config
                    .get("delegationDepth")
                    .and_then(Value::as_u64)
                    .unwrap_or_default() as usize,
                state: session.state(),
                turns: session.turn_count(),
                usage: None,
                cost: summary.get("cost_usd").and_then(Value::as_f64),
                requires_approval: session.pending_approval().is_some(),
                latest_result: None,
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
        let mut live = self.dashboard_live_sessions(cx);
        for (_, workspace) in super::AppData::live(cx) {
            if workspace.entity_id() != cx.entity_id() {
                live.extend(workspace.read(cx).dashboard_live_sessions(cx));
            }
        }
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
                && shell.shell().ai_session_id().is_none()
                && run.is_none()
            {
                continue;
            }
            let position = position.unwrap_or_else(|| {
                agents.push(Agent {
                    id: format!("tab_{tab_id}"),
                    tab_id,
                    backend: shell
                        .ai_app
                        .clone()
                        .or_else(|| run.as_ref().map(|r| r.provider.clone()))
                        .unwrap_or_else(|| "AI".into()),
                    directory: directory.clone(),
                    purpose: None,
                    parent_id: None,
                    delegation_depth: 0,
                    state: core::live_state(shell.status().as_str(), shell.is_at_prompt()),
                    turns: 0,
                    usage: None,
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
                    agent.usage = Some(Usage {
                        input: run.total_input_tokens.unwrap_or_default().max(0) as u64,
                        output: run.total_output_tokens.unwrap_or_default().max(0) as u64,
                        cache_creation: 0,
                        cache_read: run.total_cached_input_tokens.unwrap_or_default().max(0) as u64,
                    });
                }
            }
            let tracker = self.dashboard.trackers.entry(agent.id.clone()).or_default();
            tracker.update(
                journals.get(&agent.id).map(|s| &s.journal),
                shell.blocks().blocks(),
                &root,
            );
            agent.files = tracker.files.clone();
            agent.current_files = tracker.current_files.clone();
            agent.last_tool = tracker.last_tool.clone();
        }
        agents.retain(|a| core::in_repository(&a.directory, &root));
        let ids: std::collections::HashSet<_> = agents.iter().map(|a| a.id.clone()).collect();
        self.dashboard.trackers.retain(|id, _| ids.contains(id));
        for agent in &mut agents {
            if let Some(session) = journals.get(&agent.id) {
                let tracker = self.dashboard.trackers.entry(agent.id.clone()).or_default();
                tracker.update(Some(&session.journal), &[], &root);
                agent.files = tracker.files.clone();
                agent.current_files = tracker.current_files.clone();
                agent.last_tool = tracker.last_tool.clone();
            }
        }
        core::count_children(&mut agents);
        agents.sort_by(|a, b| b.created_at.cmp(&a.created_at).then(a.id.cmp(&b.id)));
        let mut timeline = Vec::new();
        for id in &ids {
            if let Some(session) = journals.get(id) {
                timeline.extend(session.journal.events(0, 1000).events);
            }
        }
        timeline.sort_by(|a, b| {
            b.timestamp
                .cmp(&a.timestamp)
                .then(b.seq.cmp(&a.seq))
                .then(a.session_id.cmp(&b.session_id))
        });
        self.dashboard.agents = agents;
        self.dashboard.timeline = timeline;
    }
    fn dashboard_live_sessions(
        &self,
        cx: &gpui::App,
    ) -> Vec<(
        uuid::Uuid,
        Entity<crate::terminal::session::TerminalSession>,
    )> {
        self.state
            .tabs()
            .iter()
            .filter_map(|tab| {
                let session = self
                    .entries
                    .get(&tab.id)?
                    .panes
                    .read(cx)
                    .focused_session(cx)?;
                Some((tab.uuid, session))
            })
            .collect()
    }
    fn open_dashboard_tab(&mut self, tab: uuid::Uuid, window: &mut Window, cx: &mut Context<Self>) {
        if let Some(id) = self
            .state
            .tabs()
            .iter()
            .find(|m| m.uuid == tab)
            .map(|m| m.id)
        {
            self.select_tab(id, window, cx);
            return;
        }
        self.dashboard.dismiss();
        for (handle, workspace) in super::AppData::live(cx) {
            if workspace.entity_id() == cx.entity_id() {
                continue;
            }
            if let Some(id) = workspace.read(cx).mcp_find(tab) {
                cx.defer(move |cx| {
                    let _ = handle.update(cx, |_, window, cx| {
                        workspace.update(cx, |workspace, cx| workspace.select_tab(id, window, cx));
                        window.activate_window();
                    });
                });
                break;
            }
        }
        cx.notify();
    }
    fn dashboard_call(&mut self, name: &'static str, args: Value, cx: &mut Context<Self>) {
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
                let context = crate::mcp::tools::ToolContext { main: &bridge };
                let result = crate::runtime::control::handle_tool_call(
                    name,
                    args.as_object().unwrap_or(&serde_json::Map::new()),
                    &context,
                );
                let parsed = serde_json::from_str::<Value>(&result).unwrap_or(Value::Null);
                let message = parsed
                    .get("error")
                    .and_then(Value::as_str)
                    .map(str::to_string)
                    .unwrap_or_else(|| {
                        if name == "runtime_session_create" {
                            "Agent started"
                        } else {
                            "Agent stopped"
                        }
                        .into()
                    });
                let _ = tx.send(message);
            });
        if let Err(error) = spawned {
            self.dashboard.pending = None;
            self.dashboard.message = Some(error.to_string());
        }
        cx.notify();
    }
    fn stop_dashboard_agent(&mut self, id: String, tab: uuid::Uuid, cx: &mut Context<Self>) {
        if crate::runtime::manager().session(&id).is_some() {
            self.dashboard_call(
                "runtime_session_stop",
                json!({"session_id":id,"force":true}),
                cx,
            );
        } else {
            let mut sessions = self.dashboard_live_sessions(cx);
            for (_, workspace) in super::AppData::live(cx) {
                if workspace.entity_id() != cx.entity_id() {
                    sessions.extend(workspace.read(cx).dashboard_live_sessions(cx));
                }
            }
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
        let Some(root) = self.dashboard.root.clone() else {
            return;
        };
        let Some(form) = self.dashboard.form.take() else {
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
    pub(super) fn render_dashboard(
        &mut self,
        chrome: Chrome,
        cx: &mut Context<Self>,
    ) -> Option<gpui::AnyElement> {
        self.refresh_dashboard(cx);
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
            "{} agents · {:?} · {} tokens · {}",
            agents.len(),
            status,
            if agents.iter().any(|a| a.usage.is_some()) {
                tokens.to_string()
            } else {
                "—".into()
            },
            if agents.iter().any(|a| a.cost.is_some()) {
                format!("${cost:.4}")
            } else {
                "cost unavailable".into()
            }
        );
        let mut body = div()
            .id("repo-dashboard")
            .absolute()
            .inset_0()
            .occlude()
            .bg(chrome.terminal_bg)
            .flex()
            .flex_col()
            .p_4()
            .gap_3()
            .child(
                div()
                    .flex()
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
                    .child(button("dashboard-close", "Close", chrome, false).on_click(
                        cx.listener(|this, _, window, cx| {
                            this.dashboard.root = None;
                            this.focus_selected(window, cx);
                            cx.notify();
                        }),
                    )),
            );
        if let Some(message) = &self.dashboard.message {
            body = body.child(div().text_sm().child(message.clone()));
        }
        if self.dashboard.pending.is_some() {
            body = body.child(
                div()
                    .text_sm()
                    .text_color(chrome.text_muted)
                    .child("Working…"),
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
        let mut scroll = div()
            .id("dashboard-scroll")
            .flex_1()
            .min_h_0()
            .overflow_y_scroll()
            .flex()
            .flex_col()
            .gap_3();
        if agents.is_empty() {
            scroll=scroll.child(div().p_4().text_color(chrome.text_muted).child("No active agents in this repository. Start an agent or open an AI CLI in a grouped tab."));
        }
        for agent in &agents {
            let tab = agent.tab_id;
            let id = agent.id.clone();
            let metrics = format!(
                "{} turns · {} tokens · {}",
                agent.turns,
                agent
                    .usage
                    .as_ref()
                    .map(|u| u.total().to_string())
                    .unwrap_or_else(|| "—".into()),
                agent
                    .cost
                    .map(|c| format!("${c:.4}"))
                    .unwrap_or_else(|| "cost unavailable".into())
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
                                .child(format!("{} · {}", agent.backend, agent.state.raw_value())),
                        )
                        .child(
                            button("dashboard-agent-open", "Open Tab", chrome, false).on_click(
                                cx.listener(move |this, _, window, cx| {
                                    this.open_dashboard_tab(tab, window, cx);
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
            if let Some(purpose) = &agent.purpose {
                card = card.child(purpose.clone());
            }
            if let Some(tool) = &agent.last_tool {
                card = card.child(format!("Last tool: {tool}"));
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
            timeline = timeline.child(div().text_xs().child(format!(
                    "{} · {} · {}",
                    event.timestamp.format("%H:%M:%S"),
                    event.event_type,
                    event
                        .data
                        .get("args_summary")
                        .or_else(|| event.data.get("message"))
                        .or_else(|| event.data.get("tool"))
                        .map(String::as_str)
                        .unwrap_or("")
                )));
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
