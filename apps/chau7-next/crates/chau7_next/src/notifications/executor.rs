//! Runs notification actions (`NotificationActionExecutor.swift`). Each
//! action reports success or a note for the history. Commands (scripts,
//! Shortcuts, Docker, kubectl, git, webhooks through `curl`) run on
//! background threads and only log their outcome, like the Swift
//! `Process` and `URLSession` calls.

use std::collections::HashMap;
use std::io::Write as _;
use std::path::Path;
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

use chau7_next_core::ai::event::AiEvent;
use chau7_next_core::notifications::action_support::{
    self as support, ExecutionReport, LOG_TIME_HEADER,
};
use chau7_next_core::notifications::actions::{NotificationActionConfig, NotificationActionType};
use gpui::{App, BorrowAppContext, ClipboardItem};
use uuid::Uuid;

use super::{NotificationCenter, banner, flash, routing};
use crate::platform::{attention, sound, workspace as ns_workspace};
use crate::workspace::AppData;

/// Executor state: running timers and tab style auto-clears.
#[derive(Debug, Default)]
pub struct ExecutorState {
    pub timers: support::TimeTracker,
    /// Last preset applied per tab, to skip redundant re-applies.
    last_applied_preset: HashMap<Uuid, String>,
    /// Pending auto-clear per tab: its generation (a newer style cancels it).
    pending_clears: HashMap<Uuid, u64>,
    clear_generation: u64,
}

fn home(cx: &App) -> String {
    cx.global::<AppData>()
        .root
        .home()
        .to_string_lossy()
        .into_owned()
}

fn state(cx: &mut App) -> &mut ExecutorState {
    &mut cx.global_mut::<NotificationCenter>().executor
}

/// `execute(actions:for:)`: run every enabled action in order.
pub fn execute(
    actions: &[NotificationActionConfig],
    event: &AiEvent,
    cx: &mut App,
) -> ExecutionReport {
    let mut report = ExecutionReport::default();
    for action in actions.iter().filter(|a| a.enabled) {
        report.append(execute_action(action, event, cx));
    }
    report
}

fn execute_action(
    action: &NotificationActionConfig,
    event: &AiEvent,
    cx: &mut App,
) -> ExecutionReport {
    use NotificationActionType as T;
    match action.action_type {
        T::ShowNotification => show_notification(action, event, cx),
        T::PlaySound => play_sound(action),
        T::FocusWindow => focus_window(action, event, cx),
        T::DockBounce => dock_bounce(action),
        T::BadgeTab => badge_tab(action, event, cx),
        T::StyleTab => style_tab(action, event, cx),
        T::RunScript => run_script(action, event, cx),
        T::RunShortcut => run_shortcut(action, event),
        T::ExecuteSnippet => execute_snippet(action, event, cx),
        T::Webhook => webhook(action, event),
        T::SendSlack => send_chat(action, event, true),
        T::SendDiscord => send_chat(action, event, false),
        T::DockerBump => docker_bump(action),
        T::DockerCompose => docker_compose(action, cx),
        T::KubernetesRollout => kubernetes(action),
        T::CopyToClipboard => copy_to_clipboard(action, event, cx),
        T::WriteToFile => write_to_file(action, event, cx),
        T::OpenUrl => open_url(action, event, cx),
        T::GitCommit => git_commit(action, event, cx),
        T::VoiceAnnounce => voice_announce(action, event),
        T::FlashScreen => flash_screen(action, cx),
        T::MenuBarAlert => menu_bar_alert(action, cx),
        T::StartTimer => start_timer(action, event, cx),
        T::StopTimer => stop_timer(action, cx),
        T::LogTime => log_time(action, event, cx),
    }
}

fn value<'a>(action: &'a NotificationActionConfig, key: &str) -> Option<&'a str> {
    action.config_value(key)
}

fn non_empty<'a>(action: &'a NotificationActionConfig, key: &str) -> Option<&'a str> {
    value(action, key).filter(|v| !v.is_empty())
}

// MARK: - Basic

