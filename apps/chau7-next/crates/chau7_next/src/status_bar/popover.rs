//! The command center popover (`StatusBarPanelView`): a 380 by 520 pt
//! window under the menu bar icon. It closes when it loses the focus (a
//! click in another window or app) or on Escape, and redraws every second.

use std::time::Duration;

use chau7_next_core::command_center::{
    self as cc, HeroKind, POPOVER_HEIGHT, POPOVER_WIDTH, PanelCommand, PanelModel, QuickCommand,
    REFRESH_SECS, SessionSummary, TimelineEntry, Tone,
};
use gpui::{
    AnyWindowHandle, App, Bounds, Context, FontWeight, Hsla, IntoElement, Render, SharedString,
    Subscription, Task, Window, WindowBackgroundAppearance, WindowBounds, WindowKind,
    WindowOptions, div, point, prelude::*, px, size,
};

use crate::theme::Chrome;

/// Open the popover with its top left corner at (`x`, `y`) in window
/// coordinates.
pub fn open(x: f32, y: f32, model: PanelModel, cx: &mut App) -> Option<AnyWindowHandle> {
    let bounds = Bounds::new(
        point(px(x), px(y)),
        size(px(POPOVER_WIDTH), px(POPOVER_HEIGHT)),
    );
    let options = WindowOptions {
        window_bounds: Some(WindowBounds::Windowed(bounds)),
        titlebar: None,
        focus: true,
        show: true,
        kind: WindowKind::PopUp,
        is_movable: false,
        is_resizable: false,
        is_minimizable: false,
        window_background: WindowBackgroundAppearance::Transparent,
        ..Default::default()
    };
    match gpui_kit::open_window(options, cx, move |window, cx| {
        cx.new(|cx| PopoverView::new(model, window, cx))
    }) {
        Ok((handle, _)) => Some(handle),
        Err(err) => {
            log::error!("command center: {err}");
            None
        }
    }
}

struct PopoverView {
    model: PanelModel,
    quit_confirm: bool,
    activity_expanded: bool,
    copied_snippet_id: Option<String>,
    /// The window was active once: only then does losing it close the popover.
    was_active: bool,
    focus: gpui::FocusHandle,
    _refresh: Task<()>,
    _activation: Subscription,
}

impl PopoverView {
    fn new(model: PanelModel, window: &mut Window, cx: &mut Context<Self>) -> Self {
        let refresh = cx.spawn(async move |this, cx| {
            loop {
                cx.background_executor()
                    .timer(Duration::from_secs(REFRESH_SECS))
                    .await;
                let fresh = cx.update(|cx| crate::status_bar::panel_model(cx));
                if this
                    .update(cx, |view, cx| {
                        view.model = fresh;
                        cx.notify();
                    })
                    .is_err()
                {
                    break;
                }
            }
        });
        let activation = cx.observe_window_activation(window, |this, window, cx| {
            if window.is_window_active() {
                this.was_active = true;
            } else if this.was_active {
                cx.defer(crate::status_bar::popover_blurred);
            }
        });
        Self {
            model,
            quit_confirm: false,
            activity_expanded: false,
            copied_snippet_id: None,
            was_active: false,
            focus: cx.focus_handle(),
            _refresh: refresh,
            _activation: activation,
        }
    }

    fn command(&mut self, command: PanelCommand, cx: &mut Context<Self>) {
        // Defer commands that can close the window. Clipboard fallback keeps
        // the panel open and displays explicit copy feedback.
        if let PanelCommand::RunSnippet(id) = command {
            let this = cx.entity().downgrade();
            cx.defer(move |cx| match super::run_snippet(&id, cx) {
                super::SnippetOutcome::Inserted => crate::status_bar::close_popover(cx),
                super::SnippetOutcome::Copied => {
                    let _ = this.update(cx, |view, cx| {
                        view.copied_snippet_id = Some(id);
                        cx.notify();
                    });
                }
                super::SnippetOutcome::Unavailable => {}
            });
        } else {
            cx.defer(move |cx| crate::status_bar::run(command, cx));
        }
    }
}

