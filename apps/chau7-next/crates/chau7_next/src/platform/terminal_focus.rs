//! Keep native and GPUI keyboard ownership aligned when explicitly focusing a GPUI control.
//!
//! A focus request may target the already-focused GPUI handle while an AppKit child
//! still owns the native keyboard. In that case no GPUI focus-out fires.

#[cfg(target_os = "macos")]
pub fn claim_gpui_keyboard(window: &gpui::Window) {
    use objc2::{MainThreadMarker, rc::Retained};
    use objc2_app_kit::NSView;
    use raw_window_handle::{HasWindowHandle, RawWindowHandle};

    let Some(_main_thread) = MainThreadMarker::new() else {
        return;
    };
    let Ok(handle) = HasWindowHandle::window_handle(window) else {
        return;
    };
    let RawWindowHandle::AppKit(raw) = handle.as_raw() else {
        return;
    };
    // SAFETY: GPUI supplies its live NSView through the window's borrowed raw
    // handle. Retain it only for this synchronous, main-thread operation.
    let Some(host) = (unsafe { Retained::retain(raw.ns_view.cast::<NSView>().as_ptr()) }) else {
        return;
    };
    let Some(native_window) = host.window() else {
        return;
    };
    // Use the host's own window, never NSApp.keyWindow: a click must not change
    // the responder in another Chau7 window or in a native dialog.
    if native_window
        .firstResponder()
        .and_then(|responder| responder.downcast::<NSView>().ok())
        .is_some_and(|responder| std::ptr::eq(&*responder, &*host))
    {
        return;
    }
    native_window.makeFirstResponder(Some(&host));
}

#[cfg(not(target_os = "macos"))]
pub fn claim_gpui_keyboard(_window: &gpui::Window) {}
