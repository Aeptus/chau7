//! MCP Control (`MCPSettingsView.swift`): enable, approval, tab limit,
//! command permissions (mode, allowed and blocked commands), tab indicator,
//! and MCP profiles with their editor (a sheet in Swift, inline here).

use chau7_next_core::mcp_profile::{MCPPermissionMode, MCPProfile};
use chau7_next_core::profile_rules::ProfileSwitchTrigger;
use gpui::{App, Context, Entity, Global, SharedString, Subscription, Window, div, prelude::*, px};
use gpui_kit::component::input::{Input, InputEvent, InputState};
use uuid::Uuid;

use super::widgets::{chip, description, row, section as titled, stepper, toggle};
use super::{SectionContext, SettingsView, update};
use crate::settings::mcp::ABSOLUTE_MAX_TABS;
use crate::theme::Chrome;

/// Swift `triggerTypes` of the profile editor.
const TRIGGER_KINDS: [&str; 5] = [
    "Directory",
    "Git Repository",
    "SSH Host",
    "Process",
    "Environment Variable",
];

/// The profile being edited (`MCPProfileEditorView` state).
#[derive(Debug, Clone, PartialEq)]
pub struct ProfileDraft {
    /// `None` for a new profile.
    pub id: Option<Uuid>,
    pub enabled: bool,
    pub priority: i64,
    pub kind: usize,
    pub mode: MCPPermissionMode,
    pub allowed: Vec<String>,
    pub blocked: Vec<String>,
    /// Kept as is (the Swift editor has no control for it).
    pub agent_allowlist: Vec<String>,
}

impl ProfileDraft {
    fn new() -> Self {
        Self {
            id: None,
            enabled: true,
            priority: 0,
            kind: 0,
            mode: MCPPermissionMode::AskUnlisted,
            allowed: Vec::new(),
            blocked: Vec::new(),
            agent_allowlist: Vec::new(),
        }
    }
}

/// Open editor, shared by the section functions (they cannot reach the
/// window's `Context`).
#[derive(Debug, Clone, Default, PartialEq)]
pub struct McpUi {
    pub draft: Option<ProfileDraft>,
}

impl Global for McpUi {}

fn ui_edit(cx: &mut App, change: impl FnOnce(&mut McpUi)) {
    change(cx.default_global::<McpUi>());
    cx.refresh_windows();
}

fn draft_edit(cx: &mut App, change: impl FnOnce(&mut ProfileDraft)) {
    ui_edit(cx, |ui| {
        if let Some(draft) = ui.draft.as_mut() {
            change(draft);
        }
    });
}

/// The text fields of the section.
pub(super) struct McpInputs {
    allowed: Entity<InputState>,
    blocked: Entity<InputState>,
    name: Entity<InputState>,
    value: Entity<InputState>,
    env_key: Entity<InputState>,
    profile_allowed: Entity<InputState>,
    profile_blocked: Entity<InputState>,
    /// A copy of [`McpUi`], refreshed on render.
    ui: McpUi,
    _subscriptions: Vec<Subscription>,
}

/// `addCommand`: trimmed, lowercased, once.
fn add_command(list: &mut Vec<String>, text: &str) {
    let command = text.trim().to_lowercase();
    if !command.is_empty() && !list.contains(&command) {
        list.push(command);
    }
}

/// Which list an input adds to.
#[derive(Clone, Copy)]
enum ListTarget {
    GlobalAllowed,
    GlobalBlocked,
    DraftAllowed,
    DraftBlocked,
}

fn add_to(target: ListTarget, text: &str, cx: &mut App) {
    match target {
        ListTarget::GlobalAllowed => update(cx, |s| add_command(&mut s.mcp.allowed_commands, text)),
        ListTarget::GlobalBlocked => update(cx, |s| add_command(&mut s.mcp.blocked_commands, text)),
        ListTarget::DraftAllowed => draft_edit(cx, |d| add_command(&mut d.allowed, text)),
        ListTarget::DraftBlocked => draft_edit(cx, |d| add_command(&mut d.blocked, text)),
    }
}

