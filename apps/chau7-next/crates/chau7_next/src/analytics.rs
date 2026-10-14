//! Terminal Analytics dashboard (`Analytics/AnalyticsDashboardView.swift`,
//! `TerminalAnalytics.swift`, ANL-001 and ANL-002): summary cards (commands
//! in history, success rate, average duration) and the ten most used
//! commands with bars scaled to the most frequent one.
//!
//! The Swift view is never opened; Chau7 Next opens it from View >
//! Terminal Analytics (and the command palette), in its own window,
//! refreshed each time it is opened. The session timeline (ANL-003 to
//! ANL-007) lives in `workspace/timeline.rs`.

use chau7_next_core::terminal_analytics::{RECENT_LIMIT, TOP_COMMANDS, TerminalAnalytics};
use gpui::{
    AnyWindowHandle, App, Context, Global, Render, SharedString, WeakEntity, Window, WindowBounds,
    WindowOptions, div, prelude::*, px, size,
};
use gpui_kit::component::TitleBar;

use crate::theme::Chrome;

#[derive(Default)]
struct WindowHandle(Option<(AnyWindowHandle, WeakEntity<AnalyticsView>)>);
impl Global for WindowHandle {}

/// `TerminalAnalytics.refresh()` from the command history database.
fn load(cx: &App) -> TerminalAnalytics {
    let Some(history) = crate::history::service(cx) else {
        return TerminalAnalytics::default();
    };
    let (total, recent, top) = history.with_store(|s| {
        (
            s.total_count(),
            s.recent(RECENT_LIMIT),
            s.frequent_commands(TOP_COMMANDS),
        )
    });
    let analytics = TerminalAnalytics::compute(total, &recent, top);
    log::info!(
        "TerminalAnalytics: refreshed (total={}, successRate={})",
        analytics.total_commands,
        analytics.success_rate_string()
    );
    analytics
}

/// Open the dashboard, or bring it to the front with fresh numbers.
pub fn open(cx: &mut App) {
    if let Some((handle, view)) = cx.try_global::<WindowHandle>().and_then(|h| h.0.clone())
        && let Some(view) = view.upgrade()
        && handle
            .update(cx, |_, window, cx| {
                window.activate_window();
                view.update(cx, |v, cx| {
                    v.data = load(cx);
                    cx.notify();
                });
            })
            .is_ok()
    {
        return;
    }
    let bounds = gpui::Bounds::centered(None, size(px(560.0), px(520.0)), cx);
    let options = WindowOptions {
        window_bounds: Some(WindowBounds::Windowed(bounds)),
        window_min_size: Some(size(px(420.0), px(320.0))),
        ..TitleBar::window_options()
    };
    match gpui_kit::open_window(options, cx, |window, cx| {
        window.set_window_title(&crate::l10n::tr("Terminal Analytics"));
        cx.new(|cx| AnalyticsView { data: load(cx) })
    }) {
        Ok((handle, view)) => cx.set_global(WindowHandle(Some((handle, view.downgrade())))),
        Err(err) => log::error!("analytics window: {err}"),
    }
}

pub struct AnalyticsView {
    data: TerminalAnalytics,
}

/// `StatCard`: an icon, the value and its title.
fn stat_card(title: &'static str, value: String, icon: &'static str, chrome: Chrome) -> gpui::Div {
    div()
        .flex_1()
        .flex()
        .flex_col()
        .items_center()
        .gap_2()
        .p_4()
        .rounded_lg()
        .bg(chrome.tab_bg)
        .child(div().text_xl().text_color(chrome.accent).child(icon))
        .child(
            div()
                .text_lg()
                .font_weight(gpui::FontWeight::BOLD)
                .child(value),
        )
        .child(div().text_xs().text_color(chrome.text_muted).child(title))
}

impl Render for AnalyticsView {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let chrome = Chrome::panels(cx);
        let a = &self.data;
        let mut commands = div()
            .flex()
            .flex_col()
            .gap_1()
            .p_3()
            .rounded_lg()
            .border_1()
            .border_color(chrome.border)
            .child(
                div()
                    .text_sm()
                    .font_weight(gpui::FontWeight::SEMIBOLD)
                    .pb_1()
                    .child(crate::l10n::tr("Most Used Commands")),
            );
        for (i, cmd) in a.top_commands.iter().take(TOP_COMMANDS).enumerate() {
            commands = commands.child(
                div()
                    .id(SharedString::from(format!("analytics-cmd-{i}")))
                    .flex()
                    .items_center()
                    .gap_2()
                    .child(
                        div()
                            .flex_1()
                            .min_w_0()
                            .font_family("Menlo")
                            .text_sm()
                            .overflow_hidden()
                            .whitespace_nowrap()
                            .text_ellipsis()
                            .child(cmd.command.clone()),
                    )
                    .child(
                        div()
                            .text_sm()
                            .text_color(chrome.text_muted)
                            .child(chau7_next_core::proxy::format_grouped(cmd.count)),
                    )
                    .child(
                        div().w(px(150.0)).flex().justify_end().child(
                            div()
                                .w(px(a.bar_width(cmd.count)))
                                .h(px(16.0))
                                .rounded(px(3.0))
                                .bg(chrome.accent.opacity(0.3)),
                        ),
                    ),
            );
        }
        if a.top_commands.is_empty() {
            commands = commands.child(
                div()
                    .text_sm()
                    .text_color(chrome.text_muted)
                    .child(crate::l10n::tr("No commands recorded yet.")),
            );
        }
        div()
            .size_full()
            .flex()
            .flex_col()
            .bg(chrome.panel_bg)
            .text_color(chrome.text)
            .child(
                crate::theme::panel_titlebar(chrome)
                    .child(div().text_sm().child(crate::l10n::tr("Terminal Analytics"))),
            )
            .child(
                div()
                    .id("analytics-scroll")
                    .flex_1()
                    .overflow_y_scroll()
                    .p_4()
                    .flex()
                    .flex_col()
                    .gap_5()
                    .child(
                        div()
                            .text_xl()
                            .font_weight(gpui::FontWeight::BOLD)
                            .child(crate::l10n::tr("Terminal Analytics")),
                    )
                    .child(
                        div()
                            .flex()
                            .gap_4()
                            .child(stat_card(
                                "Commands",
                                chau7_next_core::proxy::format_grouped(a.total_commands),
                                "\u{2328}",
                                chrome,
                            ))
                            .child(stat_card(
                                "Success Rate",
                                a.success_rate_string(),
                                "\u{2713}",
                                chrome,
                            ))
                            .child(stat_card(
                                "Avg Duration",
                                a.avg_duration_string(),
                                "\u{23f1}",
                                chrome,
                            )),
                    )
                    .child(commands),
            )
    }
}
