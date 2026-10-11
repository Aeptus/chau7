//! Settings window (Cmd+,): a sidebar of 23 sections in 6 groups with search,
//! and the section's controls next to it (`MainPanelView.swift`,
//! `SettingsSearch.swift`). Changes are written to
//! `~/.chau7-next/config.toml` and applied immediately.
//!
//! One file per section. A section is made of renderer functions listed in
//! [`renderers`]; porting a section means a new file plus one line there. A
//! section without a renderer shows a note instead of its controls, and its
//! values stay editable in the config file ("Open config.toml").

mod about;
mod ai;
mod backup;
mod colors;
mod display;
mod editor;
mod files;
mod general;
mod graphics;
mod hover_card;
mod keyboard;
mod logs;
mod mcp;
mod mine;
mod minimal_mode;
mod notification_triggers;
mod notifications;
mod panes;
mod proxy;
mod remote;
mod rendering;
mod repositories;
mod shell;
mod shortcuts;
mod tabs;
mod text;
mod token_optimization;
mod widgets;

pub use about::open_about;

use chau7_next_core::data_root::DataRoot;
use chau7_next_core::settings_search::{
    SettingsGroup, SettingsSection, matching_settings, sections_matching,
};
use gpui::{
    AnyWindowHandle, App, BorrowAppContext, Bounds, Context, Entity, Global, Render, SharedString,
    Window, WindowBounds, WindowOptions, div, prelude::*, px, size,
};
use gpui_kit::component::TitleBar;
use gpui_kit::component::input::{Input, InputEvent, InputState};

use crate::monitoring_status::MonitoringStatus;
use crate::platform::login_item::{self, LoginItemStatus};
use crate::settings::Settings;
use crate::settings::config_files::{self, ConfigFiles};
use crate::settings::sync::SyncState;
use crate::theme::Chrome;
use crate::workspace::AppData;

pub use shortcuts::open as open_shortcuts;

/// What a section renders from.
pub(crate) struct SectionContext<'a> {
    /// A copy of the current settings (the effective ones).
    pub settings: &'a Settings,
    pub chrome: Chrome,
    pub root: &'a DataRoot,
    pub view: &'a SettingsView,
    /// Repositories section: the repository being edited.
    pub selected_repo: Option<String>,
    pub known_repo_roots: Vec<String>,
    /// Config file state (General).
    pub config: &'a ConfigFiles,
    /// iCloud sync state (Sync & Backup).
    pub sync: Option<&'a SyncState>,
    /// Monitors (General > Status).
    pub monitoring: MonitoringStatus,
    /// Launch at login as the OS reports it.
    pub login_status: LoginItemStatus,
    /// Home folder, for `~` in paths.
    pub home: String,
    /// Logs & History: database statistics and tracked sessions.
    pub logs: logs::LogsData,
    /// Logs & History: "Clear All" waits for a second click.
    pub confirm_clear: bool,
    /// Remote control state (Remote Control).
    pub remote: Option<crate::remote::RemoteStatus>,
    /// API Analytics: proxy status and today's numbers.
    pub proxy_status: Option<crate::proxy::ProxyStatus>,
    pub proxy_stats: Option<chau7_next_core::proxy::ApiCallStats>,
    /// Token Optimization section: files, monitor and tabs.
    pub cto: token_optimization::CtoData,
}

/// Renders one block of a section (title and rows).
type Section = fn(&SectionContext) -> gpui::Div;

