//! The input method's pending composition (NSTextInputContext).
//!
//! A dead key (`^` on a French keyboard) or an IME composition left pending
//! in one terminal must not apply to the next one. Swift discards it when the
//! terminal loses focus (`RustTerminalView.resignFirstResponder` ->
//! `inputContext.discardMarkedText()`). GPUI shares one NSView per window,
//! so the terminal asks the current input context directly. Main thread only.

use super::Result;

/// Drop the pending composition of the current input context.
pub fn discard_marked_text() -> Result<()> {
    imp::discard_marked_text()
}

#[cfg(target_os = "macos")]
mod imp {
    use objc2_app_kit::NSTextInputContext;

    use crate::platform::{Result, main_thread};

    pub fn discard_marked_text() -> Result<()> {
        if let Some(context) = NSTextInputContext::currentInputContext(main_thread()?) {
            context.discardMarkedText();
        }
        Ok(())
    }
}

#[cfg(not(target_os = "macos"))]
mod imp {
    use crate::platform::Result;

    /// Other platforms' input methods end the composition on focus change.
    pub fn discard_marked_text() -> Result<()> {
        Ok(())
    }
}
