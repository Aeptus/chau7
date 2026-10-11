//! Notifications section (`NotificationsSettingsView.swift`): six tabs.
//!
//! - AI Tools: status and permission (Request Permission, System Settings,
//!   Send Test), "AI Notification Essentials" (finished, failed,
//!   permission: on/off plus Banner, Highlight Tab, Sound, Dock Bounce).
//! - Advanced: every trigger by category and source with its actions
//!   (`notification_triggers.rs`).
//! - Thresholds: shell and app event detection.
//! - Behavior: rate limiting and per-trigger conditions.
//! - Monitoring: the AI event log monitor.
//! - History: the delivery ledger.

use std::collections::HashSet;

use chau7_next_core::ai::notification_settings::{
    self as bridge, AiNotificationPrimaryEvent, AiNotificationPrimaryPreference,
};
use chau7_next_core::notifications::history::HistoryEntry;
use chau7_next_core::notifications::hooks::{HookProvider, InstallationStatus};
use chau7_next_core::notifications::settings::{
    NotificationSettings, default_group_action_bindings,
};
use chau7_next_core::notifications::triggers::{self, TriggerCondition};
use gpui::{
    App, Context, Entity, SharedString, Subscription, WeakEntity, Window, div, prelude::*, px,
};
use gpui_kit::component::input::{Input, InputEvent, InputState};

use super::notification_triggers::{self, Editing};
use super::widgets::{
    button, chip, description, info_row, row, section as titled, stepper, toggle,
};
use super::{SectionContext, SettingsView, update};
use crate::notifications::banner::PermissionState;
use crate::notifications::{self as engine, NotificationCenter};
use crate::settings::notifications::DEFAULT_AI_EVENTS_LOG;
use crate::theme::Chrome;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub(super) enum NotifTab {
    #[default]
    Overview,
    Advanced,
    Thresholds,
    Behavior,
    Monitoring,
    History,
}

impl NotifTab {
    const ALL: [Self; 6] = [
        Self::Overview,
        Self::Advanced,
        Self::Thresholds,
        Self::Behavior,
        Self::Monitoring,
        Self::History,
    ];

    fn label(self) -> &'static str {
        match self {
            Self::Overview => "AI Tools",
            Self::Advanced => "Advanced",
            Self::Thresholds => "Thresholds",
            Self::Behavior => "Behavior",
            Self::Monitoring => "Monitoring",
            Self::History => "History",
        }
    }
}

/// UI state of the section, kept in the settings view.
pub(super) struct NotifState {
    pub tab: NotifTab,
    pub expanded_categories: HashSet<&'static str>,
    pub expanded_sources: HashSet<String>,
    pub expanded_trigger: Option<String>,
    pub overrides_open: bool,
    /// Trigger id whose "Add Action" list is open.
    pub picker_for: Option<String>,
    pub editing: Option<Editing>,
    pub expanded_condition: Option<String>,
    pub log_path: Entity<InputState>,
    /// Copies refreshed on each render.
    pub history: Vec<HistoryEntry>,
    pub permission: PermissionState,
    pub hooks: engine::hooks::Snapshot,
    pub warning: Option<&'static str>,
    pub message: Option<String>,
    _subscriptions: Vec<Subscription>,
}

impl NotifState {
    pub(super) fn new(window: &mut Window, cx: &mut Context<SettingsView>) -> Self {
        let path = crate::settings::Settings::get(cx)
            .notifications
            .ai_events_log_path
            .clone();
        let log_path = cx.new(|cx| {
            InputState::new(window, cx)
                .placeholder(DEFAULT_AI_EVENTS_LOG)
                .default_value(path)
        });
        let sub = cx.subscribe(&log_path, |_, input, event: &InputEvent, cx| {
            if matches!(event, InputEvent::PressEnter { .. } | InputEvent::Blur) {
                let value = input.read(cx).value().trim().to_string();
                let value = if value.is_empty() {
                    DEFAULT_AI_EVENTS_LOG.to_string()
                } else {
                    value
                };
                if crate::settings::Settings::get(cx)
                    .notifications
                    .ai_events_log_path
                    != value
                {
                    update(cx, |s| s.notifications.ai_events_log_path = value);
                    engine::restart_monitor(cx);
                }
            }
        });
        Self {
            tab: NotifTab::Overview,
            expanded_categories: HashSet::from(["aiApps"]),
            expanded_sources: HashSet::new(),
            expanded_trigger: None,
            overrides_open: false,
            picker_for: None,
            editing: None,
            expanded_condition: None,
            log_path,
            history: Vec::new(),
            permission: PermissionState::Unknown,
            hooks: engine::hooks::Snapshot::default(),
            warning: None,
            message: None,
            _subscriptions: vec![sub],
        }
    }

