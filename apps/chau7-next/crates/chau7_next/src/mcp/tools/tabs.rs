//! Tab tools (`TerminalControlService.swift`): list, open, drive and read
//! tabs in every window. Tab state is read and changed on the main thread;
//! waits (stable output, CPU sampling) happen on the client thread.

use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use chau7_next_core::mcp::command_filter::{self, ResolvedPermissions};
use chau7_next_core::mcp::output::{
    MAX_STABLE_WAIT_MS, STABLE_POLL_INTERVAL, StabilityWait, clamp_lines, encode_sorted,
    fingerprint, format_buffer_output, format_pty_log_output, json_error, read_pty_log_tail,
};
use chau7_next_core::mcp_profile::MCPTabContext;
use chau7_next_core::shell_session::CommandStatus;
use chau7_next_core::terminal_key_press::TerminalKeyPress;
use chau7_next_core::token_optimization::{TabTokenOptOverride, TokenOptimizationMode};
use gpui::{AnyWindowHandle, App};
use serde_json::{Map, Value, json};

use super::{ToolContext, arg_bool, arg_int, arg_str, arg_str_list, tool};
use crate::mcp::approval;
use crate::mcp::windows::{McpTab, find_tab, parse_tab_id, windows};
use crate::pane::PaneTree;
use crate::settings::Settings;
use crate::workspace::AppData;
use crate::workspace::mcp::{CpuSamples, sample_processes, token_optimization_mode, uuid_string};

const NO_WINDOW: &str = "No active Chau7 window";

pub fn definitions() -> Vec<Value> {
    vec![
        tool(
            "tab_list",
            "List all open Chau7 tabs across all windows. Each tab includes a window_id field identifying which window it belongs to.",
            json!({"type": "object", "properties": {}}),
        ),
        tool(
            "tab_create",
            "Open a new terminal tab in Chau7. Returns the tab ID for subsequent operations.",
            json!({
                "type": "object",
                "properties": {
                    "directory": {"type": "string", "description": "Working directory for the new tab"},
                    "window_id": {"type": "integer", "description": "Target window (from tab_list). Defaults to window 0."}
                }
            }),
        ),
        tool(
            "tab_exec",
            "Execute a shell command in a tab. The tab must be at prompt (idle). Use tab_status to check first.",
            json!({
                "type": "object",
                "properties": {
                    "tab_id": {"type": "string", "description": "Tab UUID from tab_create or tab_list"},
                    "command": {"type": "string", "description": "Shell command to execute"}
                },
                "required": ["tab_id", "command"]
            }),
        ),
        tool(
            "tab_status",
            "Get detailed status of a tab: process state, working directory, active app, child processes, and active telemetry run",
            json!({
                "type": "object",
                "properties": {"tab_id": {"type": "string", "description": "Tab UUID"}},
                "required": ["tab_id"]
            }),
        ),
        tool(
            "tab_send_input",
            "Send raw input to a tab's terminal (for interactive prompts, confirmations, etc). Does NOT append newline - include \\n if needed.",
            json!({
                "type": "object",
                "properties": {
                    "tab_id": {"type": "string", "description": "Tab UUID"},
                    "input": {"type": "string", "description": "Raw text to send to the terminal"}
                },
                "required": ["tab_id", "input"]
            }),
        ),
        tool(
            "tab_press_key",
            "Send a terminal key press to a tab (for interactive TUIs like Claude Code). Use this for Enter, Escape, arrows, backspace, and control/alt key combos.",
            json!({
                "type": "object",
                "properties": {
                    "tab_id": {"type": "string", "description": "Tab UUID"},
                    "key": {
                        "type": "string",
                        "description": "Key name, e.g. enter, escape, tab, up, down, left, right, backspace, delete, home, end, page_up, page_down, insert, or a single character for ctrl/alt combos"
                    },
                    "modifiers": {
                        "type": "array",
                        "items": {"type": "string"},
                        "description": "Optional modifiers: shift, control/ctrl, option/alt/meta"
                    }
                },
                "required": ["tab_id", "key"]
            }),
        ),
        tool(
            "tab_submit_prompt",
            "Submit the current interactive prompt in a tab by sending Enter as a key press.",
            json!({
                "type": "object",
                "properties": {"tab_id": {"type": "string", "description": "Tab UUID"}},
                "required": ["tab_id"]
            }),
        ),
        tool(
            "tab_close",
            "Close a tab. Fails if a process is running unless force=true.",
            json!({
                "type": "object",
                "properties": {
                    "tab_id": {"type": "string", "description": "Tab UUID"},
                    "force": {"type": "boolean", "description": "Close even if processes are running"}
                },
                "required": ["tab_id"]
            }),
        ),
        tool(
            "tab_output",
            "Get recent terminal output from a tab. By default reads the terminal scrollback buffer. Use source='pty_log' to get the full ANSI-stripped PTY output log - this captures everything including content from TUI alternate screens that is no longer in the scrollback.",
            json!({
                "type": "object",
                "properties": {
                    "tab_id": {"type": "string", "description": "Tab UUID"},
                    "lines": {"type": "integer", "description": "Number of lines to return (default 50, max 10000)"},
                    "wait_for_stable_ms": {"type": "integer", "description": "Wait until buffer content is stable for this many ms before returning (max 30000). Only applies to source='buffer'."},
                    "source": {
                        "type": "string",
                        "description": "Data source: 'buffer' (default, terminal scrollback) or 'pty_log' (ANSI-stripped raw PTY output - captures full AI session including alternate screen content)"
                    }
                },
                "required": ["tab_id"]
            }),
        ),
        tool(
            "tab_set_cto",
            "Set the CTO (Command Token Optimization) override for a tab. 'default' follows the global mode, 'forceOn' always active, 'forceOff' always inactive.",
            json!({
                "type": "object",
                "properties": {
                    "tab_id": {"type": "string", "description": "Tab UUID"},
                    "override": {"type": "string", "description": "Override value: 'default', 'forceOn', or 'forceOff'"}
                },
                "required": ["tab_id", "override"]
            }),
        ),
        tool(
            "tab_rename",
            "Set a custom title for a tab. Pass an empty string to clear the custom title.",
            json!({
                "type": "object",
                "properties": {
                    "tab_id": {"type": "string", "description": "Tab UUID"},
                    "title": {"type": "string", "description": "New custom title for the tab. Empty string clears it."}
                },
                "required": ["tab_id", "title"]
            }),
        ),
    ]
}

