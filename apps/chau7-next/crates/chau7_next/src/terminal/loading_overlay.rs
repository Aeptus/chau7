//! Shell startup indicator over a terminal pane (`ShellLoadingBar` in
//! `Overlay/Chau7OverlayView.swift`): an ASCII bar sweeping back and forth
//! with "Loading shell..." under the tip box until the first prompt, or a
//! centered "Shell initializing..." when the shell printed nothing for 5 s.

use std::time::Duration;

use gpui::{Animation, AnimationExt, AnyElement, IntoElement, div, prelude::*, px};

use super::session::TerminalSession;
use crate::theme::Chrome;

const BAR_WIDTH: usize = 28;
const LIT_WIDTH: usize = 10;
/// The bar sweeps right then left.
const POSITIONS: usize = (BAR_WIDTH - LIT_WIDTH) * 2;
/// One step every 0.08 s.
const STEP: Duration = Duration::from_millis(80);

/// The bar at animation step `offset` (`barString`).
pub fn bar_string(offset: usize) -> String {
    let max = BAR_WIDTH - LIT_WIDTH;
    let offset = offset % POSITIONS;
    let pos = if offset <= max {
        offset
    } else {
        POSITIONS - offset
    };
    let chars: String = (0..BAR_WIDTH)
        .map(|i| {
            if (pos..pos + LIT_WIDTH).contains(&i) {
                '\u{25B8}'
            } else {
                '\u{2591}'
            }
        })
        .collect();
    format!("  {chars} ")
}

/// The overlay for `session`, if it is starting.
pub fn overlay(session: &TerminalSession, key: u64, chrome: Chrome) -> Option<AnyElement> {
    if session.exited.is_some() {
        return None;
    }
    if session.shell_slow {
        return Some(
            div()
                .absolute()
                .inset_0()
                .flex()
                .items_center()
                .justify_center()
                .child(
                    div()
                        .px(px(12.0))
                        .py(px(8.0))
                        .rounded(px(8.0))
                        .bg(chrome.tab_bg.opacity(0.9))
                        .text_size(px(12.0))
                        .font_family("Menlo")
                        .text_color(chrome.text_muted)
                        .child("Shell initializing\u{2026}"),
                )
                .into_any_element(),
        );
    }
    if !session.is_loading() {
        return None;
    }
    let total = STEP * POSITIONS as u32;
    Some(
        div()
            .absolute()
            .top(px(65.0))
            .left(px(24.0))
            .text_size(px(12.0))
            .font_family("Menlo")
            .text_color(chrome.text_muted)
            .child(div().id(("shell-loading", key as usize)).with_animation(
                ("shell-loading-bar", key as usize),
                Animation::new(total).repeat(),
                |el, delta| {
                    let step = (delta * POSITIONS as f32) as usize;
                    el.child(format!("{}Loading shell\u{2026}", bar_string(step)))
                },
            ))
            .into_any_element(),
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bar_bounces() {
        let start = bar_string(0);
        assert!(start.starts_with("  \u{25B8}"));
        assert_eq!(start.chars().count(), BAR_WIDTH + 3);
        let end = bar_string(BAR_WIDTH - LIT_WIDTH);
        assert!(end.trim_end().ends_with('\u{25B8}'));
        assert_eq!(bar_string(1), bar_string(POSITIONS - 1));
        assert_eq!(bar_string(POSITIONS), start);
    }
}
