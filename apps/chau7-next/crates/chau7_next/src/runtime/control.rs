//! The `runtime_*` MCP tools (`RuntimeControlService.swift`, MCP-031 to
//! MCP-038). They run on the MCP client thread and reach tabs through the
//! tab tools (`crate::mcp::tools::tabs`), as Swift goes through
//! `TerminalControlService`: the prompt and approval answers pass the same
//! command filter as `tab_send_input`.

use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

use chau7_next_core::mcp::output::{encode_sorted, json_error};
use chau7_next_core::runtime::agent_backend::SessionConfig;
use chau7_next_core::runtime::backends::{
    backend_named, binary_name, missing_binary_message, unknown_backend_message, validate_model,
};
use chau7_next_core::runtime::runtime_event::poll_response_json;
use chau7_next_core::runtime::session::RuntimeSession;
use chau7_next_core::runtime::session_state::State;
use serde_json::{Map, Value, json};

use super::manager;
use crate::mcp::MainThread;
use crate::mcp::tools::{ToolContext, arg_bool, arg_str, arg_str_list, tabs};
use crate::mcp::windows::parse_tab_id;

/// Capture the private caller origin before dispatching deferred work. The
/// connection identity is supplied by the transport, never by tool arguments.
#[derive(Clone)]
struct CallOrigin {
    internal: bool,
    client_id: String,
}
impl CallOrigin {
    fn capture(ctx: &ToolContext) -> Self {
        Self {
            internal: ctx.is_internal(),
            client_id: ctx.client_id.to_string(),
        }
    }
    fn context<'a>(&'a self, main: &'a MainThread) -> ToolContext<'a> {
        if self.internal {
            ToolContext::internal(main)
        } else {
            ToolContext::connection(main, &self.client_id)
        }
    }
    fn authorize(&self, tab: &str, cx: &mut gpui::App) -> Result<(), String> {
        if self.internal {
            Ok(())
        } else {
            crate::mcp::control::authorize_mutation_on_main(tab, &self.client_id, cx)
        }
    }
}
fn connected(ctx: &ToolContext) -> Result<(), String> {
    if ctx.is_internal() || crate::mcp::control::is_connected(ctx.client_id) {
        Ok(())
    } else {
        Err(json_error("MCP client connection is closed"))
    }
}
fn with_authorized_tab<T: Send + 'static>(
    tab: &str,
    ctx: &ToolContext,
    action: impl FnOnce(&mut gpui::App) -> T + Send + 'static,
) -> Result<T, String> {
    connected(ctx)?;
    let tab = tab.to_string();
    let origin = CallOrigin::capture(ctx);
    ctx.main
        .call(move |cx| {
            origin.authorize(&tab, cx)?;
            Ok(action(cx))
        })
        .unwrap_or_else(|| Err(json_error("Chau7 Next main thread unavailable")))
}
fn authorize_tab(tab: &str, ctx: &ToolContext) -> Result<(), String> {
    if ctx.is_internal() {
        return Ok(());
    }
    with_authorized_tab(tab, ctx, |_| ())
}
fn delivery_error(response: &str) -> Option<String> {
    match serde_json::from_str::<Value>(response) {
        Ok(value)
            if value.get("error").is_none() && value.get("ok") == Some(&Value::Bool(true)) =>
        {
            None
        }
        Ok(value) if value.get("error").is_some() => Some(response.to_string()),
        _ => Some(json_error("Terminal did not confirm input delivery")),
    }
}

/// `handleToolCall`.
pub fn handle_tool_call(name: &str, args: &Map<String, Value>, ctx: &ToolContext) -> String {
    match name {
        "runtime_session_create" => create_session(args, ctx),
        "runtime_session_list" => {
            let include = arg_bool(args, "include_stopped").unwrap_or(false);
            let list: Vec<Value> = manager()
                .all_sessions(include)
                .iter()
                .map(|s| s.summary())
                .collect();
            encode_sorted(&Value::Array(list))
        }
        "runtime_session_get" => match session_arg(args) {
            Ok(session) => encode_sorted(&session.summary()),
            Err(err) => err,
        },
        "runtime_session_stop" => stop_session(args, ctx),
        "runtime_session_children" => child_sessions(args),
        "runtime_session_cancel_children" => cancel_children(args, ctx),
        "runtime_session_retry" => retry_session(args, ctx),
        "runtime_turn_result" => turn_result(args, ctx),
        "runtime_turn_wait" => wait_turn(args),
        "runtime_turn_send" => send_turn(args, ctx),
        "runtime_turn_status" => turn_status(args),
        "runtime_events_poll" => poll_events(args),
        "runtime_approval_respond" => respond_to_approval(args, ctx),
        _ => json_error(&format!("Unknown runtime tool: {name}")),
    }
}

/// The session named by `session_id`, or the error to return.
fn session_arg(args: &Map<String, Value>) -> Result<Arc<RuntimeSession>, String> {
    let Some(id) = arg_str(args, "session_id") else {
        return Err(json_error("session_id is required"));
    };
    manager()
        .session(id)
        .ok_or_else(|| json_error(&format!("Session not found: {id}")))
}