/// Add the input's text to its list and clear it.
fn commit(input: &Entity<InputState>, target: ListTarget, window: &mut Window, cx: &mut App) {
    let text = input.read(cx).value().to_string();
    add_to(target, &text, cx);
    input.update(cx, |s, cx| s.set_value(String::new(), window, cx));
}

impl McpInputs {
    pub(super) fn new(window: &mut Window, cx: &mut Context<SettingsView>) -> Self {
        let mut subs = Vec::new();
        let mut list_input =
            |placeholder: &'static str, target: ListTarget, cx: &mut Context<SettingsView>| {
                let input = cx.new(|cx| InputState::new(window, cx).placeholder(placeholder));
                subs.push(cx.subscribe_in(
                    &input,
                    window,
                    move |_, input, event: &InputEvent, window, cx| {
                        if matches!(event, InputEvent::PressEnter { .. }) {
                            commit(input, target, window, cx);
                        }
                    },
                ));
                input
            };
        let allowed = list_input("e.g. git, ls, cat", ListTarget::GlobalAllowed, cx);
        let blocked = list_input("e.g. rm, sudo, curl", ListTarget::GlobalBlocked, cx);
        let profile_allowed = list_input("command", ListTarget::DraftAllowed, cx);
        let profile_blocked = list_input("command", ListTarget::DraftBlocked, cx);
        let plain =
            |placeholder: &'static str, window: &mut Window, cx: &mut Context<SettingsView>| {
                cx.new(|cx| InputState::new(window, cx).placeholder(placeholder))
            };
        Self {
            allowed,
            blocked,
            name: plain("Profile Name", window, cx),
            value: plain("Value", window, cx),
            env_key: plain("Key", window, cx),
            profile_allowed,
            profile_blocked,
            ui: McpUi::default(),
            _subscriptions: subs,
        }
    }

    pub(super) fn refresh(&mut self, cx: &App) {
        self.ui = cx.try_global::<McpUi>().cloned().unwrap_or_default();
    }
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

/// `buildTrigger`; `None` while the value is empty (Save is disabled).
fn build_trigger(kind: usize, value: &str, key: &str) -> Option<ProfileSwitchTrigger> {
    let value = value.trim().to_string();
    if value.is_empty() {
        return None;
    }
    Some(match kind {
        1 => ProfileSwitchTrigger::GitRepository { name: value },
        2 => ProfileSwitchTrigger::SshHost { hostname: value },
        3 => ProfileSwitchTrigger::ProcessRunning { name: value },
        4 => ProfileSwitchTrigger::EnvironmentVariable {
            key: key.trim().to_string(),
            value,
        },
        _ => ProfileSwitchTrigger::Directory { path: value },
    })
}

/// `triggerPlaceholder`.
fn trigger_placeholder(kind: usize) -> &'static str {
    match kind {
        0 => "~/projects/myapp",
        1 => "my-repo",
        2 => "prod-server.example.com",
        3 => "node",
        _ => "",
    }
}

/// Swift explanation under the lists for each mode.
fn mode_description(mode: MCPPermissionMode) -> &'static str {
    match mode {
        MCPPermissionMode::AllowAll => {
            "All commands run immediately except those in the blocked list."
        }
        MCPPermissionMode::Allowlist => {
            "Only commands in the allowed list run. Unlisted commands are denied."
        }
        MCPPermissionMode::AskUnlisted => "Commands not in either list will prompt for approval.",
        MCPPermissionMode::AuditOnly => {
            "All commands run but unlisted ones are logged for audit review."
        }
    }
}

fn small_button(
    id: impl Into<gpui::ElementId>,
    label: impl Into<SharedString>,
    chrome: Chrome,
) -> gpui::Stateful<gpui::Div> {
    super::mine::small_button(id, label, chrome)
}

