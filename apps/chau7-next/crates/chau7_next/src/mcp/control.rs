//! Current MCP control plane. The transport supplies the connection identity;
//! tool arguments never choose an owner. All terminal reads happen on GPUI's
//! main thread and every awaited approval is followed by an incarnation check.
use super::{
    MainThread,
    tools::{self, ToolContext},
    windows::{find_tab, parse_tab_id},
};
use crate::settings::Settings;
use chau7_next_core::mcp::{
    control_plane::{
        self as policy, ControlGrants, ExecutionSnapshot, GrantOrigin, LaunchOptions, PromptResult,
        Readiness,
    },
    output::{encode_sorted, json_error},
};
use gpui::{App, PromptLevel};
use serde_json::{Map, Value, json};
use std::{
    collections::HashSet,
    sync::{Mutex, OnceLock},
    time::{Duration, Instant},
};
use uuid::Uuid;

#[derive(Default)]
struct Controls {
    grants: ControlGrants,
    pending_commands: HashSet<(Uuid, String)>,
}
fn controls() -> &'static Mutex<Controls> {
    static CONTROLS: OnceLock<Mutex<Controls>> = OnceLock::new();
    CONTROLS.get_or_init(|| Mutex::new(Controls::default()))
}
fn lock_controls() -> std::sync::MutexGuard<'static, Controls> {
    controls().lock().unwrap_or_else(|e| e.into_inner())
}
static CONSENT: Mutex<()> = Mutex::new(());
fn missing(tab: &str) -> String {
    json_error(&format!("Tab not found: {tab}"))
}
fn unavailable() -> String {
    json_error("Chau7 Next main thread unavailable")
}
fn identity(tab_id: &str, cx: &mut App) -> Option<(Uuid, String)> {
    let uuid = parse_tab_id(tab_id)?;
    let tab = find_tab(tab_id, cx)?;
    let session = tab.window.workspace.read(cx).mcp_session(tab.tab, cx)?;
    Some((uuid, session.read(cx).tab_identifier.clone()))
}
/// Mandatory final-hop check after an approval and immediately before input,
/// close, rename or CTO mutation. Internal origins are bypassed by the router,
/// using the private ToolContext origin, never a client-provided owner string.
pub fn authorize_mutation_on_main(tab_id: &str, owner: &str, cx: &mut App) -> Result<(), String> {
    if !Settings::get(cx).mcp.enabled {
        return Err(json_error("MCP is disabled in settings."));
    }
    let (uuid, terminal) = identity(tab_id, cx).ok_or_else(|| missing(tab_id))?;
    let tab = find_tab(tab_id, cx).ok_or_else(|| missing(tab_id))?;
    let flagged = tab.window.workspace.read(cx).mcp_controlled(tab.tab);
    let controls = lock_controls();
    if !flagged || !controls.grants.allows(uuid, owner, &terminal) {
        return Err(json_error(&format!(
            "Tab {tab_id} requires explicit MCP control for this client. Call tab_request_control first."
        )));
    }
    if controls.pending_commands.contains(&(uuid, terminal)) {
        return Err(json_error("command_approval_pending"));
    }
    Ok(())
}
/// Root marks real command approval dialogs around the wait, then clears the
/// flag before the approved mutation's final-hop authority check.
pub fn set_command_approval_pending_on_main(tab_id: &str, pending: bool, cx: &mut App) {
    if let Some(identity) = identity(tab_id, cx) {
        let mut controls = lock_controls();
        if pending {
            controls.pending_commands.insert(identity);
        } else {
            controls
                .pending_commands
                .retain(|(tab, _)| *tab != identity.0);
        }
    }
}
/// The socket transport registers its actual per-connection identity before
/// dispatching any call. A closed connection cannot reacquire capabilities.
pub fn connect(owner: &str) -> Result<(), &'static str> {
    lock_controls().grants.connect(owner)
}
pub fn is_connected(owner: &str) -> bool {
    lock_controls().grants.is_connected(owner)
}

