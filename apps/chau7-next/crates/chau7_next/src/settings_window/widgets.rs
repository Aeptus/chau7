//! Controls shared by the settings sections.

use gpui::{IntoElement, SharedString, div, prelude::*, px};

use super::update;
use crate::settings::Settings;
use crate::theme::Chrome;

pub(super) fn section(title: impl Into<SharedString>, chrome: Chrome) -> gpui::Div {
    let title = title.into();
    let header = div()
        .id(SharedString::from(format!("setting-header-{title}")))
        .anchor_scroll(super::anchors::for_title(&title))
        .text_xs()
        .font_weight(gpui::FontWeight::SEMIBOLD)
        .text_color(chrome.text_muted)
        .child(crate::l10n::tr(&title).to_uppercase());
    #[cfg(any(test, feature = "native-parity-fixture"))]
    let header = {
        use gpui_kit::test::TestSupportExt;
        header.test_support()
    };
    div()
        .flex()
        .flex_col()
        .gap_2()
        .pb_4()
        .child(super::anchors::title_target(&title, header))
}

pub(super) fn row(
    label: impl Into<SharedString>,
    control: impl IntoElement,
    chrome: Chrome,
) -> gpui::Div {
    let label = label.into();
    let element = crate::l10n::row_direction(div().flex().items_center().justify_between())
        .gap_4()
        .min_h(px(30.0))
        .child(
            div()
                .flex_1()
                .min_w_0()
                .text_sm()
                .text_color(chrome.text)
                .when(crate::l10n::is_rtl(), |d| d.text_right())
                .child(crate::l10n::ui(&label)),
        )
        .child(div().flex_none().child(control));
    super::anchors::label_target(&label, element)
}

pub(super) fn chip(
    id: impl Into<gpui::ElementId>,
    label: impl Into<SharedString>,
    active: bool,
    chrome: Chrome,
) -> gpui::Stateful<gpui::Div> {
    div()
        .id(id)
        .px_2p5()
        .py_1()
        .rounded_md()
        .text_xs()
        .border_1()
        .border_color(if active { chrome.accent } else { chrome.border })
        .bg(if active {
            chrome.accent.opacity(0.18)
        } else {
            chrome.tab_bg
        })
        .text_color(chrome.text)
        .hover(|d| d.bg(chrome.tab_hover_bg))
        .child(crate::l10n::ui(&label.into()))
}

pub(super) fn toggle(
    id: &'static str,
    on: bool,
    chrome: Chrome,
    apply: fn(&mut Settings, bool),
) -> gpui::Stateful<gpui::Div> {
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
        .on_click(move |_, _, cx| update(cx, |s| apply(s, !on)))
}

pub(super) fn stepper(
    id: &'static str,
    value: String,
    chrome: Chrome,
    apply: fn(&mut Settings, i32),
) -> gpui::Div {
    let button = |suffix: &'static str, label: &'static str, delta: i32| {
        div()
            .id(SharedString::from(format!("{id}-{suffix}")))
            .size(px(24.0))
            .flex()
            .items_center()
            .justify_center()
            .rounded_md()
            .bg(chrome.tab_bg)
            .hover(|d| d.bg(chrome.tab_hover_bg))
            .child(label)
            .on_click(move |_, _, cx| update(cx, |s| apply(s, delta)))
    };
    div()
        .flex()
        .items_center()
        .gap_2()
        .child(button("dec", "−", -1))
        .child(div().min_w(px(44.0)).text_center().text_sm().child(value))
        .child(button("inc", "+", 1))
}

/// A label with a read-only value (`SettingsInfoRow`).
pub(super) fn info_row(
    label: impl Into<SharedString>,
    value: impl Into<SharedString>,
    chrome: Chrome,
) -> gpui::Div {
    row(
        label,
        div()
            .max_w(px(320.0))
            .text_xs()
            .font_family("Menlo")
            .text_color(chrome.text_muted)
            .child(value.into()),
        chrome,
    )
}

/// A short explanation under a row (`SettingsDescription`).
pub(super) fn description(text: impl Into<SharedString>, chrome: Chrome) -> gpui::Div {
    div()
        .text_xs()
        .text_color(chrome.text_muted)
        .when(crate::l10n::is_rtl(), |d| d.text_right())
        .child(crate::l10n::ui(&text.into()))
}

/// A message box: an error in the danger color, else plain.
pub(super) fn banner(text: impl Into<SharedString>, error: bool, chrome: Chrome) -> gpui::Div {
    let color = if error { chrome.danger } else { chrome.text };
    div()
        .px_2()
        .py_1p5()
        .rounded_md()
        .text_xs()
        .text_color(color)
        .border_1()
        .border_color(color.opacity(0.5))
        .bg(color.opacity(0.08))
        .when(crate::l10n::is_rtl(), |d| d.text_right())
        .child(crate::l10n::ui(&text.into()))
}

/// A push button.
pub(super) fn button(
    id: impl Into<gpui::ElementId>,
    label: impl Into<SharedString>,
    chrome: Chrome,
) -> gpui::Stateful<gpui::Div> {
    chip(id, label, false, chrome).cursor_pointer()
}

/// A switch whose change is handled by `on_change` (for settings that also
/// call the OS, such as Launch at Login).
pub(super) fn toggle_with(
    id: &'static str,
    on: bool,
    chrome: Chrome,
    on_change: fn(&mut gpui::App, bool),
) -> gpui::Stateful<gpui::Div> {
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
        .on_click(move |_, _, cx| on_change(cx, !on))
}
