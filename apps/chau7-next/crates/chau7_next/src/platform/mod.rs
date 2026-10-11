//! Platform layer: every macOS-only API Chau7 Next uses, behind small traits
//! and functions, one module per concern (see "Platform traits" in
//! `AGENTS.md`). Feature code calls these and never an AppKit, Foundation,
//! Security or libproc API directly.
//!
//! Each module exposes a trait with `current()` returning the implementation
//! for this OS, or plain functions when no state is needed. macOS has the
//! real implementation. Linux and Windows get a stub that logs once and
//! returns [`PlatformError::Unsupported`] or a neutral value (`None`,
//! `false`), so CI stays green until those ports are done.
//!
//! | Module | Covers |
//! |---|---|
//! | [`secrets`] | Keychain generic passwords (`SecretStore`) |
//! | [`notifications`] | UNUserNotificationCenter banners, permission, clicks (`Notifier`) |
//! | [`oslog`] | macOS unified log (os_log) for category logs |
//! | [`sound`] | NSBeep, NSSound, NSSpeechSynthesizer |
//! | [`attention`] | Dock bounce (requestUserAttention), Dock badge, Dock icon on/off, Dock icon image when unbundled |
//! | [`bookmarks`] | Security-scoped bookmarks of granted protected folders |
//! | [`autofill`] | Password AutoFill ("AutoFill from Passwords...") |
//! | [`workspace`] | NSWorkspace: open with a given app, default app, file icons |
//! | [`pasteboard`] | NSPasteboard change count (copies made in other apps) |
//! | [`print`] | NSPrintOperation: print the terminal text |
//! | [`icloud`] | iCloud key-value store for the settings sync (`CloudStore`) |
//! | [`login_item`] | Launch at login, SMAppService (`LoginItem`) |
//! | [`status_item`] | NSStatusItem menu bar item with a menu (`StatusItem`) |
//! | [`power`] | Opt out of App Nap while the app runs (NSProcessInfo activity) |
//! | [`process`] | libproc: cwd, children, CPU time and memory of processes |
//! | [`system`] | Host name, hardware UUID, accessibility flags, screen lock |
//! | [`cert_trust`] | Login keychain certificate trust (local TLS proxy) |
//! | [`input_method`] | NSTextInputContext: discard a pending composition |
//! | [`local_socket`] | Unix domain socket server (MCP socket) |
//! | [`defaults`] | CFPreferences app defaults (`defaults write com.chau7.next`) |
//! | [`window_style`] | App theme (NSAppearance), window opacity and floating level (NSWindow) |
//!
//! Callbacks from the OS (notification clicked, menu item chosen) are queued
//! in an [`EventQueue`]; the app drains it on its main thread (for example
//! from a GPUI timer), so no callback runs GPUI code from an AppKit stack.
//!
//! ## Use GPUI instead
//!
//! These are already cross-platform in GPUI; do not wrap them here:
//!
//! - Clipboard read and write (NSPasteboard text, OSC 52):
//!   `cx.read_from_clipboard()`, `cx.write_to_clipboard(ClipboardItem)`.
//!   Only the change count (copies from other apps) is in [`pasteboard`].
//! - Open a URL in the default browser: `cx.open_url(url)`.
//! - Open a file with its default app: `cx.open_with_system(path)`.
//! - Reveal in Finder: `cx.reveal_path(path)`.
//! - Open and save panels (NSOpenPanel, NSSavePanel):
//!   `cx.prompt_for_paths(PathPromptOptions)`, `cx.prompt_for_new_path(dir, name)`.
//! - Alerts (NSAlert): `window.prompt(level, message, detail, answers, cx)`.
//! - App menu, Window menu and Dock menu (NSMenu): `cx.set_menus(..)`,
//!   `cx.set_dock_menu(..)`.
//! - Bring the app to front, hide, hide others (NSApplication):
//!   `cx.activate(true)`, `cx.hide()`, `cx.hide_other_apps()`,
//!   `cx.unhide_other_apps()`, `window.activate_window()`.
//! - Dock icon clicked with no window: `cx.on_reopen(..)`.
//! - URL schemes and opened URLs (CFBundleURLTypes): `cx.on_open_urls(..)`,
//!   `cx.register_url_scheme(..)`.
//! - Light or dark appearance (NSAppearance): `cx.window_appearance()`,
//!   `window.appearance()`.
//! - Window level and fullscreen (NSWindow): `WindowKind::PopUp` in
//!   `WindowOptions`, `window.toggle_fullscreen()`, `window.is_fullscreen()`.
//! - Recent documents: `cx.add_recent_document(path)`.
//! - Thermal state: `cx.thermal_state()`.

// The layer is the API that feature ports call; parts of it have no caller
// yet, which is expected.
#![allow(dead_code)]

pub mod attention;
pub mod autofill;
pub mod bookmarks;
pub mod cert_trust;
pub mod defaults;
pub mod drop_image;
pub mod icloud;
pub mod input_method;
pub mod local_socket;
pub mod login_item;
pub mod notifications;
pub mod oslog;
pub mod pasteboard;
pub mod power;
pub mod print;
pub mod process;
pub mod secrets;
pub mod services;
pub mod sound;
pub mod status_item;
pub mod system;
pub mod window_style;
pub mod workspace;

