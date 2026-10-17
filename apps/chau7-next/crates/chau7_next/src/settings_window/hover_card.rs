//! Hover card (`HoverCardSettingsView.swift`): "Visible Sections", one
//! toggle per card row.

use gpui::{SharedString, div, prelude::*, px};

use super::SectionContext;
use super::update;
use super::widgets::section as titled;
use crate::settings::HoverCardSettings;
use crate::theme::Chrome;

pub(super) fn section(ctx: &SectionContext) -> gpui::Div {
    let chrome = ctx.chrome;
    let current = &ctx.settings.hover_card;
    HoverCardSettings::FIELDS.iter().fold(
        titled("Hover Card: Visible Sections", chrome),
        |d, (key, label, get, set)| {
            let on = get(current);
            let set = *set;
            d.child(
                div()
                    .flex()
                    .items_center()
                    .justify_between()
                    .gap_4()
                    .min_h(px(30.0))
                    .child(div().text_sm().text_color(chrome.text).child(*label))
                    .child(switch(SharedString::from(*key), on, chrome).on_click(
                        move |_, _, cx| update(cx, move |s| set(&mut s.hover_card, !on)),
                    )),
            )
        },
    )
}

/// Same look as `widgets::toggle`, for a setter that is not a plain `fn`.
fn switch(id: SharedString, on: bool, chrome: Chrome) -> gpui::Stateful<gpui::Div> {
    div()
        .id(id)
        .w(px(38.0))
        .h(px(22.0))
        .rounded_full()
        .p(px(2.0))
        .flex()
        .when(on, |d| d.justify_end())
        .bg(if on { chrome.accent } else { chrome.border })
        .child(div().size(px(18.0)).rounded_full().bg(gpui::white()))
}