/// The renderers of each sidebar section, top to bottom.
fn renderers(section: SettingsSection) -> &'static [Section] {
    use SettingsSection as S;
    match section {
        S::General => &[general::section, files::section],
        S::ProfilesBackup => &[
            mine::profiles::bar,
            backup::section,
            mine::profiles::auto_switch,
            mine::profiles::ssh_sync,
        ],
        S::About => &[about::section],
        S::FontColors => &[text::section, colors::section],
        S::Display => &[display::section],
        S::Tabs => &[tabs::section],
        S::HoverCard => &[hover_card::section],
        S::Repositories => &[repositories::section],
        S::LogsHistory => &[logs::section],
        S::MinimalMode => &[minimal_mode::section],
        S::Shell => &[shell::section],
        S::ScrollbackPerf => &[panes::section, rendering::section],
        S::Graphics => &[graphics::section],
        S::DangerousCommands => &[mine::dangerous::section],
        S::KeyboardMouse => &[keyboard::section, mine::links::section],
        S::SnippetsTools => &[mine::productivity::section],
        S::Notifications => &[notifications::section],
        S::AiDetection => &[ai::section],
        S::McpControl => &[mcp::section],
        S::RemoteControl => &[remote::section, remote::viewers],
        S::ApiProxy => &[proxy::section],
        S::Editor => &[editor::section],
        S::TokenOptimization => &[
            token_optimization::mode,
            token_optimization::prefix,
            token_optimization::optimizer,
            token_optimization::runtime,
            token_optimization::command_log,
            token_optimization::savings,
            token_optimization::per_tab,
            token_optimization::commands,
            token_optimization::how_it_works,
        ],
    }
}

/// The open settings window, if any (only one at a time).
#[derive(Default)]
struct SettingsWindowHandle(Option<AnyWindowHandle>);
impl Global for SettingsWindowHandle {}

pub(crate) use repositories::record_recent_repo;

/// The result of the last button (export, import, reset...), shown above the
/// section until another section is opened.
#[derive(Default)]
struct UiMessage(Option<(String, bool)>);
impl Global for UiMessage {}

/// Show `text` in the settings window; `error` draws it as a problem.
pub(crate) fn set_message(cx: &mut App, text: String, error: bool) {
    cx.set_global(UiMessage(Some((text, error))));
    cx.refresh_windows();
}

pub fn open(cx: &mut App) {
    crate::cto::refresh_gain(cx);
    if let Some(handle) = cx.try_global::<SettingsWindowHandle>().and_then(|h| h.0)
        && handle
            .update(cx, |_, window, _| window.activate_window())
            .is_ok()
    {
        return;
    }
    let bounds = Bounds::centered(None, size(px(860.0), px(640.0)), cx);
    let options = WindowOptions {
        window_bounds: Some(WindowBounds::Windowed(bounds)),
        window_min_size: Some(size(px(640.0), px(420.0))),
        ..TitleBar::window_options()
    };
    match gpui_kit::open_window(options, cx, |window, cx| {
        cx.new(|cx| SettingsView::new(window, cx))
    }) {
        Ok((handle, _)) => cx.set_global(SettingsWindowHandle(Some(handle))),
        Err(err) => log::error!("settings window: {err}"),
    }
}

pub struct SettingsView {
    /// Text section: the custom font field (`terminal.customFontFamily`).
    font_input: Entity<InputState>,
    /// Whether the typed custom font is installed (`None` while empty).
    custom_font_valid: Option<bool>,
    /// Font families installed on this computer, for the picker.
    installed_fonts: Vec<String>,
    /// Display section: the timestamp format field.
    timestamp_input: Entity<InputState>,
    /// Graphics section: "Test image copied to clipboard" for a few seconds.
    graphics_feedback: Option<&'static str>,
    entity: gpui::WeakEntity<SettingsView>,
    /// Shell section: custom shell, startup command, default directory.
    shell_inputs: shell::ShellInputs,
    /// Repositories section editor fields.
    repo_inputs: repositories::RepoInputs,
    /// AI Integration section fields.
    ai_inputs: ai::AiInputs,
    /// Logs & History text fields.
    logs_inputs: logs::LogsInputs,
    /// Remote Control: the relay URL field.
    remote_inputs: remote::RemoteInputs,
    /// API Analytics: the port field.
    proxy_inputs: proxy::ProxyInputs,
    search_input: Entity<InputState>,
    query: String,
    selected: SettingsSection,
    /// Snippets, links, command guard and profile sections.
    mine: mine::MineState,
    /// Notifications section state.
    notif: notifications::NotifState,
    /// MCP Control section fields.
    mcp: mcp::McpInputs,
    /// Token Optimization section fields.
    cto: token_optimization::CtoInputs,
    _subscriptions: Vec<gpui::Subscription>,
}