/// Tag chips with a remove button (`MCPCommandFlowLayout`).
fn command_chips(
    prefix: &'static str,
    commands: &[String],
    chrome: Chrome,
    remove: fn(&mut App, &str),
) -> gpui::Div {
    div()
        .flex()
        .flex_wrap()
        .gap(px(6.0))
        .children(commands.iter().enumerate().map(|(i, cmd)| {
            let cmd_owned = cmd.clone();
            div()
                .flex()
                .items_center()
                .gap_1()
                .px_2()
                .py_1()
                .rounded_md()
                .bg(chrome.tab_bg)
                .text_xs()
                .child(
                    div()
                        .font_family("Menlo")
                        .child(SharedString::from(cmd.clone())),
                )
                .child(
                    div()
                        .id(SharedString::from(format!("{prefix}-del-{i}")))
                        .cursor_pointer()
                        .text_color(chrome.text_muted)
                        .hover(|d| d.text_color(chrome.text))
                        .child("\u{2715}")
                        .on_click(move |_, _, cx| remove(cx, &cmd_owned)),
                )
        }))
}

/// Title, chips, field and Add button of one command list.
#[allow(clippy::too_many_arguments)]
fn command_list(
    prefix: &'static str,
    title: &'static str,
    help: &'static str,
    commands: &[String],
    input: &Entity<InputState>,
    target: ListTarget,
    remove: fn(&mut App, &str),
    chrome: Chrome,
) -> gpui::Div {
    let add_input = input.clone();
    let mut list = div()
        .flex()
        .flex_col()
        .gap_1p5()
        .pl_1()
        .child(div().text_sm().child(title));
    if !help.is_empty() {
        list = list.child(description(help, chrome));
    }
    if !commands.is_empty() {
        list = list.child(command_chips(prefix, commands, chrome, remove));
    }
    list.child(
        div()
            .flex()
            .items_center()
            .gap(px(6.0))
            .child(div().w(px(260.0)).child(Input::new(input)))
            .child(
                small_button(SharedString::from(format!("{prefix}-add")), "Add", chrome)
                    .on_click(move |_, window, cx| commit(&add_input, target, window, cx)),
            ),
    )
}

fn mode_chips(
    prefix: &'static str,
    current: MCPPermissionMode,
    chrome: Chrome,
    apply: fn(&mut App, MCPPermissionMode),
) -> gpui::Div {
    div()
        .flex()
        .flex_wrap()
        .gap_1()
        .children(MCPPermissionMode::ALL.into_iter().map(move |mode| {
            chip(
                SharedString::from(format!("{prefix}-{}", mode.raw_value())),
                mode.display_name(),
                current == mode,
                chrome,
            )
            .cursor_pointer()
            .on_click(move |_, _, cx| apply(cx, mode))
        }))
}

/// A switch drawn dimmed, without a click handler (`.disabled(...)`).
fn disabled_switch(on: bool, chrome: Chrome) -> gpui::Div {
    div()
        .opacity(0.45)
        .w(px(38.0))
        .h(px(22.0))
        .rounded_full()
        .p(px(2.0))
        .flex()
        .when(on, |d| d.justify_end())
        .bg(if on { chrome.accent } else { chrome.border })
        .child(div().size(px(18.0)).rounded_full().bg(gpui::white()))
}

