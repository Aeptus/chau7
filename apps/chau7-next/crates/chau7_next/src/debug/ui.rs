//! Small controls shared by the Debug Console tabs. Panels registered by
//! other modules (`debug::register_panel`) can use them too, so the whole
//! console looks the same.

use chau7_next_core::debug_console::Tone;
use gpui::{Hsla, IntoElement, SharedString, div, prelude::*, px, rgb};

use crate::theme::Chrome;

/// Color of a [`Tone`] (`Color.green`, `.orange`, `.red`... of the Swift view).
pub fn tone_color(tone: Tone, chrome: Chrome) -> Hsla {
    match tone {
        Tone::Good => rgb(0x34c759).into(),
        Tone::Warn => rgb(0xff9f0a).into(),
        Tone::Bad => chrome.danger,
        Tone::Info => rgb(0x0a84ff).into(),
        Tone::Accent => rgb(0xbf5af2).into(),
        Tone::Muted => chrome.text_muted,
    }
}

/// A titled box (`GroupBox`).
pub fn group(title: impl Into<SharedString>, chrome: Chrome) -> gpui::Div {
    let title = title.into();
    div()
        .flex()
        .flex_col()
        .gap_1()
        .p_2()
        .rounded_md()
        .border_1()
        .border_color(chrome.border)
        .bg(chrome.tab_bg.opacity(0.4))
        .when(!title.is_empty(), |d| {
            d.child(
                div()
                    .text_xs()
                    .font_weight(gpui::FontWeight::SEMIBOLD)
                    .text_color(chrome.text_muted)
                    .child(title),
            )
        })
}

/// `label ........ value` (`stateRow`).
pub fn state_row(
    label: impl Into<SharedString>,
    value: impl Into<SharedString>,
    chrome: Chrome,
) -> gpui::Div {
    value_row(label, value, None, chrome)
}

/// A state row whose value has a tone.
pub fn value_row(
    label: impl Into<SharedString>,
    value: impl Into<SharedString>,
    tone: Option<Tone>,
    chrome: Chrome,
) -> gpui::Div {
    div()
        .flex()
        .items_start()
        .justify_between()
        .gap_3()
        .text_xs()
        .child(
            div()
                .flex_none()
                .text_color(chrome.text_muted)
                .child(label.into()),
        )
        .child(
            div()
                .min_w_0()
                .font_family("Menlo")
                .text_color(tone.map_or(chrome.text, |t| tone_color(t, chrome)))
                .child(value.into()),
        )
}

/// A push button (`Button`).
pub fn button(
    id: impl Into<gpui::ElementId>,
    label: impl Into<SharedString>,
    chrome: Chrome,
) -> gpui::Stateful<gpui::Div> {
    div()
        .id(id)
        .px_2p5()
        .py_1()
        .rounded_md()
        .text_xs()
        .cursor_pointer()
        .border_1()
        .border_color(chrome.border)
        .bg(chrome.tab_bg)
        .text_color(chrome.text)
        .hover(|d| d.bg(chrome.tab_hover_bg))
        .child(label.into())
}

/// A toggle chip (level filters, pickers); `color` tints it when active.
pub fn chip(
    id: impl Into<gpui::ElementId>,
    label: impl Into<SharedString>,
    active: bool,
    color: Hsla,
    chrome: Chrome,
) -> gpui::Stateful<gpui::Div> {
    div()
        .id(id)
        .px_2()
        .py_0p5()
        .rounded_md()
        .text_xs()
        .cursor_pointer()
        .border_1()
        .border_color(if active { color } else { chrome.border })
        .bg(if active {
            color.opacity(0.2)
        } else {
            chrome.tab_bg.opacity(0.5)
        })
        .text_color(if active {
            chrome.text
        } else {
            chrome.text_muted
        })
        .hover(|d| d.bg(chrome.tab_hover_bg))
        .child(label.into())
}

