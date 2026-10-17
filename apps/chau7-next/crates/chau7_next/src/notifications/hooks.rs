//! Async installation controls for the owned session-only CLI hook plans.
use chau7_next_core::notifications::hooks::{self as plans, HookProvider, InstallationStatus};
use gpui::{App, Global};

use crate::workspace::AppData;

#[derive(Debug, Clone, Default)]
pub struct Snapshot {
    pub statuses: [Option<InstallationStatus>; 2],
    pub busy: bool,
    pub message: Option<String>,
}
impl Global for Snapshot {}

pub fn snapshot(cx: &App) -> Snapshot {
    cx.try_global::<Snapshot>().cloned().unwrap_or_default()
}

pub fn init(cx: &mut App) {
    cx.set_global(Snapshot::default());
    refresh(cx);
}

pub fn refresh(cx: &mut App) {
    run(None, cx);
}

pub fn change(provider: HookProvider, install: bool, cx: &mut App) {
    run(Some((provider, install)), cx);
}

fn run(action: Option<(HookProvider, bool)>, cx: &mut App) {
    if cx.global::<Snapshot>().busy {
        return;
    }
    cx.global_mut::<Snapshot>().busy = true;
    let root = cx.global::<AppData>().root.clone();
    let worker = cx.background_executor().spawn(async move {
        let result = action.map(|(provider, install)| {
            if install {
                plans::install(&root, provider)
            } else {
                plans::uninstall(&root, provider)
            }
        });
        let statuses = [HookProvider::Claude, HookProvider::Codex]
            .map(|provider| Some(plans::installation_status(&root, provider)));
        (statuses, result)
    });
    cx.spawn(async move |cx| {
        let (statuses, result) = worker.await;
        cx.update(|cx| {
            let snapshot = cx.global_mut::<Snapshot>();
            snapshot.statuses = statuses;
            snapshot.busy = false;
            snapshot.message = result.map(|result| match result {
                Ok(()) => {
                    "Notification hook configuration updated. Restart the CLI session to apply it."
                        .into()
                }
                Err(error) => error,
            });
            cx.refresh_windows();
        });
    })
    .detach();
    cx.refresh_windows();
}