pub(super) fn section(ctx: &SectionContext) -> gpui::Div {
    let chrome = ctx.chrome;
    let m = &ctx.settings.mcp;
    let inputs = &ctx.view.mcp;
    let enabled = m.enabled;

    let general = titled("General", chrome)
        .child(row(
            "Enable MCP",
            toggle("mcp-enabled", enabled, chrome, |s, v| s.mcp.enabled = v),
            chrome,
        ))
        .child(description(
            "Allow MCP clients to control Chau7 tabs via the local socket",
            chrome,
        ))
        .child(row(
            "Require Approval",
            if enabled {
                toggle("mcp-approval", m.requires_approval, chrome, |s, v| {
                    s.mcp.requires_approval = v
                })
                .into_any_element()
            } else {
                disabled_switch(m.requires_approval, chrome).into_any_element()
            },
            chrome,
        ))
        .child(description(
            "Show a confirmation dialog before MCP creates a new tab",
            chrome,
        ));

    let max_tabs = if enabled {
        stepper(
            "mcp-max-tabs",
            m.max_tabs.to_string(),
            chrome,
            |s, delta| {
                s.mcp.max_tabs = (s.mcp.max_tabs as i64 + delta as i64)
                    .clamp(1, ABSOLUTE_MAX_TABS as i64) as u32;
            },
        )
    } else {
        div()
            .opacity(0.45)
            .min_w(px(44.0))
            .text_center()
            .text_sm()
            .child(m.max_tabs.to_string())
    };
    let limits = titled("Limits", chrome)
        .child(row("Max MCP Tabs", max_tabs, chrome))
        .child(description(
            "Maximum number of tabs an MCP client can create (1-50)",
            chrome,
        ));

    let mut permissions = titled("Command Permissions", chrome)
        .child(row(
            "Permission Mode",
            mode_chips("mcp-mode", m.permission_mode, chrome, |cx, mode| {
                update(cx, |s| s.mcp.permission_mode = mode)
            }),
            chrome,
        ))
        .child(description(
            "Controls how MCP commands are filtered",
            chrome,
        ));
    if m.permission_mode != MCPPermissionMode::AllowAll {
        permissions = permissions.child(command_list(
            "mcp-allowed",
            "Allowed Commands",
            "Commands that run immediately without prompting",
            &m.allowed_commands,
            &inputs.allowed,
            ListTarget::GlobalAllowed,
            |cx, cmd| update(cx, |s| s.mcp.allowed_commands.retain(|c| c != cmd)),
            chrome,
        ));
    }
    permissions = permissions
        .child(command_list(
            "mcp-blocked",
            "Blocked Commands",
            "Commands that are always rejected - never execute",
            &m.blocked_commands,
            &inputs.blocked,
            ListTarget::GlobalBlocked,
            |cx, cmd| update(cx, |s| s.mcp.blocked_commands.retain(|c| c != cmd)),
            chrome,
        ))
        .child(description(mode_description(m.permission_mode), chrome));

    let appearance = titled("Appearance", chrome)
        .child(row(
            "Show Tab Indicator",
            toggle("mcp-indicator", m.show_tab_indicator, chrome, |s, v| {
                s.mcp.show_tab_indicator = v
            }),
            chrome,
        ))
        .child(description(
            "Display a purple icon and background on MCP-created tabs",
            chrome,
        ));

    let scripting = titled("Scripting API", chrome)
        .child(row(
            "Enable Scripting API",
            toggle("scripting-api", m.scripting_api, chrome, |s, v| {
                s.mcp.scripting_api = v
            }),
            chrome,
        ))
        .child(description(
            "Let local scripts list tabs, run commands, read output and history through a JSON socket (scripting.sock in the Chau7 Next data folder)",
            chrome,
        ));

    div()
        .flex()
        .flex_col()
        .child(general)
        .child(limits)
        .child(permissions)
        .child(appearance)
        .child(scripting)
        .child(profiles_section(ctx))
}

