//! Getting the user's attention through the Dock: bouncing the icon
//! ("Dock bounce" action, NSApplication requestUserAttention), the Dock
//! badge, and hiding the Dock icon (menu bar only mode, activation policy).
//!
//! Main thread only. To bring the app to front use GPUI's
//! `cx.activate(true)` instead.

use super::Result;

/// A running Dock bounce, to cancel with [`cancel_attention`].
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct AttentionRequest(pub isize);

/// Bounces the Dock icon until the app is activated: once when
/// `critical` is false (informational), until activated when true.
/// Does nothing while the app is already active.
pub fn request_attention(critical: bool) -> Result<AttentionRequest> {
    imp::request_attention(critical)
}

/// Stops a bounce started with [`request_attention`].
pub fn cancel_attention(request: AttentionRequest) -> Result<()> {
    imp::cancel_attention(request)
}

/// Text on the Dock icon's red badge (a count such as "3"); `None` removes it.
pub fn set_dock_badge(label: Option<&str>) -> Result<()> {
    imp::set_dock_badge(label.filter(|l| !l.is_empty()))
}

/// Shows or hides the Dock icon (and the app menu). Hidden, the app lives in
/// its menu bar item (`window.menuBarOnlyMode`).
pub fn set_dock_icon_visible(visible: bool) -> Result<()> {
    imp::set_dock_icon_visible(visible)
}

/// Sets the Dock icon from PNG bytes (`applicationIconImage`), only when the
/// app runs outside its bundle: a bundled app shows the bundle's icon.
/// Returns false when nothing was set.
pub fn set_unbundled_app_icon(png: impl FnOnce() -> Option<Vec<u8>>) -> Result<bool> {
    imp::set_unbundled_app_icon(png)
}

#[cfg(target_os = "macos")]
mod imp {
    use objc2_app_kit::{NSApplication, NSApplicationActivationPolicy, NSRequestUserAttentionType};
    use objc2_foundation::NSString;

    use super::AttentionRequest;
    use crate::platform::{PlatformError, Result, main_thread};

    pub fn request_attention(critical: bool) -> Result<AttentionRequest> {
        let app = NSApplication::sharedApplication(main_thread()?);
        let kind = if critical {
            NSRequestUserAttentionType::CriticalRequest
        } else {
            NSRequestUserAttentionType::InformationalRequest
        };
        Ok(AttentionRequest(app.requestUserAttention(kind)))
    }

    pub fn cancel_attention(request: AttentionRequest) -> Result<()> {
        let app = NSApplication::sharedApplication(main_thread()?);
        app.cancelUserAttentionRequest(request.0);
        Ok(())
    }

    pub fn set_dock_badge(label: Option<&str>) -> Result<()> {
        let app = NSApplication::sharedApplication(main_thread()?);
        let label = label.map(NSString::from_str);
        app.dockTile().setBadgeLabel(label.as_deref());
        Ok(())
    }

    pub fn set_unbundled_app_icon(png: impl FnOnce() -> Option<Vec<u8>>) -> Result<bool> {
        use objc2::AnyThread;
        use objc2_app_kit::NSImage;
        use objc2_foundation::NSData;

        let marker = main_thread()?;
        if crate::platform::running_from_app_bundle() {
            return Ok(false);
        }
        let Some(png) = png() else {
            return Ok(false);
        };
        let data = NSData::with_bytes(&png);
        let image = NSImage::initWithData(NSImage::alloc(), &data)
            .ok_or_else(|| PlatformError::Failed("invalid app icon image".into()))?;
        let app = NSApplication::sharedApplication(marker);
        // SAFETY: a valid NSImage, set on the main thread.
        unsafe { app.setApplicationIconImage(Some(&image)) };
        Ok(true)
    }

    pub fn set_dock_icon_visible(visible: bool) -> Result<()> {
        let app = NSApplication::sharedApplication(main_thread()?);
        let policy = if visible {
            NSApplicationActivationPolicy::Regular
        } else {
            NSApplicationActivationPolicy::Accessory
        };
        if app.setActivationPolicy(policy) {
            Ok(())
        } else {
            Err(PlatformError::Failed(
                "activation policy not changed".into(),
            ))
        }
    }
}

#[cfg(not(target_os = "macos"))]
mod imp {
    use super::AttentionRequest;
    use crate::platform::{Result, unsupported};

    pub fn request_attention(_critical: bool) -> Result<AttentionRequest> {
        unsupported("Dock bounce")
    }

    pub fn cancel_attention(_request: AttentionRequest) -> Result<()> {
        unsupported("Dock bounce")
    }

    pub fn set_dock_badge(_label: Option<&str>) -> Result<()> {
        unsupported("Dock badge")
    }

    pub fn set_dock_icon_visible(_visible: bool) -> Result<()> {
        unsupported("hiding the Dock icon")
    }

    pub fn set_unbundled_app_icon(_png: impl FnOnce() -> Option<Vec<u8>>) -> Result<bool> {
        unsupported("setting the Dock icon")
    }
}

#[cfg(all(test, not(target_os = "macos")))]
mod tests {
    use super::*;

    #[test]
    fn stubs_report_unsupported() {
        assert!(request_attention(true).is_err());
        assert!(set_dock_badge(Some("2")).is_err());
        assert!(set_dock_icon_visible(false).is_err());
    }
}