fn show_notification(
    action: &NotificationActionConfig,
    event: &AiEvent,
    cx: &mut App,
) -> ExecutionReport {
    let custom_title = support::interpolate(value(action, "customTitle"), event);
    let custom_body = support::interpolate(value(action, "customBody"), event);
    let title = if custom_title.is_empty() {
        event.notification_title()
    } else {
        custom_title
    };
    let body = if custom_body.is_empty() {
        event.notification_body()
    } else {
        custom_body
    };
    let dispatched = cx.update_global(|nc: &mut NotificationCenter, cx| {
        banner::dispatch(&mut nc.banner, &title, &body, cx)
    });
    if dispatched {
        ExecutionReport::success(NotificationActionType::ShowNotification)
    } else {
        ExecutionReport::failure("showNotification failed to dispatch")
    }
}

/// Plays a named system sound, a file, or `/System/Library/Sounds/<name>.aiff`;
/// the system beep for "default" or when nothing is found.
pub fn play_sound_named(name: &str, volume: f32) {
    if name == "default" {
        sound::beep();
        return;
    }
    if sound::play_named(name, volume).is_ok() {
        return;
    }
    if sound::play_file(Path::new(name), volume).is_ok() {
        return;
    }
    let system = format!("{}/{name}.aiff", sound::SYSTEM_SOUNDS_DIR);
    if sound::play_file(Path::new(&system), volume).is_err() {
        log::warn!("Action playSound: Sound not found: {name}");
        sound::beep();
    }
}

fn play_sound(action: &NotificationActionConfig) -> ExecutionReport {
    let name = value(action, "sound").unwrap_or("default");
    let volume = action.config_int("volume", 100) as f32 / 100.0;
    play_sound_named(name, volume);
    ExecutionReport::success(NotificationActionType::PlaySound)
}

fn focus_window(
    action: &NotificationActionConfig,
    event: &AiEvent,
    cx: &mut App,
) -> ExecutionReport {
    cx.activate(true);
    if !action.config_bool("focusTab", true) {
        return ExecutionReport::success(NotificationActionType::FocusWindow);
    }
    let Some(tab) = event.tab_id else {
        log::warn!(
            "Action focusWindow: Missing explicit tabID for event {}",
            event.id
        );
        return ExecutionReport::failure("focusWindow missing explicit tabID");
    };
    if routing::focus_tab(tab, cx) {
        log::info!("Action focusWindow: Focused tab {tab}");
        ExecutionReport::success(NotificationActionType::FocusWindow)
    } else {
        ExecutionReport::failure(format!(
            "focusWindow failed for explicit tabID {}",
            tab.hyphenated().to_string().to_uppercase()
        ))
    }
}

fn dock_bounce(action: &NotificationActionConfig) -> ExecutionReport {
    let critical = action.config_bool("critical", false);
    match attention::request_attention(critical) {
        Ok(_) => log::info!("Action dockBounce: Requested user attention (critical={critical})"),
        Err(err) => log::warn!("Action dockBounce: {err}"),
    }
    ExecutionReport::success(NotificationActionType::DockBounce)
}

fn badge_tab(action: &NotificationActionConfig, event: &AiEvent, cx: &mut App) -> ExecutionReport {
    let text = value(action, "badgeText").unwrap_or("!");
    let color = value(action, "badgeColor").unwrap_or("red");
    let Some(tab) = event.tab_id else {
        log::warn!(
            "Action badgeTab: Missing explicit tabID for event {}",
            event.id
        );
        return ExecutionReport::failure("badgeTab missing explicit tabID");
    };
    if routing::badge_tab(tab, text, color, cx) {
        ExecutionReport::success(NotificationActionType::BadgeTab)
    } else {
        ExecutionReport::failure(format!(
            "badgeTab failed for explicit tabID {}",
            tab.hyphenated().to_string().to_uppercase()
        ))
    }
}