    /// Copy what the engine knows (history, permission) for this frame.
    pub(super) fn refresh(&mut self, cx: &App) {
        self.hooks = engine::hooks::snapshot(cx);
        if let Some(nc) = cx.try_global::<NotificationCenter>() {
            self.history = nc.history.recent(100);
            self.permission = nc.banner.permission;
            self.warning = nc.banner.warning();
        }
    }
}

/// Change the section's UI state and redraw.
pub(super) fn with_state(
    view: &WeakEntity<SettingsView>,
    cx: &mut App,
    change: impl FnOnce(&mut NotifState),
) {
    let _ = view.update(cx, |v, cx| {
        change(&mut v.notif);
        cx.notify();
    });
}

/// Change the notification rules and save.
pub(super) fn edit_rules(cx: &mut App, change: impl FnOnce(&mut NotificationSettings)) {
    update(cx, |s| change(&mut s.notifications.rules));
}

/// A checkbox with its own handler.
pub(super) fn check(
    id: impl Into<gpui::ElementId>,
    on: bool,
    enabled: bool,
    chrome: Chrome,
    on_change: impl Fn(bool, &mut App) + 'static,
) -> gpui::Stateful<gpui::Div> {
    div()
        .id(id)
        .size(px(14.0))
        .flex_none()
        .rounded_sm()
        .border_1()
        .border_color(if on { chrome.accent } else { chrome.border })
        .bg(if on { chrome.accent } else { chrome.tab_bg })
        .flex()
        .items_center()
        .justify_center()
        .text_xs()
        .text_color(gpui::white())
        .when(on, |d| d.child("✓"))
        .when(!enabled, |d| d.opacity(0.4))
        .when(enabled, |d| {
            d.cursor_pointer()
                .on_click(move |_, _, cx| on_change(!on, cx))
        })
}

/// A switch with its own handler.
pub(super) fn switch(
    id: impl Into<gpui::ElementId>,
    on: bool,
    chrome: Chrome,
    on_change: impl Fn(bool, &mut App) + 'static,
) -> gpui::Stateful<gpui::Div> {
    div()
        .id(id)
        .flex_none()
        .w(px(32.0))
        .h(px(18.0))
        .rounded_full()
        .p(px(2.0))
        .flex()
        .cursor_pointer()
        .when(on, |d| d.justify_end())
        .bg(if on { chrome.accent } else { chrome.border })
        .child(div().size(px(14.0)).rounded_full().bg(gpui::white()))
        .on_click(move |_, _, cx| on_change(!on, cx))
}

pub(super) fn small(text: impl Into<SharedString>, chrome: Chrome) -> gpui::Div {
    div()
        .text_xs()
        .text_color(chrome.text_muted)
        .child(text.into())
}

pub(super) fn section(ctx: &SectionContext) -> gpui::Div {
    let chrome = ctx.chrome;
    let state = &ctx.view.notif;
    let view = ctx.view.entity.clone();
    let tabs = NotifTab::ALL.into_iter().map(|tab| {
        let view = view.clone();
        chip(
            SharedString::from(format!("notif-tab-{}", tab.label())),
            tab.label(),
            state.tab == tab,
            chrome,
        )
        .cursor_pointer()
        .on_click(move |_, _, cx| with_state(&view, cx, |s| s.tab = tab))
    });
    let mut page = div()
        .flex()
        .flex_col()
        .gap_2()
        .child(div().flex().flex_wrap().gap_1().pb_2().children(tabs));
    if let Some(message) = &state.message {
        page = page.child(super::widgets::banner(message.clone(), false, chrome));
    }
    match state.tab {
        NotifTab::Overview => page
            .child(status(ctx))
            .child(hook_installers(ctx))
            .child(repo_mutes(ctx))
            .child(ai_overview(ctx)),
        NotifTab::Advanced => page
            .child(status(ctx))
            .child(notification_triggers::triggers(ctx)),
        NotifTab::Thresholds => page.child(thresholds(ctx)),
        NotifTab::Behavior => page.child(rate_limiting(ctx)).child(conditions(ctx)),
        NotifTab::Monitoring => page.child(monitoring(ctx)),
        NotifTab::History => page.child(history(ctx)),
    }
}

