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

/// Installs the helpers by default: without them a plain `codex`/`claude`
/// launch never reports its session ID to its tab, so restore has no resume
/// prompt to offer. Isolated test profiles keep their explicit fixtures.
pub fn init(cx: &mut App) {
    cx.set_global(Snapshot::default());
    let defaults = !chau7_next_core::data_root::is_isolated_test_mode();
    run(None, defaults, cx);
}

pub fn refresh(cx: &mut App) {
    run(None, false, cx);
}

pub fn change(provider: HookProvider, install: bool, cx: &mut App) {
    run(Some((provider, install)), false, cx);
}

fn run(action: Option<(HookProvider, bool)>, defaults: bool, cx: &mut App) {
    if cx.global::<Snapshot>().busy {
        return;
    }
    cx.global_mut::<Snapshot>().busy = true;
    let root = cx.global::<AppData>().root.clone();
    let worker = cx.background_executor().spawn(async move {
        if defaults {
            let python = plans::python3_available();
            for provider in [HookProvider::Claude, HookProvider::Codex] {
                match plans::ensure_default(&root, provider, python) {
                    Ok(true) => log::info!("Installed {provider:?} session hooks by default"),
                    Ok(false) => {}
                    Err(error) => log::warn!("Default {provider:?} session hooks: {error}"),
                }
            }
        }
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
