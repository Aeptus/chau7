//! The launch splash and the welcome screen (`SplashView`, `WelcomeView`,
//! `SplashWindowController`).

use std::sync::{Arc, OnceLock};
use std::time::{Duration, Instant};

use chau7_next_core::welcome::{
    self, GET_STARTED, HAS_SHOWN_WELCOME_KEY, LaunchScreen, SPLASH_SIZE, SPLASH_TITLE, TIPS,
    WELCOME_SIZE, WELCOME_TITLE, WelcomeGate,
};
use gpui::{
    AnyWindowHandle, App, Bounds, Context, FontWeight, IntoElement, Render, RenderImage, Task,
    Window, WindowBackgroundAppearance, WindowBounds, WindowKind, WindowOptions, canvas, div,
    prelude::*, px, size,
};
use gpui_kit::component::TitleBar;

use super::ViewsState;
use crate::platform;
use crate::theme::Chrome;
use crate::workspace::AppData;

pub(crate) enum LaunchHandle {
    Splash(AnyWindowHandle),
    Welcome(AnyWindowHandle),
}

impl LaunchHandle {
    fn window(&self) -> AnyWindowHandle {
        match self {
            Self::Splash(handle) | Self::Welcome(handle) => *handle,
        }
    }
}

/// Decode the embedded logo once before opening the window. Passing a ready
/// frame to GPUI prevents asynchronous image loading from showing a late logo.
fn app_icon() -> Arc<RenderImage> {
    static ICON: OnceLock<Arc<RenderImage>> = OnceLock::new();
    ICON.get_or_init(|| {
        let mut pixels = image::load_from_memory_with_format(
            include_bytes!("../../assets/app-icon.png"),
            image::ImageFormat::Png,
        )
        .expect("valid embedded app icon")
        .into_rgba8();
        // GPUI's image atlas expects BGRA pixels.
        for pixel in pixels.pixels_mut() {
            pixel.0.swap(0, 2);
        }
        Arc::new(RenderImage::new(vec![image::Frame::new(pixels)]))
    })
    .clone()
}

/// A plain character for the SF Symbol of a tip.
fn tip_glyph(symbol: &str) -> &'static str {
    match symbol {
        "rectangle.stack.fill" => "\u{25A4}",
        "bell.badge.fill" => "\u{25CF}",
        "keyboard.fill" => "\u{2328}",
        _ => "\u{2022}",
    }
}

/// Whether the welcome screen was shown before: the app default, or the
/// marker file where there are no app defaults.
fn has_shown_welcome(cx: &App) -> bool {
    platform::defaults::app_bool(HAS_SHOWN_WELCOME_KEY).unwrap_or(false)
        || cx.global::<AppData>().root.welcome_shown_file().exists()
}

fn mark_welcome_shown(cx: &App) {
    if let Err(err) = platform::defaults::set_app_bool(HAS_SHOWN_WELCOME_KEY, Some(true)) {
        log::debug!("welcome flag: {err}");
    }
    let file = cx.global::<AppData>().root.welcome_shown_file();
    if let Some(dir) = file.parent() {
        let _ = std::fs::create_dir_all(dir);
    }
    if let Err(err) = std::fs::write(&file, b"1") {
        log::debug!("welcome marker: {err}");
    }
}

const SPLASH_DELAY: Duration = Duration::from_millis(200);

fn splash_due(elapsed: Duration, terminal_painted: bool, pending: bool, launch_open: bool) -> bool {
    elapsed >= SPLASH_DELAY && !terminal_painted && pending && !launch_open
}

/// Start immediately. A returning user's splash is only a fallback when no
/// terminal frame has been painted after 200 ms from Rust main() entry.
pub fn prepare_launch(cx: &mut App, start: impl FnOnce(&mut App) + 'static) {
    if welcome::launch_screen(has_shown_welcome(cx)) == LaunchScreen::Splash {
        cx.global_mut::<ViewsState>().splash_pending = true;
        cx.on_app_quit(|cx| {
            cx.global_mut::<ViewsState>().splash_pending = false;
            std::future::ready(())
        })
        .detach();
        let delay = SPLASH_DELAY.saturating_sub(crate::startup::elapsed());
        cx.spawn(async move |cx| {
            cx.background_executor().timer(delay).await;
            cx.update(|cx| {
                let state = cx.global::<ViewsState>();
                let show = splash_due(
                    crate::startup::elapsed(),
                    crate::startup::reached(crate::startup::Stage::TerminalPainted),
                    state.splash_pending,
                    state.launch.is_some(),
                );
                cx.global_mut::<ViewsState>().splash_pending = false;
                if show {
                    open_splash(cx);
                }
            });
        })
        .detach();
    }
    start(cx);
}

/// Called once from the first terminal paint. Defer window removal until the
/// current paint completes; a Help/Welcome window must survive this handoff.
pub fn terminal_displayed(cx: &mut App) {
    cx.defer(|cx| {
        if cx.try_global::<ViewsState>().is_none() {
            return;
        }
        cx.global_mut::<ViewsState>().splash_pending = false;
        if matches!(
            cx.global::<ViewsState>().launch,
            Some(LaunchHandle::Splash(_))
        ) {
            close_previous(cx);
            crate::startup::mark(crate::startup::Stage::SplashDismissed);
        }
    });
}

