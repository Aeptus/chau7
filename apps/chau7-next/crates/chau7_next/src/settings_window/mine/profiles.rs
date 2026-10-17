//! Profiles: the profile bar, automatic switching and the SSH config sync
//! (`ProfileSelectorBar.swift`, `ProfileAutoSwitchSettingsView.swift`,
//! `SSHProfilesSettingsView.swift`).
//!
//! The sections cannot reach the window's `Context`, so what they change
//! lives in app globals ([`ProfilesUi`] for the open forms) and the
//! settings window copies it into [`MineState`] on each render.

use std::io::Write;

use chau7_next_core::profile_rules::{ProfileSwitchRule, ProfileSwitchTrigger};
use chau7_next_core::settings_profiles::Uuid;
use chau7_next_core::settings_profiles::{AVAILABLE_ICONS, icon_glyph};
use chau7_next_core::ssh_config::{self, SSHConfigEntry};
use chau7_next_core::ssh_connections::{SshConnection, importable_entries};
use gpui::{App, Entity, Global, SharedString, div, prelude::*, px};
use gpui_kit::component::input::{Input, InputState};

use super::super::SectionContext;
use super::super::widgets::{chip, row, section as titled};
use super::{hint, small_button};
use crate::profiles::{self, ProfilesState, SshState};
use crate::theme::Chrome;
use crate::workspace::AppData;

pub const TRIGGER_KINDS: [&str; 5] = [
    "Directory",
    "Git Repository",
    "SSH Host",
    "Process",
    "Environment Variable",
];

/// The rule form that is open.
#[derive(Debug, Clone, PartialEq)]
pub struct RuleDraft {
    /// The rule being edited; `None` for a new one.
    pub id: Option<Uuid>,
    pub enabled: bool,
    pub priority: i64,
    pub kind: usize,
    pub profile: String,
}

/// Forms and confirmations that are open in the profile sections.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct ProfilesUi {
    pub creating: bool,
    pub icon: String,
    pub rule: Option<RuleDraft>,
    pub confirm_delete_rule: Option<Uuid>,
    pub confirm_import_all: bool,
    pub ssh_status: Option<String>,
    pub backup_status: Option<String>,
}

impl Global for ProfilesUi {}

pub(super) fn ui_edit(cx: &mut App, change: impl FnOnce(&mut ProfilesUi)) {
    change(cx.default_global::<ProfilesUi>());
    cx.refresh_windows();
}

/// Inputs and copies of the profile state, owned by the settings view.
pub(in super::super) struct ProfilesPane {
    pub name: Entity<InputState>,
    pub rule_name: Entity<InputState>,
    pub rule_value: Entity<InputState>,
    pub rule_value2: Entity<InputState>,
    pub ui: ProfilesUi,
    pub store: chau7_next_core::settings_profiles::ProfileStore,
    pub current_rule: Option<ProfileSwitchRule>,
    pub ssh_entries: std::sync::Arc<Vec<SSHConfigEntry>>,
    pub ssh_watching: bool,
    pub ssh_synced: Option<i64>,
    pub ssh_saved: usize,
    ssh_watch_state: Option<bool>,
    ssh_error: Option<String>,
    ssh_synced_local: Option<chrono::NaiveDateTime>,
}

impl ProfilesPane {
    pub(super) fn new(
        name: Entity<InputState>,
        rule_name: Entity<InputState>,
        rule_value: Entity<InputState>,
        rule_value2: Entity<InputState>,
    ) -> Self {
        Self {
            name,
            rule_name,
            rule_value,
            rule_value2,
            ui: ProfilesUi::default(),
            store: Default::default(),
            current_rule: None,
            ssh_entries: Default::default(),
            ssh_watching: false,
            ssh_synced: None,
            ssh_saved: 0,
            ssh_watch_state: None,
            ssh_error: None,
            ssh_synced_local: None,
        }
    }