pub fn call(name: &str, args: &Map<String, Value>, ctx: &ToolContext) -> Option<String> {
    let tab_id = arg_str(args, "tab_id").map(str::to_string);
    let main = ctx.main;
    let owner = (!ctx.is_internal()).then(|| ctx.client_id.to_string());
    Some(match name {
        "tab_list" => read_main(ctx, list_tabs).unwrap_or_else(|error| error),
        "tab_create" => create_tab(
            arg_str(args, "directory").map(str::to_string),
            arg_int(args, "window_id"),
            ctx,
        ),
        "tab_exec" => match (tab_id, arg_str(args, "command")) {
            (Some(tab_id), Some(command)) => exec(&tab_id, command, ctx),
            _ => json_error("tab_id and command are required"),
        },
        "tab_status" => match tab_id {
            Some(tab_id) => status(&tab_id, ctx),
            None => json_error("tab_id is required"),
        },
        "tab_send_input" => match (tab_id, arg_str(args, "input")) {
            (Some(tab_id), Some(input)) => send_input(&tab_id, input, ctx),
            _ => json_error("tab_id and input are required"),
        },
        "tab_press_key" => match (tab_id, arg_str(args, "key")) {
            (Some(tab_id), Some(key)) => {
                let modifiers = arg_str_list(args, "modifiers").unwrap_or_default();
                press_key(&tab_id, key, &modifiers, ctx)
            }
            _ => json_error("tab_id and key are required"),
        },
        "tab_submit_prompt" => match tab_id {
            Some(tab_id) => press_key(&tab_id, "enter", &[], ctx),
            None => json_error("tab_id is required"),
        },
        "tab_close" => match tab_id {
            Some(tab_id) => {
                let force = arg_bool(args, "force").unwrap_or(false);
                main.call(move |cx| {
                    if let Err(error) = authorize(&tab_id, owner.as_deref(), cx) {
                        return error;
                    }
                    close_tab(&tab_id, force, cx)
                })
                .unwrap_or_else(no_window)
            }
            None => json_error("tab_id is required"),
        },
        "tab_output" => match tab_id {
            Some(tab_id) => output(
                &tab_id,
                clamp_lines(arg_int(args, "lines")),
                arg_int(args, "wait_for_stable_ms"),
                arg_str(args, "source"),
                ctx,
            ),
            None => json_error("tab_id is required"),
        },
        "tab_set_cto" => match (tab_id, arg_str(args, "override")) {
            (Some(tab_id), Some(value)) => {
                let value = value.to_string();
                main.call(move |cx| {
                    if let Err(error) = authorize(&tab_id, owner.as_deref(), cx) {
                        return error;
                    }
                    set_cto(&tab_id, &value, cx)
                })
                .unwrap_or_else(no_window)
            }
            _ => json_error("tab_id and override are required"),
        },
        "tab_rename" => match (tab_id, arg_str(args, "title")) {
            (Some(tab_id), Some(title)) => {
                let title = title.to_string();
                main.call(move |cx| {
                    if let Err(error) = authorize(&tab_id, owner.as_deref(), cx) {
                        return error;
                    }
                    rename(&tab_id, &title, cx)
                })
                .unwrap_or_else(no_window)
            }
            _ => json_error("tab_id and title are required"),
        },
        _ => return None,
    })
}

