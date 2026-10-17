//! The Debug Console window (`DebugConsoleView.swift`): a 700x500 window with
//! a row of tabs. The built-in tabs are in `tabs/`; modules add their own
//! with `debug::register_panel`.

use chau7_next_core::debug_console::CtoPeriod;
use chau7_next_core::logging::LogFilter;
use gpui::{
    AnyElement, AnyWindowHandle, App, Bounds, Context, Entity, Global, Render, SharedString, Task,
    Window, WindowBounds, WindowOptions, div, prelude::*, px, size,
};
use gpui_kit::component::TitleBar;
use gpui_kit::component::input::{InputEvent, InputState, TextareaState};

use super::{registry, ui};
use crate::theme::Chrome;

/// Window size in Swift (`DebugConsoleView`: 700 x 500).
const WIDTH: f32 = 700.0;
const HEIGHT: f32 = 500.0;

/// The tabs of the console.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Tab {
    State,
    TokenOptimizer,
    Events,
    Lag,
    Perf,
    Logs,
    Report,
    Analytics,
    Health,
    /// A tab added with `register_panel`, by id.
    Custom(&'static str),
}

impl Tab {
    pub const BUILT_IN: [Tab; 9] = [
        Tab::State,
        Tab::TokenOptimizer,
        Tab::Events,
        Tab::Lag,
        Tab::Perf,
        Tab::Logs,
        Tab::Report,
        Tab::Analytics,
        Tab::Health,
    ];

    pub fn title(self) -> &'static str {
        match self {
            Tab::State => "State",
            Tab::TokenOptimizer => "Token Optimizer",
            Tab::Events => "Events",
            Tab::Lag => "Lag",
            Tab::Perf => "Perf",
            Tab::Logs => "Logs",
            Tab::Report => "Report",
            Tab::Analytics => "Analytics",
            Tab::Health => "Health",
            Tab::Custom(_) => "",
        }
    }
}

/// Analytics sub-pages (`AnalyticsMode`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AnalyticsMode {
    ApiCalls,
    AiRuns,
    Repos,
}

/// The open console, if any.
#[derive(Default)]
struct ConsoleWindow(Option<AnyWindowHandle>);
impl Global for ConsoleWindow {}

/// Show the console on `tab`, or the last one shown.
pub fn open(tab: Option<Tab>, cx: &mut App) {
    if let Some(handle) = cx.try_global::<ConsoleWindow>().and_then(|w| w.0) {
        let shown = handle
            .update(cx, |view, window, cx| {
                window.activate_window();
                if let Some(tab) = tab
                    && let Ok(view) = view.downcast::<DebugConsole>()
                {
                    view.update(cx, |view, cx| view.select(tab, cx));
                }
            })
            .is_ok();
        if shown {
            return;
        }
    }
    let bounds = Bounds::centered(None, size(px(WIDTH), px(HEIGHT)), cx);
    let options = WindowOptions {
        window_bounds: Some(WindowBounds::Windowed(bounds)),
        window_min_size: Some(size(px(520.0), px(360.0))),
        ..TitleBar::window_options()
    };
    match gpui_kit::open_window(options, cx, |window, cx| {
        cx.new(|cx| DebugConsole::new(tab.unwrap_or(Tab::State), window, cx))
    }) {
        Ok((handle, _)) => cx.set_global(ConsoleWindow(Some(handle))),
        Err(err) => log::error!("debug console: {err}"),
    }
}

/// Cmd+Opt+L: close the console when it is open, else open it
/// (`DebugConsoleController.toggle`).
pub fn toggle(cx: &mut App) {
    if let Some(handle) = cx.try_global::<ConsoleWindow>().and_then(|w| w.0) {
        let closed = handle
            .update(cx, |_, window, _| window.remove_window())
            .is_ok();
        cx.set_global(ConsoleWindow(None));
        if closed {
            return;
        }
    }
    open(None, cx);
}

pub struct DebugConsole {
    pub(super) tab: Tab,
    pub(super) auto_refresh: bool,
    pub(super) cto_period: CtoPeriod,
    pub(super) cto_advanced: bool,
    pub(super) events_all: bool,
    pub(super) lag_all: bool,
    pub(super) perf_slow_only: bool,
    pub(super) perf_export_status: Option<String>,
    pub(super) log_filter: LogFilter,
    pub(super) log_input: Entity<InputState>,
    /// Newest first (`logs`).
    pub(super) log_lines: Vec<String>,
    pub(super) analytics_mode: AnalyticsMode,
    pub(super) report_input: Entity<TextareaState>,
    pub(super) last_report: Option<String>,
    /// Sizes of the `.log` files, biggest first (Health tab).
    pub(super) log_files: Vec<(String, u64)>,
    _refresh: Task<()>,
    _subscriptions: Vec<gpui::Subscription>,
}

impl DebugConsole {
    fn new(tab: Tab, window: &mut Window, cx: &mut Context<Self>) -> Self {
        let log_input =
            cx.new(|cx| InputState::new(window, cx).placeholder(crate::l10n::tr("Filter logs...")));
        let report_input = cx.new(|cx| TextareaState::new(window, cx));
        let filter_sub = cx.subscribe(&log_input, |this, input, event: &InputEvent, cx| {
            if matches!(event, InputEvent::Change) {
                this.log_filter.text = input.read(cx).value().to_string();
                cx.notify();
            }
        });
        let mut console = Self {
            tab,
            auto_refresh: true,
            cto_period: CtoPeriod::Session,
            cto_advanced: false,
            events_all: true,
            lag_all: false,
            perf_slow_only: true,
            perf_export_status: None,
            log_filter: LogFilter::default(),
            log_input,
            log_lines: Vec::new(),
            analytics_mode: AnalyticsMode::ApiCalls,
            report_input,
            last_report: None,
            log_files: Vec::new(),
            _refresh: Task::ready(()),
            _subscriptions: vec![filter_sub],
        };
        console.load_logs();
        console.load_health(cx);
        console.start_refresh(cx);
        console
    }

