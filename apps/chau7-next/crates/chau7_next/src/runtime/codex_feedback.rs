//! One read-only Codex rollout watcher per live native thread; all discovery/tailing is off the UI thread.
use super::{AppHost, manager, sync_runtime_owned_tabs};
use crate::ai::events_out;
use crate::mcp::windows::{find_tab, windows};
use crate::workspace::{AppData, mcp::uuid_string};
use chau7_next_core::ai::event::{AiEvent, AiEventReliability, AiEventSource};
use chau7_next_core::runtime::codex_feedback::{self as core, Action, Record};
use gpui::{App, AppContext, Global};
use std::collections::{HashMap, HashSet};
use std::path::Path;
use std::time::{Duration, Instant};

#[derive(Clone)]
struct Binding {
    tab: String,
    native: String,
    cwd: String,
}
#[derive(Default)]
struct Watch {
    reader: Option<core::Reader>,
    tracker: core::Tracker,
    next_lookup: u64,
    attempt: u32,
    usage: Option<(i64, i64, i64, i64)>,
}

type Watches = HashMap<(String, String), Watch>;
type Deliveries = Vec<(Binding, Delivery)>;
enum Delivery {
    Feedback(Action),
    Lifecycle(Record),
}
fn bindings(cx: &mut App) -> Vec<Binding> {
    let mut result = Vec::new();
    for window in windows(cx) {
        let ws = window.workspace.read(cx);
        for uuid in ws.mcp_tab_uuids() {
            let Some(tab) = ws.mcp_find(uuid) else {
                continue;
            };
            let Some(terminal) = ws.mcp_session(tab, cx) else {
                continue;
            };
            let terminal = terminal.read(cx);
            let shell = terminal.shell();
            if !shell.is_ai_running()
                || !shell
                    .effective_provider()
                    .is_some_and(|p| p.eq_ignore_ascii_case("codex"))
            {
                continue;
            }
            let Some(native) = shell
                .ai_session_id()
                .filter(|id| uuid::Uuid::parse_str(id).is_ok())
            else {
                continue;
            };
            result.push(Binding {
                tab: uuid_string(uuid),
                native: native.into(),
                cwd: terminal
                    .cwd
                    .as_ref()
                    .map(|p| p.to_string_lossy().into_owned())
                    .unwrap_or_default(),
            });
        }
    }
    result
}
#[derive(Debug, Clone, serde::Serialize)]
pub struct Health {
    pub tab_id: String,
    pub session_id: String,
    pub phase: &'static str,
    pub lines_observed: u64,
    pub structured_records_observed: u64,
    pub pending_prompts: usize,
}
#[derive(Default)]
struct MonitorHealth(Vec<Health>);
impl Global for MonitorHealth {}
pub fn health(cx: &App) -> Vec<Health> {
    cx.try_global::<MonitorHealth>()
        .map(|h| h.0.clone())
        .unwrap_or_default()
}

