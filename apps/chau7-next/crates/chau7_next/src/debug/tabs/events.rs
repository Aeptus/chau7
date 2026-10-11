//! Events tab (`eventsView`): AI events newest first, colored by type.

use chau7_next_core::debug_console::event_tone;
use gpui::{AnyElement, Context, IntoElement, SharedString, div, prelude::*};

use super::clock_text;
use crate::debug::console::DebugConsole;
use crate::debug::{registry, ui};
use crate::theme::Chrome;

impl DebugConsole {
    pub(in crate::debug) fn events_tab(
        &mut self,
        chrome: Chrome,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let all = self.events_all;
        let picker = div()
            .flex()
            .gap_1()
            .p_2()
            .border_b_1()
            .border_color(chrome.border)
            .child(
                ui::chip("events-all", "All Events", all, chrome.accent, chrome).on_click(
                    cx.listener(|this, _, _, cx| {
                        this.events_all = true;
                        cx.notify();
                    }),
                ),
            )
            .child(
                ui::chip(
                    "events-claude",
                    "Claude Events",
                    !all,
                    chrome.accent,
                    chrome,
                )
                .on_click(cx.listener(|this, _, _, cx| {
                    this.events_all = false;
                    cx.notify();
                })),
            );

        let mut events = registry::events(cx);
        if !all {
            events.retain(|e| e.hook.is_some());
        }
        let mut list = div().flex().flex_col().gap_1();
        if events.is_empty() {
            list = list.child(ui::empty_note(
                "No events yet. AI events appear here when the monitors report them.",
                chrome,
            ));
        }
        for event in events {
            let tone = event_tone(&event.kind);
            let color = ui::tone_color(tone, chrome);
            let name = if event.tool.is_empty() {
                event.source.clone()
            } else {
                event.tool.clone()
            };
            list = list.child(
                div()
                    .flex()
                    .flex_col()
                    .gap_0p5()
                    .px_2()
                    .py_1()
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
                                    .child(
                                        div()
                                            .px_1()
                                            .rounded_sm()
                                            .bg(color.opacity(0.2))
                                            .text_color(color)
                                            .text_xs()
                                            .font_family("Menlo")
                                            .child(event.kind.to_uppercase()),
                                    )
                                    .child(
                                        div()
                                            .text_xs()
                                            .font_weight(gpui::FontWeight::MEDIUM)
                                            .child(name),
                                    ),
                            )
                            .child(ui::mono_line(
                                clock_text(event.timestamp),
                                chrome.text_muted,
                            )),
                    )
                    .when(!event.message.is_empty(), |d| {
                        d.child(
                            div()
                                .text_xs()
                                .text_color(chrome.text_muted)
                                .max_h(gpui::px(30.0))
                                .overflow_hidden()
                                .child(SharedString::from(event.message.clone())),
                        )
                    }),
            );
        }
        div()
            .size_full()
            .flex()
            .flex_col()
            .child(picker)
            .child(ui::page("events-page", list).flex_1().min_h_0())
            .into_any_element()
    }
}
