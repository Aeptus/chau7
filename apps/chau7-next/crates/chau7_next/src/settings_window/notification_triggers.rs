//! Notifications > Advanced (`UnifiedTriggerSection`,
//! `TriggerActionsSettingsView.swift`): triggers by category (Core, Shell,
//! AI Coding Apps, App) and source, each with its toggle and action list;
//! the "All AI Sources" group with per-source overrides; adding, editing,
//! enabling and removing actions with the typed fields of the action
//! catalog.

use chau7_next_core::notifications::AiEventSource;
use chau7_next_core::notifications::actions::{
    self as catalog, ConfigFieldType, NotificationActionConfig, NotificationActionType,
};
use chau7_next_core::notifications::settings::NotificationSettings;
use chau7_next_core::notifications::triggers::{
    self, NotificationTrigger, NotificationTriggerDisplay,
};
use gpui::{App, Entity, SharedString, WeakEntity, div, prelude::*, px};
use gpui_kit::component::input::{Input, InputState, Textarea, TextareaState};

use super::notifications::{check, edit_rules, small, switch, with_state};
use super::widgets::{button, chip, description, section as titled};
use super::{SectionContext, SettingsView};

/// One field of the action being edited.
pub(super) enum FieldInput {
    Line(Entity<InputState>),
    Area(Entity<TextareaState>),
    /// Toggles and pickers keep their value here.
    Choice(String),
}

/// The action open in the editor (`ActionConfigSheet`).
pub(super) struct Editing {
    pub trigger_id: String,
    pub action: NotificationActionConfig,
    pub enabled: bool,
    pub fields: Vec<(&'static str, FieldInput)>,
}

/// `TriggerCategory`.
const CATEGORIES: [(&str, &str, &[&str]); 4] = [
    (
        "core",
        "Core",
        &[
            AiEventSource::EVENTS_LOG,
            AiEventSource::TERMINAL_SESSION,
            AiEventSource::HISTORY_MONITOR,
        ],
    ),
    ("shell", "Shell", &[AiEventSource::SHELL]),
    (
        "aiApps",
        "AI Coding Apps",
        &[
            AiEventSource::CLAUDE_CODE,
            AiEventSource::CODEX,
            AiEventSource::CURSOR,
            AiEventSource::WINDSURF,
            AiEventSource::COPILOT,
            AiEventSource::AIDER,
            AiEventSource::CLINE,
            AiEventSource::CONTINUE_AI,
            AiEventSource::RUNTIME,
        ],
    ),
    (
        "app",
        "App",
        &[
            AiEventSource::APP,
            AiEventSource::API_PROXY,
            AiEventSource::UNKNOWN,
        ],
    ),
];

/// Sources of a category with their settings triggers.
fn groups(sources: &[&str]) -> Vec<(&'static str, String, Vec<&'static NotificationTrigger>)> {
    sources
        .iter()
        .filter_map(|raw| {
            let source = AiEventSource::new(*raw);
            let info = triggers::sources().iter().find(|s| s.id == source)?;
            let list: Vec<_> = triggers::triggers_for(&source)
                .into_iter()
                .filter(|t| {
                    t.display_contexts
                        .contains(NotificationTriggerDisplay::SETTINGS)
                })
                .collect();
            (!list.is_empty()).then(|| (info.label_fallback, raw.to_string(), list))
        })
        .collect()
}

fn is_group_trigger(id: &str) -> bool {
    triggers::all_group_trigger_ids().contains(id)
}

/// The action list of a trigger or group trigger id.
fn bindings_mut<'a>(
    r: &'a mut NotificationSettings,
    id: &str,
) -> &'a mut Vec<NotificationActionConfig> {
    let map = if is_group_trigger(id) {
        &mut r.group_action_bindings
    } else {
        &mut r.trigger_action_bindings
    };
    map.entry(id.to_string()).or_default()
}