    pub(super) fn refresh(&mut self, cx: &App) {
        if let Some(state) = cx.try_global::<ProfilesState>() {
            self.store = state.store.clone();
            self.current_rule = state.switcher.current_rule.clone();
        }
        self.ui = cx.try_global::<ProfilesUi>().cloned().unwrap_or_default();
        if let Some(ssh) = cx.try_global::<SshState>() {
            self.ssh_saved = ssh.0.connections.len();
        }
        let sync = profiles::ssh_config_sync::snapshot(cx);
        self.ssh_watch_state = sync.watching;
        self.ssh_watching = sync.watching.unwrap_or(false);
        self.ssh_entries = sync.entries;
        self.ssh_synced = sync.last_sync;
        self.ssh_error = sync.error;
        self.ssh_synced_local = sync.last_sync_local;
    }

    pub(in super::super) fn ssh_watch_status(&self) -> Option<bool> {
        self.ssh_watch_state
    }

    pub(in super::super) fn ssh_last_sync_local(&self) -> Option<chrono::NaiveDateTime> {
        self.ssh_synced_local
    }

    /// "Chau7 Next Settings for <name>", the window title.
    pub(in super::super) fn title(&self) -> String {
        match self.store.active_profile() {
            Some(profile) => format!("Chau7 Next Settings for {}", profile.name),
            None => "Chau7 Next Settings".to_string(),
        }
    }
}

fn switch(
    id: &'static str,
    on: bool,
    chrome: Chrome,
    apply: impl Fn(bool, &mut App) + 'static,
) -> gpui::Stateful<gpui::Div> {
    div()
        .id(id)
        .w(px(38.0))
        .h(px(22.0))
        .rounded_full()
        .p(px(2.0))
        .flex()
        .cursor_pointer()
        .when(on, |d| d.justify_end())
        .bg(if on { chrome.accent } else { chrome.border })
        .child(div().size(px(18.0)).rounded_full().bg(gpui::white()))
        .on_click(move |_, _, cx| apply(!on, cx))
}

/// The profile bar at the top of the settings.
pub(in super::super) fn bar(ctx: &SectionContext) -> gpui::Div {
    let chrome = ctx.chrome;
    let pane = &ctx.view.mine.profiles;
    let active = pane.store.active.clone();
    let chips = pane.store.profiles.iter().map(|profile| {
        let id = profile.id.clone();
        chip(
            SharedString::from(format!("profile-{}", profile.id)),
            format!("{} {}", icon_glyph(&profile.icon), profile.name),
            active.as_deref() == Some(profile.id.as_str()),
            chrome,
        )
        .on_click(move |_, _, cx| {
            profiles::load_profile(&id, cx);
        })
    });
    let title = pane.title();
    let mut bar = titled("Profile", chrome)
        .child(div().text_sm().child(SharedString::from(title)))
        .child(div().flex().flex_wrap().gap_1().children(chips))
        .child(
            div()
                .flex()
                .gap_2()
                .child(
                    small_button("profile-new", "Create New Profile...", chrome).on_click(
                        |_, _, cx| {
                            ui_edit(cx, |ui| {
                                ui.creating = true;
                                if ui.icon.is_empty() {
                                    ui.icon = "person.fill".to_string();
                                }
                            });
                        },
                    ),
                )
                .when(active.is_some(), |d| {
                    d.child(
                        small_button("profile-save", "Save Current", chrome)
                            .on_click(|_, _, cx| profiles::save_current(cx)),
                    )
                    .child(
                        small_button("profile-deactivate", "Deactivate Profile", chrome)
                            .on_click(|_, _, cx| profiles::deactivate(cx)),
                    )
                })
                .when(active.is_some() && pane.store.profiles.len() > 1, |d| {
                    let id = active.clone().unwrap_or_default();
                    d.child(
                        small_button("profile-delete", "Delete Profile", chrome)
                            .on_click(move |_, _, cx| profiles::delete_profile(&id, cx)),
                    )
                }),
        );
    if pane.ui.creating {
        let icons = AVAILABLE_ICONS.into_iter().map(|icon| {
            chip(
                SharedString::from(format!("icon-{icon}")),
                icon_glyph(icon),
                pane.ui.icon == icon,
                chrome,
            )
            .on_click(move |_, _, cx| ui_edit(cx, |ui| ui.icon = icon.to_string()))
        });
        let name = pane.name.clone();
        let icon = pane.ui.icon.clone();
        bar = bar
            .child(hint(
                "All current settings are saved to this profile. Switch between profiles to customize Chau7 for different workflows.",
                chrome,
            ))
            .child(div().w(px(280.0)).child(Input::new(&pane.name)))
            .child(div().flex().flex_wrap().gap_1().children(icons))
            .child(
                div()
                    .flex()
                    .gap_2()
                    .child(
                        small_button("profile-create", "Create Profile", chrome).on_click(
                            move |_, window, cx| {
                                let text = name.read(cx).value().to_string();
                                if profiles::create_profile(&text, &icon, cx).is_some() {
                                    name.update(cx, |state, cx| {
                                        state.set_value(String::new(), window, cx)
                                    });
                                    ui_edit(cx, |ui| ui.creating = false);
                                }
                            },
                        ),
                    )
                    .child(
                        small_button("profile-create-cancel", "Cancel", chrome)
                            .on_click(|_, _, cx| ui_edit(cx, |ui| ui.creating = false)),
                    ),
            );
    }
    bar
}