fn tone_color(tone: Tone, chrome: Chrome) -> Hsla {
    match tone {
        Tone::Blue => gpui::hsla(0.58, 0.85, 0.6, 1.0),
        Tone::Orange => gpui::hsla(0.08, 0.95, 0.55, 1.0),
        Tone::Yellow => gpui::hsla(0.14, 0.95, 0.55, 1.0),
        Tone::Red => gpui::hsla(0.0, 0.75, 0.55, 1.0),
        Tone::Green => gpui::hsla(0.37, 0.65, 0.48, 1.0),
        Tone::Gray => gpui::hsla(0.0, 0.0, 0.5, 1.0),
        Tone::Cyan => gpui::hsla(0.5, 0.8, 0.5, 1.0),
        Tone::Purple => gpui::hsla(0.77, 0.6, 0.6, 1.0),
        Tone::Secondary => chrome.text_muted,
    }
}

/// A plain character for an SF Symbol of the model.
fn glyph(symbol: &str) -> &'static str {
    match symbol {
        "hand.raised" | "hand.raised.fill" => "!",
        "wrench.and.screwdriver" | "gearshape.2" => "\u{2699}",
        "bubble.left.and.exclamationmark.bubble.right" | "exclamationmark.circle" => "!",
        "exclamationmark.triangle" => "\u{25B2}",
        "text.bubble" | "doc.text" => "\u{25A4}",
        "keyboard" => "\u{2328}",
        "bell" => "\u{25CB}",
        "bell.fill" => "\u{25CF}",
        "bell.slash" => "\u{25CC}",
        "checkmark.shield" | "checkmark.circle" => "\u{2713}",
        "moon" => "\u{263E}",
        "person.fill" => "\u{263A}",
        "hammer" => "\u{2692}",
        "xmark.circle" => "\u{2715}",
        "arrow.up.arrow.down" => "\u{21C5}",
        "gauge.with.dots.needle.33percent" => "\u{25D4}",
        "dollarsign.circle" => "$",
        "terminal.fill" => "\u{25A3}",
        "terminal" => "\u{25A2}",
        "clock.arrow.circlepath" => "\u{21BB}",
        "app.badge" => "\u{25AA}",
        _ => "\u{2022}",
    }
}

fn box_label(text: &'static str, chrome: Chrome) -> impl IntoElement {
    div()
        .text_size(px(12.0))
        .font_weight(FontWeight::SEMIBOLD)
        .text_color(chrome.text_muted)
        .child(text)
}

impl Render for PopoverView {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        window.set_window_title(cc::ITEM_NAME);
        if !self.focus.is_focused(window) {
            window.focus(&self.focus, cx);
        }
        let chrome = Chrome::panels(cx);
        let body = div()
            .id("command-center-body")
            .flex_1()
            .min_h_0()
            .overflow_y_scroll()
            .p(px(12.0))
            .flex()
            .flex_col()
            .gap(px(12.0))
            .child(self.live_sessions(chrome, cx))
            .child(self.quick_commands(chrome, cx))
            .child(self.activity(chrome, cx));
        div()
            .id("command-center")
            .track_focus(&self.focus)
            .on_key_down(cx.listener(|_, event: &gpui::KeyDownEvent, _, cx| {
                if event.keystroke.key == "escape" {
                    cx.defer(crate::status_bar::close_popover);
                }
            }))
            .size_full()
            .flex()
            .flex_col()
            .bg(chrome.panel_bg)
            .text_color(chrome.text)
            .border_1()
            .border_color(chrome.border)
            .rounded(px(10.0))
            .overflow_hidden()
            .child(self.hero(chrome, cx))
            .child(div().h(px(1.0)).bg(chrome.border))
            .child(body)
            .child(div().h(px(1.0)).bg(chrome.border))
            .child(self.footer(chrome, cx))
    }
}

