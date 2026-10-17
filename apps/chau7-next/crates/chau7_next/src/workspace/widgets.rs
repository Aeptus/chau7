//! Widgets shared by the workspace overlays.

use gpui::{Entity, IntoElement, deferred, div, prelude::*, px};
use gpui_kit::component::input::{Input, InputState};

use crate::theme::Chrome;

/// A text field of an overlay drawn with the Chau7 chrome colors instead of
/// the gpui-kit theme, so typed text stays readable on the window's
/// background whatever the app theme (the typed text takes the inherited
/// text color, so it is set here too).
pub(crate) fn chrome_input(state: &Entity<InputState>, chrome: Chrome) -> Input {
    Input::new(state)
        .bg(gpui::Hsla {
            a: 1.0,
            ..chrome.terminal_bg
        })
        .text_color(chrome.text)
        .border_color(chrome.border)
}

/// A centered sheet over the window (pickers). A click on the backdrop
/// calls `dismiss` (only one panel open, a click outside closes it).
pub(super) fn modal(
    chrome: Chrome,
    content: impl IntoElement,
    dismiss: impl Fn(&gpui::MouseDownEvent, &mut gpui::Window, &mut gpui::App) + 'static,
) -> gpui::AnyElement {
    modal_width(chrome, 420.0, content, dismiss)
}

/// A centered sheet with its own width.
pub(super) fn modal_width(
    chrome: Chrome,
    width: f32,
    content: impl IntoElement,
    dismiss: impl Fn(&gpui::MouseDownEvent, &mut gpui::Window, &mut gpui::App) + 'static,
) -> gpui::AnyElement {
    deferred(
        div()
            .absolute()
            .inset_0()
            .flex()
            .justify_center()
            .items_start()
            .pt(px(80.0))
            .bg(gpui::hsla(0.0, 0.0, 0.0, 0.25))
            .occlude()
            .on_mouse_down(gpui::MouseButton::Left, dismiss)
            .child(
                div()
                    // Clicks inside the sheet stay inside.
                    .on_mouse_down(gpui::MouseButton::Left, |_, _, cx| cx.stop_propagation())
                    .w(px(width))
                    .max_h(px(if width > 420.0 { 640.0 } else { 480.0 }))
                    .p_4()
                    .rounded_xl()
                    .border_1()
                    .border_color(chrome.border)
                    .bg(chrome.panel_bg)
                    .text_color(chrome.text)
                    .shadow_xl()
                    .child(content),
            ),
    )
    .with_priority(4)
    .into_any_element()
}

pub(crate) fn button(
    id: &'static str,
    label: &'static str,
    chrome: Chrome,
    primary: bool,
) -> gpui::Stateful<gpui::Div> {
    div()
        .id(id)
        .px_3()
        .py_1()
        .rounded_md()
        .text_sm()
        .bg(if primary {
            chrome.accent
        } else {
            chrome.tab_bg
        })
        .text_color(if primary { gpui::white() } else { chrome.text })
        .hover(|d| d.opacity(0.85))
        .child(label)
}
