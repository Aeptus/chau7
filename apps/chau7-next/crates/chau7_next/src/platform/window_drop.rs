//! Native hit testing and eligibility for cross-window tab drops.
//!
//! GPUI's cached screen bounds are not reliable on every display or Space.
//! On macOS, ask AppKit which window is actually frontmost at the pointer.

use gpui::{Pixels, Point, Window};

/// Result of asking AppKit which window is under a drag pointer.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum NativeDropHit {
    /// Native hit testing is unavailable; callers may use the pure fallback.
    Unavailable,
    /// AppKit returned no window (or a window outside the eligible workspaces).
    /// This blocks the geometric fallback to prevent drops through other apps.
    Blocked,
    /// The actual frontmost native window number under the point.
    Window(isize),
}

/// Return the frontmost native window at `point`, or 0 when no window is hit.
///
/// The hit can belong to another application. Callers must match it against
/// their own eligible windows before transferring tabs.
#[cfg(target_os = "macos")]
pub(crate) fn topmost_window_number_at_screen_point(
    point: objc2_foundation::NSPoint,
    mtm: objc2::MainThreadMarker,
) -> isize {
    use objc2_app_kit::NSWindow;

    NSWindow::windowNumberAtPoint_belowWindowWithWindowNumber(point, 0, mtm)
}

/// Find the native window under a GPUI mouse position, converting from the
/// content view's local coordinates through AppKit into global screen space.
pub(crate) fn native_drop_hit_for_position(
    window: &Window,
    position: Point<Pixels>,
) -> NativeDropHit {
    imp::native_drop_hit_for_position(window, position)
}

/// Native number for a live, visible Chau7 window on the active Space.
///
/// This deliberately does not require the window to be key or the app to be
/// active; those are irrelevant to whether it is the actual drop target.
pub(crate) fn eligible_window_number(window: &Window) -> Option<isize> {
    imp::eligible_window_number(window)
}

#[cfg(target_os = "macos")]
mod imp {
    use objc2::rc::Retained;
    use objc2_app_kit::{NSView, NSWindow};
    use objc2_foundation::NSPoint;
    use raw_window_handle::{HasWindowHandle, RawWindowHandle};

    use super::{NativeDropHit, Pixels, Point, Window, topmost_window_number_at_screen_point};
    use crate::platform::{PlatformError, main_thread};

    fn content_view(window: &Window) -> Result<&NSView, PlatformError> {
        main_thread()?;
        let handle = HasWindowHandle::window_handle(window)
            .map_err(|error| PlatformError::Failed(format!("window handle: {error}")))?;
        let RawWindowHandle::AppKit(appkit) = handle.as_raw() else {
            return Err(PlatformError::Failed("not an AppKit window".into()));
        };
        // SAFETY: GPUI's AppKit handle points to this window's content view,
        // which remains alive while the borrowed GPUI window is alive.
        Ok(unsafe { appkit.ns_view.cast::<NSView>().as_ref() })
    }

    fn native_window(view: &NSView) -> Option<Retained<NSWindow>> {
        view.window()
    }

    pub(super) fn eligible_window_number(window: &Window) -> Option<isize> {
        let _mtm = main_thread().ok()?;
        let view = content_view(window).ok()?;
        let native = native_window(view)?;
        (native.isVisible() && !native.isMiniaturized() && native.isOnActiveSpace())
            .then_some(native.windowNumber())
    }

    pub(super) fn native_drop_hit_for_position(
        window: &Window,
        position: Point<Pixels>,
    ) -> NativeDropHit {
        let Ok(mtm) = main_thread() else {
            return NativeDropHit::Unavailable;
        };
        let Ok(view) = content_view(window) else {
            return NativeDropHit::Unavailable;
        };
        let Some(native) = native_window(view) else {
            return NativeDropHit::Blocked;
        };

        let bounds = view.bounds();
        let x = bounds.origin.x + f64::from(f32::from(position.x));
        let local_y = f64::from(f32::from(position.y));
        let y = if view.isFlipped() {
            bounds.origin.y + local_y
        } else {
            bounds.origin.y + bounds.size.height - local_y
        };
        let in_window = view.convertPoint_toView(NSPoint::new(x, y), None);
        let screen = native.convertPointToScreen(in_window);
        let number = topmost_window_number_at_screen_point(screen, mtm);
        if number <= 0 {
            NativeDropHit::Blocked
        } else {
            NativeDropHit::Window(number)
        }
    }
}

#[cfg(not(target_os = "macos"))]
mod imp {
    use super::{NativeDropHit, Pixels, Point, Window};

    pub(super) fn eligible_window_number(_window: &Window) -> Option<isize> {
        None
    }

    pub(super) fn native_drop_hit_for_position(
        _window: &Window,
        _position: Point<Pixels>,
    ) -> NativeDropHit {
        NativeDropHit::Unavailable
    }
}