/// First launch keeps the existing welcome experience. Returning users
/// receive no post-load splash; the pending fallback owns that decision.
pub fn finish_launch(cx: &mut App) {
    if welcome::launch_screen(has_shown_welcome(cx)) == LaunchScreen::Welcome {
        let mut gate = WelcomeGate::default();
        gate.mark_ready();
        open_welcome(gate, cx);
    } else if crate::workspace::AppData::live(cx).is_empty() {
        close_previous(cx);
    }
}

/// Help > Welcome to Chau7.
pub fn show_welcome(cx: &mut App) {
    open_welcome(WelcomeGate::already_running(), cx);
}

fn close_previous(cx: &mut App) {
    cx.global_mut::<ViewsState>().splash_pending = false;
    if let Some(handle) = cx.global_mut::<ViewsState>().launch.take() {
        let _ = handle
            .window()
            .update(cx, |_, window, _| window.remove_window());
    }
}

fn open_splash(cx: &mut App) -> Option<AnyWindowHandle> {
    let _ = app_icon();
    close_previous(cx);
    let bounds = Bounds::centered(None, size(px(SPLASH_SIZE.0), px(SPLASH_SIZE.1)), cx);
    let options = WindowOptions {
        window_bounds: Some(WindowBounds::Windowed(bounds)),
        titlebar: None,
        focus: false,
        show: true,
        kind: WindowKind::PopUp,
        is_movable: false,
        is_resizable: false,
        is_minimizable: false,
        window_background: WindowBackgroundAppearance::Transparent,
        ..Default::default()
    };
    match gpui_kit::open_window(options, cx, |_, cx| cx.new(SplashView::new)) {
        Ok((handle, _)) => {
            cx.global_mut::<ViewsState>().launch = Some(LaunchHandle::Splash(handle));
            Some(handle)
        }
        Err(err) => {
            log::error!("splash: {err}");
            None
        }
    }
}

const SPLASH_TIMEOUT: Duration = Duration::from_secs(15);

fn splash_finished(terminal_painted: bool, elapsed: Duration) -> bool {
    terminal_painted || elapsed >= SPLASH_TIMEOUT
}

struct SplashView {
    _wait: Task<()>,
}

impl SplashView {
    fn new(cx: &mut Context<Self>) -> Self {
        let started = Instant::now();
        let wait = cx.spawn(async move |this, cx| {
            loop {
                cx.background_executor()
                    .timer(Duration::from_millis(16))
                    .await;
                if splash_finished(
                    crate::startup::reached(crate::startup::Stage::TerminalPainted),
                    started.elapsed(),
                ) {
                    // Remove only this splash. Help > Welcome may have replaced
                    // it while the task was waiting for a terminal.
                    let _ = this.update_in(cx, |_, window, cx| {
                        let handle = window.window_handle();
                        if cx
                            .global::<ViewsState>()
                            .launch
                            .as_ref()
                            .is_some_and(|current| current.window() == handle)
                        {
                            cx.global_mut::<ViewsState>().launch = None;
                        }
                        window.remove_window();
                        crate::startup::mark(crate::startup::Stage::SplashDismissed);
                    });
                    return;
                }
            }
        });
        Self { _wait: wait }
    }
}

impl Render for SplashView {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        if crate::startup::reached(crate::startup::Stage::TerminalPainted) {
            return div();
        }
        let chrome = Chrome::panels(cx);
        div()
            .relative()
            .size_full()
            .child(
                canvas(
                    |_, _, _| (),
                    |_, _, _, _| {
                        crate::startup::mark(crate::startup::Stage::SplashPainted);
                    },
                )
                .absolute()
                .size_full(),
            )
            .child(
                div()
                    .size_full()
                    .rounded_xl()
                    .bg(chrome.panel_bg)
                    .border_1()
                    .border_color(chrome.border)
                    .flex()
                    .flex_col()
                    .items_center()
                    .justify_center()
                    .gap_3()
                    .child(gpui::img(app_icon()).size(px(96.0)).rounded_xl())
                    .child(
                        div()
                            .text_2xl()
                            .font_weight(FontWeight::BOLD)
                            .text_color(chrome.text)
                            .child(SPLASH_TITLE),
                    )
                    .child(
                        div()
                            .text_xs()
                            .text_color(chrome.text_muted)
                            .child(crate::l10n::tr("Loading...")),
                    ),
            )
    }
}