    /// Every second while Auto-refresh is on (`startRefresh`).
    fn start_refresh(&mut self, cx: &mut Context<Self>) {
        self._refresh = cx.spawn(async move |this, cx| {
            loop {
                cx.background_executor()
                    .timer(std::time::Duration::from_secs(1))
                    .await;
                let alive = this.update(cx, |this, cx| {
                    if this.auto_refresh && this.tab_wants_refresh(cx) {
                        this.refresh(cx);
                    }
                });
                if alive.is_err() {
                    break;
                }
            }
        });
    }

    /// Reload what the visible tab reads from disk, then redraw.
    pub(super) fn refresh(&mut self, cx: &mut Context<Self>) {
        match self.tab {
            Tab::Logs => self.load_logs(),
            Tab::Health => self.load_health(cx),
            _ => {}
        }
        cx.notify();
    }

    /// A registered panel opts in to the timer with `Panel::auto_refresh`.
    fn tab_wants_refresh(&self, cx: &App) -> bool {
        match self.tab {
            Tab::Custom(id) => registry::panels(cx)
                .iter()
                .any(|p| p.id == id && p.auto_refresh),
            _ => true,
        }
    }

    pub(super) fn select(&mut self, tab: Tab, cx: &mut Context<Self>) {
        self.tab = tab;
        self.refresh(cx);
    }

    /// The tabs in order: built-in, then registered panels.
    fn tab_list(&self, cx: &App) -> Vec<(Tab, SharedString)> {
        let mut tabs: Vec<(Tab, SharedString)> = Tab::BUILT_IN
            .iter()
            .map(|t| (*t, SharedString::from(t.title())))
            .collect();
        tabs.extend(
            registry::panels(cx)
                .into_iter()
                .map(|p| (Tab::Custom(p.id), p.title)),
        );
        tabs
    }

    fn header(&self, chrome: Chrome, cx: &mut Context<Self>) -> gpui::Div {
        div()
            .flex()
            .items_center()
            .justify_between()
            .px_3()
            .py_2()
            .child(
                div()
                    .flex()
                    .items_center()
                    .gap_2()
                    .child(
                        div()
                            .text_color(ui::tone_color(
                                chau7_next_core::debug_console::Tone::Warn,
                                chrome,
                            ))
                            .child("\u{1F41E}"),
                    )
                    .child(
                        div()
                            .text_sm()
                            .font_weight(gpui::FontWeight::SEMIBOLD)
                            .child(crate::l10n::tr("Debug Console")),
                    ),
            )
            .child(
                div()
                    .flex()
                    .items_center()
                    .gap_3()
                    .child(
                        ui::switch("auto-refresh", "Auto-refresh", self.auto_refresh, chrome)
                            .on_click(cx.listener(|this, _, _, cx| {
                                this.auto_refresh = !this.auto_refresh;
                                cx.notify();
                            })),
                    )
                    .child(
                        ui::button("console-close", "\u{2715}", chrome)
                            .on_click(|_, window, _| window.remove_window()),
                    ),
            )
    }

    fn tab_bar(&self, chrome: Chrome, cx: &mut Context<Self>) -> gpui::Div {
        let mut row = div()
            .flex()
            .flex_wrap()
            .gap_1()
            .px_2()
            .py_1p5()
            .border_t_1()
            .border_b_1()
            .border_color(chrome.border);
        for (tab, title) in self.tab_list(cx) {
            let id = match tab {
                Tab::Custom(id) => SharedString::from(format!("tab-custom-{id}")),
                other => SharedString::from(format!("tab-{}", other.title())),
            };
            row = row.child(
                ui::chip(id, title, tab == self.tab, chrome.accent, chrome)
                    .on_click(cx.listener(move |this, _, _, cx| this.select(tab, cx))),
            );
        }
        row
    }

    fn body(&mut self, chrome: Chrome, window: &mut Window, cx: &mut Context<Self>) -> AnyElement {
        match self.tab {
            Tab::State => self.state_tab(chrome, cx),
            Tab::TokenOptimizer => self.token_optimizer_tab(chrome, cx),
            Tab::Events => self.events_tab(chrome, cx),
            Tab::Lag => self.lag_tab(chrome, cx),
            Tab::Perf => self.perf_tab(chrome, cx),
            Tab::Logs => self.logs_tab(chrome, cx),
            Tab::Report => self.report_tab(chrome, cx),
            Tab::Analytics => self.analytics_tab(chrome, cx),
            Tab::Health => self.health_tab(chrome, cx),
            Tab::Custom(id) => match registry::panels(cx).into_iter().find(|p| p.id == id) {
                Some(panel) => (panel.render)(window, cx),
                None => {
                    ui::empty_note("This tab is no longer available.", chrome).into_any_element()
                }
            },
        }
    }
}

impl Render for DebugConsole {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let chrome = Chrome::panels(cx);
        window.set_window_title(&crate::l10n::tr("Chau7 Next Debug Console"));
        let body = self.body(chrome, window, cx);
        div()
            .size_full()
            .flex()
            .flex_col()
            .bg(chrome.panel_bg)
            .text_color(chrome.text)
            .child(
                crate::theme::panel_titlebar(chrome)
                    .child(div().text_sm().child(crate::l10n::tr("Debug Console"))),
            )
            .child(self.header(chrome, cx))
            .child(self.tab_bar(chrome, cx))
            // Each tab scrolls its own list (`ui::page`).
            .child(div().flex_1().min_h_0().child(body))
    }
}