pub(crate) fn no_window() -> String {
    json_error(NO_WINDOW)
}

/// A read-only main-thread lookup, bounded like the observer tools: a busy UI
/// answers `main_thread_unresponsive` instead of holding the client until its
/// own timeout (#230).
fn read_main<T: Send + 'static>(
    ctx: &ToolContext,
    f: impl FnOnce(&mut App) -> T + Send + 'static,
) -> Result<T, String> {
    ctx.main
        .read(f)
        .map_err(|error| encode_sorted(&error.payload()))
}

fn not_found(tab_id: &str) -> String {
    json_error(&format!("Tab not found: {tab_id}"))
}

fn list_tabs(cx: &mut App) -> String {
    let windows = windows(cx);
    if windows.is_empty() {
        return no_window();
    }
    let mut tabs = Vec::new();
    for window in windows {
        let ws = window.workspace.read(cx);
        for uuid in ws.mcp_tab_uuids() {
            let Some(id) = ws.mcp_find(uuid) else {
                continue;
            };
            let mut summary = ws.mcp_summary(id, cx);
            summary.insert("window_id".into(), json!(window.id));
            tabs.push(Value::Object(summary));
        }
    }
    encode_sorted(&Value::Array(tabs))
}

/// What `tab_create` checks before asking or creating.
#[derive(Debug, PartialEq, Eq)]
struct CreationRules {
    enabled: bool,
    limit: Option<usize>,
    ask: bool,
}
fn creation_rules(settings: &crate::settings::mcp::McpSettings, internal: bool) -> CreationRules {
    CreationRules {
        enabled: internal || settings.enabled,
        limit: (!internal).then(|| settings.tab_limit()),
        ask: !internal && settings.requires_approval,
    }
}

enum CreatePlan {
    Error(String),
    Ready {
        handle: AnyWindowHandle,
        window_id: usize,
        ask: bool,
    },
}

pub(crate) fn create_tab(
    directory: Option<String>,
    window_id: Option<i64>,
    ctx: &ToolContext,
) -> String {
    let internal = ctx.is_internal();
    let plan = ctx.main.call(move |cx| {
        let rules = creation_rules(&Settings::get(cx).mcp, internal);
        if !rules.enabled {
            return CreatePlan::Error(json_error("MCP is disabled in settings."));
        }
        let ask = rules.ask;
        let windows = windows(cx);
        if windows.is_empty() {
            return CreatePlan::Error(no_window());
        }
        let window = match window_id {
            Some(wid) => match windows.iter().find(|w| w.id as i64 == wid) {
                Some(w) => w.clone(),
                None => {
                    let valid: Vec<String> = windows.iter().map(|w| w.id.to_string()).collect();
                    return CreatePlan::Error(json_error(&format!(
                        "Invalid window_id: {wid}. Valid IDs: {}",
                        valid.join(", ")
                    )));
                }
            },
            None => {
                if internal {
                    windows
                        .iter()
                        .find(|window| Some(window.handle) == cx.active_window())
                        .unwrap_or(&windows[0])
                        .clone()
                } else {
                    windows[0].clone()
                }
            }
        };
        if let Some(limit) = rules.limit
            && window.workspace.read(cx).mcp_tab_count() >= limit
        {
            return CreatePlan::Error(json_error(&format!(
                "MCP tab limit reached ({limit}). Close existing MCP tabs first."
            )));
        }
        CreatePlan::Ready {
            handle: window.handle,
            window_id: window.id,
            ask,
        }
    });
    let (handle, window_id) = match plan {
        None => return no_window(),
        Some(CreatePlan::Error(err)) => return err,
        Some(CreatePlan::Ready {
            handle,
            window_id,
            ask,
        }) => {
            if ask && !approval::request_tab_approval(ctx.main, handle, directory.as_deref()) {
                return json_error("Tab creation denied by user.");
            }
            (handle, window_id)
        }
    };
    if let Some(dir) = &directory
        && !Path::new(dir).is_dir()
    {
        return json_error(&format!("Directory does not exist: {dir}"));
    }
    let owner = (!ctx.is_internal()).then(|| ctx.client_id.to_string());
    ctx.main
        .call(move |cx| {
            let rules = creation_rules(&Settings::get(cx).mcp, internal);
            if !rules.enabled {
                return Some(json_error("MCP is disabled in settings."));
            }
            if owner
                .as_deref()
                .is_some_and(|owner| !crate::mcp::control::is_connected(owner))
            {
                return Some(json_error("MCP connection is closed"));
            }
            let workspace = windows(cx)
                .into_iter()
                .find(|w| w.handle == handle)
                .map(|w| w.workspace)?;
            if let Some(limit) = rules.limit
                && workspace.read(cx).mcp_tab_count() >= limit
            {
                return Some(json_error(&format!(
                    "MCP tab limit reached ({limit}). Close existing MCP tabs first."
                )));
            }
            let uuid = handle
                .update(cx, |_, window, cx| {
                    workspace.update(cx, |ws, cx| {
                        if internal {
                            ws.runtime_create_tab(directory.clone().map(PathBuf::from), window, cx)
                        } else {
                            ws.mcp_create_tab(directory.clone().map(PathBuf::from), window, cx)
                        }
                    })
                })
                .ok()
                .flatten()?;
            let ws = workspace.read(cx);
            let loading = ws
                .mcp_find(uuid)
                .and_then(|id| ws.mcp_session(id, cx))
                .is_none_or(|s| s.read(cx).is_loading());
            log::info!(
                "MCP: tab created {} dir={}",
                uuid_string(uuid),
                directory.as_deref().unwrap_or("(inherited)")
            );
            Some(encode_sorted(&json!({
                "tab_id": uuid_string(uuid),
                "window_id": window_id,
                "status": "created",
                "shell_loading": loading
            })))
        })
        .flatten()
        .unwrap_or_else(|| json_error("Tab creation failed"))
}