fn repo_mutes(ctx: &SectionContext) -> gpui::Div {
    let chrome = ctx.chrome;
    let mut section = titled("Muted Repositories", chrome)
        .child(description("Mute or snooze a repository from its tab group menu. Expired snoozes resume notifications automatically.", chrome));
    let now = chrono::Utc::now();
    let active = ctx
        .settings
        .notifications
        .rules
        .muted_repos
        .iter()
        .filter(|(_, mute)| mute.is_active(now))
        .collect::<Vec<_>>();
    if active.is_empty() {
        section = section.child(small("No repositories are muted.", chrome));
    }
    for (index, (root, mute)) in active.into_iter().enumerate() {
        let until = mute
            .snooze_until
            .map(|until| {
                format!(
                    "Snoozed until {}",
                    until.with_timezone(&chrono::Local).format("%Y-%m-%d %H:%M")
                )
            })
            .unwrap_or_else(|| "Muted until unmuted".into());
        let root = root.clone();
        let label = root.clone();
        section = section.child(row(
            label,
            div()
                .flex()
                .items_center()
                .gap_2()
                .child(small(until, chrome))
                .child(
                    button(
                        SharedString::from(format!("notif-unmute-repo-{index}")),
                        "Unmute",
                        chrome,
                    )
                    .on_click(move |_, _, cx| engine::unmute_repo(&root, cx)),
                ),
            chrome,
        ));
    }
    section
}

fn hook_installers(ctx: &SectionContext) -> gpui::Div {
    let chrome = ctx.chrome;
    let state = &ctx.view.notif.hooks;
    let mut section = titled("AI Tool Hooks", chrome)
        .child(description("Capture completion, approval and interactive prompt events in Chau7 Next. Restart a CLI session after installing or removing hooks.", chrome));
    for (index, (provider, name)) in [
        (HookProvider::Claude, "Claude Code"),
        (HookProvider::Codex, "Codex"),
    ]
    .into_iter()
    .enumerate()
    {
        let installed = state.statuses[index] == Some(InstallationStatus::Installed);
        let label = if !cfg!(unix) {
            "Session wrappers are unavailable on this platform"
        } else if state.busy {
            "Checking…"
        } else {
            state.statuses[index]
                .map(InstallationStatus::label)
                .unwrap_or("Not checked")
        };
        let mut actions = div()
            .flex()
            .items_center()
            .gap_2()
            .child(small(label, chrome));
        if cfg!(unix) && !state.busy {
            actions = actions.child(
                button(
                    SharedString::from(format!("notif-hook-change-{index}")),
                    if installed { "Uninstall" } else { "Install" },
                    chrome,
                )
                .on_click(move |_, _, cx| engine::hooks::change(provider, !installed, cx)),
            );
        }
        section = section.child(row(name, actions, chrome));
    }
    if let Some(message) = &state.message {
        section = section.child(description(message.clone(), chrome));
    }
    section.child(
        div().flex().child(
            button("notif-hook-refresh", "Refresh Hook Status", chrome)
                .on_click(|_, _, cx| engine::hooks::refresh(cx)),
        ),
    )
}

// ----- status ------------------------------------------------------------------

fn status(ctx: &SectionContext) -> gpui::Div {
    let chrome = ctx.chrome;
    let state = &ctx.view.notif;
    let permission = state.permission;
    let mut block = titled("Status & Permissions", chrome).child(info_row(
        "Status",
        permission.label(),
        chrome,
    ));
    if let Some(warning) = state.warning {
        block = block.child(row(
            "Warning",
            div()
                .max_w(px(360.0))
                .text_xs()
                .text_color(gpui::hsla(0.08, 0.9, 0.55, 1.0))
                .child(format!("⚠ {warning}")),
            chrome,
        ));
    }
    let request = button("notif-request", "Request Permission", chrome)
        .on_click(|_, _, cx| engine::request_permission(cx));
    let system = || {
        button("notif-system", "System Settings", chrome)
            .on_click(|_, _, cx| cx.open_url(crate::platform::notifications::SYSTEM_SETTINGS_URL))
    };
    let buttons = match permission {
        PermissionState::UnavailableNotBundled => {
            return block.child(description(
                "Launch the app as a bundle to enable system notifications. Until then, banners use AppleScript.",
                chrome,
            ));
        }
        PermissionState::NotDetermined | PermissionState::Unknown => {
            div().flex().gap_2().child(request)
        }
        PermissionState::Denied => div().flex().gap_2().child(system()),
        PermissionState::Authorized | PermissionState::Provisional => div()
            .flex()
            .gap_2()
            .child(
                button("notif-test", "Send Test", chrome)
                    .on_click(|_, _, cx| engine::send_test(cx)),
            )
            .child(system()),
    };
    block.child(buttons)
}

