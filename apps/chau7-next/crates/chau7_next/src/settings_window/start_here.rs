//! Current setup and permission summary. All values come from cached app state.
use super::{
    SectionContext, anchors,
    widgets::{description, section as titled},
};
use chau7_next_core::{
    l10n::{Arg, l, lf},
    permission_center::{FullDiskAccess, RecommendedAction},
};
use gpui::{div, prelude::*, px};
fn state(enabled: bool) -> String {
    if enabled {
        l("status.enabled", "Enabled")
    } else {
        l("status.disabled", "Disabled")
    }
}
fn item(
    label: impl Into<gpui::SharedString>,
    value: impl Into<gpui::SharedString>,
    detail: Option<String>,
    warning: bool,
    ctx: &SectionContext,
) -> gpui::Div {
    let chrome = ctx.chrome;
    div()
        .flex()
        .flex_col()
        .gap_1()
        .flex_1()
        .min_w(px(180.))
        .p_3()
        .rounded_md()
        .border_1()
        .border_color(chrome.border)
        .child(
            div()
                .text_xs()
                .text_color(chrome.text_muted)
                .child(label.into()),
        )
        .child(
            div()
                .text_sm()
                .font_weight(gpui::FontWeight::SEMIBOLD)
                .text_color(if warning { chrome.danger } else { chrome.text })
                .child(value.into()),
        )
        .when_some(detail, |card, text| card.child(description(text, chrome)))
}
pub(super) fn section(ctx: &SectionContext) -> gpui::Div {
    let chrome = ctx.chrome;
    let s = ctx.settings;
    let profile = ctx
        .view
        .mine
        .profiles
        .store
        .active_profile()
        .map(|p| p.name.clone())
        .unwrap_or_else(|| l("settings.profileBar.defaultSettings", "Default Settings"));
    let remote = ctx.remote.as_ref();
    let remote_running = s.remote.enabled && remote.is_some_and(|remote| remote.agent_running);
    let remote_error = remote
        .and_then(|remote| remote.last_error.as_ref())
        .filter(|s| !s.is_empty());
    let remote_detail = remote_error
        .cloned()
        .or_else(|| {
            remote.and_then(|remote| {
                remote
                    .devices
                    .iter()
                    .find(|(_, connected)| *connected)
                    .map(|(device, _)| {
                        lf(
                            "settings.remote.connectedDevice",
                            "Connected device: %@",
                            &[Arg::Str(device.name.clone())],
                        )
                    })
            })
        })
        .or_else(|| remote.and_then(|remote| remote.session_status.clone()))
        .or_else(|| s.remote.enabled.then(|| s.remote.relay_url.clone()));
    let remote_value = if !s.remote.enabled {
        state(false)
    } else if remote_running {
        l("status.running", "Running")
    } else {
        l("status.stopped", "Stopped")
    };
    let operational = anchors::target(
        "startHereStatus",
        titled(
            l("settings.startHere.operationalState", "Operational State"),
            chrome,
        )
        .child(
            div()
                .flex()
                .flex_wrap()
                .gap_3()
                .child(item(
                    l("settings.general.launchAtLogin", "Launch at Login"),
                    state(s.general.launch_at_login),
                    None,
                    false,
                    ctx,
                ))
                .child(item(
                    l("settings.startHere.activeProfile", "Active Profile"),
                    profile,
                    None,
                    false,
                    ctx,
                ))
                .child(item(
                    l("settings.mcpControl", "Agent Control"),
                    state(s.mcp.enabled),
                    s.mcp.enabled.then(|| {
                        lf(
                            "settings.startHere.mcp.detail",
                            "Max tabs: %d",
                            &[Arg::from(s.mcp.max_tabs)],
                        )
                    }),
                    false,
                    ctx,
                ))
                .child(item(
                    l("settings.remoteControl", "Remote Access"),
                    remote_value,
                    remote_detail,
                    s.remote.enabled && (!remote_running || remote_error.is_some()),
                    ctx,
                ))
                .child(item(
                    l("settings.notifications", "Alerts"),
                    ctx.monitoring.notifications.clone(),
                    ctx.notification_warning.clone(),
                    ctx.notification_warning.is_some(),
                    ctx,
                )),
        ),
    );
    let (fda_value, fda_detail, fda_warning) = match ctx.permissions.full_disk_access {
        FullDiskAccess::Granted => (
            l("settings.productivity.permissions.fda.granted", "Granted"),
            l(
                "settings.productivity.permissions.fda.granted.detail",
                "Child processes (codex, claude, shells) can reach protected folders like ~/Downloads.",
            ),
            false,
        ),
        FullDiskAccess::Denied => (
            l("settings.productivity.permissions.fda.denied", "Denied"),
            l(
                "settings.productivity.permissions.fda.denied.detail",
                "Grant Full Disk Access to Chau7 Next so child processes can reach protected folders.",
            ),
            true,
        ),
        FullDiskAccess::Indeterminate => (
            l("settings.productivity.permissions.fda.unknown", "Unknown"),
            l(
                "settings.productivity.permissions.fda.unknown.detail",
                "Full Disk Access status could not be determined.",
            ),
            false,
        ),
    };
    let protected = &ctx.permissions.protected_snapshots;
    let blocked = protected
        .iter()
        .filter(|snapshot| snapshot.recommended_action != RecommendedAction::None)
        .count();
    let protected_value = if protected.is_empty() {
        l("settings.startHere.protectedFolders.none", "None tracked")
    } else if blocked == 0 {
        l("settings.startHere.protectedFolders.ready", "Ready")
    } else {
        lf(
            "settings.startHere.protectedFolders.needsAccess",
            "%d need access",
            &[Arg::from(blocked)],
        )
    };
    let permissions = titled(l("settings.startHere.permissions", "Permissions"), chrome).child(
        div()
            .flex()
            .flex_wrap()
            .gap_3()
            .child(item(
                l(
                    "settings.productivity.permissions.notifications",
                    "Notifications",
                ),
                ctx.permissions.notification_permission.label(),
                None,
                ctx.notification_warning.is_some(),
                ctx,
            ))
            .child(item(
                l(
                    "settings.productivity.permissions.fullDiskAccess",
                    "Full Disk Access",
                ),
                fda_value,
                Some(fda_detail),
                fda_warning,
                ctx,
            ))
            .child(item(
                l("settings.startHere.protectedFolders", "Protected Folders"),
                protected_value,
                (!protected.is_empty()).then(|| {
                    lf(
                        "settings.startHere.protectedFolders.detail",
                        "%d protected roots tracked",
                        &[Arg::from(protected.len())],
                    )
                }),
                blocked > 0,
                ctx,
            )),
    );
    let event_path = if s.notifications.ai_events_log_path.trim().is_empty() {
        ctx.root.ai_events_log().display().to_string()
    } else {
        s.notifications.ai_events_log_path.clone()
    };
    div().flex().flex_col().gap_4().child(operational).child(permissions)
        .child(super::widgets::button("start-here-permissions","Review Permissions",chrome).on_click(|_,_,cx|super::open_at(Some(chau7_next_core::settings_search::SettingsSection::SnippetsTools),Some("permissions"),cx)))
        .child(titled(l("settings.startHere.paths","Paths"),chrome).child(div().flex().flex_wrap().gap_3()
            .child(item(l("settings.general.defaultDirectory","Default Directory"),s.general.default_directory.as_deref().unwrap_or("~"),None,false,ctx))
            .child(item(l("settings.notifications.eventLogPath","Event Log Path"),event_path,None,false,ctx))))
        .child(description(l("settings.startHere.hint","Use the sidebar or search to change any setting shown here. This page summarizes current state only."),chrome))
}
