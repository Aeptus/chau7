//! System banners (`NotificationManager.dispatchNotification` and the
//! permission handling of `AppModel`): native notifications while they are
//! allowed, the AppleScript `display notification` fallback otherwise
//! (permission denied or not asked yet, not bundled, or for 15 s to 300 s
//! after a native error), Focus / Do Not Disturb and screen lock.

use std::time::{Duration, Instant};

use chau7_next_core::data_root::PRODUCTION_CHANNEL;
use gpui::App;
use uuid::Uuid;

use crate::monitoring_status::MonitoringStatus;
use crate::platform::notifications::{self as native, AuthorizationStatus, NotificationEvent};
use crate::platform::{PlatformError, system};

const BASE_COOLDOWN: f64 = 15.0;
const MAX_COOLDOWN: f64 = 300.0;

/// `AppModel.NotificationPermissionState`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PermissionState {
    UnavailableNotBundled,
    Unknown,
    NotDetermined,
    Denied,
    Authorized,
    Provisional,
}

impl PermissionState {
    pub fn label(self) -> &'static str {
        match self {
            Self::UnavailableNotBundled => "Unavailable (Not Bundled)",
            Self::Unknown => "Unknown",
            Self::NotDetermined => "Not Determined",
            Self::Denied => "Denied",
            Self::Authorized => "Authorized",
            Self::Provisional => "Provisional",
        }
    }

    fn from_status(status: AuthorizationStatus) -> Self {
        match status {
            AuthorizationStatus::NotDetermined => Self::NotDetermined,
            AuthorizationStatus::Denied => Self::Denied,
            AuthorizationStatus::Authorized => Self::Authorized,
            AuthorizationStatus::Provisional => Self::Provisional,
            AuthorizationStatus::Unavailable => Self::UnavailableNotBundled,
        }
    }
}

/// Banner state (`useNativeNotifications`, cooldown, cached permission,
/// Focus state).
#[derive(Debug)]
pub struct BannerState {
    pub permission: PermissionState,
    /// Notification Center off for the app, or the screen locked.
    pub focus_mode_active: bool,
    /// Banners and alerts allowed in System Settings.
    pub alerts_enabled: bool,
    use_native: bool,
    failures: u32,
    cooldown_until: Option<Instant>,
}

impl Default for BannerState {
    fn default() -> Self {
        Self {
            permission: PermissionState::Unknown,
            focus_mode_active: false,
            alerts_enabled: true,
            use_native: true,
            failures: 0,
            cooldown_until: None,
        }
    }
}

fn channel_warning(beta: &'static str, production: &'static str) -> &'static str {
    if PRODUCTION_CHANNEL { production } else { beta }
}

impl BannerState {
    /// The warning Settings shows under the status (`notificationWarning`).
    pub fn warning(&self) -> Option<&'static str> {
        match self.permission {
            PermissionState::UnavailableNotBundled => Some(channel_warning(
                "Notifications require the app bundle. Build and launch Chau7 Next.app.",
                "Notifications require the app bundle. Build and launch Chau7.app.",
            )),
            PermissionState::NotDetermined => Some("Permission has not been requested."),
            PermissionState::Unknown => Some(channel_warning(
                "Notification status unknown. Check System Settings > Notifications > Chau7 Next.",
                "Notification status unknown. Check System Settings > Notifications > Chau7.",
            )),
            PermissionState::Denied => Some(channel_warning(
                "Notifications are denied. Open System Settings and allow alerts for Chau7 Next.",
                "Notifications are denied. Open System Settings and allow alerts for Chau7.",
            )),
            PermissionState::Authorized | PermissionState::Provisional if !self.alerts_enabled => {
                Some(channel_warning(
                    "Alerts are disabled for Chau7 Next. Enable banners or alerts in System Settings.",
                    "Alerts are disabled for Chau7. Enable banners or alerts in System Settings.",
                ))
            }
            _ => None,
        }
    }

    fn reset_native(&mut self) {
        self.failures = 0;
        self.cooldown_until = None;
    }

    /// `updateAuthorizationStatus`.
    fn set_status(&mut self, status: AuthorizationStatus) {
        self.permission = PermissionState::from_status(status);
        self.reset_native();
        match status {
            AuthorizationStatus::Authorized | AuthorizationStatus::Provisional => {
                self.use_native = true
            }
            AuthorizationStatus::Denied => self.use_native = false,
            _ => {}
        }
    }

    /// `shouldUseNativeNotifications`.
    fn should_use_native(&mut self, now: Instant) -> bool {
        if !self.use_native {
            return false;
        }
        match self.cooldown_until {
            Some(until) if until > now => false,
            Some(_) => {
                self.cooldown_until = None;
                true
            }
            None => true,
        }
    }

    /// `nextNativeCooldown`: 15 s doubling per failure, at most 300 s.
    fn next_cooldown(&self) -> Duration {
        let exponent = self.failures.min(5) as i32;
        Duration::from_secs_f64((BASE_COOLDOWN * 2f64.powi(exponent)).min(MAX_COOLDOWN))
    }
}