impl PopoverView {
    /// Current Swift hero states, including direct controls when monitoring is paused.
    fn hero(&self, chrome: Chrome, cx: &mut Context<Self>) -> gpui::Div {
        let (symbol, tone) = match self.model.hero.kind {
            HeroKind::ApprovalRequired => ("!", Tone::Red),
            HeroKind::WaitingForInput => ("\u{2328}", Tone::Orange),
            HeroKind::MonitoringPaused => ("\u{25CC}", Tone::Gray),
            HeroKind::Running => ("\u{25CF}", Tone::Blue),
            HeroKind::Quiet => ("\u{2713}", Tone::Green),
        };
        div()
            .p(px(12.0))
            .flex()
            .items_center()
            .gap(px(8.0))
            .child(div().text_color(tone_color(tone, chrome)).child(symbol))
            .child(
                div()
                    .flex_1()
                    .min_w_0()
                    .flex()
                    .flex_col()
                    .gap(px(2.0))
                    .child(
                        div()
                            .text_size(px(13.0))
                            .font_weight(FontWeight::SEMIBOLD)
                            .child(self.model.hero.title.clone()),
                    )
                    .child(
                        div()
                            .text_size(px(11.0))
                            .text_color(chrome.text_muted)
                            .child(self.model.hero.detail.clone()),
                    ),
            )
            .when(self.model.hero.kind == HeroKind::MonitoringPaused, |d| {
                d.child(
                    div()
                        .id("resume-monitoring")
                        .px(px(8.0))
                        .py(px(4.0))
                        .rounded_md()
                        .cursor_pointer()
                        .bg(chrome.accent)
                        .text_color(gpui::white())
                        .text_size(px(11.0))
                        .child(crate::l10n::tr("Resume"))
                        .on_click(cx.listener(|this, _, _, cx| {
                            this.command(PanelCommand::SetMonitoring(true), cx);
                        })),
                )
                .child(
                    div()
                        .id("monitoring-settings")
                        .px(px(6.0))
                        .py(px(4.0))
                        .cursor_pointer()
                        .text_size(px(11.0))
                        .child(crate::l10n::tr("Monitoring"))
                        .on_click(cx.listener(|this, _, _, cx| {
                            this.command(PanelCommand::OpenMonitoringSettings, cx);
                        })),
                )
            })
    }

    /// The Live Sessions box; nothing without sessions.
    fn live_sessions(&self, chrome: Chrome, cx: &mut Context<Self>) -> gpui::Div {
        if self.model.action_sessions.is_empty() {
            return div();
        }
        let mut cards = Vec::new();
        for (i, session) in self.model.action_sessions.iter().enumerate() {
            cards.push(self.session_card(i, session, chrome, cx));
        }
        div()
            .p(px(10.0))
            .flex()
            .flex_col()
            .gap(px(8.0))
            .rounded_lg()
            .bg(chrome.accent.opacity(0.08))
            .border_1()
            .border_color(chrome.accent.opacity(0.2))
            .child(box_label("Action list", chrome))
            .children(cards)
    }

    /// `LiveSessionCard`.
    fn session_card(
        &self,
        index: usize,
        session: &SessionSummary,
        chrome: Chrome,
        cx: &mut Context<Self>,
    ) -> impl IntoElement + use<> {
        let tab_id = session.tab_id;
        let dot = tone_color(session.state.dot_tone(), chrome);
        let state_color = tone_color(session.state.text_tone(), chrome);
        let age = (crate::workspace::AppData::now(cx) - session.last_activity).max(0.0) as i64;
        let mut detail = div()
            .flex()
            .items_center()
            .gap(px(4.0))
            .text_color(state_color)
            .child(div().text_size(px(9.0)).child(glyph(session.state.icon())))
            .child(div().text_size(px(10.0)).child(session.state.description()));
        if session.show_app_name() {
            detail = detail.child(
                div()
                    .text_size(px(9.0))
                    .text_color(chrome.text_muted.opacity(0.7))
                    .child(session.app_name.clone()),
            );
        }
        if let Some(context) = session.context_label() {
            detail = detail.child(
                div()
                    .text_size(px(9.0))
                    .text_color(chrome.text_muted.opacity(0.7))
                    .child(format!("\u{b7} {context}")),
            );
        }
        div()
            .id(SharedString::from(format!("session-{index}")))
            .px(px(4.0))
            .py(px(4.0))
            .rounded_md()
            .flex()
            .items_center()
            .gap(px(8.0))
            .cursor_pointer()
            .when(session.needs_attention(), |d| {
                d.bg(tone_color(Tone::Yellow, chrome).opacity(0.08))
            })
            .hover(|d| d.bg(chrome.tab_hover_bg))
            .child(
                div()
                    .size(px(16.0))
                    .flex()
                    .items_center()
                    .justify_center()
                    .child(
                        div()
                            .size(px(if session.state.has_ring() { 12.0 } else { 8.0 }))
                            .rounded_full()
                            .flex()
                            .items_center()
                            .justify_center()
                            .when(session.state.has_ring(), |d| {
                                d.border_2().border_color(dot.opacity(0.5))
                            })
                            .child(div().size(px(8.0)).rounded_full().bg(dot)),
                    ),
            )
            .child(
                div()
                    .flex_1()
                    .min_w_0()
                    .flex()
                    .flex_col()
                    .gap(px(2.0))
                    .child(
                        div()
                            .overflow_hidden()
                            .text_ellipsis()
                            .whitespace_nowrap()
                            .text_size(px(12.0))
                            .font_weight(FontWeight::MEDIUM)
                            .child(session.title.clone()),
                    )
                    .child(detail),
            )
            .child(
                div()
                    .text_size(px(10.0))
                    .text_color(chrome.text_muted.opacity(0.7))
                    .child(cc::time_ago(age)),
            )
            .child(
                div()
                    .text_size(px(9.0))
                    .text_color(chrome.text_muted.opacity(0.7))
                    .child("\u{203A}"),
            )
            .on_click(cx.listener(move |this, _, _, cx| {
                this.command(PanelCommand::FocusSession { tab_id }, cx)
            }))
    }