impl SettingsView {
    fn new(window: &mut Window, cx: &mut Context<Self>) -> Self {
        let appearance = Settings::get(cx).appearance.clone();
        let installed_fonts = window.text_system().all_font_names();
        let font_input = cx.new(|cx| {
            InputState::new(window, cx)
                .placeholder(crate::l10n::tr("Font family name..."))
                .default_value(appearance.custom_font_family.clone())
        });
        let timestamp_input = cx.new(|cx| {
            InputState::new(window, cx)
                .placeholder(crate::l10n::tr("HH:mm:ss"))
                .default_value(appearance.display.timestamp_format.clone())
        });
        let custom_font_valid =
            text::validate_font(&appearance.custom_font_family, &installed_fonts);
        // The custom font validates live as it is typed and applies on Enter.
        let font_sub = cx.subscribe(&font_input, |this, input, event: &InputEvent, cx| {
            let value = input.read(cx).value().trim().to_string();
            match event {
                InputEvent::Change => {
                    this.custom_font_valid = text::validate_font(&value, &this.installed_fonts);
                    cx.notify();
                }
                InputEvent::PressEnter { .. } if this.custom_font_valid == Some(true) => {
                    update(cx, |s| {
                        s.appearance.custom_font_family = value.clone();
                        s.appearance.font_family = value;
                    });
                }
                _ => {}
            }
        });
        let timestamp_sub = cx.subscribe(&timestamp_input, |_, input, event: &InputEvent, cx| {
            if matches!(event, InputEvent::PressEnter { .. } | InputEvent::Blur) {
                let value = input.read(cx).value().trim().to_string();
                if !value.is_empty()
                    && value != Settings::get(cx).appearance.display.timestamp_format
                {
                    update(cx, |s| s.appearance.display.timestamp_format = value);
                }
            }
        });
        let search_input = cx
            .new(|cx| InputState::new(window, cx).placeholder(crate::l10n::tr("Search settings")));
        let search_subscription =
            cx.subscribe(&search_input, |this, input, event: &InputEvent, cx| {
                if matches!(event, InputEvent::Change) {
                    this.query = input.read(cx).value().trim().to_string();
                    // The shown section follows the search: the first match.
                    if !this.query.is_empty() {
                        let matches = sections_matching(&this.query);
                        if !matches.iter().any(|(s, _)| *s == this.selected)
                            && let Some((first, _)) = matches.first()
                        {
                            this.selected = *first;
                        }
                    }
                    cx.notify();
                }
            });
        let mine = mine::MineState::new(window, cx);
        let notif = notifications::NotifState::new(window, cx);
        let mcp = mcp::McpInputs::new(window, cx);
        let cto = token_optimization::CtoInputs::new(window, cx);
        Self {
            mcp,
            cto,
            font_input,
            mine,
            notif,
            custom_font_valid,
            installed_fonts,
            timestamp_input,
            graphics_feedback: None,
            entity: cx.entity().downgrade(),
            shell_inputs: shell::ShellInputs::new(window, cx),
            repo_inputs: repositories::RepoInputs::new(window, cx),
            ai_inputs: ai::AiInputs::new(window, cx),
            logs_inputs: logs::LogsInputs::new(window, cx),
            remote_inputs: remote::RemoteInputs::new(window, cx),
            proxy_inputs: proxy::ProxyInputs::new(window, cx),
            search_input,
            query: String::new(),
            selected: SettingsSection::General,
            _subscriptions: vec![font_sub, timestamp_sub, search_subscription],
        }
    }

    fn select(&mut self, section: SettingsSection, cx: &mut Context<Self>) {
        self.selected = section;
        cx.set_global(UiMessage(None));
        cx.notify();
    }
}

/// Change settings, save them, and apply them to every window.
///
/// The change applies to the global file's settings; a per-repo config on top
/// of them is applied again afterwards and never written to the global file.
pub(crate) fn update(cx: &mut App, change: impl FnOnce(&mut Settings)) {
    let mut base = cx.global::<ConfigFiles>().base.clone();
    change(&mut base);
    replace_base(cx, base);
}