/// An on/off switch with a label (`Toggle`).
pub fn switch(
    id: impl Into<gpui::ElementId>,
    label: impl Into<SharedString>,
    on: bool,
    chrome: Chrome,
) -> gpui::Stateful<gpui::Div> {
    div()
        .id(id)
        .flex()
        .items_center()
        .gap_2()
        .cursor_pointer()
        .text_xs()
        .text_color(chrome.text)
        .child(
            div()
                .w(px(30.0))
                .h(px(16.0))
                .rounded_full()
                .p(px(2.0))
                .flex()
                .when(on, |d| d.justify_end())
                .bg(if on { chrome.accent } else { chrome.border })
                .child(div().size(px(12.0)).rounded_full().bg(gpui::white())),
        )
        .child(label.into())
}

/// A checkbox with a label.
pub fn checkbox(
    id: impl Into<gpui::ElementId>,
    label: impl Into<SharedString>,
    on: bool,
    chrome: Chrome,
) -> gpui::Stateful<gpui::Div> {
    div()
        .id(id)
        .flex()
        .items_center()
        .gap_2()
        .cursor_pointer()
        .text_sm()
        .text_color(chrome.text)
        .child(
            div()
                .size(px(14.0))
                .rounded_sm()
                .border_1()
                .border_color(if on { chrome.accent } else { chrome.border })
                .bg(if on { chrome.accent } else { chrome.tab_bg })
                .flex()
                .items_center()
                .justify_center()
                .text_xs()
                .text_color(gpui::white())
                .when(on, |d| d.child("\u{2713}")),
        )
        .child(label.into())
}

/// A big number with a caption (the Token Optimizer hero metrics).
pub fn metric(
    label: impl Into<SharedString>,
    value: impl Into<SharedString>,
    tone: Tone,
    chrome: Chrome,
) -> gpui::Div {
    div()
        .flex_1()
        .min_w(px(90.0))
        .flex()
        .flex_col()
        .gap_0p5()
        .p_2()
        .rounded_md()
        .bg(chrome.tab_bg.opacity(0.5))
        .child(
            div()
                .text_lg()
                .font_weight(gpui::FontWeight::SEMIBOLD)
                .text_color(tone_color(tone, chrome))
                .child(value.into()),
        )
        .child(
            div()
                .text_xs()
                .text_color(chrome.text_muted)
                .child(label.into()),
        )
}

/// A monospace line, for logs and event rows.
pub fn mono_line(text: impl Into<SharedString>, color: Hsla) -> gpui::Div {
    div()
        .text_xs()
        .font_family("Menlo")
        .text_color(color)
        .child(text.into())
}

/// A small caption in muted text.
pub fn caption(text: impl Into<SharedString>, chrome: Chrome) -> gpui::Div {
    div()
        .text_xs()
        .text_color(chrome.text_muted)
        .child(text.into())
}

/// A table row: cells with fixed relative widths. `weights` gives each
/// cell's share; the first cell is left aligned, the others right aligned.
pub fn table_row(
    cells: Vec<(SharedString, Option<Tone>)>,
    weights: &[f32],
    bold: bool,
    chrome: Chrome,
) -> gpui::Div {
    let mut row = div().flex().items_center().gap_2().text_xs();
    for (i, (text, tone)) in cells.into_iter().enumerate() {
        let weight = weights.get(i).copied().unwrap_or(1.0);
        row = row.child(
            div()
                .flex_basis(px(0.0))
                .flex_grow(1.0)
                .min_w_0()
                .w(px(weight * 40.0))
                .overflow_hidden()
                .when(i > 0, |d| d.text_right())
                .when(bold, |d| d.font_weight(gpui::FontWeight::SEMIBOLD))
                .font_family("Menlo")
                .text_color(
                    tone.map_or(if bold { chrome.text_muted } else { chrome.text }, |t| {
                        tone_color(t, chrome)
                    }),
                )
                .child(text),
        );
    }
    row
}

/// Content of a tab that has nothing to show yet.
pub fn empty_note(text: impl Into<SharedString>, chrome: Chrome) -> gpui::Div {
    div()
        .p_4()
        .text_sm()
        .text_color(chrome.text_muted)
        .child(text.into())
}

/// A scrolling page filling its tab, with the console's padding.
pub fn page(
    id: impl Into<gpui::ElementId>,
    content: impl IntoElement,
) -> gpui::Stateful<gpui::Div> {
    div().id(id).size_full().overflow_y_scroll().child(
        div()
            .w_full()
            .flex()
            .flex_col()
            .gap_3()
            .p_3()
            .child(content),
    )
}