/// `args["env"] as? [String: String]`: every value a string, else empty.
fn env_arg(args: &Map<String, Value>) -> std::collections::HashMap<String, String> {
    args.get("env")
        .and_then(Value::as_object)
        .and_then(|obj| {
            obj.iter()
                .map(|(k, v)| v.as_str().map(|v| (k.clone(), v.to_string())))
                .collect()
        })
        .unwrap_or_default()
}

/// `binaryExistsInPath` (`/usr/bin/which <name>`): an executable file of
/// that name in a `PATH` folder.
pub fn find_in_path(name: &str, path: Option<&std::ffi::OsStr>) -> Option<PathBuf> {
    std::env::split_paths(path?)
        .map(|dir| dir.join(name))
        .find(|p| is_executable(p))
}

fn is_executable(path: &Path) -> bool {
    let Ok(meta) = std::fs::metadata(path) else {
        return false;
    };
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        meta.is_file() && meta.permissions().mode() & 0o111 != 0
    }
    #[cfg(not(unix))]
    {
        meta.is_file()
    }
}

fn create_session(args: &Map<String, Value>, ctx: &ToolContext) -> String {
    let backend_name = arg_str(args, "backend").unwrap_or("claude").to_string();
    let directory = arg_str(args, "directory")
        .map(str::to_string)
        .unwrap_or_else(|| {
            std::env::current_dir()
                .map(|d| d.to_string_lossy().into_owned())
                .unwrap_or_else(|_| "/".into())
        });
    let model = arg_str(args, "model").map(str::to_string);
    let resume = arg_str(args, "resume_session_id").map(str::to_string);
    let mut env = env_arg(args);
    let backend_args = arg_str_list(args, "backend_args").unwrap_or_default();
    let initial_prompt = arg_str(args, "initial_prompt").map(str::to_string);
    let auto_approve = arg_bool(args, "auto_approve").unwrap_or(false);
    let attach = arg_str(args, "attach_tab_id").map(str::to_string);
    let purpose = clean_arg(args, "purpose");
    let parent_session_id = clean_arg(args, "parent_session_id");
    let parent_run_id = clean_arg(args, "parent_run_id");
    let parent = match parent_session_id.as_deref() {
        Some(id) => match manager().session(id) {
            Some(parent) => Some(parent),
            None => return json_error(&format!("Parent session not found: {id}")),
        },
        None => None,
    };
    let delegation_depth = crate::mcp::tools::arg_int(args, "delegation_depth")
        .map(|depth| depth.clamp(0, i64::from(u32::MAX)) as u32)
        .unwrap_or_else(|| {
            parent
                .as_ref()
                .map_or(0, |parent| parent.config.delegation_depth.saturating_add(1))
        });
    let policy = match args.get("policy") {
        Some(policy) => match serde_json::from_value::<
            chau7_next_core::runtime::delegated_task::DelegationPolicy,
        >(policy.clone())
        {
            Ok(policy) => policy,
            Err(error) => return json_error(&format!("Invalid delegation policy: {error}")),
        },
        None => Default::default(),
    };
    if let Some(error) = policy.validate_start(1, 0, delegation_depth) {
        return json_error(&error);
    }
    if let Some(parent) = &parent
        && let Some(error) = parent.config.policy.validate_child(delegation_depth)
    {
        return json_error(&error);
    }
    for (key, value) in [
        ("CHAU7_SESSION_PURPOSE", &purpose),
        ("CHAU7_PARENT_SESSION_ID", &parent_session_id),
        ("CHAU7_PARENT_RUN_ID", &parent_run_id),
    ] {
        if let Some(value) = value {
            env.insert(key.into(), value.clone());
        }
    }
    env.insert(
        "CHAU7_DELEGATION_DEPTH".into(),
        delegation_depth.to_string(),
    );
    env.insert(
        "CHAU7_ALLOW_CHILD_DELEGATION".into(),
        if policy.allow_child_delegation {
            "1"
        } else {
            "0"
        }
        .into(),
    );
    env.insert(
        "CHAU7_MAX_DELEGATION_DEPTH".into(),
        policy.max_delegation_depth.to_string(),
    );
    for (key, value) in [
        ("CHAU7_MAX_TURNS", policy.max_turns),
        ("CHAU7_MAX_DURATION_MS", policy.max_duration_ms),
    ] {
        if let Some(value) = value {
            env.insert(key.into(), value.to_string());
        }
    }
    for (key, value) in [
        ("CHAU7_ALLOW_NETWORK", policy.allow_network),
        ("CHAU7_ALLOW_FILE_WRITES", policy.allow_file_writes),
    ] {
        if let Some(value) = value {
            env.insert(key.into(), if value { "1" } else { "0" }.into());
        }
    }
    log::info!(
        "MCP runtime_session_create: backend={backend_name} model={} dir={directory} autoApprove={auto_approve} resume={} backendArgs={backend_args:?} hasInitialPrompt={} attachTab={}",
        model.as_deref().unwrap_or("(none)"),
        resume.as_deref().unwrap_or("(none)"),
        initial_prompt.is_some(),
        attach.as_deref().unwrap_or("(none)")
    );

    let Some(backend) = backend_named(&backend_name) else {
        log::warn!("MCP runtime_session_create: unknown backend '{backend_name}'");
        return json_error(&unknown_backend_message(&backend_name));
    };
    if let Some(model) = &model
        && let Some(err) = validate_model(model, &backend_name)
    {
        log::warn!("MCP runtime_session_create: model validation failed - {err}");
        return json_error(&err);
    }
    if attach.is_none()
        && let Some(binary) = binary_name(&backend_name)
        && find_in_path(binary, std::env::var_os("PATH").as_deref()).is_none()
    {
        let msg = missing_binary_message(&backend_name, binary);
        log::warn!("MCP runtime_session_create: {msg}");
        return json_error(&msg);
    }

    if let Some(parent) = &parent
        && let Err(error) = authorize_tab(&parent.tab_id, ctx)
    {
        return error;
    }
    if let Err(error) = connected(ctx) {
        return error;
    }

    let config = SessionConfig {
        directory: directory.clone(),
        provider: backend_name.clone(),
        model,
        resume_session_id: resume,
        environment: env,
        args: backend_args,
        auto_approve,
        purpose,
        parent_session_id,
        parent_run_id,
        delegation_depth,
        policy,
        task_metadata: string_map_arg(args, "task_metadata"),
        result_schema: args.get("result_schema").cloned(),
    };

    // As in Swift, an `attach_tab_id` that is not a UUID opens a new tab
    // (which is then adopted, without launching anything).
    let tab_id = match attach.as_deref().and_then(parse_tab_id) {
        Some(uuid) => {
            log::info!("MCP runtime_session_create: attaching to existing tab {uuid}");
            let tab = crate::workspace::mcp::uuid_string(uuid);
            if let Err(error) = authorize_tab(&tab, ctx) {
                return error;
            }
            tab
        }
        None => {
            let result = if ctx.is_internal() {
                tabs::create_tab(Some(directory.clone()), None, ctx)
            } else {
                let create = json!({"directory": directory}).as_object().unwrap().clone();
                crate::mcp::control::call("tab_create", &create, ctx.client_id, ctx)
                    .unwrap_or_else(|| json_error("Tab creation is unavailable"))
            };
            let created = serde_json::from_str::<Value>(&result)
                .ok()
                .and_then(|v| v.get("tab_id").and_then(Value::as_str).map(str::to_string))
                .filter(|id| parse_tab_id(id).is_some());
            match created {
                Some(id) => {
                    log::info!("MCP runtime_session_create: created tab {id}");
                    id
                }
                None => {
                    log::error!("MCP runtime_session_create: failed to create tab - {result}");
                    return json_error(&format!("Failed to create tab: {result}"));
                }
            }
        }
    };

    let launch = backend.launch_command(&config);
    let session_tab = tab_id.clone();
    let adopting = attach.is_some();
    let session = match with_authorized_tab(&tab_id, ctx, move |_| {
        if adopting {
            manager().adopt_session_with_config(&session_tab, backend, config)
        } else {
            manager().create_session(&session_tab, backend, config, auto_approve)
        }
    }) {
        Ok(session) => session,
        Err(error) => return error,
    };
    if !launch.is_empty() && attach.is_none() {
        log::info!("MCP runtime_session_create: launching command: {launch}");
        if let Some(error) = delivery_error(&tabs::exec(&tab_id, &launch, ctx)) {
            let failed = session.clone();
            let _ = with_authorized_tab(&tab_id, ctx, move |_| manager().stop_session(&failed.id));
            sync_owned_tabs(ctx.main);
            return error;
        }
    }
    sync_owned_tabs(ctx.main);
    if let Some(prompt) = initial_prompt {
        schedule_initial_prompt(
            session.clone(),
            prompt,
            ctx.main.clone(),
            CallOrigin::capture(ctx),
        );
    }
    log::info!(
        "MCP runtime_session_create: session {} created (state={})",
        session.id,
        session.state().raw_value()
    );
    encode_sorted(&session.summary())
}

