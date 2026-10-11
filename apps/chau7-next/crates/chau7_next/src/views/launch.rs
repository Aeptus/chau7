//! The launch splash and the welcome screen (`SplashView`, `WelcomeView`,
//! `SplashWindowController`).

use std::sync::Arc;
use std::time::{Duration, Instant};

use chau7_next_core::welcome::{
    self, GET_STARTED, HAS_SHOWN_WELCOME_KEY, LaunchScreen, SPLASH_SIZE, SPLASH_TITLE, TIPS,
    WELCOME_SIZE, WELCOME_TITLE, WelcomeGate,
};
use gpui::{
    AnyWindowHandle, App, Bounds, Context, FontWeight, Image, ImageFormat, IntoElement, Render,
    Task, Window, WindowBackgroundAppearance, WindowBounds, WindowKind, WindowOptions, div,
    prelude::*, px, size,
};
use gpui_kit::component::TitleBar;

use super::ViewsState;
use crate::platform;
use crate::theme::Chrome;
use crate::workspace::AppData;

pub(crate) struct LaunchHandle(AnyWindowHandle);

/// The app icon (a 256 px copy of the Swift app's).
fn app_icon() -> Arc<Image> {
    Arc::new(Image::from_bytes(
        ImageFormat::Png,
        include_bytes!("../../assets/app-icon.png").to_vec(),
    ))
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

/// At launch, after the terminal windows opened: the welcome screen the
/// first time, the splash after that.
pub fn launch(cx: &mut App) {
    match welcome::launch_screen(has_shown_welcome(cx)) {
        LaunchScreen::Welcome => {
            let mut gate = WelcomeGate::default();
            gate.mark_ready();
            open_welcome(gate, cx);
        }
        LaunchScreen::Splash => open_splash(cx),
    }
}

/// Help > Welcome to Chau7.
pub fn show_welcome(cx: &mut App) {
    open_welcome(WelcomeGate::already_running(), cx);
}

fn close_previous(cx: &mut App) {
    if let Some(LaunchHandle(handle)) = cx.global_mut::<ViewsState>().launch.take() {
        let _ = handle.update(cx, |_, window, _| window.remove_window());
    }
}

fn open_splash(cx: &mut App) {
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
        Ok((handle, _)) => cx.global_mut::<ViewsState>().launch = Some(LaunchHandle(handle)),
        Err(err) => log::error!("splash: {err}"),
    }
}

struct SplashView {
    alpha: f32,
    _fade: Task<()>,
}

impl SplashView {
    fn new(cx: &mut Context<Self>) -> Self {
        let started = Instant::now();
        let fade = cx.spawn(async move |this, cx| {
            loop {
                cx.background_executor()
                    .timer(Duration::from_millis(33))
                    .await;
                let elapsed = started.elapsed().as_secs_f32();
                let Some(alpha) = welcome::splash_alpha(elapsed) else {
                    let _ = this.update(cx, |_, cx| cx.defer(close_previous));
                    return;
                };
                let _ = this.update(cx, |this, cx| {
                    if (this.alpha - alpha).abs() > f32::EPSILON {
                        this.alpha = alpha;
                        cx.notify();
                    }
                });
            }
        });
        Self {
            alpha: 1.0,
            _fade: fade,
        }
    }
}

impl Render for SplashView {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let chrome = Chrome::panels(cx);
        div().size_full().child(
            div()
                .size_full()
                .opacity(self.alpha)
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
            cx.global_mut::<ViewsState>().launch = Some(LaunchHandle(handle));
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
            .child(TitleBar::new().child(div().text_sm().child(crate::l10n::tr(WELCOME_TITLE))))
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
