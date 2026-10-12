//! Shell loading indicator (`ShellLoadingBar`): while a new shell has not
//! drawn anything yet, an ASCII bar sweeps back and forth with "Loading
//! shell…" (after 0.2 s); when startup is slow (no output after 5 s, the
//! design intent of Swift's never-set `shellStartupSlow`), a centered
//! "Shell initializing…" with a spinner replaces it.

use std::time::Duration;

use gpui::{App, Context, Window, div, prelude::*, px};

use super::Workspace;
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
    fn shell_loading_elapsed(&self, cx: &App) -> Option<Duration> {
        let session = self.selected_panes()?.read(cx).focused_session(cx)?;
        let session = session.read(cx);
        let blank = session.cursor == (0, 0)
            && session
                .line_text(0)
                .is_none_or(|line| line.trim().is_empty());
        (session.exited.is_none() && blank).then(|| session.started_at.elapsed())
    }

    /// One cancellable clock per visible loading workspace. The visual bar
    /// changes every 80ms; it must not drive a full refresh at display rate.
    pub(super) fn update_shell_loading_timer(
        &mut self,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if !window.is_visible() || self.shell_loading_elapsed(cx).is_none() {
            self.shell_loading_tick = None;
            return;
        }
        if self.shell_loading_tick.is_some() {
            return;
        }
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
                cx.background_executor().timer(STEP).await;
                let active = this
                    .update_in(cx, |this, window, cx| {
                        use chau7_next_core::work_profiler::{self, Queue};
                        let mut cost = work_profiler::timer_callback(
                            "shell_loading_animation",
                            "refresh",
                            Queue::Main,
                        );
                        let active =
                            window.is_visible() && this.shell_loading_elapsed(cx).is_some();
                        cost.idle(!active);
                        if active {
                            cost.items(1);
                            cx.notify();
                        } else {
                            this.shell_loading_tick = None;
                        }
                        active
                    })
                    .unwrap_or(false);
                if !active {
                    break;
                }
            }
        }));
    }

    /// The indicator for the selected tab, if its shell is still starting.
    pub(super) fn render_shell_loading(
        &self,
        chrome: Chrome,
        cx: &App,
    ) -> Option<gpui::AnyElement> {
        let elapsed = self.shell_loading_elapsed(cx)?;
        if elapsed < Duration::from_millis(200) {
            return None;
        }
        if elapsed >= Duration::from_secs(5) {
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