fn sync_owned_tabs(main: &MainThread) {
    let _ = main.call(super::sync_runtime_owned_tabs);
}

/// Keep the prompt pending until a real backend readiness transition; no fixed retry deadline.
fn schedule_initial_prompt(session: Arc<RuntimeSession>, prompt: String, main: MainThread, origin: CallOrigin) {
    session.queue_initial_prompt(prompt);
    let pending = session.clone();
    let spawned = std::thread::Builder::new()
        .name("chau7-next-runtime-prompt".into())
        .stack_size(512 * 1024)
        .spawn(move || {
            let ctx = origin.context(&main);
            match pending.wait_for_pending_initial_prompt_unless(|| connected(&ctx).is_err()) {
                Ok(Some(prompt)) => {
                    let result = send_turn_internal(&pending, &prompt, None, &ctx);
                    if result.contains("\"error\"") {
                        pending.record(
                            None,
                            "initial_prompt_failed",
                            [("reason".into(), "dispatch_failed".into())].into(),
                        );
                        pending.clear_pending_initial_prompt();
                        log::warn!(
                            "Pending runtime prompt dispatch failed for session {}",
                            pending.id
                        );
                    }
                }
                Err(state) => {
                    pending.record(
                        None,
                        "initial_prompt_failed",
                        [
                            ("reason".into(), "session_terminated".into()),
                            ("state".into(), state.raw_value().into()),
                        ]
                        .into(),
                    );
                }
                Ok(None) => (),
            }
        });
    if let Err(err) = spawned {
        session.clear_pending_initial_prompt();
        log::error!("MCP initial_prompt thread: {err}");
    }
}