/// Drops the id's list once empty (`removeActionFromTrigger`,
/// `removeActionFromGroup`).
fn prune(r: &mut NotificationSettings, id: &str) {
    if r.trigger_action_bindings.get(id).is_some_and(Vec::is_empty) {
        r.trigger_action_bindings.remove(id);
    }
    if r.group_action_bindings.get(id).is_some_and(Vec::is_empty) {
        r.group_action_bindings.remove(id);
    }
}

fn actions_of(r: &NotificationSettings, id: &str) -> Vec<NotificationActionConfig> {
    let map = if is_group_trigger(id) {
        &r.group_action_bindings
    } else {
        &r.trigger_action_bindings
    };
    map.get(id).cloned().unwrap_or_default()
}

/// `enableAll` / `disableAll` of a category.
fn set_category(key: &str, sources: &[&str], on: bool, cx: &mut App) {
    let list: Vec<&'static NotificationTrigger> =
        groups(sources).into_iter().flat_map(|g| g.2).collect();
    let ai = key == "aiApps";
    edit_rules(cx, |r| {
        if ai {
            let group = triggers::ai_coding_group();
            for t in &group.trigger_types {
                r.trigger_state.set_group_enabled(on, &group.id, t);
            }
            for t in &list {
                r.trigger_state.remove_override(t);
            }
        } else {
            for t in &list {
                r.trigger_state.set_enabled(on, t);
            }
        }
    });
}

pub(super) fn triggers(ctx: &SectionContext) -> gpui::Div {
    let chrome = ctx.chrome;
    let rules = &ctx.settings.notifications.rules;
    let state = &ctx.view.notif;
    let view = ctx.view.entity.clone();
    let mut block = titled("Notification Triggers", chrome).child(description(
        "Enable triggers and configure what happens when they fire:",
        chrome,
    ));
    for (key, label, sources) in CATEGORIES {
        let list = groups(sources);
        if list.is_empty() {
            continue;
        }
        let all: Vec<_> = list.iter().flat_map(|g| g.2.iter()).collect();
        let enabled = all
            .iter()
            .filter(|t| rules.trigger_state.is_enabled(t))
            .count();
        let open = state.expanded_categories.contains(key);
        let v = view.clone();
        let header = div()
            .flex()
            .items_center()
            .gap_2()
            .py_1()
            .child(
                div()
                    .id(SharedString::from(format!("cat-{key}")))
                    .flex()
                    .flex_1()
                    .items_center()
                    .gap_2()
                    .cursor_pointer()
                    .child(div().text_xs().child(if open { "▾" } else { "▸" }))
                    .child(
                        div()
                            .text_sm()
                            .font_weight(gpui::FontWeight::SEMIBOLD)
                            .child(label),
                    )
                    .child(small(format!("({enabled}/{})", all.len()), chrome))
                    .on_click(move |_, _, cx| {
                        with_state(&v, cx, |s| {
                            if !s.expanded_categories.remove(key) {
                                s.expanded_categories.insert(key);
                            }
                        })
                    }),
            )
            .child(
                button(SharedString::from(format!("cat-all-{key}")), "All", chrome)
                    .on_click(move |_, _, cx| set_category(key, sources, true, cx)),
            )
            .child(
                button(
                    SharedString::from(format!("cat-none-{key}")),
                    "None",
                    chrome,
                )
                .on_click(move |_, _, cx| set_category(key, sources, false, cx)),
            );
        let mut cat = div()
            .flex()
            .flex_col()
            .rounded_md()
            .border_1()
            .border_color(chrome.border)
            .px_2()
            .mb_1()
            .child(header);
        if open {
            if key == "aiApps" {
                cat = cat.child(ai_group(ctx));
                cat = cat.child(overrides(ctx, &list));
            } else {
                for (label, source, triggers) in &list {
                    cat = cat.child(source_block(ctx, label, source, triggers, false));
                }
            }
        }
        block = block.child(cat);
    }
    block
}