fn open_welcome(gate: WelcomeGate, cx: &mut App) {
    close_previous(cx);
    // Shortcut names are longer off macOS ("Ctrl+Shift+T" for "Cmd+T"): the
    // shortcuts tip takes two more lines.
    let extra = if cfg!(target_os = "macos") { 0.0 } else { 36.0 };
    let bounds = Bounds::centered(
        None,
        size(px(WELCOME_SIZE.0), px(WELCOME_SIZE.1 + extra)),
        cx,
    );
    let options = WindowOptions {
        window_bounds: Some(WindowBounds::Windowed(bounds)),
        is_resizable: false,
        ..TitleBar::window_options()
    };
    match gpui_kit::open_window(options, cx, move |_, cx| cx.new(|_| WelcomeView { gate })) {
        Ok((handle, _)) => {
            cx.global_mut::<ViewsState>().launch = Some(LaunchHandle::Welcome(handle));
            let _ = handle.update(cx, |_, window, _| window.activate_window());
        }
        Err(err) => log::error!("welcome: {err}"),
    }
}

struct WelcomeView {
    gate: WelcomeGate,
}

impl Render for WelcomeView {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let chrome = Chrome::panels(cx);
        window.set_window_title(&crate::l10n::tr(WELCOME_TITLE));
        let tips = TIPS.iter().map(|tip| {
            div()
                .w_full()
                .flex()
                .gap_3()
                .child(
                    div()
                        .w(px(28.0))
                        .flex_none()
                        .text_center()
                        .text_color(chrome.accent)
                        .child(tip_glyph(tip.icon)),
                )
                .child(
                    div()
                        .flex_1()
                        .min_w_0()
                        .flex()
                        .flex_col()
                        .gap_0p5()
                        .child(
                            div()
                                .text_sm()
                                .font_weight(FontWeight::SEMIBOLD)
                                .child(tip.title),
                        )
                        .child(
                            div()
                                .text_xs()
                                .text_color(chrome.text_muted)
                                .child(crate::l10n::platform(tip.body)),
                        ),
                )
        });
        div()
            .size_full()
            .flex()
            .flex_col()
            .bg(chrome.panel_bg)
            .text_color(chrome.text)
            .child(
                crate::theme::panel_titlebar(chrome)
                    .child(div().text_sm().child(crate::l10n::tr(WELCOME_TITLE))),
            )
            .child(
                div()
                    .flex_1()
                    .min_h_0()
                    .flex()
                    .flex_col()
                    .items_center()
                    .gap_3()
                    .px_5()
                    .py_4()
                    .child(gpui::img(app_icon()).size(px(64.0)).rounded_xl())
                    .child(
                        div()
                            .text_xl()
                            .font_weight(FontWeight::BOLD)
                            .child(crate::l10n::tr(WELCOME_TITLE)),
                    )
                    // Full width, so the tip texts wrap inside the window;
                    // they scroll when they do not fit, the button stays.
                    .child(
                        div()
                            .id("welcome-tips")
                            .flex_1()
                            .min_h_0()
                            .w_full()
                            .overflow_y_scroll()
                            .child(div().w_full().flex().flex_col().gap_3().children(tips)),
                    )
                    .child(
                        crate::debug::ui::button("welcome-start", GET_STARTED, chrome)
                            .bg(chrome.accent)
                            .text_color(gpui::white())
                            .px_6()
                            .on_click(cx.listener(|this, _, window, cx| {
                                mark_welcome_shown(cx);
                                if this.gate.get_started() {
                                    window.remove_window();
                                    cx.global_mut::<ViewsState>().launch = None;
                                }
                            })),
                    ),
            )
    }
}

#[cfg(test)]
mod startup_splash_tests {
    use super::{SPLASH_DELAY, SPLASH_TIMEOUT, app_icon, splash_due, splash_finished};
    use std::sync::Arc;
    use std::time::Duration;

    #[test]
    fn fast_terminal_suppresses_splash_even_after_deadline() {
        for elapsed in [Duration::ZERO, SPLASH_DELAY, Duration::from_secs(10)] {
            assert!(!splash_due(elapsed, true, true, false));
        }
    }

    #[test]
    fn missing_terminal_shows_splash_at_200ms_only() {
        assert!(!splash_due(
            SPLASH_DELAY - Duration::from_millis(1),
            false,
            true,
            false
        ));
        assert!(splash_due(SPLASH_DELAY, false, true, false));
    }

    #[test]
    fn cancelled_startup_and_replacement_welcome_suppress_pending_splash() {
        assert!(!splash_due(SPLASH_DELAY, false, false, false));
        assert!(!splash_due(SPLASH_DELAY, false, true, true));
    }

    #[test]
    fn first_terminal_paint_dismisses_without_waiting_for_prompt_or_minimum_hold() {
        assert!(splash_finished(true, Duration::ZERO));
        assert!(!splash_finished(false, Duration::from_millis(1800)));
    }

    #[test]
    fn unavailable_terminal_has_a_bounded_splash() {
        assert!(!splash_finished(
            false,
            SPLASH_TIMEOUT - Duration::from_millis(1)
        ));
        assert!(splash_finished(false, SPLASH_TIMEOUT));
    }

    #[test]
    fn logo_is_decoded_once_and_ready_for_the_first_frame() {
        assert!(Arc::ptr_eq(&app_icon(), &app_icon()));
    }
}
