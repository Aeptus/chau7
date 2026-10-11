//! App-wide state of the dangerous command guard (`DangerousCommandGuard.shared`).
//!
//! The patterns and the enable switch come from the settings; the allow,
//! block and per-directory lists live in `dangerous_guard.json`.

use chau7_next_core::command_risk::{CheckResult, DangerousCommandGuard};
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
pub fn check_line(line: &str, directory: Option<&str>, cx: &mut App) -> CheckResult {
    sync(cx);
    guard_line::check_line(&cx.global::<GuardState>().0, line, directory)
}

/// Verdict on pasted text: it is the command itself, so no prompt to strip.
pub fn check_text(text: &str, directory: Option<&str>, cx: &mut App) -> CheckResult {
    sync(cx);
    cx.global::<GuardState>().0.check(text, directory)
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
