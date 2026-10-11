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

use chau7_next_core::command_risk::admission::{self, Context as ApprovalContext};
use chau7_next_core::remote::key_input::InputStep;

/// Exactly one complete input plan waiting for a decision.
pub(super) struct GuardPrompt {
    command: String,
    pattern: Option<String>,
    pending: Vec<InputStep>,
    broadcast: bool,
    context: ApprovalContext,
    dont_warn: bool,
    reason: Option<String>,
    focus_pending: bool,
}

impl TerminalView {
    fn approval_context(&self, cx: &Context<Self>) -> Option<ApprovalContext> {
        let session = self.session.read(cx);
        (session.exited.is_none() && session.shell_pid() > 0).then(|| ApprovalContext {
            terminal_id: session.id,
            shell_pid: session.shell_pid(),
            directory: session
                .cwd
                .as_ref()
                .map(|p| p.to_string_lossy().into_owned()),
            input_prefix: session.reviewed_input_prefix(),
            input_revision: session.input_revision(),
        })
    }

    // All submitted bytes are reviewed at the shared delivery boundary below.
    // These UI entry points only consume input while a decision is pending.
    pub(super) fn guard_enter(
        &mut self,
        _event: &KeyDownEvent,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> bool {
        if self.guard_prompt.is_some() {
            window.focus(&self.guard_focus, cx);
            true
        } else {
            false
        }
    }
    pub(super) fn guard_paste(
        &mut self,
        _text: &str,
        _bytes: Vec<u8>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> bool {
        if self.guard_prompt.is_some() {
            window.focus(&self.guard_focus, cx);
            true
        } else {
            false
        }
    }

    pub(super) fn focus_guard(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if let Some(prompt) = self.guard_prompt.as_mut()
            && std::mem::take(&mut prompt.focus_pending)
        {
            window.focus(&self.guard_focus, cx);
        }
    }

    /// Remote body and delayed Enter form one admission. A held or blocked plan
    /// returns false and has performed no PTY write, including clear-line bytes.
    pub fn send_guarded_steps(&mut self, steps: Vec<InputStep>, cx: &mut Context<Self>) -> bool {
        self.admit_steps(steps, false, cx)
    }
    pub(super) fn admit_steps(
        &mut self,
        steps: Vec<InputStep>,
        broadcast: bool,
        cx: &mut Context<Self>,
    ) -> bool {
        if steps.is_empty() || self.guard_prompt.is_some() {
            return false;
        }
        let session = self.session.read(cx);
        if session.exited.is_some() || session.shell_pid() == 0 {
            return false;
        }
        let bare_enter = steps.len() == 1 && matches!(steps[0].bytes.as_slice(), [b'\r'] | [b'\n']);
        // Preserve the existing keyboard ownership rule for a running program
        // or a full-screen application. A complete pasted plan still receives
        // the same review as the current paste entry point.
        if bare_enter
            && (session.command_running || session.is_app_cursor() || session.mouse_mode() != 0)
        {
            self.deliver_steps(steps, broadcast, cx);
            return true;
        }
        // Line editors can recall/edit history without updating the tracker.
        // Retain the actual visible logical line for idle-shell bare Enter;
        // complete body/clear-line plans use their reviewed future prefix.
        let visible_line = bare_enter
            .then(|| session.logical_line_hit(session.cursor.1 as i32, session.cursor.0 as usize))
            .flatten()
            .map(|(line, _)| line);
        // Ordinary characters must not copy the entire current line on each
        // keystroke. Only a potential submission needs a complete review.
        if steps
            .iter()
            .any(|step| step.bytes.iter().any(|byte| matches!(byte, b'\r' | b'\n')))
        {
            let Some(context) = self.approval_context(cx) else {
                return false;
            };
            if let Some(review) = admission::submitted_command(
                &context.input_prefix,
                steps
                    .iter()
                    .map(|step| String::from_utf8_lossy(&step.bytes)),
            ) {
                let verdict = command_guard::check_text(
                    &review,
                    context.directory.as_deref(),
                    context.shell_pid,
                    cx,
                );
                if !matches!(verdict.result, CheckResult::Safe | CheckResult::Allowed)
                    && self.guard_hold(verdict, steps.clone(), broadcast, context.clone(), cx)
                {
                    return false;
                }
            }
            if let Some(line) = visible_line {
                let verdict = command_guard::check_line(
                    &line,
                    context.directory.as_deref(),
                    context.shell_pid,
                    cx,
                );
                if !matches!(verdict.result, CheckResult::Safe | CheckResult::Allowed)
                    && self.guard_hold(verdict, steps.clone(), broadcast, context, cx)
                {
                    return false;
                }
            }
        }
        self.deliver_steps(steps, broadcast, cx);
        true
    }

    fn guard_hold(
        &mut self,
        verdict: GuardVerdict,
        pending: Vec<InputStep>,
        broadcast: bool,
        context: ApprovalContext,
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
            broadcast,
            context,
            dont_warn: false,
            reason,
            focus_pending: true,
        });
        cx.notify();
        true
    }

