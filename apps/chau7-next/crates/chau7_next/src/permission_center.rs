//! Cached permission evidence shared by Productivity and Start Here.
use crate::{
    notifications::{
        NotificationCenter,
        banner::{self, PermissionState},
    },
    workspace::AppData,
};
use chau7_next_core::permission_center::{
    FullDiskAccess, ProtectedSnapshot, probe_full_disk_access,
};
use chrono::{DateTime, Utc};
use gpui::{App, Global};
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
}
impl Global for State {}
/// Read cached evidence only; no permission prompts or file access from rendering.
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
/// Refresh asynchronously. Only an explicit OS denial becomes Denied.
pub fn refresh(cx: &mut App) {
    if !cx.has_global::<State>() {
        cx.set_global(State::default());
    }
    if cx.global::<State>().refreshing {
        return;
    }
    cx.global_mut::<State>().refreshing = true;
    if cx.has_global::<NotificationCenter>() {
        banner::refresh(&mut cx.global_mut::<NotificationCenter>().banner);
    }
    let home = cx.global::<AppData>().root.home().to_path_buf();
    let probe = cx
        .background_executor()
        .spawn(async move { probe_full_disk_access(&home) });
    cx.spawn(async move |cx| {
        let full_disk_access = probe.await;
        cx.update(|cx| {
            let state = cx.global_mut::<State>();
            state.full_disk_access = full_disk_access;
            state.last_refreshed_at = Some(Utc::now());
            state.refreshing = false;
            cx.refresh_windows();
        });
    })
    .detach();
    cx.refresh_windows();
}