fn style_tab(action: &NotificationActionConfig, event: &AiEvent, cx: &mut App) -> ExecutionReport {
    let preset = value(action, "style").unwrap_or("waiting").to_string();
    let auto_clear = action.config_int("autoClearSeconds", 0);
    let Some(tab) = event.tab_id else {
        log::warn!(
            "Action styleTab: Missing explicit tabID for event {}",
            event.id
        );
        return ExecutionReport::failure("styleTab missing explicit tabID");
    };
    // A style already applied with its auto-clear running is not re-applied
    // (re-notifications must not restart the countdown).
    {
        let st = state(cx);
        if preset != "clear"
            && st.last_applied_preset.get(&tab) == Some(&preset)
            && st.pending_clears.contains_key(&tab)
        {
            return ExecutionReport::success(NotificationActionType::StyleTab);
        }
    }
    let config: HashMap<String, String> = action
        .config
        .iter()
        .map(|(k, v)| (k.clone(), v.clone()))
        .collect();
    if !routing::style_tab(tab, &preset, &config, cx) {
        log::warn!(
            "Action styleTab: Explicit tabID not found across windows for event {}",
            event.id
        );
        return ExecutionReport::failure(format!(
            "styleTab failed for explicit tabID {}",
            tab.hyphenated().to_string().to_uppercase()
        ));
    }
    let generation = {
        let st = state(cx);
        if preset == "clear" {
            st.last_applied_preset.remove(&tab);
        } else {
            st.last_applied_preset.insert(tab, preset.clone());
        }
        st.pending_clears.remove(&tab);
        if auto_clear > 0 {
            st.clear_generation += 1;
            st.pending_clears.insert(tab, st.clear_generation);
            Some(st.clear_generation)
        } else {
            None
        }
    };
    if let Some(generation) = generation {
        cx.spawn(async move |cx| {
            cx.background_executor()
                .timer(Duration::from_secs(auto_clear as u64))
                .await;
            cx.update(|cx| {
                let st = state(cx);
                if st.pending_clears.get(&tab) != Some(&generation) {
                    return;
                }
                st.pending_clears.remove(&tab);
                st.last_applied_preset.remove(&tab);
                routing::style_tab(tab, "clear", &HashMap::new(), cx);
            });
        })
        .detach();
    }
    ExecutionReport::success(NotificationActionType::StyleTab)
}

// MARK: - Automation

/// Runs `program args` on a background thread and logs a failure.
fn run_in_background(label: String, mut command: Command) {
    std::thread::spawn(move || run_sync(&label, &mut command));
}

/// Runs a command to completion; false (logged) on a launch error or a
/// non-zero exit.
fn run_sync(label: &str, command: &mut Command) -> bool {
    match command.output() {
        Ok(out) if out.status.success() => true,
        Ok(out) => {
            let mut text = String::from_utf8_lossy(&out.stdout).into_owned();
            text.push_str(&String::from_utf8_lossy(&out.stderr));
            let text: String = text.chars().take(200).collect();
            log::warn!(
                "Action {label}: Exit code {}, output: {text}",
                out.status.code().unwrap_or(-1)
            );
            false
        }
        Err(err) => {
            log::error!("Action {label}: Failed: {err}");
            false
        }
    }
}

fn run_script(action: &NotificationActionConfig, event: &AiEvent, cx: &mut App) -> ExecutionReport {
    let Some(script) = non_empty(action, "script") else {
        log::warn!("Action runScript: No script provided");
        return ExecutionReport::failure("runScript missing script");
    };
    let shell = value(action, "shell").unwrap_or("/bin/zsh");
    let timeout = action.config_int("timeout", 30).max(0) as u64;
    let mut command = Command::new(shell);
    // The event reaches the script only through the environment.
    command.arg("-c").arg(script);
    for (k, v) in support::environment_variables(event) {
        command.env(k, v);
    }
    if let Some(dir) = non_empty(action, "workingDir") {
        command.current_dir(support::expand_tilde(dir, &home(cx)));
    }
    command
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    let child = match command.spawn() {
        Ok(child) => child,
        Err(err) => {
            log::error!("Action runScript: Failed to execute: {err}");
            return ExecutionReport::failure(format!("runScript failed to launch: {err}"));
        }
    };
    let pid = child.id();
    let finished = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
    let done = finished.clone();
    std::thread::spawn(move || {
        let output = child.wait_with_output();
        done.store(true, std::sync::atomic::Ordering::SeqCst);
        match output {
            Ok(out) if out.status.success() => {
                log::info!("Action runScript: Completed successfully")
            }
            Ok(out) => {
                let text: String = String::from_utf8_lossy(&out.stdout)
                    .chars()
                    .chain(String::from_utf8_lossy(&out.stderr).chars())
                    .take(500)
                    .collect();
                log::warn!(
                    "Action runScript: Exit code {}, output: {text}",
                    out.status.code().unwrap_or(-1)
                );
            }
            Err(err) => log::warn!("Action runScript: {err}"),
        }
    });
    // Terminate after the timeout if still running.
    std::thread::spawn(move || {
        std::thread::sleep(Duration::from_secs(timeout));
        if finished.load(std::sync::atomic::Ordering::SeqCst) {
            return;
        }
        log::warn!("Action runScript: Timeout after {timeout}s, terminating");
        #[cfg(unix)]
        // SAFETY: kill(2) on the child we started, which has not been reaped
        // yet (`finished` is still false), so the pid is still ours.
        unsafe {
            libc::kill(pid as i32, libc::SIGTERM);
        }
        #[cfg(not(unix))]
        let _ = pid;
    });
    ExecutionReport::success(NotificationActionType::RunScript)
}