// ----- AI overview ---------------------------------------------------------------

fn primary_trigger_id(event: AiNotificationPrimaryEvent, rules: &NotificationSettings) -> String {
    let group = triggers::ai_coding_group();
    bridge::managed_trigger_types(event)
        .into_iter()
        .map(|t| group.group_trigger_id(t))
        .find(|id| {
            rules
                .group_action_bindings
                .get(id)
                .is_some_and(|a| !a.is_empty())
        })
        .unwrap_or_else(|| bridge::group_trigger_id(event, &group.id))
}

fn primary_preference(
    event: AiNotificationPrimaryEvent,
    rules: &NotificationSettings,
) -> AiNotificationPrimaryPreference {
    let id = primary_trigger_id(event, rules);
    let defaults = default_group_action_bindings();
    bridge::preference(
        event,
        rules
            .group_action_bindings
            .get(&id)
            .map(Vec::as_slice)
            .unwrap_or(&[]),
        defaults.get(&id).map(Vec::as_slice).unwrap_or(&[]),
    )
}

fn set_primary_preference(
    event: AiNotificationPrimaryEvent,
    preference: AiNotificationPrimaryPreference,
    cx: &mut App,
) {
    edit_rules(cx, |r| {
        let group = triggers::ai_coding_group();
        let defaults = default_group_action_bindings();
        for t in bridge::managed_trigger_types(event) {
            let id = group.group_trigger_id(t);
            let current = r
                .group_action_bindings
                .get(&id)
                .cloned()
                .unwrap_or_default();
            let updated = bridge::updated_actions(
                event,
                &preference,
                &current,
                defaults.get(&id).map(Vec::as_slice).unwrap_or(&[]),
            );
            r.group_action_bindings.insert(id, updated);
        }
    });
}

fn override_count(event: AiNotificationPrimaryEvent, rules: &NotificationSettings) -> usize {
    let group = triggers::ai_coding_group();
    let types = bridge::managed_trigger_types(event);
    triggers::all()
        .iter()
        .filter(|t| {
            group.contains(&t.source)
                && types.contains(&t.trigger_type.as_str())
                && rules.trigger_state.has_per_trigger_override(t)
        })
        .count()
}