use std::collections::VecDeque;
use std::fmt;
use std::sync::Mutex;

/// Why a platform call did not do what was asked.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PlatformError {
    /// This OS has no implementation yet (Linux and Windows stubs).
    Unsupported(&'static str),
    /// The API needs a real app bundle (`Chau7 Next.app`), for example
    /// notifications and launch at login when run with `cargo run`.
    NotBundled,
    /// An AppKit call was made off the main thread.
    NotMainThread,
    /// The OS refused or failed, with its message.
    Failed(String),
}

impl fmt::Display for PlatformError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Unsupported(what) => write!(f, "{what} is not supported on this platform"),
            Self::NotBundled => write!(f, "this needs Chau7 Next to run from its app bundle"),
            Self::NotMainThread => write!(f, "this must be called on the main thread"),
            Self::Failed(message) => write!(f, "{message}"),
        }
    }
}

impl std::error::Error for PlatformError {}

pub type Result<T> = std::result::Result<T, PlatformError>;

/// Logs once per feature that it is not available on this OS, and returns
/// the matching error. Used by the stubs.
pub(crate) fn unsupported<T>(feature: &'static str) -> Result<T> {
    log_unsupported_once(feature);
    Err(PlatformError::Unsupported(feature))
}

/// Logs once per feature that it is not available on this OS. For stubs that
/// return a neutral value instead of an error.
pub(crate) fn log_unsupported_once(feature: &'static str) {
    static LOGGED: Mutex<Vec<&'static str>> = Mutex::new(Vec::new());
    let mut logged = LOGGED.lock().unwrap_or_else(|e| e.into_inner());
    if !logged.contains(&feature) {
        logged.push(feature);
        log::info!("platform: {feature} is not supported on this OS yet");
    }
}

/// Events from OS callbacks, drained by the app on its main thread. Safe to
/// push from any thread (AppKit and UserNotifications callbacks).
pub struct EventQueue<T> {
    inner: Mutex<VecDeque<T>>,
}

impl<T> EventQueue<T> {
    pub const fn new() -> Self {
        Self {
            inner: Mutex::new(VecDeque::new()),
        }
    }

    pub fn push(&self, event: T) {
        self.inner
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .push_back(event);
    }

    /// Every queued event, oldest first.
    pub fn drain(&self) -> Vec<T> {
        self.inner
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .drain(..)
            .collect()
    }
}

impl<T> Default for EventQueue<T> {
    fn default() -> Self {
        Self::new()
    }
}

/// The main thread marker AppKit calls need, or [`PlatformError::NotMainThread`].
#[cfg(target_os = "macos")]
pub(crate) fn main_thread() -> Result<objc2::MainThreadMarker> {
    objc2::MainThreadMarker::new().ok_or(PlatformError::NotMainThread)
}

/// Whether a bundle path and identifier look like a real app bundle, which
/// UserNotifications and SMAppService require (they abort or fail otherwise).
pub(crate) fn is_app_bundle(bundle_path: &str, bundle_id: Option<&str>) -> bool {
    let path = bundle_path.trim_end_matches('/');
    bundle_id.is_some_and(|id| !id.is_empty()) && path.ends_with(".app")
}

/// Whether this process runs from an app bundle.
#[cfg(target_os = "macos")]
pub(crate) fn running_from_app_bundle() -> bool {
    use objc2_foundation::NSBundle;
    let bundle = NSBundle::mainBundle();
    let id = bundle.bundleIdentifier().map(|id| id.to_string());
    is_app_bundle(&bundle.bundlePath().to_string(), id.as_deref())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn unsupported_returns_the_feature() {
        let result: Result<()> = unsupported("test feature");
        assert_eq!(result, Err(PlatformError::Unsupported("test feature")));
        // A second call only skips the log line.
        let again: Result<u8> = unsupported("test feature");
        assert!(again.is_err());
    }

    #[test]
    fn event_queue_drains_in_order() {
        let queue = EventQueue::new();
        queue.push(1);
        queue.push(2);
        assert_eq!(queue.drain(), vec![1, 2]);
        assert!(queue.drain().is_empty());
    }

    #[test]
    fn app_bundle_detection() {
        assert!(is_app_bundle(
            "/Applications/Chau7 Next.app",
            Some("com.chau7.next")
        ));
        assert!(is_app_bundle("/Applications/Chau7 Next.app/", Some("x")));
        assert!(!is_app_bundle("/Users/me/target/debug", Some("x")));
        assert!(!is_app_bundle("/Applications/Chau7 Next.app", None));
        assert!(!is_app_bundle("/Applications/Chau7 Next.app", Some("")));
    }

    #[test]
    fn errors_have_messages() {
        assert!(
            PlatformError::Unsupported("Keychain")
                .to_string()
                .contains("Keychain")
        );
        assert_eq!(PlatformError::Failed("boom".into()).to_string(), "boom");
    }
}