fn run_shortcut(action: &NotificationActionConfig, event: &AiEvent) -> ExecutionReport {
    let Some(name) = non_empty(action, "shortcutName") else {
        log::warn!("Action runShortcut: No shortcut name provided");
        return ExecutionReport::failure("runShortcut missing shortcutName");
    };
    let pass_event = action.config_bool("passEventData", true);
    let mut command = Command::new("/usr/bin/shortcuts");
    command
        .args(["run", name])
        .stdin(if pass_event {
            Stdio::piped()
        } else {
            Stdio::null()
        })
        .stdout(Stdio::null())
        .stderr(Stdio::piped());
    let mut child = match command.spawn() {
        Ok(child) => child,
        Err(err) => {
            log::error!("Action runShortcut: Failed: {err}");
            return ExecutionReport::failure(format!("runShortcut failed to launch: {err}"));
        }
    };
    if pass_event && let Some(mut stdin) = child.stdin.take() {
        let _ = stdin.write_all(support::event_json(event).to_string().as_bytes());
    }
    let name = name.to_string();
    std::thread::spawn(move || match child.wait() {
        Ok(status) if status.success() => log::info!("Action runShortcut: Executed '{name}'"),
        Ok(status) => log::warn!(
            "Action runShortcut: '{name}' exited with {}",
            status.code().unwrap_or(-1)
        ),
        Err(err) => log::warn!("Action runShortcut: {err}"),
    });
    ExecutionReport::success(NotificationActionType::RunShortcut)
}

fn execute_snippet(
    action: &NotificationActionConfig,
    event: &AiEvent,
    cx: &mut App,
) -> ExecutionReport {
    let Some(snippet_id) = non_empty(action, "snippetId") else {
        log::warn!("Action executeSnippet: No snippet ID provided");
        return ExecutionReport::failure("executeSnippet missing snippetId");
    };
    let auto_execute = action.config_bool("autoExecute", false);
    let Some(tab) = event.tab_id else {
        log::warn!(
            "Action executeSnippet: Missing explicit tabID for event {}",
            event.id
        );
        return ExecutionReport::failure("executeSnippet missing explicit tabID");
    };
    let snippet_id = snippet_id.to_string();
    if routing::insert_snippet(tab, &snippet_id, auto_execute, cx) {
        ExecutionReport::success(NotificationActionType::ExecuteSnippet)
    } else {
        ExecutionReport::failure(format!(
            "executeSnippet failed for explicit tabID {}",
            tab.hyphenated().to_string().to_uppercase()
        ))
    }
}

// MARK: - Integrations

fn send_http(
    label: &'static str,
    url: String,
    method: String,
    headers: Vec<(String, String)>,
    body: Option<String>,
) {
    std::thread::spawn(move || {
        let config = support::curl_config(&url, &method, &headers, body.as_deref());
        let child = Command::new("curl")
            .args(support::CURL_STDIN_ARGS)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn();
        let output = child.and_then(|mut child| {
            if let Some(mut stdin) = child.stdin.take() {
                stdin.write_all(config.as_bytes())?;
            }
            child.wait_with_output()
        });
        match output {
            Ok(out) if out.status.success() => {
                let code = String::from_utf8_lossy(&out.stdout).trim().to_string();
                if code.starts_with('2') {
                    log::info!("Action {label}: Success ({code})");
                } else {
                    log::warn!("Action {label}: HTTP {code}");
                }
            }
            Ok(out) => log::error!(
                "Action {label}: Failed: {}",
                String::from_utf8_lossy(&out.stderr).trim()
            ),
            Err(err) => log::error!("Action {label}: Failed: {err}"),
        }
    });
}