fn ai_overview(ctx: &SectionContext) -> gpui::Div {
    let chrome = ctx.chrome;
    let rules = &ctx.settings.notifications.rules;
    let view = ctx.view.entity.clone();
    let cards = AiNotificationPrimaryEvent::ALL.into_iter().map(|event| {
        let enabled = bridge::is_effectively_enabled(event, &rules.trigger_state);
        let pref = primary_preference(event, rules);
        let overrides = override_count(event, rules);
        let option = |label: &'static str,
                      value: bool,
                      set: fn(&mut AiNotificationPrimaryPreference, bool)| {
            div()
                .flex()
                .items_center()
                .gap_1()
                .child(check(
                    SharedString::from(format!("primary-{}-{label}", event.raw_value())),
                    value,
                    enabled,
                    chrome,
                    move |v, cx| {
                        let mut p = pref;
                        set(&mut p, v);
                        set_primary_preference(event, p, cx);
                    },
                ))
                .child(div().text_xs().child(label))
        };
        let mut card = div()
            .flex()
            .flex_col()
            .gap_2()
            .p_3()
            .rounded_lg()
            .bg(chrome.text.opacity(0.035))
            .child(
                div()
                    .flex()
                    .items_start()
                    .gap_3()
                    .child(switch(
                        SharedString::from(format!("primary-on-{}", event.raw_value())),
                        enabled,
                        chrome,
                        move |v, cx| {
                            edit_rules(cx, |r| {
                                r.trigger_state = bridge::updated_state_for_primary_toggle(
                                    &r.trigger_state,
                                    event,
                                    v,
                                )
                            })
                        },
                    ))
                    .child(
                        div()
                            .flex_1()
                            .flex()
                            .flex_col()
                            .child(
                                div()
                                    .text_sm()
                                    .font_weight(gpui::FontWeight::SEMIBOLD)
                                    .child(event.title()),
                            )
                            .child(small(event.summary(), chrome)),
                    )
                    .when(overrides > 0, |d| {
                        d.child(
                            div()
                                .px_1p5()
                                .py_0p5()
                                .rounded_md()
                                .text_xs()
                                .text_color(gpui::hsla(0.08, 0.9, 0.55, 1.0))
                                .bg(gpui::hsla(0.08, 0.9, 0.55, 0.12))
                                .child(format!(
                                    "{overrides} override{}",
                                    if overrides == 1 { "" } else { "s" }
                                )),
                        )
                    }),
            )
            .child(
                div()
                    .flex()
                    .flex_wrap()
                    .gap_4()
                    .pl(px(44.0))
                    .child(option("Banner", pref.show_notification, |p, v| {
                        p.show_notification = v
                    }))
                    .child(option("Highlight Tab", pref.style_tab, |p, v| {
                        p.style_tab = v
                    }))
                    .child(option("Sound", pref.play_sound, |p, v| p.play_sound = v))
                    .child(option("Dock Bounce", pref.dock_bounce, |p, v| {
                        p.dock_bounce = v
                    })),
            );
        if pref.has_additional_actions {
            card = card.child(div().pl(px(44.0)).child(small(
                "Advanced actions are attached to this event and will be preserved.",
                chrome,
            )));
        }
        card
    });
    titled("AI Notification Essentials", chrome)
        .child(description(
            "Choose the only things AI tools should interrupt you for by default.",
            chrome,
        ))
        .children(cards)
        .child(description(
            "Use Advanced for per-tool overrides, extra triggers, scripts, and event-source specific rules.",
            chrome,
        ))
        .child(
            div().flex().child(
                button("notif-open-advanced", "Open Advanced Rules", chrome).on_click(
                    move |_, _, cx| with_state(&view, cx, |s| s.tab = NotifTab::Advanced),
                ),
            ),
        )
}

// ----- thresholds ------------------------------------------------------------------

fn thresholds(ctx: &SectionContext) -> gpui::Div {
    let chrome = ctx.chrome;
    let shell = &ctx.settings.notifications.shell_events;
    let app = &ctx.settings.notifications.app_events;
    titled("Detection Thresholds", chrome)
        .child(description(
            "Configure when shell and app events should trigger notifications.",
            chrome,
        ))
        .child(
            div()
                .pt_2()
                .text_sm()
                .font_weight(gpui::FontWeight::SEMIBOLD)
                .child(crate::l10n::tr("Shell Events")),
        )
        .child(row(
            "Long-Running (seconds)",
            stepper(
                "notif-long-running",
                shell.long_running_threshold_seconds.to_string(),
                chrome,
                |s, d| {
                    let v = &mut s.notifications.shell_events.long_running_threshold_seconds;
                    *v = (*v + d as i64 * 10).max(1);
                },
            ),
            chrome,
        ))
        .child(row(
            "Directory Change",
            toggle(
                "notif-dir-change",
                shell.notify_on_directory_change,
                chrome,
                |s, v| s.notifications.shell_events.notify_on_directory_change = v,
            ),
            chrome,
        ))
        .child(row(
            "Git Branch",
            toggle(
                "notif-git-branch",
                shell.notify_on_git_branch_change,
                chrome,
                |s, v| s.notifications.shell_events.notify_on_git_branch_change = v,
            ),
            chrome,
        ))
        .child(
            div()
                .pt_2()
                .text_sm()
                .font_weight(gpui::FontWeight::SEMIBOLD)
                .child(crate::l10n::tr("App Events")),
        )
        .child(row(
            "Inactivity (minutes)",
            div()
                .flex()
                .items_center()
                .gap_2()
                .child(stepper(
                    "notif-inactivity",
                    app.inactivity_threshold_minutes.to_string(),
                    chrome,
                    |s, d| {
                        let v = &mut s.notifications.app_events.inactivity_threshold_minutes;
                        *v = (*v + d as i64).max(0);
                    },
                ))
                .child(small("0 = disabled", chrome)),
            chrome,
        ))
        .child(row(
            "Memory (MB)",
            div()
                .flex()
                .items_center()
                .gap_2()
                .child(stepper(
                    "notif-memory",
                    app.memory_threshold_mb.to_string(),
                    chrome,
                    |s, d| {
                        let v = &mut s.notifications.app_events.memory_threshold_mb;
                        *v = (*v + d as i64 * 100).max(0);
                    },
                ))
                .child(small("0 = disabled", chrome)),
            chrome,
        ))
        .child(row(
            "Tab Open",
            toggle("notif-tab-open", app.notify_on_tab_open, chrome, |s, v| {
                s.notifications.app_events.notify_on_tab_open = v
            }),
            chrome,
        ))
        .child(row(
            "Tab Close",
            toggle(
                "notif-tab-close",
                app.notify_on_tab_close,
                chrome,
                |s, v| s.notifications.app_events.notify_on_tab_close = v,
            ),
            chrome,
        ))
}