fn stop_session(args: &Map<String, Value>, ctx: &ToolContext) -> String {
    let Some(id) = arg_str(args, "session_id") else {
        return json_error("session_id is required");
    };
    let close_tab = arg_bool(args, "close_tab").unwrap_or(false);
    let force = arg_bool(args, "force").unwrap_or(false);
    let Some(session) = manager().session(id) else {
        log::info!("MCP runtime_session_stop: session not found {id}");
        return json_error(&format!("Session not found: {id}"));
    };
    log::info!(
        "MCP runtime_session_stop: session={id} state={} force={force} closeTab={close_tab}",
        session.state().raw_value()
    );
    if let Err(error) = authorize_tab(&session.tab_id, ctx) {
        return error;
    }
    if (force || matches!(session.state(), State::Busy | State::AwaitingApproval))
        && let Some(error) = delivery_error(&tabs::send_input(&session.tab_id, "\u{3}", ctx))
    {
        return error;
    }
    let owned = session.clone();
    let result = with_authorized_tab(&session.tab_id, ctx, move |cx| {
        let stopped = manager().stop_session(&owned.id);
        let closed = close_tab.then(|| tabs::close_tab(&owned.tab_id, true, cx));
        (stopped, closed)
    });
    let (stopped, closed) = match result {
        Ok(result) => result,
        Err(error) => return error,
    };
    if let Some(error) = closed.as_deref().and_then(delivery_error) {
        return error;
    }
    sync_owned_tabs(ctx.main);
    encode_sorted(&json!({
        "ok": stopped,
        "session_id": id,
        "final_state": session.state().raw_value()
    }))
}

fn send_turn(args: &Map<String, Value>, ctx: &ToolContext) -> String {
    if arg_str(args, "session_id").is_none() {
        return json_error("session_id is required");
    }
    let Some(prompt) = arg_str(args, "prompt") else {
        return json_error("prompt is required");
    };
    let context = arg_str(args, "context");
    match session_arg(args) {
        Ok(session) => send_turn_with_schema(
            &session,
            prompt,
            context,
            args.get("result_schema").cloned(),
            ctx,
        ),
        Err(err) => err,
    }
}

fn send_turn_internal(
    session: &RuntimeSession,
    prompt: &str,
    context: Option<&str>,
    ctx: &ToolContext,
) -> String {
    send_turn_with_schema(session, prompt, context, None, ctx)
}

fn send_turn_with_schema(
    session: &RuntimeSession,
    prompt: &str,
    context: Option<&str>,
    schema: Option<Value>,
    ctx: &ToolContext,
) -> String {
    if let Err(error) = authorize_tab(&session.tab_id, ctx) {
        return error;
    }
    if let Some(error) = session.policy_error_for_next_turn() {
        session.record_policy_block("turn_submission", &error);
        return json_error(&error);
    }
    if session.state() == State::Starting {
        let tab = session.id.clone();
        let snapshot = ctx.main.call(move |cx| {
            manager()
                .session(&tab)
                .and_then(|session| super::launch_snapshot(&session, cx))
        });
        if let Some(Some((mut snapshot, pid))) = snapshot {
            snapshot.process_names = crate::platform::process::process_tree(pid)
                .into_iter()
                .filter_map(crate::platform::process::process_name)
                .collect();
            if session.backend.name() == "shell" && !snapshot.shell_loading && snapshot.is_at_prompt
                || chau7_next_core::runtime::launch_readiness::is_ready(
                    &snapshot,
                    session.backend.name(),
                    session.config.purpose.as_deref(),
                )
            {
                let id = session.id.clone();
                if let Err(error) =
                    with_authorized_tab(&session.tab_id, ctx, move |_| manager().mark_ready(&id))
                {
                    return error;
                }
            }
        }
    }
    if !session.can_accept_turn() {
        log::info!(
            "MCP runtime_turn_send: rejected for session {}, state={}",
            session.id,
            session.state().raw_value()
        );
        return json_error(&format!(
            "Session {} is not ready (state: {}). Wait for ready state.",
            session.id,
            session.state().raw_value()
        ));
    }
    let owned = match manager().session(&session.id) {
        Some(session) => session,
        None => return json_error("Session no longer exists"),
    };
    let submitted_prompt = prompt.to_string();
    let turn = match with_authorized_tab(&session.tab_id, ctx, move |_| {
        owned.start_turn_with_schema(&submitted_prompt, schema)
    }) {
        Ok(turn) => turn,
        Err(error) => return error,
    };
    let Some(turn_id) = turn else {
        log::error!(
            "MCP runtime_turn_send: startTurn failed for session {}",
            session.id
        );
        return json_error(&format!("Failed to start turn in session {}", session.id));
    };
    let input = session.backend.format_prompt_input(prompt, context);
    let result = tabs::send_input(&session.tab_id, &input, ctx);
    log::info!(
        "MCP runtime_turn_send: session={} turn={turn_id} inputLen={} sendResult={}",
        session.id,
        input.chars().count(),
        result.chars().take(100).collect::<String>()
    );
    if let Some(error) = delivery_error(&result) {
        session.fail_turn("send_input_failed");
        return error;
    }
    encode_sorted(&json!({
        "turn_id": turn_id,
        "status": "accepted",
        "session_state": session.state().raw_value(),
        "cursor": session.journal.latest_cursor()
    }))
}

