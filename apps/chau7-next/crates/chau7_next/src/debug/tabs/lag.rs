//! Lag tab (`lagTimelineView`): input, output and highlight lag spikes of
//! the active tab, or of all tabs.

use chau7_next_core::debug_console::Tone;
use chau7_next_core::shell_latency::{LagEvent, LagKind};
use chrono::{DateTime, Utc};
use gpui::{AnyElement, Context, IntoElement, div, prelude::*, px};

use super::clock_text;
use crate::debug::console::DebugConsole;
use crate::debug::{snapshot, ui};
use crate::terminal::session::clock_seconds_now;
use crate::theme::Chrome;
use crate::workspace::TabDebugInfo;

fn kind_tone(kind: LagKind) -> Tone {
    match kind {
        LagKind::Input | LagKind::InputDispatch => Tone::Info,
        LagKind::Output => Tone::Accent,
        LagKind::Highlight => Tone::Warn,
    }
}

/// Wall-clock time of an event on the latency clock.
fn wall_time(event: &LagEvent) -> DateTime<Utc> {
    let ago = (clock_seconds_now() - event.at).max(0.0);
    Utc::now() - chrono::Duration::milliseconds((ago * 1000.0) as i64)
}

impl DebugConsole {
    pub(in crate::debug) fn lag_tab(
        &mut self,
        chrome: Chrome,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let all = self.lag_all;
        let header = div()
            .flex()
            .items_center()
            .justify_between()
            .p_2()
            .border_b_1()
            .border_color(chrome.border)
            .child(
                ui::switch("lag-all", "All tabs", all, chrome).on_click(cx.listener(
                    |this, _, _, cx| {
                        this.lag_all = !this.lag_all;
                        cx.notify();
                    },
                )),
            )
            .child(
                ui::button("lag-clear", "Clear", chrome).on_click(cx.listener(
                    move |this, _, _, cx| {
                        if let Some((_, workspace)) = snapshot::active_workspace(cx) {
                            workspace.read(cx).clear_lag_timelines(!this.lag_all, cx);
                        }
                        cx.notify();
                    },
                )),
            );

        let tabs = snapshot::tabs(cx);
        let mut events: Vec<(&TabDebugInfo, &LagEvent)> = tabs
            .iter()
            .filter(|t| all || t.selected)
            .flat_map(|t| t.lag_timeline.iter().map(move |e| (t, e)))
            .collect();
        events.sort_by(|a, b| b.1.at.total_cmp(&a.1.at));

        let mut list = div().flex().flex_col().gap_1p5();
        if events.is_empty() {
            list = list.child(
                div()
                    .py_5()
                    .flex()
                    .justify_center()
                    .child(ui::caption("No lag spikes recorded yet.", chrome)),
            );
        }
        for (tab, event) in events {
            let color = ui::tone_color(kind_tone(event.kind), chrome);
            let kind_label = match event.kind {
                LagKind::Input => "INPUT→OUTPUT",
                LagKind::InputDispatch => "INPUT DISPATCH",
                LagKind::Output => "OUTPUT PAINT",
                LagKind::Highlight => "HIGHLIGHT",
            };
            let percentiles = match (event.p50, event.p95) {
                (Some(p50), Some(p95)) => Some(format!("p50/p95 {p50}/{p95}ms")),
                _ => None,
            };
            list = list.child(
                div()
                    .flex()
                    .flex_col()
                    .gap_0p5()
                    .px_2()
                    .py_1p5()
                    .rounded_md()
                    .bg(chrome.tab_bg.opacity(0.5))
                    .child(
                        div()
                            .flex()
                            .items_center()
                            .justify_between()
                            .child(
                                div()
                                    .flex()
                                    .items_center()
                                    .gap_2()
                                    .child(div().size(px(8.0)).rounded_full().bg(color))
                                    .child(
                                        div()
                                            .text_xs()
                                            .font_family("Menlo")
                                            .font_weight(gpui::FontWeight::SEMIBOLD)
                                            .text_color(color)
                                            .child(kind_label),
                                    )
                                    .child(ui::mono_line(
                                        clock_text(wall_time(event)),
                                        chrome.text_muted,
                                    )),
                            )
                            .child(
                                div()
                                    .text_xs()
                                    .font_family("Menlo")
                                    .font_weight(gpui::FontWeight::SEMIBOLD)
                                    .child(format!("{}ms", event.elapsed_ms)),
                            ),
                    )
                    .child(
                        div()
                            .flex()
                            .gap_3()
                            .child(ui::mono_line(
                                format!("avg {}ms", event.average_ms),
                                chrome.text_muted,
                            ))
                            .when_some(percentiles, |d, text| {
                                d.child(ui::mono_line(text, chrome.text_muted))
                            })
                            .child(ui::mono_line(
                                format!("n={}", event.sample_count),
                                chrome.text_muted,
                            )),
                    )
                    .child(
                        div()
                            .text_xs()
                            .text_color(chrome.text_muted)
                            .overflow_hidden()
                            .child(format!(
                                "{} \u{2022} {} \u{2022} {}",
                                tab.title,
                                tab.ai_app.clone().unwrap_or_else(|| "none".into()),
                                tab.cwd
                            )),
                    ),
            );
        }
        div()
            .size_full()
            .flex()
            .flex_col()
            .child(header)
            .child(ui::page("lag-page", list).flex_1().min_h_0())
            .into_any_element()
    }
}