/// `gatherTabContext` plus the rules that apply to it and the tab's window.
fn permissions_for(
    tab_id: &str,
    ctx: &ToolContext,
) -> Option<(
    ResolvedPermissions,
    Option<AnyWindowHandle>,
    Option<crate::tab_bar::TabId>,
)> {
    let tab_id = tab_id.to_string();
    ctx.main.call(move |cx| {
        let (global, profiles) = approval::permission_settings(cx);
        let home = cx
            .global::<AppData>()
            .root
            .home()
            .to_string_lossy()
            .into_owned();
        let tab = find_tab(&tab_id, cx);
        let context = tab.as_ref().and_then(|t| tab_context(t, cx));
        let resolved =
            command_filter::resolve_permissions(&global, &profiles, context.as_ref(), Some(&home));
        let (window, target_tab) = tab
            .map(|t| (Some(t.window.handle), Some(t.tab)))
            .unwrap_or((None, None));
        (resolved, window, target_tab)
    })
}

fn tab_context(tab: &McpTab, cx: &App) -> Option<MCPTabContext> {
    let session = tab.window.workspace.read(cx).mcp_session(tab.tab, cx)?;
    let s = session.read(cx);
    let processes = crate::monitoring::process_tree::observed_names(s.shell_pid() as u32, cx);
    Some(MCPTabContext {
        directory: s.cwd.as_ref().map(|p| p.to_string_lossy().into_owned()),
        git_branch: s.git_branch.clone(),
        ssh_host: None,
        processes: Some(processes),
        environment: None,
    })
}

/// Write text to the tab's focused pane, as typed.
fn send_to_tab(tab: &McpTab, bytes: &[u8], cx: &mut App) -> bool {
    let Some(panes) = tab.window.workspace.read(cx).mcp_panes(tab.tab) else {
        return false;
    };
    PaneTree::send_input(&panes, bytes, cx)
}

fn input_held() -> String {
    encode_sorted(
        &json!({"ok": false, "delivered": false, "error": "Input not delivered: terminal unavailable or command approval pending/blocked"}),
    )
}

fn authorize(tab_id: &str, owner: Option<&str>, cx: &mut App) -> Result<(), String> {
    match owner {
        Some(owner) => crate::mcp::control::authorize_mutation_on_main(tab_id, owner, cx),
        None => Ok(()),
    }
}
fn preflight(tab_id: &str, ctx: &ToolContext) -> Result<(), String> {
    if ctx.is_internal() {
        return Ok(());
    }
    let tab = tab_id.to_string();
    let owner = ctx.client_id.to_string();
    ctx.main
        .call(move |cx| authorize(&tab, Some(&owner), cx))
        .unwrap_or_else(|| Err(no_window()))
}