/// Make `base` the settings of the global file: save it, apply it, and queue
/// it for iCloud when sync is on.
pub(crate) fn replace_base(cx: &mut App, base: Settings) {
    let root = cx.global::<AppData>().root.clone();
    let saved = base.save(&root);
    if let Err(err) = &saved {
        log::error!("save settings: {err}");
    }
    let shortcuts_changed = Settings::get(cx).input != base.input;
    cx.update_global(|files: &mut ConfigFiles, _| {
        files.base = base;
        files.saved();
        files.last_error = saved.err().map(|e| e.to_string());
    });
    config_files::apply(cx);
    if shortcuts_changed {
        let input = Settings::get(cx).input.clone();
        crate::actions::bind_shortcut_settings(&input, cx);
    }
    crate::settings::sync::schedule_push(cx);
}

impl SettingsView {
    /// The sidebar: the search field, then the groups and their sections.
    fn sidebar(&self, chrome: Chrome, cx: &Context<Self>) -> gpui::Stateful<gpui::Div> {
        let searching = !self.query.is_empty();
        let matches = sections_matching(&self.query);
        let mut list = div().flex().flex_col().gap_0p5();
        for group in SettingsGroup::ALL {
            let sections: Vec<(SettingsSection, usize)> = group
                .sections()
                .iter()
                .filter_map(|&section| {
                    if !searching {
                        return Some((section, 0));
                    }
                    matches.iter().find(|(s, _)| *s == section).copied()
                })
                .collect();
            if sections.is_empty() {
                continue;
            }
            list = list.child(
                div()
                    .px_2()
                    .pt_3()
                    .pb_1()
                    .text_xs()
                    .font_weight(gpui::FontWeight::SEMIBOLD)
                    .text_color(chrome.text_muted)
                    .child(crate::l10n::tr(group.title())),
            );
            for (section, count) in sections {
                let selected = section == self.selected;
                list = list.child(
                    div()
                        .id(SharedString::from(format!("section-{}", section.id())))
                        .flex()
                        .items_center()
                        .justify_between()
                        .gap_2()
                        .px_2()
                        .py_1()
                        .rounded_md()
                        .text_sm()
                        .cursor_pointer()
                        .text_color(chrome.text)
                        .when(selected, |d| d.bg(chrome.tab_selected_bg))
                        .hover(|d| d.bg(chrome.tab_hover_bg))
                        .child(crate::l10n::tr(section.title()))
                        .when(searching, |d| {
                            d.child(
                                div()
                                    .px_1p5()
                                    .rounded_full()
                                    .text_xs()
                                    .bg(chrome.accent.opacity(0.25))
                                    .child(count.to_string()),
                            )
                        })
                        .on_click(cx.listener(move |this, _, _, cx| this.select(section, cx))),
                );
            }
        }
        if searching && matches.is_empty() {
            list = list.child(
                div()
                    .p_2()
                    .text_xs()
                    .text_color(chrome.text_muted)
                    .child(crate::l10n::tr("No settings found")),
            );
        }
        div()
            .id("settings-sidebar")
            .w(px(230.0))
            .h_full()
            .flex_none()
            .flex()
            .flex_col()
            .gap_2()
            .p_2()
            .when(!crate::l10n::is_rtl(), |d| d.border_r_1())
            .when(crate::l10n::is_rtl(), |d| d.border_l_1())
            .border_color(chrome.border)
            .child(Input::new(&self.search_input))
            .child(
                div()
                    .id("settings-sidebar-list")
                    .flex_1()
                    .overflow_y_scroll()
                    .child(list),
            )
    }

