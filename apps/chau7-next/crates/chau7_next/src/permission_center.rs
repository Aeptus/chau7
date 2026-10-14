//! Cached permission evidence and the current proactive/reactive FDA guard.
use crate::{
    notifications::{
        NotificationCenter,
        banner::{self, PermissionState},
    },
    workspace::AppData,
};
use chau7_next_core::data_root::APP_NAME;
use chau7_next_core::permission_center::{
    FullDiskAccess, FullDiskAccessGuard, ProtectedSnapshot, denial_root, probe_full_disk_access,
};
use chrono::{DateTime, Utc};
use gpui::{App, Global, PromptLevel};
const FDA_SETTINGS_URL: &str =
    "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles";
#[derive(Debug, Clone)]
pub struct Snapshot {
    pub protected_snapshots: Vec<ProtectedSnapshot>,
    pub notification_permission: PermissionState,
    pub full_disk_access: FullDiskAccess,
    pub last_refreshed_at: Option<DateTime<Utc>>,
    pub refreshing: bool,
}
#[derive(Default)]
struct State {
    full_disk_access: FullDiskAccess,
    last_refreshed_at: Option<DateTime<Utc>>,
    refreshing: bool,
    guard: FullDiskAccessGuard,
    guard_pending: bool,
    child_denial_root: Option<String>,
    started: bool,
    stopped: bool,
}
impl Global for State {}
pub fn snapshot(cx: &App, known_repo_roots: &[String]) -> Snapshot {
    let state = cx.try_global::<State>();
    Snapshot {
        protected_snapshots: crate::protected_paths::snapshots_with_known_roots(known_repo_roots),
        notification_permission: cx
            .try_global::<NotificationCenter>()
            .map(|center| center.banner.permission)
            .unwrap_or(PermissionState::Unknown),
        full_disk_access: state
            .map(|state| state.full_disk_access)
            .unwrap_or_default(),
        last_refreshed_at: state.and_then(|state| state.last_refreshed_at),
        refreshing: state.is_some_and(|state| state.refreshing),
    }
}
fn state(cx: &mut App) -> &mut State {
    if !cx.has_global::<State>() {
        cx.set_global(State::default());
    }
    cx.global_mut::<State>()
}
fn guard_enabled(cx: &App) -> bool {
    cfg!(target_os = "macos")
        && crate::settings::Settings::get(cx)
            .general
            .full_disk_access_guard_enabled
}
/// Start once after the first window exists. Activation callbacks use recheck.
pub fn start(cx: &mut App) {
    if !guard_enabled(cx) || state(cx).started {
        return;
    }
    state(cx).started = true;
    recheck(cx);
}
/// Stop before application teardown; late probes cannot present prompts.
pub fn stop(cx: &mut App) {
    if cx.has_global::<State>() {
        let state = cx.global_mut::<State>();
        state.stopped = true;
        state.guard_pending = false;
        state.child_denial_root = None;
    }
}
/// Call only when the app becomes active, not from rendering.
pub fn recheck(cx: &mut App) {
    if guard_enabled(cx) {
        refresh_internal(cx, true, None);
    }
}
/// Read-only UI refresh does not invoke the warning guard.
pub fn refresh(cx: &mut App) {
    refresh_internal(cx, false, None);
}
/// A failed command's actual bounded transcript and cwd are the two evidence sources.
pub fn report_command_denial(exit_code: i32, output: &str, cwd: &str, cx: &mut App) {
    if exit_code == 0 || !guard_enabled(cx) {
        return;
    }
    let home = cx
        .global::<AppData>()
        .root
        .home()
        .to_string_lossy()
        .into_owned();
    let roots = chau7_next_core::protected_path::protected_roots(&home);
    if let Some(root) = denial_root(output, cwd, &roots) {
        refresh_internal(cx, true, Some(root));
    }
}
fn refresh_internal(cx: &mut App, guard_pending: bool, child_root: Option<String>) {
    let current = state(cx);
    if current.stopped {
        return;
    }
    current.guard_pending |= guard_pending;
    if child_root.is_some() {
        current.child_denial_root = child_root;
    }
    if current.refreshing {
        return;
    }
    current.refreshing = true;
    if cx.has_global::<NotificationCenter>() {
        banner::refresh(&mut cx.global_mut::<NotificationCenter>().banner);
    }
    let home = cx.global::<AppData>().root.home().to_path_buf();
    let probe = cx
        .background_executor()
        .spawn(async move { probe_full_disk_access(&home) });
    cx.spawn(async move |cx| {
        let result = probe.await;
        cx.update(|cx| {
            let enabled = guard_enabled(cx);
            let current = state(cx);
            if current.stopped {
                return;
            }
            current.full_disk_access = result;
            current.last_refreshed_at = Some(Utc::now());
            current.refreshing = false;
            let guard_pending = std::mem::take(&mut current.guard_pending);
            let child_root = current.child_denial_root.take();
            if guard_pending {
                let previous = current.guard.status;
                current.guard.reconcile(result, child_root.is_some());
                match result {
                    FullDiskAccess::Granted if child_root.is_some() => log::info!(
                        "FullDiskAccessGuard: child EPERM in protected folder, but probe reports access; not attributing to FDA"
                    ),
                    FullDiskAccess::Granted if previous == FullDiskAccess::Denied => {
                        log::info!("FullDiskAccessGuard: Full Disk Access restored")
                    }
                    FullDiskAccess::Denied => log::warn!(
                        "FullDiskAccessGuard: Full Disk Access probe denied (child_denial={})",
                        child_root.is_some()
                    ),
                    FullDiskAccess::Indeterminate if child_root.is_some() => log::warn!(
                        "FullDiskAccessGuard: child EPERM in protected folder; Full Disk Access could not be confirmed"
                    ),
                    _ => {}
                }
            }
            let now = Utc::now().timestamp_millis() as f64 / 1000.0;
            let alert = enabled
                && guard_pending
                && current.guard.should_alert(result, child_root.is_some(), now);
            if alert {
                present_alert(result, child_root.as_deref(), now, cx);
            }
            cx.refresh_windows();
        });
    })
    .detach();
    cx.refresh_windows();
}
fn alert_detail(child_root: Option<&str>) -> String {
    if let Some(root) = child_root {
        chau7_next_core::l10n::format_printf(
            &crate::l10n::tr(
                "A command failed with Operation not permitted in %@. Full Disk Access could not be confirmed. Re-enable Full Disk Access for %@ in System Settings.",
            ),
            &[root.into(), APP_NAME.into()],
        )
    } else {
        chau7_next_core::l10n::format_printf(
            &crate::l10n::tr(
                "Terminal commands and AI agents in protected folders like ~/Downloads will fail with Operation not permitted. This can follow a rebuild or re-sign. Re-enable Full Disk Access for %@ in System Settings.",
            ),
            &[APP_NAME.into()],
        )
    }
}