pub(crate) fn exec(tab_id: &str, command: &str, ctx: &ToolContext) -> String {
    if let Err(error) = preflight(tab_id, ctx) {
        return error;
    }
    let owner = (!ctx.is_internal()).then(|| ctx.client_id.to_string());
    let Some((permissions, window, target_tab)) = permissions_for(tab_id, ctx) else {
        return no_window();
    };
    let check = command_filter::check(command, &permissions);
    if let Some(err) = approval::enforce(
        ctx.main,
        check,
        &permissions,
        command,
        window,
        tab_id,
        target_tab,
    ) {
        return err;
    }
    let tab_id = tab_id.to_string();
    let command = command.to_string();
    ctx.main
        .call(move |cx| {
            if let Err(error) = authorize(&tab_id, owner.as_deref(), cx) { return error; }
            let Some(tab) = find_tab(&tab_id, cx) else {
                return not_found(&tab_id);
            };
            let Some(session) = tab.window.workspace.read(cx).mcp_session(tab.tab, cx) else {
                return not_found(&tab_id);
            };
            let (loading, at_prompt) = {
                let s = session.read(cx);
                (s.is_loading(), s.is_at_prompt())
            };
            let preview: String = command.chars().take(80).collect();
            if loading {
                // The shell reads it once started (`sendOrQueueInput`).
                if !send_to_tab(&tab, format!("{command}\n").as_bytes(), cx) {
                    return input_held();
                }
                log::info!("MCP: queued exec in {tab_id}: {preview}");
                return encode_sorted(&json!({"ok": true, "queued": true}));
            }
            if !at_prompt {
                return json_error(
                    "Tab is not at prompt (status: not at prompt). Wait for the current process to finish or use tab_send_input for interactive input.",
                );
            }
            if !send_to_tab(&tab, format!("{command}\n").as_bytes(), cx) {
                return input_held();
            }
            log::info!("MCP: exec in {tab_id}: {preview}");
            encode_sorted(&json!({"ok": true, "queued": false}))
        })
        .unwrap_or_else(no_window)
}

pub(crate) fn send_input(tab_id: &str, input: &str, ctx: &ToolContext) -> String {
    if let Err(error) = preflight(tab_id, ctx) {
        return error;
    }
    let owner = (!ctx.is_internal()).then(|| ctx.client_id.to_string());
    let Some((permissions, window, target_tab)) = permissions_for(tab_id, ctx) else {
        return no_window();
    };
    let check = command_filter::check_raw_input(input, &permissions);
    if let Some(err) = approval::enforce(
        ctx.main,
        check,
        &permissions,
        input,
        window,
        tab_id,
        target_tab,
    ) {
        return err;
    }
    let tab_id = tab_id.to_string();
    let input = input.to_string();
    ctx.main
        .call(move |cx| {
            if let Err(error) = authorize(&tab_id, owner.as_deref(), cx) {
                return error;
            }
            let Some(tab) = find_tab(&tab_id, cx) else {
                return not_found(&tab_id);
            };
            if !send_to_tab(&tab, input.as_bytes(), cx) {
                return input_held();
            }
            log::info!(
                "MCP: send_input to {tab_id} ({} chars)",
                input.chars().count()
            );
            encode_sorted(&json!({"ok": true}))
        })
        .unwrap_or_else(no_window)
}

fn press_key(tab_id: &str, key: &str, modifiers: &[String], ctx: &ToolContext) -> String {
    let owner = (!ctx.is_internal()).then(|| ctx.client_id.to_string());
    let modifiers: Vec<&str> = modifiers.iter().map(String::as_str).collect();
    let press = match TerminalKeyPress::new(key, &modifiers) {
        Ok(press) => press,
        Err(err) => return json_error(&err.to_string()),
    };
    if let Err(err) = press.encode(false) {
        return json_error(&err.to_string());
    }
    let tab_id = tab_id.to_string();
    ctx.main
        .call(move |cx| {
            if let Err(error) = authorize(&tab_id, owner.as_deref(), cx) {
                return error;
            }
            let Some(tab) = find_tab(&tab_id, cx) else {
                return not_found(&tab_id);
            };
            let Some(panes) = tab.window.workspace.read(cx).mcp_panes(tab.tab) else {
                return not_found(&tab_id);
            };
            if !PaneTree::send_key_press(&panes, &press, cx) {
                return json_error("Key not delivered: unsupported key, unavailable terminal, or pending/blocked command approval");
            }
            log::info!(
                "MCP: press_key in {tab_id}: key={} modifiers={}",
                press.key,
                press.sorted_modifier_names().join("+")
            );
            encode_sorted(&json!({"ok": true}))
        })
        .unwrap_or_else(no_window)
}

pub(super) fn add_deferred_status_fields(summary: &mut Map<String, Value>) {
    summary.insert("restore_state".into(), json!("deferred"));
    summary.insert("shell_loading".into(), true.into());
    summary.insert("processes".into(), Value::Array(Vec::new()));
}