// ----- behavior --------------------------------------------------------------------

fn rate_limiting(ctx: &SectionContext) -> gpui::Div {
    let chrome = ctx.chrome;
    let c = ctx.settings.notifications.rules.rate_limit_config;
    let line = |label: &'static str, help: &'static str, control: gpui::Div| {
        row(
            label,
            div()
                .flex()
                .items_center()
                .gap_2()
                .child(control)
                .child(small(help, chrome)),
            chrome,
        )
    };
    titled("Rate Limiting", chrome)
        .child(description(
            "Prevent notification spam from burst events. Applies per-trigger independently.",
            chrome,
        ))
        .child(line(
            "Max per minute",
            "Token refill rate",
            stepper(
                "notif-rate-max",
                c.max_per_minute.to_string(),
                chrome,
                |s, d| {
                    let v = &mut s.notifications.rules.rate_limit_config.max_per_minute;
                    *v = (*v + d as i64).clamp(1, 60);
                },
            ),
        ))
        .child(line(
            "Burst allowance",
            "Extra burst above rate",
            stepper(
                "notif-rate-burst",
                c.burst_allowance.to_string(),
                chrome,
                |s, d| {
                    let v = &mut s.notifications.rules.rate_limit_config.burst_allowance;
                    *v = (*v + d as i64).clamp(0, 20);
                },
            ),
        ))
        .child(line(
            "Cooldown (seconds)",
            "Min gap between same trigger",
            stepper(
                "notif-rate-cooldown",
                format!("{:.0}", c.cooldown_seconds),
                chrome,
                |s, d| {
                    let v = &mut s.notifications.rules.rate_limit_config.cooldown_seconds;
                    *v = (*v + d as f64).clamp(0.0, 300.0);
                },
            ),
        ))
}