fn profile_row(profile: &MCPProfile, inputs: &McpInputs, chrome: Chrome) -> gpui::Div {
    let edit = profile.clone();
    let delete_id = profile.id;
    let (name_in, value_in, key_in) = (
        inputs.name.clone(),
        inputs.value.clone(),
        inputs.env_key.clone(),
    );
    div()
        .flex()
        .items_center()
        .justify_between()
        .gap_2()
        .px_2()
        .py_1p5()
        .rounded_md()
        .bg(chrome.tab_bg)
        .child(
            div()
                .flex_1()
                .min_w_0()
                .child(
                    div()
                        .flex()
                        .items_center()
                        .gap(px(6.0))
                        .child(
                            div()
                                .size(px(8.0))
                                .rounded_full()
                                .bg(if profile.is_enabled {
                                    gpui::green()
                                } else {
                                    chrome.text_muted
                                }),
                        )
                        .child(
                            div()
                                .text_sm()
                                .child(SharedString::from(profile.name.clone())),
                        ),
                )
                .child(
                    div()
                        .text_xs()
                        .text_color(chrome.text_muted)
                        .child(SharedString::from(format!(
                            "{} - {}",
                            profile.trigger.display_summary(),
                            profile.permission_mode.display_name()
                        ))),
                ),
        )
        .child(
            div()
                .text_xs()
                .text_color(chrome.text_muted)
                .child(SharedString::from(format!("P{}", profile.priority))),
        )
        .child(
            small_button(
                SharedString::from(format!("mcp-prof-edit-{}", profile.id)),
                "Edit",
                chrome,
            )
            .on_click(move |_, window, cx| {
                let p = edit.clone();
                let (value, key) = match &p.trigger {
                    ProfileSwitchTrigger::Directory { path } => (path.clone(), String::new()),
                    ProfileSwitchTrigger::GitRepository { name }
                    | ProfileSwitchTrigger::ProcessRunning { name } => {
                        (name.clone(), String::new())
                    }
                    ProfileSwitchTrigger::SshHost { hostname } => (hostname.clone(), String::new()),
                    ProfileSwitchTrigger::EnvironmentVariable { key, value } => {
                        (value.clone(), key.clone())
                    }
                };
                name_in.update(cx, |s, cx| s.set_value(p.name.clone(), window, cx));
                value_in.update(cx, |s, cx| s.set_value(value, window, cx));
                key_in.update(cx, |s, cx| s.set_value(key, window, cx));
                ui_edit(cx, |ui| {
                    ui.draft = Some(ProfileDraft {
                        id: Some(p.id),
                        enabled: p.is_enabled,
                        priority: p.priority,
                        kind: trigger_kind(&p.trigger),
                        mode: p.permission_mode,
                        allowed: p.allowed_commands.clone(),
                        blocked: p.blocked_commands.clone(),
                        agent_allowlist: p.agent_allowlist.clone(),
                    })
                });
            }),
        )
        .child(
            small_button(
                SharedString::from(format!("mcp-prof-del-{}", profile.id)),
                "Delete",
                chrome,
            )
            .text_color(chrome.danger)
            .on_click(move |_, _, cx| update(cx, |s| s.mcp.profiles.retain(|p| p.id != delete_id))),
        )
}

fn profiles_section(ctx: &SectionContext) -> gpui::Div {
    let chrome = ctx.chrome;
    let inputs = &ctx.view.mcp;
    let profiles = &ctx.settings.mcp.profiles;
    let mut section = titled("MCP Profiles", chrome).child(description(
        "Profiles override global permissions when their trigger matches the current tab context.",
        chrome,
    ));
    if !profiles.is_empty() {
        section = section.child(
            div()
                .flex()
                .flex_col()
                .gap_1()
                .children(profiles.iter().map(|p| profile_row(p, inputs, chrome))),
        );
    }
    match &inputs.ui.draft {
        None => {
            let (name_in, value_in, key_in) = (
                inputs.name.clone(),
                inputs.value.clone(),
                inputs.env_key.clone(),
            );
            section.child(div().flex().child(
                small_button("mcp-prof-add", "+ Add Profile", chrome).on_click(
                    move |_, window, cx| {
                        for input in [&name_in, &value_in, &key_in] {
                            input.update(cx, |s, cx| s.set_value(String::new(), window, cx));
                        }
                        ui_edit(cx, |ui| ui.draft = Some(ProfileDraft::new()));
                    },
                ),
            ))
        }
        Some(draft) => section.child(editor(draft, inputs, chrome)),
    }
}

