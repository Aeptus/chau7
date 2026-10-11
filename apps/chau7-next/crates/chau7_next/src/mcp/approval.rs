//! Command permissions and the MCP dialogs (`TerminalControlService`:
//! `enforceVerdict`, `requestApproval`, `requestCommandApproval`).
//!
//! Dialogs are GPUI prompts (NSAlert on macOS) on the tab's window, one at a
//! time like Swift's modal alerts; the MCP client waits for the answer.
//! "Deny" is the first button, so Return denies.
//!
//! The Swift app also sends each command approval to the paired iPhone and
//! takes the first answer (MCP-045): the request goes out through
//! `crate::remote::send_approval_request` and the phone's answer comes back
//! through [`resolve_remote`] (wired in `crate::seams`). The command approval
//! is drawn in its own window (`approval_window.rs`) rather than a GPUI
//! prompt, so an iPhone answer closes it, as `NSApp.stopModal` does in Swift.

use std::collections::HashMap;
use std::sync::Mutex;

use chau7_next_core::mcp::command_filter::{CheckResult, CommandVerdict, ResolvedPermissions};
use chau7_next_core::mcp::output::json_error;
use chau7_next_core::mcp_profile::MCPApprovalResult;
use futures::FutureExt;
use futures::channel::oneshot;
use gpui::{AnyWindowHandle, App, PromptLevel};

use super::MainThread;
use crate::settings::Settings;

/// One dialog at a time (Swift `runModal` blocks the main thread).
static DIALOG: Mutex<()> = Mutex::new(());

/// Command approvals waiting for an answer from the iPhone, by request id.
static PENDING_REMOTE: Mutex<Option<HashMap<String, oneshot::Sender<MCPApprovalResult>>>> =
    Mutex::new(None);

/// An answer from the paired iPhone (`resolveApproval(requestID:approved:)`):
/// approve is "Allow Once", deny is "Deny".
pub fn resolve_remote(request_id: &str, approved: bool) {
    let sender = PENDING_REMOTE
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .as_mut()
        .and_then(|pending| pending.remove(request_id));
    if let Some(sender) = sender {
        let _ = sender.send(if approved {
            MCPApprovalResult::AllowedOnce
        } else {
            MCPApprovalResult::Denied
        });
    }
}

/// The window a dialog goes on: the given one if still open, else the
/// first window.
fn dialog_window(window: Option<AnyWindowHandle>, cx: &mut App) -> Option<AnyWindowHandle> {
    let windows = super::windows::windows(cx);
    window
        .filter(|w| windows.iter().any(|m| m.handle == *w))
        .or_else(|| windows.first().map(|m| m.handle))
}

/// Show a prompt and send the index of the chosen button (`None` when it
/// could not be shown).
fn prompt(
    cx: &mut App,
    window: Option<AnyWindowHandle>,
    level: PromptLevel,
    message: String,
    detail: String,
    buttons: &'static [&'static str],
) -> Option<oneshot::Receiver<usize>> {
    let handle = dialog_window(window, cx)?;
    handle
        .update(cx, |_, window, cx| {
            window.activate_window();
            crate::l10n::prompt(window, level, &message, Some(&detail), buttons, cx)
        })
        .ok()
}

/// `requestApproval`: "MCP Tab Request" with Allow and Deny.
pub fn request_tab_approval(
    main: &MainThread,
    window: AnyWindowHandle,
    directory: Option<&str>,
) -> bool {
    let _dialog = DIALOG.lock().unwrap_or_else(|e| e.into_inner());
    let detail = format!(
        "MCP client wants to create a new tab{}.",
        directory.map(|d| format!(" in {d}")).unwrap_or_default()
    );
    main.call_async(move |cx, reply| {
        let Some(answer) = prompt(
            cx,
            Some(window),
            PromptLevel::Info,
            "MCP Tab Request".into(),
            detail,
            &["Allow", "Deny"],
        ) else {
            let _ = reply.send(false);
            return;
        };
        cx.spawn(async move |_| {
            let _ = reply.send(answer.await.ok() == Some(0));
        })
        .detach();
    })
    .unwrap_or(false)
}