    /// Recent activity begins collapsed, retaining expansion across refreshes.
    fn activity(&self, chrome: Chrome, cx: &mut Context<Self>) -> gpui::Div {
        if self.model.timeline.is_empty() {
            return div();
        }
        let expanded = self.activity_expanded;
        let boxed = div()
            .p(px(10.0))
            .flex()
            .flex_col()
            .gap(px(8.0))
            .rounded_lg()
            .bg(chrome.tab_bg.opacity(0.5))
            .child(
                div()
                    .id("recent-activity-disclosure")
                    .flex()
                    .items_center()
                    .cursor_pointer()
                    .gap(px(6.0))
                    .child(if expanded { "\u{2304}" } else { "\u{203A}" })
                    .child(box_label("Recent activity", chrome))
                    .on_click(cx.listener(|this, _, _, cx| {
                        this.activity_expanded = !this.activity_expanded;
                        cx.notify();
                    })),
            );
        if expanded {
            boxed.children(
                self.model
                    .timeline
                    .iter()
                    .map(|entry| timeline_row(entry, chrome)),
            )
        } else {
            boxed
        }
    }

    /// The first five pinned snippets and their direct settings anchor.
    fn quick_commands(&self, chrome: Chrome, cx: &mut Context<Self>) -> gpui::Div {
        if self.model.quick_commands.is_empty() {
            return div();
        }
        div()
            .p(px(10.0))
            .flex()
            .flex_col()
            .gap(px(8.0))
            .rounded_lg()
            .bg(chrome.tab_bg.opacity(0.3))
            .child(
                div()
                    .flex()
                    .items_center()
                    .justify_between()
                    .child(box_label("Pinned snippets", chrome))
                    .child(
                        div()
                            .id("snippet-settings")
                            .cursor_pointer()
                            .text_size(px(11.0))
                            .child(crate::l10n::tr("Snippet settings"))
                            .on_click(cx.listener(|this, _, _, cx| {
                                this.command(PanelCommand::OpenSnippetSettings, cx);
                            })),
                    ),
            )
            .children(
                self.model
                    .quick_commands
                    .iter()
                    .enumerate()
                    .map(|(i, command)| self.snippet_row(i, command, chrome, cx)),
            )
    }

    fn snippet_row(
        &self,
        index: usize,
        command: &QuickCommand,
        chrome: Chrome,
        cx: &mut Context<Self>,
    ) -> impl IntoElement + use<> {
        let id = command.id.clone();
        div()
            .id(SharedString::from(format!("snippet-{index}")))
            .px(px(4.0))
            .py(px(4.0))
            .flex()
            .items_center()
            .gap(px(8.0))
            .rounded_md()
            .cursor_pointer()
            .hover(|d| d.bg(chrome.tab_hover_bg))
            .child(
                div()
                    .w(px(16.0))
                    .text_size(px(9.0))
                    .text_color(chrome.accent)
                    .child("\u{25B6}"),
            )
            .child(
                div()
                    .flex_1()
                    .min_w_0()
                    .overflow_hidden()
                    .text_ellipsis()
                    .whitespace_nowrap()
                    .text_size(px(11.0))
                    .font_weight(FontWeight::MEDIUM)
                    .child(
                        if self.copied_snippet_id.as_deref() == Some(command.id.as_str()) {
                            format!("{}: {}", command.title, crate::l10n::tr("Copied"))
                        } else {
                            command.title.clone()
                        },
                    ),
            )
            .child(
                div()
                    .text_size(px(9.0))
                    .text_color(chrome.text_muted.opacity(0.7))
                    .child("\u{203A}"),
            )
            .on_click(cx.listener(move |this, _, _, cx| {
                this.command(PanelCommand::RunSnippet(id.clone()), cx)
            }))
    }