/// "All AI Sources" (`AICodingGroupSection`).
fn ai_group(ctx: &SectionContext) -> gpui::Div {
    let chrome = ctx.chrome;
    let rules = &ctx.settings.notifications.rules;
    let group = triggers::ai_coding_group();
    let mut block = div().flex().flex_col().pb_2().child(
        div()
            .text_xs()
            .font_weight(gpui::FontWeight::SEMIBOLD)
            .child(crate::l10n::tr("All AI Sources")),
    );
    for info in triggers::group_trigger_infos(group) {
        let on = rules.trigger_state.is_group_enabled(
            &group.id,
            &info.trigger_type,
            info.default_enabled,
        );
        let overrides = triggers::all()
            .iter()
            .filter(|t| {
                group.contains(&t.source)
                    && t.trigger_type == info.trigger_type
                    && rules.trigger_state.has_per_trigger_override(t)
            })
            .count();
        let ty = info.trigger_type.clone();
        let gid = group.id.clone();
        let toggle = check(
            SharedString::from(format!("grp-{}", info.id)),
            on,
            true,
            chrome,
            move |v, cx| edit_rules(cx, |r| r.trigger_state.set_group_enabled(v, &gid, &ty)),
        );
        let extra = (overrides > 0)
            .then(|| crate::l10n::count("notifications.overrideCount", "%d overrides", overrides));
        block = block.child(trigger_row(
            ctx,
            &info.id,
            toggle,
            info.label_fallback.clone(),
            Some(info.description_fallback.clone()),
            on,
            extra,
            None,
            "No group actions configured. Using default notification.",
        ));
    }
    block
}

/// "Per-Source Overrides" (`PerSourceOverridesSection`).
fn overrides(
    ctx: &SectionContext,
    list: &[(&'static str, String, Vec<&'static NotificationTrigger>)],
) -> gpui::Div {
    let chrome = ctx.chrome;
    let view = ctx.view.entity.clone();
    let open = ctx.view.notif.overrides_open;
    let mut block = div().flex().flex_col().pb_2().child(
        div()
            .id("notif-overrides")
            .flex()
            .items_center()
            .gap_2()
            .cursor_pointer()
            .child(div().text_xs().child(if open { "▾" } else { "▸" }))
            .child(small("Per-Source Overrides", chrome))
            .on_click(move |_, _, cx| {
                with_state(&view, cx, |s| s.overrides_open = !s.overrides_open)
            }),
    );
    if open {
        for (label, source, triggers) in list {
            block = block.child(source_block(ctx, label, source, triggers, true));
        }
    }
    block
}

