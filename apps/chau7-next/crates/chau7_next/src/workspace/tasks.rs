//! Task lifecycle of the API analytics proxy (`TaskCandidateView.swift`,
//! `TaskAssessmentView.swift`, PRX-012 to PRX-014), for the selected tab's
//! terminal:
//!
//! - a banner at the top while the proxy suggests a task: "New task
//!   detected", the name, the grace countdown, Confirm and Dismiss;
//! - a bar at the bottom while a task runs: its name, tokens, tokens saved,
//!   cost, and approve / fail buttons (fail opens the assessment panel);
//! - the "Task Complete?" panel: calls, tokens, cost, duration, tokens
//!   saved, an optional note, Failed and Success.

use chau7_next_core::l10n::numbers;
use chrono::Utc;
use gpui::{Context, Entity, SharedString, Window, div, prelude::*, px};
use gpui_kit::component::input::{Input, InputState};

use super::Workspace;
use super::widgets::button;
use crate::theme::Chrome;

/// The assessment panel of the selected terminal.
#[derive(Default)]
pub(super) struct TaskUi {
    /// Panel shown (`isTaskAssessmentVisible`).
    assessing: bool,
    /// The note field, once shown.
    note: Option<Entity<InputState>>,
    show_note: bool,
}

fn green() -> gpui::Hsla {
    gpui::hsla(0.36, 0.65, 0.45, 1.0)
}

fn orange() -> gpui::Hsla {
    gpui::hsla(0.08, 0.9, 0.55, 1.0)
}

fn red() -> gpui::Hsla {
    gpui::hsla(0.0, 0.75, 0.55, 1.0)
}

impl Workspace {
    /// `tabIdentifier` of the selected tab's focused terminal.
    fn selected_terminal_id(&self, cx: &gpui::App) -> Option<String> {
        let panes = self.selected_panes()?;
        let session = panes.read(cx).focused_session(cx)?;
        Some(session.read(cx).tab_identifier.clone())
    }

    fn toggle_task_note(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let ui = &mut self.task_ui;
        ui.show_note = !ui.show_note;
        if ui.show_note && ui.note.is_none() {
            ui.note = Some(cx.new(|cx| {
                InputState::new(window, cx).placeholder(crate::l10n::tr("Add a note (optional)"))
            }));
        }
        cx.notify();
    }

    fn assess_selected_task(&mut self, approved: bool, cx: &mut Context<Self>) {
        let Some(tab) = self.selected_terminal_id(cx) else {
            return;
        };
        let note = self
            .task_ui
            .note
            .as_ref()
            .map(|n| n.read(cx).value().trim().to_string())
            .filter(|n| !n.is_empty() && self.task_ui.show_note);
        let weak = cx.entity().downgrade();
        crate::proxy::assess_task(&tab, approved, note, cx, move |ok, cx| {
            if ok {
                let _ = weak.update(cx, |this, cx| {
                    this.task_ui = TaskUi::default();
                    cx.notify();
                });
            }
        });
    }

