//! Window looks GPUI does not expose: the app theme (NSApplication
//! appearance: System, Light or Dark, `applyAppTheme`), whole-window opacity
//! (NSWindow alphaValue, `applyWindowOpacity`) and floating windows
//! (NSWindow level, `window.floating`).
//!
//! Main thread only. Stubs elsewhere: the theme falls back to the chrome
//! colors, opacity to a see-through background, floating to nothing.

use super::Result;

/// `NSApp.appearance`: `None` follows the system, `Some(true)` dark aqua,
/// `Some(false)` aqua. Every window (terminal, settings) follows it.
pub fn set_app_theme(dark: Option<bool>) -> Result<()> {
    imp::set_app_theme(dark)
}

/// `NSWindow.alphaValue`: the whole window (text, tab bar, background)
/// fades, 0.3 to 1.
pub fn set_window_alpha(window: &gpui::Window, alpha: f32) -> Result<()> {
    imp::set_window_alpha(window, alpha.clamp(0.0, 1.0))
}

/// `NSWindow.level`: floating windows stay above other apps' windows.
pub fn set_window_floating(window: &gpui::Window, floating: bool) -> Result<()> {
    imp::set_window_floating(window, floating)
}

/// Whether whole-window opacity is available (else the app makes only the
/// terminal background see-through).
pub fn supports_window_alpha() -> bool {
    cfg!(target_os = "macos")
}

#[cfg(target_os = "macos")]
mod imp {
    use objc2::rc::Retained;
    use objc2_app_kit::{
        NSAppearance, NSAppearanceNameAqua, NSAppearanceNameDarkAqua, NSApplication,
        NSFloatingWindowLevel, NSNormalWindowLevel, NSView, NSWindow,
    };
    use raw_window_handle::{HasWindowHandle, RawWindowHandle};

    use crate::platform::{PlatformError, Result, main_thread};

    fn ns_window(window: &gpui::Window) -> Result<Retained<NSWindow>> {
        main_thread()?;
        // `HasWindowHandle`, not GPUI's inherent `Window::window_handle`.
        let handle = HasWindowHandle::window_handle(window)
            .map_err(|e| PlatformError::Failed(format!("window handle: {e}")))?;
        let RawWindowHandle::AppKit(appkit) = handle.as_raw() else {
            return Err(PlatformError::Failed("not an AppKit window".into()));
        };
        // SAFETY: GPUI's AppKit handle points to the window's content NSView,
        // alive for as long as `window` is borrowed; we are on the main thread.
        let view: &NSView = unsafe { appkit.ns_view.cast::<NSView>().as_ref() };
        view.window()
            .ok_or_else(|| PlatformError::Failed("view has no window".into()))
    }

    pub fn set_app_theme(dark: Option<bool>) -> Result<()> {
        let app = NSApplication::sharedApplication(main_thread()?);
        let appearance = match dark {
            None => None,
            // SAFETY: AppKit constants, valid for the program's lifetime.
            Some(true) => NSAppearance::appearanceNamed(unsafe { NSAppearanceNameDarkAqua }),
            Some(false) => NSAppearance::appearanceNamed(unsafe { NSAppearanceNameAqua }),
        };
        app.setAppearance(appearance.as_deref());
        Ok(())
    }

    pub fn set_window_alpha(window: &gpui::Window, alpha: f32) -> Result<()> {
        ns_window(window)?.setAlphaValue(alpha as f64);
        Ok(())
    }

    pub fn set_window_floating(window: &gpui::Window, floating: bool) -> Result<()> {
        let level = if floating {
            NSFloatingWindowLevel
        } else {
            NSNormalWindowLevel
        };
        ns_window(window)?.setLevel(level);
        Ok(())
    }
}

#[cfg(not(target_os = "macos"))]
mod imp {
    use crate::platform::{Result, unsupported};

    pub fn set_app_theme(_dark: Option<bool>) -> Result<()> {
        unsupported("app theme")
    }

    pub fn set_window_alpha(_window: &gpui::Window, _alpha: f32) -> Result<()> {
        unsupported("window opacity")
    }

    pub fn set_window_floating(_window: &gpui::Window, _floating: bool) -> Result<()> {
        unsupported("floating windows")
    }
}