fn trigger_kind(trigger: &ProfileSwitchTrigger) -> usize {
    match trigger {
        ProfileSwitchTrigger::Directory { .. } => 0,
        ProfileSwitchTrigger::GitRepository { .. } => 1,
        ProfileSwitchTrigger::SshHost { .. } => 2,
        ProfileSwitchTrigger::ProcessRunning { .. } => 3,
        ProfileSwitchTrigger::EnvironmentVariable { .. } => 4,
    }
}

fn build_trigger(kind: usize, a: String, b: String) -> Option<ProfileSwitchTrigger> {
    if a.is_empty() {
        return None;
    }
    Some(match kind {
        0 => ProfileSwitchTrigger::Directory { path: a },
        1 => ProfileSwitchTrigger::GitRepository { name: a },
        2 => ProfileSwitchTrigger::SshHost { hostname: a },
        3 => ProfileSwitchTrigger::ProcessRunning { name: a },
        _ => ProfileSwitchTrigger::EnvironmentVariable { key: a, value: b },
    })
}

/// Automatic profile switching.
pub(in super::super) fn auto_switch(ctx: &SectionContext) -> gpui::Div {
    let chrome = ctx.chrome;
    let pane = &ctx.view.mine.profiles;
    let store = &pane.store;
    let mut section = titled("Automatic profile switching", chrome).child(row(
        "Switch profiles by rule",
        switch("auto-switch", store.auto_switch, chrome, |on, cx| {
            profiles::set_auto_switch(on, cx)
        }),
        chrome,
    ));
    if !store.auto_switch {
        return section.child(hint(
            "Rules load a profile when a tab changes to a matching directory, repository, SSH host, process or environment. The previous profile comes back when nothing matches.",
            chrome,
        ));
    }
    if let Some(rule) = &pane.current_rule {
        section = section.child(
            div()
                .flex()
                .items_center()
                .justify_between()
                .p_2()
                .rounded_md()
                .bg(chrome.accent.opacity(0.15))
                .child(div().text_sm().child(SharedString::from(format!(
                    "Active: {} to {}",
                    rule.name, rule.profile_name
                ))))
                .child(
                    small_button("auto-restore", "Restore", chrome)
                        .on_click(|_, _, cx| profiles::restore_previous(cx)),
                ),
        );
    }
    let mut sorted = store.rules.clone();
    sorted.sort_by(|a, b| {
        b.priority
            .cmp(&a.priority)
            .then_with(|| a.name.cmp(&b.name))
    });
    if sorted.is_empty() {
        section = section.child(hint("No rules yet.", chrome));
    }
    for rule in sorted {
        let edit_rule = rule.clone();
        let del_id = rule.id;
        let name_in = pane.rule_name.clone();
        let value_in = pane.rule_value.clone();
        let value2_in = pane.rule_value2.clone();
        section = section.child(
            div()
                .flex()
                .items_center()
                .justify_between()
                .gap_2()
                .child(
                    div()
                        .flex_1()
                        .min_w_0()
                        .child(
                            div()
                                .flex()
                                .items_center()
                                .gap_2()
                                .text_sm()
                                .child(SharedString::from(rule.name.clone()))
                                .when(!rule.is_enabled, |d| {
                                    d.child(
                                        div()
                                            .text_xs()
                                            .text_color(chrome.text_muted)
                                            .child(crate::l10n::tr("DISABLED")),
                                    )
                                })
                                .when(rule.priority != 0, |d| {
                                    d.child(
                                        div().text_xs().text_color(chrome.accent).child(
                                            SharedString::from(format!("P{}", rule.priority)),
                                        ),
                                    )
                                }),
                        )
                        .child(div().text_xs().text_color(chrome.text_muted).child(
                            SharedString::from(format!(
                                "{} to {}",
                                rule.trigger.display_summary(),
                                rule.profile_name
                            )),
                        )),
                )
                .child(
                    div()
                        .flex()
                        .gap_1()
                        .child(
                            small_button(
                                SharedString::from(format!("rule-edit-{}", rule.id)),
                                "Edit",
                                chrome,
                            )
                            .on_click(move |_, window, cx| {
                                let rule = edit_rule.clone();
                                let (a, b) = match &rule.trigger {
                                    ProfileSwitchTrigger::Directory { path } => {
                                        (path.clone(), String::new())
                                    }
                                    ProfileSwitchTrigger::GitRepository { name } => {
                                        (name.clone(), String::new())
                                    }
                                    ProfileSwitchTrigger::SshHost { hostname } => {
                                        (hostname.clone(), String::new())
                                    }
                                    ProfileSwitchTrigger::ProcessRunning { name } => {
                                        (name.clone(), String::new())
                                    }
                                    ProfileSwitchTrigger::EnvironmentVariable { key, value } => {
                                        (key.clone(), value.clone())
                                    }
                                };
                                name_in
                                    .update(cx, |s, cx| s.set_value(rule.name.clone(), window, cx));
                                value_in.update(cx, |s, cx| s.set_value(a, window, cx));
                                value2_in.update(cx, |s, cx| s.set_value(b, window, cx));
                                ui_edit(cx, |ui| {
                                    ui.rule = Some(RuleDraft {
                                        id: Some(rule.id),
                                        enabled: rule.is_enabled,
                                        priority: rule.priority,
                                        kind: trigger_kind(&rule.trigger),
                                        profile: rule.profile_name.clone(),
                                    })
                                });
                            }),
                        )
                        .child(
                            small_button(
                                SharedString::from(format!("rule-del-{}", rule.id)),
                                "Delete",
                                chrome,
                            )
                            .on_click(move |_, _, cx| {
                                ui_edit(cx, |ui| ui.confirm_delete_rule = Some(del_id))
                            }),
                        ),
                ),
        );
        if pane.ui.confirm_delete_rule == Some(rule.id) {
            section = section.child(
                div()
                    .flex()
                    .items_center()
                    .gap_2()
                    .text_xs()
                    .child(crate::l10n::tr("Delete this rule?"))
                    .child(small_button("rule-del-yes", "Delete", chrome).on_click(
                        move |_, _, cx| {
                            profiles::edit(cx, |s| s.delete_rule(del_id));
                            ui_edit(cx, |ui| ui.confirm_delete_rule = None);
                        },
                    ))
                    .child(
                        small_button("rule-del-no", "Cancel", chrome)
                            .on_click(|_, _, cx| ui_edit(cx, |ui| ui.confirm_delete_rule = None)),
                    ),
            );
        }
    }
    match &pane.ui.rule {
        None => {
            let default_profile = store
                .profiles
                .first()
                .map(|p| p.name.clone())
                .unwrap_or_default();
            let name_in = pane.rule_name.clone();
            let value_in = pane.rule_value.clone();
            let value2_in = pane.rule_value2.clone();
            section.child(small_button("rule-add", "Add Rule", chrome).on_click(
                move |_, window, cx| {
                    for input in [&name_in, &value_in, &value2_in] {
                        input.update(cx, |s, cx| s.set_value(String::new(), window, cx));
                    }
                    let profile = default_profile.clone();
                    ui_edit(cx, |ui| {
                        ui.rule = Some(RuleDraft {
                            id: None,
                            enabled: true,
                            priority: 0,
                            kind: 0,
                            profile,
                        })
                    });
                },
            ))
        }
        Some(draft) => {
            let kinds = TRIGGER_KINDS.into_iter().enumerate().map(|(i, label)| {
                chip(
                    SharedString::from(format!("rule-kind-{i}")),
                    label,
                    draft.kind == i,
                    chrome,
                )
                .on_click(move |_, _, cx| {
                    ui_edit(cx, |ui| {
                        if let Some(d) = ui.rule.as_mut() {
                            d.kind = i;
                        }
                    })
                })
            });
            let targets = store.profiles.iter().map(|p| {
                let name = p.name.clone();
                chip(
                    SharedString::from(format!("rule-target-{}", p.id)),
                    p.name.clone(),
                    draft.profile == p.name,
                    chrome,
                )
                .on_click(move |_, _, cx| {
                    let name = name.clone();
                    ui_edit(cx, |ui| {
                        if let Some(d) = ui.rule.as_mut() {
                            d.profile = name;
                        }
                    })
                })
            });
            let value_hint = match draft.kind {
                0 => "Directory pattern (~, *, **)",
                1 => "Repository folder name",
                2 => "SSH host name",
                3 => "Process name",
                _ => "Variable name",
            };
            let save_draft = draft.clone();
            let (name_in, value_in, value2_in) = (
                pane.rule_name.clone(),
                pane.rule_value.clone(),
                pane.rule_value2.clone(),
            );
            let enabled = draft.enabled;
            section
                .child(hint("Rule", chrome))
                .child(div().w(px(320.0)).child(Input::new(&pane.rule_name)))
                .child(div().flex().flex_wrap().gap_1().children(kinds))
                .child(hint(value_hint, chrome))
                .child(div().w(px(320.0)).child(Input::new(&pane.rule_value)))
                .when(draft.kind == 4, |d| {
                    d.child(hint("Value", chrome))
                        .child(div().w(px(320.0)).child(Input::new(&pane.rule_value2)))
                })
                .child(hint("Load this profile", chrome))
                .child(div().flex().flex_wrap().gap_1().children(targets))
                .child(row(
                    "Enabled",
                    switch("rule-enabled", enabled, chrome, |on, cx| {
                        ui_edit(cx, |ui| {
                            if let Some(d) = ui.rule.as_mut() {
                                d.enabled = on;
                            }
                        })
                    }),
                    chrome,
                ))
                .child(row(
                    "Priority",
                    div()
                        .flex()
                        .items_center()
                        .gap_2()
                        .child(small_button("rule-prio-dec", "\u{2212}", chrome).on_click(
                            |_, _, cx| {
                                ui_edit(cx, |ui| {
                                    if let Some(d) = ui.rule.as_mut() {
                                        d.priority -= 1;
                                    }
                                })
                            },
                        ))
                        .child(
                            div()
                                .min_w(px(30.0))
                                .text_center()
                                .text_sm()
                                .child(SharedString::from(draft.priority.to_string())),
                        )
                        .child(
                            small_button("rule-prio-inc", "+", chrome).on_click(|_, _, cx| {
                                ui_edit(cx, |ui| {
                                    if let Some(d) = ui.rule.as_mut() {
                                        d.priority += 1;
                                    }
                                })
                            }),
                        ),
                    chrome,
                ))
                .child(
                    div()
                        .flex()
                        .gap_2()
                        .child(small_button("rule-save", "Save Rule", chrome).on_click(
                            move |_, _, cx| {
                                let name = name_in.read(cx).value().trim().to_string();
                                let a = value_in.read(cx).value().trim().to_string();
                                let b = value2_in.read(cx).value().trim().to_string();
                                let Some(trigger) = build_trigger(save_draft.kind, a, b) else {
                                    return;
                                };
                                if name.is_empty() || save_draft.profile.is_empty() {
                                    return;
                                }
                                let draft = save_draft.clone();
                                profiles::edit(cx, |store| {
                                    let mut rule =
                                        ProfileSwitchRule::new(&name, trigger, &draft.profile);
                                    rule.is_enabled = draft.enabled;
                                    rule.priority = draft.priority;
                                    match draft.id {
                                        Some(id) => {
                                            rule.id = id;
                                            store.update_rule(rule);
                                        }
                                        None => store.add_rule(rule),
                                    }
                                });
                                ui_edit(cx, |ui| ui.rule = None);
                            },
                        ))
                        .child(
                            small_button("rule-cancel", "Cancel", chrome)
                                .on_click(|_, _, cx| ui_edit(cx, |ui| ui.rule = None)),
                        ),
                )
        }
    }
}

