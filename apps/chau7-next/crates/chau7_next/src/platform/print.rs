//! Print (File menu, Cmd+P): the macOS print panel for the terminal.
//!
//! Swift prints the terminal view itself (`AppDelegate.printTerminal`,
//! NSPrintOperation, fit to the page width, print and progress panels).
//! GPUI draws with Metal and has no printable NSView, so the visible text is
//! laid out in an off-screen NSTextView in a monospaced font and printed with
//! the same options. Main thread only; blocks while the panel is open, as in
//! Swift (`NSPrintOperation.run`).

use super::Result;

/// Open the print panel for `text`, set in `font_name` at `font_size` points
/// (the system monospaced font when that font is not installed).
pub fn print_text(text: &str, font_name: &str, font_size: f64) -> Result<()> {
    imp::print_text(text, font_name, font_size)
}

#[cfg(target_os = "macos")]
mod imp {
    use objc2::MainThreadOnly;
    use objc2_app_kit::{
        NSFont, NSPrintInfo, NSPrintOperation, NSPrintingPaginationMode, NSTextView,
    };
    use objc2_foundation::{NSPoint, NSRect, NSSize, NSString};

    use crate::platform::{Result, main_thread};

    pub fn print_text(text: &str, font_name: &str, font_size: f64) -> Result<()> {
        let mtm = main_thread()?;
        let info = NSPrintInfo::sharedPrintInfo();
        info.setHorizontalPagination(NSPrintingPaginationMode::Fit);
        info.setVerticalPagination(NSPrintingPaginationMode::Automatic);
        info.setHorizontallyCentered(true);
        info.setVerticallyCentered(false);
        let paper = info.paperSize();
        let frame = NSRect::new(
            NSPoint::new(0.0, 0.0),
            NSSize::new(paper.width, paper.height),
        );
        let view = NSTextView::initWithFrame(NSTextView::alloc(mtm), frame);
        view.setString(&NSString::from_str(text));
        let font = NSFont::fontWithName_size(&NSString::from_str(font_name), font_size)
            .or_else(|| NSFont::userFixedPitchFontOfSize(font_size));
        view.setFont(font.as_deref());
        let operation = NSPrintOperation::printOperationWithView_printInfo(&view, &info);
        operation.setShowsPrintPanel(true);
        operation.setShowsProgressPanel(true);
        operation.runOperation();
        Ok(())
    }
}

#[cfg(not(target_os = "macos"))]
mod imp {
    use crate::platform::{Result, unsupported};

    pub fn print_text(_text: &str, _font_name: &str, _font_size: f64) -> Result<()> {
        unsupported("printing")
    }
}

#[cfg(test)]
mod tests {
    #[cfg(not(target_os = "macos"))]
    #[test]
    fn stub_is_unsupported() {
        assert!(super::print_text("x", "Menlo", 11.0).is_err());
    }
}
