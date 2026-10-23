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

/// Correlate deferred-window errors without logging tab titles or contents.
pub(crate) fn lifecycle(handle: gpui::AnyWindowHandle, phase: &'static str, cx: &App) {
    crate::incidents::record(
        chau7_next_core::incidents::Kind::WindowLifecycle,
        chau7_next_core::incidents::Severity::Info,
        "Terminal window lifecycle",
        std::collections::BTreeMap::from([
            ("windowID".into(), format!("{:?}", handle.window_id())),
            ("phase".into(), phase.into()),
            ("nativeWindowCount".into(), cx.windows().len().to_string()),
            (
                "parkedWindowCount".into(),
                cx.global::<super::AppData>().hidden.len().to_string(),
            ),
        ]),
    );
}

impl Workspace {
    /// Close the window and its sessions after any required confirmation.
    pub(super) fn close_window(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        lifecycle(window.window_handle(), "close_action", cx);
        if self.window_close_allowed(window, cx) {
            self.finish_window_close(window, cx);
            window.remove_window();
        }
    }

    fn window_close_fence(&self, cx: &App) -> Vec<(super::TabId, super::TabCloseFence)> {
        self.state
            .tabs()
            .iter()
            .filter_map(|tab| {
                self.tab_close_fence(tab.id, cx)
                    .map(|fence| (tab.id, fence))
            })
            .collect()
    }

    fn window_close_allowed(&mut self, window: &mut Window, cx: &mut Context<Self>) -> bool {
        if self.last_tab_prompt {
            return false;
        }
        let fence = self.window_close_fence(cx);
        let running: usize = fence.iter().map(|(_, tab)| tab.busy_panes).sum();
        let settings = &Settings::get(cx).tabs;
        if !settings.confirm_close && !(settings.warn_on_close_running && running > 0) {
            return true;
        }
        self.last_tab_prompt = true;
        let detail = if running > 0 {
            format!(
                "Closing this window will end all its tabs, including {running} active terminal session(s)."
            )
        } else {
            "Closing this window will end all its tabs and sessions.".into()
        };
        let answer = crate::l10n::prompt(
            window,
            gpui::PromptLevel::Warning,
            "Close this window?",
            Some(&detail),
            &["Close Window", "Cancel"],
            cx,
        );
        cx.spawn_in(window, async move |this, cx| {
            let answer = answer.await.ok();
            let _ = this.update_in(cx, |this, window, cx| {
                this.last_tab_prompt = false;
                if answer != Some(0)
                    || !window_close_fence_admits(&fence, &this.window_close_fence(cx))
                {
                    return;
                }
                this.finish_window_close(window, cx);
                window.remove_window();
            });
        })
        .detach();
        false
    }

    fn finish_window_close(&mut self, window: &Window, cx: &mut Context<Self>) {
        lifecycle(window.window_handle(), "retiring", cx);
        Self::retire_native_window(window);
        if let Some(closed) = self.take_window_tabs(window) {
            for tab in closed.tabs {
                crate::mcp::control::forget_closed_tab(&tab.meta.uuid.to_string());
                for (_, session) in tab.panes.read(cx).pane_sessions(cx) {
                    session.update(cx, |session, _| session.close());
                }
            }
        }
    }

    /// Retire raw AppKit pointer registrations and queued events before GPUI
    /// removes a terminal window. Only windows created by a terminal
    /// `Workspace` call this helper.
    pub(super) fn retire_native_window(window: &Window) {
        crate::platform::services::uninstall(window);
        crate::platform::drop_image::uninstall(window);
    }

    /// The native close button follows the same confirmation and cleanup path.
    pub(super) fn confirm_on_close(window: &mut Window, cx: &mut Context<Self>) {
        let workspace = cx.entity().downgrade();
        window.on_window_should_close(cx, move |window, cx| {
            workspace.upgrade().is_none_or(|workspace| {
                workspace.update(cx, |ws, cx| {
                    lifecycle(window.window_handle(), "native_close", cx);
                    if ws.window_close_allowed(window, cx) {
                        ws.finish_window_close(window, cx);
                        true
                    } else {
                        false
                    }
                })
            })
        });
    }
}

fn window_close_fence_admits(
    captured: &[(super::TabId, super::TabCloseFence)],
    current: &[(super::TabId, super::TabCloseFence)],
) -> bool {
    captured.len() == current.len()
        && captured
            .iter()
            .zip(current)
            .all(|((id, before), (current_id, after))| id == current_id && before.admits(after))
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
        window_background: background_appearance(
            Settings::get(cx).appearance.opacity,
            Settings::get(cx).appearance.window_blur_enabled,
        ),
        ..TitleBar::window_options()
    }
}

/// The current Windows material setting is independent of opacity. Turning
/// blur off retains ordinary transparency for a translucent terminal.
pub fn background_appearance(opacity: f32, blur_enabled: bool) -> gpui::WindowBackgroundAppearance {
    if blur_enabled && (cfg!(target_os = "macos") || opacity < 1.0) {
        gpui::WindowBackgroundAppearance::Blurred
    } else if opacity < 1.0 {
        gpui::WindowBackgroundAppearance::Transparent
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
        background: background_appearance(appearance.opacity, appearance.window_blur_enabled),
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

#[cfg(test)]
mod current_windows_tests {
    use super::*;
    #[test]
    fn explicit_blur_off_preserves_plain_transparency() {
        assert_eq!(
            background_appearance(0.5, false),
            gpui::WindowBackgroundAppearance::Transparent
        );
        assert_eq!(
            background_appearance(1., false),
            gpui::WindowBackgroundAppearance::Opaque
        );
        assert_eq!(
            background_appearance(0.5, true),
            gpui::WindowBackgroundAppearance::Blurred
        );
    }
}