    /// The only bypass of admission is delivery of an already reviewed plan.
    /// Every delayed continuation must still match the exact context after the
    /// previous write; intervening typing or a replaced/exited terminal cancels it.
    fn deliver_steps(&mut self, steps: Vec<InputStep>, broadcast: bool, cx: &mut Context<Self>) {
        let mut steps = steps.into_iter().peekable();
        while steps.peek().is_some_and(|step| step.delay_ms == 0) {
            self.write_admitted(&steps.next().unwrap().bytes, broadcast, cx);
        }
        let rest: Vec<_> = steps.collect();
        if rest.is_empty() {
            return;
        }
        let mut expected = self.approval_context(cx);
        cx.spawn(async move |view, cx| {
            for step in rest {
                if step.delay_ms > 0 {
                    cx.background_executor()
                        .timer(std::time::Duration::from_millis(step.delay_ms))
                        .await;
                }
                let Ok(next) = view.update(cx, |view, cx| {
                    if view.guard_prompt.is_some()
                        || !expected.as_ref().is_some_and(|previous| {
                            previous.accepts(view.approval_context(cx).as_ref())
                        })
                    {
                        return None;
                    }
                    view.write_admitted(&step.bytes, broadcast, cx);
                    view.approval_context(cx)
                }) else {
                    break;
                };
                if next.is_none() {
                    break;
                }
                expected = next;
            }
        })
        .detach();
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
        if run
            && prompt.pattern.is_some()
            && prompt.context.accepts(self.approval_context(cx).as_ref())
        {
            if always || prompt.dont_warn {
                command_guard::always_allow(&prompt.command, cx);
            }
            self.deliver_steps(prompt.pending, prompt.broadcast, cx);
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

#[cfg(all(test, unix))]
mod tests {
    use super::*;
    use crate::{settings::Settings, terminal::session::TerminalSession, workspace::AppData};
    use chau7_next_core::{command_risk::self_protect::ProtectionLevel, data_root::DataRoot};
    use chau7_terminal::Chau7Terminal;
    use gpui::{AppContext, TestAppContext};

    /// A real fixture PTY running cat, which never interprets these commands.
    /// No installed app, shell profiles, provider sessions or user data is used.
    #[gpui::test]
    fn actual_admission_holds_full_plan_and_fences_approval(cx: &mut TestAppContext) {
        let home =
            std::env::temp_dir().join(format!("chau7-next-admission-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&home).unwrap();
        cx.update(|cx| {
            gpui_kit::init(cx);
            cx.set_global(Settings::default());
            cx.set_global(AppData::new(DataRoot::with_home(home.clone(), true)));
            command_guard::init(cx);
        });
        let (handle, view) = cx.update(|cx| {
            gpui_kit::open_window(gpui::WindowOptions::default(), cx, |window, cx| {
                let term = Chau7Terminal::new_with_args_env_in_dir(
                    80,
                    24,
                    "/bin/cat",
                    &[],
                    &[("TERM", "xterm-256color")],
                    None,
                )
                .unwrap();
                let session =
                    cx.new(|cx| TerminalSession::from_terminal_manually_driven(term, None, cx));
                cx.new(|cx| TerminalView::new(session, window, cx))
            })
            .unwrap()
        });
        let session = cx.update(|cx| view.read(cx).session.clone());
        let pid = cx.update(|cx| session.read(cx).shell_pid());
        assert!(pid > 0);
        cx.update(|cx| {
            view.update(cx, |view, cx| {
                assert!(view.write_without_broadcast(format!("kill {pid}").as_bytes(), cx));
                let revision = view.session.read(cx).input_revision();
                assert!(!view.write_without_broadcast(b"\r", cx));
                assert!(view.guard_prompt.as_ref().unwrap().pattern.is_none());
                assert_eq!(view.session.read(cx).input_revision(), revision);
                assert!(!view.write_without_broadcast(b"extra", cx));
                assert_eq!(view.session.read(cx).input_revision(), revision);
            })
        });
        cx.update_window(handle, |_, window, cx| {
            view.update(cx, |view, cx| view.guard_decide(false, false, window, cx))
        })
        .unwrap();
        cx.update(|cx| {
            cx.global_mut::<Settings>()
                .dangerous_commands
                .protect_chau7_level = ProtectionLevel::Warning;
            view.update(cx, |view, cx| {
                let revision = view.session.read(cx).input_revision();
                let plan = vec![
                    InputStep {
                        bytes: vec![21],
                        delay_ms: 0,
                    },
                    InputStep {
                        bytes: format!("kill {pid}").into_bytes(),
                        delay_ms: 0,
                    },
                    InputStep {
                        bytes: vec![13],
                        delay_ms: 60,
                    },
                ];
                assert!(!view.send_guarded_steps(plan, cx));
                assert_eq!(view.guard_prompt.as_ref().unwrap().pending.len(), 3);
                assert_eq!(
                    view.session.read(cx).input_revision(),
                    revision,
                    "even clear-line must wait for approval"
                );
                // Another actual input mutation invalidates the stored approval,
                // even if the terminal and directory remain the same.
                view.session.read(cx).write_input(b"x");
            });
        });
        let revision = cx.update(|cx| session.read(cx).input_revision());
        cx.update_window(handle, |_, window, cx| {
            view.update(cx, |view, cx| view.guard_decide(true, false, window, cx))
        })
        .unwrap();
        cx.update(|cx| {
            assert_eq!(
                session.read(cx).input_revision(),
                revision,
                "stale approval must deliver no bytes"
            );
            assert!(view.read(cx).guard_prompt.is_none());
            view.update(cx, |view, cx| {
                let revision = view.session.read(cx).input_revision();
                assert!(!view.send_guarded_steps(
                    vec![
                        InputStep {
                            bytes: vec![21],
                            delay_ms: 0
                        },
                        InputStep {
                            bytes: format!("kill {pid}").into_bytes(),
                            delay_ms: 0
                        },
                        InputStep {
                            bytes: vec![13],
                            delay_ms: 0
                        },
                    ],
                    cx
                ));
                assert_eq!(view.session.read(cx).input_revision(), revision);
            });
        });
        cx.update_window(handle, |_, window, cx| {
            view.update(cx, |view, cx| view.guard_decide(true, false, window, cx))
        })
        .unwrap();
        let admitted_revision = cx.update(|cx| session.read(cx).input_revision());
        assert_eq!(
            admitted_revision,
            revision + 3,
            "approved plan delivered once"
        );
        cx.update_window(handle, |_, window, cx| {
            view.update(cx, |view, cx| view.guard_decide(true, false, window, cx))
        })
        .unwrap();
        cx.update(|cx| {
            assert_eq!(session.read(cx).input_revision(), admitted_revision);
            session.update(cx, |session, _| session.close());
        });
        cx.update_window(handle, |_, window, _| window.remove_window())
            .unwrap();
        let _ = std::fs::remove_dir_all(home);
    }
    #[gpui::test]
    fn recalled_grid_command_is_guarded_but_running_program_owns_enter(cx: &mut TestAppContext) {
        let home =
            std::env::temp_dir().join(format!("chau7-next-admission-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&home).unwrap();
        cx.update(|cx| {
            gpui_kit::init(cx);
            cx.set_global(Settings::default());
            cx.set_global(AppData::new(DataRoot::with_home(home.clone(), true)));
            command_guard::init(cx);
        });
        let (handle, view) = cx.update(|cx| {
            gpui_kit::open_window(gpui::WindowOptions::default(), cx, |window, cx| {
                let term = Chau7Terminal::new_with_args_env_in_dir(
                    80,
                    24,
                    "/bin/cat",
                    &[],
                    &[("TERM", "xterm-256color")],
                    None,
                )
                .unwrap();
                term.inject_output(format!("$ kill {}", term.shell_pid()).as_bytes());
                let session =
                    cx.new(|cx| TerminalSession::from_terminal_manually_driven(term, None, cx));
                cx.new(|cx| TerminalView::new(session, window, cx))
            })
            .unwrap()
        });
        cx.update(|cx| {
            view.update(cx, |view, cx| {
                assert!(view.session.read(cx).reviewed_input_prefix().is_empty());
                assert!(!view.write_without_broadcast(b"\r", cx));
                assert!(view.guard_prompt.as_ref().unwrap().pattern.is_none());
                assert_eq!(view.session.read(cx).input_revision(), 0);
            })
        });
        cx.update_window(handle, |_, window, cx| {
            view.update(cx, |view, cx| view.guard_decide(false, false, window, cx))
        })
        .unwrap();
        cx.update(|cx| {
            view.update(cx, |view, cx| {
                view.session
                    .update(cx, |session, _| session.command_running = true);
                assert!(view.write_without_broadcast(b"\r", cx));
                assert_eq!(view.session.read(cx).input_revision(), 1);
                assert!(view.guard_prompt.is_none());
                view.session.update(cx, |session, _| session.close());
            })
        });
        cx.update_window(handle, |_, window, _| window.remove_window())
            .unwrap();
        let _ = std::fs::remove_dir_all(home);
    }
}
