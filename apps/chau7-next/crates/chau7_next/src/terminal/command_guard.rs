//! App-wide state of the dangerous command guard (`DangerousCommandGuard.shared`).
//!
//! The patterns and the enable switch come from the settings; the allow,
//! block and per-directory lists live in `dangerous_guard.json`.

use chau7_next_core::command_risk::{DangerousCommandGuard, GuardVerdict, self_protect};
use chau7_next_core::dangerous_guard_store;
use chau7_next_core::guard_line;
use gpui::{App, Global};

use crate::settings::Settings;
use crate::workspace::AppData;

pub struct GuardState(pub DangerousCommandGuard);

impl Global for GuardState {}

fn sync(cx: &mut App) {
    let (enabled, patterns) = {
        let s = &Settings::get(cx).dangerous_commands;
        (s.guard_enabled, s.patterns.clone())
    };
    let state = cx.global_mut::<GuardState>();
    state.0.is_enabled = enabled;
    state.0.patterns = patterns;
}

/// Load the saved lists. Call once at startup, after `AppData` is set.
pub fn init(cx: &mut App) {
    let path = cx.global::<AppData>().root.dangerous_guard_file();
    let mut guard = DangerousCommandGuard::default();
    dangerous_guard_store::load_into(&mut guard, &path);
    cx.set_global(GuardState(guard));
}

/// Verdict on the line being typed at the prompt.
pub fn check_line(
    line: &str,
    directory: Option<&str>,
    shell_pid: u64,
    cx: &mut App,
) -> GuardVerdict {
    sync(cx);
    let context = protection_context(shell_pid, cx);
    let settings = &Settings::get(cx).dangerous_commands;
    let protection = settings
        .protect_chau7_enabled
        .then_some((settings.protect_chau7_level, &context));
    let guard = &cx.global::<GuardState>().0;
    for candidate in guard_line::candidates(line) {
        let verdict = guard.check_with_self_protection(&candidate, directory, protection);
        if verdict.self_protection.is_some() {
            log_protection(&verdict, settings.protect_chau7_level);
            return verdict;
        }
    }
    guard_line::check_line(guard, line, directory).into()
}

/// Verdict on pasted text: it is the command itself, so no prompt to strip.
pub fn check_text(
    text: &str,
    directory: Option<&str>,
    shell_pid: u64,
    cx: &mut App,
) -> GuardVerdict {
    sync(cx);
    let context = protection_context(shell_pid, cx);
    let settings = &Settings::get(cx).dangerous_commands;
    let protection = settings
        .protect_chau7_enabled
        .then_some((settings.protect_chau7_level, &context));
    let verdict = cx
        .global::<GuardState>()
        .0
        .check_with_self_protection(text, directory, protection);
    log_protection(&verdict, settings.protect_chau7_level);
    verdict
}

fn protection_context(shell_pid: u64, cx: &App) -> self_protect::Context {
    let patterns = &Settings::get(cx)
        .dangerous_commands
        .protected_process_patterns;
    let pids = [
        i32::try_from(std::process::id()).ok(),
        i32::try_from(shell_pid).ok(),
    ]
    .into_iter()
    .flatten();
    let names = patterns.iter().cloned().chain([
        chau7_next_core::data_root::BUNDLE_ID.to_string(),
        "Chau7Next".to_string(),
    ]);
    let observed = u32::try_from(shell_pid)
        .ok()
        .map(|pid| crate::monitoring::process_tree::observed_names(pid, cx))
        .unwrap_or_default();
    self_protect::Context::new(pids, names).with_observed_names(patterns, &observed)
}
fn log_protection(verdict: &GuardVerdict, level: self_protect::ProtectionLevel) {
    if let Some(detail) = &verdict.self_protection {
        // A real verbose-logging response, without persisting typed secrets.
        log::warn!("Managed-process protection {:?}: {}", level, detail.reason);
    }
}

/// Write the lists to disk.
pub fn save(cx: &App) {
    let path = cx.global::<AppData>().root.dangerous_guard_file();
    if let Err(err) = dangerous_guard_store::save(&cx.global::<GuardState>().0, &path) {
        log::warn!("saving the command guard lists: {err}");
    }
}

/// "Always Allow": remember `command` and keep it.
pub fn always_allow(command: &str, cx: &mut App) {
    cx.global_mut::<GuardState>().0.add_to_allow_list(command);
    save(cx);
}
