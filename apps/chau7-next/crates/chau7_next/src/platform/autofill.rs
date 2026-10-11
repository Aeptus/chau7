//! "AutoFill from Passwords..." (Edit menu and terminal context menu): asks
//! macOS to show the Passwords picker for the focused view. The chosen
//! password arrives through the text input system (GPUI's input handler,
//! `replace_text_in_range`), which the terminal pastes like Swift's
//! `insertText` does for text not typed on the keyboard.
//!
//! Swift sends the private `_handleInsertFromPasswordsCommand:` action down
//! the responder chain (`AppDelegate.autofillFromPasswords`,
//! `RustTerminalView.contextAutoFillFromPasswords`); so does this module.
//! Main thread only.

use super::Result;

/// True when the responder chain can show the Passwords picker (the
/// context menu shows the item only then).
pub fn is_available() -> bool {
    imp::is_available()
}

/// Show the Passwords picker. `Ok(false)` when nothing handled the request.
pub fn request() -> Result<bool> {
    imp::request()
}

#[cfg(target_os = "macos")]
mod imp {
    use objc2::runtime::Sel;
    use objc2_app_kit::NSApplication;

    use crate::platform::{Result, main_thread};

    fn selector() -> Sel {
        Sel::register(c"_handleInsertFromPasswordsCommand:")
    }

    pub fn is_available() -> bool {
        let Ok(mtm) = main_thread() else {
            return false;
        };
        let app = NSApplication::sharedApplication(mtm);
        // SAFETY: a valid selector, no target (responder chain), no sender.
        unsafe { app.targetForAction_to_from(selector(), None, None) }.is_some()
    }

    pub fn request() -> Result<bool> {
        let app = NSApplication::sharedApplication(main_thread()?);
        // SAFETY: as above; the action takes a sender argument, `nil` here.
        Ok(unsafe { app.sendAction_to_from(selector(), None, None) })
    }
}

#[cfg(not(target_os = "macos"))]
mod imp {
    use crate::platform::{Result, unsupported};

    pub fn is_available() -> bool {
        false
    }

    pub fn request() -> Result<bool> {
        unsupported("Password AutoFill")
    }
}

#[cfg(test)]
mod tests {
    #[cfg(not(target_os = "macos"))]
    #[test]
    fn stub_is_unavailable() {
        assert!(!super::is_available());
        assert!(super::request().is_err());
    }
}