fn webhook(action: &NotificationActionConfig, event: &AiEvent) -> ExecutionReport {
    let Some(url) = value(action, "url").filter(|u| support::is_valid_url(u)) else {
        log::warn!("Action webhook: Invalid URL");
        return ExecutionReport::failure("webhook invalid URL");
    };
    let method = value(action, "method").unwrap_or("POST").to_string();
    let headers = support::webhook_headers(value(action, "headers"));
    let body = (method != "GET")
        .then(|| support::webhook_payload(value(action, "customPayload"), event).to_string());
    send_http("webhook", url.to_string(), method, headers, body);
    ExecutionReport::success(NotificationActionType::Webhook)
}

fn send_chat(action: &NotificationActionConfig, event: &AiEvent, slack: bool) -> ExecutionReport {
    let (label, kind) = if slack {
        ("sendSlack", NotificationActionType::SendSlack)
    } else {
        ("sendDiscord", NotificationActionType::SendDiscord)
    };
    let Some(url) = value(action, "webhookUrl").filter(|u| support::is_valid_url(u)) else {
        log::warn!("Action {label}: Invalid webhook URL");
        return ExecutionReport::failure(format!("{label} invalid webhook URL"));
    };
    let payload = if slack {
        support::slack_payload(
            event,
            value(action, "username"),
            value(action, "emoji"),
            value(action, "channel"),
        )
    } else {
        support::discord_payload(event, value(action, "username"), value(action, "avatarUrl"))
    };
    send_http(
        label,
        url.to_string(),
        "POST".into(),
        Vec::new(),
        Some(payload.to_string()),
    );
    ExecutionReport::success(kind)
}

// MARK: - DevOps

fn docker_bump(action: &NotificationActionConfig) -> ExecutionReport {
    let Some(container) = non_empty(action, "container") else {
        log::warn!("Action dockerBump: No container specified");
        return ExecutionReport::failure("dockerBump missing container");
    };
    let operation = value(action, "operation").unwrap_or("restart");
    let docker = value(action, "dockerPath")
        .unwrap_or("/usr/local/bin/docker")
        .to_string();
    let steps = match support::docker_bump_steps(operation, container) {
        Ok(steps) => steps,
        Err(note) => {
            log::warn!("Action dockerBump: Unknown operation: {operation}");
            return ExecutionReport::failure(note);
        }
    };
    std::thread::spawn(move || {
        for step in steps {
            if !run_sync("dockerBump", Command::new(&docker).args(&step)) {
                return;
            }
        }
        log::info!("Action dockerBump: Completed successfully");
    });
    ExecutionReport::success(NotificationActionType::DockerBump)
}

fn docker_compose(action: &NotificationActionConfig, cx: &App) -> ExecutionReport {
    let Some(path) = non_empty(action, "composePath") else {
        log::warn!("Action dockerCompose: No compose file path specified");
        return ExecutionReport::failure("dockerCompose missing composePath");
    };
    let operation = value(action, "operation").unwrap_or("restart");
    let services = value(action, "services").unwrap_or("");
    let program = value(action, "dockerComposePath").unwrap_or("/usr/local/bin/docker-compose");
    let expanded = support::expand_tilde(path, &home(cx));
    match support::docker_compose_arguments(&expanded, operation, services) {
        Ok(args) => {
            let mut command = Command::new(program);
            command.args(args);
            run_in_background("dockerCompose".into(), command);
            ExecutionReport::success(NotificationActionType::DockerCompose)
        }
        Err(note) => {
            log::warn!("Action dockerCompose: Unknown operation: {operation}");
            ExecutionReport::failure(note)
        }
    }
}

fn kubernetes(action: &NotificationActionConfig) -> ExecutionReport {
    let Some(deployment) = non_empty(action, "deployment") else {
        log::warn!("Action kubernetesRollout: No deployment specified");
        return ExecutionReport::failure("kubernetesRollout missing deployment");
    };
    let args = support::kubectl_arguments(
        deployment,
        value(action, "namespace").unwrap_or("default"),
        value(action, "context"),
        value(action, "operation").unwrap_or("restart"),
        value(action, "replicas"),
    );
    match args {
        Ok(args) => {
            let mut command =
                Command::new(value(action, "kubectlPath").unwrap_or("/usr/local/bin/kubectl"));
            command.args(args);
            run_in_background("kubernetesRollout".into(), command);
            ExecutionReport::success(NotificationActionType::KubernetesRollout)
        }
        Err(note) => ExecutionReport::failure(note),
    }
}