pub(crate) fn status(tab_id: &str, ctx: &ToolContext) -> String {
    let id = tab_id.to_string();
    let found = read_main(ctx, move |cx| {
        let tab = find_tab(&id, cx)?;
        let ws = tab.window.workspace.read(cx);
        let mut summary = ws.mcp_summary(tab.tab, cx);
        let Some(session) = ws.mcp_session(tab.tab, cx) else {
            ws.mcp_deferred_saved(tab.tab, cx)?;
            add_deferred_status_fields(&mut summary);
            return Some((summary, None));
        };
        let s = session.read(cx);
        summary.insert("shell_loading".into(), json!(s.is_loading()));
        let pid = if s.exited.is_some() {
            0
        } else {
            s.shell_pid() as u32
        };
        Some((summary, Some((pid, s.tab_identifier.clone()))))
    });
    let found = match found {
        Ok(found) => found,
        Err(error) => return error,
    };
    let Some((mut summary, live)) = found else {
        return not_found(tab_id);
    };
    if let Some((shell_pid, telemetry_key)) = live {
        // `ProcessResourceMonitor`: the shell's descendants by CPU, sampled
        // twice for the CPU percentage.
        let mut samples = CpuSamples::new();
        sample_processes(shell_pid, &mut samples);
        std::thread::sleep(Duration::from_millis(250));
        let snapshot = sample_processes(shell_pid, &mut samples);
        let processes: Vec<Value> = snapshot
            .children
            .iter()
            .map(|p| {
                json!({
                    "pid": p.pid,
                    "name": p.name,
                    "cpu_percent": p.cpu_percent,
                    "rss_bytes": p.rss_bytes
                })
            })
            .collect();
        summary.insert("processes".into(), Value::Array(processes));
        // Runs are keyed by the terminal's `tabIdentifier`, as in Swift.
        if let Some(run) = crate::mcp::sources::telemetry().active_run_for_tab(&telemetry_key) {
            let elapsed = (chrono::Utc::now() - run.started_at).num_milliseconds();
            summary.insert(
                "active_run".into(),
                json!({
                    "run_id": run.id,
                    "provider": run.provider,
                    "started_at": run.started_at.to_rfc3339_opts(chrono::SecondsFormat::Secs, true),
                    "session_id": run.session_id,
                    "duration_so_far_ms": elapsed
                }),
            );
        }
    }
    encode_sorted(&Value::Object(summary))
}

fn close_requires_force(status: CommandStatus) -> bool {
    matches!(
        status,
        CommandStatus::Running
            | CommandStatus::WaitingForInput
            | CommandStatus::ApprovalRequired
            | CommandStatus::Stuck
    )
}

pub(crate) fn close_tab(tab_id: &str, force: bool, cx: &mut App) -> String {
    if parse_tab_id(tab_id).is_none() {
        return json_error(&format!("Invalid tab ID: {tab_id}"));
    }
    let Some(tab) = find_tab(tab_id, cx) else {
        return not_found(tab_id);
    };
    if !force {
        let status = tab
            .window
            .workspace
            .read(cx)
            .mcp_session(tab.tab, cx)
            .map(|s| s.read(cx).status());
        if let Some(status) = status
            && close_requires_force(status)
        {
            return json_error(&format!(
                "Tab has a running process (status: {}). Use force=true to close anyway.",
                status.as_str()
            ));
        }
    }
    log::info!("MCP: closing tab {tab_id} force={force}");
    let workspace = tab.window.workspace.clone();
    let _ = tab.window.handle.update(cx, |_, window, cx| {
        workspace.update(cx, |ws, cx| ws.mcp_close_tab(tab.tab, window, cx))
    });
    encode_sorted(&json!({"ok": true}))
}

/// The tab's terminal text (scrollback and screen), or `None` when the tab
/// is gone.
fn buffer_text(tab_id: &str, cx: &mut App) -> Option<String> {
    let tab = find_tab(tab_id, cx)?;
    let ws = tab.window.workspace.read(cx);
    if let Some(session) = ws.mcp_session(tab.tab, cx) {
        return Some(session.read(cx).buffer_text());
    }
    ws.mcp_deferred_saved(tab.tab, cx).map(|_| String::new())
}

fn encode_buffer_output(tab_id: &str, text: &str, lines: usize) -> String {
    let (output, count) = format_buffer_output(text, lines);
    encode_sorted(&json!({
        "tab_id": tab_id,
        "output": output,
        "lines": count,
        "source": "buffer"
    }))
}

