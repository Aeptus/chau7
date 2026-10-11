//! The native window: options, global frame, and window actions.

use gpui::{
    App, Bounds, Context, Div, Pixels, Stateful, Window, WindowBounds, WindowOptions, prelude::*,
    px, size,
};
use gpui_kit::component::TitleBar;

use super::Workspace;
use crate::actions::{CloseWindow, Minimize, ToggleFullScreen, Zoom};
use crate::settings::Settings;

pub(super) fn register_window_actions(
    div: Stateful<Div>,
    cx: &mut Context<Workspace>,
) -> Stateful<Div> {
    div.on_action(cx.listener(|this, _: &CloseWindow, window, cx| this.close_window(window, cx)))
        .on_action(cx.listener(|_, _: &ToggleFullScreen, window, _| window.toggle_fullscreen()))
        .on_action(cx.listener(|_, _: &Minimize, window, _| window.minimize_window()))
        .on_action(cx.listener(|_, _: &Zoom, window, _| window.zoom_window()))
}

impl Workspace {
    /// Close Window: the tabs and their shells are kept (macOS), the window
    /// comes back from the Dock or the next shortcut.
    pub(super) fn close_window(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.hide_tabs(window, cx);
        window.remove_window();
    }

    /// Park the tabs in `AppData` so closing the window does not end them.
    pub(super) fn hide_tabs(&mut self, window: &Window, cx: &mut Context<Self>) {
        if !cfg!(target_os = "macos") {
            return;
        }
        if let Some(parked) = self.park_tabs(window) {
            cx.global_mut::<super::AppData>().hidden.push(parked);
        }
    }

    /// Closing with the window's close button hides the window too.
    pub(super) fn hide_on_close(window: &mut Window, cx: &mut Context<Self>) {
        let workspace = cx.entity().downgrade();
        window.on_window_should_close(cx, move |window, cx| {
            if let Some(workspace) = workspace.upgrade() {
                workspace.update(cx, |ws, cx| ws.hide_tabs(window, cx));
            }
            true
        });
    }
}

/// Window frame in one coordinate space shared by every window. On macOS,
/// GPUI reports window bounds relative to the window's display, so the
/// display's origin (global, top-left of the primary display) is added;
/// otherwise windows on a second display would overlap those on the first.
/// The other backends already report global coordinates.
pub(super) fn global_bounds(window: &Window, cx: &App) -> Bounds<Pixels> {
    let bounds = window.bounds();
    if cfg!(target_os = "macos")
        && let Some(display) = window.display(cx)
    {
        return Bounds::new(display.bounds().origin + bounds.origin, bounds.size);
    }
    bounds
}

/// Options for a new Chau7 Next window.
pub fn window_options(bounds: Option<Bounds<Pixels>>, cx: &App) -> WindowOptions {
    let bounds = bounds.unwrap_or_else(|| Bounds::centered(None, size(px(980.0), px(620.0)), cx));
    WindowOptions {
        window_bounds: Some(WindowBounds::Windowed(bounds)),
        window_min_size: Some(size(px(420.0), px(240.0))),
        app_id: Some("com.chau7.next".into()),
        window_background: background_appearance(Settings::get(cx).appearance.opacity),
        ..TitleBar::window_options()
    }
}

/// The window material behind the terminal. On macOS it is always the blurred
/// material, as in Swift (`createOverlayWindow`); elsewhere blur is only worth
/// it once the terminal is see-through.
pub fn background_appearance(opacity: f32) -> gpui::WindowBackgroundAppearance {
    if cfg!(target_os = "macos") || opacity < 1.0 {
        gpui::WindowBackgroundAppearance::Blurred
    } else {
        gpui::WindowBackgroundAppearance::Opaque
    }
}

/// What was last applied to each window, so AppKit is only called on changes.
#[derive(Clone, Copy, PartialEq)]
struct AppliedStyle {
    alpha: f32,
    floating: bool,
    background: gpui::WindowBackgroundAppearance,
}

/// Window opacity (whole window on macOS, `applyWindowOpacity`), floating
/// level (`window.floating`) and background blur, applied live. Called on
/// every render; does nothing when unchanged.
pub(super) fn apply_window_style(window: &mut Window, cx: &App) {
    thread_local! {
        static APPLIED: std::cell::RefCell<std::collections::HashMap<gpui::WindowId, AppliedStyle>> =
            Default::default();
    }
    let appearance = &Settings::get(cx).appearance;
    let wanted = AppliedStyle {
        alpha: appearance.opacity,
        floating: appearance.window_floating,
        background: background_appearance(appearance.opacity),
    };
    let id = window.window_handle().window_id();
    let previous = APPLIED.with(|a| a.borrow_mut().insert(id, wanted));
    if previous == Some(wanted) {
        return;
    }
    if previous.is_none() {
        // First frame of a terminal window: accept dropped image data
        // (RBK-051) and offer the selection to macOS Services (RBK-042).
        crate::platform::drop_image::install(window);
        crate::platform::services::install(window);
    }
    if previous.is_none_or(|p| p.background != wanted.background) {
        window.set_background_appearance(wanted.background);
    }
    if crate::platform::window_style::supports_window_alpha()
        && previous.is_none_or(|p| p.alpha != wanted.alpha)
        && let Err(err) = crate::platform::window_style::set_window_alpha(window, wanted.alpha)
    {
        log::warn!("window opacity: {err}");
    }
    if previous.is_none_or(|p| p.floating != wanted.floating)
        && (wanted.floating || previous.is_some())
        && let Err(err) =
            crate::platform::window_style::set_window_floating(window, wanted.floating)
    {
        log::warn!("floating window: {err}");
    }
}