// MARK: - Productivity

fn copy_to_clipboard(
    action: &NotificationActionConfig,
    event: &AiEvent,
    cx: &mut App,
) -> ExecutionReport {
    let content = support::interpolate(value(action, "content"), event);
    log::info!(
        "Action copyToClipboard: Copied {} characters",
        content.chars().count()
    );
    cx.write_to_clipboard(ClipboardItem::new_string(content));
    ExecutionReport::success(NotificationActionType::CopyToClipboard)
}

fn append(path: &str, text: &str) -> std::io::Result<()> {
    if let Some(parent) = Path::new(path).parent() {
        std::fs::create_dir_all(parent)?;
    }
    let mut file = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(path)?;
    file.write_all(text.as_bytes())
}

fn write_to_file(action: &NotificationActionConfig, event: &AiEvent, cx: &App) -> ExecutionReport {
    let Some(path) = non_empty(action, "filePath") else {
        log::warn!("Action writeToFile: No file path specified");
        return ExecutionReport::failure("writeToFile missing filePath");
    };
    let line = support::write_to_file_line(
        value(action, "format").unwrap_or("text"),
        value(action, "template"),
        event,
    );
    let expanded = support::expand_tilde(path, &home(cx));
    match append(&expanded, &format!("{line}\n")) {
        Ok(()) => {
            log::info!("Action writeToFile: Appended to {path}");
            ExecutionReport::success(NotificationActionType::WriteToFile)
        }
        Err(err) => {
            log::error!("Action writeToFile: Failed: {err}");
            ExecutionReport::failure(format!("writeToFile failed: {err}"))
        }
    }
}

fn open_url(action: &NotificationActionConfig, event: &AiEvent, cx: &mut App) -> ExecutionReport {
    let Some(template) = non_empty(action, "url") else {
        log::warn!("Action openURL: No URL specified");
        return ExecutionReport::failure("openURL missing url");
    };
    let raw = support::interpolate(Some(template), event);
    let url = support::percent_encode_query_allowed(&raw);
    if !support::is_valid_url(&url) {
        log::warn!("Action openURL: Invalid URL: {raw}");
        return ExecutionReport::failure(format!("openURL invalid URL: {raw}"));
    }
    match support::browser_bundle_id(value(action, "browser").unwrap_or("default")) {
        Some(bundle) if ns_workspace::app_path(bundle).is_some() => {
            if let Err(err) = ns_workspace::open_url_with(&url, bundle) {
                log::warn!("Action openURL: {err}");
                cx.open_url(&url);
            }
        }
        _ => cx.open_url(&url),
    }
    log::info!("Action openURL: Opened {url}");
    ExecutionReport::success(NotificationActionType::OpenUrl)
}

fn git_commit(action: &NotificationActionConfig, event: &AiEvent, cx: &App) -> ExecutionReport {
    let message = support::interpolate(
        Some(value(action, "message").unwrap_or("Auto-commit: ${type}")),
        event,
    );
    let add_all = action.config_bool("addAll", true);
    let push = action.config_bool("push", false);
    let dir = non_empty(action, "repoPath").map(|p| support::expand_tilde(p, &home(cx)));
    std::thread::spawn(move || {
        let git = |args: &[&str]| {
            let mut c = Command::new("/usr/bin/git");
            c.args(args);
            if let Some(dir) = &dir {
                c.current_dir(dir);
            }
            c
        };
        if add_all && !run_sync("gitCommit(add)", &mut git(&["add", "-A"])) {
            return;
        }
        if !run_sync("gitCommit(commit)", &mut git(&["commit", "-m", &message])) {
            return;
        }
        if push && !run_sync("gitCommit(push)", &mut git(&["push"])) {
            return;
        }
        log::info!("Action gitCommit: Completed successfully");
    });
    ExecutionReport::success(NotificationActionType::GitCommit)
}