fn output(
    tab_id: &str,
    lines: usize,
    wait_ms: Option<i64>,
    source: Option<&str>,
    ctx: &ToolContext,
) -> String {
    if source == Some("pty_log") {
        return pty_log_output(tab_id, lines, ctx);
    }
    if let Some(wait) = wait_ms.filter(|w| *w > 0) {
        let wait = wait.min(MAX_STABLE_WAIT_MS) as u64;
        let start = Instant::now();
        let deadline = start + Duration::from_millis(wait);
        let mut stability = StabilityWait::new(wait);
        while Instant::now() < deadline {
            let id = tab_id.to_string();
            let Ok(Some(fp)) =
                read_main(ctx, move |cx| buffer_text(&id, cx).map(|t| fingerprint(&t)))
            else {
                break;
            };
            if stability.observe(fp, start.elapsed().as_millis() as u64) {
                break;
            }
            std::thread::sleep(STABLE_POLL_INTERVAL);
        }
    }
    let id = tab_id.to_string();
    match read_main(ctx, move |cx| buffer_text(&id, cx)) {
        Err(error) => error,
        Ok(None) => not_found(tab_id),
        Ok(Some(text)) => encode_buffer_output(tab_id, &text, lines),
    }
}

/// `source=pty_log`: the cleaned tail of the tab's last AI PTY log.
#[derive(Debug, PartialEq, Eq)]
enum PtyLogLookup {
    MissingTerminal,
    NoLog,
    Path(PathBuf),
}

fn classify_pty_log_lookup(terminal_found: bool, path: Option<PathBuf>) -> PtyLogLookup {
    if !terminal_found {
        PtyLogLookup::MissingTerminal
    } else if let Some(path) = path {
        PtyLogLookup::Path(path)
    } else {
        PtyLogLookup::NoLog
    }
}

fn empty_pty_log_output(tab_id: &str) -> String {
    encode_sorted(&json!({
        "tab_id": tab_id, "output": "", "lines": 0, "source": "pty_log"
    }))
}

fn pty_log_output(tab_id: &str, lines: usize, ctx: &ToolContext) -> String {
    let id = tab_id.to_string();
    let lookup = read_main(ctx, move |cx| {
        let tab = find_tab(&id, cx);
        let (terminal_found, path) = tab.as_ref().map_or((false, None), |tab| {
            let ws = tab.window.workspace.read(cx);
            if let Some(session) = ws.mcp_session(tab.tab, cx) {
                let path = session
                    .read(cx)
                    .last_ai_log_path()
                    .map(|path| path.to_path_buf());
                (true, path)
            } else {
                (ws.mcp_deferred_saved(tab.tab, cx).is_some(), None)
            }
        });
        classify_pty_log_lookup(terminal_found, path)
    });
    let lookup = match lookup {
        Err(error) => return error,
        Ok(lookup) => lookup,
    };
    let path = match lookup {
        PtyLogLookup::MissingTerminal => return not_found(tab_id),
        PtyLogLookup::NoLog => return empty_pty_log_output(tab_id),
        PtyLogLookup::Path(path) => path,
    };
    let Some(text) = read_pty_log_tail(&path) else {
        return empty_pty_log_output(tab_id);
    };
    let (output, count) = format_pty_log_output(&text, lines);
    encode_sorted(&json!({
        "tab_id": tab_id,
        "output": output,
        "lines": count,
        "source": "pty_log"
    }))
}

fn set_cto(tab_id: &str, value: &str, cx: &mut App) -> String {
    let Some(value) = TabTokenOptOverride::ALL
        .into_iter()
        .find(|o| o.raw_value() == value)
    else {
        let valid: Vec<&str> = TabTokenOptOverride::ALL
            .iter()
            .map(|o| o.raw_value())
            .collect();
        return json_error(&format!(
            "Invalid override value: {value}. Valid values: {}",
            valid.join(", ")
        ));
    };
    if parse_tab_id(tab_id).is_none() {
        return json_error(&format!("Invalid tab ID: {tab_id}"));
    }
    let Some(tab) = find_tab(tab_id, cx) else {
        return not_found(tab_id);
    };
    if token_optimization_mode(cx) == TokenOptimizationMode::Off {
        return json_error(
            "Token optimization is globally disabled (mode=off). Enable it in settings first.",
        );
    }
    let result = tab
        .window
        .workspace
        .update(cx, |ws, cx| ws.mcp_set_cto(tab.tab, value, cx));
    let Some((active, value)) = result else {
        return not_found(tab_id);
    };
    log::info!("MCP: setCTO tab {tab_id} override={}", value.raw_value());
    encode_sorted(&json!({
        "ok": true,
        "cto_active": active,
        "cto_override": value.raw_value()
    }))
}

fn rename(tab_id: &str, title: &str, cx: &mut App) -> String {
    if parse_tab_id(tab_id).is_none() {
        return json_error(&format!("Invalid tab ID: {tab_id}"));
    }
    let Some(tab) = find_tab(tab_id, cx) else {
        return not_found(tab_id);
    };
    let title = tab
        .window
        .workspace
        .update(cx, |ws, cx| ws.mcp_rename(tab.tab, title, cx));
    encode_sorted(&json!({"ok": true, "title": title}))
}

