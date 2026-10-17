//! The command approval dialog as a small GPUI window (MCP-045).
//!
//! Swift shows an `NSAlert` and, when the iPhone answers first, stops it with
//! `NSApp.stopModal`. A GPUI prompt (`window.prompt`) cannot be closed from
//! code, so Chau7 Next draws the alert itself in a floating window that the
//! iPhone's answer closes. It keeps the alert's layout: warning icon, bold
//! title, the message, and the buttons with the first one ("Deny") as the
//! default (Return). Escape and the close button also deny.

use futures::channel::oneshot;
use gpui::{
    AnyWindowHandle, App, Context, FocusHandle, Focusable, KeyDownEvent, Render, SharedString,
    Window, WindowBounds, WindowKind, WindowOptions, div, prelude::*, px, size,
};
use gpui_kit::component::{Icon, IconName, TitleBar};

use crate::theme::Chrome;

/// An open dialog: its window and the answer (index of the button).
pub struct OpenDialog {
    pub window: AnyWindowHandle,
    pub answer: oneshot::Receiver<usize>,
}

/// Open the dialog over `parent` (centered on it), or centered on the screen.
pub fn open(
    parent: Option<AnyWindowHandle>,
    title: &str,
    message: &str,
    buttons: &'static [&'static str],
    cx: &mut App,
) -> Option<OpenDialog> {
    let dialog_size = size(px(460.0), px(dialog_height(message)));
    let parent_bounds = parent.and_then(|p| p.update(cx, |_, window, _| window.bounds()).ok());
    let bounds = match parent_bounds {
        Some(parent) => gpui::Bounds::new(
            gpui::point(
                parent.center().x - dialog_size.width / 2.0,
                parent.center().y - dialog_size.height / 2.0,
            ),
            dialog_size,
        ),
        None => gpui::Bounds::centered(None, dialog_size, cx),
    };
    let options = WindowOptions {
        window_bounds: Some(WindowBounds::Windowed(bounds)),
        kind: WindowKind::Floating,
        is_resizable: false,
        is_minimizable: false,
        ..TitleBar::window_options()
    };
    let (tx, rx) = oneshot::channel();
    let title = SharedString::from(title.to_string());
    let message = SharedString::from(message.to_string());
    match gpui_kit::open_window(options, cx, move |window, cx| {
        window.set_window_title(&title);
        cx.new(|cx| {
            let focus = cx.focus_handle();
            window.focus(&focus, cx);
            ApprovalDialog {
                title,
                message,
                buttons,
                reply: Some(tx),
                focus,
            }
        })
    }) {
        Ok((handle, _)) => {
            let _ = handle.update(cx, |_, window, _| window.activate_window());
            Some(OpenDialog {
                window: handle,
                answer: rx,
            })
        }
        Err(err) => {
            log::error!("MCP approval dialog: {err}");
            None
        }
    }
}

/// Close a dialog that was answered elsewhere (the iPhone).
pub fn close(window: AnyWindowHandle, cx: &mut App) {
    let _ = window.update(cx, |_, window, _| window.remove_window());
}

/// Height that fits the message (about 64 characters per line).
fn dialog_height(message: &str) -> f32 {
    let lines: usize = message
        .lines()
        .map(|l| l.chars().count().div_ceil(64).max(1))
        .sum();
    (150.0 + lines.min(20) as f32 * 18.0).min(560.0)
}

pub struct ApprovalDialog {
    title: SharedString,
    message: SharedString,
    buttons: &'static [&'static str],
    reply: Option<oneshot::Sender<usize>>,
    focus: FocusHandle,
}

impl ApprovalDialog {
    fn answer(&mut self, index: usize, window: &mut Window) {
        if let Some(reply) = self.reply.take() {
            let _ = reply.send(index);
        }
        window.remove_window();
    }
}

impl Focusable for ApprovalDialog {
    fn focus_handle(&self, _cx: &App) -> FocusHandle {
        self.focus.clone()
    }
}

impl Render for ApprovalDialog {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let chrome = Chrome::panels(cx);
        let warning = gpui::hsla(0.11, 0.9, 0.5, 1.0);
        // macOS order: the default (first) button is on the right.
        let buttons = self
            .buttons
            .iter()
            .enumerate()
            .rev()
            .map(|(index, label)| {
                let primary = index == 0;
                div()
                    .id(("approval-button", index))
                    .px_3()
                    .py_1()
                    .rounded_md()
                    .text_sm()
                    .cursor_pointer()
                    .bg(if primary {
                        chrome.accent
                    } else {
                        chrome.tab_bg
                    })
                    .text_color(if primary { gpui::white() } else { chrome.text })
                    .border_1()
                    .border_color(chrome.border)
                    .hover(|d| d.opacity(0.85))
                    .child(*label)
                    .on_click(cx.listener(move |this, _, window, _| this.answer(index, window)))
            })
            .collect::<Vec<_>>();
        div()
            .size_full()
            .flex()
            .flex_col()
            .bg(chrome.panel_bg)
            .text_color(chrome.text)
            .track_focus(&self.focus)
            .key_context("ApprovalDialog")
            .on_key_down(cx.listener(|this, event: &KeyDownEvent, window, _| {
                if matches!(event.keystroke.key.as_str(), "enter" | "escape") {
                    this.answer(0, window);
                }
            }))
            .child(crate::theme::panel_titlebar(chrome))
            .child(
                div()
                    .flex_1()
                    .min_h_0()
                    .flex()
                    .gap_4()
                    .px_5()
                    .pb_4()
                    .child(
                        div()
                            .flex_shrink_0()
                            .text_color(warning)
                            .child(Icon::new(IconName::TriangleAlert).size(px(40.0))),
                    )
                    .child(
                        div()
                            .flex_1()
                            .min_w_0()
                            .flex()
                            .flex_col()
                            .gap_2()
                            .child(
                                div()
                                    .text_sm()
                                    .font_weight(gpui::FontWeight::BOLD)
                                    .child(self.title.clone()),
                            )
                            .child(
                                div()
                                    .id("approval-message")
                                    .flex_1()
                                    .min_h_0()
                                    .overflow_y_scroll()
                                    .text_xs()
                                    .child(self.message.clone()),
                            )
                            .child(div().flex().justify_end().gap_2().children(buttons)),
                    ),
            )
    }
}

#[cfg(test)]
mod tests {
    #[test]
    fn height_grows_with_the_message() {
        let short = super::dialog_height("one line");
        let long = super::dialog_height(&"x\n".repeat(10));
        assert!(long > short);
        assert!(super::dialog_height(&"y\n".repeat(500)) <= 560.0);
    }
}