/// One source with its triggers (`UnifiedSourceSection`, `OverrideSourceSection`).
fn source_block(
    ctx: &SectionContext,
    label: &str,
    source: &str,
    list: &[&'static NotificationTrigger],
    is_override: bool,
) -> gpui::Div {
    let chrome = ctx.chrome;
    let rules = &ctx.settings.notifications.rules;
    let view = ctx.view.entity.clone();
    let open = ctx.view.notif.expanded_sources.contains(source);
    let enabled = list
        .iter()
        .filter(|t| rules.trigger_state.is_enabled(t))
        .count();
    let key = source.to_string();
    let mut block = div().flex().flex_col().pl_2().child(
        div()
            .id(SharedString::from(format!(
                "src-{}{source}",
                if is_override { "o-" } else { "" }
            )))
            .flex()
            .items_center()
            .gap_2()
            .py_0p5()
            .cursor_pointer()
            .child(div().text_xs().child(if open { "▾" } else { "▸" }))
            .child(
                div()
                    .text_xs()
                    .font_weight(gpui::FontWeight::MEDIUM)
                    .child(label.to_string()),
            )
            .child(small(format!("({enabled}/{})", list.len()), chrome))
            .on_click(move |_, _, cx| {
                let key = key.clone();
                with_state(&view, cx, |s| {
                    if !s.expanded_sources.remove(&key) {
                        s.expanded_sources.insert(key);
                    }
                })
            }),
    );
    if !open {
        return block;
    }
    for trigger in list {
        let on = rules.trigger_state.is_enabled(trigger);
        let has_override = rules.trigger_state.has_per_trigger_override(trigger);
        let t: &'static NotificationTrigger = trigger;
        let toggle = check(
            SharedString::from(format!("trg-{}", t.id)),
            on,
            true,
            chrome,
            move |v, cx| edit_rules(cx, |r| r.trigger_state.set_enabled(v, t)),
        );
        let (subtitle, reset) = if is_override && !has_override {
            (Some("Inherited from group".to_string()), None)
        } else {
            (
                Some(t.description_fallback.clone()).filter(|d| !d.is_empty()),
                (is_override && has_override).then_some(t),
            )
        };
        block = block.child(trigger_row(
            ctx,
            &t.id,
            toggle,
            t.label_fallback.clone(),
            subtitle,
            on,
            None,
            reset,
            "No actions configured. Using default notification.",
        ));
    }
    block
}

/// A trigger line: toggle, label, action count, and when expanded its
/// actions (`UnifiedTriggerRow`, `GroupTriggerRow`, `OverrideTriggerRow`).
#[allow(clippy::too_many_arguments)]
fn trigger_row(
    ctx: &SectionContext,
    id: &str,
    toggle: gpui::Stateful<gpui::Div>,
    label: String,
    subtitle: Option<String>,
    on: bool,
    extra: Option<String>,
    reset: Option<&'static NotificationTrigger>,
    empty_text: &'static str,
) -> gpui::Div {
    let chrome = ctx.chrome;
    let state = &ctx.view.notif;
    let view = ctx.view.entity.clone();
    let actions = actions_of(&ctx.settings.notifications.rules, id);
    let open = state.expanded_trigger.as_deref() == Some(id);
    let key = id.to_string();
    let header = div()
        .flex()
        .items_center()
        .gap_2()
        .px_1()
        .py_1()
        .rounded_md()
        .when(open, |d| d.bg(chrome.text.opacity(0.04)))
        .child(toggle)
        .child(
            div()
                .id(SharedString::from(format!("trow-{id}")))
                .flex()
                .flex_1()
                .items_center()
                .gap_2()
                .cursor_pointer()
                .child(
                    div()
                        .flex()
                        .flex_col()
                        .flex_1()
                        .min_w_0()
                        .child(
                            div()
                                .text_xs()
                                .text_color(if on { chrome.text } else { chrome.text_muted })
                                .child(label),
                        )
                        .when_some(subtitle, |d, s| d.child(small(s, chrome))),
                )
                .when_some(extra, |d, e| {
                    d.child(
                        div()
                            .text_xs()
                            .text_color(gpui::hsla(0.08, 0.9, 0.55, 1.0))
                            .child(e),
                    )
                })
                .when(!actions.is_empty(), |d| {
                    d.child(
                        div()
                            .px_1p5()
                            .rounded_md()
                            .text_xs()
                            .text_color(chrome.accent)
                            .bg(chrome.accent.opacity(0.2))
                            .child(actions.len().to_string()),
                    )
                })
                .child(div().size(px(8.0)).rounded_full().bg(if on {
                    gpui::hsla(0.35, 0.6, 0.45, 1.0)
                } else {
                    chrome.border
                }))
                .child(div().text_xs().child(if open { "▾" } else { "▸" }))
                .on_click(move |_, _, cx| {
                    let key = key.clone();
                    with_state(&view, cx, |s| {
                        s.expanded_trigger = if s.expanded_trigger.as_deref() == Some(&key) {
                            None
                        } else {
                            Some(key)
                        };
                        s.picker_for = None;
                    })
                }),
        )
        .when_some(reset, |d, t| {
            d.child(
                div()
                    .id(SharedString::from(format!("reset-{}", t.id)))
                    .text_xs()
                    .cursor_pointer()
                    .text_color(gpui::hsla(0.08, 0.9, 0.55, 1.0))
                    .child(crate::l10n::tr("Reset"))
                    .on_click(move |_, _, cx| {
                        edit_rules(cx, |r| r.trigger_state.remove_override(t))
                    }),
            )
        });
    let mut row = div().flex().flex_col().child(header);
    if open {
        row = row.child(actions_panel(ctx, id, &actions, empty_text));
    }
    row
}

/// `actionConfigSummary`.
fn summary(action: &NotificationActionConfig) -> Option<String> {
    use NotificationActionType as T;
    let v = |k: &str| action.config_value(k).map(str::to_string);
    match action.action_type {
        T::PlaySound | T::VoiceAnnounce => v(if action.action_type == T::PlaySound {
            "sound"
        } else {
            "voice"
        }),
        T::RunScript => v("script").map(|s| {
            let short: String = s.chars().take(40).collect();
            if s.chars().count() > 40 {
                format!("{short}...")
            } else {
                short
            }
        }),
        T::Webhook | T::OpenUrl => v("url"),
        T::SendSlack | T::SendDiscord => {
            v("webhookUrl").map(|u| format!("{}...", u.chars().take(30).collect::<String>()))
        }
        T::DockerBump => v("container"),
        T::DockerCompose => v("operation"),
        _ => None,
    }
}

fn actions_panel(
    ctx: &SectionContext,
    trigger_id: &str,
    actions: &[NotificationActionConfig],
    empty_text: &'static str,
) -> gpui::Div {
    let chrome = ctx.chrome;
    let state = &ctx.view.notif;
    let view = ctx.view.entity.clone();
    let mut panel = div()
        .flex()
        .flex_col()
        .gap_1()
        .pl_6()
        .py_1()
        .bg(chrome.text.opacity(0.02));
    if actions.is_empty() {
        panel = panel.child(small(format!("ⓘ {empty_text}"), chrome));
    }
    for action in actions {
        let info = catalog::action_for(action.action_type);
        let label = info
            .map(|i| i.label_fallback.to_string())
            .unwrap_or_else(|| action.action_type.raw_value().to_string());
        let id = action.id;
        let tid = trigger_id.to_string();
        let tid_del = trigger_id.to_string();
        let tid_edit = trigger_id.to_string();
        let edit_action = action.clone();
        let v = view.clone();
        let editing_this = state
            .editing
            .as_ref()
            .is_some_and(|e| e.action.id == id && e.trigger_id == trigger_id);
        panel = panel.child(
            div()
                .flex()
                .items_center()
                .gap_2()
                .child(switch(
                    SharedString::from(format!("act-on-{id}")),
                    action.enabled,
                    chrome,
                    move |on, cx| {
                        let tid = tid.clone();
                        edit_rules(cx, |r| {
                            if let Some(a) = bindings_mut(r, &tid).iter_mut().find(|a| a.id == id) {
                                a.enabled = on;
                            }
                        })
                    },
                ))
                .child(
                    div()
                        .flex()
                        .flex_col()
                        .flex_1()
                        .min_w_0()
                        .child(
                            div()
                                .text_xs()
                                .text_color(if action.enabled {
                                    chrome.text
                                } else {
                                    chrome.text_muted
                                })
                                .child(label),
                        )
                        .when_some(summary(action), |d, s| d.child(small(s, chrome))),
                )
                .child(
                    button(SharedString::from(format!("act-edit-{id}")), "Edit", chrome).on_click(
                        move |_, window, cx| {
                            let editing = start_editing(&tid_edit, &edit_action, window, cx);
                            with_state(&v, cx, |s| s.editing = Some(editing));
                        },
                    ),
                )
                .child(
                    button(
                        SharedString::from(format!("act-del-{id}")),
                        "Remove",
                        chrome,
                    )
                    .text_color(chrome.danger)
                    .on_click(move |_, _, cx| {
                        let tid = tid_del.clone();
                        edit_rules(cx, |r| {
                            bindings_mut(r, &tid).retain(|a| a.id != id);
                            prune(r, &tid);
                        })
                    }),
                ),
        );
        if editing_this {
            panel = panel.child(editor(ctx));
        }
    }
    let picker_open = state.picker_for.as_deref() == Some(trigger_id);
    let v = view.clone();
    let tid = trigger_id.to_string();
    panel = panel.child(
        div().flex().child(
            button(
                SharedString::from(format!("act-add-{trigger_id}")),
                "+ Add Action",
                chrome,
            )
            .text_color(chrome.accent)
            .on_click(move |_, _, cx| {
                let tid = tid.clone();
                with_state(&v, cx, |s| {
                    s.picker_for = if s.picker_for.as_deref() == Some(&tid) {
                        None
                    } else {
                        Some(tid)
                    }
                })
            }),
        ),
    );
    if picker_open {
        panel = panel.child(picker(ctx, trigger_id));
    }
    if let Some(editing) = &state.editing
        && editing.trigger_id == trigger_id
        && !actions.iter().any(|a| a.id == editing.action.id)
    {
        panel = panel.child(editor(ctx));
    }
    panel
}

/// `ActionPickerSheet`: the catalog by category.
fn picker(ctx: &SectionContext, trigger_id: &str) -> gpui::Div {
    let chrome = ctx.chrome;
    let view = ctx.view.entity.clone();
    let mut panel = div()
        .flex()
        .flex_col()
        .gap_1()
        .p_2()
        .rounded_md()
        .border_1()
        .border_color(chrome.border)
        .child(
            div()
                .text_xs()
                .font_weight(gpui::FontWeight::SEMIBOLD)
                .child(crate::l10n::tr("Select Action")),
        );
    for (category, infos) in catalog::by_category() {
        panel = panel.child(small(category.display_name(), chrome));
        let chips = infos.into_iter().map(|info| {
            let v = view.clone();
            let tid = trigger_id.to_string();
            let action_type = info.action_type;
            let requires = info.requires_config;
            chip(
                SharedString::from(format!("pick-{trigger_id}-{}", action_type.raw_value())),
                info.label_fallback,
                false,
                chrome,
            )
            .cursor_pointer()
            .on_click(move |_, window, cx| {
                let action = NotificationActionConfig::new(action_type);
                let tid2 = tid.clone();
                let added = action.clone();
                edit_rules(cx, |r| bindings_mut(r, &tid2).push(added));
                let editing = requires.then(|| start_editing(&tid, &action, window, cx));
                with_state(&v, cx, |s| {
                    s.picker_for = None;
                    if editing.is_some() {
                        s.editing = editing;
                    }
                });
            })
        });
        panel = panel.child(div().flex().flex_wrap().gap_1().children(chips));
    }
    panel
}

fn start_editing(
    trigger_id: &str,
    action: &NotificationActionConfig,
    window: &mut gpui::Window,
    cx: &mut App,
) -> Editing {
    let fields = catalog::action_for(action.action_type)
        .map(|info| info.config_fields)
        .unwrap_or(&[]);
    let inputs = fields
        .iter()
        .map(|field| {
            let value = action
                .config_value(field.id)
                .map(str::to_string)
                .or_else(|| field.default_value.map(str::to_string))
                .unwrap_or_default();
            let input = match field.field_type {
                ConfigFieldType::Toggle
                | ConfigFieldType::Picker
                | ConfigFieldType::SoundPicker => FieldInput::Choice(
                    if value.is_empty() && field.field_type == ConfigFieldType::SoundPicker {
                        "default".into()
                    } else {
                        value
                    },
                ),
                ConfigFieldType::TextArea => {
                    let area = cx.new(|cx| TextareaState::new(window, cx));
                    area.update(cx, |a, cx| a.set_value(value, window, cx));
                    FieldInput::Area(area)
                }
                _ => {
                    let placeholder = field.placeholder.unwrap_or("").to_string();
                    let masked = field.field_type == ConfigFieldType::SecretText;
                    FieldInput::Line(cx.new(|cx| {
                        InputState::new(window, cx)
                            .placeholder(placeholder)
                            .masked(masked)
                            .default_value(value)
                    }))
                }
            };
            (field.id, input)
        })
        .collect();
    Editing {
        trigger_id: trigger_id.to_string(),
        action: action.clone(),
        enabled: action.enabled,
        fields: inputs,
    }
}

/// System sound names for the sound picker.
fn system_sounds() -> Vec<String> {
    let mut names: Vec<String> = std::fs::read_dir(crate::platform::sound::SYSTEM_SOUNDS_DIR)
        .map(|dir| {
            dir.filter_map(|e| e.ok())
                .filter_map(|e| {
                    e.file_name()
                        .to_string_lossy()
                        .strip_suffix(".aiff")
                        .map(str::to_string)
                })
                .collect()
        })
        .unwrap_or_default();
    names.sort();
    names
}

fn set_choice(view: &WeakEntity<SettingsView>, field: &'static str, value: String, cx: &mut App) {
    with_state(view, cx, |s| {
        if let Some(editing) = s.editing.as_mut()
            && let Some((_, FieldInput::Choice(v))) =
                editing.fields.iter_mut().find(|(id, _)| *id == field)
        {
            *v = value;
        }
    });
}

/// `ActionConfigSheet`, inline.
fn editor(ctx: &SectionContext) -> gpui::Div {
    let chrome = ctx.chrome;
    let view = ctx.view.entity.clone();
    let Some(editing) = &ctx.view.notif.editing else {
        return div();
    };
    let info = catalog::action_for(editing.action.action_type);
    let title = info.map(|i| i.label_fallback).unwrap_or("Action");
    let v = view.clone();
    let mut panel = div()
        .flex()
        .flex_col()
        .gap_2()
        .p_3()
        .rounded_md()
        .border_1()
        .border_color(chrome.accent.opacity(0.6))
        .child(
            div()
                .text_sm()
                .font_weight(gpui::FontWeight::SEMIBOLD)
                .child(title),
        )
        .child(
            div()
                .flex()
                .items_center()
                .gap_2()
                .child(check(
                    "edit-enabled",
                    editing.enabled,
                    true,
                    chrome,
                    move |on, cx| {
                        with_state(&v, cx, |s| {
                            if let Some(e) = s.editing.as_mut() {
                                e.enabled = on;
                            }
                        })
                    },
                ))
                .child(div().text_xs().child(crate::l10n::tr("Action Enabled"))),
        );
    if let Some(info) = info {
        panel = panel.child(small(info.description_fallback, chrome));
        if info.config_fields.is_empty() {
            panel = panel.child(small(
                "This action requires no additional configuration.",
                chrome,
            ));
        }
        for field in info.config_fields {
            let Some((_, input)) = editing.fields.iter().find(|(id, _)| *id == field.id) else {
                continue;
            };
            let label = div()
                .flex()
                .gap_1()
                .text_xs()
                .font_weight(gpui::FontWeight::MEDIUM)
                .child(field.label_fallback)
                .when(field.required, |d| {
                    d.child(div().text_color(chrome.danger).child("*"))
                });
            let control: gpui::AnyElement = match input {
                FieldInput::Line(input) => div()
                    .w(px(340.0))
                    .child(Input::new(input))
                    .into_any_element(),
                FieldInput::Area(area) => div()
                    .w(px(340.0))
                    .child(Textarea::new(area).h(px(70.0)))
                    .into_any_element(),
                FieldInput::Choice(value) => {
                    let value = value.clone();
                    match field.field_type {
                        ConfigFieldType::Toggle => {
                            let on = value.to_lowercase() == "true" || value == "1";
                            let v = view.clone();
                            let id = field.id;
                            check(
                                SharedString::from(format!("edit-{id}")),
                                on,
                                true,
                                chrome,
                                move |on, cx| {
                                    set_choice(&v, id, if on { "true" } else { "false" }.into(), cx)
                                },
                            )
                            .into_any_element()
                        }
                        ConfigFieldType::SoundPicker => {
                            let mut names = vec!["default".to_string()];
                            names.extend(system_sounds());
                            let chips = names.into_iter().map(|name| {
                                let v = view.clone();
                                let id = field.id;
                                let label = if name == "default" {
                                    "Default".to_string()
                                } else {
                                    name.clone()
                                };
                                chip(
                                    SharedString::from(format!("edit-{id}-{name}")),
                                    label,
                                    value == name,
                                    chrome,
                                )
                                .cursor_pointer()
                                .on_click(move |_, _, cx| {
                                    crate::notifications::executor::play_sound_named(&name, 1.0);
                                    set_choice(&v, id, name.clone(), cx)
                                })
                            });
                            div()
                                .flex()
                                .flex_wrap()
                                .gap_1()
                                .max_w(px(420.0))
                                .children(chips)
                                .into_any_element()
                        }
                        _ => {
                            let chips = field.options.unwrap_or(&[]).iter().map(|option| {
                                let v = view.clone();
                                let id = field.id;
                                let option_id = option.id.to_string();
                                chip(
                                    SharedString::from(format!("edit-{id}-{}", option.id)),
                                    option.label,
                                    value == option.id,
                                    chrome,
                                )
                                .cursor_pointer()
                                .on_click(move |_, _, cx| set_choice(&v, id, option_id.clone(), cx))
                            });
                            div()
                                .flex()
                                .flex_wrap()
                                .gap_1()
                                .children(chips)
                                .into_any_element()
                        }
                    }
                }
            };
            panel = panel.child(div().flex().flex_col().gap_1().child(label).child(control));
        }
    }
    let v_cancel = view.clone();
    let v_save = view.clone();
    panel.child(
        div()
            .flex()
            .gap_2()
            .justify_end()
            .child(
                button("edit-cancel", "Cancel", chrome)
                    .on_click(move |_, _, cx| with_state(&v_cancel, cx, |s| s.editing = None)),
            )
            .child(
                button("edit-save", "Save", chrome)
                    .text_color(chrome.accent)
                    .on_click(move |_, _, cx| save_editing(&v_save, cx)),
            ),
    )
}

/// `saveAndDismiss`: empty values are dropped from the config.
fn save_editing(view: &WeakEntity<SettingsView>, cx: &mut App) {
    let Some(editing) = view
        .upgrade()
        .and_then(|v| v.update(cx, |v, _| v.notif.editing.take()))
    else {
        return;
    };
    let mut action = editing.action.clone();
    action.enabled = editing.enabled;
    action.config.clear();
    for (id, input) in &editing.fields {
        let value = match input {
            FieldInput::Line(i) => i.read(cx).value().to_string(),
            FieldInput::Area(a) => a.read(cx).value().to_string(),
            FieldInput::Choice(v) => v.clone(),
        };
        if !value.is_empty() {
            action.config.insert(id.to_string(), value);
        }
    }
    let tid = editing.trigger_id.clone();
    edit_rules(cx, |r| {
        if let Some(a) = bindings_mut(r, &tid).iter_mut().find(|a| a.id == action.id) {
            *a = action;
        }
        prune(r, &tid);
    });
    cx.refresh_windows();
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn categories_cover_every_settings_trigger() {
        let listed: usize = CATEGORIES
            .iter()
            .map(|(_, _, s)| groups(s).iter().map(|g| g.2.len()).sum::<usize>())
            .sum();
        let all = triggers::all()
            .iter()
            .filter(|t| {
                t.display_contexts
                    .contains(NotificationTriggerDisplay::SETTINGS)
            })
            .count();
        assert_eq!(listed, all);
    }

    #[test]
    fn bindings_go_to_trigger_or_group() {
        let mut r = NotificationSettings::default();
        bindings_mut(&mut r, "shell.command_failed").push(NotificationActionConfig::new(
            NotificationActionType::DockBounce,
        ));
        assert_eq!(r.trigger_action_bindings["shell.command_failed"].len(), 1);
        bindings_mut(&mut r, "ai_coding.idle").clear();
        prune(&mut r, "ai_coding.idle");
        assert!(!r.group_action_bindings.contains_key("ai_coding.idle"));
        assert!(r.group_action_bindings.contains_key("ai_coding.finished"));
        bindings_mut(&mut r, "shell.command_failed").clear();
        prune(&mut r, "shell.command_failed");
        assert!(r.trigger_action_bindings.is_empty());
        assert_eq!(
            summary(
                &NotificationActionConfig::new(NotificationActionType::RunScript)
                    .with_config([("script", "x".repeat(50))])
            )
            .unwrap()
            .len(),
            43
        );
    }
}
