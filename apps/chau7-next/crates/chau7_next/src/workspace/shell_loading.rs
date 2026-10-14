//! Shell startup indicator (`ShellLoadingBar`), driven by the session's
//! authoritative prompt/output readiness. An ASCII bar appears after 0.5s;
//! the session's no-output slow-start signal selects the centered spinner.
//! Clearing an already ready terminal must never restart this indicator.

use std::time::Duration;

use gpui::{App, Context, Window, div, prelude::*, px};

use super::Workspace;
use crate::terminal::loading_overlay::{APPEAR_AFTER, appearance_delay};
use crate::theme::Chrome;

const BAR_WIDTH: usize = 28;
const LIT_WIDTH: usize = 10;
/// Swift ticks every 0.08 s.
const STEP: Duration = Duration::from_millis(80);

/// The bar at animation step `step` (`barString`).
fn bar(step: usize) -> String {
    let max_offset = BAR_WIDTH - LIT_WIDTH;
    let total = max_offset * 2;
    let offset = step % total;
    let pos = if offset <= max_offset {
        offset
    } else {
        total - offset
    };
    let mut chars = vec!['░'; BAR_WIDTH];
    for c in chars.iter_mut().skip(pos).take(LIT_WIDTH) {
        *c = '▸';
    }
    format!("  {} ", chars.into_iter().collect::<String>())
}

impl Workspace {
    pub(super) fn shell_loading_state(&self, cx: &App) -> Option<(Duration, bool)> {
        let session = self.selected_panes()?.read(cx).focused_session(cx)?;
        let session = session.read(cx);
        session
            .is_loading()
            .then(|| (session.started_at.elapsed(), session.shell_slow))
    }

    /// One cancellable clock per visible loading workspace. It waits until
    /// the appearance threshold, then changes the visual bar every 80ms.
    pub(super) fn update_shell_loading_timer(
        &mut self,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if !window.is_visible() {
            self.shell_loading_tick = None;
            return;
        }
        let Some((elapsed, _)) = self.shell_loading_state(cx) else {
            self.shell_loading_tick = None;
            return;
        };
        if self.shell_loading_tick.is_some() {
            return;
        }
        let mut wait = appearance_delay(elapsed);
        let timer = crate::observability::timer_registry(cx).map(|registry| {
            registry.register(
                &format!("shell.loading.{}", cx.entity_id()),
                "Shell loading animation",
                "workspace",
                STEP.as_millis() as u64,
                "gpui_task",
                "gpui-main",
            )
        });
        self.shell_loading_tick = Some(cx.spawn_in(window, async move |this, cx| {
            let _timer = timer;
            loop {
                if !wait.is_zero() {
                    cx.background_executor().timer(wait).await;
                }
                let next_wait = this
                    .update_in(cx, |this, window, cx| {
                        use chau7_next_core::work_profiler::{self, Queue};
                        let mut cost = work_profiler::timer_callback(
                            "shell_loading_animation",
                            "refresh",
                            Queue::Main,
                        );
                        let Some((elapsed, _)) = this.shell_loading_state(cx) else {
                            this.shell_loading_tick = None;
                            cost.idle(true);
                            return None;
                        };
                        if !window.is_visible() {
                            this.shell_loading_tick = None;
                            cost.idle(true);
                            return None;
                        }
                        let remaining = appearance_delay(elapsed);
                        if remaining.is_zero() {
                            cost.idle(false);
                            cost.items(1);
                            cx.notify();
                            Some(STEP)
                        } else {
                            // A tab switch while waiting can select a newer
                            // session; recheck its own startup deadline here.
                            cost.idle(true);
                            Some(remaining)
                        }
                    })
                    .unwrap_or(None);
                let Some(next_wait) = next_wait else { break };
                wait = next_wait;
            }
        }));
    }

    /// The indicator for the selected tab, if its shell is still starting.
    pub(super) fn render_shell_loading(
        &self,
        chrome: Chrome,
        cx: &App,
    ) -> Option<gpui::AnyElement> {
        let (elapsed, slow) = self.shell_loading_state(cx)?;
        if elapsed < APPEAR_AFTER {
            return None;
        }
        if slow {
            let spinner = ["◐", "◓", "◑", "◒"][(elapsed.as_millis() / 150) as usize % 4];
            return Some(
                div()
                    .absolute()
                    .inset_0()
                    .flex()
                    .items_center()
                    .justify_center()
                    .child(
                        div()
                            .flex()
                            .items_center()
                            .gap(px(6.0))
                            .px_3()
                            .py_2()
                            .rounded(px(8.0))
                            .bg(chrome.panel_bg.opacity(0.9))
                            .text_xs()
                            .font_family("Menlo")
                            .text_color(chrome.text_muted)
                            .child(spinner)
                            .child(crate::l10n::l(
                                "overlay.shellInitializing",
                                "Shell initializing\u{2026}",
                            )),
                    )
                    .into_any_element(),
            );
        }
        let step = (elapsed.as_millis() / STEP.as_millis()) as usize;
        Some(
            div()
                .absolute()
                .top(px(65.0))
                .left(px(24.0))
                .text_xs()
                .font_family("Menlo")
                .text_color(chrome.text_muted)
                .child(format!("{}Loading shell\u{2026}", bar(step)))
                .into_any_element(),
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bar_bounces() {
        assert_eq!(bar(0), format!("  {}{} ", "▸".repeat(10), "░".repeat(18)));
        assert_eq!(bar(18), format!("  {}{} ", "░".repeat(18), "▸".repeat(10)));
        assert_eq!(bar(19), bar(17));
        assert_eq!(bar(36), bar(0));
    }
}