/// Connection teardown revokes only that client's process-local capabilities.
pub fn disconnect(owner: &str, main: &MainThread) {
    let removed = lock_controls().grants.disconnect(owner);
    let _ = main.dispatch(move |cx| {
        for uuid in removed {
            // A locally confirmed transfer may have happened after teardown.
            if lock_controls().grants.has_tab(uuid) {
                continue;
            }
            if let Some(tab) = find_tab(&uuid.to_string(), cx) {
                tab.window.workspace.update(cx, |ws, cx| {
                    ws.mcp_set_control(tab.tab, false);
                    cx.notify();
                });
            }
        }
    });
}
pub fn forget_closed_tab(tab_id: &str) {
    if let Some(uuid) = parse_tab_id(tab_id) {
        let mut state = lock_controls();
        state.grants.forget(uuid);
        state.pending_commands.retain(|(tab, _)| *tab != uuid);
    }
}
/// Projects a parked restored tab as known-but-unavailable, without creating
/// a terminal or granting the caller mutation authority.
fn deferred_status_projection(mut out: Map<String, Value>) -> Map<String, Value> {
    let terminal = Readiness::evaluate(&ExecutionSnapshot {
        shell_loading: true,
        at_prompt: false,
        has_view: false,
        status: "unknown".into(),
        approval_pending: false,
    });
    out.insert("restore_state".into(), json!("deferred"));
    out.insert("status".into(), json!("unknown"));
    out.insert("is_at_prompt".into(), false.into());
    out.insert("is_mcp_controlled".into(), false.into());
    out.insert("shell_loading".into(), true.into());
    out.insert("has_terminal_view".into(), false.into());
    out.insert("command_approval_pending".into(), false.into());
    out.insert("mcp_mutation_allowed".into(), false.into());
    out.insert("mcp_control_required".into(), true.into());
    out.insert(
        "terminal_can_accept_exec".into(),
        terminal.can_accept.into(),
    );
    out.insert("terminal_ready_for_exec".into(), terminal.ready.into());
    terminal.project(false).insert(&mut out);
    out
}

