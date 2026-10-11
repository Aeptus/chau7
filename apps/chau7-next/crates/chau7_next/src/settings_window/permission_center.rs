//! Current Productivity Permission Center. Controls remain in General.
use super::{
    SectionContext,
    widgets::{button, description, info_row, section as titled},
};
use crate::{l10n::l, notifications::banner::PermissionState};
use chau7_next_core::permission_center::{FullDiskAccess, RecommendedAction};
use gpui::{div, prelude::*};
pub(super) fn section(ctx: &SectionContext) -> gpui::Div {
    let chrome = ctx.chrome;
    let snapshot = &ctx.permissions;
    let notification_detail = match snapshot.notification_permission {
        PermissionState::Authorized | PermissionState::Provisional => {
            "System notifications are available."
        }
        PermissionState::NotDetermined => "Notification permission has not been requested yet.",
        PermissionState::Denied => "Notifications are denied in System Settings.",
        PermissionState::UnavailableNotBundled => "Notifications require the bundled app.",
        PermissionState::Unknown => "Notification status could not be determined.",
    };
    let (fda_label, fda_detail) = if cfg!(target_os = "macos") {
        match snapshot.full_disk_access {
            FullDiskAccess::Granted => (
                "Granted",
                "Child processes (codex, claude, shells) can reach protected folders like ~/Downloads.",
            ),
            FullDiskAccess::Denied => (
                "Denied",
                "Commands in protected folders fail with Operation not permitted. Re-enable Full Disk Access for Chau7 Next in System Settings.",
            ),
            FullDiskAccess::Indeterminate => (
                "Unknown",
                "Full Disk Access status could not be determined.",
            ),
        }
    } else {
        ("Not Applicable", "Full Disk Access is a macOS permission.")
    };
    let mut rows=titled(l("settings.productivity.permissions","Permissions"),chrome)
        .child(description(l("settings.productivity.permissions.help","Review notification status and protected-folder access without guessing what is blocked."),chrome))
        .child(info_row(l("settings.productivity.permissions.notifications","Notifications"),snapshot.notification_permission.label(),chrome))
        .child(description(notification_detail,chrome))
        .child(info_row(l("settings.productivity.permissions.fullDiskAccess","Full Disk Access"),fda_label,chrome))
        .child(description(fda_detail,chrome));
    for protected in &snapshot.protected_snapshots {
        let title = protected
            .root
            .as_ref()
            .map(|path| {
                if path.starts_with(&ctx.home) {
                    path.file_name()
                        .map(|name| name.to_string_lossy().into_owned())
                        .unwrap_or_else(|| path.display().to_string())
                } else {
                    path.display().to_string()
                }
            })
            .unwrap_or_else(|| "Protected Root".into());
        let detail = if protected.can_use_known_identity && !protected.can_probe_live {
            "Known repo identity is preserved, but live refresh is blocked."
        } else {
            match protected.recommended_action {
                RecommendedAction::None => "Live repo detection is available for this root.",
                RecommendedAction::EnableFeature => {
                    "Enable protected folder access to allow live repo refresh."
                }
                RecommendedAction::GrantAccess => {
                    "Grant folder access to allow live repo refresh in this location."
                }
                RecommendedAction::WaitForCooldown => {
                    "Chau7 Next is waiting before retrying access after a recent denial."
                }
                RecommendedAction::RegrantAccess => {
                    "The saved permission is stale. Grant access again to restore live refresh."
                }
            }
        };
        rows = rows
            .child(info_row(title, protected.state.label(), chrome))
            .child(description(detail, chrome));
    }
    let checked = snapshot
        .last_refreshed_at
        .map(|value| value.format("%Y-%m-%d %H:%M:%S UTC").to_string())
        .unwrap_or_else(|| "Not checked".into());
    rows = rows.child(info_row("Last Checked", checked, chrome));
    div().flex().flex_col().gap_4().child(super::general::protected_controls(ctx)).child(rows.child(div().flex().gap_2()
        .child(button("permission-refresh",if snapshot.refreshing {"Refreshing..."}else{"Refresh Status"},chrome).on_click(|_,_,cx|crate::permission_center::refresh(cx)))
        .child(button("permission-system-settings","Open System Settings",chrome).on_click(|_,_,cx|{
            cx.open_url("x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles");
        }))))
}