/// `requestCommandApproval`: Deny / Allow Once / Always Allow, with the
/// rule set that applied. The first answer (Mac or iPhone) wins.
pub fn request_command_approval(
    main: &MainThread,
    window: Option<AnyWindowHandle>,
    command: &str,
    flagged: &str,
    permissions: &ResolvedPermissions,
) -> MCPApprovalResult {
    let _dialog = DIALOG.lock().unwrap_or_else(|e| e.into_inner());
    let request_id = uuid::Uuid::new_v4().to_string().to_uppercase();
    let (remote_tx, remote_rx) = oneshot::channel();
    PENDING_REMOTE
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .get_or_insert_with(HashMap::new)
        .insert(request_id.clone(), remote_tx);
    let source_info = permissions.source_info();
    let detail = format!("An MCP client wants to execute:\n\n{command}\n\n{source_info}");
    let payload = crate::seams::approval_request(&request_id, command, flagged, &source_info);
    let result = main
        .call_async(move |cx, reply| {
            // The paired iPhone gets the same request (RMT-017).
            crate::remote::send_approval_request(payload, cx);
            let parent = dialog_window(window, cx);
            let Some(dialog) = super::approval_window::open(
                parent,
                "MCP Command Approval",
                &detail,
                &["Deny", "Allow Once", "Always Allow"],
                cx,
            ) else {
                let _ = reply.send(MCPApprovalResult::Denied);
                return;
            };
            let dialog_handle = dialog.window;
            let answer = dialog.answer;
            cx.spawn(async move |cx| {
                let local = answer.map(|a| match a.ok() {
                    Some(1) => MCPApprovalResult::AllowedOnce,
                    Some(2) => MCPApprovalResult::AlwaysAllow,
                    _ => MCPApprovalResult::Denied,
                });
                let remote = async move {
                    match remote_rx.await {
                        Ok(result) => result,
                        // No iPhone answer will come: the Mac answer decides.
                        Err(_) => futures::future::pending().await,
                    }
                };
                let result = match futures::future::select(local, Box::pin(remote)).await {
                    futures::future::Either::Left((r, _)) => r,
                    futures::future::Either::Right((r, _)) => {
                        // The iPhone answered first: the Mac dialog goes away.
                        cx.update(|cx| super::approval_window::close(dialog_handle, cx));
                        r
                    }
                };
                let _ = reply.send(result);
            })
            .detach();
        })
        .unwrap_or(MCPApprovalResult::Denied);
    PENDING_REMOTE
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .get_or_insert_with(HashMap::new)
        .remove(&request_id);
    result
}

/// `enforceVerdict`: `None` when the command may run, else the error to
/// return. "Always Allow" adds the command to the matched profile or the
/// global list. `context` names the tab in the log.
pub fn enforce(
    main: &MainThread,
    check: CheckResult,
    permissions: &ResolvedPermissions,
    full_input: &str,
    context: &str,
    window: Option<AnyWindowHandle>,
) -> Option<String> {
    for name in &check.audited {
        log::info!(
            "MCP audit: command '{name}' allowed under audit-only mode ({})",
            permissions.source_name()
        );
    }
    match check.verdict {
        CommandVerdict::Allowed => None,
        CommandVerdict::Blocked(cmd) => {
            log::info!("MCP: blocked '{cmd}' in {context}");
            Some(json_error(&format!(
                "Command '{cmd}' is blocked by MCP permissions."
            )))
        }
        CommandVerdict::NeedsApproval(cmd) => {
            match request_command_approval(main, window, full_input, &cmd, permissions) {
                MCPApprovalResult::Denied => {
                    log::info!("MCP: user denied '{cmd}' in {context}");
                    Some(json_error(&format!("Command '{cmd}' was denied by user.")))
                }
                MCPApprovalResult::AllowedOnce => {
                    log::info!("MCP: user allowed once '{cmd}' in {context}");
                    None
                }
                MCPApprovalResult::AlwaysAllow => {
                    log::info!(
                        "MCP: user always-allowed '{cmd}' in {context} ({})",
                        permissions.source_name()
                    );
                    let profile = permissions.profile_id();
                    main.call(move |cx| {
                        crate::settings_window::update(cx, |s| {
                            s.mcp.add_allowed_command(&cmd, profile)
                        })
                    });
                    None
                }
            }
        }
    }
}

/// The global rules and profiles, read on the main thread.
pub fn permission_settings(
    cx: &App,
) -> (
    ResolvedPermissions,
    Vec<chau7_next_core::mcp_profile::MCPProfile>,
) {
    let mcp = &Settings::get(cx).mcp;
    (mcp.global_permissions(), mcp.profiles.clone())
}
