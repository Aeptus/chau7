//! App startup gate before session/helper/profile mutation.
use chau7_next_core::{
    data_root::DataRoot,
    instance::{Acquisition, InstanceGuard, Outcome, Owner},
};
pub fn acquire(root: &DataRoot) -> std::io::Result<Option<InstanceGuard>> {
    match InstanceGuard::acquire(&root.instance_lock_file(), root.launch_continuity_file())? {
        Acquisition::Acquired(guard) => Ok(Some(guard)),
        Acquisition::AlreadyRunning(owner) => {
            activate_existing(owner.as_ref());
            eprintln!(
                "{}: this profile already has a running application",
                chau7_next_core::data_root::APP_NAME
            );
            Ok(None)
        }
    }
}
pub fn begin(guard: &InstanceGuard) -> std::io::Result<()> {
    let build = crate::platform::system::bundle_string("CFBundleVersion")
        .unwrap_or_else(|| env!("CARGO_PKG_VERSION").into());
    let previous = guard.begin_launch(&build)?;
    let message = format!(
        "Launch continuity previous={} previous_build={} previous_started={} current_build={} pid={}",
        previous.outcome.name(),
        previous.build.as_deref().unwrap_or("unknown"),
        previous
            .started_at
            .map(|at| at.to_rfc3339())
            .unwrap_or_else(|| "unknown".into()),
        build,
        guard.owner().pid
    );
    if previous.outcome == Outcome::Abrupt {
        log::warn!("{message}");
        crate::incidents::record(
            chau7_next_core::incidents::Kind::AppRecovery,
            chau7_next_core::incidents::Severity::Warning,
            "Previous launch ended abruptly",
            std::collections::BTreeMap::from([
                (
                    "previousBuild".into(),
                    previous.build.unwrap_or_else(|| "unknown".into()),
                ),
                ("currentBuild".into(), build),
            ]),
        );
    } else {
        log::info!("{message}");
    }
    Ok(())
}
#[cfg(target_os = "macos")]
fn activate_existing(owner: Option<&Owner>) {
    use objc2_app_kit::{NSApplicationActivationOptions, NSRunningApplication};
    let Some(pid) = owner.and_then(|owner| i32::try_from(owner.pid).ok()) else {
        return;
    };
    let Some(application) = NSRunningApplication::runningApplicationWithProcessIdentifier(pid)
    else {
        return;
    };
    let current = crate::platform::system::bundle_string("CFBundleIdentifier");
    if current.is_some() && application.bundleIdentifier().map(|id| id.to_string()) == current {
        application.activateWithOptions(NSApplicationActivationOptions::ActivateAllWindows);
    }
}
#[cfg(not(target_os = "macos"))]
fn activate_existing(_: Option<&Owner>) {}
