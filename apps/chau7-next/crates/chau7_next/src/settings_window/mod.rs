//! Settings window (Cmd+,): a sidebar of 28 sections in 6 groups with search,
//! and the section's controls next to it (`MainPanelView.swift`,
//! `SettingsSearch.swift`). Changes are written to
//! `~/.chau7-next/config.toml` and applied immediately.
//!
//! One file per section. A section is made of renderer functions listed in
//! [`renderers`]; porting a section means a new file plus one line there. A
//! All current sidebar sections have renderer routes. Search results use
//! stable current-source anchors to reach their controls.

mod about;
mod ai;
mod anchors;
mod backup;
mod colors;
mod display;
mod editor;
mod files;
mod general;
mod graphics;
mod hover_card;
mod injection;
mod io_snapshot;
mod keyboard;
mod logs;
mod mcp;
mod mine;
mod minimal_mode;
#[cfg(all(feature = "native-parity-fixture", target_os = "macos"))]
mod native_cache_fixture;
#[cfg(feature = "native-parity-fixture")]
mod native_fixture;
#[cfg(any(test, feature = "native-parity-fixture"))]
mod native_locale;
mod notification_triggers;
mod notifications;
mod panes;
mod permission_center;
mod proxy;
mod remote;
mod rendering;
mod repositories;
mod search_animation;
mod shell;
mod shortcuts;
mod start_here;
mod summary;
mod tabs;
mod text;
mod token_optimization;
mod widgets;
mod windows;

pub use about::open_about;
pub(crate) use io_snapshot::invalidate_snippets;
#[cfg(all(feature = "native-parity-fixture", target_os = "macos"))]
pub(crate) use io_snapshot::shutdown_native_fixture as shutdown_native_snapshots;
#[cfg(all(feature = "native-parity-fixture", target_os = "macos"))]
pub(crate) use native_cache_fixture::verify_native_cache_fixture;
#[cfg(feature = "native-parity-fixture")]
pub(crate) use native_fixture::verify_native_fixture;

use chau7_next_core::data_root::DataRoot;
use chau7_next_core::settings_search::{
    SEARCHABLE_SETTINGS, SearchableSetting, SettingsGroup, SettingsNavigation, SettingsSection,
    matching_settings, sections_matching,
};
use gpui::{
    AnyWindowHandle, App, BorrowAppContext, Bounds, Context, Entity, Global, Render, ScrollAnchor,
    ScrollHandle, SharedString, Window, WindowBounds, WindowOptions, div, prelude::*, px, size,
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
    pub recent_repo_roots: Option<Vec<String>>,
    pub notification_warning: Option<String>,
    pub permissions: crate::permission_center::Snapshot,
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
        S::StartHere => &[start_here::section],
        S::Windows => &[windows::section],
        S::History => &[logs::history, ai::telemetry_history],
        S::SshProfiles => &[mine::profiles::ssh_sync],
        S::General => &[general::section, files::section],
        S::ProfilesBackup => &[
            mine::profiles::bar,
            backup::section,
            mine::profiles::auto_switch,
        ],
        S::About => &[about::section],
        S::FontColors => &[text::section, colors::section],
        S::Display => &[display::section],
        S::Tabs => &[tabs::section],
        S::HoverCard => &[hover_card::section],
        S::Repositories => &[repository_settings],
        S::LogsHistory => &[logs::section],
        S::MinimalMode => &[minimal_mode::section],
        S::Shell => &[shell::section, text::cursor],
        S::ScrollbackPerf => &[panes::section, rendering::section],
        S::Graphics => &[graphics::section],
        S::DangerousCommands => &[mine::dangerous::section],
        S::KeyboardMouse => &[keyboard::section, mine::links::section],
        S::SnippetsTools => &[mine::productivity::section, permissions],
        S::Notifications => &[notifications::section],
        S::AiDetection => &[ai::section],
        S::PromptInjection => &[injection::section],
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

fn repository_settings(ctx: &SectionContext) -> gpui::Div {
    anchors::target("repositoryMetadata", repositories::section(ctx))
}

fn permissions(ctx: &SectionContext) -> gpui::Div {
    anchors::target("permissions", permission_center::section(ctx))
}

/// The open settings window, if any (only one at a time).
#[derive(Default)]
struct SettingsWindowHandle {
    handle: Option<AnyWindowHandle>,
    view: Option<gpui::WeakEntity<SettingsView>>,
}
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
    crate::permission_center::refresh(cx);
    crate::cto::refresh_gain(cx);
    if let Some(handle) = cx
        .try_global::<SettingsWindowHandle>()
        .and_then(|h| h.handle)
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
        Ok((handle, view)) => cx.set_global(SettingsWindowHandle {
            handle: Some(handle),
            view: Some(view.downgrade()),
        }),
        Err(err) => log::error!("settings window: {err}"),
    }
}