/// Apply what the OS reported (permission answers, delivery settings,
/// refused banners). Called from the notification timer.
pub fn handle_platform_events(state: &mut BannerState) -> Vec<(String, String)> {
    let mut resend = Vec::new();
    for event in native::current().drain_events() {
        match event {
            NotificationEvent::Authorization(status) => state.set_status(status),
            NotificationEvent::Delivery {
                notification_center,
                alerts,
            } => {
                state.focus_mode_active = !notification_center || system::screen_locked();
                state.alerts_enabled = alerts;
            }
            NotificationEvent::PostFailed {
                title,
                body,
                message,
                ..
            } => {
                state.failures += 1;
                let cooldown = state.next_cooldown();
                state.cooldown_until = Some(Instant::now() + cooldown);
                log::warn!(
                    "Native notification error: {message} (failure #{}). Temporarily disabling native notifications for {}s, falling back to AppleScript.",
                    state.failures,
                    cooldown.as_secs()
                );
                resend.push((title, body));
            }
            // Swift does not handle clicks: a click only brings the app forward.
            NotificationEvent::Clicked { .. } | NotificationEvent::Dismissed { .. } => {}
        }
    }
    resend
}

/// Mirror the permission into Settings > General > Status.
pub fn publish_status(permission: PermissionState, cx: &mut App) {
    let label = permission.label().to_string();
    if MonitoringStatus::get(cx).notifications != label {
        MonitoringStatus::update(cx, |s| s.notifications = label);
    }
}

/// Ask for permission (the system prompts only once) and read the status.
pub fn request_permission(state: &mut BannerState) {
    match native::current().request_authorization() {
        Ok(()) => {}
        Err(PlatformError::NotBundled) => {
            state.permission = PermissionState::UnavailableNotBundled;
            log::warn!("Not running as bundle - notifications use the AppleScript fallback.");
        }
        Err(err) => log::info!("notification permission: {err}"),
    }
}

/// Re-read permission and Focus (every 30 s, `refreshFocusState`).
pub fn refresh(state: &mut BannerState) {
    if let Err(PlatformError::NotBundled) = native::current().refresh_authorization() {
        state.permission = PermissionState::UnavailableNotBundled;
        state.focus_mode_active = system::screen_locked();
    }
}

/// Show a banner (`dispatchNotification`). Returns whether it was handed to
/// a delivery path.
pub fn dispatch(state: &mut BannerState, title: &str, body: &str, cx: &mut App) -> bool {
    let now = Instant::now();
    let native_allowed = state.should_use_native(now)
        && matches!(
            state.permission,
            PermissionState::Authorized | PermissionState::Provisional | PermissionState::Unknown
        );
    if native_allowed {
        let notification = native::Notification {
            id: Uuid::new_v4().to_string().to_uppercase(),
            title: title.to_string(),
            subtitle: None,
            body: body.to_string(),
            sound: true,
            thread_id: None,
        };
        match native::current().post(&notification) {
            Ok(()) => {
                state.reset_native();
                return true;
            }
            Err(PlatformError::NotBundled) => {
                state.permission = PermissionState::UnavailableNotBundled;
            }
            Err(err) => log::debug!("native notification: {err}"),
        }
    }
    fallback(title, body, cx)
}

/// AppleScript on macOS; the toolkit's notification elsewhere.
pub fn fallback(title: &str, body: &str, cx: &mut App) -> bool {
    match native::post_applescript(title, body) {
        Ok(()) => true,
        Err(PlatformError::Unsupported(_)) => {
            cx.show_system_notification(gpui::SystemNotification {
                tag: format!("chau7-next-{}", Uuid::new_v4()).into(),
                title: title.to_string().into(),
                body: body.to_string().into(),
                actions: Vec::new(),
            });
            true
        }
        Err(err) => {
            log::error!("AppleScript notification error: {err}");
            false
        }
    }
}

#[cfg(test)]
mod tests {
    use chau7_next_core::data_root::APP_NAME;

    use super::*;

    #[test]
    fn cooldown_doubles_up_to_five_minutes() {
        let mut s = BannerState::default();
        assert_eq!(s.next_cooldown(), Duration::from_secs(15));
        s.failures = 1;
        assert_eq!(s.next_cooldown(), Duration::from_secs(30));
        s.failures = 9;
        assert_eq!(s.next_cooldown(), Duration::from_secs(300));
    }

    #[test]
    fn warnings_use_the_compiled_product_name() {
        let mut state = BannerState::default();

        state.permission = PermissionState::UnavailableNotBundled;
        let warning = state.warning().unwrap();
        assert!(warning.contains(format!("{APP_NAME}.app").as_str()));

        state.permission = PermissionState::Unknown;
        assert!(
            state
                .warning()
                .unwrap()
                .ends_with(format!("{APP_NAME}.").as_str())
        );

        state.permission = PermissionState::Denied;
        assert!(
            state
                .warning()
                .unwrap()
                .ends_with(format!("{APP_NAME}.").as_str())
        );

        state.permission = PermissionState::Authorized;
        state.alerts_enabled = false;
        assert!(state.warning().unwrap().contains(APP_NAME));
    }

    #[test]
    fn native_is_skipped_during_cooldown_and_when_denied() {
        let mut s = BannerState::default();
        let now = Instant::now();
        assert!(s.should_use_native(now));
        s.cooldown_until = Some(now + Duration::from_secs(10));
        assert!(!s.should_use_native(now));
        assert!(s.should_use_native(now + Duration::from_secs(11)));
        s.set_status(AuthorizationStatus::Denied);
        assert!(!s.should_use_native(now));
        assert_eq!(s.permission, PermissionState::Denied);
        assert!(s.warning().unwrap().contains("denied"));
        s.set_status(AuthorizationStatus::Authorized);
        assert!(s.should_use_native(now));
        assert_eq!(s.warning(), None);
        s.alerts_enabled = false;
        assert!(s.warning().unwrap().contains("Alerts are disabled"));
        assert_eq!(PermissionState::Provisional.label(), "Provisional");
    }
}