fn present_alert(status: FullDiskAccess, child_root: Option<&str>, now: f64, cx: &mut App) {
    let Some(handle) = cx
        .active_window()
        .or_else(|| cx.windows().into_iter().next())
    else {
        return;
    };
    let title = if status == FullDiskAccess::Indeterminate {
        format!("Check Full Disk Access for {APP_NAME}")
    } else {
        format!("{APP_NAME} has lost Full Disk Access")
    };
    let detail = alert_detail(child_root);
    let answer = handle.update(cx, |_, window, cx| {
        // The detail is already localized. Translating it again could rewrite
        // a user directory whose name includes the beta product name.
        let title = crate::l10n::tr(&title);
        let open = crate::l10n::tr("Open Full Disk Access...");
        let later = crate::l10n::tr("Later");
        window.prompt(
            PromptLevel::Warning,
            &title,
            Some(&detail),
            &[open.as_str(), later.as_str()],
            cx,
        )
    });
    let Ok(answer) = answer else {
        return;
    };
    state(cx).guard.record_alert(now);
    cx.spawn(async move |cx| {
        if answer.await == Ok(0) {
            cx.update(|cx| {
                if !state(cx).stopped {
                    cx.open_url(FDA_SETTINGS_URL);
                }
            });
        }
    })
    .detach();
}

#[cfg(test)]
mod alert_detail_tests {
    use super::*;

    #[test]
    fn permission_details_preserve_user_paths_containing_beta_name() {
        let root = "/Users/test/Downloads/Chau7 Next project";
        let detail = alert_detail(Some(root));
        assert!(detail.contains(root), "{detail}");
        assert!(detail.contains(&format!("for {APP_NAME} in System Settings.")));
    }

    #[test]
    fn permission_details_without_child_use_compiled_product() {
        assert!(alert_detail(None).contains(&format!("for {APP_NAME} in System Settings.")));
    }
}
