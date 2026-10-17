//! "Flash screen" and "Menu bar alert" actions.
//!
//! Flash screen: Swift orders a borderless `screenSaver` level window over
//! the main screen and blinks its alpha. Chau7 Next opens a transparent
//! GPUI pop-up window over the primary display and blinks its color.
//!
//! Menu bar alert: Swift swaps the status item icon to `bell.badge.fill`
//! for N seconds (pulsing when animated). Chau7 Next has no permanent menu
//! bar item yet (StatusBar is a later port), so it shows a temporary one
//! with that symbol for the same time.

use std::time::Duration;

use gpui::{
    App, AppContext, Context, Hsla, Render, Window, WindowBackgroundAppearance, WindowBounds,
    WindowKind, WindowOptions, div, prelude::*,
};

struct FlashView {
    color: Hsla,
    on: bool,
}

impl Render for FlashView {
    fn render(&mut self, _window: &mut Window, _cx: &mut Context<Self>) -> impl IntoElement {
        let color = if self.on {
            self.color.opacity(0.5)
        } else {
            self.color.opacity(0.0)
        };
        div().size_full().bg(color)
    }
}

/// Flash color names (`yellow`, `red`, `green`, `blue`, else white).
fn flash_color(name: &str) -> Hsla {
    let rgb = match name {
        "yellow" => 0xffff00,
        "red" => 0xff0000,
        "green" => 0x00ff00,
        "blue" => 0x0000ff,
        _ => 0xffffff,
    };
    gpui::rgb(rgb).into()
}

/// Blink a translucent color over the screen `count` times, each
/// `duration_ms` long with 100 ms between.
pub fn flash(color: &str, duration_ms: u64, count: u32, cx: &mut App) {
    if count == 0 {
        return;
    }
    let Some(display) = cx.primary_display() else {
        return;
    };
    let options = WindowOptions {
        window_bounds: Some(WindowBounds::Windowed(display.bounds())),
        titlebar: None,
        focus: false,
        show: true,
        kind: WindowKind::PopUp,
        is_movable: false,
        is_resizable: false,
        is_minimizable: false,
        display_id: Some(display.id()),
        window_background: WindowBackgroundAppearance::Transparent,
        ..Default::default()
    };
    let color = flash_color(color);
    let handle = match cx.open_window(options, |_, cx| cx.new(|_| FlashView { color, on: true })) {
        Ok(handle) => handle,
        Err(err) => {
            log::warn!("Action flashScreen: {err}");
            return;
        }
    };
    cx.spawn(async move |cx| {
        for i in 0..count {
            if i > 0 {
                let _ = handle.update(cx, |view, _, cx| {
                    view.on = true;
                    cx.notify();
                });
            }
            cx.background_executor()
                .timer(Duration::from_millis(duration_ms))
                .await;
            let _ = handle.update(cx, |view, _, cx| {
                view.on = false;
                cx.notify();
            });
            cx.background_executor()
                .timer(Duration::from_millis(100))
                .await;
        }
        let _ = handle.update(cx, |_, window, _| window.remove_window());
    })
    .detach();
}

/// Show the alert icon in the menu bar for `duration_secs`, pulsing every
/// 0.5 s (at most 10 times) when `animate`: the permanent menu bar item of
/// `crate::status_bar` changes its icon, no second item is created.
pub fn menu_bar_alert(duration_secs: u64, animate: bool, cx: &mut App) {
    if !crate::status_bar::flash_alert(duration_secs, animate, cx) {
        log::info!("Action menuBarAlert: no menu bar item");
    }
}
