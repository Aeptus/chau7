//! Print (File menu, Cmd+P): the macOS print panel for a terminal snapshot.
//!
//! Swift prints the terminal view itself (`AppDelegate.printTerminal`,
//! NSPrintOperation, fit to the page width, print and progress panels).
//! GPUI has no printable NSView. `terminal::paint` supplies an owned PNG from
//! its CPU canvas, and AppKit prints it through a temporary NSImageView. Main
//! thread only; the print panel and progress panel are user initiated.

use super::Result;

/// Print an owned terminal raster at the original viewport's point dimensions.
pub fn print_png(png: &[u8], point_size: (f64, f64)) -> Result<()> {
    imp::print_png(png, point_size)
}

#[cfg(target_os = "macos")]
mod imp {
    use objc2::{AnyThread, MainThreadOnly};
    use objc2_app_kit::{
        NSImage, NSImageScaling, NSImageView, NSPrintInfo, NSPrintOperation,
        NSPrintingPaginationMode,
    };
    use objc2_foundation::{NSData, NSPoint, NSRect, NSSize};

    use crate::platform::{Result, main_thread};

    pub fn print_png(png: &[u8], point_size: (f64, f64)) -> Result<()> {
        if !point_size.0.is_finite()
            || !point_size.1.is_finite()
            || point_size.0 <= 0.0
            || point_size.1 <= 0.0
        {
            return Err(crate::platform::PlatformError::Failed(
                "invalid print snapshot size".into(),
            ));
        }
        let mtm = main_thread()?;
        let data = NSData::with_bytes(png);
        let image = NSImage::initWithData(NSImage::alloc(), &data).ok_or_else(|| {
            crate::platform::PlatformError::Failed("invalid print snapshot PNG".into())
        })?;
        image.setSize(NSSize::new(point_size.0, point_size.1));
        let frame = NSRect::new(
            NSPoint::new(0.0, 0.0),
            NSSize::new(point_size.0, point_size.1),
        );
        let view = NSImageView::initWithFrame(NSImageView::alloc(mtm), frame);
        view.setImage(Some(&image));
        view.setImageScaling(NSImageScaling::ScaleProportionallyDown);

        let info = NSPrintInfo::sharedPrintInfo();
        info.setHorizontalPagination(NSPrintingPaginationMode::Fit);
        info.setVerticalPagination(NSPrintingPaginationMode::Automatic);
        info.setHorizontallyCentered(true);
        info.setVerticallyCentered(false);
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

    pub fn print_png(_png: &[u8], _point_size: (f64, f64)) -> Result<()> {
        unsupported("printing")
    }
}

#[cfg(test)]
mod tests {
    #[cfg(not(target_os = "macos"))]
    #[test]
    fn stub_is_unsupported() {
        assert!(super::print_png(&[], (1.0, 1.0)).is_err());
    }
}