pub fn start(cx: &mut App) {
    let sessions = cx.global::<AppData>().root.home().join(".codex/sessions");
    cx.default_global::<AppServerTrackers>();
    let timer = crate::observability::register_timer(
        cx,
        "runtime.codex_feedback",
        "Codex structured feedback",
        "runtime",
        200,
    );
    cx.spawn(async move |cx| {
        let _timer = timer;
        let began = Instant::now();
        let mut watches: Watches = HashMap::new();
        loop {
            cx.background_executor()
                .timer(Duration::from_millis(200))
                .await;
            let current = cx.update(bindings);
            if current.is_empty() && watches.is_empty() {
                continue;
            }
            let now = began.elapsed().as_millis().min(u64::MAX as u128) as u64;
            let sessions = sessions.clone();
            let (next, deliveries) = cx
                .background_spawn(async move { poll(&sessions, watches, current, now) })
                .await;
            watches = next;
            let health: Vec<_> = watches
                .iter()
                .map(|((tab, native), watch)| Health {
                    tab_id: tab.clone(),
                    session_id: native.clone(),
                    phase: if watch.reader.is_some() {
                        "watching"
                    } else {
                        "discovering"
                    },
                    lines_observed: watch.tracker.lines_observed,
                    structured_records_observed: watch.tracker.structured_records_observed,
                    pending_prompts: watch.tracker.pending_count(),
                })
                .collect();
            cx.update(|cx| {
                cx.default_global::<MonitorHealth>().0 = health;
                let alive: HashSet<_> = bindings(cx)
                    .into_iter()
                    .map(|b| (b.tab, b.native))
                    .collect();
                for (binding, delivery) in deliveries {
                    if !alive.contains(&(binding.tab.clone(), binding.native.clone())) {
                        continue;
                    }
                    match delivery {
                        Delivery::Feedback(Action::Prompt(prompt)) => {
                            manager().handle_codex_record(
                                &binding.tab,
                                &binding.native,
                                &binding.cwd,
                                &Record::Prompt(prompt.clone()),
                                &mut AppHost { cx },
                            );
                            let message = if prompt.options.is_empty() {
                                prompt.message
                            } else {
                                format!(
                                    "{}\nOptions: {}",
                                    prompt.message,
                                    prompt.options.join(", ")
                                )
                            };
                            publish(
                                &binding,
                                "user_input_requested",
                                &message,
                                "codex_rollout_feedback",
                                true,
                                cx,
                            );
                        }
                        Delivery::Feedback(Action::Resolved {
                            call_id,
                            has_other_pending,
                        }) => {
                            manager().resolve_codex_input(&binding.tab, has_other_pending);
                            if !has_other_pending {
                                publish(
                                    &binding,
                                    "user_input_resolved",
                                    &call_id,
                                    "codex_rollout_feedback",
                                    false,
                                    cx,
                                );
                            }
                        }
                        Delivery::Lifecycle(record) => {
                            manager().handle_codex_record(
                                &binding.tab,
                                &binding.native,
                                &binding.cwd,
                                &record,
                                &mut AppHost { cx },
                            );
                            if matches!(record, Record::TurnCompleted(_)) {
                                publish(
                                    &binding,
                                    "turn_completed",
                                    "Codex turn completed",
                                    "codex_rollout_feedback",
                                    false,
                                    cx,
                                );
                            }
                        }
                    }
                }
                sync_runtime_owned_tabs(cx);
            });
        }
    })
    .detach();
}
fn poll(
    sessions: &Path,
    mut watches: Watches,
    current: Vec<Binding>,
    now: u64,
) -> (Watches, Deliveries) {
    let alive: HashSet<_> = current
        .iter()
        .map(|b| (b.tab.clone(), b.native.clone()))
        .collect();
    watches.retain(|key, _| alive.contains(key));
    let mut deliveries = Vec::new();
    for binding in current {
        let watch = watches
            .entry((binding.tab.clone(), binding.native.clone()))
            .or_default();
        if watch.reader.is_none() && now >= watch.next_lookup {
            if let Some(path) = core::locate(sessions, &binding.native) {
                watch.reader = Some(core::Reader::new(path));
            } else {
                watch.next_lookup = now + core::retry_delay_ms(watch.attempt);
                watch.attempt = watch.attempt.saturating_add(1);
            }
        }
        if let Some(reader) = watch.reader.as_mut() {
            match reader.poll() {
                Ok(records) => {
                    watch.tracker.lines_observed = reader.lines_observed;
                    for (record, catch_up) in records {
                        match record {
                            Record::Prompt(_) | Record::Completed(_) => {
                                for action in watch.tracker.consume(record, now) {
                                    deliveries.push((binding.clone(), Delivery::Feedback(action)));
                                }
                            }
                            Record::Usage {
                                input,
                                output,
                                cached,
                                reasoning,
                            } => {
                                let old = watch.usage.replace((input, output, cached, reasoning));
                                if !catch_up
                                    && let Some((
                                        prior_input,
                                        prior_output,
                                        prior_cached,
                                        prior_reasoning,
                                    )) = old
                                {
                                    let delta = Record::Usage {
                                        input: input.saturating_sub(prior_input).max(0),
                                        output: output.saturating_sub(prior_output).max(0),
                                        cached: cached.saturating_sub(prior_cached).max(0),
                                        reasoning: reasoning.saturating_sub(prior_reasoning).max(0),
                                    };
                                    if !matches!(
                                        delta,
                                        Record::Usage {
                                            input: 0,
                                            output: 0,
                                            cached: 0,
                                            reasoning: 0,
                                        }
                                    ) {
                                        deliveries
                                            .push((binding.clone(), Delivery::Lifecycle(delta)));
                                    }
                                }
                            }
                            record if !catch_up => {
                                deliveries.push((binding.clone(), Delivery::Lifecycle(record)))
                            }
                            _ => (),
                        }
                    }
                }
                Err(_) => {
                    watch.reader = None;
                    watch.next_lookup = now + core::retry_delay_ms(watch.attempt);
                    watch.attempt = watch.attempt.saturating_add(1);
                }
            }
        }
        for action in watch.tracker.announce(now) {
            deliveries.push((binding.clone(), Delivery::Feedback(action)));
        }
    }
    (watches, deliveries)
}
fn publish(
    binding: &Binding,
    kind: &str,
    message: &str,
    producer: &str,
    notify: bool,
    cx: &mut App,
) {
    let mut event = AiEvent::new(
        AiEventSource::new(AiEventSource::CODEX),
        kind,
        "Codex",
        message,
        chau7_next_core::iso8601::now_iso8601(),
    );
    event.tab_id = find_tab(&binding.tab, cx).map(|t| events_out::tab_uuid(t.tab));
    event.session_id = Some(binding.native.clone());
    event.directory = Some(binding.cwd.clone());
    event.producer = Some(producer.into());
    event.reliability = AiEventReliability::Authoritative;
    events_out::publish(event, notify, cx);
}
#[derive(Default)]
struct AppServerTrackers(HashMap<(String, String), core::InteractionTracker>);
impl Global for AppServerTrackers {}
/// Optional actual JSON-RPC transport seam, matching Swift's PTY-neutral ingestion API.
#[allow(dead_code)] // The default PTY transport does not carry App Server JSON-RPC, as in Swift.
pub fn ingest_app_server(tab_id: &str, line: &str, cx: &mut App) -> bool {
    let Some(interaction) = core::parse_app_server(line) else {
        return false;
    };
    let Some(binding) = bindings(cx).into_iter().find(|b| b.tab == tab_id) else {
        return false;
    };
    if interaction
        .thread_id
        .as_ref()
        .is_some_and(|id| !id.eq_ignore_ascii_case(&binding.native))
    {
        return false;
    }
    let (resolved, pending) = {
        let trackers = &mut cx.default_global::<AppServerTrackers>().0;
        trackers.retain(|(tab, native), _| tab != tab_id || native == &binding.native);
        trackers
            .entry((binding.tab.clone(), binding.native.clone()))
            .or_default()
            .consume(&interaction)
    };
    if let Some(kind) = interaction.kind {
        match kind {
            core::InteractionKind::UserInput => {
                if let Some(prompt) = interaction.prompt {
                    manager().handle_codex_record(
                        &binding.tab,
                        &binding.native,
                        &binding.cwd,
                        &Record::Prompt(prompt.clone()),
                        &mut AppHost { cx },
                    );
                    publish(
                        &binding,
                        "user_input_requested",
                        &prompt.message,
                        "codex_app_server",
                        true,
                        cx,
                    );
                }
            }
            core::InteractionKind::Approval => {
                let session = manager().handle_codex_record(
                    &binding.tab,
                    &binding.native,
                    &binding.cwd,
                    &Record::Started(String::new()),
                    &mut AppHost { cx },
                );
                if let Some(session) = session {
                    if session.state()
                        == chau7_next_core::runtime::session_state::State::WaitingInput
                    {
                        session.transition(
                            chau7_next_core::runtime::session_state::Trigger::InputProvided,
                        );
                    }
                    session.request_approval("Codex", "Codex is waiting for approval.");
                }
                publish(
                    &binding,
                    "approval_requested",
                    "Codex is waiting for approval.",
                    "codex_app_server",
                    true,
                    cx,
                );
            }
        }
    } else if let Some(resolved) = resolved {
        if pending.contains(&core::InteractionKind::Approval) {
            publish(
                &binding,
                "approval_requested",
                "Codex is waiting for approval.",
                "codex_app_server",
                false,
                cx,
            );
        } else if pending.contains(&core::InteractionKind::UserInput) {
            if let Some(session) = manager().session_for_tab(&binding.tab) {
                session.reconcile_approval_resolution("codex_app_server");
                session
                    .transition(chau7_next_core::runtime::session_state::Trigger::InputRequested);
            }
            publish(
                &binding,
                "user_input_requested",
                "Codex is waiting for input.",
                "codex_app_server",
                false,
                cx,
            );
        } else {
            manager().resolve_codex_input(&binding.tab, false);
            if let Some(session) = manager().session_for_tab(&binding.tab)
                && session.pending_approval().is_some()
            {
                session.reconcile_approval_resolution("codex_app_server");
            }
            publish(
                &binding,
                if resolved == core::InteractionKind::Approval {
                    "approval_resolved"
                } else {
                    "user_input_resolved"
                },
                "Codex request resolved",
                "codex_app_server",
                false,
                cx,
            );
        }
    }
    true
}