fn ssh_config_path(cx: &App) -> std::path::PathBuf {
    cx.global::<AppData>().root.home().join(".ssh/config")
}

/// Import entries as saved connections.
fn import_entries(entries: Vec<SSHConfigEntry>, cx: &mut App) {
    let mut added = 0;
    profiles::ssh_edit(cx, |ssh| {
        for entry in &entries {
            ssh.add(SshConnection::from_config_entry(entry));
            added += 1;
        }
    });
    ui_edit(cx, |ui| {
        ui.ssh_status = Some(format!("Imported {added} host(s)."));
        ui.confirm_import_all = false;
    });
}

/// Append saved connections that are not in the config yet.
fn export_connections(cx: &mut App) {
    let path = ssh_config_path(cx);
    let existing: Vec<String> = std::fs::read_to_string(&path)
        .map(|text| {
            ssh_config::parse(&text)
                .into_iter()
                .map(|e| e.host)
                .collect()
        })
        .unwrap_or_default();
    let entries = cx
        .global::<SshState>()
        .0
        .config_entries_to_export(&existing);
    let status = if entries.is_empty() {
        "Every connection is already in the SSH config.".to_string()
    } else {
        let text = format!("\n{}", ssh_config::serialize(&entries));
        let result = path
            .parent()
            .map(std::fs::create_dir_all)
            .transpose()
            .and_then(|_| {
                std::fs::OpenOptions::new()
                    .create(true)
                    .append(true)
                    .open(&path)
            })
            .and_then(|mut file| file.write_all(text.as_bytes()));
        match result {
            Ok(()) => format!("Added {} host(s) to ~/.ssh/config.", entries.len()),
            Err(err) => format!("Could not write ~/.ssh/config: {err}"),
        }
    };
    ui_edit(cx, |ui| ui.ssh_status = Some(status));
}

