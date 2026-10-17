//! Security-scoped bookmarks (`URL.bookmarkData(options: .withSecurityScope)`)
//! for the protected folders the user granted in the "Grant access" dialog:
//! a folder picked in the open panel stays readable across launches without
//! a new privacy prompt.
//!
//! A started bookmark keeps its URL alive here until [`stop_all`]
//! (`stopAccessingSecurityScopedResource`).

use std::path::{Path, PathBuf};

use super::Result;

/// A bookmark resolved and in use.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Started {
    /// Where the bookmark points now.
    pub path: PathBuf,
    /// The bookmark was stale and was made again: save this one instead.
    pub refreshed: Option<Vec<u8>>,
}

/// A security-scoped bookmark of `path`.
pub fn create(path: &Path) -> Result<Vec<u8>> {
    imp::create(path)
}

/// Resolve `bookmark` and start accessing the folder.
pub fn start(bookmark: &[u8]) -> Result<Started> {
    imp::start(bookmark)
}

/// Stop accessing every started folder (`resetAccessChecks`).
pub fn stop_all() {
    imp::stop_all()
}

#[cfg(target_os = "macos")]
mod imp {
    use std::path::{Path, PathBuf};
    use std::sync::Mutex;

    use objc2::rc::Retained;
    use objc2::runtime::Bool;
    use objc2_foundation::{
        NSData, NSString, NSURL, NSURLBookmarkCreationOptions, NSURLBookmarkResolutionOptions,
    };

    use super::Started;
    use crate::platform::{PlatformError, Result};

    /// URLs being accessed.
    static ACTIVE: Mutex<Vec<Retained<NSURL>>> = Mutex::new(Vec::new());

    fn bookmark_of(url: &NSURL) -> Result<Vec<u8>> {
        url.bookmarkDataWithOptions_includingResourceValuesForKeys_relativeToURL_error(
            NSURLBookmarkCreationOptions::WithSecurityScope,
            None,
            None,
        )
        .map(|data| data.to_vec())
        .map_err(|err| PlatformError::Failed(format!("bookmark: {}", err.localizedDescription())))
    }

    pub fn create(path: &Path) -> Result<Vec<u8>> {
        let url = NSURL::fileURLWithPath(&NSString::from_str(&path.to_string_lossy()));
        bookmark_of(&url)
    }

    pub fn start(bookmark: &[u8]) -> Result<Started> {
        let data = NSData::with_bytes(bookmark);
        let mut stale = Bool::NO;
        // SAFETY: `stale` is a valid pointer for the call.
        let url = unsafe {
            NSURL::URLByResolvingBookmarkData_options_relativeToURL_bookmarkDataIsStale_error(
                &data,
                NSURLBookmarkResolutionOptions::WithSecurityScope,
                None,
                &mut stale,
            )
        }
        .map_err(|err| {
            PlatformError::Failed(format!("resolve bookmark: {}", err.localizedDescription()))
        })?;
        let refreshed = if stale.as_bool() {
            bookmark_of(&url).ok()
        } else {
            None
        };
        // SAFETY: plain call on a file URL; balanced by `stop_all`.
        if !unsafe { url.startAccessingSecurityScopedResource() } {
            return Err(PlatformError::Failed(
                "startAccessingSecurityScopedResource failed".into(),
            ));
        }
        let path = url
            .path()
            .map(|p| PathBuf::from(p.to_string()))
            .unwrap_or_default();
        ACTIVE.lock().unwrap_or_else(|e| e.into_inner()).push(url);
        Ok(Started { path, refreshed })
    }

    pub fn stop_all() {
        let urls = std::mem::take(&mut *ACTIVE.lock().unwrap_or_else(|e| e.into_inner()));
        for url in urls {
            // SAFETY: each URL was started once by `start`.
            unsafe { url.stopAccessingSecurityScopedResource() };
        }
    }
}

#[cfg(not(target_os = "macos"))]
mod imp {
    use std::path::Path;

    use super::Started;
    use crate::platform::{Result, unsupported};

    pub fn create(_path: &Path) -> Result<Vec<u8>> {
        unsupported("security-scoped bookmarks")
    }

    pub fn start(_bookmark: &[u8]) -> Result<Started> {
        unsupported("security-scoped bookmarks")
    }

    pub fn stop_all() {}
}

#[cfg(all(test, not(target_os = "macos")))]
mod tests {
    use super::*;

    #[test]
    fn stubs_report_unsupported() {
        assert!(create(Path::new("/tmp")).is_err());
        assert!(start(b"x").is_err());
        stop_all();
    }
}
