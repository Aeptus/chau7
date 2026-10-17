//! NSWorkspace calls GPUI does not cover: opening a URL or file with a
//! chosen app (URL handler setting, "open URL" action with a browser), the
//! default app for a file or URL, and file icons (preview pane headers).
//!
//! Use GPUI for the rest: `cx.open_url(url)` (default browser),
//! `cx.open_with_system(path)` (default app), `cx.reveal_path(path)`
//! (Show in Finder).

use std::path::{Path, PathBuf};

use super::Result;

/// Read-only process check. The production replacement must not register its
/// helpers or URL handlers while a previous stable app still owns them.
pub fn another_instance_is_running(bundle_id: &str) -> bool {
    #[cfg(target_os = "macos")]
    {
        use objc2_app_kit::NSRunningApplication;
        use objc2_foundation::NSString;
        NSRunningApplication::runningApplicationsWithBundleIdentifier(&NSString::from_str(
            bundle_id,
        ))
        .iter()
        .any(|app| app.processIdentifier() as u32 != std::process::id())
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = bundle_id;
        false
    }
}

/// Opens `url` with the app whose bundle id is `bundle_id`
/// (`com.google.Chrome`). Fails when that app is not installed.
pub fn open_url_with(url: &str, bundle_id: &str) -> Result<()> {
    imp::open_with(Target::Url(url), bundle_id)
}

/// Opens a file with the app whose bundle id is `bundle_id`.
pub fn open_file_with(path: &Path, bundle_id: &str) -> Result<()> {
    imp::open_with(Target::File(path), bundle_id)
}

/// Where the app with this bundle id is installed, if it is.
pub fn app_path(bundle_id: &str) -> Option<PathBuf> {
    imp::app_path(bundle_id)
}

/// The app that opens this URL by default (the default browser for http).
pub fn default_app_for_url(url: &str) -> Option<PathBuf> {
    imp::default_app(Target::Url(url))
}

/// The app that opens this file by default.
pub fn default_app_for_file(path: &Path) -> Option<PathBuf> {
    imp::default_app(Target::File(path))
}

/// The Finder icon of a file, folder or app as PNG bytes, `size` points
/// square (rendered at 2x). Load it in GPUI with `Image::from_bytes(ImageFormat::Png, ..)`.
pub fn file_icon_png(path: &Path, size: f64) -> Option<Vec<u8>> {
    imp::file_icon_png(path, size)
}

/// What to open.
#[derive(Debug, Clone, Copy)]
enum Target<'a> {
    Url(&'a str),
    File(&'a Path),
}

#[cfg(target_os = "macos")]
mod imp {
    use std::path::{Path, PathBuf};

    use objc2::rc::Retained;
    use objc2::runtime::AnyObject;
    use objc2_app_kit::{
        NSBitmapImageFileType, NSBitmapImageRep, NSWorkspace, NSWorkspaceOpenConfiguration,
    };
    use objc2_foundation::{NSArray, NSDictionary, NSSize, NSString, NSURL};

    use super::Target;
    use crate::platform::{PlatformError, Result};

    fn url_for(target: Target<'_>) -> Option<Retained<NSURL>> {
        match target {
            Target::Url(url) => NSURL::URLWithString(&NSString::from_str(url)),
            Target::File(path) => Some(NSURL::fileURLWithPath(&NSString::from_str(
                &path.to_string_lossy(),
            ))),
        }
    }

    fn path_of(url: &NSURL) -> Option<PathBuf> {
        url.path().map(|path| PathBuf::from(path.to_string()))
    }

    pub fn open_with(target: Target<'_>, bundle_id: &str) -> Result<()> {
        let workspace = NSWorkspace::sharedWorkspace();
        let app = workspace
            .URLForApplicationWithBundleIdentifier(&NSString::from_str(bundle_id))
            .ok_or_else(|| PlatformError::Failed(format!("{bundle_id} is not installed")))?;
        let url = url_for(target).ok_or_else(|| PlatformError::Failed("invalid URL".into()))?;
        let urls = NSArray::from_retained_slice(&[url]);
        let configuration = NSWorkspaceOpenConfiguration::configuration();
        workspace.openURLs_withApplicationAtURL_configuration_completionHandler(
            &urls,
            &app,
            &configuration,
            None,
        );
        Ok(())
    }

    pub fn app_path(bundle_id: &str) -> Option<PathBuf> {
        let workspace = NSWorkspace::sharedWorkspace();
        let url =
            workspace.URLForApplicationWithBundleIdentifier(&NSString::from_str(bundle_id))?;
        path_of(&url)
    }

    pub fn default_app(target: Target<'_>) -> Option<PathBuf> {
        let workspace = NSWorkspace::sharedWorkspace();
        let url = url_for(target)?;
        let app = workspace.URLForApplicationToOpenURL(&url)?;
        path_of(&app)
    }

    pub fn file_icon_png(path: &Path, size: f64) -> Option<Vec<u8>> {
        let workspace = NSWorkspace::sharedWorkspace();
        let image = workspace.iconForFile(&NSString::from_str(&path.to_string_lossy()));
        // Twice the point size, so the PNG is sharp on Retina screens.
        image.setSize(NSSize::new(size * 2.0, size * 2.0));
        let tiff = image.TIFFRepresentation()?;
        let bitmap = NSBitmapImageRep::imageRepWithData(&tiff)?;
        let properties: Retained<NSDictionary<NSString, AnyObject>> = NSDictionary::new();
        // SAFETY: an empty properties dictionary is valid for PNG output.
        let png = unsafe {
            bitmap.representationUsingType_properties(NSBitmapImageFileType::PNG, &properties)
        }?;
        Some(png.to_vec())
    }
}

#[cfg(not(target_os = "macos"))]
mod imp {
    use std::path::{Path, PathBuf};

    use super::Target;
    use crate::platform::{Result, log_unsupported_once, unsupported};

    pub fn open_with(_target: Target<'_>, _bundle_id: &str) -> Result<()> {
        unsupported("opening with a chosen app")
    }

    pub fn app_path(_bundle_id: &str) -> Option<PathBuf> {
        log_unsupported_once("app lookup by bundle id");
        None
    }

    pub fn default_app(_target: Target<'_>) -> Option<PathBuf> {
        log_unsupported_once("default app lookup");
        None
    }

    pub fn file_icon_png(_path: &Path, _size: f64) -> Option<Vec<u8>> {
        log_unsupported_once("file icons");
        None
    }
}

#[cfg(all(test, not(target_os = "macos")))]
mod tests {
    use super::*;

    #[test]
    fn stubs_are_neutral() {
        assert!(open_url_with("https://example.com", "com.apple.Safari").is_err());
        assert!(open_file_with(Path::new("/tmp"), "com.apple.TextEdit").is_err());
        assert_eq!(app_path("com.apple.Safari"), None);
        assert_eq!(default_app_for_url("https://example.com"), None);
        assert_eq!(default_app_for_file(Path::new("/tmp")), None);
        assert_eq!(file_icon_png(Path::new("/tmp"), 16.0), None);
    }
}