fn conditions(ctx: &SectionContext) -> gpui::Div {
    let chrome = ctx.chrome;
    let rules = &ctx.settings.notifications.rules;
    let view = ctx.view.entity.clone();
    let expanded = ctx.view.notif.expanded_condition.clone();
    let enabled: Vec<_> = triggers::all()
        .iter()
        .filter(|t| rules.trigger_state.is_enabled(t))
        .collect();
    let mut block = titled("Trigger Conditions", chrome).child(description(
        "Control when enabled triggers are allowed to fire. Conditions are evaluated before rate limiting.",
        chrome,
    ));
    if enabled.is_empty() {
        return block.child(small(
            "No triggers are currently enabled. Enable triggers in the Triggers tab first.",
            chrome,
        ));
    }
    for trigger in enabled {
        let id = trigger.id.clone();
        let condition = rules
            .trigger_conditions
            .get(&id)
            .copied()
            .unwrap_or_default();
        let custom = condition != TriggerCondition::default();
        let is_open = expanded.as_deref() == Some(id.as_str());
        let source_label = triggers::sources()
            .iter()
            .find(|s| s.id == trigger.source)
            .map(|s| s.label_fallback)
            .unwrap_or("");
        let view_toggle = view.clone();
        let toggle_id = id.clone();
        let mut item = div().flex().flex_col().child(
            div()
                .id(SharedString::from(format!("cond-{id}")))
                .flex()
                .items_center()
                .gap_2()
                .px_1()
                .py_1()
                .rounded_md()
                .cursor_pointer()
                .hover(|d| d.bg(chrome.tab_hover_bg))
                .child(div().text_xs().child(if is_open { "▾" } else { "▸" }))
                .child(
                    div()
                        .flex_1()
                        .text_xs()
                        .child(format!("{source_label}: {}", trigger.label_fallback)),
                )
                .when(custom, |d| {
                    d.child(
                        div()
                            .text_xs()
                            .text_color(chrome.accent)
                            .child(crate::l10n::tr("Custom")),
                    )
                })
                .on_click(move |_, _, cx| {
                    let id = toggle_id.clone();
                    with_state(&view_toggle, cx, |s| {
                        s.expanded_condition = if s.expanded_condition.as_deref() == Some(&id) {
                            None
                        } else {
                            Some(id)
                        }
                    })
                }),
        );
        if is_open {
            let set = move |id: String,
                            change: fn(&mut TriggerCondition, bool),
                            v: bool,
                            cx: &mut App| {
                rules_condition(id, cx, |c| change(c, v));
            };
            let line = |label: &'static str,
                        on: bool,
                        key: &'static str,
                        change: fn(&mut TriggerCondition, bool)| {
                let id = id.clone();
                div()
                    .flex()
                    .items_center()
                    .gap_2()
                    .child(check(
                        SharedString::from(format!("cond-{key}-{id}")),
                        on,
                        true,
                        chrome,
                        move |v, cx| set(id.clone(), change, v, cx),
                    ))
                    .child(div().text_xs().child(label))
            };
            let reset_id = id.clone();
            item = item.child(
                div()
                    .flex()
                    .flex_col()
                    .gap_1()
                    .pl_6()
                    .py_1()
                    .child(line(
                        "Respect Focus/DND mode",
                        condition.respect_dnd,
                        "dnd",
                        |c, v| c.respect_dnd = v,
                    ))
                    .child(line(
                        "Only when app is in background",
                        condition.only_when_unfocused,
                        "bg",
                        |c, v| c.only_when_unfocused = v,
                    ))
                    .child(line(
                        "Only when triggering tab is not selected",
                        condition.only_when_tab_inactive,
                        "tab",
                        |c, v| c.only_when_tab_inactive = v,
                    ))
                    .when(custom, |d| {
                        d.child(
                            div().flex().child(
                                button(
                                    SharedString::from(format!("cond-reset-{reset_id}")),
                                    "Reset to defaults",
                                    chrome,
                                )
                                .on_click(move |_, _, cx| {
                                    let id = reset_id.clone();
                                    edit_rules(cx, |r| {
                                        r.trigger_conditions.remove(&id);
                                    })
                                }),
                            ),
                        )
                    }),
            );
        }
        block = block.child(item);
    }
    block
}

/// `setConditionForTrigger`: the default condition removes the entry.
fn rules_condition(id: String, cx: &mut App, change: impl FnOnce(&mut TriggerCondition)) {
    edit_rules(cx, |r| {
        let mut condition = r.trigger_conditions.get(&id).copied().unwrap_or_default();
        change(&mut condition);
        if condition == TriggerCondition::default() {
            r.trigger_conditions.remove(&id);
        } else {
            r.trigger_conditions.insert(id, condition);
        }
    });
}

// ----- monitoring ------------------------------------------------------------------

fn monitoring(ctx: &SectionContext) -> gpui::Div {
    let chrome = ctx.chrome;
    let n = &ctx.settings.notifications;
    let view = ctx.view.entity.clone();
    let path = n.ai_events_log_path.clone();
    let home = ctx.home.clone();
    titled("Event Monitoring", chrome)
        .child(row(
            "Monitor AI Events",
            toggle("notif-monitor", n.monitor_ai_events, chrome, |s, v| {
                s.notifications.monitor_ai_events = v
            }),
            chrome,
        ))
        .child(description(
            "Watch for AI CLI events like task completion, failures, and permission requests",
            chrome,
        ))
        .child(row(
            "Event Log Path",
            div()
                .w(px(280.0))
                .child(Input::new(&ctx.view.notif.log_path)),
            chrome,
        ))
        .child(description("Path to the AI event log file", chrome))
        .child(
            div()
                .flex()
                .gap_2()
                .child(
                    button("notif-restart-monitor", "Restart Monitor", chrome).on_click(
                        move |_, _, cx| {
                            let message = if engine::restart_monitor(cx) {
                                "Monitor restarted."
                            } else {
                                "The AI event monitor is not running."
                            };
                            with_state(&view, cx, |s| s.message = Some(message.into()));
                        },
                    ),
                )
                .child(
                    button("notif-reveal-log", "Reveal in Finder", chrome).on_click(
                        move |_, _, cx| {
                            let expanded =
                                chau7_next_core::notifications::action_support::expand_tilde(
                                    &path, &home,
                                );
                            cx.reveal_path(std::path::Path::new(&expanded));
                        },
                    ),
                ),
        )
}

