//! The dangerous command guard in the terminal view: Enter (or a multi-line
//! paste) of a risky command waits for a confirmation
//! (`DangerousCommandConfirmationView.swift`).

use chau7_next_core::command_risk::{CheckResult, GuardVerdict};
use gpui::{
    AnyElement, Context, FontWeight, KeyDownEvent, MouseButton, SharedString, Window, deferred,
    div, prelude::*, px,
};

use super::TerminalView;
use crate::commands::{GuardCancel, GuardExecute};
use crate::terminal::command_guard;
use crate::theme::Chrome;

/// A command waiting for the user's decision.
pub(super) struct GuardPrompt {
    command: String,
    /// `None` when the command is on the block list: nothing can run it.
    pattern: Option<String>,
    /// What reaches the shell on Execute.
    pending: Vec<u8>,
    /// "Do not warn for this command again".
    dont_warn: bool,
    reason: Option<String>,
}

impl TerminalView {
    fn directory(&self, cx: &Context<Self>) -> Option<String> {
        self.session
            .read(cx)
            .cwd
            .as_ref()
            .map(|p| p.to_string_lossy().into_owned())
    }

    /// Plain Enter at the prompt: hold it back when the typed line is risky.
    /// Returns true when the key was taken.
    pub(super) fn guard_enter(
        &mut self,
        event: &KeyDownEvent,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> bool {
        let k = &event.keystroke;
        if k.key != "enter"
            || k.modifiers.control
            || k.modifiers.alt
            || k.modifiers.platform
            || k.modifiers.shift
            || self.guard_prompt.is_some()
        {
            return false;
        }
        let session = self.session.read(cx);
        // A running program or a full-screen app owns the keyboard.
        if session.command_running || session.is_app_cursor() || session.mouse_mode() != 0 {
            return false;
        }
        let Some((line, _)) =
            session.logical_line_hit(session.cursor.1 as i32, session.cursor.0 as usize)
        else {
            return false;
        };
        let directory = self.directory(cx);
        let shell_pid = session.shell_pid();
        let result = command_guard::check_line(&line, directory.as_deref(), shell_pid, cx);
        self.guard_hold(result, b"\r".to_vec(), window, cx)
    }

    /// A multi-line paste is a command in itself: ask before it is sent.
    pub(super) fn guard_paste(
        &mut self,
        text: &str,
        bytes: Vec<u8>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> bool {
        if self.guard_prompt.is_some() || !text.contains(['\n', '\r']) {
            return false;
        }
        let directory = self.directory(cx);
        let shell_pid = self.session.read(cx).shell_pid();
        let result = command_guard::check_text(text, directory.as_deref(), shell_pid, cx);
        self.guard_hold(result, bytes, window, cx)
    }

    fn guard_hold(
        &mut self,
        verdict: GuardVerdict,
        pending: Vec<u8>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> bool {
        let reason = verdict
            .self_protection
            .as_ref()
            .map(|detail| detail.reason.to_string());
        let (command, pattern) = match verdict.result {
            CheckResult::Safe | CheckResult::Allowed => return false,
            CheckResult::Blocked => (
                verdict
                    .self_protection
                    .map(|detail| detail.command)
                    .unwrap_or_default(),
                None,
            ),
            CheckResult::NeedsConfirmation {
                command,
                matched_pattern,
            } => (command, Some(matched_pattern)),
        };
        self.guard_prompt = Some(GuardPrompt {
            command,
            pattern,
            pending,
            dont_warn: false,
            reason,
        });
        window.focus(&self.guard_focus, cx);
        cx.notify();
        true
    }

    fn guard_decide(
        &mut self,
        run: bool,
        always: bool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let Some(prompt) = self.guard_prompt.take() else {
            return;
        };
        window.focus(&self.focus_handle, cx);
        if run && prompt.pattern.is_some() {
            if always || prompt.dont_warn {
                command_guard::always_allow(&prompt.command, cx);
            }
            self.write(&prompt.pending, cx);
        }
        cx.notify();
    }

    pub(super) fn render_guard(&self, cx: &mut Context<Self>) -> Option<AnyElement> {
        let prompt = self.guard_prompt.as_ref()?;
        let chrome = Chrome::get(cx);
        let blocked = prompt.pattern.is_none();
        let title = if blocked {
            "Command Blocked"
        } else {
            "Dangerous Command Detected"
        };
        let subtitle = if blocked {
            "This command is on your block list and will not run."
        } else {
            "This command matches a risky pattern and may cause irreversible changes."
        };
        let subtitle = prompt.reason.as_deref().unwrap_or(subtitle);
        let button = |id: &'static str, label: &'static str, primary: bool| {
            div()
                .id(id)
                .px_3()
                .py_1()
                .rounded_md()
                .text_sm()
                .cursor_pointer()
                .bg(if primary {
                    chrome.danger
                } else {
                    chrome.tab_bg
                })
                .text_color(if primary { gpui::white() } else { chrome.text })
                .hover(|d| d.opacity(0.85))
                .child(label)
        };
        let mut body = div()
            .flex()
            .flex_col()
            .gap_3()
            .child(
                div()
                    .text_base()
                    .font_weight(FontWeight::SEMIBOLD)
                    .child(title),
            )
            .child(
                div()
                    .text_xs()
                    .text_color(chrome.text_muted)
                    .child(SharedString::from(subtitle.to_string())),
            );
        if blocked && !prompt.command.is_empty() {
            body = body.child(
                div()
                    .text_sm()
                    .font_family("monospace")
                    .text_color(chrome.danger)
                    .child(SharedString::from(prompt.command.clone())),
            );
        }
        if !blocked {
            body = body
                .child(
                    div()
                        .p_3()
                        .rounded_md()
                        .border_1()
                        .border_color(chrome.danger.opacity(0.4))
                        .bg(chrome.danger.opacity(0.1))
                        .text_sm()
                        .font_family("monospace")
                        .text_color(chrome.danger)
                        .child(SharedString::from(prompt.command.clone())),
                )
                .child(
                    div()
                        .flex()
                        .gap_2()
                        .text_xs()
                        .child(
                            div()
                                .text_color(chrome.text_muted)
                                .child(crate::l10n::tr("Matched pattern:")),
                        )
                        .child(SharedString::from(
                            prompt.pattern.clone().unwrap_or_default(),
                        )),
                )
                .child(
                    div()
                        .id("guard-dont-warn")
                        .flex()
                        .items_center()
                        .gap_2()
                        .cursor_pointer()
                        .text_xs()
                        .text_color(chrome.text_muted)
                        .on_click(cx.listener(|this, _, _, cx| {
                            if let Some(p) = this.guard_prompt.as_mut() {
                                p.dont_warn = !p.dont_warn;
                            }
                            cx.notify();
                        }))
                        .child(
                            div()
                                .size(px(14.0))
                                .rounded_sm()
                                .border_1()
                                .border_color(chrome.border)
                                .bg(if prompt.dont_warn {
                                    chrome.accent
                                } else {
                                    chrome.tab_bg
                                }),
                        )
                        .child(crate::l10n::tr("Do not warn for this command again")),
                );
        }
        let mut buttons = div().flex().justify_end().gap_2();
        if blocked {
            buttons = buttons.child(button("guard-dismiss", "OK", false).on_click(
                cx.listener(|this, _, window, cx| this.guard_decide(false, false, window, cx)),
            ));
        } else {
            buttons = buttons
                .child(button("guard-always", "Always Allow", false).on_click(
                    cx.listener(|this, _, window, cx| this.guard_decide(true, true, window, cx)),
                ))
                .child(button("guard-cancel", "Cancel", false).on_click(
                    cx.listener(|this, _, window, cx| this.guard_decide(false, false, window, cx)),
                ))
                .child(button("guard-execute", "Execute", true).on_click(
                    cx.listener(|this, _, window, cx| this.guard_decide(true, false, window, cx)),
                ));
        }
        Some(
            deferred(
                div()
                    .id("guard-overlay")
                    .absolute()
                    .inset_0()
                    .flex()
                    .justify_center()
                    .items_start()
                    .pt(px(80.0))
                    .bg(gpui::hsla(0.0, 0.0, 0.0, 0.3))
                    .occlude()
                    .on_mouse_down(MouseButton::Left, |_, _, cx| cx.stop_propagation())
                    .child(
                        div()
                            .key_context("DangerGuard")
                            .track_focus(&self.guard_focus)
                            .on_action(cx.listener(|this, _: &GuardExecute, window, cx| {
                                this.guard_decide(true, false, window, cx)
                            }))
                            .on_action(cx.listener(|this, _: &GuardCancel, window, cx| {
                                this.guard_decide(false, false, window, cx)
                            }))
                            .w(px(440.0))
                            .max_w_full()
                            .p_5()
                            .flex()
                            .flex_col()
                            .gap_4()
                            .rounded_xl()
                            .border_1()
                            .border_color(chrome.border)
                            .bg(chrome.panel_bg)
                            .text_color(chrome.text)
                            .shadow_xl()
                            .child(body)
                            .child(buttons),
                    ),
            )
            .with_priority(5)
            .into_any_element(),
        )
    }
}