/// The SSH config sync pane.
pub(in super::super) fn ssh_sync(ctx: &SectionContext) -> gpui::Div {
    let chrome = ctx.chrome;
    let pane = &ctx.view.mine.profiles;
    let entries = &pane.ssh_entries;
    let mut section = titled("SSH Config Sync", chrome).child(row(
        "File watch",
        div()
            .flex()
            .items_center()
            .gap_2()
            .child(
                div()
                    .size(px(8.0))
                    .rounded_full()
                    .bg(match pane.ssh_watch_status() {
                        Some(true) => gpui::hsla(0.36, 0.6, 0.45, 1.0),
                        Some(false) => gpui::hsla(0.0, 0.75, 0.55, 1.0),
                        None => chrome.text_muted,
                    }),
            )
            .child(div().text_sm().child(match pane.ssh_watch_status() {
                Some(true) => "Watching ~/.ssh/config",
                Some(false) => "Not watching",
                None => "Loading SSH config status…",
            })),
        chrome,
    ));
    if let Some(date) = pane.ssh_last_sync_local() {
        let formatted =
            chau7_next_core::l10n::formatters::date_time(chau7_next_core::l10n::current(), date);
        section = section.child(hint_owned(
            crate::l10n::lf("ssh.lastSync", "Last sync: %@", &[formatted.into()]),
            chrome,
        ));
    }
    if let Some(error) = &pane.ssh_error {
        section = section.child(hint_owned(error.clone(), chrome));
    }
    if entries.is_empty() {
        section = section
            .child(hint("No SSH config entries found.", chrome))
            .child(hint("Add hosts to ~/.ssh/config to see them here.", chrome));
    }
    for (i, entry) in entries.iter().enumerate() {
        let wildcard = entry.host.contains('*');
        let import = entry.clone();
        section = section.child(
            div()
                .flex()
                .items_center()
                .justify_between()
                .gap_2()
                .child(
                    div()
                        .flex_1()
                        .min_w_0()
                        .child(
                            div()
                                .text_sm()
                                .child(SharedString::from(entry.host.clone())),
                        )
                        .child(
                            div()
                                .text_xs()
                                .text_color(chrome.text_muted)
                                .child(SharedString::from(entry.display_name())),
                        ),
                )
                .child(
                    small_button(
                        SharedString::from(format!("ssh-import-{i}")),
                        "Import",
                        chrome,
                    )
                    .when(wildcard, |d| d.opacity(0.4))
                    .on_click(move |_, _, cx| {
                        if !wildcard {
                            import_entries(vec![import.clone()], cx);
                        }
                    }),
                ),
        );
    }
    let importable: Vec<SSHConfigEntry> =
        importable_entries(entries).into_iter().cloned().collect();
    let count = importable.len();
    let mut actions = div()
        .flex()
        .items_center()
        .gap_2()
        .child(
            small_button("ssh-refresh", "Refresh", chrome).on_click(|_, _, cx| {
                profiles::ssh_config_sync::refresh(cx);
            }),
        )
        .child(
            small_button("ssh-import-all", "Import All", chrome)
                .when(entries.is_empty(), |d| d.opacity(0.4))
                .on_click(move |_, _, cx| {
                    ui_edit(cx, |ui| ui.confirm_import_all = true);
                }),
        )
        .child(
            small_button("ssh-export", "Export to SSH Config", chrome)
                .when(pane.ssh_saved == 0, |d| d.opacity(0.4))
                .on_click(|_, _, cx| export_connections(cx)),
        );
    if pane.ui.confirm_import_all {
        actions = actions
            .child(div().text_xs().child(SharedString::from(format!(
                "Import {count} SSH hosts into Chau7 Next?"
            ))))
            .child(
                small_button("ssh-import-yes", "Import", chrome)
                    .on_click(move |_, _, cx| import_entries(importable.clone(), cx)),
            )
            .child(
                small_button("ssh-import-no", "Cancel", chrome)
                    .on_click(|_, _, cx| ui_edit(cx, |ui| ui.confirm_import_all = false)),
            );
    }
    section = section.child(actions);
    if let Some(status) = &pane.ui.ssh_status {
        section = section.child(hint_owned(status.clone(), chrome));
    }
    section
}

fn hint_owned(text: String, chrome: Chrome) -> gpui::Div {
    div()
        .text_xs()
        .text_color(chrome.accent)
        .child(SharedString::from(text))
}