// ----- history ---------------------------------------------------------------------

fn history(ctx: &SectionContext) -> gpui::Div {
    let chrome = ctx.chrome;
    let entries = &ctx.view.notif.history;
    let delivered = entries
        .iter()
        .filter(|e| !e.actions_executed.is_empty())
        .count();
    let dropped = entries.iter().filter(|e| e.drop_reason.is_some()).count();
    let limited = entries.iter().filter(|e| e.was_rate_limited).count();
    let summary = format!(
        "{} events: {delivered} delivered, {dropped} dropped, {limited} rate limited",
        entries.len()
    );
    let mut block = titled("Notification History", chrome)
        .child(
            div()
                .flex()
                .items_center()
                .justify_between()
                .gap_2()
                .child(description(
                    "Recent notification events (last 100, in-memory only).",
                    chrome,
                ))
                .child(
                    button("notif-history-refresh", "Refresh", chrome)
                        .on_click(|_, _, cx| cx.refresh_windows()),
                )
                .child(
                    button("notif-history-clear", "Clear", chrome).on_click(|_, _, cx| {
                        if cx.has_global::<NotificationCenter>() {
                            cx.global_mut::<NotificationCenter>().history.clear();
                        }
                        cx.refresh_windows();
                    }),
                ),
        )
        .child(small(summary, chrome));
    if entries.is_empty() {
        return block.child(small("No notification events recorded yet.", chrome));
    }
    for (i, e) in entries.iter().enumerate() {
        let time = e
            .timestamp
            .with_timezone(&chrono::Local)
            .format("%H:%M:%S")
            .to_string();
        let color = if e.was_rate_limited {
            gpui::hsla(0.08, 0.9, 0.55, 1.0)
        } else if e.drop_reason.is_some() {
            chrome.danger
        } else if !e.actions_executed.is_empty() {
            gpui::hsla(0.35, 0.6, 0.45, 1.0)
        } else {
            chrome.text_muted
        };
        let mut lines = vec![format!(
            "{} {}{}",
            e.delivery_state.raw_value(),
            e.trigger_id.clone().unwrap_or_default(),
            e.semantic_kind
                .as_ref()
                .map(|k| format!(" ({k})"))
                .unwrap_or_default()
        )];
        if let Some(reason) = &e.drop_reason {
            lines.push(format!("Dropped: {reason}"));
        }
        if !e.actions_executed.is_empty() {
            lines.push(format!("Actions: {}", e.actions_executed.join(", ")));
        }
        if let Some(method) = &e.resolution_method {
            lines.push(format!(
                "Routing: {method}{}",
                e.resolved_tab_id
                    .as_ref()
                    .map(|t| format!(" tab {t}"))
                    .unwrap_or_default()
            ));
        }
        if !e.notes.is_empty() {
            lines.push(e.notes.join(" | "));
        }
        if let Some(confidence) = &e.classification_confidence {
            lines.push(format!(
                "Codex proposal: {confidence} confidence ({})",
                e.classification_evidence.join(", ")
            ));
        }
        block = block.child(
            div()
                .id(SharedString::from(format!("notif-history-{i}")))
                .flex()
                .flex_col()
                .gap_0p5()
                .px_2()
                .py_1p5()
                .rounded_md()
                .bg(if i % 2 == 0 {
                    chrome.text.opacity(0.03)
                } else {
                    chrome.text.opacity(0.0)
                })
                .child(
                    div()
                        .flex()
                        .gap_2()
                        .text_xs()
                        .child(div().text_color(chrome.text_muted).child(time))
                        .child(div().size(px(8.0)).mt_1().rounded_full().bg(color))
                        .child(
                            div()
                                .font_weight(gpui::FontWeight::SEMIBOLD)
                                .child(format!("{}.{}", e.source, e.event_type)),
                        )
                        .child(div().text_color(chrome.text_muted).child(e.tool.clone()))
                        .child(
                            div()
                                .text_color(chrome.text_muted)
                                .child(e.reliability.clone()),
                        ),
                )
                .when(!e.message.is_empty(), |d| {
                    d.child(
                        div()
                            .text_xs()
                            .child(e.message.chars().take(160).collect::<String>()),
                    )
                })
                .children(lines.into_iter().map(|l| small(l, chrome))),
        );
    }
    block
}
