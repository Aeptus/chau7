//! Launch at login (Settings > General, SET-018, MIG-001/002).
//!
//! macOS 13+ registers the app itself as a login item with SMAppService, so
//! there is no LaunchAgent plist to write (the Swift app writes
//! `~/Library/LaunchAgents/<bundle id>.plist`; the two never collide since
//! Chau7 Next has its own bundle id). The user can also turn it off in
//! System Settings > General > Login Items, so read [`LoginItem::status`]
//! rather than trusting a saved setting.

use super::Result;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LoginItemStatus {
    /// Not registered: the app does not start at login.
    Disabled,
    /// Registered and allowed: the app starts at login.
    Enabled,
    /// Registered, but the user must allow it in System Settings > Login
    /// Items ([`LoginItem::open_system_settings`]).
    RequiresApproval,
    /// The system cannot find the app (not running from the bundle).
    NotFound,
    /// Not available on this OS.
    Unsupported,
}

impl LoginItemStatus {
    /// What a Launch at Login switch shows.
    pub fn is_on(self) -> bool {
        matches!(self, Self::Enabled | Self::RequiresApproval)
    }
}

pub trait LoginItem: Send + Sync {
    fn status(&self) -> LoginItemStatus;
    /// Registers (`true`) or unregisters (`false`) the app as a login item.
    fn set_enabled(&self, enabled: bool) -> Result<()>;
    /// Opens System Settings > General > Login Items.
    fn open_system_settings(&self) -> Result<()>;
}

/// SMAppService on macOS; a stub elsewhere. In isolated test mode
/// (`CHAU7_NEXT_ISOLATED_TEST_MODE=1`) nothing is registered: the status is
/// off and changes are ignored, as in Swift's `LaunchAtLoginManager`.
pub fn current() -> &'static dyn LoginItem {
    static ITEM: imp::MainApp = imp::MainApp;
    static ISOLATED: Isolated = Isolated;
    if chau7_next_core::data_root::is_isolated_test_mode() {
        &ISOLATED
    } else {
        &ITEM
    }
}

/// The login item of an isolated test run: never registered.
struct Isolated;

impl LoginItem for Isolated {
    fn status(&self) -> LoginItemStatus {
        LoginItemStatus::Disabled
    }

    fn set_enabled(&self, _enabled: bool) -> Result<()> {
        log::info!("LaunchAtLogin: ignored in isolated test mode.");
        Ok(())
    }

    fn open_system_settings(&self) -> Result<()> {
        Ok(())
    }
}

#[cfg(target_os = "macos")]
mod imp {
    use objc2_service_management::{SMAppService, SMAppServiceStatus};

    use super::LoginItemStatus;
    use crate::platform::{PlatformError, Result, running_from_app_bundle};

    pub struct MainApp;

    impl super::LoginItem for MainApp {
        fn status(&self) -> LoginItemStatus {
            if !running_from_app_bundle() {
                return LoginItemStatus::NotFound;
            }
            // SAFETY: plain SMAppService calls on the main app service.
            let status = unsafe { SMAppService::mainAppService().status() };
            match status {
                SMAppServiceStatus::Enabled => LoginItemStatus::Enabled,
                SMAppServiceStatus::RequiresApproval => LoginItemStatus::RequiresApproval,
                SMAppServiceStatus::NotFound => LoginItemStatus::NotFound,
                _ => LoginItemStatus::Disabled,
            }
        }

        fn set_enabled(&self, enabled: bool) -> Result<()> {
            if !running_from_app_bundle() {
                return Err(PlatformError::NotBundled);
            }
            // SAFETY: plain SMAppService calls on the main app service.
            let result = unsafe {
                let service = SMAppService::mainAppService();
                if enabled {
                    service.registerAndReturnError()
                } else {
                    service.unregisterAndReturnError()
                }
            };
            result.map_err(|err| {
                PlatformError::Failed(format!("launch at login: {}", err.localizedDescription()))
            })
        }

        fn open_system_settings(&self) -> Result<()> {
            // SAFETY: class method without arguments.
            unsafe { SMAppService::openSystemSettingsLoginItems() };
            Ok(())
        }
    }
}

#[cfg(not(target_os = "macos"))]
mod imp {
    use super::LoginItemStatus;
    use crate::platform::{Result, log_unsupported_once, unsupported};

    pub struct MainApp;

    impl super::LoginItem for MainApp {
        fn status(&self) -> LoginItemStatus {
            log_unsupported_once("launch at login");
            LoginItemStatus::Unsupported
        }

        fn set_enabled(&self, _enabled: bool) -> Result<()> {
            unsupported("launch at login")
        }

        fn open_system_settings(&self) -> Result<()> {
            unsupported("launch at login")
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn switch_state() {
        assert!(LoginItemStatus::Enabled.is_on());
        assert!(LoginItemStatus::RequiresApproval.is_on());
        assert!(!LoginItemStatus::Disabled.is_on());
        assert!(!LoginItemStatus::NotFound.is_on());
    }

    #[cfg(not(target_os = "macos"))]
    #[test]
    fn stub_is_unsupported() {
        assert_eq!(current().status(), LoginItemStatus::Unsupported);
        assert!(current().set_enabled(true).is_err());
    }
}