fn turn_status(args: &Map<String, Value>) -> String {
    let session = match session_arg(args) {
        Ok(session) => session,
        Err(err) => return err,
    };
    let mut out = Map::new();
    out.insert("session_id".into(), json!(session.id));
    out.insert("state".into(), json!(session.state().raw_value()));
    out.insert("turn_count".into(), json!(session.turn_count()));
    if let Some(turn) = session.last_completed_turn_id() {
        out.insert("last_completed_turn_id".into(), json!(turn));
    }
    if let Some(result) = session.turn_result(arg_str(args, "turn_id")) {
        out.insert(
            if arg_str(args, "turn_id").is_some() {
                "turn_result"
            } else {
                "latest_turn_result"
            }
            .into(),
            json!(result),
        );
    }
    if let Some(turn) = session.current_turn_id() {
        out.insert("current_turn_id".into(), json!(turn));
    }
    if let Some(reason) = session.last_exit_reason() {
        out.insert("last_exit_reason".into(), json!(reason.raw_value()));
    }
    if let Some(approval) = session.pending_approval() {
        out.insert("pending_approval".into(), approval.json());
    }
    encode_sorted(&Value::Object(out))
}

fn clean_arg(args: &Map<String, Value>, key: &str) -> Option<String> {
    arg_str(args, key)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(str::to_string)
}
fn string_map_arg(
    args: &Map<String, Value>,
    key: &str,
) -> std::collections::HashMap<String, String> {
    args.get(key)
        .and_then(Value::as_object)
        .and_then(|object| {
            object
                .iter()
                .map(|(key, value)| value.as_str().map(|value| (key.clone(), value.to_string())))
                .collect()
        })
        .unwrap_or_default()
}
fn child_sessions(args: &Map<String, Value>) -> String {
    let Some(id) = arg_str(args, "session_id") else {
        return json_error("session_id is required");
    };
    let include = arg_bool(args, "include_stopped").unwrap_or(false);
    let sessions = if arg_bool(args, "recursive").unwrap_or(false) {
        manager().descendant_sessions(id, include)
    } else {
        manager().child_sessions(id, include)
    };
    encode_sorted(&json!(
        sessions
            .iter()
            .map(|session| session.summary())
            .collect::<Vec<_>>()
    ))
}
fn cancel_children(args: &Map<String, Value>, ctx: &ToolContext) -> String {
    let Some(id) = arg_str(args, "session_id") else {
        return json_error("session_id is required");
    };
    let parent = match session_arg(args) {
        Ok(session) => session,
        Err(error) => return error,
    };
    if let Err(error) = authorize_tab(&parent.tab_id, ctx) {
        return error;
    }
    let mut stopped = Vec::new();
    let mut failures = Vec::new();
    for session in manager().descendant_sessions(id, false) {
        let mut stop_args = Map::new();
        stop_args.insert("session_id".into(), json!(session.id));
        stop_args.insert(
            "close_tab".into(),
            json!(arg_bool(args, "close_tabs").unwrap_or(false)),
        );
        stop_args.insert(
            "force".into(),
            json!(arg_bool(args, "force").unwrap_or(false)),
        );
        let response = stop_session(&stop_args, ctx);
        if serde_json::from_str::<Value>(&response)
            .ok()
            .is_some_and(|value| value["ok"] == true)
        {
            stopped.push(session.id.clone());
        } else {
            failures.push(json!({"session_id":session.id,"response":serde_json::from_str::<Value>(&response).unwrap_or_else(|_| json!(response))}));
        }
    }
    encode_sorted(
        &json!({"ok":failures.is_empty(),"session_id":id,"count":stopped.len(),"stopped_session_ids":stopped,"failures":failures}),
    )
}
fn retry_session(args: &Map<String, Value>, ctx: &ToolContext) -> String {
    let session = match session_arg(args) {
        Ok(session) => session,
        Err(error) => return error,
    };
    if let Err(error) = authorize_tab(&session.tab_id, ctx) {
        return error;
    }
    let config = &session.config;
    let mut retry = json!({"backend":config.provider,"directory":config.directory,"env":config.environment,"backend_args":config.args,
        "auto_approve":config.auto_approve,"delegation_depth":config.delegation_depth,"policy":config.policy.summary(),"task_metadata":config.task_metadata}).as_object().unwrap().clone();
    for (key, value) in [
        ("model", &config.model),
        ("resume_session_id", &config.resume_session_id),
        ("purpose", &config.purpose),
        ("parent_session_id", &config.parent_session_id),
        ("parent_run_id", &config.parent_run_id),
    ] {
        if let Some(value) = value {
            retry.insert(key.into(), json!(value));
        }
    }
    if let Some(schema) = &config.result_schema {
        retry.insert("result_schema".into(), schema.clone());
    }
    if let Some(prompt) = clean_arg(args, "prompt").or_else(|| session.last_prompt()) {
        retry.insert("initial_prompt".into(), json!(prompt));
    }
    create_session(&retry, ctx)
}
fn turn_result(args: &Map<String, Value>, ctx: &ToolContext) -> String {
    let session = match session_arg(args) {
        Ok(session) => session,
        Err(error) => return error,
    };
    if let Some(result) = session.turn_result(arg_str(args, "turn_id")) {
        return encode_sorted(&json!(result));
    }
    if arg_str(args, "turn_id").is_none() {
        let tab_id = session.tab_id.clone();
        let source = ctx.main.call(move |cx| {
            let tab = crate::mcp::windows::find_tab(&tab_id, cx)?;
            let terminal = tab.window.workspace.read(cx).mcp_session(tab.tab, cx)?;
            let terminal = terminal.read(cx);
            Some((
                crate::telemetry::recorder(cx)?,
                terminal.tab_identifier.clone(),
                terminal.shell().ai_session_id().map(str::to_string),
            ))
        });
        if let Some(Some((recorder, tab, native_id))) = source {
            let filter = chau7_next_core::telemetry::run::TelemetryRunFilter {
                session_id: native_id,
                provider: Some(session.backend.name().into()),
                limit: Some(1000),
                ..Default::default()
            };
            if let Some(run) = recorder
                .store()
                .list_runs(&filter)
                .into_iter()
                .find(|run| run.tab_id.as_deref() == Some(&tab))
            {
                let turns = recorder.store().get_turns(&run.id);
                if let Some(content) = turns
                    .iter()
                    .rev()
                    .find(|turn| turn.role == chau7_next_core::telemetry::turn::TurnRole::Assistant)
                    .and_then(|turn| turn.content.as_deref())
                {
                    let turn = session
                        .last_completed_turn_id()
                        .unwrap_or_else(|| "telemetry_latest".into());
                    if let Some(result) = chau7_next_core::runtime::structured_result::capture(
                        &session.id,
                        &turn,
                        Some(content),
                        None,
                        session.config.result_schema.as_ref(),
                    ) {
                        return encode_sorted(&json!(result));
                    }
                }
            }
        }
    }
    json_error(&format!("Turn result not found for session {}", session.id))
}
fn wait_turn(args: &Map<String, Value>) -> String {
    let session = match session_arg(args) {
        Ok(session) => session,
        Err(error) => return error,
    };
    let requested = arg_str(args, "turn_id");
    let timeout = Duration::from_millis(
        crate::mcp::tools::arg_int(args, "timeout_ms")
            .unwrap_or(30000)
            .clamp(100, 3600000) as u64,
    );
    let started = std::time::Instant::now();
    loop {
        let settled = if let Some(turn) = requested {
            session.turn_result(Some(turn)).is_some()
                || session.last_completed_turn_id().as_deref() == Some(turn)
                || (session.state() != State::Starting
                    && session.current_turn_id().as_deref() != Some(turn)
                    && !matches!(session.state(), State::Busy | State::AwaitingApproval))
        } else {
            session.current_turn_id().is_none() && session.state() != State::Starting
        };
        let timed_out = started.elapsed() >= timeout;
        if settled || timed_out {
            let mut response =
                serde_json::from_str::<Value>(&turn_status(args)).unwrap_or_else(|_| json!({}));
            response["timed_out"] = json!(!settled);
            response["waited_ms"] = json!(started.elapsed().as_millis().min(timeout.as_millis()));
            return encode_sorted(&response);
        }
        std::thread::sleep(
            Duration::from_millis(200).min(timeout.saturating_sub(started.elapsed())),
        );
    }
}