#[cfg(test)]
mod creation_tests {
    use super::*;
    #[test]
    fn trusted_ui_creation_is_independent_of_external_mcp_settings() {
        let settings = crate::settings::mcp::McpSettings {
            enabled: false,
            requires_approval: true,
            max_tabs: 1,
            ..Default::default()
        };
        assert_eq!(
            creation_rules(&settings, true),
            CreationRules {
                enabled: true,
                limit: None,
                ask: false
            }
        );
        assert_eq!(
            creation_rules(&settings, false),
            CreationRules {
                enabled: false,
                limit: Some(1),
                ask: true
            }
        );
    }
    #[test]
    fn external_creation_keeps_limit_and_explicit_approval() {
        let settings = crate::settings::mcp::McpSettings {
            enabled: true,
            requires_approval: true,
            max_tabs: 50,
            ..Default::default()
        };
        assert_eq!(
            creation_rules(&settings, false),
            CreationRules {
                enabled: true,
                limit: Some(50),
                ask: true
            }
        );
    }
}

#[cfg(test)]
mod close_tests {
    use super::close_requires_force;
    use chau7_next_core::shell_session::CommandStatus::*;
    #[test]
    fn force_false_matches_current_swift_display_session_statuses() {
        for status in [Running, WaitingForInput, ApprovalRequired, Stuck] {
            assert!(close_requires_force(status));
        }
        for status in [Idle, Done, Exited] {
            assert!(!close_requires_force(status));
        }
    }
}

#[cfg(test)]
mod deferred_read_tests {
    use super::*;

    #[test]
    fn deferred_status_adds_loading_and_empty_process_projection() {
        let mut summary = json!({
            "tab_id": "parked-uuid",
            "cwd": "/tmp/project",
            "status": "unknown",
            "is_mcp_controlled": false,
            "restore_state": "active",
            "shell_loading": false,
            "processes": [{"pid": 12}]
        })
        .as_object()
        .unwrap()
        .clone();

        add_deferred_status_fields(&mut summary);

        assert_eq!(summary["tab_id"], "parked-uuid");
        assert_eq!(summary["cwd"], "/tmp/project");
        assert_eq!(summary["status"], "unknown");
        assert_eq!(summary["is_mcp_controlled"], false);
        assert_eq!(summary["restore_state"], "deferred");
        assert_eq!(summary["shell_loading"], true);
        assert_eq!(summary["processes"], json!([]));
        assert!(!summary.contains_key("active_run"));
    }

    #[test]
    fn deferred_buffer_output_is_successful_and_empty() {
        let encoded = encode_buffer_output("parked-uuid", "", 160);
        let response: Value = serde_json::from_str(&encoded).expect("valid JSON buffer response");

        assert_eq!(
            response,
            json!({
                "tab_id": "parked-uuid",
                "output": "",
                "lines": 0,
                "source": "buffer"
            })
        );
    }

    #[test]
    fn pty_log_lookup_keeps_missing_tabs_distinct_from_tabs_without_a_log() {
        assert_eq!(
            classify_pty_log_lookup(false, None),
            PtyLogLookup::MissingTerminal
        );
        let path = PathBuf::from("/tmp/pty.log");
        assert_eq!(
            classify_pty_log_lookup(false, Some(path.clone())),
            PtyLogLookup::MissingTerminal
        );
        assert_eq!(classify_pty_log_lookup(true, None), PtyLogLookup::NoLog);
        assert_eq!(
            classify_pty_log_lookup(true, Some(path.clone())),
            PtyLogLookup::Path(path)
        );

        let encoded = empty_pty_log_output("parked-uuid");
        let response: Value = serde_json::from_str(&encoded).expect("valid JSON PTY log response");
        assert_eq!(
            response,
            json!({
                "tab_id": "parked-uuid",
                "output": "",
                "lines": 0,
                "source": "pty_log"
            })
        );
    }
}

#[cfg(test)]
mod unresponsive_main_thread_tests {
    use super::*;
    use crate::mcp::MainThread;

    #[test]
    fn read_only_tab_tools_answer_when_the_main_thread_is_stuck() {
        // The receiver is kept alive and never drained: a busy UI thread.
        let (jobs, _queued) = futures::channel::mpsc::unbounded();
        let main = MainThread::for_tests(jobs);
        let ctx = ToolContext::internal(&main);
        let started = Instant::now();
        let mut args = Map::new();
        for name in ["tab_list", "tab_status", "tab_output"] {
            args.insert("tab_id".into(), json!("tab"));
            let reply = call(name, &args, &ctx).unwrap();
            assert!(
                reply.contains("main_thread_unresponsive"),
                "{name}: {reply}"
            );
        }
        assert!(started.elapsed() < Duration::from_secs(10));
    }
}