// MARK: - Accessibility

fn voice_announce(action: &NotificationActionConfig, event: &AiEvent) -> ExecutionReport {
    let text = support::interpolate(value(action, "text"), event);
    let voice = value(action, "voice").unwrap_or("default");
    let rate = action.config_int("rate", 175) as f32;
    let voice_id = (voice != "default")
        .then(|| format!("com.apple.speech.synthesis.voice.{}", voice.to_lowercase()));
    match sound::speak(&text, voice_id.as_deref(), Some(rate)) {
        Ok(()) => log::info!(
            "Action voiceAnnounce: Speaking '{}...'",
            text.chars().take(50).collect::<String>()
        ),
        Err(err) => log::warn!("Action voiceAnnounce: {err}"),
    }
    ExecutionReport::success(NotificationActionType::VoiceAnnounce)
}

fn flash_screen(action: &NotificationActionConfig, cx: &mut App) -> ExecutionReport {
    let color = value(action, "color").unwrap_or("white").to_string();
    let duration = action.config_int("duration", 200).max(0) as u64;
    let count = action.config_int("count", 2).max(0) as u32;
    log::info!("Action flashScreen: Flashing {count} times");
    flash::flash(&color, duration, count, cx);
    ExecutionReport::success(NotificationActionType::FlashScreen)
}

fn menu_bar_alert(action: &NotificationActionConfig, cx: &mut App) -> ExecutionReport {
    let duration = action.config_int("duration", 5).max(0) as u64;
    let animate = action.config_bool("animate", true);
    flash::menu_bar_alert(duration, animate, cx);
    log::info!("Action menuBarAlert: Alert for {duration} seconds");
    ExecutionReport::success(NotificationActionType::MenuBarAlert)
}

// MARK: - Time tracking

fn start_timer(
    action: &NotificationActionConfig,
    event: &AiEvent,
    cx: &mut App,
) -> ExecutionReport {
    let name = support::interpolate(
        Some(value(action, "timerName").unwrap_or(&event.tool)),
        event,
    );
    let project = value(action, "project").unwrap_or("");
    state(cx).timers.start(&name, Instant::now());
    log::info!("Action startTimer: Started '{name}' for project '{project}'");
    ExecutionReport::success(NotificationActionType::StartTimer)
}

fn stop_timer(action: &NotificationActionConfig, cx: &mut App) -> ExecutionReport {
    let name = value(action, "timerName").map(str::to_string);
    match state(cx).timers.stop(name.as_deref(), Instant::now()) {
        Some((name, secs)) => {
            log::info!(
                "Action stopTimer: Stopped '{name}' after {}",
                support::elapsed_label(secs)
            );
            ExecutionReport::success(NotificationActionType::StopTimer)
        }
        None => {
            log::warn!("Action stopTimer: No active timer found");
            ExecutionReport::failure("stopTimer found no active timer")
        }
    }
}

fn log_time(action: &NotificationActionConfig, event: &AiEvent, cx: &App) -> ExecutionReport {
    let service = value(action, "service").unwrap_or("file");
    if service != "file" {
        log::warn!("Action logTime: Unknown service: {service}");
        return ExecutionReport::failure(format!("logTime unknown service: {service}"));
    }
    let description = support::interpolate(
        Some(value(action, "description").unwrap_or("${type}: ${message}")),
        event,
    );
    let path = value(action, "filePath").unwrap_or("~/time-log.csv");
    let expanded = support::expand_tilde(path, &home(cx));
    let result = (|| -> std::io::Result<()> {
        if let Some(parent) = Path::new(&expanded).parent() {
            std::fs::create_dir_all(parent)?;
        }
        // The header is written only by whoever creates the file.
        if let Ok(mut f) = std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&expanded)
        {
            f.write_all(LOG_TIME_HEADER.as_bytes())?;
        }
        append(
            &expanded,
            &format!("{}\n", support::log_time_entry(event, &description)),
        )
    })();
    match result {
        Ok(()) => {
            log::info!("Action logTime: Logged to {path}");
            ExecutionReport::success(NotificationActionType::LogTime)
        }
        Err(err) => {
            log::error!("Action logTime: Failed to write file: {err}");
            ExecutionReport::failure(format!("logTime failed: {err}"))
        }
    }
}