/// `cursor` as a number (`NSNumber.uint64Value`; negative or missing is 0).
fn cursor_arg(args: &Map<String, Value>) -> u64 {
    match args.get("cursor") {
        Some(v) => v
            .as_u64()
            .or_else(|| v.as_f64().filter(|f| *f >= 0.0).map(|f| f as u64))
            .unwrap_or(0),
        None => 0,
    }
}

fn poll_events(args: &Map<String, Value>) -> String {
    let session = match session_arg(args) {
        Ok(session) => session,
        Err(err) => return err,
    };
    // Swift returns at least one event whatever the limit (its loop checks
    // the count after appending).
    let limit = crate::mcp::tools::arg_int(args, "limit")
        .unwrap_or(50)
        .max(1) as usize;
    let batch = session.journal.events(cursor_arg(args), limit);
    encode_sorted(&poll_response_json(
        &batch.events,
        batch.cursor,
        batch.has_more,
        session.state().raw_value(),
    ))
}

fn respond_to_approval(args: &Map<String, Value>, ctx: &ToolContext) -> String {
    if arg_str(args, "session_id").is_none() {
        return json_error("session_id is required");
    }
    let Some(approval_id) = arg_str(args, "approval_id") else {
        return json_error("approval_id is required");
    };
    let Some(approved) = arg_bool(args, "approved") else {
        return json_error("approved is required");
    };
    let reason = arg_str(args, "reason").unwrap_or("orchestrator");
    let session = match session_arg(args) {
        Ok(session) => session,
        Err(err) => return err,
    };
    if session.pending_approval().map(|a| a.id).as_deref() != Some(approval_id) {
        return json_error(&format!("No pending approval with id {approval_id}"));
    }
    if let Err(error) = authorize_tab(&session.tab_id, ctx) {
        return error;
    }
    if let Some(error) = delivery_error(&tabs::send_input(
        &session.tab_id,
        if approved { "y\n" } else { "n\n" },
        ctx,
    )) {
        return error;
    }
    let tab = session.tab_id.clone();
    let owned = session.clone();
    let approval_id = approval_id.to_string();
    let reason = reason.to_string();
    let resolved = with_authorized_tab(&session.tab_id, ctx, move |cx| {
        if !owned.resolve_approval(&approval_id, approved, &reason) {
            return false;
        }

        let Some(found) = crate::mcp::windows::find_tab(&tab, cx) else {
            return true;
        };
        found
            .window
            .workspace
            .update(cx, |ws, cx| ws.clear_persistent_style(found.tab, cx));
        true
    });
    match resolved {
        Ok(true) => encode_sorted(&json!({"ok": true, "approved": approved})),
        Ok(false) => json_error("Approval changed before the response was applied"),
        Err(error) => error,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn deferred_context_retains_private_origin_and_transport_identity() {
        let (tx, _rx) = futures::channel::mpsc::unbounded();
        let main = MainThread::for_tests(tx);
        let external = ToolContext::connection(&main, "runtime-origin-fixture");
        let origin = CallOrigin::capture(&external);
        let deferred = origin.context(&main);
        assert!(!deferred.is_internal());
        assert_eq!(deferred.client_id, external.client_id);
        assert!(connected(&deferred).is_err());
        let internal = CallOrigin::capture(&ToolContext::internal(&main));
        assert!(internal.context(&main).is_internal());
        assert!(connected(&internal.context(&main)).is_ok());
    }

    #[test]
    fn delivery_requires_explicit_terminal_confirmation() {
        assert!(delivery_error(r#"{"ok":true,"queued":true}"#).is_none());
        assert!(delivery_error(r#"{"ok":false}"#).is_some());
        assert!(delivery_error(r#"{"queued":false}"#).is_some());
        assert!(delivery_error("not-json").is_some());
        assert_eq!(
            delivery_error(r#"{"error":"denied"}"#).as_deref(),
            Some(r#"{"error":"denied"}"#)
        );
    }

    #[test]
    fn disconnected_runtime_client_cannot_mutate_or_attach_sessions() {
        let (tx, mut rx) = futures::channel::mpsc::unbounded();
        let main = MainThread::for_tests(tx);
        let ctx = ToolContext::connection(&main, "runtime-disconnected-fixture");
        let session = manager().adopt_session(
            "00000000-0000-0000-0000-00000000AABB",
            backend_named("shell").unwrap(),
            "/tmp",
        );
        let before = session.summary();
        for (name, args) in [
            (
                "runtime_turn_send",
                json!({"session_id":session.id,"prompt":"do not send"}),
            ),
            (
                "runtime_session_stop",
                json!({"session_id":session.id,"force":true,"close_tab":true}),
            ),
            ("runtime_session_retry", json!({"session_id":session.id})),
            (
                "runtime_session_cancel_children",
                json!({"session_id":session.id}),
            ),
            (
                "runtime_session_create",
                json!({"backend":"shell","attach_tab_id":session.tab_id}),
            ),
            (
                "runtime_session_create",
                json!({"backend":"shell","parent_session_id":session.id}),
            ),
        ] {
            let response: Value =
                serde_json::from_str(&handle_tool_call(name, args.as_object().unwrap(), &ctx))
                    .unwrap();
            assert_eq!(
                response["error"], "MCP client connection is closed",
                "{name}"
            );
            assert_eq!(session.summary(), before);
        }
        session.start_turn("fixture turn").unwrap();
        let approval = session
            .request_approval("fixture tool", "fixture approval")
            .unwrap();
        let pending = session.summary();
        let args = json!({"session_id":session.id,"approval_id":approval.id,"approved":true});
        let response: Value = serde_json::from_str(&handle_tool_call(
            "runtime_approval_respond",
            args.as_object().unwrap(),
            &ctx,
        ))
        .unwrap();
        assert_eq!(response["error"], "MCP client connection is closed");
        assert_eq!(session.summary(), pending);
        assert_eq!(session.pending_approval().unwrap().id, approval.id);
        // A denied caller never even queues work on the main thread.
        assert!(rx.try_recv().is_err());
        manager().stop_session(&session.id);
    }

    #[test]
    fn env_needs_string_values() {
        let args = json!({"env": {"A": "1", "B": "2"}});
        assert_eq!(env_arg(args.as_object().unwrap()).len(), 2);
        let bad = json!({"env": {"A": "1", "B": 2}});
        assert!(env_arg(bad.as_object().unwrap()).is_empty());
    }

    #[test]
    fn cursors_are_unsigned() {
        let args = |v: Value| json!({ "cursor": v }).as_object().unwrap().clone();
        assert_eq!(cursor_arg(&args(json!(7))), 7);
        assert_eq!(cursor_arg(&args(json!(7.0))), 7);
        assert_eq!(cursor_arg(&args(json!(-3))), 0);
        assert_eq!(cursor_arg(&Map::new()), 0);
    }

    #[cfg(unix)]
    #[test]
    fn path_lookup_needs_an_executable() {
        use std::os::unix::fs::PermissionsExt;
        let dir = std::env::temp_dir().join(format!("chau7-next-which-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let tool = dir.join("claude");
        std::fs::write(&tool, "#!/bin/sh\n").unwrap();
        let path = std::env::join_paths([Path::new("/nonexistent"), &dir]).unwrap();
        assert!(find_in_path("claude", Some(&path)).is_none());
        std::fs::set_permissions(&tool, std::fs::Permissions::from_mode(0o755)).unwrap();
        assert_eq!(find_in_path("claude", Some(&path)), Some(tool));
        assert!(find_in_path("codex", Some(&path)).is_none());
        assert!(find_in_path("claude", None).is_none());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn tools_validate_arguments_before_reaching_tabs() {
        let (tx, _rx) = futures::channel::mpsc::unbounded();
        let main = MainThread::for_tests(tx);
        let ctx = ToolContext::internal(&main);
        let call = |name: &str, args: Value| {
            let v: Value =
                serde_json::from_str(&handle_tool_call(name, args.as_object().unwrap(), &ctx))
                    .unwrap();
            v
        };
        assert_eq!(
            call("runtime_session_create", json!({"backend": "gemini"}))["error"],
            "Unknown backend: gemini. Valid: claude, codex, shell"
        );
        assert!(
            call(
                "runtime_session_create",
                json!({"backend": "codex", "model": "sonnet"})
            )["error"]
                .as_str()
                .unwrap()
                .contains("looks like a Claude model")
        );
        assert_eq!(
            call("runtime_session_get", json!({}))["error"],
            "session_id is required"
        );
        assert_eq!(
            call("runtime_session_get", json!({"session_id": "rs_nope"}))["error"],
            "Session not found: rs_nope"
        );
        assert_eq!(
            call("runtime_turn_send", json!({"session_id": "x"}))["error"],
            "prompt is required"
        );
        assert_eq!(
            call(
                "runtime_approval_respond",
                json!({"session_id": "x", "approval_id": "a"})
            )["error"],
            "approved is required"
        );
        assert_eq!(
            call("runtime_nope", json!({}))["error"],
            "Unknown runtime tool: runtime_nope"
        );

        // A session the registry knows (adopted, so nothing is launched).
        let session = manager().adopt_session(
            "00000000-0000-0000-0000-00000000AAAA",
            backend_named("shell").unwrap(),
            "/tmp",
        );
        let got = call("runtime_session_get", json!({"session_id": session.id}));
        assert_eq!(got["state"], "ready");
        let status = call("runtime_turn_status", json!({"session_id": session.id}));
        assert_eq!(status["turn_count"], 0);
        assert!(status.get("current_turn_id").is_none());
        let polled = call(
            "runtime_events_poll",
            json!({"session_id": session.id, "cursor": 0}),
        );
        assert_eq!(polled["session_state"], "ready");
        let types: Vec<_> = polled["events"]
            .as_array()
            .unwrap()
            .iter()
            .map(|e| e["type"].as_str().unwrap().to_string())
            .collect();
        assert_eq!(types, ["state_changed", "session_ready"]);
        assert_eq!(polled["cursor"], 2);
        assert_eq!(polled["has_more"], false);
        let limited = call(
            "runtime_events_poll",
            json!({"session_id": session.id, "cursor": 0, "limit": 1}),
        );
        assert_eq!(limited["cursor"], 1);
        assert_eq!(limited["has_more"], true);
        let wrong = call(
            "runtime_approval_respond",
            json!({"session_id": session.id, "approval_id": "a", "approved": true}),
        );
        assert_eq!(wrong["error"], "No pending approval with id a");
        let listed = call("runtime_session_list", json!({}));
        assert!(
            listed
                .as_array()
                .unwrap()
                .iter()
                .any(|s| s["session_id"] == session.id.as_str())
        );
        manager().stop_session(&session.id);
    }
}