/// `MCPProfileEditorView`.
fn editor(draft: &ProfileDraft, inputs: &McpInputs, chrome: Chrome) -> gpui::Div {
    let kinds = TRIGGER_KINDS.into_iter().enumerate().map(|(i, label)| {
        chip(
            SharedString::from(format!("mcp-kind-{i}")),
            label,
            draft.kind == i,
            chrome,
        )
        .cursor_pointer()
        .on_click(move |_, _, cx| draft_edit(cx, |d| d.kind = i))
    });
    let trigger_field = if draft.kind == 4 {
        div()
            .flex()
            .items_center()
            .gap_2()
            .child(div().w(px(160.0)).child(Input::new(&inputs.env_key)))
            .child("=")
            .child(div().w(px(160.0)).child(Input::new(&inputs.value)))
    } else {
        div()
            .flex()
            .flex_col()
            .gap_1()
            .child(div().w(px(340.0)).child(Input::new(&inputs.value)))
            .child(description(
                format!("For example {}", trigger_placeholder(draft.kind)),
                chrome,
            ))
    };
    let save_draft = draft.clone();
    let (name_in, value_in, key_in) = (
        inputs.name.clone(),
        inputs.value.clone(),
        inputs.env_key.clone(),
    );
    let mut lists = div().flex().flex_col().gap_2();
    if draft.mode != MCPPermissionMode::AllowAll {
        lists = lists.child(command_list(
            "mcp-prof-allowed",
            "Allowed Commands",
            "",
            &draft.allowed,
            &inputs.profile_allowed,
            ListTarget::DraftAllowed,
            |cx, cmd| draft_edit(cx, |d| d.allowed.retain(|c| c != cmd)),
            chrome,
        ));
    }
    lists = lists.child(command_list(
        "mcp-prof-blocked",
        "Blocked Commands",
        "",
        &draft.blocked,
        &inputs.profile_blocked,
        ListTarget::DraftBlocked,
        |cx, cmd| draft_edit(cx, |d| d.blocked.retain(|c| c != cmd)),
        chrome,
    ));
    let priority = draft.priority;
    div()
        .flex()
        .flex_col()
        .gap_2()
        .p_3()
        .rounded_lg()
        .border_1()
        .border_color(chrome.border)
        .child(
            div()
                .text_sm()
                .font_weight(gpui::FontWeight::SEMIBOLD)
                .child(if draft.id.is_none() {
                    "New MCP Profile"
                } else {
                    "Edit MCP Profile"
                }),
        )
        .child(div().w(px(340.0)).child(Input::new(&inputs.name)))
        .child(row(
            "Enabled",
            div()
                .id("mcp-prof-enabled")
                .w(px(38.0))
                .h(px(22.0))
                .rounded_full()
                .p(px(2.0))
                .flex()
                .cursor_pointer()
                .when(draft.enabled, |d| d.justify_end())
                .bg(if draft.enabled {
                    chrome.accent
                } else {
                    chrome.border
                })
                .child(div().size(px(18.0)).rounded_full().bg(gpui::white()))
                .on_click(|_, _, cx| draft_edit(cx, |d| d.enabled = !d.enabled)),
            chrome,
        ))
        .child(row(
            "Priority",
            div()
                .flex()
                .items_center()
                .gap_2()
                .child(
                    small_button("mcp-prof-prio-dec", "\u{2212}", chrome).on_click(|_, _, cx| {
                        draft_edit(cx, |d| d.priority = (d.priority - 1).clamp(0, 100))
                    }),
                )
                .child(
                    div()
                        .min_w(px(30.0))
                        .text_center()
                        .text_sm()
                        .child(SharedString::from(priority.to_string())),
                )
                .child(
                    small_button("mcp-prof-prio-inc", "+", chrome).on_click(|_, _, cx| {
                        draft_edit(cx, |d| d.priority = (d.priority + 1).clamp(0, 100))
                    }),
                ),
            chrome,
        ))
        .child(div().text_sm().child(crate::l10n::tr("Trigger")))
        .child(div().flex().flex_wrap().gap_1().children(kinds))
        .child(trigger_field)
        .child(div().text_sm().child(crate::l10n::tr("Permission Mode")))
        .child(mode_chips(
            "mcp-prof-mode",
            draft.mode,
            chrome,
            |cx, mode| draft_edit(cx, |d| d.mode = mode),
        ))
        .child(lists)
        .child(
            div()
                .flex()
                .justify_end()
                .gap_2()
                .child(
                    small_button("mcp-prof-cancel", "Cancel", chrome)
                        .on_click(|_, _, cx| ui_edit(cx, |ui| ui.draft = None)),
                )
                .child(
                    small_button("mcp-prof-save", "Save", chrome).on_click(move |_, _, cx| {
                        let name = name_in.read(cx).value().trim().to_string();
                        let value = value_in.read(cx).value().to_string();
                        let key = key_in.read(cx).value().to_string();
                        let Some(trigger) = build_trigger(save_draft.kind, &value, &key) else {
                            return;
                        };
                        if name.is_empty() {
                            return;
                        }
                        let profile = profile_from_draft(&save_draft, name, trigger);
                        update(cx, |s| {
                            match s.mcp.profiles.iter_mut().find(|p| p.id == profile.id) {
                                Some(existing) => *existing = profile,
                                None => s.mcp.profiles.push(profile),
                            }
                        });
                        ui_edit(cx, |ui| ui.draft = None);
                    }),
                ),
        )
}