    /// The version, and Quit with its confirmation.
    fn footer(&self, chrome: Chrome, cx: &mut Context<Self>) -> gpui::Div {
        let confirm = self.quit_confirm;
        let mut right = div().flex().items_center().gap(px(8.0));
        if confirm {
            right = right
                .child(
                    div()
                        .text_size(px(12.0))
                        .font_weight(FontWeight::MEDIUM)
                        .child(crate::l10n::tr("Quit Chau7 Next?")),
                )
                .child(
                    div()
                        .id("quit-cancel")
                        .px(px(8.0))
                        .py(px(3.0))
                        .rounded_md()
                        .cursor_pointer()
                        .text_size(px(11.0))
                        .border_1()
                        .border_color(chrome.border)
                        .bg(chrome.tab_bg)
                        .hover(|d| d.bg(chrome.tab_hover_bg))
                        .child(crate::l10n::tr("Cancel"))
                        .on_click(cx.listener(|this, _, _, cx| {
                            this.quit_confirm = false;
                            cx.notify();
                        })),
                )
                .child(
                    div()
                        .id("quit-confirm")
                        .px(px(8.0))
                        .py(px(3.0))
                        .rounded_md()
                        .cursor_pointer()
                        .text_size(px(11.0))
                        .text_color(gpui::white())
                        .bg(chrome.danger)
                        .hover(|d| d.opacity(0.85))
                        .child(crate::l10n::tr("Quit"))
                        .on_click(
                            cx.listener(|this, _, _, cx| this.command(PanelCommand::Quit, cx)),
                        ),
                );
        } else {
            right = right.child(
                div()
                    .id("quit")
                    .cursor_pointer()
                    .text_size(px(11.0))
                    .text_color(chrome.text_muted)
                    .hover(|d| d.text_color(chrome.text))
                    .child(crate::l10n::tr("Quit Chau7 Next"))
                    .on_click(cx.listener(|this, _, _, cx| {
                        this.quit_confirm = true;
                        cx.notify();
                    })),
            );
        }
        div()
            .p(px(10.0))
            .flex()
            .items_center()
            .justify_between()
            .bg(chrome.tab_bg)
            .when(!confirm, |d| {
                d.child(
                    div()
                        .id("default-settings")
                        .cursor_pointer()
                        .text_size(px(11.0))
                        .child(crate::l10n::tr("Settings"))
                        .on_click(cx.listener(|this, _, _, cx| {
                            this.command(PanelCommand::OpenSettings, cx);
                        })),
                )
            })
            .child(
                div()
                    .text_size(px(10.0))
                    .text_color(chrome.text_muted.opacity(0.7))
                    .child(format!("v{}", self.model.version)),
            )
            .child(right)
    }
}

/// `TimelineRow`.
fn timeline_row(entry: &TimelineEntry, chrome: Chrome) -> impl IntoElement {
    div()
        .py(px(2.0))
        .flex()
        .items_center()
        .gap(px(8.0))
        .when(entry.is_rate_limited, |d| d.opacity(0.5))
        .child(
            div()
                .w(px(16.0))
                .text_size(px(10.0))
                .text_color(tone_color(entry.tone, chrome))
                .child(glyph(entry.icon)),
        )
        .child(
            div()
                .flex_1()
                .min_w_0()
                .flex()
                .flex_col()
                .gap(px(1.0))
                .child(
                    div()
                        .overflow_hidden()
                        .text_ellipsis()
                        .whitespace_nowrap()
                        .text_size(px(11.0))
                        .font_weight(FontWeight::MEDIUM)
                        .child(entry.title.clone()),
                )
                .when(!entry.detail.is_empty(), |d| {
                    d.child(
                        div()
                            .overflow_hidden()
                            .text_ellipsis()
                            .whitespace_nowrap()
                            .text_size(px(10.0))
                            .text_color(chrome.text_muted)
                            .child(entry.detail.clone()),
                    )
                }),
        )
        .child(
            div()
                .font_family("Menlo")
                .text_size(px(9.0))
                .text_color(chrome.text_muted.opacity(0.7))
                .child(cc::timeline_time(entry.timestamp)),
        )
}