/// Lightweight readiness snapshot; wait_ready never samples process CPU or
/// reads the scrollback on each poll.
fn snapshot_on_main(tab_id: &str, owner: &str, cx: &mut App) -> Option<Map<String, Value>> {
    let tab = find_tab(tab_id, cx)?;
    let ws = tab.window.workspace.read(cx);
    let Some(session) = ws.mcp_session(tab.tab, cx) else {
        ws.mcp_deferred_saved(tab.tab, cx)?;
        return Some(deferred_status_projection(
            ws.mcp_readiness_summary(tab.tab, cx),
        ));
    };
    let session = session.read(cx);
    let uuid = parse_tab_id(tab_id)?;
    let mut out = ws.mcp_readiness_summary(tab.tab, cx);
    let state = lock_controls();
    let authorized = Settings::get(cx).mcp.enabled
        && out.get("is_mcp_controlled").and_then(Value::as_bool) == Some(true)
        && state.grants.allows(uuid, owner, &session.tab_identifier);
    let pending = state
        .pending_commands
        .contains(&(uuid, session.tab_identifier.clone()));
    drop(state);
    let terminal = Readiness::evaluate(&ExecutionSnapshot {
        shell_loading: session.is_loading(),
        at_prompt: session.is_at_prompt(),
        has_view: true,
        status: session.status().as_str().into(),
        approval_pending: pending,
    });
    out.insert("shell_loading".into(), session.is_loading().into());
    out.insert("has_terminal_view".into(), true.into());
    out.insert("command_approval_pending".into(), pending.into());
    out.insert("mcp_mutation_allowed".into(), authorized.into());
    out.insert("mcp_control_required".into(), (!authorized).into());
    out.insert(
        "terminal_can_accept_exec".into(),
        terminal.can_accept.into(),
    );
    out.insert("terminal_ready_for_exec".into(), terminal.ready.into());
    terminal.project(authorized).insert(&mut out);
    if let Some(run) = super::sources::telemetry().active_run_for_tab(&session.tab_identifier) {
        out.insert("active_run".into(),json!({"run_id":run.id,"provider":run.provider,"started_at":run.started_at.to_rfc3339(),"session_id":run.session_id,"duration_so_far_ms":(chrono::Utc::now()-run.started_at).num_milliseconds()}));
    }
    Some(out)
}
fn snapshot(tab_id: &str, owner: &str, main: &MainThread) -> Result<Map<String, Value>, String> {
    let id = tab_id.to_string();
    let owner = owner.to_string();
    main.call(move |cx| snapshot_on_main(&id, &owner, cx))
        .ok_or_else(unavailable)?
        .ok_or_else(|| missing(tab_id))
}
pub fn definitions() -> Vec<Value> {
    vec![
        tools::tool(
            "tab_request_control",
            "Request user-confirmed MCP control of an existing user-opened tab. Chau7 Next always shows a local confirmation. A granted control session lasts until release, tab closure, connection teardown or Chau7 Next quits.",
            json!({"type":"object","properties":{"tab_id":{"type":"string","description":"Existing tab ID from tab_list"}},"required":["tab_id"]}),
        ),
        tools::tool(
            "tab_release_control",
            "Release this client's MCP control of a tab without closing it. Subsequent mutating tab tools require a new grant.",
            json!({"type":"object","properties":{"tab_id":{"type":"string","description":"MCP-controlled tab ID"}},"required":["tab_id"]}),
        ),
        tools::tool(
            "tab_wait_ready",
            "Wait for deterministic exec acceptance (can_accept_exec=true), including queued shell bootstrap. Returns the last observed status on success or timeout.",
            json!({"type":"object","properties":{"tab_id":{"type":"string"},"timeout_ms":{"type":"integer","description":"Maximum wait in milliseconds, default 30000, max 120000."}},"required":["tab_id"]}),
        ),
        tools::tool(
            "agent_launch",
            "Launch one or more AI agents in fresh tabs with optional task prompts. Composes tab_create, tab_wait_ready, tab_exec and verified throttled prompt injection. Returns per-agent prompt visibility, submission and running evidence.",
            json!({"type":"object","properties":{"directory":{"type":"string"},"agent_command":{"type":"string","description":"Agent shell command, default claude."},"prompt":{"type":"string"},"count":{"type":"integer","description":"Number of agents, default 1, capped by MCP tab limit."},"pr_number":{"type":"integer"},"window_id":{"type":"integer"},"ready_timeout_ms":{"type":"integer","description":"Per-agent readiness/attach timeout, default 30000."}}}),
        ),
    ]
}
/// Router calls this only for an external connection. Root owns the origin
/// policy and also gates the remaining mutating tab tools at their final hops.
pub fn call(
    name: &str,
    args: &Map<String, Value>,
    owner: &str,
    ctx: &ToolContext,
) -> Option<String> {
    Some(match name {
        "tab_create" => create(args, owner, ctx),
        "tab_status" => {
            let Some(id) = tools::arg_str(args, "tab_id") else {
                return Some(json_error("tab_id is required"));
            };
            let mut full =
                serde_json::from_str::<Value>(&tools::tabs::status(id, ctx)).unwrap_or(Value::Null);
            match snapshot(id, owner, ctx.main) {
                Ok(snapshot) => {
                    if let Some(full) = full.as_object_mut() {
                        full.extend(snapshot);
                    }
                    encode_sorted(&full)
                }
                Err(error) => error,
            }
        }
        "tab_request_control" => match tools::arg_str(args, "tab_id") {
            Some(id) => request(id, owner, ctx.main),
            None => json_error("tab_id is required"),
        },
        "tab_release_control" => match tools::arg_str(args, "tab_id") {
            Some(id) => release(id, owner, ctx.main),
            None => json_error("tab_id is required"),
        },
        "tab_wait_ready" => match tools::arg_str(args, "tab_id") {
            Some(id) => wait_ready(
                id,
                owner,
                tools::arg_int(args, "timeout_ms").unwrap_or(30000),
                ctx.main,
            ),
            None => json_error("tab_id is required"),
        },
        "agent_launch" => match LaunchOptions::parse(args) {
            Ok(options) => launch(options, owner, ctx),
            Err(error) => json_error(&error),
        },
        _ => return None,
    })
}
fn create(args: &Map<String, Value>, owner: &str, ctx: &ToolContext) -> String {
    if !lock_controls().grants.is_connected(owner) {
        return json_error("MCP client connection closed");
    }
    let response = tools::tabs::create_tab(
        tools::arg_str(args, "directory").map(str::to_string),
        tools::arg_int(args, "window_id"),
        ctx,
    );
    let value = serde_json::from_str::<Value>(&response).unwrap_or(Value::Null);
    let Some(tab_id) = value.get("tab_id").and_then(Value::as_str) else {
        return response;
    };
    let id = tab_id.to_string();
    let owner = owner.to_string();
    let result = ctx.main.call(move |cx| {
        let (uuid, terminal) = identity(&id, cx).ok_or_else(|| missing(&id))?;
        let granted = lock_controls()
            .grants
            .grant(uuid, &owner, &terminal, GrantOrigin::Created)
            .map_err(json_error);
        if granted.is_err()
            && let Some(tab) = find_tab(&id, cx)
        {
            tab.window.workspace.update(cx, |ws, cx| {
                ws.mcp_set_control(tab.tab, false);
                cx.notify();
            });
        }
        granted
    });
    match result {
        Some(Ok(())) => response,
        Some(Err(error)) => error,
        None => unavailable(),
    }
}
fn request(tab_id: &str, owner: &str, main: &MainThread) -> String {
    if !lock_controls().grants.is_connected(owner) {
        return json_error("MCP client connection closed");
    }
    let id = tab_id.to_string();
    let prepared=main.call(move|cx|{
        if !Settings::get(cx).mcp.enabled{return Err(json_error("MCP is disabled in settings."));}
        let (uuid,terminal)=identity(&id,cx).ok_or_else(||missing(&id))?;
        let tab=find_tab(&id,cx).ok_or_else(||missing(&id))?;
        let ws=tab.window.workspace.read(cx);
        let summary=ws.mcp_summary(tab.tab,cx);
        let controlled=summary.get("is_mcp_controlled").and_then(Value::as_bool)==Some(true);
        let limit=Settings::get(cx).mcp.tab_limit();
        if !controlled && ws.mcp_tab_count()>=limit{return Err(json_error(&format!("MCP tab limit reached ({limit}). Release or close a controlled tab first.")));}
        let title=summary.get("title").and_then(Value::as_str).unwrap_or("Shell");
        let cwd=summary.get("cwd").and_then(Value::as_str).unwrap_or("");
        Ok((uuid,terminal,tab.window.handle,format!("A connected MCP client wants to control the existing tab “{title}” in {cwd}.\n\nThis client will be able to send commands and key presses and close this tab until control is released, its connection closes, or Chau7 Next quits.")))
    });
    let (uuid, terminal, handle, message) = match prepared {
        Some(Ok(prepared)) => prepared,
        Some(Err(error)) => return error,
        None => return unavailable(),
    };
    // Existing grants are not broadened silently to a different connection.
    let _consent = CONSENT.lock().unwrap_or_else(|e| e.into_inner());
    let approved = main
        .call_async(move |cx, reply| {
            let prompt = handle.update(cx, |_, window, cx| {
                window.activate_window();
                crate::l10n::prompt(
                    window,
                    PromptLevel::Warning,
                    "MCP Tab Control",
                    Some(&message),
                    &["Deny", "Allow"],
                    cx,
                )
            });
            match prompt {
                Ok(answer) => {
                    cx.spawn(async move |_| {
                        let _ = reply.send(answer.await.ok() == Some(1));
                    })
                    .detach();
                }
                Err(_) => {
                    let _ = reply.send(false);
                }
            }
        })
        .unwrap_or(false);
    if !approved {
        return json_error("Tab control denied by user.");
    }
    let owner = owner.to_string();
    let id = tab_id.to_string();
    main.call(move |cx| {
        if !Settings::get(cx).mcp.enabled {
            return json_error("MCP is disabled in settings.");
        }
        if identity(&id, cx) != Some((uuid, terminal.clone())) {
            return json_error("Tab changed while approval was pending; retry the request.");
        }
        let Some(tab) = find_tab(&id, cx) else {
            return missing(&id);
        };
        let ws = tab.window.workspace.read(cx);
        let controlled = ws
            .mcp_readiness_summary(tab.tab, cx)
            .get("is_mcp_controlled")
            .and_then(Value::as_bool)
            == Some(true);
        let limit = Settings::get(cx).mcp.tab_limit();
        if !controlled && ws.mcp_tab_count() >= limit {
            return json_error(&format!("MCP tab limit reached ({limit})."));
        }
        if let Err(error) =
            lock_controls()
                .grants
                .grant(uuid, &owner, &terminal, GrantOrigin::UserConfirmed)
        {
            return json_error(error);
        }
        tab.window.workspace.update(cx, |ws, cx| {
            ws.mcp_set_control(tab.tab, true);
            cx.notify();
        });
        log::info!("MCP: user granted client control of tab {id}");
        encode_sorted(
            &json!({"ok":true,"tab_id":id,"is_mcp_controlled":true,"status":"control_granted"}),
        )
    })
    .unwrap_or_else(unavailable)
}
fn release(tab_id: &str, owner: &str, main: &MainThread) -> String {
    let owner = owner.to_string();
    let id = tab_id.to_string();
    main.call(move |cx| {
        let Some((uuid, terminal)) = identity(&id, cx) else {
            return missing(&id);
        };
        if let Err(error) = lock_controls().grants.release(uuid, &owner, &terminal) {
            return json_error(error);
        }
        let Some(tab) = find_tab(&id, cx) else {
            return missing(&id);
        };
        tab.window.workspace.update(cx, |ws, cx| {
            ws.mcp_set_control(tab.tab, false);
            cx.notify();
        });
        encode_sorted(
            &json!({"ok":true,"tab_id":id,"is_mcp_controlled":false,"status":"control_released"}),
        )
    })
    .unwrap_or_else(unavailable)
}
fn wait_ready(tab_id: &str, owner: &str, timeout_ms: i64, main: &MainThread) -> String {
    let start = Instant::now();
    let timeout = Duration::from_millis(policy::bounded_wait_timeout(timeout_ms));
    loop {
        let status = match snapshot(tab_id, owner, main) {
            Ok(status) => status,
            Err(error) => return error,
        };
        let allowed = status.get("mcp_mutation_allowed").and_then(Value::as_bool) == Some(true);
        let accepted = status.get("can_accept_exec").and_then(Value::as_bool) == Some(true);
        let timed_out = !accepted && start.elapsed() >= timeout;
        if !allowed || accepted || timed_out {
            let mut result = json!({"tab_id":tab_id,"can_accept_exec":accepted,"ready_for_exec":status.get("ready_for_exec").and_then(Value::as_bool).unwrap_or(false),"timed_out":timed_out,"waited_ms":start.elapsed().as_millis() as u64,"status":status});
            if !allowed {
                result["error"] = format!(
                    "Tab {tab_id} requires explicit MCP control. Call tab_request_control first."
                )
                .into();
                result["timed_out"] = false.into();
            }
            return encode_sorted(&result);
        }
        let remaining = timeout.saturating_sub(start.elapsed());
        std::thread::sleep(policy::poll_interval(start.elapsed(), remaining));
    }
}
fn lightweight_status(
    tab: &str,
    owner: &str,
    ctx: &ToolContext,
) -> Result<Map<String, Value>, String> {
    snapshot(tab, owner, ctx.main)
}
fn tab_output(tab: &str, source: &str, ctx: &ToolContext) -> String {
    tools::tabs::call(
        "tab_output",
        json!({"tab_id":tab,"lines":160,"source":source})
            .as_object()
            .unwrap(),
        ctx,
    )
    .and_then(|s| serde_json::from_str::<Value>(&s).ok())
    .and_then(|v| v.get("output").and_then(Value::as_str).map(str::to_string))
    .unwrap_or_default()
}
fn provider(status: &Map<String, Value>) -> Option<&str> {
    ["raw_active_app", "active_app", "ai_provider"]
        .into_iter()
        .find_map(|key| {
            status
                .get(key)
                .and_then(Value::as_str)
                .filter(|s| !s.trim().is_empty())
        })
}
fn action(
    name: &str,
    tab: &str,
    args: Value,
    owner: &str,
    ctx: &ToolContext,
) -> Result<Value, String> {
    let id = tab.to_string();
    let owner = owner.to_string();
    ctx.main
        .call(move |cx| authorize_mutation_on_main(&id, &owner, cx))
        .ok_or_else(unavailable)??;
    let response = tools::tabs::call(name, args.as_object().unwrap(), ctx)
        .ok_or_else(|| json_error("Unknown tab action"))?;
    let value =
        serde_json::from_str::<Value>(&response).map_err(|_| "Invalid tab response".to_string())?;
    if let Some(error) = value.get("error") {
        return Err(error
            .as_str()
            .map(str::to_string)
            .unwrap_or_else(|| error.to_string()));
    }
    if value.get("ok").and_then(Value::as_bool) != Some(true) {
        return Err("Tab action did not return ok=true".into());
    }
    Ok(value)
}
fn throttle() {
    std::thread::sleep(Duration::from_millis(350));
}
fn inject_prompt(
    tab: &str,
    prompt: &str,
    timeout_ms: u64,
    owner: &str,
    ctx: &ToolContext,
) -> PromptResult {
    let deadline = Instant::now() + Duration::from_millis(timeout_ms);
    let attached_provider = loop {
        if Instant::now() >= deadline {
            return PromptResult::failed(
                "agent_not_detected",
                "no attached AI provider was detected before timeout",
            );
        }
        let status = match lightweight_status(tab, owner, ctx) {
            Ok(status) => status,
            Err(error) => return PromptResult::failed("agent_unavailable", error),
        };
        if status.get("mcp_mutation_allowed").and_then(Value::as_bool) != Some(true) {
            return PromptResult::failed(
                "control_released",
                "MCP control was released while waiting for the agent",
            );
        }
        if let Some(provider) = provider(&status) {
            break provider.to_string();
        }
        if policy::exited_before_prompt(&status) {
            return PromptResult::failed(
                "agent_exited_before_prompt",
                "attached agent exited or returned to the shell before prompt injection",
            );
        }
        std::thread::sleep(
            Duration::from_millis(250).min(deadline.saturating_duration_since(Instant::now())),
        );
    };
    let input_deadline = Instant::now()
        + Duration::from_millis(timeout_ms.div_ceil(3).clamp(2000, 8000))
            .min(deadline.saturating_duration_since(Instant::now()));
    loop {
        if Instant::now() >= input_deadline {
            return PromptResult::failed(
                "agent_input_not_ready",
                "attached agent did not render a recognizable input surface before prompt injection",
            );
        }
        let status = match lightweight_status(tab, owner, ctx) {
            Ok(status) => status,
            Err(error) => return PromptResult::failed("agent_unavailable", error),
        };
        if policy::exited_before_prompt(&status) && provider(&status).is_none() {
            return PromptResult::failed(
                "agent_exited_before_prompt",
                "attached agent exited before its input surface was ready",
            );
        }
        if policy::input_ready(
            &tab_output(tab, "buffer", ctx),
            Some(&attached_provider),
            false,
        ) {
            break;
        }
        std::thread::sleep(
            Duration::from_millis(200)
                .min(input_deadline.saturating_duration_since(Instant::now())),
        );
    }
    throttle();
    if let Err(error) = action(
        "tab_send_input",
        tab,
        json!({"tab_id":tab,"input":prompt}),
        owner,
        ctx,
    ) {
        return PromptResult::failed("input_rejected", error);
    }
    throttle();
    let needles = policy::visibility_needles(prompt);
    let echo_deadline = Instant::now() + Duration::from_millis((timeout_ms / 4).clamp(1000, 4000));
    let visible = if needles.is_empty() {
        true
    } else {
        loop {
            let output = tab_output(tab, "buffer", ctx);
            if needles.iter().any(|needle| output.contains(needle)) {
                break true;
            }
            if Instant::now() >= echo_deadline {
                break false;
            }
            std::thread::sleep(
                Duration::from_millis(200)
                    .min(echo_deadline.saturating_duration_since(Instant::now())),
            );
        }
    };
    throttle();
    if let Err(error) = action("tab_submit_prompt", tab, json!({"tab_id":tab}), owner, ctx) {
        let mut result = PromptResult::failed("submit_failed", error);
        result.prompt_input_visible = visible;
        return result;
    }
    throttle();
    let running_deadline =
        Instant::now() + Duration::from_millis((timeout_ms / 4).clamp(1500, 5000));
    let running = loop {
        let status = match lightweight_status(tab, owner, ctx) {
            Ok(status) => status,
            Err(_) => break false,
        };
        if policy::agent_running(&status)
            || ["buffer", "pty_log"].iter().any(|source| {
                policy::input_ready(
                    &tab_output(tab, source, ctx),
                    Some(&attached_provider),
                    true,
                )
            })
        {
            break true;
        }
        if Instant::now() >= running_deadline {
            break false;
        }
        std::thread::sleep(
            Duration::from_millis(250)
                .min(running_deadline.saturating_duration_since(Instant::now())),
        );
    };
    PromptResult::submitted(visible, running)
}
fn launch(options: LaunchOptions, owner: &str, ctx: &ToolContext) -> String {
    let mut agents = Vec::new();
    let command = options.command();
    for index in 0..options.bounded_count() {
        let create_args = json!({"directory":options.directory,"window_id":options.window_id});
        let created =
            serde_json::from_str::<Value>(&create(create_args.as_object().unwrap(), owner, ctx))
                .unwrap_or(Value::Null);
        let Some(tab) = created.get("tab_id").and_then(Value::as_str) else {
            agents.push(json!({"index":index,"status":"failed","stage":"create","error":created.get("error").cloned().unwrap_or_else(||"Tab creation failed".into())}));
            break;
        };
        let tab = tab.to_string();
        throttle();
        let ready = serde_json::from_str::<Value>(&wait_ready(
            &tab,
            owner,
            options.timeout_ms() as i64,
            ctx.main,
        ))
        .unwrap_or(Value::Null);
        if ready.get("can_accept_exec").and_then(Value::as_bool) != Some(true) {
            agents.push(json!({"index":index,"tab_id":tab,"status":"failed","stage":"wait_ready","error":ready.get("error").cloned().unwrap_or_else(||"Tab did not become ready before timeout".into())}));
            continue;
        }
        throttle();
        if let Err(error) = action(
            "tab_exec",
            &tab,
            json!({"tab_id":tab,"command":command}),
            owner,
            ctx,
        ) {
            agents.push(json!({"index":index,"tab_id":tab,"status":"failed","stage":"exec","launch_command":command,"error":error}));
            continue;
        }
        throttle();
        let result = options
            .prompt
            .as_deref()
            .filter(|p| !p.is_empty())
            .map(|prompt| inject_prompt(&tab, prompt, options.prompt_timeout_ms(), owner, ctx))
            .unwrap_or_else(PromptResult::skipped);
        let failed = options.prompt.as_deref().is_some_and(|p| !p.is_empty()) && !result.accepted();
        let mut agent = serde_json::to_value(&result).unwrap();
        agent["index"] = index.into();
        agent["tab_id"] = tab.into();
        agent["status"] = if failed { "failed" } else { "launched" }.into();
        agent["launch_command"] = command.clone().into();
        if failed {
            agent["stage"] = "prompt".into();
        }
        agents.push(agent);
        throttle();
    }
    let launched = agents
        .iter()
        .filter(|agent| agent["status"] == "launched")
        .count();
    let mut result = json!({"requested":options.count,"launched":launched,"agent_command":options.agent_command,"agents":agents,"next":"Collect each agent's output with tab_output(source='pty_log')."});
    if let Some(pr) = options.pr_number {
        result["pr_number"] = pr.into();
    }
    encode_sorted(&result)
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn current_swift_control_schemas_have_required_fields() {
        let definitions = definitions();
        assert_eq!(
            definitions
                .iter()
                .map(|v| v["name"].as_str().unwrap())
                .collect::<Vec<_>>(),
            [
                "tab_request_control",
                "tab_release_control",
                "tab_wait_ready",
                "agent_launch"
            ]
        );
        for tool in definitions.iter().take(3) {
            assert_eq!(tool["inputSchema"]["required"], json!(["tab_id"]));
        }
        for field in [
            "directory",
            "window_id",
            "agent_command",
            "prompt",
            "count",
            "pr_number",
            "ready_timeout_ms",
        ] {
            assert!(
                definitions[3]["inputSchema"]["properties"]
                    .get(field)
                    .is_some()
            );
        }
    }

    #[test]
    fn deferred_status_projection_forces_read_only_blocked_state() {
        let base = json!({
            "tab_id": "parked-uuid",
            "title": "Restored",
            "status": "idle",
            "cwd": "/tmp/project",
            "is_at_prompt": true,
            "is_mcp_controlled": true
        });
        let projected = deferred_status_projection(base.as_object().unwrap().clone());

        assert_eq!(projected["tab_id"], "parked-uuid");
        assert_eq!(projected["cwd"], "/tmp/project");
        assert_eq!(projected["status"], "unknown");
        assert_eq!(projected["is_at_prompt"], false);
        assert_eq!(projected["is_mcp_controlled"], false);
        assert_eq!(projected["restore_state"], "deferred");
        assert_eq!(projected["shell_loading"], true);
        assert_eq!(projected["has_terminal_view"], false);
        assert_eq!(projected["command_approval_pending"], false);
        assert_eq!(projected["mcp_mutation_allowed"], false);
        assert_eq!(projected["mcp_control_required"], true);

        // The parked terminal is queued underneath, while this MCP caller is blocked.
        assert_eq!(projected["terminal_can_accept_exec"], true);
        assert_eq!(projected["terminal_ready_for_exec"], false);
        assert_eq!(projected["can_accept_exec"], false);
        assert_eq!(projected["ready_for_exec"], false);
        assert_eq!(projected["exec_acceptance_mode"], "blocked");
        assert_eq!(projected["readiness_reason"], "mcp_control_required");
    }
}