    /// Banner, bar and assessment panel for the selected terminal.
    pub(super) fn render_tasks(
        &mut self,
        chrome: Chrome,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Vec<gpui::AnyElement> {
        let Some(tab) = self.selected_terminal_id(cx) else {
            return Vec::new();
        };
        let mut out = Vec::new();
        let now = Utc::now();
        if let Some(candidate) = crate::proxy::candidate_for(&tab, cx) {
            let remaining = candidate.grace_remaining_ms(now);
            if remaining > 0 {
                // The countdown ticks (Swift: 0.1 s timer).
                window.request_animation_frame();
            }
            let confirm_tab = tab.clone();
            let dismiss_tab = tab.clone();
            out.push(
                div()
                    .absolute()
                    .top(px(8.0))
                    .left(px(16.0))
                    .right(px(16.0))
                    .flex()
                    .items_center()
                    .gap_3()
                    .px_3()
                    .py_2()
                    .rounded_lg()
                    .bg(chrome.panel_bg)
                    .border_1()
                    .border_color(chrome.border)
                    .shadow_md()
                    .child(div().text_color(chrome.accent).child("\u{1f4cb}\u{fe0e}"))
                    .child(
                        div()
                            .flex_1()
                            .min_w_0()
                            .flex()
                            .flex_col()
                            .child(
                                div()
                                    .text_xs()
                                    .text_color(chrome.text_muted)
                                    .child(crate::l10n::tr("New task detected")),
                            )
                            .child(
                                div()
                                    .text_sm()
                                    .font_weight(gpui::FontWeight::SEMIBOLD)
                                    .overflow_hidden()
                                    .whitespace_nowrap()
                                    .text_ellipsis()
                                    .child(candidate.suggested_name.clone()),
                            ),
                    )
                    .when(remaining > 0, |d| {
                        d.child(
                            div()
                                .px_1p5()
                                .rounded_sm()
                                .bg(chrome.text_muted.opacity(0.15))
                                .text_xs()
                                .text_color(chrome.text_muted)
                                .child(crate::l10n::count(
                                    "task.candidate.auto_confirm",
                                    "Auto-confirming in %d seconds",
                                    remaining / 1000,
                                )),
                        )
                    })
                    .child(
                        button("task-confirm", "\u{2713} Confirm", chrome, true).on_click(
                            cx.listener(move |_, _, _, cx| {
                                crate::proxy::confirm_candidate(&confirm_tab, cx)
                            }),
                        ),
                    )
                    .child(
                        button("task-dismiss", "\u{2715} Dismiss", chrome, false).on_click(
                            cx.listener(move |_, _, _, cx| {
                                crate::proxy::dismiss_candidate(&dismiss_tab, cx)
                            }),
                        ),
                    )
                    .into_any_element(),
            );
        }
        let Some(task) = crate::proxy::task_for(&tab, cx) else {
            if self.task_ui.assessing {
                self.task_ui = TaskUi::default();
            }
            return out;
        };
        let saved_color = if task.has_savings() {
            green()
        } else {
            orange()
        };
        if self.task_ui.assessing {
            let mut stats = div()
                .flex()
                .gap_3()
                .text_xs()
                .text_color(chrome.text_muted)
                .child(format!(
                    "\u{2195} {}",
                    crate::l10n::count("task.calls", "%d calls", task.total_api_calls)
                ))
                .child(crate::l10n::count(
                    "task.tokens",
                    "%d tokens",
                    task.total_tokens,
                ))
                .child(numbers::cost_precise(task.total_cost_usd))
                .child(format!("\u{23f1} {}", task.formatted_duration(now)));
            if task.tokens_saved != 0 {
                stats = stats.child(div().text_color(saved_color).child(format!(
                    "{} {} tokens",
                    if task.has_savings() {
                        "\u{2193}"
                    } else {
                        "\u{2191}"
                    },
                    format!(
                        "{}{}",
                        if task.tokens_saved > 0 { "+" } else { "" },
                        numbers::integer(task.tokens_saved)
                    )
                )));
            }
            let note = self.task_ui.note.clone().filter(|_| self.task_ui.show_note);
            out.push(
                div()
                    .absolute()
                    .bottom(px(20.0))
                    .left_0()
                    .right_0()
                    .flex()
                    .justify_center()
                    .child(
                        div()
                            .w(px(320.0))
                            .flex()
                            .flex_col()
                            .gap_3()
                            .p_3()
                            .rounded_lg()
                            .bg(chrome.panel_bg)
                            .border_1()
                            .border_color(chrome.border)
                            .shadow_lg()
                            .child(
                                div()
                                    .flex()
                                    .justify_between()
                                    .child(
                                        div()
                                            .text_sm()
                                            .font_weight(gpui::FontWeight::SEMIBOLD)
                                            .child(crate::l10n::tr("Task Complete?")),
                                    )
                                    .child(
                                        div()
                                            .id("task-assess-cancel")
                                            .cursor_pointer()
                                            .text_color(chrome.text_muted)
                                            .child("\u{2715}")
                                            .on_click(cx.listener(|this, _, _, cx| {
                                                this.task_ui.assessing = false;
                                                cx.notify();
                                            })),
                                    ),
                            )
                            .child(
                                div()
                                    .flex()
                                    .flex_col()
                                    .gap_1()
                                    .p_2()
                                    .rounded_md()
                                    .bg(chrome.tab_bg)
                                    .child(
                                        div()
                                            .text_xs()
                                            .font_weight(gpui::FontWeight::MEDIUM)
                                            .child(task.name.clone()),
                                    )
                                    .child(stats),
                            )
                            .children(note.map(|n| Input::new(&n).into_any_element()))
                            .child(
                                div()
                                    .flex()
                                    .items_center()
                                    .gap_2()
                                    .child(
                                        div()
                                            .id("task-note-toggle")
                                            .cursor_pointer()
                                            .text_color(chrome.text_muted)
                                            .child(SharedString::from(if self.task_ui.show_note {
                                                "\u{270e}+"
                                            } else {
                                                "\u{270e}"
                                            }))
                                            .on_click(cx.listener(|this, _, window, cx| {
                                                this.toggle_task_note(window, cx)
                                            })),
                                    )
                                    .child(div().flex_1())
                                    .child(
                                        button("task-failed", "\u{2715} Failed", chrome, false)
                                            .text_color(red())
                                            .on_click(cx.listener(|this, _, _, cx| {
                                                this.assess_selected_task(false, cx)
                                            })),
                                    )
                                    .child(
                                        button("task-success", "\u{2713} Success", chrome, false)
                                            .bg(green())
                                            .text_color(gpui::white())
                                            .on_click(cx.listener(|this, _, _, cx| {
                                                this.assess_selected_task(true, cx)
                                            })),
                                    ),
                            ),
                    )
                    .into_any_element(),
            );
        } else {
            out.push(
                div()
                    .absolute()
                    .bottom(px(8.0))
                    .left(px(16.0))
                    .right(px(16.0))
                    .flex()
                    .items_center()
                    .gap_2()
                    .px_2()
                    .py_1()
                    .rounded_md()
                    .bg(chrome.panel_bg.opacity(0.9))
                    .child(div().size(px(6.0)).rounded_full().bg(chrome.accent))
                    .child(
                        div()
                            .flex_1()
                            .min_w_0()
                            .text_xs()
                            .font_weight(gpui::FontWeight::MEDIUM)
                            .overflow_hidden()
                            .whitespace_nowrap()
                            .text_ellipsis()
                            .child(task.name.clone()),
                    )
                    .child(
                        div()
                            .text_size(px(10.0))
                            .text_color(chrome.text_muted)
                            .child(numbers::integer(task.total_tokens)),
                    )
                    .when(task.tokens_saved != 0, |d| {
                        d.child(
                            div()
                                .text_size(px(10.0))
                                .text_color(saved_color)
                                .child(format!(
                                    "({})",
                                    format!(
                                        "{}{}",
                                        if task.tokens_saved > 0 { "+" } else { "" },
                                        numbers::integer(task.tokens_saved)
                                    )
                                )),
                        )
                    })
                    .child(
                        div()
                            .text_size(px(10.0))
                            .text_color(chrome.text_muted)
                            .child(numbers::cost_precise(task.total_cost_usd)),
                    )
                    .child(
                        div()
                            .id("task-bar-approve")
                            .cursor_pointer()
                            .text_color(green())
                            .child("\u{2713}")
                            .on_click(
                                cx.listener(|this, _, _, cx| this.assess_selected_task(true, cx)),
                            ),
                    )
                    .child(
                        div()
                            .id("task-bar-fail")
                            .cursor_pointer()
                            .text_color(red())
                            .child("\u{2715}")
                            .on_click(cx.listener(|this, _, _, cx| {
                                this.task_ui.assessing = true;
                                cx.notify();
                            })),
                    )
                    .into_any_element(),
            );
        }
        out
    }
}