/// Focus an actual settings section/control requested by a feature.
pub fn open_at(section: Option<SettingsSection>, anchor_id: Option<&str>, cx: &mut App) {
    open(cx);
    let request = cx
        .try_global::<SettingsWindowHandle>()
        .and_then(|state| Some((state.handle?, state.view.clone()?)));
    let Some((handle, view)) = request else {
        return;
    };
    let anchor_id = anchor_id.map(str::to_owned);
    let _ = handle.update(cx, move |_, window, cx| {
        let _ = view.update(cx, |view, cx| {
            if !view.search_input.read(cx).value().is_empty() {
                view.suppress_search_change = true;
                view.search_input
                    .update(cx, |input, cx| input.set_value("", window, cx));
            }
            view.navigation.show(section, anchor_id.as_deref());
            if view.navigation.selection == SettingsSection::StartHere {
                crate::permission_center::refresh(cx);
            }
            view.scroll_to_active_search_anchor(window, cx);
            cx.notify();
        });
    });
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
    /// Scrollback section: independently held integer edit buffer.
    pane_inputs: panes::PaneInputs,
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
    injection: injection::InjectionState,
    search_input: Entity<InputState>,
    navigation: SettingsNavigation,
    suppress_search_change: bool,
    scroll_handle: ScrollHandle,
    target_bounds: anchors::TargetBounds,
    search_scroll_generation: u64,
    search_highlights: search_animation::Highlights,
    search_scroll_motion: Option<search_animation::ScrollMotion>,
    search_scroll_retry: Option<gpui::Task<()>>,
    search_retry_pending: bool,
    search_animation_frame_pending: bool,
    search_retry_attempts: u64,
    #[cfg(feature = "native-parity-fixture")]
    search_scroll_requested_at: std::time::Instant,
    #[cfg(feature = "native-parity-fixture")]
    search_scroll_trace: Vec<serde_json::Value>,
    search_anchors: std::rc::Rc<std::collections::HashMap<&'static str, ScrollAnchor>>,
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
        Self::new_inner(window, cx, None)
    }

    fn new_inner(window: &mut Window, cx: &mut Context<Self>, api_key: Option<String>) -> Self {
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
        let search_window = window.window_handle();
        let search_subscription =
            cx.subscribe(&search_input, move |this, input, event: &InputEvent, cx| {
                if matches!(event, InputEvent::Change) {
                    if this.suppress_search_change {
                        this.suppress_search_change = false;
                        return;
                    }
                    let query = input.read(cx).value().to_string();
                    let first = sections_matching(&query)
                        .first()
                        .map(|(section, _)| *section);
                    this.navigation.update_search_query(query, first);
                    this.search_scroll_generation = this.search_scroll_generation.wrapping_add(1);
                    this.search_scroll_motion = None;
                    this.search_scroll_retry = None;
                    this.search_retry_pending = false;
                    this.search_animation_frame_pending = false;
                    let view = this.entity.clone();
                    cx.defer(move |cx| {
                        let _ = search_window.update(cx, |_, window, cx| {
                            let _ = view.update(cx, |view, cx| {
                                view.scroll_to_active_search_anchor(window, cx)
                            });
                        });
                    });
                    cx.notify();
                }
            });
        let mine = mine::MineState::new(window, cx);
        let notif = notifications::NotifState::new(window, cx);
        let mcp = mcp::McpInputs::new(window, cx);
        let cto = token_optimization::CtoInputs::new(window, cx);
        let scroll_handle = ScrollHandle::new();
        let search_anchors = std::rc::Rc::new(
            SEARCHABLE_SETTINGS
                .iter()
                .map(|setting| {
                    (
                        setting.anchor_id,
                        ScrollAnchor::for_handle(scroll_handle.clone()),
                    )
                })
                .chain(
                    ["permissions", "pageSummary"]
                        .into_iter()
                        .map(|id| (id, ScrollAnchor::for_handle(scroll_handle.clone()))),
                )
                .collect(),
        );
        Self {
            scroll_handle,
            target_bounds: Default::default(),
            search_scroll_generation: 0,
            search_highlights: Default::default(),
            search_scroll_motion: None,
            search_scroll_retry: None,
            search_retry_pending: false,
            search_animation_frame_pending: false,
            search_retry_attempts: 0,
            #[cfg(feature = "native-parity-fixture")]
            search_scroll_requested_at: cx.background_executor().now(),
            #[cfg(feature = "native-parity-fixture")]
            search_scroll_trace: Vec::new(),
            search_anchors,
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
            pane_inputs: panes::PaneInputs::new(window, cx),
            repo_inputs: repositories::RepoInputs::new(window, cx),
            ai_inputs: match api_key {
                Some(key) => ai::AiInputs::new_with_api_key(window, cx, key),
                None => ai::AiInputs::new(window, cx),
            },
            logs_inputs: logs::LogsInputs::new(window, cx),
            remote_inputs: remote::RemoteInputs::new(window, cx),
            proxy_inputs: proxy::ProxyInputs::new(window, cx),
            injection: injection::InjectionState::new(window, cx),
            search_input,
            navigation: SettingsNavigation::default(),
            suppress_search_change: false,
            _subscriptions: vec![font_sub, timestamp_sub, search_subscription],
        }
    }

    fn active_search_anchor_id(&self) -> Option<&'static str> {
        if let Some(id) = self.navigation.anchor_id.as_deref() {
            return self.search_anchors.get_key_value(id).map(|(key, _)| *key);
        }
        if self.navigation.search_query.is_empty() {
            return None;
        }
        matching_settings(self.navigation.selection, &self.navigation.search_query)
            .first()
            .map(|setting| setting.anchor_id)
    }

    fn scroll_to_active_search_anchor(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.search_scroll_generation = self.search_scroll_generation.wrapping_add(1);
        self.search_scroll_motion = None;
        self.search_scroll_retry = None;
        self.search_retry_pending = false;
        self.search_animation_frame_pending = false;
        self.target_bounds.clear();
        #[cfg(feature = "native-parity-fixture")]
        {
            self.search_scroll_requested_at = cx.background_executor().now();
            self.search_scroll_trace.clear();
        }
        let generation = self.search_scroll_generation;
        let id = self.active_search_anchor_id();
        self.search_highlights
            .begin(id, cx.background_executor().now());
        self.schedule_search_animation_frame(window, cx);
        let Some(id) = id else {
            cx.notify();
            return;
        };
        if self.navigation.selection == SettingsSection::Notifications {
            self.notif.focus_search_target(id);
        }
        // The target must have real layout before calculating centered offset.
        cx.on_next_frame(window, move |_, window, cx| {
            cx.on_next_frame(window, move |this, window, cx| {
                if this.search_scroll_generation == generation
                    && this.active_search_anchor_id() == Some(id)
                {
                    this.start_search_scroll_motion(id, "initial_layout", window, cx);
                }
            });
            cx.notify();
        });
        // Swift retries at 120ms. Holding exactly one weak-entity task cancels
        // obsolete retries when the query, section, target or window changes.
        self.search_retry_pending = true;
        self.search_scroll_retry = Some(cx.spawn_in(window, async move |view, cx| {
            cx.background_executor()
                .timer(search_animation::SCROLL_RETRY)
                .await;
            let _ = view.update_in(cx, |view, window, cx| {
                if view.search_scroll_generation != generation
                    || view.active_search_anchor_id() != Some(id)
                {
                    return;
                }
                view.search_retry_pending = false;
                view.search_retry_attempts = view.search_retry_attempts.saturating_add(1);
                view.start_search_scroll_motion(id, "retry", window, cx);
            });
        }));
        cx.notify();
    }

    fn start_search_scroll_motion(
        &mut self,
        id: &'static str,
        _source_kind: &'static str,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let viewport = self.scroll_handle.bounds();
        let maximum = self.scroll_handle.max_offset();
        let centered = self.target_bounds.centered_offset(id, viewport, maximum.y);
        let now = cx.background_executor().now();
        let observed = self.scroll_handle.offset().y;
        if let Some(centered) = centered
            && search_animation::update_motion(
                &mut self.search_scroll_motion,
                observed,
                centered,
                now,
            )
        {
            // Completion remains a real frame applying the exact final offset.
            self.schedule_search_animation_frame(window, cx);
        }
        #[cfg(feature = "native-parity-fixture")]
        if self.search_scroll_trace.len() < 4 {
            self.search_scroll_trace.push(serde_json::json!({
                "source_kind": _source_kind,
                "attempt_microseconds": now.saturating_duration_since(self.search_scroll_requested_at).as_micros(),
                "requested_from_px": f32::from(observed),
                "requested_to_px": centered.map(f32::from),
                "motion": self.search_scroll_motion.as_ref().map(|motion| motion.diagnostic(self.search_scroll_requested_at, now)),
            }));
        }
    }

    fn schedule_search_animation_frame(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.search_animation_frame_pending {
            return;
        }
        self.search_animation_frame_pending = true;
        let generation = self.search_scroll_generation;
        cx.on_next_frame(window, move |view, window, cx| {
            if view.search_scroll_generation != generation {
                return;
            }
            view.search_animation_frame_pending = false;
            let now = cx.background_executor().now();
            if let Some(motion) = &view.search_scroll_motion {
                let maximum = view.scroll_handle.max_offset();
                let offset = view.scroll_handle.offset();
                view.scroll_handle.set_offset(gpui::point(
                    offset.x,
                    motion.value(now).clamp(-maximum.y, px(0.)),
                ));
                if motion.finished(now) {
                    view.search_scroll_motion = None;
                }
            }
            cx.notify();
            if !view.search_animations_finished(now) {
                view.schedule_search_animation_frame(window, cx);
            }
        });
    }

    fn search_animations_finished(&self, now: std::time::Instant) -> bool {
        self.search_scroll_motion.is_none()
            && !self.search_retry_pending
            && self.search_highlights.finished(now)
    }

    fn focus_search_result(
        &mut self,
        setting: &'static SearchableSetting,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.navigation.focus_search_result(setting);
        if setting.section == SettingsSection::Notifications {
            self.notif.focus_search_target(setting.anchor_id);
        }

        if self.navigation.selection == SettingsSection::StartHere {
            crate::permission_center::refresh(cx);
        }
        self.scroll_to_active_search_anchor(window, cx);
        cx.notify();
    }

    fn select(&mut self, section: SettingsSection, window: &mut Window, cx: &mut Context<Self>) {
        self.navigation.selection = section;
        self.navigation.clear_anchor();
        self.scroll_handle.set_offset(gpui::point(px(0.), px(0.)));
        if section == SettingsSection::StartHere {
            crate::permission_center::refresh(cx);
        }
        self.scroll_to_active_search_anchor(window, cx);
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
        let searching = !self.navigation.search_query.is_empty();
        let matches = sections_matching(&self.navigation.search_query);
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
                let selected = section == self.navigation.selection;
                list =
                    list.child(
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
                            .on_click(cx.listener(move |this, _, window, cx| {
                                this.select(section, window, cx)
                            })),
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
    fn detail(&self, context: &SectionContext, cx: &Context<Self>) -> gpui::Stateful<gpui::Div> {
        let chrome = context.chrome;
        let section = self.navigation.selection;
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
                                        if section == SettingsSection::DangerousCommands {
                                            mine::guard_update(cx, |guard| {
                                                guard.is_enabled = true;
                                                guard.clear_allow_list();
                                                guard.clear_block_list();
                                            });
                                        }
                                        if section == SettingsSection::SnippetsTools {
                                            crate::repository::reset_discovered_repositories(cx);
                                        }
                                        update(cx, |s| s.reset_section(section))
                                    }),
                            )
                        }),
                )
                .child(widgets::description(section.description(), chrome)),
        );
        page = page.child(anchors::with_search_scope(
            section,
            self.search_anchors.clone(),
            anchors::SearchPresentation {
                bounds: self.target_bounds.clone(),
                strengths: self
                    .search_highlights
                    .values(cx.background_executor().now()),
                accent: chrome.accent,
                scroll_handle: self.scroll_handle.clone(),
            },
            || summary::section(context),
        ));
        if let Some((text, error)) = cx.try_global::<UiMessage>().and_then(|m| m.0.clone()) {
            page = page.child(div().pb_3().child(widgets::banner(text, error, chrome)));
        }
        if !self.navigation.search_query.is_empty() {
            let hits = matching_settings(section, &self.navigation.search_query);
            if !hits.is_empty() {
                page = page.child(div().flex().flex_wrap().gap_2().pb_3().children(
                    hits.into_iter().map(|setting| {
                        widgets::chip(
                            gpui::SharedString::from(format!("search-hit-{}", setting.id)),
                            setting.localized_title(),
                            self.active_search_anchor_id() == Some(setting.anchor_id),
                            chrome,
                        )
                        .on_click(cx.listener(
                            move |this, _, window, cx| {
                                this.focus_search_result(setting, window, cx)
                            },
                        ))
                    }),
                ));
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
            page = anchors::with_search_scope(
                section,
                self.search_anchors.clone(),
                anchors::SearchPresentation {
                    bounds: self.target_bounds.clone(),
                    strengths: self
                        .search_highlights
                        .values(cx.background_executor().now()),
                    accent: chrome.accent,
                    scroll_handle: self.scroll_handle.clone(),
                },
                || page.children(blocks.iter().map(|block| block(context))),
            );
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
            .track_scroll(&self.scroll_handle)
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
        #[cfg(any(test, feature = "native-parity-fixture"))]
        let sidebar = {
            use gpui_kit::test::TestSupportExt;
            sidebar.test_support()
        };
        let settings = Settings::get(cx).clone();
        let root = cx.global::<AppData>().root.clone();
        let files = cx.global::<ConfigFiles>();
        let sync = cx.try_global::<SyncState>();
        let known_repo_roots = crate::repository::known_roots(cx);
        let permissions = crate::permission_center::snapshot(cx, &known_repo_roots);
        let context = SectionContext {
            settings: &settings,
            chrome,
            root: &root,
            view: self,
            selected_repo: repositories::selected_repo(cx),
            known_repo_roots,
            recent_repo_roots: crate::repository::recent_roots(cx).ok(),
            notification_warning: cx
                .try_global::<crate::notifications::NotificationCenter>()
                .and_then(|center| center.banner.warning().map(str::to_owned)),
            permissions,
            config: files,
            sync,
            monitoring: MonitoringStatus::get(cx),
            login_status: login_item::current().status(),
            home: root.home().to_string_lossy().into_owned(),
            logs: if matches!(
                self.navigation.selection,
                SettingsSection::History | SettingsSection::LogsHistory
            ) {
                logs::LogsData::read(cx)
            } else {
                logs::LogsData::default()
            },
            confirm_clear: logs::confirm_pending(cx),
            remote: crate::remote::status(cx),
            proxy_status: Some(crate::proxy::status(cx)),
            proxy_stats: if self.navigation.selection == SettingsSection::ApiProxy {
                crate::proxy::today_stats(cx)
            } else {
                None
            },
            cto: token_optimization::CtoData::read(
                self.navigation.selection == SettingsSection::TokenOptimization,
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

#[cfg(test)]
mod rendered_targets_test;

#[cfg(test)]
mod search_navigation_test;