/// `MCPProfileEditorView.save`.
fn profile_from_draft(
    draft: &ProfileDraft,
    name: String,
    trigger: ProfileSwitchTrigger,
) -> MCPProfile {
    let mut profile = MCPProfile::new(&name, trigger);
    if let Some(id) = draft.id {
        profile.id = id;
    }
    profile.is_enabled = draft.enabled;
    profile.permission_mode = draft.mode;
    profile.allowed_commands = draft.allowed.clone();
    profile.blocked_commands = draft.blocked.clone();
    profile.priority = draft.priority;
    profile.agent_allowlist = draft.agent_allowlist.clone();
    profile
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn commands_are_added_lowercased_once() {
        let mut list = Vec::new();
        add_command(&mut list, "  Git ");
        add_command(&mut list, "git");
        add_command(&mut list, "   ");
        assert_eq!(list, ["git"]);
    }

    #[test]
    fn triggers_from_the_editor() {
        assert_eq!(build_trigger(0, "  ", ""), None);
        assert_eq!(
            build_trigger(0, " ~/x ", ""),
            Some(ProfileSwitchTrigger::Directory { path: "~/x".into() })
        );
        assert_eq!(
            build_trigger(4, "prod", " ENV "),
            Some(ProfileSwitchTrigger::EnvironmentVariable {
                key: "ENV".into(),
                value: "prod".into()
            })
        );
        for kind in 0..5 {
            let trigger = build_trigger(kind, "v", "k").unwrap();
            assert_eq!(trigger_kind(&trigger), kind);
        }
    }

    #[test]
    fn editing_keeps_the_id_and_agent_allowlist() {
        let mut draft = ProfileDraft::new();
        let id = Uuid::new_v4();
        draft.id = Some(id);
        draft.agent_allowlist = vec!["Claude".into()];
        draft.priority = 3;
        let p = profile_from_draft(
            &draft,
            "P".into(),
            ProfileSwitchTrigger::SshHost {
                hostname: "h".into(),
            },
        );
        assert_eq!(p.id, id);
        assert_eq!(p.agent_allowlist, ["Claude"]);
        assert_eq!(p.priority, 3);
        assert_eq!(p.permission_mode, MCPPermissionMode::AskUnlisted);
    }
}