    /// The selected section: header, last message, and its controls.
    fn detail(&self, context: &SectionContext, cx: &App) -> gpui::Stateful<gpui::Div> {
        let chrome = context.chrome;
        let section = self.selected;
        let mut page = div().flex().flex_col().child(
            div()
                .pb_3()
                .child(
                    crate::l10n::row_direction(div().flex().items_center().justify_between())
                        .child(
                            div()
                                .text_lg()
                                .font_weight(gpui::FontWeight::SEMIBOLD)
                                .child(crate::l10n::tr(section.title())),
                        )
                        .when(Settings::can_reset_section(section), |d| {
                            d.child(
                                widgets::button("reset-section", "Reset to Defaults", chrome)
                                    .on_click(move |_, _, cx| {
                                        update(cx, |s| s.reset_section(section))
                                    }),
                            )
                        }),
                )
                .child(widgets::description(section.description(), chrome)),
        );
        if let Some((text, error)) = cx.try_global::<UiMessage>().and_then(|m| m.0.clone()) {
            page = page.child(div().pb_3().child(widgets::banner(text, error, chrome)));
        }
        if !self.query.is_empty() {
            let hits = matching_settings(section, &self.query);
            if !hits.is_empty() {
                let names: Vec<&str> = hits.iter().map(|h| h.title).collect();
                page = page.child(div().pb_3().child(widgets::description(
                    format!("Matches: {}", names.join(", ")),
                    chrome,
                )));
            }
        }
        let blocks = renderers(section);
        if blocks.is_empty() {
            page = page.child(widgets::section("Not available yet", chrome).child(
                widgets::description(
                    "These settings are not in Chau7 Next yet. Their values can still be set in config.toml.",
                    chrome,
                ),
            ));
            page = page.child(div().flex().child(
                widgets::button("open-config-placeholder", "Open config.toml", chrome).on_click(
                    |_, window, cx| {
                        window.dispatch_action(Box::new(crate::actions::OpenConfigFile), cx)
                    },
                ),
            ));
        } else {
            page = page.children(blocks.iter().map(|block| block(context)));
        }
        div()
            // One id per section: a newly selected section opens at the top
            // instead of keeping the previous section's scroll offset.
            .id(SharedString::from(format!(
                "settings-scroll-{}",
                section.id()
            )))
            .flex_1()
            // Without it the column grows to its longest line and the
            // controls at the right edge end up outside the window.
            .min_w_0()
            .h_full()
            .overflow_y_scroll()
            .px_6()
            .py_4()
            .child(page)
    }
}

impl Render for SettingsView {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        window.set_window_title(&self.mine.profiles.title());
        self.mine.refresh(cx);
        self.notif.refresh(cx);
        self.mcp.refresh(cx);
        let chrome = Chrome::panels(cx);
        let sidebar = self.sidebar(chrome, cx);
        let settings = Settings::get(cx).clone();
        let root = cx.global::<AppData>().root.clone();
        let files = cx.global::<ConfigFiles>();
        let sync = cx.try_global::<SyncState>();
        let context = SectionContext {
            settings: &settings,
            chrome,
            root: &root,
            view: self,
            selected_repo: repositories::selected_repo(cx),
            known_repo_roots: crate::repository::known_roots(cx),
            config: files,
            sync,
            monitoring: MonitoringStatus::get(cx),
            login_status: login_item::current().status(),
            home: root.home().to_string_lossy().into_owned(),
            logs: logs::LogsData::read(cx),
            confirm_clear: logs::confirm_pending(cx),
            remote: crate::remote::status(cx),
            proxy_status: Some(crate::proxy::status(cx)),
            proxy_stats: crate::proxy::today_stats(cx),
            cto: token_optimization::CtoData::read(
                self.selected == SettingsSection::TokenOptimization,
                cx,
            ),
        };
        let detail = self.detail(&context, cx);

        div()
            .size_full()
            .flex()
            .flex_col()
            .bg(chrome.panel_bg)
            .text_color(chrome.text)
            .when(crate::l10n::is_rtl(), |d| d.text_right())
            .child(TitleBar::new().child(div().text_sm().child(crate::l10n::tr("Settings"))))
            .child(
                crate::l10n::row_direction(div().flex_1().min_h_0().flex())
                    .child(sidebar)
                    .child(detail),
            )
    }
}
